# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or https://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or https://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import  options, unittest, sequtils,
  ../beacon_chain/[beacon_chain_db, extras, interop, ssz, state_transition],
  ../beacon_chain/spec/[beaconstate, datatypes, digest, crypto],
  eth/db/kvstore,
  # test utilies
  ./testutil, ./testblockutil

proc getStateRef(db: BeaconChainDB, root: Eth2Digest): NilableBeaconStateRef =
  let res = BeaconStateRef()
  if db.getState(root, res[], noRollback):
    return res

suiteReport "Beacon chain DB" & preset():
  timedTest "empty database" & preset():
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())
    check:
      db.getStateRef(Eth2Digest()).isNil
      db.getBlock(Eth2Digest()).isNone

  timedTest "sanity check blocks" & preset():
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())

    let
      signedBlock = SignedBeaconBlock()
      root = hash_tree_root(signedBlock.message)

    db.putBlock(signedBlock)

    check:
      db.containsBlock(root)
      db.getBlock(root).get() == signedBlock

    db.putStateRoot(root, signedBlock.message.slot, root)
    check:
      db.getStateRoot(root, signedBlock.message.slot).get() == root

  timedTest "sanity check states" & preset():
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())

    let
      state = BeaconStateRef()
      root = hash_tree_root(state)

    db.putState(state[])

    check:
      db.containsState(root)
      db.getStateRef(root)[] == state[]

  timedTest "find ancestors" & preset():
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())

    let
      a0 = SignedBeaconBlock(message: BeaconBlock(slot: GENESIS_SLOT + 0))
      a0r = hash_tree_root(a0.message)
      a1 = SignedBeaconBlock(message:
        BeaconBlock(slot: GENESIS_SLOT + 1, parent_root: a0r))
      a1r = hash_tree_root(a1.message)
      a2 = SignedBeaconBlock(message:
        BeaconBlock(slot: GENESIS_SLOT + 2, parent_root: a1r))
      a2r = hash_tree_root(a2.message)

    doAssert toSeq(db.getAncestors(a0r)) == []
    doAssert toSeq(db.getAncestors(a2r)) == []

    db.putBlock(a2)

    doAssert toSeq(db.getAncestors(a0r)) == []
    doAssert toSeq(db.getAncestors(a2r)) == [(a2r, a2)]

    db.putBlock(a1)

    doAssert toSeq(db.getAncestors(a0r)) == []
    doAssert toSeq(db.getAncestors(a2r)) == [(a2r, a2), (a1r, a1)]

    db.putBlock(a0)

    doAssert toSeq(db.getAncestors(a0r)) == [(a0r, a0)]
    doAssert toSeq(db.getAncestors(a2r)) == [(a2r, a2), (a1r, a1), (a0r, a0)]

  timedTest "sanity check genesis roundtrip" & preset():
    # This is a really dumb way of checking that we can roundtrip a genesis
    # state. We've been bit by this because we've had a bug in the BLS
    # serialization where an all-zero default-initialized bls signature could
    # not be deserialized because the deserialization was too strict.
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())

    let
      state = initialize_beacon_state_from_eth1(
        eth1BlockHash, 0, makeInitialDeposits(SLOTS_PER_EPOCH), {skipBlsValidation})
      root = hash_tree_root(state)

    db.putState(state[])

    check:
      db.containsState(root)
      db.getStateRef(root)[] == state[]
