# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[intsets, strformat],
  ./datatypes, ./helpers, ./validator

const
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#topics-and-messages
  topicBeaconBlocksSuffix* = "beacon_block/ssz"
  topicVoluntaryExitsSuffix* = "voluntary_exit/ssz"
  topicProposerSlashingsSuffix* = "proposer_slashing/ssz"
  topicAttesterSlashingsSuffix* = "attester_slashing/ssz"
  topicAggregateAndProofsSuffix* = "beacon_aggregate_and_proof/ssz"

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#eth2-network-interaction-domains
  MAX_CHUNK_SIZE* = 1 * 1024 * 1024 # bytes
  GOSSIP_MAX_SIZE* = 1 * 1024 * 1024 # bytes
  TTFB_TIMEOUT* = 5.seconds
  RESP_TIMEOUT* = 10.seconds

  defaultEth2TcpPort* = 9000

  # This is not part of the spec yet! Keep in sync with BASE_RPC_PORT
  defaultEth2RpcPort* = 9190

func getBeaconBlocksTopic*(forkDigest: ForkDigest): string =
  try:
    &"/eth2/{$forkDigest}/{topicBeaconBlocksSuffix}"
  except ValueError as e:
    raiseAssert e.msg

func getVoluntaryExitsTopic*(forkDigest: ForkDigest): string =
  try:
    &"/eth2/{$forkDigest}/{topicVoluntaryExitsSuffix}"
  except ValueError as e:
    raiseAssert e.msg

func getProposerSlashingsTopic*(forkDigest: ForkDigest): string =
  try:
    &"/eth2/{$forkDigest}/{topicProposerSlashingsSuffix}"
  except ValueError as e:
    raiseAssert e.msg

func getAttesterSlashingsTopic*(forkDigest: ForkDigest): string =
  try:
    &"/eth2/{$forkDigest}/{topicAttesterSlashingsSuffix}"
  except ValueError as e:
    raiseAssert e.msg

func getAggregateAndProofsTopic*(forkDigest: ForkDigest): string =
  try:
    &"/eth2/{$forkDigest}/{topicAggregateAndProofsSuffix}"
  except ValueError as e:
    raiseAssert e.msg

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#broadcast-attestation
func compute_subnet_for_attestation*(
    committees_per_slot: uint64, slot: Slot, committee_index: CommitteeIndex):
    uint64 =
  # Compute the correct subnet for an attestation for Phase 0.
  # Note, this mimics expected Phase 1 behavior where attestations will be
  # mapped to their shard subnet.
  let
    slots_since_epoch_start = slot mod SLOTS_PER_EPOCH
    committees_since_epoch_start =
      committees_per_slot * slots_since_epoch_start

  (committees_since_epoch_start + committee_index.uint64) mod
    ATTESTATION_SUBNET_COUNT

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#broadcast-attestation
func getAttestationTopic*(forkDigest: ForkDigest, subnetIndex: uint64):
    string =
  ## For subscribing and unsubscribing to/from a subnet.
  doAssert subnetIndex < ATTESTATION_SUBNET_COUNT

  try:
    &"/eth2/{$forkDigest}/beacon_attestation_{subnetIndex}/ssz"
  except ValueError as e:
    raiseAssert e.msg

iterator get_committee_assignments*(
    state: BeaconState, epoch: Epoch,
    validator_indices: IntSet,
    cache: var StateCache):
    tuple[validatorIndices: IntSet,
      committeeIndex: CommitteeIndex,
      subnetIndex: uint8, slot: Slot] =
  let
    committees_per_slot = get_committee_count_per_slot(state, epoch, cache)
    start_slot = compute_start_slot_at_epoch(epoch)

  for slot in start_slot ..< start_slot + SLOTS_PER_EPOCH:
    for index in 0'u64 ..< committees_per_slot:
      let
        idx = index.CommitteeIndex
        includedIndices =
          toIntSet(get_beacon_committee(state, slot, idx, cache)) *
            validator_indices
      if includedIndices.len > 0:
        yield (
          includedIndices, idx,
          compute_subnet_for_attestation(committees_per_slot, slot, idx).uint8,
          slot)
