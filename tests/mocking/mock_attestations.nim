# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Mocking attestations
# ---------------------------------------------------------------

import
  # Standard library
  intsets,
  # Status
  chronicles,
  # Specs
  ../../beacon_chain/spec/[datatypes, beaconstate, helpers, validator, crypto,
                           signatures, presets],
  # Mocking procs
  ./mock_blocks,
  ./mock_validator_keys

proc mockAttestationData(
       state: BeaconState,
       slot: Slot,
       index: uint64): AttestationData =
  doAssert state.slot >= slot

  if slot == state.slot:
    result.beacon_block_root = mockBlockForNextSlot(state).message.parent_root
  else:
    result.beacon_block_root = get_block_root_at_slot(state, slot)

  let current_epoch_start_slot = state.get_current_epoch().compute_start_slot_at_epoch()
  let epoch_boundary_root = block:
    if slot < current_epoch_start_slot:
      get_block_root(state, get_previous_epoch(state))
    elif slot == current_epoch_start_slot:
      result.beacon_block_root
    else:
      get_block_root(state, get_current_epoch(state))

  if slot < current_epoch_start_slot:
    result.source = state.previous_justified_checkpoint
  else:
    result.source = state.current_justified_checkpoint

  let target_epoch = compute_epoch_at_slot(slot)

  result.slot = slot
  result.index = index

  result.target = Checkpoint(
    epoch: target_epoch, root: epoch_boundary_root
  )

proc signMockAttestation*(state: BeaconState, attestation: var Attestation) =
  var cache = StateCache()

  var agg {.noInit.}: AggregateSignature
  var first_iter = true # Can't do while loop on hashset
  for validator_index in get_attesting_indices(
        state,
        attestation.data,
        attestation.aggregation_bits,
        cache
      ):
    let sig = get_attestation_signature(
      state.fork, state.genesis_validators_root, attestation.data,
      MockPrivKeys[validator_index]
    )
    if first_iter:
      agg.init(sig)
      first_iter = false
    else:
      agg.aggregate(sig)

  if first_iter != true:
    attestation.signature = agg.finish().toValidatorSig()
    # Otherwise no participants so zero sig

proc mockAttestationImpl(
       state: BeaconState,
       slot: Slot): Attestation =

  var cache = StateCache()

  let
    beacon_committee = get_beacon_committee(
      state,
      result.data.slot,
      result.data.index.CommitteeIndex,
      cache
    )
    committee_size = beacon_committee.len

  result.data = mockAttestationData(state, slot, 0)
  result.aggregation_bits = init(CommitteeValidatorsBits, committee_size)

  # fillAggregateAttestation
  for i in 0 ..< beacon_committee.len:
    result.aggregation_bits[i] = true

  signMockAttestation(state, result)

proc mockAttestation*(
       state: BeaconState): Attestation =
  mockAttestationImpl(state, state.slot)

proc mockAttestation*(
       state: BeaconState,
       slot: Slot): Attestation =
  mockAttestationImpl(state, slot)
