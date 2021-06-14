# beacon_chain
# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# `state_sim` runs the state transition function in isolation, creating blocks
# and attesting to them as if the network was running as a whole.

import
  confutils, stats, times,
  strformat,
  options, sequtils, random, tables,
  ssz_serialization,
  ../tests/testblockutil,
  ../beacon_chain/spec/[
   beaconstate, crypto, datatypes, digest, forkedbeaconstate_helpers, helpers],
  ../beacon_chain/extras,
  ./simutils

type Timers = enum
  tBlock = "Process non-epoch slot with block"
  tEpoch = "Process epoch slot with block"
  tHashBlock = "Tree-hash block"
  tShuffle = "Retrieve committee once using get_beacon_committee"
  tAttest = "Combine committee attestations"

proc jsonName(prefix, slot: auto): string =
  fmt"{prefix:04}-{shortLog(slot):08}.json"

proc writeJson*(fn, v: auto) =
  var f: File
  defer: close(f)
  Json.saveFile(fn, v, pretty = true)

cli do(slots = SLOTS_PER_EPOCH * 5,
       validators = SLOTS_PER_EPOCH * 400, # One per shard is minimum
       json_interval = SLOTS_PER_EPOCH,
       write_last_json = false,
       prefix: int = 0,
       attesterRatio {.desc: "ratio of validators that attest in each round"} = 0.82,
       validate = true):
  let
    flags = if validate: {} else: {skipBlsValidation}
    (hashedState, _) = loadGenesis(validators, validate)
    genesisBlock = get_initial_beacon_block(hashedState.data)
    state = (ref ForkedHashedBeaconState)(
      hbsPhase0: hashedState[], beaconStateFork: forkPhase0)

  echo "Starting simulation..."

  var
    attestations = initTable[Slot, seq[Attestation]]()
    latest_block_root = hash_tree_root(genesisBlock.message)
    timers: array[Timers, RunningStat]
    attesters: RunningStat
    r = initRand(1)
    signedBlock: SignedBeaconBlock
    cache = StateCache()

  proc maybeWrite(last: bool) =
    if write_last_json:
      if getStateField(state[], slot) mod json_interval.uint64 == 0:
        write(stdout, ":")
      else:
        write(stdout, ".")

      if last:
        writeJson("state.json", state[].hbsPhase0)
    else:
      if getStateField(state[], slot) mod json_interval.uint64 == 0:
        writeJson(jsonName(prefix, getStateField(state[], slot)), state[].hbsPhase0.data)
        write(stdout, ":")
      else:
        write(stdout, ".")

  # TODO doAssert against this up-front
  # indexed attestation: validator index beyond max validators per committee
  # len(indices) <= MAX_VALIDATORS_PER_COMMITTEE

  for i in 0..<slots:
    maybeWrite(false)
    verifyConsensus(state[].hbsPhase0.data, attesterRatio)

    let
      attestations_idx = getStateField(state[], slot)
      blockAttestations = attestations.getOrDefault(attestations_idx)

    attestations.del attestations_idx
    doAssert attestations.lenu64 <=
      SLOTS_PER_EPOCH + MIN_ATTESTATION_INCLUSION_DELAY

    let t =
      if (getStateField(state[], slot) > GENESIS_SLOT and
        (getStateField(state[], slot) + 1).isEpoch): tEpoch
      else: tBlock

    withTimer(timers[t]):
      signedBlock = addTestBlock(
        state[], latest_block_root, cache, attestations = blockAttestations,
        flags = flags)
    latest_block_root = withTimerRet(timers[tHashBlock]):
      hash_tree_root(signedBlock.message)
    signedBlock.root = latest_block_root

    if attesterRatio > 0.0:
      # attesterRatio is the fraction of attesters that actually do their
      # work for every slot - we'll randomize it deterministically to give
      # some variation
      let
        target_slot = getStateField(state[], slot) + MIN_ATTESTATION_INCLUSION_DELAY - 1
        committees_per_slot =
          get_committee_count_per_slot(state[], target_slot.epoch, cache)

      let
        scass = withTimerRet(timers[tShuffle]):
          mapIt(
            0 ..< committees_per_slot.int,
            get_beacon_committee(state[], target_slot, it.CommitteeIndex, cache))

      for i, scas in scass:
        var
          attestation: Attestation
          first = true

        attesters.push scas.len()

        withTimer(timers[tAttest]):
          var agg {.noInit.}: AggregateSignature
          for v in scas:
            if (rand(r, high(int)).float * attesterRatio).int <= high(int):
              if first:
                attestation =
                  makeAttestation(state[], latest_block_root, scas, target_slot,
                    i.CommitteeIndex, v, cache, flags)
                agg.init(attestation.signature.load.get())
                first = false
              else:
                let att2 =
                  makeAttestation(state[], latest_block_root, scas, target_slot,
                    i.CommitteeIndex, v, cache, flags)
                if not att2.aggregation_bits.overlaps(attestation.aggregation_bits):
                  attestation.aggregation_bits.incl(att2.aggregation_bits)
                  if skipBlsValidation notin flags:
                    agg.aggregate(att2.signature.load.get())
          attestation.signature = agg.finish().toValidatorSig()

        if not first:
          # add the attestation if any of the validators attested, as given
          # by the randomness. We have to delay when the attestation is
          # actually added to the block per the attestation delay rule!
          let target_slot =
            attestation.data.slot + MIN_ATTESTATION_INCLUSION_DELAY - 1

          doAssert target_slot > attestations_idx
          var target_slot_attestations =
            getOrDefault(attestations, target_slot)
          target_slot_attestations.add attestation
          attestations[target_slot] = target_slot_attestations

    flushFile(stdout)

    if getStateField(state[], slot).isEpoch:
      echo &" slot: {shortLog(getStateField(state[], slot))} ",
        &"epoch: {shortLog(state[].get_current_epoch())}"


  maybeWrite(true) # catch that last state as well..

  echo "Done!"

  printTimers(state[].hbsPhase0.data, attesters, validate, timers)
