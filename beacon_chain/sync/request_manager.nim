# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import std/[options, sequtils, strutils]
import chronos, chronicles, ssz_serialization
import ../spec/[datatypes, digest],
       ../networking/eth2_network,
       ../beacon_node_types,
       ../gossip_processing/block_processor,
       ./sync_protocol, ./sync_manager
export sync_manager

logScope:
  topics = "requman"

const
  SYNC_MAX_REQUESTED_BLOCKS* = 32 # Spec allows up to MAX_REQUEST_BLOCKS.
    ## Maximum number of blocks which will be requested in each
    ## `beaconBlocksByRoot` invocation.
  PARALLEL_REQUESTS* = 2
    ## Number of peers we using to resolve our request.

type
  RequestManager* = object
    network*: Eth2Node
    inpQueue*: AsyncQueue[FetchRecord]
    blockProcessor: ref BlockProcessor
    loopFuture: Future[void]

func shortLog*(x: seq[Eth2Digest]): string =
  "[" & x.mapIt(shortLog(it)).join(", ") & "]"

func shortLog*(x: seq[FetchRecord]): string =
  "[" & x.mapIt(shortLog(it.root)).join(", ") & "]"

proc init*(T: type RequestManager, network: Eth2Node,
           blockProcessor: ref BlockProcessor): RequestManager =
  RequestManager(
    network: network,
    inpQueue: newAsyncQueue[FetchRecord](),
    blockProcessor: blockProcessor
  )

proc checkResponse(roots: openArray[Eth2Digest],
                   blocks: openArray[SignedBeaconBlock]): bool =
  ## This procedure checks peer's response.
  var checks = @roots
  if len(blocks) > len(roots):
    return false
  for blk in blocks:
    let res = checks.find(blk.root)
    if res == -1:
      return false
    else:
      checks.del(res)
  return true

proc validate(rman: RequestManager,
              b: SignedBeaconBlock): Future[Result[void, BlockError]] =
  let resfut = newFuture[Result[void, BlockError]]("request.manager.validate")
  rman.blockProcessor[].addBlock(b, resfut)
  resfut

proc fetchAncestorBlocksFromNetwork(rman: RequestManager,
                                    items: seq[Eth2Digest]) {.async.} =
  var peer: Peer
  try:
    peer = await rman.network.peerPool.acquire()
    debug "Requesting blocks by root", peer = peer, blocks = shortLog(items),
                                       peer_score = peer.getScore()

    let blocks = await peer.beaconBlocksByRoot(BlockRootsList items)
    if blocks.isOk:
      let ublocks = blocks.get()
      if checkResponse(items, ublocks):
        var res: Result[void, BlockError]
        if len(ublocks) > 0:
          for b in ublocks:
            res = await rman.validate(b)
            # We are ignoring errors:
            # `BlockError.MissingParent` - because the order of the blocks that
            # we requested may be different from the order in which we need
            # these blocks to apply.
            # `BlockError.Old`, `BlockError.Duplicate` and `BlockError.Unviable`
            # errors could occur due to the concurrent/parallel requests we are
            # made.
            if res.isErr() and (res.error == BlockError.Invalid):
              # We stop processing blocks further to avoid DoS attack with big
              # chunk of incorrect blocks.
              break
        else:
          res = Result[void, BlockError].ok()

        if res.isOk():
          if len(ublocks) > 0:
            # We reward peer only if it returns something.
            peer.updateScore(PeerScoreGoodBlocks)
        else:
          # We are not penalizing other errors because of the reasons described
          # above.
          if res.error == BlockError.Invalid:
            peer.updateScore(PeerScoreBadBlocks)
      else:
        peer.updateScore(PeerScoreBadResponse)
    else:
      peer.updateScore(PeerScoreNoBlocks)

  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    peer.updateScore(PeerScoreNoBlocks)
    debug "Error while fetching ancestor blocks", exc = exc.msg,
          items = shortLog(items), peer = peer, peer_score = peer.getScore()
    raise exc
  finally:
    if not(isNil(peer)):
      rman.network.peerPool.release(peer)

proc requestManagerLoop(rman: RequestManager) {.async.} =
  var rootList = newSeq[Eth2Digest]()
  var workers = newSeq[Future[void]](PARALLEL_REQUESTS)
  while true:
    try:
      rootList.setLen(0)
      let req = await rman.inpQueue.popFirst()
      rootList.add(req.root)

      var count = min(SYNC_MAX_REQUESTED_BLOCKS - 1, len(rman.inpQueue))
      while count > 0:
        rootList.add(rman.inpQueue.popFirstNoWait().root)
        dec(count)

      let start = SyncMoment.now(Slot(0))

      for i in 0 ..< PARALLEL_REQUESTS:
        workers[i] = rman.fetchAncestorBlocksFromNetwork(rootList)

      # We do not care about
      await allFutures(workers)

      let finish = SyncMoment.now(Slot(0) + uint64(len(rootList)))

      var succeed = 0
      for worker in workers:
        if worker.finished() and not(worker.failed()):
          inc(succeed)

      debug "Request manager tick", blocks_count = len(rootList),
                                    succeed = succeed,
                                    failed = (len(workers) - succeed),
                                    queue_size = len(rman.inpQueue),
                                    sync_speed = speed(start, finish)

    except CatchableError as exc:
      debug "Got a problem in request manager", exc = exc.msg

proc start*(rman: var RequestManager) =
  ## Start Request Manager's loop.
  rman.loopFuture = rman.requestManagerLoop()

proc stop*(rman: RequestManager) =
  ## Stop Request Manager's loop.
  if not(isNil(rman.loopFuture)):
    rman.loopFuture.cancel()

proc fetchAncestorBlocks*(rman: RequestManager, roots: seq[FetchRecord]) =
  ## Enqueue list missing blocks roots ``roots`` for download by
  ## Request Manager ``rman``.
  for item in roots:
    try:
      rman.inpQueue.addLastNoWait(item)
    except AsyncQueueFullError: raiseAssert "unbounded queue"
