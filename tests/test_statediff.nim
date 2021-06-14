# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/[options, sequtils],
  unittest2, ssz_serialization,
  ./testutil, ./testdbutil, ./teststateutil,
  ../beacon_chain/spec/[
    datatypes, digest, forkedbeaconstate_helpers, helpers, presets],
  ../beacon_chain/[beacon_node_types, statediff],
  ../beacon_chain/consensus_object_pools/[blockchain_dag, block_quarantine]

when isMainModule:
  import chronicles # or some random compile error happens...

suite "state diff tests" & preset():
  setup:
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimePreset, db)

  test "random slot differences" & preset():
    let testStates = getTestStates(dag.headState.data)

    for i in 0 ..< testStates.len:
      for j in (i+1) ..< testStates.len:
        doAssert getStateField(testStates[i][], slot) <
          getStateField(testStates[j][], slot)
        if getStateField(testStates[i][], slot) + SLOTS_PER_EPOCH != getStateField(testStates[j][], slot):
          continue
        var tmpStateApplyBase = assignClone(testStates[i].hbsPhase0.data)
        let diff = diffStates(
          testStates[i].hbsPhase0.data, testStates[j].hbsPhase0.data)
        # Immutable parts of validators stored separately, so aren't part of
        # the state diff. Synthesize required portion here for testing.
        applyDiff(
          tmpStateApplyBase[],
          mapIt(
            getStateField(testStates[j][], validators).asSeq[
              getStateField(testStates[i][], validators).len ..
              getStateField(testStates[j][], validators).len - 1],
            it.getImmutableValidatorData),
          diff)
        check hash_tree_root(testStates[j][]) ==
          hash_tree_root(tmpStateApplyBase[])
