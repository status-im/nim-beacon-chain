# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import chronicles
import options, deques, heapqueue, tables, strutils, sequtils, math, algorithm
import stew/results, chronos, chronicles
import ../spec/[datatypes/phase0, datatypes/altair, digest, helpers, eth2_apis/callsigs_types, forkedbeaconstate_helpers],
       ../networking/[peer_pool, eth2_network]

import ../gossip_processing/block_processor
import ../consensus_object_pools/block_pools_types
export phase0, altair, digest, chronos, chronicles, results, block_pools_types,
       helpers

logScope:
  topics = "syncman"

const
  PeerScoreNoStatus* = -100
    ## Peer did not answer `status` request.
  PeerScoreStaleStatus* = -50
    ## Peer's `status` answer do not progress in time.
  PeerScoreUseless* = -10
    ## Peer's latest head is lower then ours.
  PeerScoreGoodStatus* = 50
    ## Peer's `status` answer is fine.
  PeerScoreNoBlocks* = -100
    ## Peer did not respond in time on `blocksByRange` request.
  PeerScoreGoodBlocks* = 100
    ## Peer's `blocksByRange` answer is fine.
  PeerScoreBadBlocks* = -1000
    ## Peer's response contains incorrect blocks.
  PeerScoreBadResponse* = -1000
    ## Peer's response is not in requested range.
  PeerScoreMissingBlocks* = -200
    ## Peer response contains too many empty blocks.

  SyncWorkersCount* = 10
    ## Number of sync workers to spawn

  StatusUpdateInterval* = chronos.minutes(1)
    ## Minimum time between two subsequent calls to update peer's status

  StatusExpirationTime* = chronos.minutes(2)
    ## Time time it takes for the peer's status information to expire.

type
  SyncFailureKind* = enum
    StatusInvalid,
    StatusDownload,
    StatusStale,
    EmptyProblem,
    BlockDownload,
    BadResponse

  GetSlotCallback* = proc(): Slot {.gcsafe, raises: [Defect].}

  SyncRequest*[T] = object
    index*: uint64
    slot*: Slot
    count*: uint64
    step*: uint64
    item*: T

  SyncResult*[T] = object
    request*: SyncRequest[T]
    data*: seq[ForkedSignedBeaconBlock]

  SyncWaiter*[T] = object
    future: Future[bool]
    request: SyncRequest[T]

  RewindPoint = object
    failSlot: Slot
    epochCount: uint64

  SyncQueue*[T] = ref object
    inpSlot*: Slot
    outSlot*: Slot
    startSlot*: Slot
    lastSlot: Slot
    chunkSize*: uint64
    queueSize*: int
    counter*: uint64
    opcounter*: uint64
    pending*: Table[uint64, SyncRequest[T]]
    waiters: seq[SyncWaiter[T]]
    getFinalizedSlot*: GetSlotCallback
    debtsQueue: HeapQueue[SyncRequest[T]]
    debtsCount: uint64
    readyQueue: HeapQueue[SyncResult[T]]
    rewind: Option[RewindPoint]
    blockProcessor: ref BlockProcessor

  SyncWorkerStatus* {.pure.} = enum
    Sleeping, WaitingPeer, UpdatingStatus, Requesting, Downloading, Processing

  SyncWorker*[A, B] = object
    future: Future[void]
    status: SyncWorkerStatus

  SyncManager*[A, B] = ref object
    pool: PeerPool[A, B]
    responseTimeout: chronos.Duration
    sleepTime: chronos.Duration
    maxStatusAge: uint64
    maxHeadAge: uint64
    toleranceValue: uint64
    getLocalHeadSlot: GetSlotCallback
    getLocalWallSlot: GetSlotCallback
    getFinalizedSlot: GetSlotCallback
    workers: array[SyncWorkersCount, SyncWorker[A, B]]
    notInSyncEvent: AsyncEvent
    rangeAge: uint64
    inRangeEvent*: AsyncEvent
    notInRangeEvent*: AsyncEvent
    chunkSize: uint64
    queue: SyncQueue[A]
    syncFut: Future[void]
    blockProcessor: ref BlockProcessor
    inProgress*: bool
    insSyncSpeed*: float
    avgSyncSpeed*: float
    timeLeft*: Duration
    syncCount*: uint64
    syncStatus*: string

  SyncMoment* = object
    stamp*: chronos.Moment
    slot*: Slot

  SyncFailure*[T] = object
    kind*: SyncFailureKind
    peer*: T
    stamp*: chronos.Moment

  SyncManagerError* = object of CatchableError
  BeaconBlocksRes* = NetRes[seq[ForkedSignedBeaconBlock]]

proc validate*[T](sq: SyncQueue[T],
                  blk: ForkedSignedBeaconBlock): Future[Result[void, BlockError]] =
  let resfut = newFuture[Result[void, BlockError]]("sync.manager.validate")
  sq.blockProcessor[].addBlock(blk, resfut)
  resfut

proc getShortMap*[T](req: SyncRequest[T],
                     data: openArray[ForkedSignedBeaconBlock]): string =
  ## Returns all slot numbers in ``data`` as placement map.
  var res = newStringOfCap(req.count)
  var slider = req.slot
  var last = 0
  for i in 0 ..< req.count:
    if last < len(data):
      for k in last ..< len(data):
        if slider == data[k].slot:
          res.add('x')
          last = k + 1
          break
        elif slider < data[k].slot:
          res.add('.')
          break
    else:
      res.add('.')
    slider = slider + req.step
  result = res

proc contains*[T](req: SyncRequest[T], slot: Slot): bool {.inline.} =
  slot >= req.slot and slot < req.slot + req.count * req.step and
    ((slot - req.slot) mod req.step == 0)

proc cmp*[T](a, b: SyncRequest[T]): int =
  result = cmp(uint64(a.slot), uint64(b.slot))

proc checkResponse*[T](req: SyncRequest[T],
                       data: openArray[ForkedSignedBeaconBlock]): bool =
  if len(data) == 0:
    # Impossible to verify empty response.
    return true

  if uint64(len(data)) > req.count:
    # Number of blocks in response should be less or equal to number of
    # requested blocks.
    return false

  var slot = req.slot
  var rindex = 0'u64
  var dindex = 0

  while (rindex < req.count) and (dindex < len(data)):
    if slot < data[dindex].slot:
      discard
    elif slot == data[dindex].slot:
      inc(dindex)
    else:
      return false
    slot = slot + req.step
    rindex = rindex + 1'u64

  if dindex == len(data):
    return true
  else:
    return false

proc getFullMap*[T](req: SyncRequest[T],
                    data: openArray[ForkedSignedBeaconBlock]): string =
  # Returns all slot numbers in ``data`` as comma-delimeted string.
  result = mapIt(data, $it.message.slot).join(", ")

proc init*[T](t1: typedesc[SyncRequest], t2: typedesc[T], slot: Slot,
              count: uint64): SyncRequest[T] =
  result = SyncRequest[T](slot: slot, count: count, step: 1'u64)

proc init*[T](t1: typedesc[SyncRequest], t2: typedesc[T], start: Slot,
              finish: Slot): SyncRequest[T] =
  let count = finish - start + 1'u64
  result = SyncRequest[T](slot: start, count: count, step: 1'u64)

proc init*[T](t1: typedesc[SyncRequest], t2: typedesc[T], slot: Slot,
              count: uint64, item: T): SyncRequest[T] =
  result = SyncRequest[T](slot: slot, count: count, item: item, step: 1'u64)

proc init*[T](t1: typedesc[SyncRequest], t2: typedesc[T], start: Slot,
              finish: Slot, item: T): SyncRequest[T] =
  let count = finish - start + 1'u64
  result = SyncRequest[T](slot: start, count: count, step: 1'u64, item: item)

proc init*[T](t1: typedesc[SyncFailure], kind: SyncFailureKind,
              peer: T): SyncFailure[T] =
  result = SyncFailure[T](kind: kind, peer: peer, stamp: now(chronos.Moment))

proc empty*[T](t: typedesc[SyncRequest],
               t2: typedesc[T]): SyncRequest[T] {.inline.} =
  result = SyncRequest[T](step: 0'u64, count: 0'u64)

proc setItem*[T](sr: var SyncRequest[T], item: T) =
  sr.item = item

proc isEmpty*[T](sr: SyncRequest[T]): bool {.inline.} =
  result = (sr.step == 0'u64) and (sr.count == 0'u64)

proc init*[T](t1: typedesc[SyncQueue], t2: typedesc[T],
              start, last: Slot, chunkSize: uint64,
              getFinalizedSlotCb: GetSlotCallback,
              blockProcessor: ref BlockProcessor,
              syncQueueSize: int = -1): SyncQueue[T] =
  ## Create new synchronization queue with parameters
  ##
  ## ``start`` and ``last`` are starting and finishing Slots.
  ##
  ## ``chunkSize`` maximum number of slots in one request.
  ##
  ## ``syncQueueSize`` maximum queue size for incoming data. If ``syncQueueSize > 0``
  ## queue will help to keep backpressure under control. If ``syncQueueSize <= 0``
  ## then queue size is unlimited (default).
  ##
  ## ``updateCb`` procedure which will be used to send downloaded blocks to
  ## consumer. Procedure should return ``false`` only when it receives
  ## incorrect blocks, and ``true`` if sequence of blocks is correct.

  # SyncQueue is the core of sync manager, this data structure distributes
  # requests to peers and manages responses from peers.
  #
  # Because SyncQueue is async data structure it manages backpressure and
  # order of incoming responses and it also resolves "joker's" problem.
  #
  # Joker's problem
  #
  # According to current Ethereum2 network specification
  # > Clients MUST respond with at least one block, if they have it and it
  # > exists in the range. Clients MAY limit the number of blocks in the
  # > response.
  #
  # Such rule can lead to very uncertain responses, for example let slots from
  # 10 to 12 will be not empty. Client which follows specification can answer
  # with any response from this list (X - block, `-` empty space):
  #
  # 1.   X X X
  # 2.   - - X
  # 3.   - X -
  # 4.   - X X
  # 5.   X - -
  # 6.   X - X
  # 7.   X X -
  #
  # If peer answers with `1` everything will be fine and `block_pool` will be
  # able to process all 3 blocks. In case of `2`, `3`, `4`, `6` - `block_pool`
  # will fail immediately with chunk and report "parent is missing" error.
  # But in case of `5` and `7` blocks will be processed by `block_pool` without
  # any problems, however it will start producing problems right from this
  # uncertain last slot. SyncQueue will start producing requests for next
  # blocks, but all the responses from this point will fail with "parent is
  # missing" error. Lets call such peers "jokers", because they are joking
  # with responses.
  #
  # To fix "joker" problem we going to perform rollback to the latest finalized
  # epoch's first slot.
  doAssert(chunkSize > 0'u64, "Chunk size should not be zero")
  result = SyncQueue[T](
    startSlot: start,
    lastSlot: last,
    chunkSize: chunkSize,
    queueSize: syncQueueSize,
    getFinalizedSlot: getFinalizedSlotCb,
    waiters: newSeq[SyncWaiter[T]](),
    counter: 1'u64,
    pending: initTable[uint64, SyncRequest[T]](),
    debtsQueue: initHeapQueue[SyncRequest[T]](),
    inpSlot: start,
    outSlot: start,
    blockProcessor: blockProcessor
  )

proc `<`*[T](a, b: SyncRequest[T]): bool {.inline.} =
  result = (a.slot < b.slot)

proc `<`*[T](a, b: SyncResult[T]): bool {.inline.} =
  result = (a.request.slot < b.request.slot)

proc `==`*[T](a, b: SyncRequest[T]): bool {.inline.} =
  result = ((a.slot == b.slot) and (a.count == b.count) and
            (a.step == b.step))

proc lastSlot*[T](req: SyncRequest[T]): Slot {.inline.} =
  ## Returns last slot for request ``req``.
  result = req.slot + req.count - 1'u64

proc makePending*[T](sq: SyncQueue[T], req: var SyncRequest[T]) =
  req.index = sq.counter
  sq.counter = sq.counter + 1'u64
  sq.pending[req.index] = req

proc updateLastSlot*[T](sq: SyncQueue[T], last: Slot) {.inline.} =
  ## Update last slot stored in queue ``sq`` with value ``last``.
  doAssert(sq.lastSlot <= last,
           "Last slot could not be lower then stored one " &
           $sq.lastSlot & " <= " & $last)
  sq.lastSlot = last

proc wakeupWaiters[T](sq: SyncQueue[T], flag = true) =
  ## Wakeup one or all blocked waiters.
  for item in sq.waiters:
    if not(item.future.finished()):
      item.future.complete(flag)

proc waitForChanges[T](sq: SyncQueue[T],
                       req: SyncRequest[T]): Future[bool] {.async.} =
  ## Create new waiter and wait for completion from `wakeupWaiters()`.
  var waitfut = newFuture[bool]("SyncQueue.waitForChanges")
  let waititem = SyncWaiter[T](future: waitfut, request: req)
  sq.waiters.add(waititem)
  try:
    result = await waitfut
  finally:
    sq.waiters.delete(sq.waiters.find(waititem))

proc wakeupAndWaitWaiters[T](sq: SyncQueue[T]) {.async.} =
  ## This procedure will perform wakeupWaiters(false) and blocks until last
  ## waiter will be awakened.
  var waitChanges = sq.waitForChanges(SyncRequest.empty(T))
  sq.wakeupWaiters(false)
  discard await waitChanges

proc resetWait*[T](sq: SyncQueue[T], toSlot: Option[Slot]) {.async.} =
  ## Perform reset of all the blocked waiters in SyncQueue.
  ##
  ## We adding one more waiter to the waiters sequence and
  ## call wakeupWaiters(false). Because our waiter is last in sequence of
  ## waiters it will be resumed only after all waiters will be awakened and
  ## finished.

  # We are clearing pending list, so that all requests that are still running
  # around (still downloading, but not yet pushed to the SyncQueue) will be
  # expired. Its important to perform this call first (before await), otherwise
  # you can introduce race problem.
  sq.pending.clear()

  # We calculating minimal slot number to which we will be able to reset,
  # without missing any blocks. There 3 sources:
  # 1. Debts queue.
  # 2. Processing queue (`inpSlot`, `outSlot`).
  # 3. Requested slot `toSlot`.
  #
  # Queue's `outSlot` is the lowest slot we added to `block_pool`, but
  # `toSlot` slot can be less then `outSlot`. `debtsQueue` holds only not
  # added slot requests, so it can't be bigger then `outSlot` value.
  var minSlot = sq.outSlot
  if toSlot.isSome():
    minSlot = min(toSlot.get(), sq.outSlot)
  sq.debtsQueue.clear()
  sq.debtsCount = 0
  sq.readyQueue.clear()
  sq.inpSlot = minSlot
  sq.outSlot = minSlot

  # We are going to wakeup all the waiters and wait for last one.
  await sq.wakeupAndWaitWaiters()

proc isEmpty*[T](sr: SyncResult[T]): bool {.inline.} =
  ## Returns ``true`` if response chain of blocks is empty (has only empty
  ## slots).
  len(sr.data) == 0

proc hasEndGap*[T](sr: SyncResult[T]): bool {.inline.} =
  ## Returns ``true`` if response chain of blocks has gap at the end.
  let lastslot = sr.request.slot + sr.request.count - 1'u64
  if len(sr.data) == 0:
    return true
  if sr.data[^1].slot != lastslot:
    return true
  return false

proc getLastNonEmptySlot*[T](sr: SyncResult[T]): Slot {.inline.} =
  ## Returns last non-empty slot from result ``sr``. If response has only
  ## empty slots, original request slot will be returned.
  if len(sr.data) == 0:
    # If response has only empty slots we going to use original request slot
    sr.request.slot
  else:
    sr.data[^1].slot

proc toDebtsQueue[T](sq: SyncQueue[T], sr: SyncRequest[T]) =
  sq.debtsQueue.push(sr)
  sq.debtsCount = sq.debtsCount + sr.count

proc getRewindPoint*[T](sq: SyncQueue[T], failSlot: Slot,
                        finalizedSlot: Slot): Slot =
  # Calculate the latest finalized epoch.
  let finalizedEpoch = compute_epoch_at_slot(finalizedSlot)

  # Calculate failure epoch.
  let failEpoch = compute_epoch_at_slot(failSlot)

  # Calculate exponential rewind point in number of epochs.
  let epochCount =
    if sq.rewind.isSome():
      let rewind = sq.rewind.get()
      if failSlot == rewind.failSlot:
        # `MissingParent` happened at same slot so we increase rewind point by
        # factor of 2.
        if failEpoch > finalizedEpoch:
          let rewindPoint = rewind.epochCount shl 1
          if rewindPoint < rewind.epochCount:
            # If exponential rewind point produces `uint64` overflow we will
            # make rewind to latest finalized epoch.
            failEpoch - finalizedEpoch
          else:
            if (failEpoch < rewindPoint) or
               (failEpoch - rewindPoint < finalizedEpoch):
              # If exponential rewind point points to position which is far
              # behind latest finalized epoch.
              failEpoch - finalizedEpoch
            else:
              rewindPoint
        else:
          warn "Trying to rewind over the last finalized epoch",
               finalized_slot = finalizedSlot, fail_slot = failSlot,
               finalized_epoch = finalizedEpoch, fail_epoch = failEpoch,
               rewind_epoch_count = rewind.epochCount,
               finalized_epoch = finalizedEpoch
          0'u64
      else:
        # `MissingParent` happened at different slot so we going to rewind for
        # 1 epoch only.
        if (failEpoch < 1'u64) or (failEpoch - 1'u64 < finalizedEpoch):
          warn "Сould not rewind further than the last finalized epoch",
               finalized_slot = finalizedSlot, fail_slot = failSlot,
               finalized_epoch = finalizedEpoch, fail_epoch = failEpoch,
               rewind_epoch_count = rewind.epochCount,
               finalized_epoch = finalizedEpoch
          0'u64
        else:
          1'u64
    else:
      # `MissingParent` happened first time.
      if (failEpoch < 1'u64) or (failEpoch - 1'u64 < finalizedEpoch):
        warn "Сould not rewind further than the last finalized epoch",
             finalized_slot = finalizedSlot, fail_slot = failSlot,
             finalized_epoch = finalizedEpoch, fail_epoch = failEpoch,
             finalized_epoch = finalizedEpoch
        0'u64
      else:
        1'u64

  # echo "epochCount = ", epochCount

  if epochCount == 0'u64:
    warn "Unable to continue syncing, please restart the node",
         finalized_slot = finalizedSlot, fail_slot = failSlot,
         finalized_epoch = finalizedEpoch, fail_epoch = failEpoch,
         finalized_epoch = finalizedEpoch
    # Calculate the rewind epoch, which will be equal to last rewind point or
    # finalizedEpoch
    let rewindEpoch =
      if sq.rewind.isNone():
        finalizedEpoch
      else:
        compute_epoch_at_slot(sq.rewind.get().failSlot) -
          sq.rewind.get().epochCount
    compute_start_slot_at_epoch(rewindEpoch)
  else:
    # Calculate the rewind epoch, which should not be less than the latest
    # finalized epoch.
    let rewindEpoch = failEpoch - epochCount
    # Update and save new rewind point in SyncQueue.
    sq.rewind = some(RewindPoint(failSlot: failSlot, epochCount: epochCount))
    compute_start_slot_at_epoch(rewindEpoch)

proc push*[T](sq: SyncQueue[T], sr: SyncRequest[T],
              data: seq[ForkedSignedBeaconBlock]) {.async, gcsafe.} =
  ## Push successfull result to queue ``sq``.
  mixin updateScore

  if sr.index notin sq.pending:
    # If request `sr` not in our pending list, it only means that
    # SyncQueue.resetWait() happens and all pending requests are expired, so
    # we swallow `old` requests, and in such way sync-workers are able to get
    # proper new requests from SyncQueue.
    return

  sq.pending.del(sr.index)

  # This is backpressure handling algorithm, this algorithm is blocking
  # all pending `push` requests if `request.slot` not in range:
  # [current_queue_slot, current_queue_slot + sq.queueSize * sq.chunkSize].
  var exitNow = false
  while true:
    if (sq.queueSize > 0) and
       (sr.slot >= sq.outSlot + uint64(sq.queueSize) * sq.chunkSize):
      let res = await sq.waitForChanges(sr)
      if res:
        continue
      else:
        # SyncQueue reset happens. We are exiting to wake up sync-worker.
        exitNow = true
        break
    let syncres = SyncResult[T](request: sr, data: data)
    sq.readyQueue.push(syncres)
    exitNow = false
    break

  if exitNow:
    return

  while len(sq.readyQueue) > 0:
    let minSlot = sq.readyQueue[0].request.slot
    if sq.outSlot != minSlot:
      break
    let item = sq.readyQueue.pop()

    # Validating received blocks one by one
    var res: Result[void, BlockError]
    var failSlot: Option[Slot]
    if len(item.data) > 0:
      for blk in item.data:
        trace "Pushing block", block_root = blk.root,
                               block_slot = blk.slot
        res = await sq.validate(blk)
        if not(res.isOk):
          failSlot = some(blk.slot)
          break
    else:
      res = Result[void, BlockError].ok()

    # Increase progress counter, so watch task will be able to know that we are
    # not stuck.
    inc(sq.opcounter)

    if res.isOk:
      sq.outSlot = sq.outSlot + item.request.count
      if len(item.data) > 0:
        # If there no error and response was not empty we should reward peer
        # with some bonus score.
        item.request.item.updateScore(PeerScoreGoodBlocks)
      sq.wakeupWaiters()
    else:
      debug "Block pool rejected peer's response", peer = item.request.item,
            request_slot = item.request.slot,
            request_count = item.request.count,
            request_step = item.request.step,
            blocks_map = getShortMap(item.request, item.data),
            blocks_count = len(item.data), errCode = res.error,
            topics = "syncman"

      var resetSlot: Option[Slot]

      if res.error == BlockError.MissingParent:
        # If we got `BlockError.MissingParent` it means that peer returns chain
        # of blocks with holes or `block_pool` is in incomplete state. We going
        # to rewind to the first slot at latest finalized epoch.
        let req = item.request
        let finalizedSlot = sq.getFinalizedSlot()
        if finalizedSlot < req.slot:
          let rewindSlot = sq.getRewindPoint(failSlot.get(), finalizedSlot)
          warn "Unexpected missing parent, rewind happens",
               peer = req.item, rewind_to_slot = rewindSlot,
               rewind_epoch_count = sq.rewind.get().epochCount,
               rewind_fail_slot = failSlot.get(),
               finalized_slot = finalized_slot,
               request_slot = req.slot, request_count = req.count,
               request_step = req.step, blocks_count = len(item.data),
               blocks_map = getShortMap(req, item.data), topics = "syncman"
          resetSlot = some(rewindSlot)
          req.item.updateScore(PeerScoreMissingBlocks)
        else:
          error "Unexpected missing parent at finalized epoch slot",
                peer = req.item, to_slot = finalizedSlot,
                request_slot = req.slot, request_count = req.count,
                request_step = req.step, blocks_count = len(item.data),
                blocks_map = getShortMap(req, item.data), topics = "syncman"
          req.item.updateScore(PeerScoreBadBlocks)
      elif res.error == BlockError.Invalid:
        let req = item.request
        warn "Received invalid sequence of blocks", peer = req.item,
              request_slot = req.slot, request_count = req.count,
              request_step = req.step, blocks_count = len(item.data),
              blocks_map = getShortMap(req, item.data), topics = "syncman"
        req.item.updateScore(PeerScoreBadBlocks)
      else:
        let req = item.request
        warn "Received unexpected response from block_pool", peer = req.item,
             request_slot = req.slot, request_count = req.count,
             request_step = req.step, blocks_count = len(item.data),
             blocks_map = getShortMap(req, item.data), errorCode = res.error,
             topics = "syncman"
        req.item.updateScore(PeerScoreBadBlocks)

      # We need to move failed response to the debts queue.
      sq.toDebtsQueue(item.request)
      if resetSlot.isSome():
        await sq.resetWait(resetSlot)
        debug "Rewind to slot was happened", reset_slot = reset_slot.get(),
              queue_input_slot = sq.inpSlot, queue_output_slot = sq.outSlot,
              rewind_epoch_count = sq.rewind.get().epochCount,
              rewind_fail_slot = sq.rewind.get().failSlot,
              reset_slot = resetSlot, topics = "syncman"
      break

proc push*[T](sq: SyncQueue[T], sr: SyncRequest[T]) =
  ## Push failed request back to queue.
  if sr.index notin sq.pending:
    # If request `sr` not in our pending list, it only means that
    # SyncQueue.resetWait() happens and all pending requests are expired, so
    # we swallow `old` requests, and in such way sync-workers are able to get
    # proper new requests from SyncQueue.
    return
  sq.pending.del(sr.index)
  sq.toDebtsQueue(sr)

proc pop*[T](sq: SyncQueue[T], maxslot: Slot, item: T): SyncRequest[T] =
  if len(sq.debtsQueue) > 0:
    if maxSlot < sq.debtsQueue[0].slot:
      return SyncRequest.empty(T)

    var sr = sq.debtsQueue.pop()
    if sr.lastSlot() <= maxSlot:
      sq.debtsCount = sq.debtsCount - sr.count
      sr.setItem(item)
      sq.makePending(sr)
      return sr

    var sr1 = SyncRequest.init(T, sr.slot, maxslot, item)
    let sr2 = SyncRequest.init(T, maxslot + 1'u64, sr.lastSlot())
    sq.debtsQueue.push(sr2)
    sq.debtsCount = sq.debtsCount - sr1.count
    sq.makePending(sr1)
    return sr1
  else:
    if maxSlot < sq.inpSlot:
      return SyncRequest.empty(T)

    if sq.inpSlot > sq.lastSlot:
      return SyncRequest.empty(T)

    let lastSlot = min(maxslot, sq.lastSlot)
    let count = min(sq.chunkSize, lastSlot + 1'u64 - sq.inpSlot)
    var sr = SyncRequest.init(T, sq.inpSlot, count, item)
    sq.inpSlot = sq.inpSlot + count
    sq.makePending(sr)
    return sr

proc len*[T](sq: SyncQueue[T]): uint64 {.inline.} =
  ## Returns number of slots left in queue ``sq``.
  if sq.inpSlot > sq.lastSlot:
    result = sq.debtsCount
  else:
    result = sq.lastSlot - sq.inpSlot + 1'u64 - sq.debtsCount

proc total*[T](sq: SyncQueue[T]): uint64 {.inline.} =
  ## Returns total number of slots in queue ``sq``.
  result = sq.lastSlot - sq.startSlot + 1'u64

proc progress*[T](sq: SyncQueue[T]): uint64 =
  ## Returns queue's ``sq`` progress string.
  let curSlot = sq.outSlot - sq.startSlot
  result = (curSlot * 100'u64) div sq.total()

proc now*(sm: typedesc[SyncMoment], slot: Slot): SyncMoment {.inline.} =
  result = SyncMoment(stamp: now(chronos.Moment), slot: slot)

proc speed*(start, finish: SyncMoment): float {.inline.} =
  ## Returns number of slots per second.
  let slots = finish.slot - start.slot
  let dur = finish.stamp - start.stamp
  let secs = float(chronos.seconds(1).nanoseconds)
  if isZero(dur):
    result = 0.0
  else:
    let v = float(slots) * (secs / float(dur.nanoseconds))
    # We doing round manually because stdlib.round is deprecated
    result = round(v * 10000) / 10000

proc newSyncManager*[A, B](pool: PeerPool[A, B],
                           getLocalHeadSlotCb: GetSlotCallback,
                           getLocalWallSlotCb: GetSlotCallback,
                           getFinalizedSlotCb: GetSlotCallback,
                           blockProcessor: ref BlockProcessor,
                           maxStatusAge = uint64(SLOTS_PER_EPOCH * 4),
                           maxHeadAge = uint64(SLOTS_PER_EPOCH * 1),
                           sleepTime = (int(SLOTS_PER_EPOCH) *
                                        int(SECONDS_PER_SLOT)).seconds,
                           chunkSize = uint64(SLOTS_PER_EPOCH),
                           toleranceValue = uint64(1),
                           rangeAge = uint64(SLOTS_PER_EPOCH * 4)
                           ): SyncManager[A, B] =

  let queue = SyncQueue.init(A, getLocalHeadSlotCb(), getLocalWallSlotCb(),
                             chunkSize, getFinalizedSlotCb, blockProcessor, 1)

  result = SyncManager[A, B](
    pool: pool,
    maxStatusAge: maxStatusAge,
    getLocalHeadSlot: getLocalHeadSlotCb,
    getLocalWallSlot: getLocalWallSlotCb,
    getFinalizedSlot: getFinalizedSlotCb,
    maxHeadAge: maxHeadAge,
    sleepTime: sleepTime,
    chunkSize: chunkSize,
    queue: queue,
    blockProcessor: blockProcessor,
    notInSyncEvent: newAsyncEvent(),
    inRangeEvent: newAsyncEvent(),
    notInRangeEvent: newAsyncEvent(),
    rangeAge: rangeAge
  )

proc getBlocks*[A, B](man: SyncManager[A, B], peer: A,
                      req: SyncRequest): Future[BeaconBlocksRes] {.async.} =
  mixin beaconBlocksByRange, getScore, `==`
  doAssert(not(req.isEmpty()), "Request must not be empty!")
  debug "Requesting blocks from peer", peer = peer,
        slot = req.slot, slot_count = req.count, step = req.step,
        peer_score = peer.getScore(), peer_speed = peer.netKbps(),
        topics = "syncman"
  if peer.useSyncV2():
    var workFut = awaitne beaconBlocksByRange_v2(peer, req.slot, req.count, req.step)
    if workFut.failed():
      debug "Error, while waiting getBlocks response", peer = peer,
            slot = req.slot, slot_count = req.count, step = req.step,
            errMsg = workFut.readError().msg, peer_speed = peer.netKbps(),
            topics = "syncman"
    else:
      let res = workFut.read()
      if res.isErr:
        debug "Error, while reading getBlocks response",
              peer = peer, slot = req.slot, count = req.count,
              step = req.step, peer_speed = peer.netKbps(),
              topics = "syncman", error = $res.error()
      result = res
  else:
    var workFut = awaitne beaconBlocksByRange(peer, req.slot, req.count, req.step)
    if workFut.failed():
      debug "Error, while waiting getBlocks response", peer = peer,
            slot = req.slot, slot_count = req.count, step = req.step,
            errMsg = workFut.readError().msg, peer_speed = peer.netKbps(),
            topics = "syncman"
    else:
      let res = workFut.read()
      if res.isErr:
        debug "Error, while reading getBlocks response",
              peer = peer, slot = req.slot, count = req.count,
              step = req.step, peer_speed = peer.netKbps(),
              topics = "syncman", error = $res.error()
      result = res.map() do (blcks: seq[phase0.SignedBeaconBlock]) -> auto: blcks.mapIt(ForkedSignedBeaconBlock.init(it))

template headAge(): uint64 =
  wallSlot - headSlot

template queueAge(): uint64 =
  wallSlot - man.queue.outSlot

template peerStatusAge(): Duration =
  Moment.now() - peer.state(BeaconSync).statusLastTime

func syncQueueLen*[A, B](man: SyncManager[A, B]): uint64 =
  man.queue.len

proc syncStep[A, B](man: SyncManager[A, B], index: int, peer: A) {.async.} =
  let wallSlot = man.getLocalWallSlot()
  let headSlot = man.getLocalHeadSlot()
  var peerSlot = peer.getHeadSlot()

  # We updating SyncQueue's last slot all the time
  man.queue.updateLastSlot(wallSlot)

  debug "Peer's syncing status", wall_clock_slot = wallSlot,
        remote_head_slot = peerSlot, local_head_slot = headSlot,
        peer_score = peer.getScore(), peer = peer, index = index,
        peer_speed = peer.netKbps(), topics = "syncman"

  # Check if peer's head slot is bigger than our wall clock slot.
  if peerSlot > wallSlot + man.toleranceValue:
    warn "Local timer is broken or peer's status information is invalid",
          wall_clock_slot = wallSlot, remote_head_slot = peerSlot,
          local_head_slot = headSlot, peer = peer, index = index,
          tolerance_value = man.toleranceValue, peer_speed = peer.netKbps(),
          peer_score = peer.getScore(), topics = "syncman"
    discard SyncFailure.init(SyncFailureKind.StatusInvalid, peer)
    return

  # Check if we need to update peer's status information
  if peerStatusAge >= StatusExpirationTime:
    # Peer's status information is very old, its time to update it
    man.workers[index].status = SyncWorkerStatus.UpdatingStatus
    trace "Updating peer's status information", wall_clock_slot = wallSlot,
          remote_head_slot = peerSlot, local_head_slot = headSlot,
          peer = peer, peer_score = peer.getScore(), index = index,
          peer_speed = peer.netKbps(), topics = "syncman"

    try:
      let res = await peer.updateStatus()
      if not(res):
        peer.updateScore(PeerScoreNoStatus)
        debug "Failed to get remote peer's status, exiting", peer = peer,
              peer_score = peer.getScore(), peer_head_slot = peerSlot,
              peer_speed = peer.netKbps(), index = index, topics = "syncman"
        discard SyncFailure.init(SyncFailureKind.StatusDownload, peer)
        return
    except CatchableError as exc:
      debug "Unexpected exception while updating peer's status",
            peer = peer, peer_score = peer.getScore(),
            peer_head_slot = peerSlot, peer_speed = peer.netKbps(),
            index = index, errMsg = exc.msg, topics = "syncman"
      return

    let newPeerSlot = peer.getHeadSlot()
    if peerSlot >= newPeerSlot:
      peer.updateScore(PeerScoreStaleStatus)
      debug "Peer's status information is stale",
            wall_clock_slot = wallSlot, remote_old_head_slot = peerSlot,
            local_head_slot = headSlot, remote_new_head_slot = newPeerSlot,
            peer = peer, peer_score = peer.getScore(), index = index,
            peer_speed = peer.netKbps(), topics = "syncman"
    else:
      debug "Peer's status information updated", wall_clock_slot = wallSlot,
            remote_old_head_slot = peerSlot, local_head_slot = headSlot,
            remote_new_head_slot = newPeerSlot, peer = peer,
            peer_score = peer.getScore(), peer_speed = peer.netKbps(),
            index = index, topics = "syncman"
      peer.updateScore(PeerScoreGoodStatus)
      peerSlot = newPeerSlot

  if headAge <= man.maxHeadAge:
    info "We are in sync with network", wall_clock_slot = wallSlot,
          remote_head_slot = peerSlot, local_head_slot = headSlot,
          peer = peer, peer_score = peer.getScore(), index = index,
          peer_speed = peer.netKbps(), topics = "syncman"
    # We clear SyncManager's `notInSyncEvent` so all the workers will become
    # sleeping soon.
    man.notInSyncEvent.clear()
    return

  if headSlot >= peerSlot - man.maxHeadAge:
    debug "We are in sync with peer; refreshing peer's status information",
          wall_clock_slot = wallSlot, remote_head_slot = peerSlot,
          local_head_slot = headSlot, peer = peer, peer_score = peer.getScore(),
          index = index, peer_speed = peer.netKbps(), topics = "syncman"

    man.workers[index].status = SyncWorkerStatus.UpdatingStatus

    if peerStatusAge <= StatusUpdateInterval:
      await sleepAsync(StatusUpdateInterval - peerStatusAge)

    try:
      let res = await peer.updateStatus()
      if not(res):
        peer.updateScore(PeerScoreNoStatus)
        debug "Failed to get remote peer's status, exiting", peer = peer,
              peer_score = peer.getScore(), peer_head_slot = peerSlot,
              peer_speed = peer.netKbps(), index = index, topics = "syncman"
        discard SyncFailure.init(SyncFailureKind.StatusDownload, peer)
        return
    except CatchableError as exc:
      debug "Unexpected exception while updating peer's status",
            peer = peer, peer_score = peer.getScore(),
            peer_head_slot = peerSlot, peer_speed = peer.netKbps(),
            index = index, errMsg = exc.msg, topics = "syncman"
      return

    let newPeerSlot = peer.getHeadSlot()
    if peerSlot >= newPeerSlot:
      peer.updateScore(PeerScoreStaleStatus)
      debug "Peer's status information is stale",
            wall_clock_slot = wallSlot, remote_old_head_slot = peerSlot,
            local_head_slot = headSlot, remote_new_head_slot = newPeerSlot,
            peer = peer, peer_score = peer.getScore(), index = index,
            peer_speed = peer.netKbps(), topics = "syncman"
    else:
      # This is not very good solution because we should not discriminate and/or
      # penalize peers which are in sync process too, but their latest head is
      # lower then our latest head. We should keep connections with such peers
      # (so this peers are able to get in sync using our data), but we should
      # not use this peers for syncing because this peers are useless for us.
      # Right now we decreasing peer's score a bit, so it will not be
      # disconnected due to low peer's score, but new fresh peers could replace
      # peers with low latest head.
      if headSlot >= newPeerSlot - man.maxHeadAge:
        # Peer's head slot is still lower then ours.
        debug "Peer's head slot is lower then local head slot",
              wall_clock_slot = wallSlot, remote_old_head_slot = peerSlot,
              local_head_slot = headSlot, remote_new_head_slot = newPeerSlot,
              peer = peer, peer_score = peer.getScore(),
              peer_speed = peer.netKbps(), index = index, topics = "syncman"
        peer.updateScore(PeerScoreUseless)
      else:
        debug "Peer's status information updated", wall_clock_slot = wallSlot,
              remote_old_head_slot = peerSlot, local_head_slot = headSlot,
              remote_new_head_slot = newPeerSlot, peer = peer,
              peer_score = peer.getScore(), peer_speed = peer.netKbps(),
              index = index, topics = "syncman"
        peer.updateScore(PeerScoreGoodStatus)
        peerSlot = newPeerSlot

    return

  man.workers[index].status = SyncWorkerStatus.Requesting
  let req = man.queue.pop(peerSlot, peer)
  if req.isEmpty():
    # SyncQueue could return empty request in 2 cases:
    # 1. There no more slots in SyncQueue to download (we are synced, but
    #    our ``notInSyncEvent`` is not yet cleared).
    # 2. Current peer's known head slot is too low to satisfy request.
    #
    # To avoid endless loop we going to wait for RESP_TIMEOUT time here.
    # This time is enough for all pending requests to finish and it is also
    # enough for main sync loop to clear ``notInSyncEvent``.
    debug "Empty request received from queue, exiting", peer = peer,
          local_head_slot = headSlot, remote_head_slot = peerSlot,
          queue_input_slot = man.queue.inpSlot,
          queue_output_slot = man.queue.outSlot,
          queue_last_slot = man.queue.lastSlot,
          peer_speed = peer.netKbps(), peer_score = peer.getScore(),
          index = index, topics = "syncman"
    await sleepAsync(RESP_TIMEOUT)
    return

  debug "Creating new request for peer", wall_clock_slot = wallSlot,
        remote_head_slot = peerSlot, local_head_slot = headSlot,
        request_slot = req.slot, request_count = req.count,
        request_step = req.step, peer = peer, peer_speed = peer.netKbps(),
        peer_score = peer.getScore(), index = index, topics = "syncman"

  man.workers[index].status = SyncWorkerStatus.Downloading

  try:
    let blocks = await man.getBlocks(peer, req)
    if blocks.isOk:
      let data = blocks.get()
      let smap = getShortMap(req, data)
      debug "Received blocks on request", blocks_count = len(data),
            blocks_map = smap, request_slot = req.slot,
            request_count = req.count, request_step = req.step,
            peer = peer, peer_score = peer.getScore(),
            peer_speed = peer.netKbps(), index = index, topics = "syncman"

      if not(checkResponse(req, data)):
        peer.updateScore(PeerScoreBadResponse)
        warn "Received blocks sequence is not in requested range",
             blocks_count = len(data), blocks_map = smap,
             request_slot = req.slot, request_count = req.count,
             request_step = req.step, peer = peer,
             peer_score = peer.getScore(), peer_speed = peer.netKbps(),
             index = index, topics = "syncman"
        discard SyncFailure.init(SyncFailureKind.BadResponse, peer)
        return

      # Scoring will happen in `syncUpdate`.
      man.workers[index].status = SyncWorkerStatus.Processing
      await man.queue.push(req, data)
    else:
      peer.updateScore(PeerScoreNoBlocks)
      man.queue.push(req)
      debug "Failed to receive blocks on request",
            request_slot = req.slot, request_count = req.count,
            request_step = req.step, peer = peer, index = index,
            peer_score = peer.getScore(), peer_speed = peer.netKbps(),
            topics = "syncman"
      discard SyncFailure.init(SyncFailureKind.BlockDownload, peer)
      return

  except CatchableError as exc:
    debug "Unexpected exception while receiving blocks",
            request_slot = req.slot, request_count = req.count,
            request_step = req.step, peer = peer, index = index,
            peer_score = peer.getScore(), peer_speed = peer.netKbps(),
            errMsg = exc.msg, topics = "syncman"
    return

proc syncWorker[A, B](man: SyncManager[A, B], index: int) {.async.} =
  mixin getKey, getScore, getHeadSlot

  debug "Starting syncing worker", index = index, topics = "syncman"

  while true:
    man.workers[index].status = SyncWorkerStatus.Sleeping
    # This event is going to be set until we are not in sync with network
    await man.notInSyncEvent.wait()
    man.workers[index].status = SyncWorkerStatus.WaitingPeer
    let peer = await man.pool.acquire()
    await man.syncStep(index, peer)
    man.pool.release(peer)

proc getWorkersStats[A, B](man: SyncManager[A, B]): tuple[map: string,
                                                          sleeping: int,
                                                          waiting: int,
                                                          pending: int] =
  var map = newString(len(man.workers))
  var sleeping, waiting, pending: int
  for i in 0 ..< len(man.workers):
    var ch: char
    case man.workers[i].status
      of SyncWorkerStatus.Sleeping:
        ch = 's'
        inc(sleeping)
      of SyncWorkerStatus.WaitingPeer:
        ch = 'w'
        inc(waiting)
      of SyncWorkerStatus.UpdatingStatus:
        ch = 'U'
        inc(pending)
      of SyncWorkerStatus.Requesting:
        ch = 'R'
        inc(pending)
      of SyncWorkerStatus.Downloading:
        ch = 'D'
        inc(pending)
      of SyncWorkerStatus.Processing:
        ch = 'P'
        inc(pending)
    map[i] = ch
  (map, sleeping, waiting, pending)

proc guardTask[A, B](man: SyncManager[A, B]) {.async.} =
  var pending: array[SyncWorkersCount, Future[void]]

  # Starting all the synchronization workers.
  for i in 0 ..< len(man.workers):
    let future = syncWorker[A, B](man, i)
    man.workers[i].future = future
    pending[i] = future

  # Wait for synchronization worker's failure and replace it with new one.
  while true:
    let failFuture = await one(pending)
    let index = pending.find(failFuture)
    if failFuture.failed():
      warn "Synchronization worker stopped working unexpectedly with an error",
            index = index, errMsg = failFuture.error.msg
    else:
      warn "Synchronization worker stopped working unexpectedly without error",
            index = index

    let future = syncWorker[A, B](man, index)
    man.workers[index].future = future
    pending[index] = future

proc toTimeLeftString(d: Duration): string =
  var v = d
  var res = ""
  let ndays = chronos.days(v)
  if ndays > 0:
    res = res & (if ndays < 10: "0" & $ndays else: $ndays) & "d"
    v = v - chronos.days(ndays)

  let nhours = chronos.hours(v)
  if nhours > 0:
    res = res & (if nhours < 10: "0" & $nhours else: $nhours) & "h"
    v = v - chronos.hours(nhours)
  else:
    res =  res & "00h"

  let nmins = chronos.minutes(v)
  if nmins > 0:
    res = res & (if nmins < 10: "0" & $nmins else: $nmins) & "m"
    v = v - chronos.minutes(nmins)
  else:
    res = res & "00m"
  res

proc syncLoop[A, B](man: SyncManager[A, B]) {.async.} =
  mixin getKey, getScore
  var pauseTime = 0

  asyncSpawn man.guardTask()

  debug "Synchronization loop started", topics = "syncman"

  proc averageSpeedTask() {.async.} =
    while true:
      let wallSlot = man.getLocalWallSlot()
      let headSlot = man.getLocalHeadSlot()
      let lsm1 = SyncMoment.now(man.getLocalHeadSlot())
      await sleepAsync(chronos.seconds(int(SECONDS_PER_SLOT)))
      let lsm2 = SyncMoment.now(man.getLocalHeadSlot())
      let bps =
        if lsm2.slot - lsm1.slot == 0'u64:
          0.0
        else:
          speed(lsm1, lsm2)
      inc(man.syncCount)
      man.insSyncSpeed = bps
      man.avgSyncSpeed = man.avgSyncSpeed +
                         (bps - man.avgSyncSpeed) / float(man.syncCount)
      let nsec = (float(wallSlot - headSlot) / man.avgSyncSpeed) *
                 1_000_000_000.0
      man.timeLeft = chronos.nanoseconds(int64(nsec))

  asyncSpawn averageSpeedTask()

  while true:
    let wallSlot = man.getLocalWallSlot()
    let headSlot = man.getLocalHeadSlot()

    let (map, sleeping, waiting, pending) = man.getWorkersStats()

    debug "Current syncing state", workers_map = map,
          sleeping_workers_count = sleeping,
          waiting_workers_count = waiting,
          pending_workers_count = pending,
          wall_head_slot = wallSlot, local_head_slot = headSlot,
          pause_time = $chronos.seconds(pauseTime),
          avg_sync_speed = man.avgSyncSpeed, ins_sync_speed = man.insSyncSpeed,
          topics = "syncman"

    # Update status string
    man.syncStatus = map & ":" & $pending & ":" &
                     man.insSyncSpeed.formatBiggestFloat(ffDecimal, 4) & ":" &
                     man.avgSyncSpeed.formatBiggestFloat(ffDecimal, 4) & ":" &
                     man.timeLeft.toTimeLeftString() &
                     " (" & $man.queue.outSlot & ")"

    if headAge <= man.maxHeadAge:
      man.notInSyncEvent.clear()
      # We are marking SyncManager as not working only when we are in sync and
      # all sync workers are in `Sleeping` state.
      if pending > 0:
        debug "Synchronization loop waits for workers completion",
              wall_head_slot = wallSlot, local_head_slot = headSlot,
              difference = (wallSlot - headSlot), max_head_age = man.maxHeadAge,
              sleeping_workers_count = sleeping,
              waiting_workers_count = waiting, pending_workers_count = pending,
              topics = "syncman"
        man.inProgress = true
      else:
        debug "Synchronization loop sleeping", wall_head_slot = wallSlot,
              local_head_slot = headSlot, difference = (wallSlot - headSlot),
              max_head_age = man.maxHeadAge, topics = "syncman"
        man.inProgress = false
    else:
      if not(man.notInSyncEvent.isSet()):
        # We get here only if we lost sync for more then `maxHeadAge` period.
        if pending == 0:
          man.queue = SyncQueue.init(A, man.getLocalHeadSlot(),
                                     man.getLocalWallSlot(),
                                     man.chunkSize, man.getFinalizedSlot,
                                     man.blockProcessor, 1)
          man.notInSyncEvent.fire()
          man.inProgress = true
      else:
        man.notInSyncEvent.fire()
        man.inProgress = true

    if queueAge <= man.rangeAge:
      # We are in requested range ``man.rangeAge``.
      man.inRangeEvent.fire()
      man.notInRangeEvent.clear()
    else:
      # We are not in requested range anymore ``man.rangeAge``.
      man.inRangeEvent.clear()
      man.notInRangeEvent.fire()

    await sleepAsync(chronos.seconds(2))

proc start*[A, B](man: SyncManager[A, B]) =
  ## Starts SyncManager's main loop.
  man.syncFut = man.syncLoop()

proc getInfo*[A, B](man: SyncManager[A, B]): SyncInfo =
  ## Returns current synchronization information for RPC call.
  let wallSlot = man.getLocalWallSlot()
  let headSlot = man.getLocalHeadSlot()
  let sync_distance = wallSlot - headSlot
  (
    head_slot: headSlot,
    sync_distance: sync_distance,
    is_syncing: man.inProgress
  )
