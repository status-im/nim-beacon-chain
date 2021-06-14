# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or https://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or https://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/[algorithm, options, sequtils],
  unittest2, ssz_serialization,
  ../beacon_chain/[beacon_chain_db, extras, interop],
  ../beacon_chain/spec/[
    beaconstate, crypto, datatypes, digest, forkedbeaconstate_helpers, presets,
    state_transition],
  ../beacon_chain/consensus_object_pools/blockchain_dag,
  ../beacon_chain/ssz/spec_types,
  eth/db/kvstore,
  # test utilies
  ./testutil, ./testdbutil, ./testblockutil, ./teststateutil

when isMainModule:
  import chronicles # or some random compile error happens...

proc getStateRef(db: BeaconChainDB, root: Eth2Digest): NilableBeaconStateRef =
  # load beaconstate the way the block pool does it - into an existing instance
  let res = BeaconStateRef()
  if db.getState(root, res[], noRollback):
    return res

func withDigest(blck: TrustedBeaconBlock): TrustedSignedBeaconBlock =
  TrustedSignedBeaconBlock(
    message: blck,
    root: hash_tree_root(blck)
  )

suite "Beacon chain DB" & preset():
  test "empty database" & preset():
    var
      db = BeaconChainDB.new(defaultRuntimePreset, "", inMemory = true)
    check:
      db.getStateRef(Eth2Digest()).isNil
      db.getBlock(Eth2Digest()).isNone

  test "sanity check blocks" & preset():
    var
      db = BeaconChainDB.new(defaultRuntimePreset, "", inMemory = true)

    let
      signedBlock = withDigest(TrustedBeaconBlock())
      root = hash_tree_root(signedBlock.message)

    db.putBlock(signedBlock)

    check:
      db.containsBlock(root)
      db.getBlock(root).get() == signedBlock

    db.putStateRoot(root, signedBlock.message.slot, root)
    var root2 = root
    root2.data[0] = root.data[0] + 1
    db.putStateRoot(root, signedBlock.message.slot + 1, root2)

    check:
      db.getStateRoot(root, signedBlock.message.slot).get() == root
      db.getStateRoot(root, signedBlock.message.slot + 1).get() == root2

    db.close()

  test "sanity check states" & preset():
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimePreset, db)
      testStates = getTestStates(dag.headState.data)

    # Ensure transitions beyond just adding validators and increasing slots
    sort(testStates) do (x, y: ref ForkedHashedBeaconState) -> int:
      cmp($getStateRoot(x[]), $getStateRoot(y[]))

    for state in testStates:
      db.putState(state[].hbsPhase0.data)
      let root = hash_tree_root(state[])

      check:
        db.containsState(root)
        hash_tree_root(db.getStateRef(root)[]) == root

      db.delState(root)
      check: not db.containsState(root)

    db.close()

  test "sanity check states, reusing buffers" & preset():
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimePreset, db)

    let stateBuffer = BeaconStateRef()
    var testStates = getTestStates(dag.headState.data)

    # Ensure transitions beyond just adding validators and increasing slots
    sort(testStates) do (x, y: ref ForkedHashedBeaconState) -> int:
      cmp($getStateRoot(x[]), $getStateRoot(y[]))

    for state in testStates:
      db.putState(state[].hbsPhase0.data)
      let root = hash_tree_root(state[])

      check:
        db.getState(root, stateBuffer[], noRollback)
        db.containsState(root)
        hash_tree_root(stateBuffer[]) == root

      db.delState(root)
      check: not db.containsState(root)

    db.close()

  test "find ancestors" & preset():
    var
      db = BeaconChainDB.new(defaultRuntimePreset, "", inMemory = true)

    let
      a0 = withDigest(
        TrustedBeaconBlock(slot: GENESIS_SLOT + 0))
      a1 = withDigest(
        TrustedBeaconBlock(slot: GENESIS_SLOT + 1, parent_root: a0.root))
      a2 = withDigest(
        TrustedBeaconBlock(slot: GENESIS_SLOT + 2, parent_root: a1.root))

    doAssert toSeq(db.getAncestors(a0.root)) == []
    doAssert toSeq(db.getAncestors(a2.root)) == []

    doAssert toSeq(db.getAncestorSummaries(a0.root)).len == 0
    doAssert toSeq(db.getAncestorSummaries(a2.root)).len == 0

    db.putBlock(a2)

    doAssert toSeq(db.getAncestors(a0.root)) == []
    doAssert toSeq(db.getAncestors(a2.root)) == [a2]

    doAssert toSeq(db.getAncestorSummaries(a0.root)).len == 0
    doAssert toSeq(db.getAncestorSummaries(a2.root)).len == 1

    db.putBlock(a1)

    doAssert toSeq(db.getAncestors(a0.root)) == []
    doAssert toSeq(db.getAncestors(a2.root)) == [a2, a1]

    doAssert toSeq(db.getAncestorSummaries(a0.root)).len == 0
    doAssert toSeq(db.getAncestorSummaries(a2.root)).len == 2

    db.putBlock(a0)

    doAssert toSeq(db.getAncestors(a0.root)) == [a0]
    doAssert toSeq(db.getAncestors(a2.root)) == [a2, a1, a0]

    doAssert toSeq(db.getAncestorSummaries(a0.root)).len == 1
    doAssert toSeq(db.getAncestorSummaries(a2.root)).len == 3

  test "sanity check genesis roundtrip" & preset():
    # This is a really dumb way of checking that we can roundtrip a genesis
    # state. We've been bit by this because we've had a bug in the BLS
    # serialization where an all-zero default-initialized bls signature could
    # not be deserialized because the deserialization was too strict.
    var
      db = BeaconChainDB.new(defaultRuntimePreset, "", inMemory = true)

    let
      state = initialize_beacon_state_from_eth1(
        defaultRuntimePreset, eth1BlockHash, 0,
        makeInitialDeposits(SLOTS_PER_EPOCH), {skipBlsValidation})
      root = hash_tree_root(state[])

    db.putState(state[])

    check db.containsState(root)
    let state2 = db.getStateRef(root)
    db.delState(root)
    check not db.containsState(root)
    db.close()

    check:
      hash_tree_root(state2[]) == root

  test "sanity check state diff roundtrip" & preset():
    var
      db = BeaconChainDB.new(defaultRuntimePreset, "", inMemory = true)

    # TODO htr(diff) probably not interesting/useful, but stand-in
    let
      stateDiff = BeaconStateDiff()
      root = hash_tree_root(stateDiff)

    db.putStateDiff(root, stateDiff)

    let state2 = db.getStateDiff(root)
    db.delStateDiff(root)
    check db.getStateDiff(root).isNone()
    db.close()

    check:
      hash_tree_root(state2[]) == root
