# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  ../ssz/merkleization,
  ./crypto, ./digest, ./datatypes/[phase0, altair], ./helpers, ./presets

template withTrust(sig: SomeSig, body: untyped): bool =
  when sig is TrustedSig:
    true
  else:
    body

func getDepositMessage(depositData: DepositData): DepositMessage =
  DepositMessage(
    pubkey: depositData.pubkey,
    amount: depositData.amount,
    withdrawal_credentials: depositData.withdrawal_credentials)

func compute_slot_root*(
    fork: Fork, genesis_validators_root: Eth2Digest, slot: Slot
    ): Eth2Digest =
  let
    epoch = compute_epoch_at_slot(slot)
    domain = get_domain(
      fork, DOMAIN_SELECTION_PROOF, epoch, genesis_validators_root)
  result = compute_signing_root(slot, domain)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#aggregation-selection
func get_slot_signature*(
    fork: Fork, genesis_validators_root: Eth2Digest, slot: Slot,
    privkey: ValidatorPrivKey): CookedSig =
  blsSign(privKey, compute_slot_root(fork, genesis_validators_root, slot).data)

proc verify_slot_signature*(
    fork: Fork, genesis_validators_root: Eth2Digest, slot: Slot,
    pubkey: ValidatorPubKey | CookedPubKey, signature: SomeSig): bool =
  withTrust(signature):
    let
      epoch = compute_epoch_at_slot(slot)
      domain = get_domain(
        fork, DOMAIN_SELECTION_PROOF, epoch, genesis_validators_root)
      signing_root = compute_signing_root(slot, domain)

    blsVerify(pubkey, signing_root.data, signature)

func compute_epoch_root*(
    fork: Fork, genesis_validators_root: Eth2Digest, epoch: Epoch
    ): Eth2Digest =
  let
    domain = get_domain(fork, DOMAIN_RANDAO, epoch, genesis_validators_root)
  result = compute_signing_root(epoch, domain)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#randao-reveal
func get_epoch_signature*(
    fork: Fork, genesis_validators_root: Eth2Digest, epoch: Epoch,
    privkey: ValidatorPrivKey): CookedSig =
  blsSign(privKey, compute_epoch_root(fork, genesis_validators_root, epoch).data)

proc verify_epoch_signature*(
    fork: Fork, genesis_validators_root: Eth2Digest, epoch: Epoch,
    pubkey: ValidatorPubKey | CookedPubKey, signature: SomeSig): bool =
  withTrust(signature):
    let
      domain = get_domain(fork, DOMAIN_RANDAO, epoch, genesis_validators_root)
      signing_root = compute_signing_root(epoch, domain)

    blsVerify(pubkey, signing_root.data, signature)

func compute_block_root*(
    fork: Fork, genesis_validators_root: Eth2Digest, slot: Slot,
    root: Eth2Digest): Eth2Digest =
  let
    epoch = compute_epoch_at_slot(slot)
    domain = get_domain(
      fork, DOMAIN_BEACON_PROPOSER, epoch, genesis_validators_root)
  result = compute_signing_root(root, domain)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#signature
func get_block_signature*(
    fork: Fork, genesis_validators_root: Eth2Digest, slot: Slot,
    root: Eth2Digest, privkey: ValidatorPrivKey): CookedSig =
  blsSign(privKey, compute_block_root(fork, genesis_validators_root, slot, root).data)

proc verify_block_signature*(
    fork: Fork, genesis_validators_root: Eth2Digest, slot: Slot,
    blck: Eth2Digest | SomeSomeBeaconBlock | BeaconBlockHeader,
    pubkey: ValidatorPubKey | CookedPubKey, signature: SomeSig): bool =
  withTrust(signature):
    let
      epoch = compute_epoch_at_slot(slot)
      domain = get_domain(
        fork, DOMAIN_BEACON_PROPOSER, epoch, genesis_validators_root)
      signing_root = compute_signing_root(blck, domain)

    blsVerify(pubKey, signing_root.data, signature)

func compute_aggregate_and_proof_root*(fork: Fork, genesis_validators_root: Eth2Digest,
                                       aggregate_and_proof: AggregateAndProof,
                                       ): Eth2Digest =
  let
    epoch = compute_epoch_at_slot(aggregate_and_proof.aggregate.data.slot)
    domain = get_domain(
      fork, DOMAIN_AGGREGATE_AND_PROOF, epoch, genesis_validators_root)
  result = compute_signing_root(aggregate_and_proof, domain)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#broadcast-aggregate
func get_aggregate_and_proof_signature*(fork: Fork, genesis_validators_root: Eth2Digest,
                                        aggregate_and_proof: AggregateAndProof,
                                        privKey: ValidatorPrivKey): CookedSig =
  blsSign(privKey, compute_aggregate_and_proof_root(fork, genesis_validators_root,
                                                    aggregate_and_proof).data)

proc verify_aggregate_and_proof_signature*(
    fork: Fork, genesis_validators_root: Eth2Digest,
    aggregate_and_proof: AggregateAndProof,
    pubkey: ValidatorPubKey | CookedPubKey, signature: SomeSig): bool =
  withTrust(signature):
    let
      epoch = compute_epoch_at_slot(aggregate_and_proof.aggregate.data.slot)
      domain = get_domain(
        fork, DOMAIN_AGGREGATE_AND_PROOF, epoch, genesis_validators_root)
      signing_root = compute_signing_root(aggregate_and_proof, domain)

    blsVerify(pubKey, signing_root.data, signature)

func compute_attestation_root*(
    fork: Fork, genesis_validators_root: Eth2Digest,
    attestation_data: AttestationData
    ): Eth2Digest =
  let
    epoch = attestation_data.target.epoch
    domain = get_domain(
      fork, DOMAIN_BEACON_ATTESTER, epoch, genesis_validators_root)
  result = compute_signing_root(attestation_data, domain)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#aggregate-signature
func get_attestation_signature*(
    fork: Fork, genesis_validators_root: Eth2Digest,
    attestation_data: AttestationData,
    privkey: ValidatorPrivKey): CookedSig =
  blsSign(privKey, compute_attestation_root(fork, genesis_validators_root,
                                            attestation_data).data)

proc verify_attestation_signature*(
    fork: Fork, genesis_validators_root: Eth2Digest,
    attestation_data: AttestationData,
    pubkeys: auto,
    signature: SomeSig): bool =
  withTrust(signature):
    let
      epoch = attestation_data.target.epoch
      domain = get_domain(
        fork, DOMAIN_BEACON_ATTESTER, epoch, genesis_validators_root)
      signing_root = compute_signing_root(attestation_data, domain)

    blsFastAggregateVerify(pubkeys, signing_root.data, signature)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#deposits
func get_deposit_signature*(preset: RuntimeConfig,
                            deposit: DepositData,
                            privkey: ValidatorPrivKey): CookedSig =
  let
    deposit_message = deposit.getDepositMessage()
    # Fork-agnostic domain since deposits are valid across forks
    domain = compute_domain(DOMAIN_DEPOSIT, preset.GENESIS_FORK_VERSION)
    signing_root = compute_signing_root(deposit_message, domain)

  blsSign(privKey, signing_root.data)

proc verify_deposit_signature*(preset: RuntimeConfig,
                               deposit: DepositData): bool =
  let
    deposit_message = deposit.getDepositMessage()
    # Fork-agnostic domain since deposits are valid across forks
    domain = compute_domain(DOMAIN_DEPOSIT, preset.GENESIS_FORK_VERSION)
    signing_root = compute_signing_root(deposit_message, domain)

  blsVerify(deposit.pubkey, signing_root.data, deposit.signature)

func get_voluntary_exit_signature*(
    fork: Fork,
    genesis_validators_root: Eth2Digest,
    voluntary_exit: VoluntaryExit,
    privkey: ValidatorPrivKey): CookedSig =
  let
    domain = get_domain(
      fork, DOMAIN_VOLUNTARY_EXIT, voluntary_exit.epoch, genesis_validators_root)
    signing_root = compute_signing_root(voluntary_exit, domain)

  blsSign(privKey, signing_root.data)

proc verify_voluntary_exit_signature*(
    fork: Fork,
    genesis_validators_root: Eth2Digest,
    voluntary_exit: VoluntaryExit,
    pubkey: ValidatorPubKey,
    signature: SomeSig): bool =
  withTrust(signature):
    let
      domain = get_domain(
        fork, DOMAIN_VOLUNTARY_EXIT, voluntary_exit.epoch, genesis_validators_root)
      signing_root = compute_signing_root(voluntary_exit, domain)

    blsVerify(pubkey, signing_root.data, signature)

proc verify_sync_committee_message_signature*(
    msg: SyncCommitteeMessage | SyncCommitteeContribution,
    fork: Fork,
    genesis_validators_root: Eth2Digest,
    pubkey: ValidatorPubKey | CookedPubKey): bool =
  let
    domain = get_domain(
      fork, DOMAIN_SYNC_COMMITTEE, msg.slot.epoch, genesis_validators_root)
    signing_root = compute_signing_root(msg.beacon_block_root, domain)

  blsVerify(pubkey, signing_root.data, msg.signature)

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.7/specs/altair/validator.md#aggregation-selection
proc is_sync_committee_aggregator*(signature: ValidatorSig): bool =
  let
    signatureDigest = eth2digest(signature.blob)
    modulo = max(1'u64, (SYNC_COMMITTEE_SIZE div SYNC_COMMITTEE_SUBNET_COUNT) div TARGET_AGGREGATORS_PER_SYNC_SUBCOMMITTEE)
  bytes_to_uint64(signatureDigest.data.toOpenArray(0, 7)) mod modulo == 0

proc verify_signed_contribution_and_proof_signature*(
    msg: SignedContributionAndProof,
    fork: Fork,
    genesis_validators_root: Eth2Digest,
    pubkey: ValidatorPubKey | CookedPubKey): bool =
  let
    domain = get_domain(
      fork, DOMAIN_CONTRIBUTION_AND_PROOF, msg.message.contribution.slot.epoch, genesis_validators_root)
    signing_root = compute_signing_root(msg.message, domain)

  blsVerify(pubkey, signing_root.data, msg.signature)

proc verify_selection_proof_signature*(
    msg: ContributionAndProof,
    fork: Fork,
    genesis_validators_root: Eth2Digest,
    pubkey: ValidatorPubKey | CookedPubKey): bool =
  let
    slot = msg.contribution.slot
    domain = get_domain(
      fork, DOMAIN_SYNC_COMMITTEE_SELECTION_PROOF, slot.epoch, genesis_validators_root)
    signing_data = SyncAggregatorSelectionData(
      slot: slot,
      subcommittee_index: msg.contribution.subcommittee_index)
    signing_root = compute_signing_root(signing_data, domain)

  blsVerify(pubkey, signing_root.data, msg.selection_proof)

