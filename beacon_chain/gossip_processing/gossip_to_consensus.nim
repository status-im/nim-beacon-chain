# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/math,
  stew/results,
  chronicles, chronos, metrics,
  ../spec/[crypto, datatypes, digest],
  ../consensus_object_pools/[block_clearance, blockchain_dag, attestation_pool],
  ./consensus_manager,
  ".."/[beacon_clock, beacon_node_types],
  ../ssz/sszdump,
  ../eth1/eth1_monitor

# Gossip Queue Manager
# ------------------------------------------------------------------------------
# The queue manager moves blocks from "Gossip validated" to "Consensus verified"

declareHistogram beacon_store_block_duration_seconds,
  "storeBlock() duration", buckets = [0.25, 0.5, 1, 2, 4, 8, Inf]

type
  SyncBlock* = object
    blk*: SignedBeaconBlock
    resfut*: Future[Result[void, BlockError]]

  BlockEntry* = object
    # Exported for "test_sync_manager"
    v*: SyncBlock

  AttestationEntry = object
    v: Attestation
    attesting_indices: seq[ValidatorIndex]
    sig: CookedSig

  AggregateEntry = AttestationEntry

  VerifQueueManager* = object
    ## This manages the queues of blocks and attestations.
    ## Blocks and attestations are enqueued in a gossip-validated state
    ##
    ## from:
    ## - Gossip (when synced)
    ## - SyncManager (during sync)
    ## - RequestManager (missing ancestor blocks)
    ##
    ## are then consensus-verified and added to:
    ## - the blockchain DAG
    ## - database
    ## - attestation pool
    ## - fork choice
    ##
    ## The queue manager doesn't manage exits (voluntary, attester slashing or proposer slashing)
    ## as don't need extra verification and can be added to the exit pool as soon as they are gossip-validated.

    # Config
    # ----------------------------------------------------------------
    dumpEnabled: bool
    dumpDirInvalid: string
    dumpDirIncoming: string

    # Clock
    # ----------------------------------------------------------------
    getWallTime: GetWallTimeFn

    # Producers
    # ----------------------------------------------------------------
    blocksQueue*: AsyncQueue[BlockEntry] # Exported for "test_sync_manager"

    # Consumer
    # ----------------------------------------------------------------
    consensusManager: ref ConsensusManager
      ## Blockchain DAG, AttestationPool, Quarantine, and Eth1Manager

{.push raises: [Defect].}

# Initialization
# ------------------------------------------------------------------------------

proc new*(T: type VerifQueueManager,
          dumpEnabled: bool,
          dumpDirInvalid, dumpDirIncoming: string,
          consensusManager: ref ConsensusManager,
          getWallTime: GetWallTimeFn): ref VerifQueueManager =
  (ref VerifQueueManager)(
    dumpEnabled: dumpEnabled,
    dumpDirInvalid: dumpDirInvalid,
    dumpDirIncoming: dumpDirIncoming,

    getWallTime: getWallTime,

    blocksQueue: newAsyncQueue[BlockEntry](),
    consensusManager: consensusManager,
  )

# Sync callbacks
# ------------------------------------------------------------------------------

proc done*(blk: SyncBlock) =
  ## Send signal to [Sync/Request]Manager that the block ``blk`` has passed
  ## verification successfully.
  if blk.resfut != nil:
    blk.resfut.complete(Result[void, BlockError].ok())

proc fail*(blk: SyncBlock, error: BlockError) =
  ## Send signal to [Sync/Request]Manager that the block ``blk`` has NOT passed
  ## verification with specific ``error``.
  if blk.resfut != nil:
    blk.resfut.complete(Result[void, BlockError].err(error))

proc complete*(blk: SyncBlock, res: Result[void, BlockError]) =
  ## Send signal to [Sync/Request]Manager about result ``res`` of block ``blk``
  ## verification.
  if blk.resfut != nil:
    blk.resfut.complete(res)

proc hasBlocks*(self: VerifQueueManager): bool =
  self.blocksQueue.len() > 0

# Enqueue
# ------------------------------------------------------------------------------

proc addBlock*(self: var VerifQueueManager, syncBlock: SyncBlock) =
  ## Enqueue a Gossip-validated block for consensus verification
  # Backpressure:
  #   There is no backpressure here - producers must wait for the future in the
  #   SyncBlock to constrain their own processing
  # Producers:
  # - Gossip (when synced)
  # - SyncManager (during sync)
  # - RequestManager (missing ancestor blocks)

  # addLast doesn't fail with unbounded queues, but we'll add asyncSpawn as a
  # sanity check
  asyncSpawn self.blocksQueue.addLast(BlockEntry(v: syncBlock))

# Storage
# ------------------------------------------------------------------------------

proc dumpBlock*[T](
    self: VerifQueueManager, signedBlock: SignedBeaconBlock,
    res: Result[T, (ValidationResult, BlockError)]) =
  if self.dumpEnabled and res.isErr:
    case res.error[1]
    of Invalid:
      dump(
        self.dumpDirInvalid, signedBlock)
    of MissingParent:
      dump(
        self.dumpDirIncoming, signedBlock)
    else:
      discard

proc storeBlock(
    self: var VerifQueueManager, signedBlock: SignedBeaconBlock,
    wallSlot: Slot): Result[void, BlockError] =
  let
    start = Moment.now()
    attestationPool = self.consensusManager.attestationPool

  let blck = self.consensusManager.chainDag.addRawBlock(self.consensusManager.quarantine, signedBlock) do (
      blckRef: BlockRef, trustedBlock: TrustedSignedBeaconBlock,
      epochRef: EpochRef, state: HashedBeaconState):
    # Callback add to fork choice if valid
    attestationPool[].addForkChoice(
      epochRef, blckRef, trustedBlock.message, wallSlot)

  self.dumpBlock(signedBlock, blck)

  # There can be a scenario where we receive a block we already received.
  # However this block was before the last finalized epoch and so its parent
  # was pruned from the ForkChoice.
  if blck.isErr:
    return err(blck.error[1])

  let duration = (Moment.now() - start).toFloatSeconds()
  beacon_store_block_duration_seconds.observe(duration)
  ok()

# Event Loop
# ------------------------------------------------------------------------------

proc processBlock(self: var VerifQueueManager, entry: BlockEntry): bool =
  logScope:
    blockRoot = shortLog(entry.v.blk.root)

  let
    wallTime = self.getWallTime()
    (afterGenesis, wallSlot) = wallTime.toSlot()

  if not afterGenesis:
    error "Processing block before genesis, clock turned back?"
    quit 1

  let
    start = now(chronos.Moment)
    res = self.storeBlock(entry.v.blk, wallSlot)
    storeDone = now(chronos.Moment)

  if res.isOk():
    # Eagerly update head in case the new block gets selected
    self.consensusManager[].updateHead(wallSlot)    # This also eagerly prunes the blocks DAG to prevent processing forks.
    # self.consensusManager.pruneStateCachesDAG() # Amortized pruning, we don't prune states & fork choice here but in `onSlotEnd`()

    let updateDone = now(chronos.Moment)
    let storeBlockDuration = storeDone - start
    let updateHeadDuration = updateDone - storeDone
    let overallDuration = updateDone - start
    let storeSpeed =
      block:
        let secs = float(chronos.seconds(1).nanoseconds)
        if not(overallDuration.isZero()):
          let v = secs / float(overallDuration.nanoseconds)
          round(v * 10_000) / 10_000
        else:
          0.0
    debug "Block processed",
      local_head_slot = self.consensusManager.chainDag.head.slot,
      store_speed = storeSpeed,
      block_slot = entry.v.blk.message.slot,
      store_block_duration = $storeBlockDuration,
      update_head_duration = $updateHeadDuration,
      overall_duration = $overallDuration

    if entry.v.resFut != nil:
      entry.v.resFut.complete(Result[void, BlockError].ok())
    true
  elif res.error() in {BlockError.Duplicate, BlockError.Old}:
    # These are harmless / valid outcomes - for the purpose of scoring peers,
    # they are ok
    if entry.v.resFut != nil:
      entry.v.resFut.complete(Result[void, BlockError].ok())
    false
  else:
    if entry.v.resFut != nil:
      entry.v.resFut.complete(Result[void, BlockError].err(res.error()))
    false

proc newBlock(consensusManager: ref ConsensusManager, executionPayload: ExecutionPayload):
    Future[bool] {.async.} =
  try:
    return await(consensusManager.web3Provider.newBlock(executionPayload)).valid
  except CatchableError:
    return false

proc executionPayloadSync(
    consensusManager: ref ConsensusManager, blck: BeaconBlock) {.async.} =
  # storeBlock() has already run, so already in database, if resolved. Blocks
  # not resolved should not get their execution payloads added, either way. A
  # way of looking at this is as a kind of eth1-block-sync in terms of future
  # refactoring. Notably, newBlock doesnt matter until assembleBlock. It thus
  # isn't required to be completely synchronized all the time, only close, so
  # that assembleBlock can be guaranteed to catch up, in a reasonably bounded
  # time frame.

  # Fast-path out. Maybe it just works and the execution engine was already
  # synced. This should be the usual case.
  if await consensusManager.newBlock(blck.body.execution_payload):
    return

  # Execution engine rejected block, so backfill execution engine.
  var
    executionPayloads = @[blck.body.execution_payload]
    root = blck.parent_root

  # ChainDAG might get pruned, but need to go back to Eth1 root, so access
  # database. While this is potentially unbounded, it practically will not
  # occur outside a single initialization step or the execution engine has
  # not been maintaining reliable connections with Nimbus.
  #
  # This loop enqueues execution payloads which don't yet apply, until it
  # finds one which does, at which point all those queued payloads apply.
  while true:
    let blockData = consensusManager.chainDag.get(root)

    if blockData.isNone:
      discard

    let executionPayload = blockData.get.data.message.body.execution_payload

    if await consensusManager.newBlock(executionPayload):
      break

    # This payload didn't apply either, so queue it up to be applied once the
    # newest applicable execution payload is found.
    executionPayloads.add executionPayload

    # Might run out of execution-layer chain...
    if executionPayload.parent_hash == default(Eth2Digest) or
        executionpayload.blockhash == default(Eth2Digest):
      break

    # ... or consensus-layer chain.
    root = blockData.get.data.message.parent_root
    if root == default(Eth2Digest):
      break

  # executionPayloads is ordered from newest to oldest, but execution payloads
  # must be applied oldest to newest.
  doAssert executionPayloads.len > 0
  for i in countdown(executionPayloads.len - 1, 0):
    if not await consensusManager.newBlock(executionPayloads[i]):
      break  # TODO could detect pathological failure loops here

proc runQueueProcessingLoop*(self: ref VerifQueueManager) {.async.} =
  while true:
    # Cooperative concurrency: one block per loop iteration - because
    # we run both networking and CPU-heavy things like block processing
    # on the same thread, we need to make sure that there is steady progress
    # on the networking side or we get long lockups that lead to timeouts.
    const
      # We cap waiting for an idle slot in case there's a lot of network traffic
      # taking up all CPU - we don't want to _completely_ stop processing blocks
      # in this case - doing so also allows us to benefit from more batching /
      # larger network reads when under load.
      idleTimeout = 10.milliseconds

    discard await idleAsync().withTimeout(idleTimeout)

    let blck = await self[].blocksQueue.popFirst()
    if self[].processBlock(blck):
      await self.consensusManager.executionPayloadSync(blck.v.blk.message)
