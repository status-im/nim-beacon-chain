import
  # Standard library
  options,
  # Local modules
  ../[datatypes, digest, crypto],
  json_rpc/jsonmarshal,
  callsigs_types


# calls that return a bool are actually without a return type in the main REST API
# spec but nim-json-rpc requires that all RPC calls have a return type.

proc get_v1_validator_block(slot: Slot, graffiti: GraffitiBytes, randao_reveal: ValidatorSig): BeaconBlock

proc post_v1_validator_block(body: SignedBeaconBlock): bool

proc get_v1_validator_attestation(slot: Slot, committee_index: CommitteeIndex): AttestationData

proc get_v1_validator_aggregate_attestation(slot: Slot, attestation_data_root: Eth2Digest): Attestation

proc post_v1_validator_aggregate_and_proofs(payload: SignedAggregateAndProof): bool

# TODO epoch is part of the REST path
proc get_v1_validator_duties_attester(epoch: Epoch, public_keys: seq[ValidatorPubKey]): seq[AttesterDuties]

# TODO epoch is part of the REST path
proc get_v1_validator_duties_proposer(epoch: Epoch): seq[ValidatorPubkeySlotPair]

proc post_v1_validator_beacon_committee_subscriptions(committee_index: CommitteeIndex,
                                                      slot: Slot,
                                                      aggregator: bool,
                                                      validator_pubkey: ValidatorPubKey,
                                                      slot_signature: ValidatorSig): bool
