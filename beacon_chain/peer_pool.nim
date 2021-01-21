import std/[tables, heapqueue]
import chronos

export tables

type
  PeerType* = enum
    Incoming, Outgoing

  PeerFlags = enum
    Acquired, DeleteOnRelease

  EventType = enum
    NotEmptyEvent, NotFullEvent

  PeerStatus* = enum
    Success,        ## Peer was successfully added to PeerPool.
    DuplicateError, ## Peer is already present in PeerPool.
    NoSpaceError,   ## There no space for the peer in PeerPool.
    LowScoreError,  ## Peer has too low score.
    DeadPeerError   ## Peer is already dead.

  PeerItem[T] = object
    data: T
    peerType: PeerType
    flags: set[PeerFlags]
    index: int
    future: Future[void]

  PeerIndex = object
    data: int
    cmp: proc(a, b: PeerIndex): bool {.closure, gcsafe.}

  PeerScoreCheckCallback*[T] = proc(peer: T): bool {.gcsafe, raises: [Defect].}

  PeerCounterCallback* = proc() {.gcsafe, raises: [Defect].}

  PeerOnDeleteCallback*[T] = proc(peer: T) {.gcsafe.}

  PeerPool*[A, B] = ref object
    incNotEmptyEvent*: AsyncEvent
    outNotEmptyEvent*: AsyncEvent
    incNotFullEvent*: AsyncEvent
    outNotFullEvent*: AsyncEvent
    incQueue: HeapQueue[PeerIndex]
    outQueue: HeapQueue[PeerIndex]
    registry: Table[B, PeerIndex]
    storage: seq[PeerItem[A]]
    cmp: proc(a, b: PeerIndex): bool {.closure, gcsafe.}
    scoreCheck: PeerScoreCheckCallback[A]
    onDeletePeer: PeerOnDeleteCallback[A]
    peerCounter: PeerCounterCallback
    maxPeersCount: int
    maxIncPeersCount: int
    maxOutPeersCount: int
    curIncPeersCount: int
    curOutPeersCount: int
    acqIncPeersCount: int
    acqOutPeersCount: int

  PeerPoolError* = object of CatchableError

proc `<`*(a, b: PeerIndex): bool =
  ## PeerIndex ``a`` holds reference to ``cmp()`` procedure which has captured
  ## PeerPool instance.
  a.cmp(b, a)

proc fireNotEmptyEvent[A, B](pool: PeerPool[A, B],
                             item: PeerItem[A]) =
  case item.peerType:
  of PeerType.Incoming:
    pool.incNotEmptyEvent.fire()
  of PeerType.Outgoing:
    pool.outNotEmptyEvent.fire()

proc fireNotFullEvent[A, B](pool: PeerPool[A, B],
                            item: PeerItem[A]) =
  case item.peerType:
  of PeerType.Incoming:
    pool.incNotFullEvent.fire()
  of PeerType.Outgoing:
    pool.outNotFullEvent.fire()

iterator pairs*[A, B](pool: PeerPool[A, B]): (B, A) =
  for peerId, peerIdx in pool.registry:
    yield (peerId, pool.storage[peerIdx.data].data)

template incomingEvent(eventType: EventType): AsyncEvent =
  case eventType
  of EventType.NotEmptyEvent:
    pool.incNotEmptyEvent
  of EventType.NotFullEvent:
    pool.incNotFullEvent

template outgoingEvent(eventType: EventType): AsyncEvent =
  case eventType
  of EventType.NotEmptyEvent:
    pool.outNotEmptyEvent
  of EventType.NotFullEvent:
    pool.outNotFullEvent

proc waitForEvent[A, B](pool: PeerPool[A, B], eventType: EventType,
                        filter: set[PeerType]) {.async.} =
  if filter == {PeerType.Incoming, PeerType.Outgoing} or filter == {}:
    var fut1 = incomingEvent(eventType).wait()
    var fut2 = outgoingEvent(eventType).wait()
    try:
      discard await one(fut1, fut2)
      if fut1.finished:
        if not(fut2.finished):
          fut2.cancel()
        incomingEvent(eventType).clear()
      else:
        if not(fut1.finished):
          fut1.cancel()
        outgoingEvent(eventType).clear()
    except CancelledError as exc:
      if not(fut1.finished):
        fut1.cancel()
      if not(fut2.finished):
        fut2.cancel()
      raise exc
  elif PeerType.Incoming in filter:
    await incomingEvent(eventType).wait()
    incomingEvent(eventType).clear()
  elif PeerType.Outgoing in filter:
    await outgoingEvent(eventType).wait()
    outgoingEvent(eventType).clear()

proc waitNotEmptyEvent[A, B](pool: PeerPool[A, B],
                             filter: set[PeerType]): Future[void] =
  pool.waitForEvent(EventType.NotEmptyEvent, filter)

proc waitNotFullEvent[A, B](pool: PeerPool[A, B],
                            filter: set[PeerType]): Future[void] =
  pool.waitForEvent(EventType.NotFullEvent, filter)

proc newPeerPool*[A, B](maxPeers = -1, maxIncomingPeers = -1,
                        maxOutgoingPeers = -1,
                        scoreCheckCb: PeerScoreCheckCallback[A] = nil,
                        peerCounterCb: PeerCounterCallback = nil,
                    onDeleteCb: PeerOnDeleteCallback[A] = nil): PeerPool[A, B] =
  ## Create new PeerPool.
  ##
  ## ``maxPeers`` - maximum number of peers allowed. All the peers which
  ## exceeds this number will be rejected (``addPeer()`` procedure will return
  ## ``false``). By default this number is infinite.
  ##
  ## ``maxIncomingPeers`` - maximum number of incoming peers allowed. All the
  ## incoming peers exceeds this number will be rejected. By default this
  ## number is infinite.
  ##
  ## ``maxOutgoingPeers`` - maximum number of outgoing peers allowed. All the
  ## outgoing peers exceeds this number will be rejected. By default this
  ## number if infinite.
  ##
  ## ``scoreCheckCb`` - callback which will be called for all released peers.
  ## If callback procedure returns ``false`` peer will be removed from
  ## PeerPool.
  ##
  ## ``peerCountCb`` - callback to be called when number of peers in PeerPool
  ## has been changed.
  ##
  ## ``onDeleteCb`` - callback to be called when peer is leaving PeerPool.
  ##
  ## Please note, that if ``maxPeers`` is positive non-zero value, then equation
  ## ``maxPeers >= maxIncomingPeers + maxOutgoingPeers`` must be ``true``.
  var res = PeerPool[A, B]()
  if maxPeers != -1:
    doAssert(maxPeers >= maxIncomingPeers + maxOutgoingPeers)

  res.maxPeersCount = if maxPeers < 0: high(int) else: maxPeers
  res.maxIncPeersCount =
    if maxIncomingPeers < 0:
      high(int)
    else:
      maxIncomingPeers
  res.maxOutPeersCount =
    if maxOutgoingPeers < 0:
      high(int)
    else:
      maxOutgoingPeers

  res.incNotEmptyEvent = newAsyncEvent()
  res.outNotEmptyEvent = newAsyncEvent()
  res.incNotFullEvent = newAsyncEvent()
  res.outNotFullEvent = newAsyncEvent()
  res.incQueue = initHeapQueue[PeerIndex]()
  res.outQueue = initHeapQueue[PeerIndex]()
  res.registry = initTable[B, PeerIndex]()
  res.scoreCheck = scoreCheckCb
  res.peerCounter = peerCounterCb
  res.onDeletePeer = onDeleteCb
  res.storage = newSeq[PeerItem[A]]()

  proc peerCmp(a, b: PeerIndex): bool {.closure, gcsafe.} =
    let p1 = res.storage[a.data].data
    let p2 = res.storage[b.data].data
    p1 < p2

  res.cmp = peerCmp
  res

proc len*[A, B](pool: PeerPool[A, B]): int =
  ## Returns number of registered peers in PeerPool ``pool``. This number
  ## includes all the peers (acquired and available).
  len(pool.registry)

proc lenCurrent*[A, B](pool: PeerPool[A, B],
                       filter = {PeerType.Incoming,
                                 PeerType.Outgoing}): int {.inline.} =
  ## Returns number of registered peers in PeerPool ``pool`` which satisfies
  ## filter ``filter``.
  (if PeerType.Incoming in filter: pool.curIncPeersCount else: 0) +
  (if PeerType.Outgoing in filter: pool.curOutPeersCount else: 0)

proc lenAvailable*[A, B](pool: PeerPool[A, B],
                         filter = {PeerType.Incoming,
                                   PeerType.Outgoing}): int {.inline.} =
  ## Returns number of available peers in PeerPool ``pool`` which satisfies
  ## filter ``filter``.
  (if PeerType.Incoming in filter: len(pool.incQueue) else: 0) +
  (if PeerType.Outgoing in filter: len(pool.outQueue) else: 0)

proc lenAcquired*[A, B](pool: PeerPool[A, B],
                        filter = {PeerType.Incoming,
                                  PeerType.Outgoing}): int {.inline.} =
  ## Returns number of acquired peers in PeerPool ``pool`` which satisifies
  ## filter ``filter``.
  (if PeerType.Incoming in filter: pool.acqIncPeersCount else: 0) +
  (if PeerType.Outgoing in filter: pool.acqOutPeersCount else: 0)

proc lenSpace*[A, B](pool: PeerPool[A, B],
                     filter = {PeerType.Incoming,
                               PeerType.Outgoing}): int {.inline.} =
  ## Returns number of available space for peers in PeerPool ``pool`` which
  ## satisfies filter ``filter``.
  let curPeersCount = pool.curIncPeersCount + pool.curOutPeersCount
  let totalSpace = pool.maxPeersCount - curPeersCount
  let incoming = min(totalSpace, pool.maxIncPeersCount - pool.curIncPeersCount)
  let outgoing = min(totalSpace, pool.maxOutPeersCount - pool.curOutPeersCount)
  if filter == {PeerType.Incoming, PeerType.Outgoing}:
    # To avoid overflow check we need to check by ourself.
    if uint64(incoming) + uint64(outgoing) > uint64(high(int)):
      min(totalSpace, high(int))
    else:
      min(totalSpace, incoming + outgoing)
  elif PeerType.Incoming in filter:
    incoming
  else:
    outgoing

proc shortLogAvailable*[A, B](pool: PeerPool[A, B]): string =
  $len(pool.incQueue) & "/" & $len(pool.outQueue)

proc shortLogAcquired*[A, B](pool: PeerPool[A, B]): string =
  $pool.acqIncPeersCount & "/" & $pool.acqOutPeersCount

proc shortLogSpace*[A, B](pool: PeerPool[A, B]): string =
  $pool.lenSpace({PeerType.Incoming}) & "/" &
    $pool.lenSpace({PeerType.Outgoing})

proc shortLogCurrent*[A, B](pool: PeerPool[A, B]): string =
  $pool.curIncPeersCount & "/" & $pool.curOutPeersCount

proc checkPeerScore*[A, B](pool: PeerPool[A, B], peer: A): bool {.inline.} =
  ## Returns ``true`` if peer passing score check.
  if not(isNil(pool.scoreCheck)):
    pool.scoreCheck(peer)
  else:
    true

proc peerCountChanged[A, B](pool: PeerPool[A, B]) =
  ## Call callback when number of peers changed.
  if not(isNil(pool.peerCounter)):
    pool.peerCounter()

proc peerDeleted[A, B](pool: PeerPool[A, B], peer: A) =
  ## Call callback when peer is leaving PeerPool.
  if not(isNil(pool.onDeletePeer)):
    pool.onDeletePeer(peer)

proc deletePeer*[A, B](pool: PeerPool[A, B], peer: A, force = false): bool =
  ## Remove ``peer`` from PeerPool ``pool``.
  ##
  ## Deletion occurs immediately only if peer is available, otherwise it will
  ## be deleted only when peer will be released. You can change this behavior
  ## with ``force`` option.
  mixin getKey
  let key = getKey(peer)
  if pool.registry.hasKey(key):
    let pindex = pool.registry[key].data
    var item = addr(pool.storage[pindex])
    if (PeerFlags.Acquired in item[].flags):
      if not(force):
        item[].flags.incl(PeerFlags.DeleteOnRelease)
      else:
        if item[].peerType == PeerType.Incoming:
          dec(pool.curIncPeersCount)
          dec(pool.acqIncPeersCount)
        elif item[].peerType == PeerType.Outgoing:
          dec(pool.curOutPeersCount)
          dec(pool.acqOutPeersCount)

        let fut = item[].future
        # Indicate that we have an empty space
        pool.fireNotFullEvent(item[])
        # Cleanup storage with default item, and removing key from hashtable.
        pool.storage[pindex] = PeerItem[A]()
        pool.registry.del(key)
        pool.peerDeleted(peer)
        pool.peerCountChanged()
        # Indicate that peer was deleted
        fut.complete()
    else:
      if item[].peerType == PeerType.Incoming:
        # If peer is available, then its copy present in heapqueue, so we need
        # to remove it.
        for i in 0 ..< len(pool.incQueue):
          if pool.incQueue[i].data == pindex:
            pool.incQueue.del(i)
            break
        dec(pool.curIncPeersCount)
      elif item[].peerType == PeerType.Outgoing:
        # If peer is available, then its copy present in heapqueue, so we need
        # to remove it.
        for i in 0 ..< len(pool.outQueue):
          if pool.outQueue[i].data == pindex:
            pool.outQueue.del(i)
            break
        dec(pool.curOutPeersCount)

      let fut = item[].future
      # Indicate that we have an empty space
      pool.fireNotFullEvent(item[])
      # Cleanup storage with default item, and removing key from hashtable.
      pool.storage[pindex] = PeerItem[A]()
      pool.registry.del(key)
      pool.peerDeleted(peer)
      pool.peerCountChanged()
      # Indicate that peer was deleted
      fut.complete()
    true
  else:
    false

proc joinPeer*[A, B](pool: PeerPool[A, B], peer: A): Future[void] =
  ## This procedure will only when peer ``peer`` finally leaves PeerPool
  ## ``pool``.
  mixin getKey
  var retFuture = newFuture[void]("peerpool.joinPeer")
  var future: Future[void]

  proc continuation(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      retFuture.complete()

  proc cancellation(udata: pointer) {.gcsafe.} =
    if not(isNil(future)):
      future.removeCallback(continuation)

  let key = getKey(peer)
  if pool.registry.hasKey(key):
    let pindex = pool.registry[key].data
    var item = addr(pool.storage[pindex])
    future = item[].future
    # If peer is still in PeerPool, then item[].future should not be finished.
    doAssert(not(future.finished()))
    future.addCallback(continuation)
    retFuture.cancelCallback = cancellation
  else:
    # If there no such peer in PeerPool anymore, its possible that
    # PeerItem.future's callbacks is not yet processed, so we going to complete
    # retFuture only in next `poll()` call.
    callSoon(continuation, cast[pointer](retFuture))

  retFuture

proc addPeerImpl[A, B](pool: PeerPool[A, B], peer: A, peerKey: B,
                       peerType: PeerType) =
  mixin getFuture
  proc onPeerClosed(udata: pointer) {.gcsafe.} =
    discard pool.deletePeer(peer)

  let item = PeerItem[A](data: peer, peerType: peerType,
                         index: len(pool.storage),
                         future: newFuture[void]("peerpool.peer"))
  pool.storage.add(item)
  var pitem = addr(pool.storage[^1])
  let pindex = PeerIndex(data: item.index, cmp: pool.cmp)
  pool.registry[peerKey] = pindex
  pitem[].data.getFuture().addCallback(onPeerClosed)
  if peerType == PeerType.Incoming:
    inc(pool.curIncPeersCount)
    pool.incQueue.push(pindex)
    pool.incNotEmptyEvent.fire()
  elif peerType == PeerType.Outgoing:
    inc(pool.curOutPeersCount)
    pool.outQueue.push(pindex)
    pool.outNotEmptyEvent.fire()
  pool.peerCountChanged()

proc checkPeer*[A, B](pool: PeerPool[A, B], peer: A): PeerStatus {.inline.} =
  ## Checks if peer could be added to PeerPool, e.g. it has:
  ##
  ## * Positive value of peer's score - (PeerStatus.LowScoreError)
  ## * Peer's key is not present in PeerPool - (PeerStatus.DuplicateError)
  ## * Peer's lifetime future is not finished yet - (PeerStatus.DeadPeerError)
  ##
  ## If peer could be added to PeerPool procedure returns (PeerStatus.Success)
  mixin getKey, isAlive
  if not(pool.checkPeerScore(peer)):
    PeerStatus.LowScoreError
  else:
    let peerKey = getKey(peer)
    if not(pool.registry.hasKey(peerKey)):
      if peer.isAlive():
        PeerStatus.Success
      else:
        PeerStatus.DeadPeerError
    else:
      PeerStatus.DuplicateError

proc addPeerNoWait*[A, B](pool: PeerPool[A, B],
                          peer: A, peerType: PeerType): PeerStatus =
  ## Add peer ``peer`` of type ``peerType`` to PeerPool ``pool``.
  ##
  ## Procedure returns ``PeerStatus``
  ##   * if ``peer`` is already closed - (PeerStatus.DeadPeerError)
  ##   * if ``pool`` already has peer ``peer`` - (PeerStatus.DuplicateError)
  ##   * if ``pool`` currently has a maximum of peers.
  ##     (PeerStatus.NoSpaceError)
  ##   * if ``pool`` currently has a maximum of `Incoming` or `Outgoing` peers.
  ##     (PeerStatus.NoSpaceError)
  ##
  ## Procedure returns (PeerStatus.Success) on success.
  mixin getKey
  let res = pool.checkPeer(peer)
  if res != PeerStatus.Success:
    res
  else:
    let peerKey = peer.getKey()
    case peerType:
    of PeerType.Incoming:
      if pool.lenSpace({PeerType.Incoming}) > 0:
        pool.addPeerImpl(peer, peerKey, peerType)
        PeerStatus.Success
      else:
        PeerStatus.NoSpaceError
    of PeerType.Outgoing:
      if pool.lenSpace({PeerType.Outgoing}) > 0:
        pool.addPeerImpl(peer, peerKey, peerType)
        PeerStatus.Success
      else:
        PeerStatus.NoSpaceError

proc getPeerSpaceMask[A, B](pool: PeerPool[A, B],
                            peerType: PeerType): set[PeerType] {.inline.} =
  ## This procedure returns set of events which you need to wait to get empty
  ## space for peer type ``peerType``. This set can be used for call to
  ## ``waitNotFullEvent()``.
  case peerType:
  of PeerType.Incoming:
    if pool.maxIncPeersCount >= pool.maxPeersCount:
      # If maximum number of `incoming` peers is only limited by
      # maximum number of peers, then we could wait for both events.
      # It means that we do not care about what peer will left pool.
      {PeerType.Incoming, PeerType.Outgoing}
    else:
      # Otherwise we could wait only for `incoming` event
      {PeerType.Incoming}
  of PeerType.Outgoing:
    if pool.maxOutPeersCount >= pool.maxPeersCount:
      # If maximum number of `outgoing` peers is only limited by
      # maximum number of peers, then we could wait for both events.
      # It means that we do not care about what peer will left pool.
      {PeerType.Incoming, PeerType.Outgoing}
    else:
      # Otherwise we could wait only for `outgoing` event
      {PeerType.Outgoing}

proc waitForEmptySpace*[A, B](pool: PeerPool[A, B],
                              peerType: PeerType) {.async.} =
  ## This procedure will block until ``pool`` will have an empty space for peer
  ## of type ``peerType``.
  let mask = pool.getPeerSpaceMask(peerType)
  while pool.lenSpace({peerType}) == 0:
    await pool.waitNotFullEvent(mask)

proc addPeer*[A, B](pool: PeerPool[A, B],
                    peer: A, peerType: PeerType): Future[PeerStatus] {.async.} =
  ## Add peer ``peer`` of type ``peerType`` to PeerPool ``pool``.
  ##
  ## This procedure will wait for an empty space in PeerPool ``pool``, if
  ## PeerPool ``pool`` is full.
  ##
  ## Procedure returns ``PeerStatus``
  ##   * if ``peer`` is already closed - (PeerStatus.DeadPeerError)
  ##   * if ``pool`` already has peer ``peer`` - (PeerStatus.DuplicateError)
  ##
  ## Procedure returns (PeerStatus.Success) on success.
  mixin getKey
  let res =
    block:
      let res1 = pool.checkPeer(peer)
      if res1 != PeerStatus.Success:
        res1
      else:
        let mask = pool.getPeerSpaceMask(peerType)
        # We going to block here until ``pool`` will not have free space,
        # for our type of peer.
        while pool.lenSpace({peerType}) == 0:
          await pool.waitNotFullEvent(mask)
        # Because we could wait for a long time we need to check peer one more
        # time to avoid race condition.
        let res2 = pool.checkPeer(peer)
        if res2 == PeerStatus.Success:
          let peerKey = peer.getKey()
          pool.addPeerImpl(peer, peerKey, peerType)
          PeerStatus.Success
        else:
          res2
  return res

proc acquireItemImpl[A, B](pool: PeerPool[A, B],
                           filter: set[PeerType]): A {.inline.} =
  doAssert((len(pool.outQueue) > 0) or (len(pool.incQueue) > 0))
  let pindex =
    if filter == {PeerType.Incoming, PeerType.Outgoing}:
      if len(pool.outQueue) > 0 and len(pool.incQueue) > 0:
        # Don't think `<` is actually `<` here.
        if pool.incQueue[0] < pool.outQueue[0]:
          inc(pool.acqIncPeersCount)
          let item = pool.incQueue.pop()
          item.data
        else:
          inc(pool.acqOutPeersCount)
          let item = pool.outQueue.pop()
          item.data
      else:
        if len(pool.outQueue) > 0:
          inc(pool.acqOutPeersCount)
          let item = pool.outQueue.pop()
          item.data
        else:
          inc(pool.acqIncPeersCount)
          let item = pool.incQueue.pop()
          item.data
    else:
      if PeerType.Outgoing in filter:
        inc(pool.acqOutPeersCount)
        let item = pool.outQueue.pop()
        item.data
      else:
        inc(pool.acqIncPeersCount)
        let item = pool.incQueue.pop()
        item.data
  var pitem = addr(pool.storage[pindex])
  doAssert(PeerFlags.Acquired notin pitem[].flags)
  pitem[].flags.incl(PeerFlags.Acquired)
  pitem[].data

proc acquire*[A, B](pool: PeerPool[A, B],
                    filter = {PeerType.Incoming,
                              PeerType.Outgoing}): Future[A] {.async.} =
  ## Acquire peer from PeerPool ``pool``, which match the filter ``filter``.
  mixin getKey
  doAssert(filter != {}, "Filter must not be empty")
  while true:
    if pool.lenAvailable(filter) == 0:
      await pool.waitNotEmptyEvent(filter)
    else:
      return pool.acquireItemImpl(filter)

proc acquireNoWait*[A, B](pool: PeerPool[A, B],
                          filter = {PeerType.Incoming,
                                    PeerType.Outgoing}): A =
  doAssert(filter != {}, "Filter must not be empty")
  if pool.lenAvailable(filter) < 1:
    raise newException(PeerPoolError, "Not enough peers in pool")
  pool.acquireItemImpl(filter)

proc release*[A, B](pool: PeerPool[A, B], peer: A) =
  ## Release peer ``peer`` back to PeerPool ``pool``
  mixin getKey
  let key = getKey(peer)
  var titem = pool.registry.getOrDefault(key, PeerIndex(data: -1))
  if titem.data >= 0:
    let pindex = titem.data
    var item = addr(pool.storage[pindex])
    if PeerFlags.Acquired in item[].flags:
      if not(pool.checkPeerScore(peer)):
        item[].flags.incl(DeleteOnRelease)
      if PeerFlags.DeleteOnRelease in item[].flags:
        # We do not care about result here because peer is present in registry
        # and has all proper flags set.
        discard pool.deletePeer(peer, force = true)
      else:
        item[].flags.excl(PeerFlags.Acquired)
        case item[].peerType
        of PeerType.Incoming:
          pool.incQueue.push(titem)
          dec(pool.acqIncPeersCount)
        of PeerType.Outgoing:
          pool.outQueue.push(titem)
          dec(pool.acqOutPeersCount)
        pool.fireNotEmptyEvent(item[])

proc release*[A, B](pool: PeerPool[A, B], peers: openArray[A]) {.inline.} =
  ## Release array of peers ``peers`` back to PeerPool ``pool``.
  for item in peers:
    pool.release(item)

proc acquire*[A, B](pool: PeerPool[A, B],
                    number: int,
                    filter = {PeerType.Incoming,
                              PeerType.Outgoing}): Future[seq[A]] {.async.} =
  ## Acquire ``number`` number of peers from PeerPool ``pool``, which match the
  ## filter ``filter``.
  doAssert(filter != {}, "Filter must not be empty")
  var peers = newSeq[A]()
  try:
    if number > 0:
      while true:
        if len(peers) >= number:
          break
        if pool.lenAvailable(filter) == 0:
          await pool.waitNotEmptyEvent(filter)
        else:
          peers.add(pool.acquireItemImpl(filter))
  except CancelledError as exc:
    # If we got cancelled, we need to return all the acquired peers back to
    # pool.
    for item in peers:
      pool.release(item)
    peers.setLen(0)
    raise exc
  return peers

proc acquireNoWait*[A, B](pool: PeerPool[A, B],
                          number: int,
                          filter = {PeerType.Incoming,
                                    PeerType.Outgoing}): seq[A] =
  ## Acquire ``number`` number of peers from PeerPool ``pool``, which match the
  ## filter ``filter``.
  doAssert(filter != {}, "Filter must not be empty")
  var peers = newSeq[A]()
  if pool.lenAvailable(filter) < number:
    raise newException(PeerPoolError, "Not enough peers in pool")
  for i in 0 ..< number:
    peers.add(pool.acquireItemImpl(filter))
  return peers

proc acquireIncomingPeer*[A, B](pool: PeerPool[A, B]): Future[A] {.inline.} =
  ## Acquire single incoming peer from PeerPool ``pool``.
  pool.acquire({PeerType.Incoming})

proc acquireOutgoingPeer*[A, B](pool: PeerPool[A, B]): Future[A] {.inline.} =
  ## Acquire single outgoing peer from PeerPool ``pool``.
  pool.acquire({PeerType.Outgoing})

proc acquireIncomingPeers*[A, B](pool: PeerPool[A, B],
                                 number: int): Future[seq[A]] {.inline.} =
  ## Acquire ``number`` number of incoming peers from PeerPool ``pool``.
  pool.acquire(number, {PeerType.Incoming})

proc acquireOutgoingPeers*[A, B](pool: PeerPool[A, B],
                                 number: int): Future[seq[A]] {.inline.} =
  ## Acquire ``number`` number of outgoing peers from PeerPool ``pool``.
  pool.acquire(number, {PeerType.Outgoing})

iterator peers*[A, B](pool: PeerPool[A, B],
                      filter = {PeerType.Incoming,
                                PeerType.Outgoing}): A =
  ## Iterate over sorted list of peers.
  ##
  ## All peers will be sorted by equation `>`(Peer1, Peer2), so biggest values
  ## will be first.
  var sorted = initHeapQueue[PeerIndex]()
  for i in 0 ..< len(pool.storage):
    if pool.storage[i].peerType in filter:
      sorted.push(PeerIndex(data: i, cmp: pool.cmp))
  while len(sorted) > 0:
    let pindex = sorted.pop().data
    yield pool.storage[pindex].data

iterator availablePeers*[A, B](pool: PeerPool[A, B],
                               filter = {PeerType.Incoming,
                                         PeerType.Outgoing}): A =
  ## Iterate over sorted list of available peers.
  ##
  ## All peers will be sorted by equation `>`(Peer1, Peer2), so biggest values
  ## will be first.
  var sorted = initHeapQueue[PeerIndex]()
  for i in 0 ..< len(pool.storage):
    if (PeerFlags.Acquired notin pool.storage[i].flags) and
       (pool.storage[i].peerType in filter):
      sorted.push(PeerIndex(data: i, cmp: pool.cmp))
  while len(sorted) > 0:
    let pindex = sorted.pop().data
    yield pool.storage[pindex].data

iterator acquiredPeers*[A, B](pool: PeerPool[A, B],
                              filter = {PeerType.Incoming,
                                         PeerType.Outgoing}): A =
  ## Iterate over sorted list of acquired (non-available) peers.
  ##
  ## All peers will be sorted by equation `>`(Peer1, Peer2), so biggest values
  ## will be first.
  var sorted = initHeapQueue[PeerIndex]()
  for i in 0 ..< len(pool.storage):
    if (PeerFlags.Acquired in pool.storage[i].flags) and
       (pool.storage[i].peerType in filter):
      sorted.push(PeerIndex(data: i, cmp: pool.cmp))
  while len(sorted) > 0:
    let pindex = sorted.pop().data
    yield pool.storage[pindex].data

proc `[]`*[A, B](pool: PeerPool[A, B], key: B): A {.inline.} =
  ## Retrieve peer with key ``key`` from PeerPool ``pool``.
  let pindex = pool.registry[key]
  pool.storage[pindex.data]

proc `[]`*[A, B](pool: var PeerPool[A, B], key: B): var A {.inline.} =
  ## Retrieve peer with key ``key`` from PeerPool ``pool``.
  let pindex = pool.registry[key]
  pool.storage[pindex.data].data

proc hasPeer*[A, B](pool: PeerPool[A, B], key: B): bool {.inline.} =
  ## Returns ``true`` if peer with ``key`` present in PeerPool ``pool``.
  pool.registry.hasKey(key)

proc getOrDefault*[A, B](pool: PeerPool[A, B], key: B): A {.inline.} =
  ## Retrieves the peer from PeerPool ``pool`` using key ``key``. If peer is
  ## not present, default initialization value for type ``A`` is returned
  ## (e.g. 0 for any integer type).
  let pindex = pool.registry.getOrDefault(key, PeerIndex(data: -1))
  if pindex.data >= 0:
    pool.storage[pindex.data].data
  else:
    A()

proc getOrDefault*[A, B](pool: PeerPool[A, B], key: B,
                         default: A): A {.inline.} =
  ## Retrieves the peer from PeerPool ``pool`` using key ``key``. If peer is
  ## not present, default value ``default`` is returned.
  let pindex = pool.registry.getOrDefault(key, PeerIndex(data: -1))
  if pindex.data >= 0:
    pool.storage[pindex.data].data
  else:
    default

proc clear*[A, B](pool: PeerPool[A, B]) =
  ## Performs PeerPool's ``pool`` storage and counters reset.
  pool.incQueue.clear()
  pool.outQueue.clear()
  pool.registry.clear()
  for i in 0 ..< len(pool.storage):
    pool.storage[i] = PeerItem[A]()
  pool.storage.setLen(0)
  pool.curIncPeersCount = 0
  pool.curOutPeersCount = 0
  pool.acqIncPeersCount = 0
  pool.acqOutPeersCount = 0

proc clearSafe*[A, B](pool: PeerPool[A, B]) {.async.} =
  ## Performs "safe" clear. Safe means that it first acquires all the peers
  ## in PeerPool, and only after that it will reset storage.
  var acquired = newSeq[A]()
  while len(pool.registry) > len(acquired):
    var peers = await pool.acquire(len(pool.registry) - len(acquired))
    for item in peers:
      acquired.add(item)
  pool.clear()

proc setScoreCheck*[A, B](pool: PeerPool[A, B],
                          scoreCheckCb: PeerScoreCheckCallback[A]) =
  ## Sets ScoreCheck callback.
  pool.scoreCheck = scoreCheckCb

proc setOnDeletePeer*[A, B](pool: PeerPool[A, B],
                            deletePeerCb: PeerOnDeleteCallback[A]) =
  ## Sets DeletePeer callback.
  pool.onDeletePeer = deletePeerCb

proc setPeerCounter*[A, B](pool: PeerPool[A, B],
                           peerCounterCb: PeerCounterCallback) =
  ## Sets PeerCounter callback.
  pool.peerCounter = peerCounterCb
