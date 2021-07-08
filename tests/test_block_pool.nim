# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronicles,
  std/[options, sequtils],
  unittest2,
  stew/assign2,
  eth/keys,
  ../beacon_chain/spec/datatypes/base,
  ../beacon_chain/spec/[
    digest, forkedbeaconstate_helpers, helpers, state_transition, presets],
  ../beacon_chain/beacon_node_types,
  ../beacon_chain/[beacon_chain_db, ssz],
  ../beacon_chain/consensus_object_pools/[
    blockchain_dag, block_quarantine, block_clearance],
  ./testutil, ./testdbutil, ./testblockutil

proc `$`(x: BlockRef): string =
  $x.root

proc pruneAtFinalization(dag: ChainDAGRef) =
  if dag.needStateCachesAndForkChoicePruning():
    dag.pruneStateCachesDAG()

suite "BlockRef and helpers" & preset():
  test "isAncestorOf sanity" & preset():
    let
      s0 = BlockRef(slot: Slot(0))
      s1 = BlockRef(slot: Slot(1), parent: s0)
      s2 = BlockRef(slot: Slot(2), parent: s1)

    check:
      s0.isAncestorOf(s0)
      s0.isAncestorOf(s1)
      s0.isAncestorOf(s2)
      s1.isAncestorOf(s1)
      s1.isAncestorOf(s2)

      not s2.isAncestorOf(s0)
      not s2.isAncestorOf(s1)
      not s1.isAncestorOf(s0)

  test "get_ancestor sanity" & preset():
    let
      s0 = BlockRef(slot: Slot(0))
      s1 = BlockRef(slot: Slot(1), parent: s0)
      s2 = BlockRef(slot: Slot(2), parent: s1)
      s4 = BlockRef(slot: Slot(4), parent: s2)

    check:
      s0.get_ancestor(Slot(0)) == s0
      s0.get_ancestor(Slot(1)) == s0

      s1.get_ancestor(Slot(0)) == s0
      s1.get_ancestor(Slot(1)) == s1

      s4.get_ancestor(Slot(0)) == s0
      s4.get_ancestor(Slot(1)) == s1
      s4.get_ancestor(Slot(2)) == s2
      s4.get_ancestor(Slot(3)) == s2
      s4.get_ancestor(Slot(4)) == s4

  test "epochAncestor sanity" & preset():
    let
      s0 = BlockRef(slot: Slot(0))
    var cur = s0
    for i in 1..SLOTS_PER_EPOCH * 2:
      cur = BlockRef(slot: Slot(i), parent: cur)

    let ancestor = cur.epochAncestor(cur.slot.epoch)

    check:
      ancestor.epoch == cur.slot.epoch
      ancestor.blck != cur # should have selected a parent

      ancestor.blck.epochAncestor(cur.slot.epoch) == ancestor
      ancestor.blck.epochAncestor(ancestor.blck.slot.epoch) != ancestor

suite "BlockSlot and helpers" & preset():
  test "atSlot sanity" & preset():
    let
      s0 = BlockRef(slot: Slot(0))
      s1 = BlockRef(slot: Slot(1), parent: s0)
      s2 = BlockRef(slot: Slot(2), parent: s1)
      s4 = BlockRef(slot: Slot(4), parent: s2)

    check:
      s0.atSlot(Slot(0)).blck == s0
      s0.atSlot(Slot(0)) == s1.atSlot(Slot(0))
      s1.atSlot(Slot(1)).blck == s1

      s4.atSlot(Slot(0)).blck == s0

  test "parent sanity" & preset():
    let
      s0 = BlockRef(slot: Slot(0))
      s00 = BlockSlot(blck: s0, slot: Slot(0))
      s01 = BlockSlot(blck: s0, slot: Slot(1))
      s2 = BlockRef(slot: Slot(2), parent: s0)
      s22 = BlockSlot(blck: s2, slot: Slot(2))
      s24 = BlockSlot(blck: s2, slot: Slot(4))

    check:
      s00.parent == BlockSlot(blck: nil, slot: Slot(0))
      s01.parent == s00
      s01.parentOrSlot == s00
      s22.parent == s01
      s22.parentOrSlot == BlockSlot(blck: s0, slot: Slot(2))
      s24.parent == BlockSlot(blck: s2, slot: Slot(3))
      s24.parent.parent == s22

suite "Block pool processing" & preset():
  setup:
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimeConfig, db, {})
      quarantine = QuarantineRef.init(keys.newRng())
      nilPhase0Callback: OnPhase0BlockAdded
      state = newClone(dag.headState.data)
      cache = StateCache()
      rewards = RewardInfo()
      att0 = makeFullAttestations(state[], dag.tail.root, 0.Slot, cache)
      b1 = addTestBlock(state[], dag.tail.root, cache, attestations = att0)
      b2 = addTestBlock(state[], b1.root, cache)
  test "getRef returns nil for missing blocks":
    check:
      dag.getRef(default Eth2Digest) == nil

  test "loading tail block works" & preset():
    let
      b0 = dag.get(dag.tail.root)

    check:
      b0.isSome()

  test "Simple block add&get" & preset():
    let
      b1Add = dag.addRawBlock(quarantine, b1, nilPhase0Callback)
      b1Get = dag.get(b1.root)

    check:
      b1Get.isSome()
      b1Get.get().refs.root == b1.root
      b1Add[].root == b1Get.get().refs.root
      dag.heads.len == 1
      dag.heads[0] == b1Add[]

    let
      b2Add = dag.addRawBlock(quarantine, b2, nilPhase0Callback)
      b2Get = dag.get(b2.root)
      er = dag.findEpochRef(b1Add[], b1Add[].slot.epoch)
      validators = getStateField(dag.headState.data, validators).lenu64()

    check:
      b2Get.isSome()
      b2Get.get().refs.root == b2.root
      b2Add[].root == b2Get.get().refs.root
      dag.heads.len == 1
      dag.heads[0] == b2Add[]
      not er.isNil
      # Same epoch - same epochRef
      er == dag.findEpochRef(b2Add[], b2Add[].slot.epoch)
      # Different epoch that was never processed
      dag.findEpochRef(b1Add[], b1Add[].slot.epoch + 1).isNil

      er.validatorKey(0'u64).isSome()
      er.validatorKey(validators - 1).isSome()
      er.validatorKey(validators).isNone()

    # Skip one slot to get a gap
    check:
      process_slots(
        defaultRuntimeConfig, state[], getStateField(state[], slot) + 1, cache,
        rewards, {})

    let
      b4 = addTestBlock(state[], b2.root, cache)
      b4Add = dag.addRawBlock(quarantine, b4, nilPhase0Callback)

    check:
      b4Add[].parent == b2Add[]

    dag.updateHead(b4Add[], quarantine)
    dag.pruneAtFinalization()

    var blocks: array[3, BlockRef]

    check:
      dag.getBlockRange(Slot(0), 1, blocks.toOpenArray(0, 0)) == 0
      blocks[0..<1] == [dag.tail]

      dag.getBlockRange(Slot(0), 1, blocks.toOpenArray(0, 1)) == 0
      blocks[0..<2] == [dag.tail, b1Add[]]

      dag.getBlockRange(Slot(0), 2, blocks.toOpenArray(0, 1)) == 0
      blocks[0..<2] == [dag.tail, b2Add[]]

      dag.getBlockRange(Slot(0), 3, blocks.toOpenArray(0, 1)) == 1
      blocks[1..<2] == [dag.tail] # block 3 is missing!

      dag.getBlockRange(Slot(2), 2, blocks.toOpenArray(0, 1)) == 0
      blocks[0..<2] == [b2Add[], b4Add[]] # block 3 is missing!

      # large skip step
      dag.getBlockRange(Slot(0), uint64.high, blocks.toOpenArray(0, 2)) == 2
      blocks[2..2] == [dag.tail]

      # large skip step
      dag.getBlockRange(Slot(2), uint64.high, blocks.toOpenArray(0, 1)) == 1
      blocks[1..1] == [b2Add[]]

      # empty length
      dag.getBlockRange(Slot(2), 2, blocks.toOpenArray(0, -1)) == 0

      # No blocks in sight
      dag.getBlockRange(Slot(5), 1, blocks.toOpenArray(0, 1)) == 2

      # No blocks in sight
      dag.getBlockRange(Slot(uint64.high), 1, blocks.toOpenArray(0, 1)) == 2

      # No blocks in sight either due to gaps
      dag.getBlockRange(Slot(3), 2, blocks.toOpenArray(0, 1)) == 2
      blocks[2..<2].len == 0

  test "Reverse order block add & get" & preset():
    let missing = dag.addRawBlock(quarantine, b2, nilPhase0Callback)
    check: missing.error == (ValidationResult.Ignore, MissingParent)

    check:
      dag.get(b2.root).isNone() # Unresolved, shouldn't show up
      FetchRecord(root: b1.root) in quarantine.checkMissing()

    let status = dag.addRawBlock(quarantine, b1, nilPhase0Callback)

    check: status.isOk

    let
      b1Get = dag.get(b1.root)
      b2Get = dag.get(b2.root)

    check:
      b1Get.isSome()
      b2Get.isSome()

      b2Get.get().refs.parent == b1Get.get().refs

    dag.updateHead(b2Get.get().refs, quarantine)
    dag.pruneAtFinalization()

    # The heads structure should have been updated to contain only the new
    # b2 head
    check:
      dag.heads.mapIt(it) == @[b2Get.get().refs]

    # check that init also reloads block graph
    var
      dag2 = init(ChainDAGRef, defaultRuntimeConfig, db, {})

    check:
      # ensure we loaded the correct head state
      dag2.head.root == b2.root
      hash_tree_root(dag2.headState.data) == b2.message.state_root
      dag2.get(b1.root).isSome()
      dag2.get(b2.root).isSome()
      dag2.heads.len == 1
      dag2.heads[0].root == b2.root

  test "Adding the same block twice returns a Duplicate error" & preset():
    let
      b10 = dag.addRawBlock(quarantine, b1, nilPhase0Callback)
      b11 = dag.addRawBlock(quarantine, b1, nilPhase0Callback)

    check:
      b11.error == (ValidationResult.Ignore, Duplicate)
      not b10[].isNil

  test "updateHead updates head and headState" & preset():
    let
      b1Add = dag.addRawBlock(quarantine, b1, nilPhase0Callback)

    dag.updateHead(b1Add[], quarantine)
    dag.pruneAtFinalization()

    check:
      dag.head == b1Add[]
      getStateField(dag.headState.data, slot) == b1Add[].slot

  test "updateStateData sanity" & preset():
    let
      b1Add = dag.addRawBlock(quarantine, b1, nilPhase0Callback)
      b2Add = dag.addRawBlock(quarantine, b2, nilPhase0Callback)
      bs1 = BlockSlot(blck: b1Add[], slot: b1.message.slot)
      bs1_3 = b1Add[].atSlot(3.Slot)
      bs2_3 = b2Add[].atSlot(3.Slot)

    var tmpState = assignClone(dag.headState)

    # move to specific block
    var cache = StateCache()
    dag.updateStateData(tmpState[], bs1, false, cache)

    check:
      tmpState.blck == b1Add[]
      getStateField(tmpState.data, slot) == bs1.slot

    # Skip slots
    dag.updateStateData(tmpState[], bs1_3, false, cache) # skip slots

    check:
      tmpState.blck == b1Add[]
      getStateField(tmpState.data, slot) == bs1_3.slot

    # Move back slots, but not blocks
    dag.updateStateData(tmpState[], bs1_3.parent(), false, cache)
    check:
      tmpState.blck == b1Add[]
      getStateField(tmpState.data, slot) == bs1_3.parent().slot

    # Move to different block and slot
    dag.updateStateData(tmpState[], bs2_3, false, cache)
    check:
      tmpState.blck == b2Add[]
      getStateField(tmpState.data, slot) == bs2_3.slot

    # Move back slot and block
    dag.updateStateData(tmpState[], bs1, false, cache)
    check:
      tmpState.blck == b1Add[]
      getStateField(tmpState.data, slot) == bs1.slot

    # Move back to genesis
    dag.updateStateData(tmpState[], bs1.parent(), false, cache)
    check:
      tmpState.blck == b1Add[].parent
      getStateField(tmpState.data, slot) == bs1.parent.slot

suite "chain DAG finalization tests" & preset():
  setup:
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimeConfig, db, {})
      quarantine = QuarantineRef.init(keys.newRng())
      nilPhase0Callback: OnPhase0BlockAdded
      cache = StateCache()
      rewards = RewardInfo()

  test "prune heads on finalization" & preset():
    # Create a fork that will not be taken
    var
      blck = makeTestBlock(dag.headState.data, dag.head.root, cache)
      tmpState = assignClone(dag.headState.data)
    check:
      process_slots(
        defaultRuntimeConfig, tmpState[],
        getStateField(tmpState[], slot) + (5 * SLOTS_PER_EPOCH).uint64,
        cache, rewards, {})

    let lateBlock = addTestBlock(tmpState[], dag.head.root, cache)
    block:
      let status = dag.addRawBlock(quarantine, blck, nilPhase0Callback)
      check: status.isOk()

    assign(tmpState[], dag.headState.data)

    for i in 0 ..< (SLOTS_PER_EPOCH * 6):
      if i == 1:
        # There are 2 heads now because of the fork at slot 1
        check:
          dag.heads.len == 2

      blck = addTestBlock(
        tmpState[], dag.head.root, cache,
        attestations = makeFullAttestations(
          tmpState[], dag.head.root, getStateField(tmpState[], slot), cache, {}))
      let added = dag.addRawBlock(quarantine, blck, nilPhase0Callback)
      check: added.isOk()
      dag.updateHead(added[], quarantine)
      dag.pruneAtFinalization()

    check:
      dag.heads.len() == 1

    check:
      dag.db.immutableValidators.len() == getStateField(dag.headState.data, validators).len()

    let
      finalER = dag.findEpochRef(dag.finalizedHead.blck, dag.finalizedHead.slot.epoch)

      # The EpochRef for the finalized block is needed for eth1 voting, so we
      # should never drop it!
    check:
      not finalER.isNil

    block:
      for er in dag.epochRefs:
        check: er == nil or er.epoch >= dag.finalizedHead.slot.epoch

    block:
      let tmpStateData = assignClone(dag.headState)

      # Check that cached data is available after updateStateData - since we
      # just processed the head the relevant epochrefs should not have been
      # evicted yet
      cache = StateCache()
      updateStateData(
        dag, tmpStateData[], dag.head.atSlot(dag.head.slot), false, cache)

      check:
        dag.head.slot.epoch in cache.shuffled_active_validator_indices
        (dag.head.slot.epoch - 1) in cache.shuffled_active_validator_indices

        dag.head.slot in cache.beacon_proposer_indices

    block:
      # The late block is a block whose parent was finalized long ago and thus
      # is no longer a viable head candidate
      let status = dag.addRawBlock(quarantine, lateBlock, nilPhase0Callback)
      check: status.error == (ValidationResult.Ignore, Unviable)

    block:
      let
        finalizedCheckpoint = dag.finalizedHead.stateCheckpoint
        headCheckpoint = dag.head.atSlot(dag.head.slot).stateCheckpoint
      check:
        db.getStateRoot(headCheckpoint.blck.root, headCheckpoint.slot).isSome
        db.getStateRoot(finalizedCheckpoint.blck.root, finalizedCheckpoint.slot).isSome

    let
      dag2 = init(ChainDAGRef, defaultRuntimeConfig, db, {})

    # check that the state reloaded from database resembles what we had before
    check:
      dag2.tail.root == dag.tail.root
      dag2.head.root == dag.head.root
      dag2.finalizedHead.blck.root == dag.finalizedHead.blck.root
      dag2.finalizedHead.slot == dag.finalizedHead.slot
      hash_tree_root(dag2.headState.data) == hash_tree_root(dag.headState.data)

  test "orphaned epoch block" & preset():
    var prestate = (ref ForkedHashedBeaconState)(beaconStateFork: forkPhase0)
    for i in 0 ..< SLOTS_PER_EPOCH:
      if i == SLOTS_PER_EPOCH - 1:
        assign(prestate[], dag.headState.data)

      let blck = makeTestBlock(dag.headState.data, dag.head.root, cache)
      let added = dag.addRawBlock(quarantine, blck, nilPhase0Callback)
      check: added.isOk()
      dag.updateHead(added[], quarantine)
      dag.pruneAtFinalization()

    check:
      dag.heads.len() == 1

    # The loop creates multiple branches, which StateCache isn't suitable for
    cache = StateCache()

    doAssert process_slots(
      defaultRuntimeConfig, prestate[], getStateField(prestate[], slot) + 1,
      cache, rewards, {})

    # create another block, orphaning the head
    let blck = makeTestBlock(prestate[], dag.head.parent.root, cache)

    # Add block, but don't update head
    let added = dag.addRawBlock(quarantine, blck, nilPhase0Callback)
    check: added.isOk()

    var
      dag2 = init(ChainDAGRef, defaultRuntimeConfig, db, {})

    # check that we can apply the block after the orphaning
    let added2 = dag2.addRawBlock(quarantine, blck, nilPhase0Callback)
    check: added2.isOk()

  test "init with gaps" & preset():
    for blck in makeTestBlocks(
        dag.headState.data, dag.head.root, cache, int(SLOTS_PER_EPOCH * 6 - 2),
        true):
      let added = dag.addRawBlock(quarantine, blck, nilPhase0Callback)
      check: added.isOk()
      dag.updateHead(added[], quarantine)
      dag.pruneAtFinalization()

    # Advance past epoch so that the epoch transition is gapped
    check:
      process_slots(
        defaultRuntimeConfig, dag.headState.data, Slot(SLOTS_PER_EPOCH * 6 + 2),
        cache, rewards, {})

    var blck = makeTestBlock(
      dag.headState.data, dag.head.root, cache,
      attestations = makeFullAttestations(
        dag.headState.data, dag.head.root, getStateField(dag.headState.data, slot),
        cache, {}))

    let added = dag.addRawBlock(quarantine, blck, nilPhase0Callback)
    check: added.isOk()
    dag.updateHead(added[], quarantine)
    dag.pruneAtFinalization()

    block:
      # Check that we can rewind to every block from head to finalized
      var
        cur = dag.head
        tmpStateData = assignClone(dag.headState)
      while cur.slot >= dag.finalizedHead.slot:
        assign(tmpStateData[], dag.headState)
        dag.updateStateData(tmpStateData[], cur.atSlot(cur.slot), false, cache)
        check:
          dag.get(cur).data.phase0Block.message.state_root == getStateRoot(tmpStateData[].data)
          getStateRoot(tmpStateData[].data) == hash_tree_root(tmpStateData[].data)
        cur = cur.parent

    let
      dag2 = init(ChainDAGRef, defaultRuntimeConfig, db, {})

    # check that the state reloaded from database resembles what we had before
    check:
      dag2.tail.root == dag.tail.root
      dag2.head.root == dag.head.root
      dag2.finalizedHead.blck.root == dag.finalizedHead.blck.root
      dag2.finalizedHead.slot == dag.finalizedHead.slot
      hash_tree_root(dag2.headState.data) == hash_tree_root(dag.headState.data)
