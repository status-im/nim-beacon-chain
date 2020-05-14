# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  ../beacon_chain/spec/datatypes,
  ../beacon_chain/ssz

import
  unittest,
  chronicles,
  stew/byteutils,
  ./testutil, ./testblockutil,
  ../beacon_chain/spec/[digest, validator],
  ../beacon_chain/[beacon_node_types, attestation_pool, block_pool, state_transition]

proc main() =
  suiteReport "Attestation pool processing" & preset():
    ## For now just test that we can compile and execute block processing with
    ## mock data.
    setup: # ref to avoid stack overflow
      var pool: ref AttestationPool
      new pool

      var state: ref StateData
      new state

      # Genesis state that results in 3 members per committee
      var blockPool = BlockPool.init(makeTestDB(SLOTS_PER_EPOCH * 3))
      pool[] = AttestationPool.init(blockPool, blockPool.finalizedHead)
      state[] = loadTailState(blockPool)
      # Slot 0 is a finalized slot - won't be making attestations for it..
      process_slots(state.data, state.data.data.slot + 1)

      pool[].add(blockPool.tail) # Make the tail known to fork choice

    timedTest "Can add and retrieve simple attestation" & preset():
      var cache = get_empty_per_epoch_cache()
      let
        # Create an attestation for slot 1!
        beacon_committee = get_beacon_committee(
          state.data.data[], state.data.data.slot, 0.CommitteeIndex, cache)
        attestation = makeAttestation(
          state.data.data[], state.blck.root, beacon_committee[0], cache)

      pool[].add(attestation)

      process_slots(state.data, MIN_ATTESTATION_INCLUSION_DELAY.Slot + 1)

      let attestations = pool[].getAttestationsForBlock(state.data.data[])

      check:
        attestations.len == 1

    timedTest "Attestations may arrive in any order" & preset():
      var cache = get_empty_per_epoch_cache()
      let
        # Create an attestation for slot 1!
        bc0 = get_beacon_committee(
          state.data.data[], state.data.data.slot, 0.CommitteeIndex, cache)
        attestation0 = makeAttestation(
          state.data.data[], state.blck.root, bc0[0], cache)

      process_slots(state.data, state.data.data.slot + 1)

      let
        bc1 = get_beacon_committee(state.data.data[],
          state.data.data.slot, 0.CommitteeIndex, cache)
        attestation1 = makeAttestation(
          state.data.data[], state.blck.root, bc1[0], cache)

      # test reverse order
      pool[].add(attestation1)
      pool[].add(attestation0)

      process_slots(state.data, MIN_ATTESTATION_INCLUSION_DELAY.Slot + 1)

      let attestations = pool[].getAttestationsForBlock(state.data.data[])

      check:
        attestations.len == 1

    timedTest "Attestations should be combined" & preset():
      var cache = get_empty_per_epoch_cache()
      let
        # Create an attestation for slot 1!
        bc0 = get_beacon_committee(
          state.data.data[], state.data.data.slot, 0.CommitteeIndex, cache)
        attestation0 = makeAttestation(
          state.data.data[], state.blck.root, bc0[0], cache)
        attestation1 = makeAttestation(
          state.data.data[], state.blck.root, bc0[1], cache)

      pool[].add(attestation0)
      pool[].add(attestation1)

      process_slots(state.data, MIN_ATTESTATION_INCLUSION_DELAY.Slot + 1)

      let attestations = pool[].getAttestationsForBlock(state.data.data[])

      check:
        attestations.len == 1

    timedTest "Attestations may overlap, bigger first" & preset():
      var cache = get_empty_per_epoch_cache()

      var
        # Create an attestation for slot 1!
        bc0 = get_beacon_committee(
          state.data.data[], state.data.data.slot, 0.CommitteeIndex, cache)
        attestation0 = makeAttestation(
          state.data.data[], state.blck.root, bc0[0], cache)
        attestation1 = makeAttestation(
          state.data.data[], state.blck.root, bc0[1], cache)

      attestation0.combine(attestation1, {})

      pool[].add(attestation0)
      pool[].add(attestation1)

  setup:
    # Genesis state that results in 3 members per committee
    var
      blockPool = BlockPool.init(makeTestDB(SLOTS_PER_EPOCH * 3))
      pool = AttestationPool.init(blockPool)
      state = newClone(loadTailState(blockPool))
    # Slot 0 is a finalized slot - won't be making attestations for it..
    process_slots(state.data, state.data.data.slot + 1)

  timedTest "Can add and retrieve simple attestation" & preset():
    var cache = get_empty_per_epoch_cache()
    let
      # Create an attestation for slot 1!
      beacon_committee = get_beacon_committee(
        state.data.data, state.data.data.slot, 0.CommitteeIndex, cache)
      attestation = makeAttestation(
        state.data.data, state.blck.root, beacon_committee[0], cache)

    pool.add(attestation)

<<<<<<< HEAD
    process_slots(state.data, MIN_ATTESTATION_INCLUSION_DELAY.Slot + 1)

    let attestations = pool.getAttestationsForBlock(state.data.data)
=======
      let attestations = pool[].getAttestationsForBlock(state.data.data[])
>>>>>>> f045519... Use ProtoArray fork choice

    check:
      attestations.len == 1

  timedTest "Attestations may arrive in any order" & preset():
    var cache = get_empty_per_epoch_cache()
    let
      # Create an attestation for slot 1!
      bc0 = get_beacon_committee(
        state.data.data, state.data.data.slot, 0.CommitteeIndex, cache)
      attestation0 = makeAttestation(
        state.data.data, state.blck.root, bc0[0], cache)

    process_slots(state.data, state.data.data.slot + 1)

    let
      bc1 = get_beacon_committee(state.data.data,
        state.data.data.slot, 0.CommitteeIndex, cache)
      attestation1 = makeAttestation(
        state.data.data, state.blck.root, bc1[0], cache)

    # test reverse order
    pool.add(attestation1)
    pool.add(attestation0)

    process_slots(state.data, MIN_ATTESTATION_INCLUSION_DELAY.Slot + 1)

    let attestations = pool.getAttestationsForBlock(state.data.data)

    check:
      attestations.len == 1

  timedTest "Attestations should be combined" & preset():
    var cache = get_empty_per_epoch_cache()
    let
      # Create an attestation for slot 1!
      bc0 = get_beacon_committee(
        state.data.data, state.data.data.slot, 0.CommitteeIndex, cache)
      attestation0 = makeAttestation(
        state.data.data, state.blck.root, bc0[0], cache)
      attestation1 = makeAttestation(
        state.data.data, state.blck.root, bc0[1], cache)

    pool.add(attestation0)
    pool.add(attestation1)

    process_slots(state.data, MIN_ATTESTATION_INCLUSION_DELAY.Slot + 1)

    let attestations = pool.getAttestationsForBlock(state.data.data)

    check:
      attestations.len == 1

  timedTest "Attestations may overlap, bigger first" & preset():
    var cache = get_empty_per_epoch_cache()

    var
      # Create an attestation for slot 1!
      bc0 = get_beacon_committee(
        state.data.data, state.data.data.slot, 0.CommitteeIndex, cache)
      attestation0 = makeAttestation(
        state.data.data, state.blck.root, bc0[0], cache)
      attestation1 = makeAttestation(
        state.data.data, state.blck.root, bc0[1], cache)

    attestation0.combine(attestation1, {})

    pool.add(attestation0)
    pool.add(attestation1)

    process_slots(state.data, MIN_ATTESTATION_INCLUSION_DELAY.Slot + 1)

<<<<<<< HEAD
    let attestations = pool.getAttestationsForBlock(state.data.data)
=======
      pool[].add(attestation1)
      pool[].add(attestation0)
>>>>>>> f045519... Use ProtoArray fork choice

    check:
      attestations.len == 1

<<<<<<< HEAD
  timedTest "Attestations may overlap, smaller first" & preset():
    var cache = get_empty_per_epoch_cache()
    var
      # Create an attestation for slot 1!
      bc0 = get_beacon_committee(state.data.data,
        state.data.data.slot, 0.CommitteeIndex, cache)
      attestation0 = makeAttestation(
        state.data.data, state.blck.root, bc0[0], cache)
      attestation1 = makeAttestation(
        state.data.data, state.blck.root, bc0[1], cache)
=======
      let attestations = pool[].getAttestationsForBlock(state.data.data[])
>>>>>>> f045519... Use ProtoArray fork choice

    attestation0.combine(attestation1, {})

<<<<<<< HEAD
    pool.add(attestation1)
    pool.add(attestation0)
=======
    timedTest "Fork choice returns latest block with no attestations":
      let
        b1 = addTestBlock(state.data.data[], blockPool.tail.root)
        b1Root = hash_tree_root(b1.message)
        b1Add = blockPool.add(b1Root, b1)

      pool[].add(b1Add)
      let head = pool[].selectHead()
>>>>>>> f045519... Use ProtoArray fork choice

    process_slots(state.data, MIN_ATTESTATION_INCLUSION_DELAY.Slot + 1)

<<<<<<< HEAD
    let attestations = pool.getAttestationsForBlock(state.data.data)
=======
      let
        b2 = addTestBlock(state.data.data[], b1Root)
        b2Root = hash_tree_root(b2.message)
        b2Add = blockPool.add(b2Root, b2)

      pool[].add(b2Add)
      let head2 = pool[].selectHead()
>>>>>>> f045519... Use ProtoArray fork choice

    check:
      attestations.len == 1

<<<<<<< HEAD
  timedTest "Fork choice returns latest block with no attestations":
    let
      b1 = addTestBlock(state.data.data, blockPool.tail.root)
      b1Root = hash_tree_root(b1.message)
      b1Add = blockPool.add(b1Root, b1)
      head = pool.selectHead()
=======
    timedTest "Fork choice returns block with attestation":
      var cache = get_empty_per_epoch_cache()
      let
        b10 = makeTestBlock(state.data.data[], blockPool.tail.root)
        b10Root = hash_tree_root(b10.message)
        b10Add = blockPool.add(b10Root, b10)

      pool[].add(b10Add)
      let head = pool[].selectHead()
>>>>>>> f045519... Use ProtoArray fork choice

    check:
      head == b1Add

    let
      b2 = addTestBlock(state.data.data, b1Root)
      b2Root = hash_tree_root(b2.message)
      b2Add = blockPool.add(b2Root, b2)
      head2 = pool.selectHead()

    check:
      head2 == b2Add

<<<<<<< HEAD
  timedTest "Fork choice returns block with attestation":
    var cache = get_empty_per_epoch_cache()
    let
      b10 = makeTestBlock(state.data.data, blockPool.tail.root)
      b10Root = hash_tree_root(b10.message)
      b10Add = blockPool.add(b10Root, b10)
      head = pool.selectHead()

    check:
      head == b10Add
=======
      pool[].add(b11Add)
      pool[].add(attestation0)

      let head2 = pool[].selectHead()
>>>>>>> f045519... Use ProtoArray fork choice

    let
      b11 = makeTestBlock(state.data.data, blockPool.tail.root,
        graffiti = Eth2Digest(data: [1'u8, 0, 0, 0 ,0 ,0 ,0 ,0 ,0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
      )
      b11Root = hash_tree_root(b11.message)
      b11Add = blockPool.add(b11Root, b11)

<<<<<<< HEAD
      bc1 = get_beacon_committee(
        state.data.data, state.data.data.slot, 1.CommitteeIndex, cache)
      attestation0 = makeAttestation(state.data.data, b10Root, bc1[0], cache)

    pool.add(attestation0)

    let head2 = pool.selectHead()

    check:
      # Single vote for b10 and no votes for b11
      head2 == b10Add

    let
      attestation1 = makeAttestation(state.data.data, b11Root, bc1[1], cache)
      attestation2 = makeAttestation(state.data.data, b11Root, bc1[2], cache)
    pool.add(attestation1)

    let head3 = pool.selectHead()
    let smaller = if b10Root.data < b11Root.data: b10Add else: b11Add

    check:
      # Ties broken lexicographically
      head3 == smaller

    pool.add(attestation2)

    let head4 = pool.selectHead()

    check:
      # Two votes for b11
      head4 == b11Add
=======
      let
        attestation1 = makeAttestation(state.data.data[], b11Root, bc1[1], cache)
        attestation2 = makeAttestation(state.data.data[], b11Root, bc1[2], cache)
      pool[].add(attestation1)

      let head3 = pool[].selectHead()
      let bigger = if b10Root.data > b11Root.data: b10Add else: b11Add

      check:
        # Ties broken lexicographically in spec -> ?
        # all implementations favor the biggest root
        head3 == bigger

      pool[].add(attestation2)

      let head4 = pool[].selectHead()

      check:
        # Two votes for b11
        head4 == b11Add

main()
>>>>>>> f045519... Use ProtoArray fork choice
