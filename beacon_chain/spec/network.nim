# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  "."/[digest, helpers],
  "."/datatypes/base

const
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/p2p-interface.md#topics-and-messages
  topicBeaconBlocksSuffix* = "beacon_block/ssz"
  topicVoluntaryExitsSuffix* = "voluntary_exit/ssz"
  topicProposerSlashingsSuffix* = "proposer_slashing/ssz"
  topicAttesterSlashingsSuffix* = "attester_slashing/ssz"
  topicAggregateAndProofsSuffix* = "beacon_aggregate_and_proof/ssz"

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/p2p-interface.md#eth2-network-interaction-domains
  MAX_CHUNK_SIZE* = 1 * 1024 * 1024 # bytes
  GOSSIP_MAX_SIZE* = 1 * 1024 * 1024 # bytes
  TTFB_TIMEOUT* = 5.seconds
  RESP_TIMEOUT* = 10.seconds

  defaultEth2TcpPort* = 9000

  # This is not part of the spec yet! Keep in sync with BASE_RPC_PORT
  defaultEth2RpcPort* = 9190

  # This is not part of the spec! But its port which uses Lighthouse
  DefaultEth2RestPort* = 5052

template eth2Prefix(forkDigest: ForkDigest): string =
  "/eth2/" & $forkDigest & "/"

func getBeaconBlocksTopic*(forkDigest: ForkDigest): string =
  eth2Prefix(forkDigest) & topicBeaconBlocksSuffix

func getVoluntaryExitsTopic*(forkDigest: ForkDigest): string =
  eth2Prefix(forkDigest) & topicVoluntaryExitsSuffix

func getProposerSlashingsTopic*(forkDigest: ForkDigest): string =
  eth2Prefix(forkDigest) & topicProposerSlashingsSuffix

func getAttesterSlashingsTopic*(forkDigest: ForkDigest): string =
  eth2Prefix(forkDigest) & topicAttesterSlashingsSuffix

func getAggregateAndProofsTopic*(forkDigest: ForkDigest): string =
  eth2Prefix(forkDigest) & topicAggregateAndProofsSuffix

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#broadcast-attestation
func compute_subnet_for_attestation*(
    committees_per_slot: uint64, slot: Slot, committee_index: CommitteeIndex):
    SubnetId =
  # Compute the correct subnet for an attestation for Phase 0.
  # Note, this mimics expected Phase 1 behavior where attestations will be
  # mapped to their shard subnet.
  let
    slots_since_epoch_start = slot mod SLOTS_PER_EPOCH
    committees_since_epoch_start =
      committees_per_slot * slots_since_epoch_start

  SubnetId(
    (committees_since_epoch_start + committee_index.uint64) mod
    ATTESTATION_SUBNET_COUNT)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#broadcast-attestation
func getAttestationTopic*(forkDigest: ForkDigest,
                          subnet_id: SubnetId): string =
  ## For subscribing and unsubscribing to/from a subnet.
  eth2Prefix(forkDigest) & "beacon_attestation_" & $uint64(subnet_id) & "/ssz"

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.8/specs/altair/p2p-interface.md#topics-and-messages
func getSyncCommitteeTopic*(forkDigest: ForkDigest,
                            subnet_id: SubnetId): string =
  ## For subscribing and unsubscribing to/from a subnet.
  eth2Prefix(forkDigest) & "sync_committee_" & $uint64(subnet_id) & "/ssz"

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.8/specs/altair/p2p-interface.md#topics-and-messages
func getSyncCommitteeContributionAndProofTopic*(forkDigest: ForkDigest): string =
  ## For subscribing and unsubscribing to/from a subnet.
  eth2Prefix(forkDigest) & "sync_committee_contribution_and_proof" & "/ssz"

func getENRForkID*(fork_version: Version,
                   genesis_validators_root: Eth2Digest): ENRForkID =
  let
    current_fork_version = fork_version
    fork_digest = compute_fork_digest(
      current_fork_version, genesis_validators_root)

  ENRForkID(
    fork_digest: fork_digest,
    next_fork_version: current_fork_version,
    next_fork_epoch: FAR_FUTURE_EPOCH) # TODO altair-transition
