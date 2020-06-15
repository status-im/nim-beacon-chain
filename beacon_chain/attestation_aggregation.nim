# beacon_chain
# Copyright (c) 2019-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  options, chronicles,
  ./spec/[beaconstate, datatypes, crypto, digest, helpers, validator,
    state_transition_block],
  ./block_pool, ./attestation_pool, ./beacon_node_types, ./ssz

# https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#aggregation-selection
func is_aggregator(state: BeaconState, slot: Slot, index: CommitteeIndex,
    slot_signature: ValidatorSig): bool =
  var cache = get_empty_per_epoch_cache()

  let
    committee = get_beacon_committee(state, slot, index, cache)
    modulo = max(1, len(committee) div TARGET_AGGREGATORS_PER_COMMITTEE).uint64
  bytes_to_int(eth2hash(slot_signature.toRaw()).data[0..7]) mod modulo == 0

proc aggregate_attestations*(
    pool: AttestationPool, state: BeaconState, index: CommitteeIndex,
    privkey: ValidatorPrivKey, trailing_distance: uint64): Option[AggregateAndProof] =
  doAssert state.slot >= trailing_distance

  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/p2p-interface.md#configuration
  doAssert trailing_distance <= ATTESTATION_PROPAGATION_SLOT_RANGE

  let
    slot = state.slot - trailing_distance
    slot_signature = get_slot_signature(
      state.fork, state.genesis_validators_root, slot, privkey)

  doAssert slot + ATTESTATION_PROPAGATION_SLOT_RANGE >= state.slot
  doAssert state.slot >= slot

  # TODO performance issue for future, via get_active_validator_indices(...)
  doAssert index.uint64 < get_committee_count_at_slot(state, slot)

  # TODO for testing purposes, refactor this into the condition check
  # and just calculation
  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#aggregation-selection
  if not is_aggregator(state, slot, index, slot_signature):
    return none(AggregateAndProof)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#attestation-data
  # describes how to construct an attestation, which applies for makeAttestationData(...)
  # TODO this won't actually match anything
  let attestation_data = AttestationData(
    slot: slot,
    index: index.uint64,
    beacon_block_root: get_block_root_at_slot(state, slot))

  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#construct-aggregate
  # TODO once EV goes in w/ refactoring of getAttestationsForBlock, pull out the getSlot version and use
  # it. This is incorrect.
  for attestation in getAttestationsForBlock(pool, state):
    # getAttestationsForBlock(...) already aggregates
    if attestation.data == attestation_data:
      # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#aggregateandproof
      return some(AggregateAndProof(
        aggregator_index: index.uint64,
        aggregate: attestation,
        selection_proof: slot_signature))

  none(AggregateAndProof)

# https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/p2p-interface.md#attestation-subnets
proc isValidAttestation*(
    pool: AttestationPool, attestation: Attestation, current_slot: Slot,
    topicCommitteeIndex: uint64): bool =
  when ETH2_SPEC == "v0.12.1":
    # TODO see validator_duties.sendAttestation() for example of how to derive
    # the 0.12.1 condition data efficiently; even so, might re-order given how
    # this condition's more expensive than rest. REJECT/IGNORE result would be
    # different, but that's reasonable for now:
    #
    # https://github.com/ethereum/eth2.0-specs/blob/v0.12.1/specs/phase0/p2p-interface.md
    # [REJECT] The attestation is for the correct subnet (i.e.
    # compute_subnet_for_attestation(state, attestation) == subnet_id).
    if attestation.data.index != topicCommitteeIndex:
      debug "isValidAttestation: attestation's committee index not for the correct subnet",
        topicCommitteeIndex = topicCommitteeIndex,
        attestation_data_index = attestation.data.index
      return false
  else:
    # The attestation's committee index (attestation.data.index) is for the
    # correct subnet.
    if attestation.data.index != topicCommitteeIndex:
      debug "isValidAttestation: attestation's committee index not for the correct subnet",
        topicCommitteeIndex = topicCommitteeIndex,
        attestation_data_index = attestation.data.index
      return false

  if not (attestation.data.slot + ATTESTATION_PROPAGATION_SLOT_RANGE >=
      current_slot and current_slot >= attestation.data.slot):
    debug "isValidAttestation: attestation.data.slot not within ATTESTATION_PROPAGATION_SLOT_RANGE"
    return false

  # The attestation is unaggregated -- that is, it has exactly one
  # participating validator (len([bit for bit in attestation.aggregation_bits
  # if bit == 0b1]) == 1).
  # TODO a cleverer algorithm, along the lines of countOnes() in nim-stew
  # But that belongs in nim-stew, since it'd break abstraction layers, to
  # use details of its representation from nim-beacon-chain.
  var onesCount = 0
  for aggregation_bit in attestation.aggregation_bits:
    if not aggregation_bit:
      continue
    onesCount += 1
    if onesCount > 1:
      debug "isValidAttestation: attestation has too many aggregation bits",
        aggregation_bits = attestation.aggregation_bits
      return false
  if onesCount != 1:
    debug "isValidAttestation: attestation has too few aggregation bits"
    return false

  # The attestation is the first valid attestation received for the
  # participating validator for the slot, attestation.data.slot.
  let maybeAttestationsSeen = getAttestationsForSlot(pool, attestation.data.slot)
  if maybeAttestationsSeen.isSome:
    for attestationEntry in maybeAttestationsSeen.get.attestations:
      if attestation.data != attestationEntry.data:
        continue
      # Attestations might be aggregated eagerly or lazily; allow for both.
      for validation in attestationEntry.validations:
        if attestation.aggregation_bits.isSubsetOf(validation.aggregation_bits):
          debug "isValidAttestation: attestation already exists at slot",
            attestation_data_slot = attestation.data.slot,
            attestation_aggregation_bits = attestation.aggregation_bits,
            attestation_pool_validation = validation.aggregation_bits
          return false

  # The block being voted for (attestation.data.beacon_block_root) passes
  # validation.
  # We rely on the block pool to have been validated, so check for the
  # existence of the block in the pool.
  # TODO: consider a "slush pool" of attestations whose blocks have not yet
  # propagated - i.e. imagine that attestations are smaller than blocks and
  # therefore propagate faster, thus reordering their arrival in some nodes
  if pool.blockPool.get(attestation.data.beacon_block_root).isNone():
    debug "isValidAttestation: block doesn't exist in block pool",
      attestation_data_beacon_block_root = attestation.data.beacon_block_root
    return false

  # The signature of attestation is valid.
  # TODO need to know above which validator anyway, and this is too general
  # as it supports aggregated attestations (which this can't be)
  var cache = get_empty_per_epoch_cache()
  if not is_valid_indexed_attestation(
      pool.blockPool.headState.data.data,
      get_indexed_attestation(
        pool.blockPool.headState.data.data, attestation, cache), {}):
    debug "isValidAttestation: signature verification failed"
    return false

  true
