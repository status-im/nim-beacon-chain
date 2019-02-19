import
  confutils,
  json, strformat,
  options, sequtils, random,
  ../tests/[testutil],
  ../beacon_chain/spec/[beaconstate, crypto, datatypes, digest, helpers, validator],
  ../beacon_chain/[attestation_pool, extras, ssz, state_transition, fork_choice]

proc `%`(v: uint64): JsonNode = newJInt(v.BiggestInt)
proc `%`(v: Eth2Digest): JsonNode = newJString($v)
proc `%`(v: ValidatorSig|ValidatorPubKey): JsonNode = newJString($v)

proc writeJson*(prefix, slot, v: auto) =
  var f: File
  defer: close(f)
  discard open(f, fmt"{prefix:04}-{slot:08}.json", fmWrite)
  write(f, pretty(%*(v)))

cli do(slots = 1945,
       validators = SLOTS_PER_EPOCH, # One per shard is minimum
       json_interval = SLOTS_PER_EPOCH,
       prefix = 0,
       attesterRatio {.desc: "ratio of validators that attest in each round"} = 0.0,
       validate = false):
  let
    flags = if validate: {} else: {skipValidation}
    genesisState = get_initial_beacon_state(
      makeInitialDeposits(validators, flags), 0, Eth1Data(), flags)
    genesisBlock = makeGenesisBlock(genesisState)

  var
    attestations: array[MIN_ATTESTATION_INCLUSION_DELAY, seq[Attestation]]
    state = genesisState
    latest_block_root = hash_tree_root_final(genesisBlock)

  var r: Rand
  for i in 0..<slots:
    if state.slot mod json_interval.uint64 == 0:
      writeJson(prefix, state.slot, state)
      write(stdout, ":")
    else:
      write(stdout, ".")

    let
      attestations_idx = state.slot mod MIN_ATTESTATION_INCLUSION_DELAY
      body =  BeaconBlockBody(attestations: attestations[attestations_idx])

    attestations[attestations_idx] = @[]

    latest_block_root = hash_tree_root_final(
      addBlock(state, latest_block_root, body, flags))

    if attesterRatio > 0.0:
      # attesterRatio is the fraction of attesters that actually do their
      # work for every slot - we'll randimize it deterministically to give
      # some variation
      let scass = get_crosslink_committees_at_slot(state, state.slot)

      for scas in scass:
        var
          attestation: Attestation
          first = true

        for v in scas.committee:
          if (rand(r, high(int)).float * attesterRatio).int <= high(int):
            if first:
              attestation = makeAttestation(state, latest_block_root, v)
              first = false
            else:
              attestation.combine(
                makeAttestation(state, latest_block_root, v), flags)

        if not first:
          # add the attestation if any of the validators attested, as given
          # by the randomness. We have to delay when the attestation is
          # actually added to the block per the attestation delay rule!
          attestations[
            (state.slot + MIN_ATTESTATION_INCLUSION_DELAY - 1) mod
              MIN_ATTESTATION_INCLUSION_DELAY].add attestation

    flushFile(stdout)

  echo "done!"

