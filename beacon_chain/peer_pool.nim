import std/[tables, heapqueue]
import chronos

type
  PeerType* = enum
    None, Incoming, Outgoing

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

  PeerIndex = object
    data: int
    cmp: proc(a, b: PeerIndex): bool {.closure, gcsafe.}

  PeerScoreCheckCallback*[T] = proc(peer: T): bool {.gcsafe, raises: [Defect].}

  PeerCounterCallback* = proc() {.gcsafe, raises: [Defect].}

  PeerPool*[A, B] = ref object
    incNotEmptyEvent: AsyncEvent
    outNotEmptyEvent: AsyncEvent
    incNotFullEvent: AsyncEvent
    outNotFullEvent: AsyncEvent
    incQueue: HeapQueue[PeerIndex]
    outQueue: HeapQueue[PeerIndex]
    registry: Table[B, PeerIndex]
    storage: seq[PeerItem[A]]
    cmp: proc(a, b: PeerIndex): bool {.closure, gcsafe.}
    scoreCheck: PeerScoreCheckCallback[A]
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
                             item: PeerItem[A]) {.inline.} =
  if item.peerType == PeerType.Incoming:
    pool.incNotEmptyEvent.fire()
  elif item.peerType == PeerType.Outgoing:
    pool.outNotEmptyEvent.fire()

proc fireNotFullEvent[A, B](pool: PeerPool[A, B],
                            item: PeerItem[A]) {.inline.} =
  if item.peerType == PeerType.Incoming:
    pool.incNotFullEvent.fire()
  elif item.peerType == PeerType.Outgoing:
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
                peerCounterCb: PeerCounterCallback = nil): PeerPool[A, B] =
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
  ## Please note, that if ``maxPeers`` is positive non-zero value, then equation
  ## ``maxPeers >= maxIncomingPeers + maxOutgoingPeers`` must be ``true``.
  var res = PeerPool[A, B]()
  if maxPeers != -1:
    doAssert(maxPeers >= maxIncomingPeers + maxOutgoingPeers)

  res.maxPeersCount = if maxPeers < 0: high(int)
                        else: maxPeers
  res.maxIncPeersCount = if maxIncomingPeers < 0: high(int)
                           else: maxIncomingPeers
  res.maxOutPeersCount = if maxOutgoingPeers < 0: high(int)
                           else: maxOutgoingPeers
  res.incNotEmptyEvent = newAsyncEvent()
  res.outNotEmptyEvent = newAsyncEvent()
  res.incNotFullEvent = newAsyncEvent()
  res.outNotFullEvent = newAsyncEvent()
  res.incQueue = initHeapQueue[PeerIndex]()
  res.outQueue = initHeapQueue[PeerIndex]()
  res.registry = initTable[B, PeerIndex]()
  res.scoreCheck = scoreCheckCb
  res.peerCounter = peerCounterCb
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

proc shortLogAvailable*[A, B](pool: PeerPool[A, B]): string =
  $len(pool.incQueue) & "/" & $len(pool.outQueue)

proc shortLogAcquired*[A, B](pool: PeerPool[A, B]): string =
  $pool.acqIncPeersCount & "/" & $pool.acqOutPeersCount

proc checkPeerScore[A, B](pool: PeerPool[A, B], peer: A): bool {.inline.} =
  ## Returns ``true`` if peer passing score check.
  if not(isNil(pool.scoreCheck)):
    pool.scoreCheck(peer)
  else:
    true

proc peerCountChanged[A, B](pool: PeerPool[A, B]) {.inline.} =
  ## Call callback when number of peers changed.
  if not(isNil(pool.peerCounter)):
    pool.peerCounter()

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

        # Indicate that we have an empty space
        pool.fireNotFullEvent(item[])
        # Cleanup storage with default item, and removing key from hashtable.
        pool.storage[pindex] = PeerItem[A]()
        pool.registry.del(key)
        pool.peerCountChanged()
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

      # Indicate that we have an empty space
      pool.fireNotFullEvent(item[])
      # Cleanup storage with default item, and removing key from hashtable.
      pool.storage[pindex] = PeerItem[A]()
      pool.registry.del(key)
      pool.peerCountChanged()
    true
  else:
    false

proc addPeerImpl[A, B](pool: PeerPool[A, B], peer: A, peerKey: B,
                       peerType: PeerType) =
  proc onPeerClosed(udata: pointer) {.gcsafe.} =
    discard pool.deletePeer(peer)

  let item = PeerItem[A](data: peer, peerType: peerType,
                         index: len(pool.storage))
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

proc addPeerNoWait*[A, B](pool: PeerPool[A, B],
                          peer: A, peerType: PeerType): PeerStatus =
  ## Add peer ``peer`` of type ``peerType`` to PeerPool ``pool``.
  ##
  ## Procedure returns ``false`` in case
  ##   * if ``peer`` is already closed.
  ##   * if ``pool`` already has peer ``peer`` inside.
  ##   * if ``pool`` currently has a maximum of peers.
  ##   * if ``pool`` currently has a maximum of `Incoming` or `Outgoing` peers.
  ##
  ## Procedure returns ``true`` on success.
  mixin getKey, getFuture
  doAssert(peerType in {PeerType.Incoming, PeerType.Outgoing})

  if not(pool.checkPeerScore(peer)):
    PeerStatus.LowScoreError
  else:
    let peerKey = getKey(peer)
    if not(pool.registry.hasKey(peerKey)):
      if not(peer.getFuture().finished):
        if len(pool.registry) < pool.maxPeersCount:
          if peerType == PeerType.Incoming:
            if pool.curIncPeersCount < pool.maxIncPeersCount:
              pool.addPeerImpl(peer, peerKey, peerType)
              PeerStatus.Success
            else:
              PeerStatus.NoSpaceError
          else:
            if pool.curOutPeersCount < pool.maxOutPeersCount:
              pool.addPeerImpl(peer, peerKey, peerType)
              PeerStatus.Success
            else:
              PeerStatus.NoSpaceError
        else:
          PeerStatus.NoSpaceError
      else:
        PeerStatus.DeadPeerError
    else:
      PeerStatus.DuplicateError

proc addPeer*[A, B](pool: PeerPool[A, B],
                    peer: A, peerType: PeerType): Future[PeerStatus] {.async.} =
  ## Add peer ``peer`` of type ``peerType`` to PeerPool ``pool``.
  ##
  ## This procedure will wait for an empty space in PeerPool ``pool``, if
  ## PeerPool ``pool`` is full.
  ##
  ## Procedure returns ``false`` in case:
  ##   * if ``peer`` is already closed.
  ##   * if ``pool`` already has peer ``peer`` inside.
  ##
  ## Procedure returns ``true`` on success.
  mixin getKey, getFuture
  doAssert(peerType in {PeerType.Incoming, PeerType.Outgoing})

  return
    if not(pool.checkPeerScore(peer)):
      PeerStatus.LowScoreError
    else:
      let peerKey = getKey(peer)
      if not(pool.registry.hasKey(peerKey)):
        if not(peer.getFuture().finished):
          while len(pool.registry) >= pool.maxPeersCount:
            await pool.waitNotFullEvent({PeerType.Incoming, PeerType.Outgoing})
          if peerType == PeerType.Incoming:
            while pool.curIncPeersCount >= pool.maxIncPeersCount:
              await pool.waitNotFullEvent({peerType})
            pool.addPeerImpl(peer, peerKey, peerType)
            PeerStatus.Success
          else:
            while pool.curOutPeersCount >= pool.maxOutPeersCount:
              await pool.waitNotFullEvent({peerType})
            pool.addPeerImpl(peer, peerKey, peerType)
            PeerStatus.Success
        else:
          PeerStatus.DeadPeerError
      else:
        PeerStatus.DuplicateError

proc addIncomingPeerNoWait*[A, B](pool: PeerPool[A, B],
                                  peer: A): PeerStatus {.inline.} =
  ## Add incoming peer ``peer`` to PeerPool ``pool``.
  ##
  ## Returns ``true`` on success.
  pool.addPeerNoWait(peer, PeerType.Incoming)

proc addOutgoingPeerNoWait*[A, B](pool: PeerPool[A, B],
                                  peer: A): PeerStatus {.inline.} =
  ## Add outgoing peer ``peer`` to PeerPool ``pool``.
  ##
  ## Returns ``true`` on success.
  pool.addPeerNoWait(peer, PeerType.Outgoing)

proc addIncomingPeer*[A, B](pool: PeerPool[A, B],
                                  peer: A): Future[PeerStatus] {.inline.} =
  ## Add incoming peer ``peer`` to PeerPool ``pool``.
  ##
  ## Returns ``true`` on success.
  pool.addPeer(peer, PeerType.Incoming)

proc addOutgoingPeer*[A, B](pool: PeerPool[A, B],
                                  peer: A): Future[PeerStatus] {.inline.} =
  ## Add outgoing peer ``peer`` to PeerPool ``pool``.
  ##
  ## Returns ``true`` on success.
  pool.addPeer(peer, PeerType.Outgoing)

proc acquireItemImpl[A, B](pool: PeerPool[A, B],
                           filter: set[PeerType]): A {.inline.} =
  doAssert(filter != {})
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
        if item[].peerType == PeerType.Incoming:
          pool.incQueue.push(titem)
          dec(pool.acqIncPeersCount)
        elif item[].peerType == PeerType.Outgoing:
          pool.outQueue.push(titem)
          dec(pool.acqOutPeersCount)
        pool.fireNotEmptyEvent(item[])

proc release*[A, B](pool: PeerPool[A, B], peers: openarray[A]) {.inline.} =
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
  ## Add ScoreCheck callback.
  pool.scoreCheck = scoreCheckCb

proc setPeerCounter*[A, B](pool: PeerPool[A, B],
                           peerCounterCb: PeerCounterCallback) =
  ## Add PeerCounter callback.
  pool.peerCounter = peerCounterCb
