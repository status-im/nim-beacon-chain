{.used.}

import std/strutils
import unittest2
import chronos
import ../beacon_chain/gossip_processing/block_processor,
       ../beacon_chain/sync/sync_manager,
       ../beacon_chain/spec/datatypes/phase0,
       ../beacon_chain/spec/forkedbeaconstate_helpers

type
  SomeTPeer = ref object

proc `$`*(peer: SomeTPeer): string =
  "SomeTPeer"

proc updateScore(peer: SomeTPeer, score: int) =
  discard

proc getFirstSlotAtFinalizedEpoch(): Slot =
  Slot(0)

proc newBlockProcessor(): ref BlockProcessor =
  # Minimal block processor for test - the real block processor has an unbounded
  # queue but the tests here
  (ref BlockProcessor)(
    blocksQueue: newAsyncQueue[BlockEntry]()
  )

suite "SyncManager test suite":
  proc createChain(start, finish: Slot): seq[ForkedSignedBeaconBlock] =
    doAssert(start <= finish)
    let count = int(finish - start + 1'u64)
    result = newSeq[ForkedSignedBeaconBlock](count)
    var curslot = start
    for item in result.mitems():
      item.phase0Block.message.slot = curslot
      curslot = curslot + 1'u64

  test "[SyncQueue] Start and finish slots equal":
    let p1 = SomeTPeer()
    let aq = newBlockProcessor()
    var queue = SyncQueue.init(SomeTPeer, Slot(0), Slot(0), 1'u64,
                               getFirstSlotAtFinalizedEpoch, aq)
    check len(queue) == 1
    var r11 = queue.pop(Slot(0), p1)
    check len(queue) == 0
    queue.push(r11)
    check len(queue) == 1
    var r11e = queue.pop(Slot(0), p1)
    check:
      len(queue) == 0
      r11e == r11
      r11.item == p1
      r11e.item == r11.item
      r11.slot == Slot(0) and r11.count == 1'u64 and r11.step == 1'u64

  test "[SyncQueue] Two full requests success/fail":
    let aq = newBlockProcessor()
    var queue = SyncQueue.init(SomeTPeer, Slot(0), Slot(1), 1'u64,
                               getFirstSlotAtFinalizedEpoch, aq)
    let p1 = SomeTPeer()
    let p2 = SomeTPeer()
    check len(queue) == 2
    var r21 = queue.pop(Slot(1), p1)
    check len(queue) == 1
    var r22 = queue.pop(Slot(1), p2)
    check len(queue) == 0
    queue.push(r22)
    check len(queue) == 1
    queue.push(r21)
    check len(queue) == 2
    var r21e = queue.pop(Slot(1), p1)
    check len(queue) == 1
    var r22e = queue.pop(Slot(1), p2)
    check:
      len(queue) == 0
      r21 == r21e
      r22 == r22e
      r21.item == p1
      r22.item == p2
      r21.item == r21e.item
      r22.item == r22e.item
      r21.slot == Slot(0) and r21.count == 1'u64 and r21.step == 1'u64
      r22.slot == Slot(1) and r22.count == 1'u64 and r22.step == 1'u64

  test "[SyncQueue] Full and incomplete success/fail start from zero":
    let aq = newBlockProcessor()
    var queue = SyncQueue.init(SomeTPeer, Slot(0), Slot(4), 2'u64,
                               getFirstSlotAtFinalizedEpoch, aq)
    let p1 = SomeTPeer()
    let p2 = SomeTPeer()
    let p3 = SomeTPeer()
    check len(queue) == 5
    var r31 = queue.pop(Slot(4), p1)
    check len(queue) == 3
    var r32 = queue.pop(Slot(4), p2)
    check len(queue) == 1
    var r33 = queue.pop(Slot(4), p3)
    check len(queue) == 0
    queue.push(r33)
    check len(queue) == 1
    queue.push(r32)
    check len(queue) == 3
    queue.push(r31)
    check len(queue) == 5
    var r31e = queue.pop(Slot(4), p1)
    check len(queue) == 3
    var r32e = queue.pop(Slot(4), p2)
    check len(queue) == 1
    var r33e = queue.pop(Slot(4), p3)
    check:
      len(queue) == 0
      r31 == r31e
      r32 == r32e
      r33 == r33e
      r31.item == r31e.item
      r32.item == r32e.item
      r33.item == r33e.item
      r31.item == p1
      r32.item == p2
      r33.item == p3
      r31.slot == Slot(0) and r31.count == 2'u64 and r31.step == 1'u64
      r32.slot == Slot(2) and r32.count == 2'u64 and r32.step == 1'u64
      r33.slot == Slot(4) and r33.count == 1'u64 and r33.step == 1'u64

  test "[SyncQueue] Full and incomplete success/fail start from non-zero":
    let aq = newBlockProcessor()
    var queue = SyncQueue.init(SomeTPeer, Slot(1), Slot(5), 3'u64,
                               getFirstSlotAtFinalizedEpoch, aq)
    let p1 = SomeTPeer()
    let p2 = SomeTPeer()
    check len(queue) == 5
    var r41 = queue.pop(Slot(5), p1)
    check len(queue) == 2
    var r42 = queue.pop(Slot(5), p2)
    check len(queue) == 0
    queue.push(r42)
    check len(queue) == 2
    queue.push(r41)
    check len(queue) == 5
    var r41e = queue.pop(Slot(5), p1)
    check len(queue) == 2
    var r42e = queue.pop(Slot(5), p2)
    check:
      len(queue) == 0
      r41 == r41e
      r42 == r42e
      r41.item == r41e.item
      r42.item == r42e.item
      r41.item == p1
      r42.item == p2
      r41.slot == Slot(1) and r41.count == 3'u64 and r41.step == 1'u64
      r42.slot == Slot(4) and r42.count == 2'u64 and r42.step == 1'u64

  test "[SyncQueue] Smart and stupid success/fail":
    let aq = newBlockProcessor()
    var queue = SyncQueue.init(SomeTPeer, Slot(0), Slot(4), 5'u64,
                               getFirstSlotAtFinalizedEpoch, aq)
    let p1 = SomeTPeer()
    let p2 = SomeTPeer()
    check len(queue) == 5
    var r51 = queue.pop(Slot(3), p1)
    check len(queue) == 1
    var r52 = queue.pop(Slot(4), p2)
    check len(queue) == 0
    queue.push(r52)
    check len(queue) == 1
    queue.push(r51)
    check len(queue) == 5
    var r51e = queue.pop(Slot(3), p1)
    check len(queue) == 1
    var r52e = queue.pop(Slot(4), p2)
    check:
      len(queue) == 0
      r51 == r51e
      r52 == r52e
      r51.item == r51e.item
      r52.item == r52e.item
      r51.item == p1
      r52.item == p2
      r51.slot == Slot(0) and r51.count == 4'u64 and r51.step == 1'u64
      r52.slot == Slot(4) and r52.count == 1'u64 and r52.step == 1'u64

  test "[SyncQueue] One smart and one stupid + debt split + empty":
    let aq = newBlockProcessor()
    var queue = SyncQueue.init(SomeTPeer, Slot(0), Slot(4), 5'u64,
                               getFirstSlotAtFinalizedEpoch, aq)
    let p1 = SomeTPeer()
    let p2 = SomeTPeer()
    let p3 = SomeTPeer()
    let p4 = SomeTPeer()
    check len(queue) == 5
    var r61 = queue.pop(Slot(4), p1)
    check len(queue) == 0
    queue.push(r61)
    var r61e = queue.pop(Slot(2), p1)
    check len(queue) == 2
    var r62e = queue.pop(Slot(2), p2)
    check len(queue) == 2
    check r62e.isEmpty()
    var r63e = queue.pop(Slot(3), p3)
    check len(queue) == 1
    var r64e = queue.pop(Slot(4), p4)
    check:
      len(queue) == 0
      r61.slot == Slot(0) and r61.count == 5'u64 and r61.step == 1'u64
      r61e.slot == Slot(0) and r61e.count == 3'u64 and r61e.step == 1'u64
      r62e.isEmpty()
      r63e.slot == Slot(3) and r63e.count == 1'u64 and r63e.step == 1'u64
      r64e.slot == Slot(4) and r64e.count == 1'u64 and r64e.step == 1'u64
      r61.item == p1
      r61e.item == p1
      isNil(r62e.item) == true
      r63e.item == p3
      r64e.item == p4

  test "[SyncQueue] Async unordered push start from zero":
    proc test(): Future[bool] {.async.} =
      var counter = 0

      proc simpleValidator(aq: AsyncQueue[BlockEntry]) {.async.} =
        while true:
          let sblock = await aq.popFirst()
          if sblock.blck.phase0Block.message.slot == Slot(counter):
            inc(counter)
            sblock.done()
          else:
            sblock.fail(BlockError.Invalid)

      let aq = newBlockProcessor()
      var chain = createChain(Slot(0), Slot(2))
      var queue = SyncQueue.init(SomeTPeer, Slot(0), Slot(2), 1'u64,
                                 getFirstSlotAtFinalizedEpoch, aq, 1)

      var validatorFut = simpleValidator(aq[].blocksQueue)
      let p1 = SomeTPeer()
      let p2 = SomeTPeer()
      let p3 = SomeTPeer()
      var r11 = queue.pop(Slot(2), p1)
      var r12 = queue.pop(Slot(2), p2)
      var r13 = queue.pop(Slot(2), p3)
      var f13 = queue.push(r13, @[chain[2]])
      #
      await sleepAsync(100.milliseconds)
      # doAssert(f12.finished == false)
      doAssert(f13.finished == false)
      doAssert(counter == 0)
      var f11 = queue.push(r11, @[chain[0]])
      await sleepAsync(100.milliseconds)
      doAssert(counter == 1)
      doAssert(f11.finished == true and f11.failed == false)
      var f12 = queue.push(r12, @[chain[1]])
      await sleepAsync(100.milliseconds)
      doAssert(f12.finished == true and f12.failed == false)
      doAssert(f13.finished == true and f13.failed == false)
      doAssert(counter == 3)
      doAssert(r11.item == p1)
      doAssert(r12.item == p2)
      doAssert(r13.item == p3)

      await validatorFut.cancelAndWait()
      result = true

    check waitFor(test())

  test "[SyncQueue] Async unordered push with not full start from non-zero":
    proc test(): Future[bool] {.async.} =
      var counter = 5

      proc simpleValidator(aq: AsyncQueue[BlockEntry]) {.async.} =
        while true:
          let sblock = await aq.popFirst()
          if sblock.blck.phase0Block.message.slot == Slot(counter):
            inc(counter)
            sblock.done()
          else:
            sblock.fail(BlockError.Invalid)

      let aq = newBlockProcessor()
      var chain = createChain(Slot(5), Slot(11))
      var queue = SyncQueue.init(SomeTPeer, Slot(5), Slot(11), 2'u64,
                                 getFirstSlotAtFinalizedEpoch, aq, 2)

      let p1 = SomeTPeer()
      let p2 = SomeTPeer()
      let p3 = SomeTPeer()
      let p4 = SomeTPeer()

      var validatorFut = simpleValidator(aq[].blocksQueue)

      var r21 = queue.pop(Slot(11), p1)
      var r22 = queue.pop(Slot(11), p2)
      var r23 = queue.pop(Slot(11), p3)
      var r24 = queue.pop(Slot(11), p4)

      var f24 = queue.push(r24, @[chain[6]])
      var f22 = queue.push(r22, @[chain[2], chain[3]])
      doAssert(f24.finished == false)
      doAssert(f22.finished == true and f22.failed == false)
      doAssert(counter == 5)
      var f21 = queue.push(r21, @[chain[0], chain[1]])
      await sleepAsync(100.milliseconds)
      doAssert(f21.finished == true and f21.failed == false)
      doAssert(f24.finished == true and f24.failed == false)
      doAssert(counter == 9)
      var f23 = queue.push(r23, @[chain[4], chain[5]])
      await sleepAsync(100.milliseconds)
      doAssert(f23.finished == true and f23.failed == false)
      doAssert(counter == 12)
      doAssert(counter == 12)
      doAssert(r21.item == p1)
      doAssert(r22.item == p2)
      doAssert(r23.item == p3)
      doAssert(r24.item == p4)

      await validatorFut.cancelAndWait()
      result = true

    check waitFor(test())

  test "[SyncQueue] Async pending and resetWait() test":
    proc test(): Future[bool] {.async.} =
      var counter = 5

      proc simpleValidator(aq: AsyncQueue[BlockEntry]) {.async.} =
        while true:
          let sblock = await aq.popFirst()
          if sblock.blck.phase0Block.message.slot == Slot(counter):
            inc(counter)
            sblock.done()
          else:
            sblock.fail(BlockError.Invalid)

      let aq = newBlockProcessor()
      var chain = createChain(Slot(5), Slot(18))
      var queue = SyncQueue.init(SomeTPeer, Slot(5), Slot(18), 2'u64,
                                 getFirstSlotAtFinalizedEpoch, aq, 2)
      let p1 = SomeTPeer()
      let p2 = SomeTPeer()
      let p3 = SomeTPeer()
      let p4 = SomeTPeer()
      let p5 = SomeTPeer()
      let p6 = SomeTPeer()
      let p7 = SomeTPeer()

      var validatorFut = simpleValidator(aq[].blocksQueue)

      var r21 = queue.pop(Slot(20), p1)
      var r22 = queue.pop(Slot(20), p2)
      var r23 = queue.pop(Slot(20), p3)
      var r24 = queue.pop(Slot(20), p4)
      var r25 = queue.pop(Slot(20), p5)
      var r26 = queue.pop(Slot(20), p6)
      var r27 = queue.pop(Slot(20), p7)

      var f21 = queue.push(r21, @[chain[0], chain[1]])
      # This should be silently ignored, because r21 is already processed.
      var e21 = queue.push(r21, @[chain[0], chain[1]])
      queue.push(r22)
      queue.push(r23)
      var f26 = queue.push(r26, @[chain[10], chain[11]])
      var f27 = queue.push(r27, @[chain[12], chain[13]])

      await sleepAsync(100.milliseconds)
      doAssert(f21.finished == true and f21.failed == false)
      doAssert(e21.finished == true and e21.failed == false)
      doAssert(f26.finished == false)
      doAssert(f27.finished == false)
      await queue.resetWait(none[Slot]())
      await sleepAsync(100.milliseconds)
      doAssert(f26.finished == true and f26.failed == false)
      doAssert(f27.finished == true and f27.failed == false)
      doAssert(queue.inpSlot == Slot(7) and queue.outSlot == Slot(7))
      doAssert(counter == 7)
      doAssert(len(queue) == 12)
      # This should be silently ignored, because r21 is already processed.
      var o21 = queue.push(r21, @[chain[0], chain[1]])
      var o22 = queue.push(r22, @[chain[2], chain[3]])
      queue.push(r23)
      queue.push(r24)
      var o25 = queue.push(r25, @[chain[8], chain[9]])
      var o26 = queue.push(r26, @[chain[10], chain[11]])
      var o27 = queue.push(r27, @[chain[12], chain[13]])
      await sleepAsync(100.milliseconds)
      doAssert(o21.finished == true and o21.failed == false)
      doAssert(o22.finished == true and o22.failed == false)
      doAssert(o25.finished == true and o25.failed == false)
      doAssert(o26.finished == true and o26.failed == false)
      doAssert(o27.finished == true and o27.failed == false)
      doAssert(len(queue) == 12)

      await validatorFut.cancelAndWait()
      result = true

    check waitFor(test())

  test "[SyncQueue] hasEndGap() test":
    let chain1 = createChain(Slot(1), Slot(1))
    let chain2 = newSeq[ForkedSignedBeaconBlock]()

    for counter in countdown(32'u64, 2'u64):
      let req = SyncRequest[SomeTPeer](slot: Slot(1), count: counter,
                                      step: 1'u64)
      let sr = SyncResult[SomeTPeer](request: req, data: chain1)
      check sr.hasEndGap() == true

    let req = SyncRequest[SomeTPeer](slot: Slot(1), count: 1'u64, step: 1'u64)
    let sr1 = SyncResult[SomeTPeer](request: req, data: chain1)
    let sr2 = SyncResult[SomeTPeer](request: req, data: chain2)
    check:
      sr1.hasEndGap() == false
      sr2.hasEndGap() == true

  test "[SyncQueue] getLastNonEmptySlot() test":
    let chain1 = createChain(Slot(10), Slot(10))
    let chain2 = newSeq[ForkedSignedBeaconBlock]()

    for counter in countdown(32'u64, 2'u64):
      let req = SyncRequest[SomeTPeer](slot: Slot(10), count: counter,
                                       step: 1'u64)
      let sr = SyncResult[SomeTPeer](request: req, data: chain1)
      check sr.getLastNonEmptySlot() == Slot(10)

    let req = SyncRequest[SomeTPeer](slot: Slot(100), count: 1'u64, step: 1'u64)
    let sr = SyncResult[SomeTPeer](request: req, data: chain2)
    check sr.getLastNonEmptySlot() == Slot(100)

  test "[SyncQueue] contains() test":
    proc checkRange[T](req: SyncRequest[T]): bool =
      var slot = req.slot
      var counter = 0'u64
      while counter < req.count:
        if not(req.contains(slot)):
          return false
        slot = slot + req.step
        counter = counter + 1'u64
      return true

    var req1 = SyncRequest[SomeTPeer](slot: Slot(5), count: 10'u64, step: 1'u64)
    var req2 = SyncRequest[SomeTPeer](slot: Slot(1), count: 10'u64, step: 2'u64)
    var req3 = SyncRequest[SomeTPeer](slot: Slot(2), count: 10'u64, step: 3'u64)
    var req4 = SyncRequest[SomeTPeer](slot: Slot(3), count: 10'u64, step: 4'u64)
    var req5 = SyncRequest[SomeTPeer](slot: Slot(4), count: 10'u64, step: 5'u64)

    check:
      req1.checkRange() == true
      req2.checkRange() == true
      req3.checkRange() == true
      req4.checkRange() == true
      req5.checkRange() == true

      req1.contains(Slot(4)) == false
      req1.contains(Slot(15)) == false

      req2.contains(Slot(0)) == false
      req2.contains(Slot(21)) == false
      req2.contains(Slot(20)) == false

      req3.contains(Slot(0)) == false
      req3.contains(Slot(1)) == false
      req3.contains(Slot(32)) == false
      req3.contains(Slot(31)) == false
      req3.contains(Slot(30)) == false

      req4.contains(Slot(0)) == false
      req4.contains(Slot(1)) == false
      req4.contains(Slot(2)) == false
      req4.contains(Slot(43)) == false
      req4.contains(Slot(42)) == false
      req4.contains(Slot(41)) == false
      req4.contains(Slot(40)) == false

      req5.contains(Slot(0)) == false
      req5.contains(Slot(1)) == false
      req5.contains(Slot(2)) == false
      req5.contains(Slot(3)) == false
      req5.contains(Slot(54)) == false
      req5.contains(Slot(53)) == false
      req5.contains(Slot(52)) == false
      req5.contains(Slot(51)) == false
      req5.contains(Slot(50)) == false

  test "[SyncQueue] checkResponse() test":
    let chain = createChain(Slot(10), Slot(20))
    let r1 = SyncRequest[SomeTPeer](slot: Slot(11), count: 1'u64, step: 1'u64)
    let r21 = SyncRequest[SomeTPeer](slot: Slot(11), count: 2'u64, step: 1'u64)
    let r22 = SyncRequest[SomeTPeer](slot: Slot(11), count: 2'u64, step: 2'u64)

    check:
      checkResponse(r1, @[chain[1]]) == true
      checkResponse(r1, @[]) == true
      checkResponse(r1, @[chain[1], chain[1]]) == false
      checkResponse(r1, @[chain[0]]) == false
      checkResponse(r1, @[chain[2]]) == false

      checkResponse(r21, @[chain[1]]) == true
      checkResponse(r21, @[]) == true
      checkResponse(r21, @[chain[1], chain[2]]) == true
      checkResponse(r21, @[chain[2]]) == true
      checkResponse(r21, @[chain[1], chain[2], chain[3]]) == false
      checkResponse(r21, @[chain[0], chain[1]]) == false
      checkResponse(r21, @[chain[0]]) == false
      checkResponse(r21, @[chain[2], chain[1]]) == false
      checkResponse(r21, @[chain[2], chain[1]]) == false
      checkResponse(r21, @[chain[2], chain[3]]) == false
      checkResponse(r21, @[chain[3]]) == false

      checkResponse(r22, @[chain[1]]) == true
      checkResponse(r22, @[]) == true
      checkResponse(r22, @[chain[1], chain[3]]) == true
      checkResponse(r22, @[chain[3]]) == true
      checkResponse(r22, @[chain[1], chain[3], chain[5]]) == false
      checkResponse(r22, @[chain[0], chain[1]]) == false
      checkResponse(r22, @[chain[1], chain[2]]) == false
      checkResponse(r22, @[chain[2], chain[3]]) == false
      checkResponse(r22, @[chain[3], chain[4]]) == false
      checkResponse(r22, @[chain[4], chain[5]]) == false
      checkResponse(r22, @[chain[4]]) == false
      checkResponse(r22, @[chain[3], chain[1]]) == false

  test "[SyncQueue] getRewindPoint() test":
    let aq = newBlockProcessor()
    block:
      var queue = SyncQueue.init(SomeTPeer,
                                 Slot(0), Slot(0xFFFF_FFFF_FFFF_FFFFF'u64),
                                 1'u64, getFirstSlotAtFinalizedEpoch, aq, 2)
      let finalizedSlot = compute_start_slot_at_epoch(Epoch(0'u64))
      let startSlot = compute_start_slot_at_epoch(Epoch(0'u64)) + 1'u64
      let finishSlot = compute_start_slot_at_epoch(Epoch(2'u64))

      for i in uint64(startSlot) ..< uint64(finishSlot):
        check queue.getRewindPoint(Slot(i), finalizedSlot) == finalizedSlot

    block:
      var queue = SyncQueue.init(SomeTPeer,
                                 Slot(0), Slot(0xFFFF_FFFF_FFFF_FFFFF'u64),
                                 1'u64, getFirstSlotAtFinalizedEpoch, aq, 2)
      let finalizedSlot = compute_start_slot_at_epoch(Epoch(1'u64))
      let startSlot = compute_start_slot_at_epoch(Epoch(1'u64)) + 1'u64
      let finishSlot = compute_start_slot_at_epoch(Epoch(3'u64))

      for i in uint64(startSlot) ..< uint64(finishSlot) :
        check queue.getRewindPoint(Slot(i), finalizedSlot) == finalizedSlot

    block:
      var queue = SyncQueue.init(SomeTPeer,
                                 Slot(0), Slot(0xFFFF_FFFF_FFFF_FFFFF'u64),
                                 1'u64, getFirstSlotAtFinalizedEpoch, aq, 2)
      let finalizedSlot = compute_start_slot_at_epoch(Epoch(0'u64))
      let failSlot = Slot(0xFFFF_FFFF_FFFF_FFFFF'u64)
      let failEpoch = compute_epoch_at_slot(failSlot)

      var counter = 1'u64
      for i in 0 ..< 64:
        if counter >= failEpoch:
          break
        let rewindEpoch = failEpoch - counter
        let rewindSlot = compute_start_slot_at_epoch(rewindEpoch)
        check queue.getRewindPoint(failSlot, finalizedSlot) == rewindSlot
        counter = counter shl 1

    block:
      var queue = SyncQueue.init(SomeTPeer,
                                 Slot(0), Slot(0xFFFF_FFFF_FFFF_FFFFF'u64),
                                 1'u64, getFirstSlotAtFinalizedEpoch, aq, 2)
      let finalizedSlot = compute_start_slot_at_epoch(Epoch(1'u64))
      let failSlot = Slot(0xFFFF_FFFF_FFFF_FFFFF'u64)
      let failEpoch = compute_epoch_at_slot(failSlot)
      var counter = 1'u64
      for i in 0 ..< 64:
        if counter >= failEpoch:
          break
        let rewindEpoch = failEpoch - counter
        let rewindSlot = compute_start_slot_at_epoch(rewindEpoch)
        check queue.getRewindPoint(failSlot, finalizedSlot) == rewindSlot
        counter = counter shl 1
