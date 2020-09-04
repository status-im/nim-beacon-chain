import chronicles
import options, deques, heapqueue, tables, strutils, sequtils, math, algorithm
import stew/results, chronos, chronicles
import spec/[datatypes, digest], peer_pool, eth2_network
import eth/async_utils

import ./eth2_processor
import block_pools/block_pools_types
export datatypes, digest, chronos, chronicles, results, block_pools_types

logScope:
  topics = "syncman"

const
  PeerScoreNoStatus* = -100
    ## Peer did not answer `status` request.
  PeerScoreStaleStatus* = -50
    ## Peer's `status` answer do not progress in time.
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

  SyncWorkersCount* = 20
    ## Number of sync workers to spawn

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
    data*: seq[SignedBeaconBlock]

  SyncWaiter*[T] = object
    future: Future[bool]
    request: SyncRequest[T]

  SyncQueue*[T] = ref object
    inpSlot*: Slot
    outSlot*: Slot
    startSlot*: Slot
    lastSlot: Slot
    chunkSize*: uint64
    queueSize*: int
    counter*: uint64
    pending*: Table[uint64, SyncRequest[T]]
    waiters: seq[SyncWaiter[T]]
    getFinalizedSlot*: GetSlotCallback
    debtsQueue: HeapQueue[SyncRequest[T]]
    debtsCount: uint64
    readyQueue: HeapQueue[SyncResult[T]]
    suspects: seq[SyncResult[T]]
    outQueue: AsyncQueue[BlockEntry]

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
    maxRecurringFailures: int
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
    failures: seq[SyncFailure[A]]
    syncFut: Future[void]
    outQueue: AsyncQueue[BlockEntry]
    inProgress*: bool
    syncSpeed*: float
    syncStatus*: string

  SyncMoment* = object
    stamp*: chronos.Moment
    slot*: Slot

  SyncFailure*[T] = object
    kind*: SyncFailureKind
    peer*: T
    stamp*: chronos.Moment

  SyncManagerError* = object of CatchableError
  BeaconBlocksRes* = NetRes[seq[SignedBeaconBlock]]

proc validate*[T](sq: SyncQueue[T],
           blk: SignedBeaconBlock): Future[Result[void, BlockError]] {.async.} =
  let sblock = SyncBlock(
    blk: blk,
    resfut: newFuture[Result[void, BlockError]]("sync.manager.validate")
  )
  await sq.outQueue.addLast(BlockEntry(v: sblock))
  return await sblock.resfut

proc getShortMap*[T](req: SyncRequest[T],
                     data: openarray[SignedBeaconBlock]): string =
  ## Returns all slot numbers in ``data`` as placement map.
  var res = newStringOfCap(req.count)
  var slider = req.slot
  var last = 0
  for i in 0 ..< req.count:
    if last < len(data):
      for k in last ..< len(data):
        if slider == data[k].message.slot:
          res.add('x')
          last = k + 1
          break
        elif slider < data[k].message.slot:
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
                       data: openarray[SignedBeaconBlock]): bool =
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
    if slot < data[dindex].message.slot:
      discard
    elif slot == data[dindex].message.slot:
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
                    data: openarray[SignedBeaconBlock]): string =
  # Returns all slot numbers in ``data`` as comma-delimeted string.
  result = mapIt(data, $it.message.slot).join(", ")

proc init*[T](t1: typedesc[SyncRequest], t2: typedesc[T], slot: Slot,
              count: uint64): SyncRequest[T] {.inline.} =
  result = SyncRequest[T](slot: slot, count: count, step: 1'u64)

proc init*[T](t1: typedesc[SyncRequest], t2: typedesc[T], start: Slot,
              finish: Slot): SyncRequest[T] {.inline.} =
  let count = finish - start + 1'u64
  result = SyncRequest[T](slot: start, count: count, step: 1'u64)

proc init*[T](t1: typedesc[SyncRequest], t2: typedesc[T], slot: Slot,
              count: uint64, item: T): SyncRequest[T] {.inline.} =
  result = SyncRequest[T](slot: slot, count: count, item: item, step: 1'u64)

proc init*[T](t1: typedesc[SyncRequest], t2: typedesc[T], start: Slot,
              finish: Slot, item: T): SyncRequest[T] {.inline.} =
  let count = finish - start + 1'u64
  result = SyncRequest[T](slot: start, count: count, step: 1'u64, item: item)

proc init*[T](t1: typedesc[SyncFailure], kind: SyncFailureKind,
              peer: T): SyncFailure[T] {.inline.} =
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
              outputQueue: AsyncQueue[BlockEntry],
              queueSize: int = -1): SyncQueue[T] =
  ## Create new synchronization queue with parameters
  ##
  ## ``start`` and ``last`` are starting and finishing Slots.
  ##
  ## ``chunkSize`` maximum number of slots in one request.
  ##
  ## ``queueSize`` maximum queue size for incoming data. If ``queueSize > 0``
  ## queue will help to keep backpressure under control. If ``queueSize <= 0``
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
    queueSize: queueSize,
    getFinalizedSlot: getFinalizedSlotCb,
    waiters: newSeq[SyncWaiter[T]](),
    counter: 1'u64,
    pending: initTable[uint64, SyncRequest[T]](),
    debtsQueue: initHeapQueue[SyncRequest[T]](),
    inpSlot: start,
    outSlot: start,
    outQueue: outputQueue
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

proc wakeupWaiters[T](sq: SyncQueue[T], flag = true) {.inline.} =
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
  if sr.data[^1].message.slot != lastslot:
    return true
  return false

proc getLastNonEmptySlot*[T](sr: SyncResult[T]): Slot {.inline.} =
  ## Returns last non-empty slot from result ``sr``. If response has only
  ## empty slots, original request slot will be returned.
  if len(sr.data) == 0:
    # If response has only empty slots we going to use original request slot
    sr.request.slot
  else:
    sr.data[^1].message.slot

proc toDebtsQueue[T](sq: SyncQueue[T], sr: SyncRequest[T]) {.inline.} =
  sq.debtsQueue.push(sr)
  sq.debtsCount = sq.debtsCount + sr.count

proc push*[T](sq: SyncQueue[T], sr: SyncRequest[T],
              data: seq[SignedBeaconBlock]) {.async, gcsafe.} =
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
    if len(item.data) > 0:
      for blk in item.data:
        trace "Pushing block", block_root = blk.root,
                               block_slot = blk.message.slot
        res = await sq.validate(blk)
        if not(res.isOk):
          break
    else:
      res = Result[void, BlockError].ok()

    if res.isOk:
      sq.outSlot = sq.outSlot + item.request.count
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
          warn "Unexpected missing parent, rewind happens",
               peer = req.item, rewind_to_slot = finalizedSlot,
               request_slot = req.slot, request_count = req.count,
               request_step = req.step, blocks_count = len(item.data),
               blocks_map = getShortMap(req, item.data), topics = "syncman"
          resetSlot = some(finalizedSlot)
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
                                             queue_input_slot = sq.inpSlot,
                                             queue_output_slot = sq.outSlot,
                                             topics = "syncman"
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
                           outputQueue: AsyncQueue[BlockEntry],
                           maxStatusAge = uint64(SLOTS_PER_EPOCH * 4),
                           maxHeadAge = uint64(SLOTS_PER_EPOCH * 1),
                           sleepTime = (int(SLOTS_PER_EPOCH) *
                                        int(SECONDS_PER_SLOT)).seconds,
                           chunkSize = uint64(SLOTS_PER_EPOCH),
                           toleranceValue = uint64(1),
                           maxRecurringFailures = 3,
                           rangeAge = uint64(SLOTS_PER_EPOCH * 4)
                           ): SyncManager[A, B] =

  let queue = SyncQueue.init(A, getLocalHeadSlotCb(), getLocalWallSlotCb(),
                             chunkSize, getFinalizedSlotCb, outputQueue, 1)

  result = SyncManager[A, B](
    pool: pool,
    maxStatusAge: maxStatusAge,
    getLocalHeadSlot: getLocalHeadSlotCb,
    getLocalWallSlot: getLocalWallSlotCb,
    getFinalizedSlot: getFinalizedSlotCb,
    maxHeadAge: maxHeadAge,
    maxRecurringFailures: maxRecurringFailures,
    sleepTime: sleepTime,
    chunkSize: chunkSize,
    queue: queue,
    outQueue: outputQueue,
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
    result = res

template headAge(): uint64 =
  wallSlot - headSlot

template peerAge(): uint64 =
  if peerSlot > wallSlot: 0'u64 else: wallSlot - peerSlot

template queueAge(): uint64 =
  wallSlot - man.queue.outSlot

template checkPeerScore(peer, body: untyped): untyped =
  mixin getScore
  let currentScore = peer.getScore()
  body
  let newScore = peer.getScore()
  if currentScore > newScore:
    debug "Overdue penalty for peer's score received, exiting", peer = peer,
          penalty = newScore - currentScore, peer_score = newScore,
          topics = "syncman"
    break

func syncQueueLen*[A, B](man: SyncManager[A, B]): uint64 =
  man.queue.len

proc syncWorker[A, B](man: SyncManager[A, B], index: int) {.async.} =
  mixin getKey, getScore, getHeadSlot

  debug "Starting syncing worker", index = index, topics = "syncman"

  while true:
    man.workers[index].status = SyncWorkerStatus.Sleeping
    # This event is going to be set until we are not in sync with network
    await man.notInSyncEvent.wait()

    man.workers[index].status = SyncWorkerStatus.WaitingPeer
    let peer = await man.pool.acquire()

    try:
      let wallSlot = man.getLocalWallSlot()
      let headSlot = man.getLocalHeadSlot()
      var peerSlot = peer.getHeadSlot()

      # We updating SyncQueue's last slot all the time
      man.queue.updateLastSlot(wallSlot)

      debug "Peer's syncing status", wall_clock_slot = wallSlot,
            remote_head_slot = peerSlot, local_head_slot = headSlot,
            peer_score = peer.getScore(), peer = peer,
            peer_speed = peer.netKbps(), topics = "syncman"

      # Check if peer's head slot is bigger than our wall clock slot.
      if peerSlot > wallSlot + man.toleranceValue:
        # Our wall timer is broken, or peer's status information is invalid.
        warn "Local timer is broken or peer's status information is invalid",
              wall_clock_slot = wallSlot, remote_head_slot = peerSlot,
              local_head_slot = headSlot, peer = peer,
              tolerance_value = man.toleranceValue, peer_speed = peer.netKbps(),
              peer_score = peer.getScore(), topics = "syncman"
        let failure = SyncFailure.init(SyncFailureKind.StatusInvalid, peer)
        man.failures.add(failure)
        continue

      # Check if we need to update peer's status information
      if peerAge >= man.maxStatusAge:
        # Peer's status information is very old, its time to update it
        man.workers[index].status = SyncWorkerStatus.UpdatingStatus
        debug "Updating peer's status information", wall_clock_slot = wallSlot,
              remote_head_slot = peerSlot, local_head_slot = headSlot,
              peer = peer, peer_score = peer.getScore(),
              peer_speed = peer.netKbps(), topics = "syncman"

        let res = await peer.updateStatus()

        if not(res):
          peer.updateScore(PeerScoreNoStatus)
          debug "Failed to get remote peer's status, exiting", peer = peer,
                peer_score = peer.getScore(), peer_head_slot = peerSlot,
                peer_speed = peer.netKbps(), topics = "syncman"
          let failure = SyncFailure.init(SyncFailureKind.StatusDownload, peer)
          man.failures.add(failure)
          continue

        let newPeerSlot = peer.getHeadSlot()
        if peerSlot >= newPeerSlot:
          peer.updateScore(PeerScoreStaleStatus)
          debug "Peer's status information is stale",
                wall_clock_slot = wallSlot, remote_old_head_slot = peerSlot,
                local_head_slot = headSlot, remote_new_head_slot = newPeerSlot,
                peer = peer, peer_score = peer.getScore(),
                peer_speed = peer.netKbps(), topics = "syncman"
        else:
          debug "Peer's status information updated", wall_clock_slot = wallSlot,
                remote_old_head_slot = peerSlot, local_head_slot = headSlot,
                remote_new_head_slot = newPeerSlot, peer = peer,
                peer_score = peer.getScore(), peer_speed = peer.netKbps(),
                topics = "syncman"
          peer.updateScore(PeerScoreGoodStatus)
          peerSlot = newPeerSlot

      if (peerAge <= man.maxHeadAge) and (headAge <= man.maxHeadAge):
        debug "We are in sync with peer, exiting", wall_clock_slot = wallSlot,
              remote_head_slot = peerSlot, local_head_slot = headSlot,
              peer = peer, peer_score = peer.getScore(),
              peer_speed = peer.netKbps(), topics = "syncman"
        continue

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
              topics = "syncman"
        await sleepAsync(RESP_TIMEOUT)
        continue

      man.workers[index].status = SyncWorkerStatus.Downloading
      debug "Creating new request for peer", wall_clock_slot = wallSlot,
            remote_head_slot = peerSlot, local_head_slot = headSlot,
            request_slot = req.slot, request_count = req.count,
            request_step = req.step, peer = peer, peer_speed = peer.netKbps(),
            peer_score = peer.getScore(), topics = "syncman"

      let blocks = await man.getBlocks(peer, req)

      if blocks.isOk:
        let data = blocks.get()
        let smap = getShortMap(req, data)
        debug "Received blocks on request", blocks_count = len(data),
              blocks_map = smap, request_slot = req.slot,
              request_count = req.count, request_step = req.step,
              peer = peer, peer_score = peer.getScore(),
              peer_speed = peer.netKbps(), topics = "syncman"

        if not(checkResponse(req, data)):
          peer.updateScore(PeerScoreBadResponse)
          warn "Received blocks sequence is not in requested range",
               blocks_count = len(data), blocks_map = smap,
               request_slot = req.slot, request_count = req.count,
               request_step = req.step, peer = peer,
               peer_score = peer.getScore(), peer_speed = peer.netKbps(),
               topics = "syncman"
          let failure = SyncFailure.init(SyncFailureKind.BadResponse, peer)
          man.failures.add(failure)
          continue

        # Scoring will happen in `syncUpdate`.
        man.workers[index].status = SyncWorkerStatus.Processing
        await man.queue.push(req, data)

        # Cleaning up failures.
        man.failures.setLen(0)
      else:
        peer.updateScore(PeerScoreNoBlocks)
        man.queue.push(req)
        debug "Failed to receive blocks on request",
              request_slot = req.slot, request_count = req.count,
              request_step = req.step, peer = peer,
              peer_score = peer.getScore(), peer_speed = peer.netKbps(),
              topics = "syncman"
        let failure = SyncFailure.init(SyncFailureKind.BlockDownload, peer)
        man.failures.add(failure)

    except CatchableError as exc:
      debug "Unexpected exception happened", topics = "syncman",
            excName = $exc.name, excMsg = exc.msg
    finally:
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

proc syncLoop[A, B](man: SyncManager[A, B]) {.async.} =
  mixin getKey, getScore

  # Starting all sync workers
  for i in 0 ..< len(man.workers):
    man.workers[i].future = syncWorker[A, B](man, i)

  debug "Synchronization loop started", topics = "syncman"

  proc watchAndSpeedTask() {.async.} =
    while true:
      let wallSlot = man.getLocalWallSlot()
      let headSlot = man.getLocalHeadSlot()
      let lsm1 = SyncMoment.now(man.getLocalHeadSlot())
      await sleepAsync(chronos.seconds(int(SECONDS_PER_SLOT)))
      let lsm2 = SyncMoment.now(man.getLocalHeadSlot())

      let (map, sleeping, waiting, pending) = man.getWorkersStats()
      if pending == 0:
        man.syncSpeed = 0.0
      else:
        if (lsm2.slot - lsm1.slot == 0'u64) and (pending > 1):
          debug "Syncing process is not progressing, reset the queue",
                pending_workers_count = pending,
                to_slot = man.queue.outSlot,
                local_head_slot = lsm1.slot, topics = "syncman"
          await man.queue.resetWait(none[Slot]())
        else:
          man.syncSpeed = speed(lsm1, lsm2)

      debug "Synchronization loop tick", wall_head_slot = wallSlot,
          local_head_slot = headSlot, queue_start_slot = man.queue.startSlot,
          queue_last_slot = man.queue.lastSlot,
          sync_speed = man.syncSpeed, pending_workers_count = pending,
          topics = "syncman"

  traceAsyncErrors watchAndSpeedTask()

  while true:
    let wallSlot = man.getLocalWallSlot()
    let headSlot = man.getLocalHeadSlot()

    let (map, sleeping, waiting, pending) = man.getWorkersStats()

    debug "Current syncing state", workers_map = map,
          sleeping_workers_count = sleeping,
          waiting_workers_count = waiting,
          pending_workers_count = pending,
          wall_head_slot = wallSlot, local_head_slot = headSlot,
          topics = "syncman"

    # Update status string
    man.syncStatus = map & ":" & $pending & ":" &
                       man.syncSpeed.formatBiggestFloat(ffDecimal, 4) &
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

    if len(man.failures) > man.maxRecurringFailures and pending > 1:
      debug "Number of recurring failures exceeds limit, reseting queue",
            pending_workers_count = pending, sleeping_workers_count = sleeping,
            waiting_workers_count = waiting, rec_failures = len(man.failures),
            topics = "syncman"
      # Cleaning up failures.
      man.failures.setLen(0)
      await man.queue.resetWait(none[Slot]())

    await sleepAsync(chronos.seconds(2))

proc start*[A, B](man: SyncManager[A, B]) =
  ## Starts SyncManager's main loop.
  man.syncFut = man.syncLoop()
