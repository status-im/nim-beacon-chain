# beacon_chain
# Copyright (c) 2019-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  options, chronicles,
  ./spec/[
    beaconstate, datatypes, crypto, digest, helpers, network, validator,
    signatures],
  ./block_pools/[spec_cache, chain_dag, quarantine, spec_cache],
  ./attestation_pool, ./beacon_node_types, ./ssz

logScope:
  topics = "att_aggr"

# https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/validator.md#aggregation-selection
func is_aggregator(state: BeaconState, slot: Slot, index: CommitteeIndex,
    slot_signature: ValidatorSig, cache: var StateCache): bool =
  let
    committee_len = get_beacon_committee_len(state, slot, index, cache)
    modulo = max(1'u64, committee_len div TARGET_AGGREGATORS_PER_COMMITTEE)
  bytes_to_uint64(eth2digest(
    slot_signature.toRaw()).data.toOpenArray(0, 7)) mod modulo == 0

proc aggregate_attestations*(
    pool: AttestationPool, state: BeaconState, index: CommitteeIndex,
    validatorIndex: ValidatorIndex, privkey: ValidatorPrivKey,
    cache: var StateCache):
    Option[AggregateAndProof] =
  let
    slot = state.slot
    slot_signature = get_slot_signature(
      state.fork, state.genesis_validators_root, slot, privkey)

  doAssert validatorIndex in get_beacon_committee(state, slot, index, cache)
  doAssert index.uint64 < get_committee_count_per_slot(state, slot.epoch, cache)

  # TODO for testing purposes, refactor this into the condition check
  # and just calculation
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/validator.md#aggregation-selection
  if not is_aggregator(state, slot, index, slot_signature, cache):
    return none(AggregateAndProof)

  let maybe_slot_attestation = getAggregatedAttestation(pool, slot, index)
  if maybe_slot_attestation.isNone:
    return none(AggregateAndProof)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/validator.md#construct-aggregate
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/validator.md#aggregateandproof
  some(AggregateAndProof(
    aggregator_index: validatorIndex.uint64,
    aggregate: maybe_slot_attestation.get,
    selection_proof: slot_signature))

proc isValidAttestationSlot(
    pool: AttestationPool, attestationSlot: Slot, attestationBlck: BlockRef): bool =
  # If we allow voting for very old blocks, the state transaction below will go
  # nuts and keep processing empty slots
  logScope:
    attestationSlot
    attestationBlck = shortLog(attestationBlck)

  if not (attestationBlck.slot > pool.chainDag.finalizedHead.slot):
    debug "Voting for already-finalized block"
    return false

  # we'll also cap it at 4 epochs which is somewhat arbitrary, but puts an
  # upper bound on the processing done to validate the attestation
  # TODO revisit with less arbitrary approach
  if not (attestationSlot >= attestationBlck.slot):
    debug "Voting for block that didn't exist at the time"
    return false

  if not ((attestationSlot - attestationBlck.slot) <= uint64(4 * SLOTS_PER_EPOCH)):
    debug "Voting for very old block"
    return false

  true

func checkPropagationSlotRange(data: AttestationData, current_slot: Slot): bool =
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/p2p-interface.md#beacon_attestation_subnet_id
  # TODO clock disparity of 0.5s instead of whole slot
  # attestation.data.slot + ATTESTATION_PROPAGATION_SLOT_RANGE >=
  # current_slot >= attestation.data.slot
  (data.slot + ATTESTATION_PROPAGATION_SLOT_RANGE + 1 >= current_slot) and
    (current_slot >= data.slot)

# https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/p2p-interface.md#beacon_attestation_subnet_id
proc isValidAttestation*(
    pool: var AttestationPool,
    attestation: Attestation, current_slot: Slot,
    topicCommitteeIndex: uint64): bool =
  logScope:
    topics = "att_aggr valid_att"
    received_attestation = shortLog(attestation)

  # TODO https://github.com/ethereum/eth2.0-specs/issues/1998
  if (let v = check_attestation_slot_target(attestation.data); v.isErr):
    debug "Invalid attestation", err = v.error
    return false

  if not checkPropagationSlotRange(attestation.data, current_slot):
    debug "Attestation slot not in propagation range",
      current_slot
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
      debug "Attestation has too many aggregation bits"
      return false
  if onesCount != 1:
    debug "Attestation has too few aggregation bits"
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
          debug "Attestation already exists at slot",
            attestation_pool_validation = validation.aggregation_bits
          return false

  # The block being voted for (attestation.data.beacon_block_root) passes
  # validation.
  # We rely on the chain DAG to have been validated, so check for the existence
  # of the block in the pool.
  let attestationBlck = pool.chainDag.getRef(attestation.data.beacon_block_root)
  if attestationBlck.isNil:
    debug "Attestation block unknown"
    pool.addUnresolved(attestation)
    pool.quarantine.addMissing(attestation.data.beacon_block_root)
    return false

  if not isValidAttestationSlot(pool, attestation.data.slot, attestationBlck):
    # Not in spec - check that rewinding to the state is sane
    return false

  let tgtBlck = pool.chainDag.getRef(attestation.data.target.root)
  if tgtBlck.isNil:
    debug "Attestation target block unknown"
    pool.addUnresolved(attestation)
    pool.quarantine.addMissing(attestation.data.target.root)
    return false

  # The following rule follows implicitly from that we clear out any
  # unviable blocks from the chain dag:
  #
  # The current finalized_checkpoint is an ancestor of the block defined by
  # attestation.data.beacon_block_root -- i.e. get_ancestor(store,
  # attestation.data.beacon_block_root,
  # compute_start_slot_at_epoch(store.finalized_checkpoint.epoch)) ==
  # store.finalized_checkpoint.root

  let epochRef = pool.chainDag.getEpochRef(
    tgtBlck, attestation.data.target.epoch)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/p2p-interface.md#beacon_attestation_subnet_id
  # [REJECT] The attestation is for the correct subnet -- i.e.
  # compute_subnet_for_attestation(committees_per_slot,
  # attestation.data.slot, attestation.data.index) == subnet_id, where
  # committees_per_slot = get_committee_count_per_slot(state,
  # attestation.data.target.epoch), which may be pre-computed along with the
  # committee information for the signature check.
  let
    requiredSubnetIndex =
      compute_subnet_for_attestation(
        get_committee_count_per_slot(epochRef),
        attestation.data.slot, attestation.data.index.CommitteeIndex)

  if requiredSubnetIndex != topicCommitteeIndex:
    debug "Attestation's committee index not for the correct subnet",
      topicCommitteeIndex = topicCommitteeIndex,
      attestation_data_index = attestation.data.index,
      requiredSubnetIndex = requiredSubnetIndex
    return false

  let
    fork = pool.chainDag.headState.data.data.fork
    genesis_validators_root =
      pool.chainDag.headState.data.data.genesis_validators_root

    # The signature of attestation is valid.
  if (let v = is_valid_indexed_attestation(
      fork, genesis_validators_root,
      epochRef, get_indexed_attestation(epochRef, attestation), {}); v.isErr):
    debug "Attestation verification failed", err = v.error()
    return false

  true

# https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/p2p-interface.md#beacon_aggregate_and_proof
proc isValidAggregatedAttestation*(
    pool: var AttestationPool,
    signedAggregateAndProof: SignedAggregateAndProof,
    current_slot: Slot): bool =
  let
    aggregate_and_proof = signedAggregateAndProof.message
    aggregate = aggregate_and_proof.aggregate

  logScope:
    aggregate = shortLog(aggregate)

  # TODO https://github.com/ethereum/eth2.0-specs/issues/1998
  if (let v = check_attestation_slot_target(aggregate.data); v.isErr):
    debug "Invalid aggregate", err = v.error
    return false

  # There's some overlap between this and isValidAttestation(), but unclear if
  # saving a few lines of code would balance well with losing straightforward,
  # spec-based synchronization.
  #
  # [IGNORE] aggregate.data.slot is within the last
  # ATTESTATION_PROPAGATION_SLOT_RANGE slots (with a
  # MAXIMUM_GOSSIP_CLOCK_DISPARITY allowance) -- i.e. aggregate.data.slot +
  # ATTESTATION_PROPAGATION_SLOT_RANGE >= current_slot >= aggregate.data.slot
  if not checkPropagationSlotRange(aggregate.data, current_slot):
    debug "Aggregate slot not in propagation range"
    return false

  # [IGNORE] The valid aggregate attestation defined by
  # hash_tree_root(aggregate) has not already been seen (via aggregate gossip,
  # within a verified block, or through the creation of an equivalent aggregate
  # locally).
  #
  # This is [IGNORE] and already checked by attestation pool when aggregate is
  # added.

  # [IGNORE] The aggregate is the first valid aggregate received for the
  # aggregator with index aggregate_and_proof.aggregator_index for the epoch
  # aggregate.data.target.epoch.
  #
  # This is [IGNORE] and already effectively checked by attestation pool upon
  # attempting to resolve attestations.

  # [REJECT] The block being voted for (aggregate.data.beacon_block_root)
  # passes validation.
  let attestationBlck = pool.chainDag.getRef(aggregate.data.beacon_block_root)
  if attestationBlck.isNil:
    debug "Aggregate block unknown"
    pool.quarantine.addMissing(aggregate.data.beacon_block_root)
    return false

  # [REJECT] The attestation has participants -- that is,
  # len(get_attesting_indices(state, aggregate.data, aggregate.aggregation_bits)) >= 1.
  #
  # get_attesting_indices() is:
  # committee = get_beacon_committee(state, data.slot, data.index)
  # return set(index for i, index in enumerate(committee) if bits[i])
  #
  # the attestation doesn't have participants is iff either:
  # (1) the aggregation bits are all 0; or
  # (2) the non-zero aggregation bits don't overlap with extant committee
  #     members, i.e. they counts don't match.
  # But (2) would reflect an invalid aggregation in other ways, so reject it
  # either way.
  if isZeros(aggregate.aggregation_bits):
    debug "Aggregate has no or invalid aggregation bits"
    return false

  if not isValidAttestationSlot(pool, aggregate.data.slot, attestationBlck):
    # Not in spec - check that rewinding to the state is sane
    return false

  # [REJECT] aggregate_and_proof.selection_proof selects the validator as an
  # aggregator for the slot -- i.e. is_aggregator(state, aggregate.data.slot,
  # aggregate.data.index, aggregate_and_proof.selection_proof) returns True.
  let tgtBlck = pool.chainDag.getRef(aggregate.data.target.root)
  if tgtBlck.isNil:
    debug "Aggregate target block unknown"
    pool.quarantine.addMissing(aggregate.data.target.root)
    return

  let epochRef = pool.chainDag.getEpochRef(tgtBlck, aggregate.data.target.epoch)

  if not is_aggregator(
      epochRef, aggregate.data.slot, aggregate.data.index.CommitteeIndex,
      aggregate_and_proof.selection_proof):
    debug "Incorrect aggregator"
    return false

  # [REJECT] The aggregator's validator index is within the committee -- i.e.
  # aggregate_and_proof.aggregator_index in get_beacon_committee(state,
  # aggregate.data.slot, aggregate.data.index).
  if aggregate_and_proof.aggregator_index.ValidatorIndex notin
      get_beacon_committee(
        epochRef, aggregate.data.slot, aggregate.data.index.CommitteeIndex):
    debug "Aggregator's validator index not in committee"
    return false

  # [REJECT] The aggregate_and_proof.selection_proof is a valid signature of the
  # aggregate.data.slot by the validator with index
  # aggregate_and_proof.aggregator_index.
  # get_slot_signature(state, aggregate.data.slot, privkey)
  if aggregate_and_proof.aggregator_index >= epochRef.validator_keys.lenu64:
    debug "Invalid aggregator_index"
    return false

  let
    fork = pool.chainDag.headState.data.data.fork
    genesis_validators_root =
      pool.chainDag.headState.data.data.genesis_validators_root
  if not verify_slot_signature(
      fork, genesis_validators_root, aggregate.data.slot,
      epochRef.validator_keys[aggregate_and_proof.aggregator_index],
      aggregate_and_proof.selection_proof):
    debug "Selection_proof signature verification failed"
    return false

  # [REJECT] The aggregator signature, signed_aggregate_and_proof.signature, is valid.
  if not verify_aggregate_and_proof_signature(
      fork, genesis_validators_root, aggregate_and_proof,
      epochRef.validator_keys[aggregate_and_proof.aggregator_index],
      signed_aggregate_and_proof.signature):
    debug "signed_aggregate_and_proof signature verification failed"
    return false

  # [REJECT] The signature of aggregate is valid.
  if (let v = is_valid_indexed_attestation(
      fork, genesis_validators_root,
      epochRef, get_indexed_attestation(epochRef, aggregate), {}); v.isErr):
    debug "Aggregate verification failed", err = v.error()
    return false

  # The following rule follows implicitly from that we clear out any
  # unviable blocks from the chain dag:
  #
  # The current finalized_checkpoint is an ancestor of the block defined by
  # aggregate.data.beacon_block_root -- i.e. get_ancestor(store,
  # aggregate.data.beacon_block_root,
  # compute_start_slot_at_epoch(store.finalized_checkpoint.epoch)) ==
  # store.finalized_checkpoint.root

  true
