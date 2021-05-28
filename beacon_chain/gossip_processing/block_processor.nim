# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/math,
  stew/results,
  chronicles, chronos, metrics,
  ../spec/[crypto, datatypes, digest],
  ../consensus_object_pools/[block_clearance, blockchain_dag, attestation_pool],
  ./consensus_manager,
  ".."/[beacon_clock, beacon_node_types],
  ../ssz/sszdump

# Block Processor
# ------------------------------------------------------------------------------
# The block processor moves blocks from "Incoming" to "Consensus verified"

declareHistogram beacon_store_block_duration_seconds,
  "storeBlock() duration", buckets = [0.25, 0.5, 1, 2, 4, 8, Inf]

type
  BlockEntry* = object
    blck*: SignedBeaconBlock
    resfut*: Future[Result[void, BlockError]]
    queueTick*: Moment # Moment when block was enqueued
    validationDur*: Duration # Time it took to perform gossip validation

  BlockProcessor* = object
    ## This manages the processing of blocks from different sources
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
      ## Blockchain DAG, AttestationPool and Quarantine

# Initialization
# ------------------------------------------------------------------------------

proc new*(T: type BlockProcessor,
          dumpEnabled: bool,
          dumpDirInvalid, dumpDirIncoming: string,
          consensusManager: ref ConsensusManager,
          getWallTime: GetWallTimeFn): ref BlockProcessor =
  (ref BlockProcessor)(
    dumpEnabled: dumpEnabled,
    dumpDirInvalid: dumpDirInvalid,
    dumpDirIncoming: dumpDirIncoming,

    getWallTime: getWallTime,

    blocksQueue: newAsyncQueue[BlockEntry](),
    consensusManager: consensusManager,
  )

# Sync callbacks
# ------------------------------------------------------------------------------

proc done*(entry: BlockEntry) =
  ## Send signal to [Sync/Request]Manager that the block ``entry`` has passed
  ## verification successfully.
  if entry.resfut != nil:
    entry.resfut.complete(Result[void, BlockError].ok())

proc fail*(entry: BlockEntry, error: BlockError) =
  ## Send signal to [Sync/Request]Manager that the block ``blk`` has NOT passed
  ## verification with specific ``error``.
  if entry.resfut != nil:
    entry.resfut.complete(Result[void, BlockError].err(error))

proc hasBlocks*(self: BlockProcessor): bool =
  self.blocksQueue.len() > 0

# Enqueue
# ------------------------------------------------------------------------------

proc addBlock*(
    self: var BlockProcessor, blck: SignedBeaconBlock,
    resfut: Future[Result[void, BlockError]] = nil,
    validationDur = Duration()) =
  ## Enqueue a Gossip-validated block for consensus verification
  # Backpressure:
  #   There is no backpressure here - producers must wait for the future in the
  #   BlockEntry to constrain their own processing
  # Producers:
  # - Gossip (when synced)
  # - SyncManager (during sync)
  # - RequestManager (missing ancestor blocks)

  # addLast doesn't fail with unbounded queues, but we'll add asyncSpawn as a
  # sanity check
  try:
    self.blocksQueue.addLastNoWait(BlockEntry(
      blck: blck, resfut: resfut, queueTick: Moment.now(),
      validationDur: validationDur))
  except AsyncQueueFullError:
    raiseAssert "unbounded queue"

# Storage
# ------------------------------------------------------------------------------

proc dumpBlock*[T](
    self: BlockProcessor, signedBlock: SignedBeaconBlock,
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
    self: var BlockProcessor, signedBlock: SignedBeaconBlock,
    wallSlot: Slot): Result[void, BlockError] =
  let
    attestationPool = self.consensusManager.attestationPool

  let blck = self.consensusManager.chainDag.addRawBlock(
    self.consensusManager.quarantine, signedBlock) do (
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
  ok()

# Event Loop
# ------------------------------------------------------------------------------

proc processBlock(self: var BlockProcessor, entry: BlockEntry) =
  logScope:
    blockRoot = shortLog(entry.blck.root)

  let
    wallTime = self.getWallTime()
    (afterGenesis, wallSlot) = wallTime.toSlot()

  if not afterGenesis:
    error "Processing block before genesis, clock turned back?"
    quit 1

  let
    startTick = Moment.now()
    res = self.storeBlock(entry.blck, wallSlot)
    storeBlockTick = Moment.now()

  if res.isOk():
    # Eagerly update head in case the new block gets selected
    self.consensusManager[].updateHead(wallSlot)

    let
      updateHeadTick = Moment.now()
      queueDur = startTick - entry.queueTick
      storeBlockDur = storeBlockTick - startTick
      updateHeadDur = updateHeadTick - storeBlockTick

    beacon_store_block_duration_seconds.observe(storeBlockDur.toFloatSeconds())

    debug "Block processed",
      localHeadSlot = self.consensusManager.chainDag.head.slot,
      blockSlot = entry.blck.message.slot,
      validationDur = entry.validationDur,
      queueDur, storeBlockDur, updateHeadDur

    entry.done()
  elif res.error() in {BlockError.Duplicate, BlockError.Old}:
    # Duplicate and old blocks are ok from a sync point of view, so we mark
    # them as successful
    entry.done()
  else:
    entry.fail(res.error())

proc runQueueProcessingLoop*(self: ref BlockProcessor) {.async.} =
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

    self[].processBlock(await self[].blocksQueue.popFirst())
