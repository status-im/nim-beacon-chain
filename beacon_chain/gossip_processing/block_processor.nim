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
  ../spec/datatypes/[phase0, altair],
  ../spec/[crypto, digest, forkedbeaconstate_helpers],
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
    blck*: ForkedSignedBeaconBlock
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

    # Producers
    # ----------------------------------------------------------------
    blocksQueue*: AsyncQueue[BlockEntry] # Exported for "test_sync_manager"

    # Consumer
    # ----------------------------------------------------------------
    consensusManager: ref ConsensusManager
      ## Blockchain DAG, AttestationPool and Quarantine
    getTime: GetTimeFn

# Initialization
# ------------------------------------------------------------------------------

proc new*(T: type BlockProcessor,
          dumpEnabled: bool,
          dumpDirInvalid, dumpDirIncoming: string,
          consensusManager: ref ConsensusManager,
          getTime: GetTimeFn): ref BlockProcessor =
  (ref BlockProcessor)(
    dumpEnabled: dumpEnabled,
    dumpDirInvalid: dumpDirInvalid,
    dumpDirIncoming: dumpDirIncoming,
    blocksQueue: newAsyncQueue[BlockEntry](),
    consensusManager: consensusManager,
    getTime: getTime)

proc getCurrentBeaconTime*(self: BlockProcessor): BeaconTime =
  self.consensusManager.dag.beaconClock.toBeaconTime(self.getTime())

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
    self: var BlockProcessor, blck: ForkedSignedBeaconBlock,
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
      blck: blck,
      resfut: resfut, queueTick: Moment.now(),
      validationDur: validationDur))
  except AsyncQueueFullError:
    raiseAssert "unbounded queue"

# Storage
# ------------------------------------------------------------------------------

proc dumpBlock*[T](
    self: BlockProcessor, signedBlock: phase0.SignedBeaconBlock,
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
    self: var BlockProcessor, signedBlock: phase0.SignedBeaconBlock,
    wallSlot: Slot): Result[void, BlockError] =
  let
    attestationPool = self.consensusManager.attestationPool

  type Trusted = typeof signedBlock.asTrusted()
  let blck = self.consensusManager.dag.addRawBlock(
    self.consensusManager.quarantine, signedBlock) do (
      blckRef: BlockRef, trustedBlock: Trusted, epochRef: EpochRef):
    # Callback add to fork choice if valid
    attestationPool[].addForkChoice(
      epochRef, blckRef, trustedBlock.message, wallSlot)

  # TODO self.dumpBlock(signedBlock, blck)

  # There can be a scenario where we receive a block we already received.
  # However this block was before the last finalized epoch and so its parent
  # was pruned from the ForkChoice.
  if blck.isErr:
    return err(blck.error[1])
  ok()

proc storeBlock(
    self: var BlockProcessor, signedBlock: altair.SignedBeaconBlock,
    wallSlot: Slot): Result[void, BlockError] =
  let
    attestationPool = self.consensusManager.attestationPool

  # TODO only differs in altair.TrustedSignedBeaconBlock
  let blck = self.consensusManager.dag.addRawBlock(
    self.consensusManager.quarantine, signedBlock) do (
      blckRef: BlockRef, trustedBlock: altair.TrustedSignedBeaconBlock,
      epochRef: EpochRef):
    # Callback add to fork choice if valid
    attestationPool[].addForkChoice(
      epochRef, blckRef, trustedBlock.message, wallSlot)

  when false:
    # TODO altair
    self.dumpBlock(signedBlock, blck)

  # There can be a scenario where we receive a block we already received.
  # However this block was before the last finalized epoch and so its parent
  # was pruned from the ForkChoice.
  if blck.isErr:
    return err(blck.error[1])
  ok()

# Event Loop
# ------------------------------------------------------------------------------

# TODO extract if useful to helper module
template getForkedBlockField(x, y: untyped): untyped =
  case x.kind:
  of BeaconBlockFork.Phase0: x.phase0Block.message.y
  of BeaconBlockFork.Altair: x.altairBlock.message.y

template getForkedBlockRoot(x): untyped =
  case x.kind:
  of BeaconBlockFork.Phase0: x.phase0Block.root
  of BeaconBlockFork.Altair: x.altairBlock.root

proc processBlock(self: var BlockProcessor, entry: BlockEntry) =
  logScope:
    blockRoot = shortLog(getForkedBlockRoot(entry.blck))

  let
    wallTime = self.getCurrentBeaconTime()
    (afterGenesis, wallSlot) = wallTime.toSlot()

  if not afterGenesis:
    error "Processing block before genesis, clock turned back?"
    quit 1

  let
    startTick = Moment.now()
    res = withBlck(entry.blck): self.storeBlock(blck, wallSlot)
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
      localHeadSlot = self.consensusManager.dag.head.slot,
      blockSlot = getForkedBlockField(entry.blck, slot),
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
