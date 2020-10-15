# beacon_chain
# Copyright (c) 2019-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# `block_sim` is a block and attestation simulator similar to `state_sim` whose
# task is to run the beacon chain without considering the network or the
# wall clock. Functionally, it achieves the same as the distributed beacon chain
# by producing blocks and attestations as if they were created by separate
# nodes, just like a set of `beacon_node` instances would.
#
# Similar to `state_sim`, but uses the block and attestation pools along with
# a database, as if a real node was running.

import
  confutils, chronicles, stats, times, strformat,
  options, random, tables, os,
  eth/db/kvstore_sqlite3,
  ../tests/[testblockutil],
  ../beacon_chain/spec/[beaconstate, crypto, datatypes, digest, presets,
                        helpers, validator, signatures, state_transition],
  ../beacon_chain/[
    attestation_pool, beacon_node_types, beacon_chain_db,
    interop, validator_pool],
  ../beacon_chain/block_pools/[
    spec_cache, chain_dag, quarantine, clearance],
  ../beacon_chain/ssz/[merkleization, ssz_serialization],
  ./simutils

type Timers = enum
  tBlock = "Process non-epoch slot with block"
  tEpoch = "Process epoch slot with block"
  tHashBlock = "Tree-hash block"
  tSignBlock = "Sign block"
  tAttest = "Have committee attest to block"
  tReplay = "Replay all produced blocks"

# TODO confutils is an impenetrable black box. how can a help text be added here?
cli do(slots = SLOTS_PER_EPOCH * 6,
       validators = SLOTS_PER_EPOCH * 200, # One per shard is minimum
       attesterRatio {.desc: "ratio of validators that attest in each round"} = 0.82,
       blockRatio {.desc: "ratio of slots with blocks"} = 1.0,
       replay = true):
  let
    state = loadGenesis(validators, true)
    genesisBlock = get_initial_beacon_block(state[].data)
    runtimePreset = defaultRuntimePreset

  echo "Starting simulation..."

  let db = BeaconChainDB.init(runtimePreset, "block_sim_db")
  defer: db.close()

  ChainDAGRef.preInit(db, state[].data, state[].data, genesisBlock)

  var
    chainDag = init(ChainDAGRef, runtimePreset, db)
    quarantine = QuarantineRef()
    attPool = AttestationPool.init(chainDag, quarantine)
    timers: array[Timers, RunningStat]
    attesters: RunningStat
    r = initRand(1)

  let replayState = assignClone(chainDag.headState)

  proc handleAttestations(slot: Slot) =
    let
      attestationHead = chainDag.head.atSlot(slot)

    chainDag.withState(chainDag.tmpState, attestationHead):
      let committees_per_slot =
        get_committee_count_per_slot(state, slot.epoch, cache)

      for committee_index in 0'u64..<committees_per_slot:
        let committee = get_beacon_committee(
          state, slot, committee_index.CommitteeIndex, cache)

        for index_in_committee, validatorIdx in committee:
          if rand(r, 1.0) <= attesterRatio:
            let
              data = makeAttestationData(state, slot, committee_index, blck.root)
              sig =
                get_attestation_signature(state.fork,
                  state.genesis_validators_root,
                  data, hackPrivKey(state.validators[validatorIdx]))
            var aggregation_bits = CommitteeValidatorsBits.init(committee.len)
            aggregation_bits.setBit index_in_committee

            attPool.addAttestation(
              Attestation(
                data: data,
                aggregation_bits: aggregation_bits,
                signature: sig
              ), [validatorIdx].toHashSet(), data.slot)

  proc proposeBlock(slot: Slot) =
    if rand(r, 1.0) > blockRatio:
      return

    let
      head = chainDag.head

    chainDag.withState(chainDag.tmpState, head.atSlot(slot)):
      let
        proposerIdx = get_beacon_proposer_index(state, cache).get()
        privKey = hackPrivKey(state.validators[proposerIdx])
        eth1data = get_eth1data_stub(
          state.eth1_deposit_index, slot.compute_epoch_at_slot())
        message = makeBeaconBlock(
          runtimePreset,
          hashedState,
          proposerIdx,
          head.root,
          privKey.genRandaoReveal(state.fork, state.genesis_validators_root, slot),
          eth1data,
          default(GraffitiBytes),
          attPool.getAttestationsForBlock(state, cache),
          @[],
          @[],
          @[],
          @[],
          noRollback,
          cache)

      var
        newBlock = SignedBeaconBlock(
          message: message.get()
        )

      let blockRoot = withTimerRet(timers[tHashBlock]):
        hash_tree_root(newBlock.message)
      newBlock.root = blockRoot
      # Careful, state no longer valid after here because of the await..
      newBlock.signature = withTimerRet(timers[tSignBlock]):
        get_block_signature(
          state.fork, state.genesis_validators_root, newBlock.message.slot,
          blockRoot, privKey)

      let added = chainDag.addRawBlock(quarantine, newBlock) do (
          blckRef: BlockRef, signedBlock: SignedBeaconBlock,
          epochRef: EpochRef, state: HashedBeaconState):
        # Callback add to fork choice if valid
        attPool.addForkChoice(epochRef, blckRef, signedBlock.message, blckRef.slot)

      blck() = added[]
      chainDag.updateHead(added[], quarantine)

  for i in 0..<slots:
    let
      slot = Slot(i + 1)
      t =
        if slot.isEpoch: tEpoch
        else: tBlock

    if blockRatio > 0.0:
      withTimer(timers[t]):
        proposeBlock(slot)
    if attesterRatio > 0.0:
      withTimer(timers[tAttest]):
        handleAttestations(slot)

    # TODO if attestation pool was smarter, it would include older attestations
    #      too!
    verifyConsensus(chainDag.headState.data.data, attesterRatio * blockRatio)

    if t == tEpoch:
      echo &". slot: {shortLog(slot)} ",
        &"epoch: {shortLog(slot.compute_epoch_at_slot)}"
    else:
      write(stdout, ".")
      flushFile(stdout)

  if replay:
    withTimer(timers[tReplay]):
      var cache = StateCache()
      chainDag.updateStateData(
        replayState[], chainDag.head.atSlot(Slot(slots)), cache)

  echo "Done!"

  printTimers(chainDag.headState.data.data, attesters, true, timers)
