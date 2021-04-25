# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# This file contains data types that are part of the spec and thus subject to
# serialization and spec updates.
#
# The spec folder in general contains code that has been hoisted from the
# specification and that follows the spec as closely as possible, so as to make
# it easy to keep up-to-date.
#
# These datatypes are used as specifications for serialization - thus should not
# be altered outside of what the spec says. Likewise, they should not be made
# `ref` - this can be achieved by wrapping them in higher-level
# types / composition

# TODO Careful, not nil analysis is broken / incomplete and the semantics will
#      likely change in future versions of the language:
#      https://github.com/nim-lang/RFCs/issues/250
{.experimental: "notnil".}

{.push raises: [Defect].}

import
  std/[macros, hashes, intsets, strutils, tables, typetraits],
  stew/[assign2, byteutils], chronicles,
  json_serialization,
  ../../version, ../../ssz/types as sszTypes, ../crypto, ../digest, ../presets,
  ./merge

export
  sszTypes, merge, presets, json_serialization

# Presently, we're reusing the data types from the serialization (uint64) in the
# objects we pass around to the beacon chain logic, thus keeping the two
# similar. This is convenient for keeping up with the specification, but
# will eventually need a more robust approach such that we don't run into
# over- and underflows.
# Some of the open questions are being tracked here:
# https://github.com/ethereum/eth2.0-specs/issues/224
#
# The present approach causes some problems due to how Nim treats unsigned
# integers - here's no high(uint64), arithmetic support is incomplete, there's
# no over/underflow checking available
#
# Eventually, we could also differentiate between user/tainted data and
# internal state that's gone through sanity checks already.

const SPEC_VERSION* = "1.0.1"
## Spec version we're aiming to be compatible with, right now

const
  GENESIS_SLOT* = Slot(0)
  GENESIS_EPOCH* = (GENESIS_SLOT.uint64 div SLOTS_PER_EPOCH).Epoch ##\
  ## compute_epoch_at_slot(GENESIS_SLOT)

  FAR_FUTURE_EPOCH* = (not 0'u64).Epoch # 2^64 - 1 in spec

  # Not part of spec. Still useful, pending removing usage if appropriate.
  ZERO_HASH* = Eth2Digest()
  MAX_GRAFFITI_SIZE = 32
  FAR_FUTURE_SLOT* = (not 0'u64).Slot

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/p2p-interface.md#configuration
  MAXIMUM_GOSSIP_CLOCK_DISPARITY* = 500.millis

  SLOTS_PER_ETH1_VOTING_PERIOD* =
    EPOCHS_PER_ETH1_VOTING_PERIOD * SLOTS_PER_EPOCH

  DEPOSIT_CONTRACT_TREE_DEPTH* = 32
  BASE_REWARDS_PER_EPOCH* = 4

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#misc
  ATTESTATION_SUBNET_COUNT* = 64

template maxSize*(n: int) {.pragma.}

# Block validation flow
# We distinguish 4 cases depending
# if the signature and/or transition logic of a
# a block have been verified:
#
# |                            | Signature unchecked             | Signature verified          |
# |----------------------------|-------------------------------  |-----------------------------|
# | State transition unchecked | - UntrustedBeaconBlock          | - SigVerifiedBeaconBlock    |
# |                            | - UntrustedIndexedAttestation   | - TrustedIndexedAttestation |
# |                            | - UntrustedAttestation          | - TrustedAttestation        |
# |----------------------------|-------------------------------  |-----------------------------|
# | State transition verified  | - TransitionVerifiedBeaconBlock | - TrustedSignedBeaconBlock  |
# |                            | - UntrustedIndexedAttestation   | - TrustedIndexedAttestation |
# |                            | - UntrustedAttestation          | - TrustedAttestation        |
#
# At the moment we only introduce SigVerifiedBeaconBlock
# and keep the old naming where BeaconBlock == UntrustedbeaconBlock
# Also for Attestation, IndexedAttestation, AttesterSlashing, ProposerSlashing.
# We only distinguish between the base version and the Trusted version
# (i.e. Attestation and TrustedAttestation)
# The Trusted version, at the moment, implies that the cryptographic signature was checked.
# It DOES NOT imply that the state transition was verified.
# Currently the code MUST verify the state transition as soon as the signature is verified
#
# TODO We could implement the trust level as either static enums or generic tags
# and reduce duplication and improve maintenance and readability,
# however this caused problems respectively of:
# - ambiguous calls, in particular for chronicles, with static enums
# - broke the compiler in SSZ and nim-serialization

type
  # Domains
  # ---------------------------------------------------------------
  DomainType* = enum
    # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#domain-types
    DOMAIN_BEACON_PROPOSER = 0
    DOMAIN_BEACON_ATTESTER = 1
    DOMAIN_RANDAO = 2
    DOMAIN_DEPOSIT = 3
    DOMAIN_VOLUNTARY_EXIT = 4
    DOMAIN_SELECTION_PROOF = 5
    DOMAIN_AGGREGATE_AND_PROOF = 6

    # https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.2/specs/altair/beacon-chain.md#domain-types
    # Needs to be in same enum definition and is safe regardless of whether one
    # only accesses phase 0 definitions
    DOMAIN_SYNC_COMMITTEE = 7
    DOMAIN_SYNC_COMMITTEE_SELECTION_PROOF = 8
    DOMAIN_CONTRIBUTION_AND_PROOF = 9

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#custom-types
  Eth2Domain* = array[32, byte]

  # https://github.com/nim-lang/Nim/issues/574 and be consistent across
  # 32-bit and 64-bit word platforms.
  # The distinct types here should only be used when data has been de-tainted
  # following overflow checks - they cannot be used in SSZ objects as SSZ
  # instances are not invalid _per se_ when they hold an out-of-bounds index -
  # that is part of consensus.
  # VALIDATOR_REGISTRY_LIMIT is 1^40 in spec 1.0, but if the number of
  # validators ever grows near 1^32 that we support here, we'll have bigger
  # issues than the size of this type to take care of. Until then, we'll use
  # uint32 as it halves memory requirements for active validator sets,
  # improves consistency on 32-vs-64-bit platforms and works better with
  # Nim seq constraints.
  ValidatorIndex* = distinct uint32

  # Though in theory the committee index would fit in a uint8, it is not used
  # in a way that would significantly benefit from the smaller type, thus we
  # leave it at spec size
  CommitteeIndex* = distinct uint64

  # The subnet id maps which gossip subscription to use to publish an
  # attestation - it is distinct from the CommitteeIndex in particular
  SubnetId* = distinct uint8

  Gwei* = uint64

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#proposerslashing
  ProposerSlashing* = object
    signed_header_1*: SignedBeaconBlockHeader
    signed_header_2*: SignedBeaconBlockHeader

  TrustedProposerSlashing* = object
    # The Trusted version, at the moment, implies that the cryptographic signature was checked.
    # It DOES NOT imply that the state transition was verified.
    # Currently the code MUST verify the state transition as soon as the signature is verified
    signed_header_1*: TrustedSignedBeaconBlockHeader
    signed_header_2*: TrustedSignedBeaconBlockHeader

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#attesterslashing
  AttesterSlashing* = object
    attestation_1*: IndexedAttestation
    attestation_2*: IndexedAttestation

  TrustedAttesterSlashing* = object
    # The Trusted version, at the moment, implies that the cryptographic signature was checked.
    # It DOES NOT imply that the state transition was verified.
    # Currently the code MUST verify the state transition as soon as the signature is verified
    attestation_1*: TrustedIndexedAttestation
    attestation_2*: TrustedIndexedAttestation

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#indexedattestation
  IndexedAttestation* = object
    attesting_indices*: List[uint64, Limit MAX_VALIDATORS_PER_COMMITTEE]
    data*: AttestationData
    signature*: ValidatorSig

  TrustedIndexedAttestation* = object
    # The Trusted version, at the moment, implies that the cryptographic signature was checked.
    # It DOES NOT imply that the state transition was verified.
    # Currently the code MUST verify the state transition as soon as the signature is verified
    attesting_indices*: List[uint64, Limit MAX_VALIDATORS_PER_COMMITTEE]
    data*: AttestationData
    signature*: TrustedSig

  CommitteeValidatorsBits* = BitList[Limit MAX_VALIDATORS_PER_COMMITTEE]

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#attestation
  Attestation* = object
    aggregation_bits*: CommitteeValidatorsBits
    data*: AttestationData
    signature*: ValidatorSig

  TrustedAttestation* = object
    # The Trusted version, at the moment, implies that the cryptographic signature was checked.
    # It DOES NOT imply that the state transition was verified.
    # Currently the code MUST verify the state transition as soon as the signature is verified
    aggregation_bits*: CommitteeValidatorsBits
    data*: AttestationData
    signature*: TrustedSig

  ForkDigest* = distinct array[4, byte]

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#forkdata
  ForkData* = object
    current_version*: Version
    genesis_validators_root*: Eth2Digest

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#checkpoint
  Checkpoint* = object
    epoch*: Epoch
    root*: Eth2Digest

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#AttestationData
  AttestationData* = object
    slot*: Slot

    index*: uint64

    # LMD GHOST vote
    beacon_block_root*: Eth2Digest

    # FFG vote
    source*: Checkpoint
    target*: Checkpoint

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#deposit
  Deposit* = object
    proof*: array[DEPOSIT_CONTRACT_TREE_DEPTH + 1, Eth2Digest] ##\
    ## Merkle path to deposit root

    data*: DepositData

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#depositmessage
  DepositMessage* = object
    pubkey*: ValidatorPubKey
    withdrawal_credentials*: Eth2Digest
    amount*: Gwei

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#depositdata
  DepositData* = object
    pubkey*: ValidatorPubKey
    withdrawal_credentials*: Eth2Digest
    amount*: Gwei
    # Cannot use TrustedSig here as invalid signatures are possible and determine
    # if the deposit should be added or not during processing
    signature*: ValidatorSig  # Signing over DepositMessage

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#voluntaryexit
  VoluntaryExit* = object
    epoch*: Epoch ##\
    ## Earliest epoch when voluntary exit can be processed

    validator_index*: uint64

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beaconblock
  BeaconBlock* = object
    ## For each slot, a proposer is chosen from the validator pool to propose
    ## a new block. Once the block as been proposed, it is transmitted to
    ## validators that will have a chance to vote on it through attestations.
    ## Each block collects attestations, or votes, on past blocks, thus a chain
    ## is formed.

    slot*: Slot
    proposer_index*: uint64

    parent_root*: Eth2Digest ##\
    ## Root hash of the previous block

    state_root*: Eth2Digest ##\
    ## The state root, _after_ this block has been processed

    body*: BeaconBlockBody

  SigVerifiedBeaconBlock* = object
    ## A BeaconBlock that contains verified signatures
    ## but that has not been verified for state transition
    slot*: Slot
    proposer_index*: uint64

    parent_root*: Eth2Digest ##\
    ## Root hash of the previous block

    state_root*: Eth2Digest ##\
    ## The state root, _after_ this block has been processed

    body*: SigVerifiedBeaconBlockBody

  TrustedBeaconBlock* = object
    ## When we receive blocks from outside sources, they are untrusted and go
    ## through several layers of validation. Blocks that have gone through
    ## validations can be trusted to be well-formed, with a correct signature,
    ## having a parent and applying cleanly to the state that their parent
    ## left them with.
    ##
    ## When loading such blocks from the database, to rewind states for example,
    ## it is expensive to redo the validations (in particular, the signature
    ## checks), thus `TrustedBlock` uses a `TrustedSig` type to mark that these
    ## checks can be skipped.
    ##
    ## TODO this could probably be solved with some type trickery, but there
    ##      too many bugs in nim around generics handling, and we've used up
    ##      the trickery budget in the serialization library already. Until
    ##      then, the type must be manually kept compatible with its untrusted
    ##      cousin.
    slot*: Slot
    proposer_index*: uint64
    parent_root*: Eth2Digest ##\
    state_root*: Eth2Digest ##\
    body*: TrustedBeaconBlockBody

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beaconblockheader
  BeaconBlockHeader* = object
    slot*: Slot
    proposer_index*: uint64
    parent_root*: Eth2Digest
    state_root*: Eth2Digest
    body_root*: Eth2Digest

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#signingdata
  SigningData* = object
    object_root*: Eth2Digest
    domain*: Eth2Domain

  GraffitiBytes* = distinct array[MAX_GRAFFITI_SIZE, byte]

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beaconblockbody
  # https://github.com/ethereum/eth2.0-specs/blob/eca6bd7d622a0cfb7343bff742da046ed25b3825/specs/merge/beacon-chain.md#beaconblockbody
  BeaconBlockBody* = object
    randao_reveal*: ValidatorSig
    eth1_data*: Eth1Data
    graffiti*: GraffitiBytes

    # Operations
    proposer_slashings*: List[ProposerSlashing, Limit MAX_PROPOSER_SLASHINGS]
    attester_slashings*: List[AttesterSlashing, Limit MAX_ATTESTER_SLASHINGS]
    attestations*: List[Attestation, Limit MAX_ATTESTATIONS]
    deposits*: List[Deposit, Limit MAX_DEPOSITS]
    voluntary_exits*: List[SignedVoluntaryExit, Limit MAX_VOLUNTARY_EXITS]

    execution_payload*: ExecutionPayload  # [New in Merge]

  SigVerifiedBeaconBlockBody* = object
    ## A BeaconBlock body with signatures verified
    ## including:
    ## - Randao reveal
    ## - Attestations
    ## - ProposerSlashing (SignedBeaconBlockHeader)
    ## - AttesterSlashing (IndexedAttestation)
    ## - SignedVoluntaryExits
    ##
    ## - ETH1Data (Deposits) can contain invalid BLS signatures
    ##
    ## The block state transition has NOT been verified
    randao_reveal*: TrustedSig
    eth1_data*: Eth1Data
    graffiti*: GraffitiBytes

    # Operations
    proposer_slashings*: List[TrustedProposerSlashing, Limit MAX_PROPOSER_SLASHINGS]
    attester_slashings*: List[TrustedAttesterSlashing, Limit MAX_ATTESTER_SLASHINGS]
    attestations*: List[TrustedAttestation, Limit MAX_ATTESTATIONS]
    deposits*: List[Deposit, Limit MAX_DEPOSITS]
    voluntary_exits*: List[TrustedSignedVoluntaryExit, Limit MAX_VOLUNTARY_EXITS]

    execution_payload*: ExecutionPayload  # [New in Merge]

  TrustedBeaconBlockBody* = object
    ## A full verified block
    randao_reveal*: TrustedSig
    eth1_data*: Eth1Data
    graffiti*: GraffitiBytes

    # Operations
    proposer_slashings*: List[TrustedProposerSlashing, Limit MAX_PROPOSER_SLASHINGS]
    attester_slashings*: List[TrustedAttesterSlashing, Limit MAX_ATTESTER_SLASHINGS]
    attestations*: List[TrustedAttestation, Limit MAX_ATTESTATIONS]
    deposits*: List[Deposit, Limit MAX_DEPOSITS]
    voluntary_exits*: List[TrustedSignedVoluntaryExit, Limit MAX_VOLUNTARY_EXITS]

    execution_payload*: ExecutionPayload  # [New in Merge]

  SomeSignedBeaconBlock* = SignedBeaconBlock | SigVerifiedSignedBeaconBlock | TrustedSignedBeaconBlock
  SomeBeaconBlock* = BeaconBlock | SigVerifiedBeaconBlock | TrustedBeaconBlock
  SomeBeaconBlockBody* = BeaconBlockBody | SigVerifiedBeaconBlockBody | TrustedBeaconBlockBody
  SomeAttestation* = Attestation | TrustedAttestation
  SomeIndexedAttestation* = IndexedAttestation | TrustedIndexedAttestation
  SomeProposerSlashing* = ProposerSlashing | TrustedProposerSlashing
  SomeAttesterSlashing* = AttesterSlashing | TrustedAttesterSlashing
  SomeSignedBeaconBlockHeader* = SignedBeaconBlockHeader | TrustedSignedBeaconBlockHeader
  SomeSignedVoluntaryExit* = SignedVoluntaryExit | TrustedSignedVoluntaryExit

  # https://github.com/ethereum/eth2.0-specs/blob/dev/specs/merge/beacon-chain.md#executionpayloadheader
  ExecutionPayloadHeader* = object
    block_hash*: Eth2Digest  # Hash of execution block
    parent_hash*: Eth2Digest
    coinbase*: EthAddress
    state_root*: Eth2Digest
    number*: uint64
    gas_limit*: uint64
    gas_used*: uint64
    timestamp*: uint64
    receipt_root*: Eth2Digest
    logs_bloom*: BloomLogs
    transactions_root*: Eth2Digest

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beaconstate
  # https://github.com/ethereum/eth2.0-specs/blob/eca6bd7d622a0cfb7343bff742da046ed25b3825/specs/merge/beacon-chain.md#beaconstate
  BeaconState* = object
    # Versioning
    genesis_time*: uint64
    genesis_validators_root*: Eth2Digest
    slot*: Slot
    fork*: Fork

    # History
    latest_block_header*: BeaconBlockHeader ##\
    ## `latest_block_header.state_root == ZERO_HASH` temporarily

    block_roots*: HashArray[Limit SLOTS_PER_HISTORICAL_ROOT, Eth2Digest] ##\
    ## Needed to process attestations, older to newer

    state_roots*: HashArray[Limit SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    historical_roots*: HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT]

    # Eth1
    eth1_data*: Eth1Data
    eth1_data_votes*:
      HashList[Eth1Data, Limit(EPOCHS_PER_ETH1_VOTING_PERIOD * SLOTS_PER_EPOCH)]
    eth1_deposit_index*: uint64

    # Registry
    validators*: HashList[Validator, Limit VALIDATOR_REGISTRY_LIMIT]
    balances*: HashList[uint64, Limit VALIDATOR_REGISTRY_LIMIT]

    # Randomness
    randao_mixes*: HashArray[Limit EPOCHS_PER_HISTORICAL_VECTOR, Eth2Digest]

    # Slashings
    slashings*: HashArray[Limit EPOCHS_PER_SLASHINGS_VECTOR, uint64] ##\
    ## Per-epoch sums of slashed effective balances

    # Attestations
    previous_epoch_attestations*:
      HashList[PendingAttestation, Limit(MAX_ATTESTATIONS * SLOTS_PER_EPOCH)]
    current_epoch_attestations*:
      HashList[PendingAttestation, Limit(MAX_ATTESTATIONS * SLOTS_PER_EPOCH)]

    # Finality
    justification_bits*: uint8 ##\
    ## Bit set for every recent justified epoch
    ## Model a Bitvector[4] as a one-byte uint, which should remain consistent
    ## with ssz/hashing.

    previous_justified_checkpoint*: Checkpoint ##\
    ## Previous epoch snapshot

    current_justified_checkpoint*: Checkpoint
    finalized_checkpoint*: Checkpoint

    # Execution-layer
    latest_execution_payload_header*: ExecutionPayloadHeader  # [New in Merge]

  # TODO Careful, not nil analysis is broken / incomplete and the semantics will
  #      likely change in future versions of the language:
  #      https://github.com/nim-lang/RFCs/issues/250
  BeaconStateRef* = ref BeaconState not nil
  NilableBeaconStateRef* = ref BeaconState

  # Please note that this type is not part of the spec
  ImmutableValidatorData* = object
    pubkey*: ValidatorPubKey
    withdrawal_credentials*: Eth2Digest

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#validator
  Validator* = object
    pubkey*: ValidatorPubKey

    withdrawal_credentials*: Eth2Digest ##\
    ## Commitment to pubkey for withdrawals and transfers

    effective_balance*: uint64 ##\
    ## Balance at stake

    slashed*: bool

    # Status epochs
    activation_eligibility_epoch*: Epoch ##\
    ## When criteria for activation were met

    activation_epoch*: Epoch
    exit_epoch*: Epoch

    withdrawable_epoch*: Epoch ##\
    ## When validator can withdraw or transfer funds

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#pendingattestation
  PendingAttestation* = object
    aggregation_bits*: CommitteeValidatorsBits
    data*: AttestationData

    inclusion_delay*: uint64

    proposer_index*: uint64

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#historicalbatch
  HistoricalBatch* = object
    block_roots* : array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    state_roots* : array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#fork
  Fork* = object
    previous_version*: Version
    current_version*: Version

    epoch*: Epoch ##\
    ## Epoch of latest fork

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#eth1data
  Eth1Data* = object
    deposit_root*: Eth2Digest
    deposit_count*: uint64
    block_hash*: Eth2Digest

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#signedvoluntaryexit
  SignedVoluntaryExit* = object
    message*: VoluntaryExit
    signature*: ValidatorSig

  TrustedSignedVoluntaryExit* = object
    message*: VoluntaryExit
    signature*: TrustedSig

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#signedbeaconblock
  SignedBeaconBlock* = object
    message*: BeaconBlock
    signature*: ValidatorSig

    root* {.dontSerialize.}: Eth2Digest # cached root of signed beacon block

  SigVerifiedSignedBeaconBlock* = object
    ## A SignedBeaconBlock with signatures verified
    ## including:
    ## - Block signature
    ## - BeaconBlockBody
    ##   - Randao reveal
    ##   - Attestations
    ##   - ProposerSlashing (SignedBeaconBlockHeader)
    ##   - AttesterSlashing (IndexedAttestation)
    ##   - SignedVoluntaryExits
    ##
    ##   - ETH1Data (Deposits) can contain invalid BLS signatures
    ##
    ## The block state transition has NOT been verified
    message*: SigVerifiedBeaconBlock
    signature*: TrustedSig

    root* {.dontSerialize.}: Eth2Digest # cached root of signed beacon block

  TrustedSignedBeaconBlock* = object
    message*: TrustedBeaconBlock
    signature*: TrustedSig

    root* {.dontSerialize.}: Eth2Digest # cached root of signed beacon block

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#signedbeaconblockheader
  SignedBeaconBlockHeader* = object
    message*: BeaconBlockHeader
    signature*: ValidatorSig

  TrustedSignedBeaconBlockHeader* = object
    message*: BeaconBlockHeader
    signature*: TrustedSig

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#aggregateandproof
  AggregateAndProof* = object
    aggregator_index*: uint64
    aggregate*: Attestation
    selection_proof*: ValidatorSig

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#signedaggregateandproof
  SignedAggregateAndProof* = object
    message*: AggregateAndProof
    signature*: ValidatorSig

  HashedBeaconState* = object
    data*: BeaconState
    root*: Eth2Digest # hash_tree_root(data)

  # This doesn't know about forks or branches in the DAG. It's for straight,
  # linear chunks of the chain.
  StateCache* = object
    shuffled_active_validator_indices*:
      Table[Epoch, seq[ValidatorIndex]]
    beacon_proposer_indices*: Table[Slot, Option[ValidatorIndex]]

  # This matches the mutable state of the Solidity deposit contract
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/solidity_deposit_contract/deposit_contract.sol
  DepositContractState* = object
    branch*: array[DEPOSIT_CONTRACT_TREE_DEPTH, Eth2Digest]
    deposit_count*: array[32, byte] # Uint256

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#validator
  ValidatorStatus* = object
    # This is a validator without the expensive, immutable, append-only parts
    # serialized. They're represented in memory to allow in-place SSZ reading
    # and writing compatibly with the full Validator object.

    pubkey* {.dontserialize.}: ValidatorPubKey

    withdrawal_credentials* {.dontserialize.}: Eth2Digest ##\
    ## Commitment to pubkey for withdrawals and transfers

    effective_balance*: uint64 ##\
    ## Balance at stake

    slashed*: bool

    # Status epochs
    activation_eligibility_epoch*: Epoch ##\
    ## When criteria for activation were met

    activation_epoch*: Epoch
    exit_epoch*: Epoch

    withdrawable_epoch*: Epoch ##\
    ## When validator can withdraw or transfer funds

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/p2p-interface.md#metadata
  MetaData* = object
    seq_number*: uint64
    attnets*: BitArray[ATTESTATION_SUBNET_COUNT]

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/p2p-interface.md#eth2-field
  ENRForkID* = object
    fork_digest*: ForkDigest
    next_fork_version*: Version
    next_fork_epoch*: Epoch

  BeaconStateDiff* = object
    # Small and/or static; always include
    slot*: Slot
    latest_block_header*: BeaconBlockHeader

    # Mod-increment/circular
    block_roots*: array[SLOTS_PER_EPOCH, Eth2Digest]
    state_roots*: array[SLOTS_PER_EPOCH, Eth2Digest]

    # Append only; either 0 or 1 per epoch
    historical_root_added*: bool
    historical_root*: Eth2Digest

    # Replace
    eth1_data*: Eth1Data

    eth1_data_votes_replaced*: bool
    eth1_data_votes*:
      List[Eth1Data, Limit(EPOCHS_PER_ETH1_VOTING_PERIOD * SLOTS_PER_EPOCH)]

    # Replace
    eth1_deposit_index*: uint64

    # Validators come in two parts, the immutable public key and mutable
    # entrance/exit/slashed information about that validator.
    validator_statuses*:
      List[ValidatorStatus, Limit VALIDATOR_REGISTRY_LIMIT]

    # Represent in full
    balances*: List[uint64, Limit VALIDATOR_REGISTRY_LIMIT]

    # Mod-increment
    randao_mix*: Eth2Digest
    slashing*: uint64

    # To start with, always overwrite, not append
    previous_epoch_attestations*:
      List[PendingAttestation, Limit(MAX_ATTESTATIONS * SLOTS_PER_EPOCH)]
    current_epoch_attestations*:
      List[PendingAttestation, Limit(MAX_ATTESTATIONS * SLOTS_PER_EPOCH)]

    justification_bits*: uint8
    previous_justified_checkpoint*: Checkpoint
    current_justified_checkpoint*: Checkpoint
    finalized_checkpoint*: Checkpoint

  DoppelgangerProtection* = object
    broadcastStartEpoch*: Epoch

type
  # Caches for computing justificiation, rewards and penalties - based on
  # implementation in Lighthouse:
  # https://github.com/sigp/lighthouse/blob/master/consensus/state_processing/src/per_epoch_processing/validator_statuses.rs
  RewardDelta* = object
    rewards*: Gwei
    penalties*: Gwei

  InclusionInfo* = object
    # The distance between the attestation slot and the slot that attestation
    # was included in block.
    delay*: uint64
    # The index of the proposer at the slot where the attestation was included.
    proposer_index*: uint64

  RewardFlags* {.pure.} = enum
    isSlashed
    canWithdrawInCurrentEpoch
    isActiveInPreviousEpoch
    isCurrentEpochAttester

    # the validator's beacon block root attestation for the first slot
    # of the _current_ epoch matches the block root known to the state.
    isCurrentEpochTargetAttester

    # Set if the validator's beacon block root attestation for the first slot of
    # the _previous_ epoch matches the block root known to the state.
    # Information used to reward the block producer of this validators
    # earliest-included attestation.
    isPreviousEpochTargetAttester
    # True if the validator's beacon block root attestation in the _previous_
    # epoch at the attestation's slot (`attestation_data.slot`) matches the
    # block root known to the state.
    isPreviousEpochHeadAttester

  RewardStatus* = object
    ## Data detailing the status of a single validator with respect to the
    ## reward processing

    # The validator's effective balance in the _current_ epoch.
    current_epoch_effective_balance*: uint64

    # True if the validator had an attestation included in the _previous_ epoch.
    is_previous_epoch_attester*: Option[InclusionInfo]

    inclusion_info*: Option[InclusionInfo]

    # Total rewards and penalties for this validator
    delta*: RewardDelta

    flags*: set[RewardFlags]

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_total_balance
  TotalBalances* = object
    # The total effective balance of all active validators during the _current_
    # epoch.
    current_epoch_raw*: Gwei
    # The total effective balance of all active validators during the _previous_
    # epoch.
    previous_epoch_raw*: Gwei
    # The total effective balance of all validators who attested during the
    # _current_ epoch.
    current_epoch_attesters_raw*: Gwei
    # The total effective balance of all validators who attested during the
    # _current_ epoch and agreed with the state about the beacon block at the
    # first slot of the _current_ epoch.
    current_epoch_target_attesters_raw*: Gwei
    # The total effective balance of all validators who attested during the
    # _previous_ epoch.
    previous_epoch_attesters_raw*: Gwei
    # The total effective balance of all validators who attested during the
    # _previous_ epoch and agreed with the state about the beacon block at the
    # first slot of the _previous_ epoch.
    previous_epoch_target_attesters_raw*: Gwei
    # The total effective balance of all validators who attested during the
    # _previous_ epoch and agreed with the state about the beacon block at the
    # time of attestation.
    previous_epoch_head_attesters_raw*: Gwei

  RewardInfo* = object
    statuses*: seq[RewardStatus]
    total_balances*: TotalBalances

func getImmutableValidatorData*(validator: Validator): ImmutableValidatorData =
  ImmutableValidatorData(
    pubkey: validator.pubkey,
    withdrawal_credentials: validator.withdrawal_credentials)

# TODO when https://github.com/nim-lang/Nim/issues/14440 lands in Status's Nim,
# switch proc {.noSideEffect.} to func.
template ethTimeUnit(typ: type) {.dirty.} =
  proc `+`*(x: typ, y: uint64): typ {.borrow, noSideEffect.}
  proc `-`*(x: typ, y: uint64): typ {.borrow, noSideEffect.}
  proc `-`*(x: uint64, y: typ): typ {.borrow, noSideEffect.}

  # Not closed over type in question (Slot or Epoch)
  proc `mod`*(x: typ, y: uint64): uint64 {.borrow, noSideEffect.}
  proc `div`*(x: typ, y: uint64): uint64 {.borrow, noSideEffect.}
  proc `div`*(x: uint64, y: typ): uint64 {.borrow, noSideEffect.}
  proc `-`*(x: typ, y: typ): uint64 {.borrow, noSideEffect.}

  proc `*`*(x: typ, y: uint64): uint64 {.borrow, noSideEffect.}

  proc `+=`*(x: var typ, y: typ) {.borrow, noSideEffect.}
  proc `+=`*(x: var typ, y: uint64) {.borrow, noSideEffect.}
  proc `-=`*(x: var typ, y: typ) {.borrow, noSideEffect.}
  proc `-=`*(x: var typ, y: uint64) {.borrow, noSideEffect.}

  # Comparison operators
  proc `<`*(x: typ, y: typ): bool {.borrow, noSideEffect.}
  proc `<`*(x: typ, y: uint64): bool {.borrow, noSideEffect.}
  proc `<`*(x: uint64, y: typ): bool {.borrow, noSideEffect.}
  proc `<=`*(x: typ, y: typ): bool {.borrow, noSideEffect.}
  proc `<=`*(x: typ, y: uint64): bool {.borrow, noSideEffect.}
  proc `<=`*(x: uint64, y: typ): bool {.borrow, noSideEffect.}

  proc `==`*(x: typ, y: typ): bool {.borrow, noSideEffect.}
  proc `==`*(x: typ, y: uint64): bool {.borrow, noSideEffect.}
  proc `==`*(x: uint64, y: typ): bool {.borrow, noSideEffect.}

  # Nim integration
  proc `$`*(x: typ): string {.borrow, noSideEffect.}
  proc hash*(x: typ): Hash {.borrow, noSideEffect.}

  # Serialization
  proc writeValue*(writer: var JsonWriter, value: typ)
                  {.raises: [IOError, Defect].}=
    writeValue(writer, uint64 value)

  proc readValue*(reader: var JsonReader, value: var typ)
                 {.raises: [IOError, SerializationError, Defect].} =
    value = typ reader.readValue(uint64)

proc writeValue*(writer: var JsonWriter, value: ValidatorIndex)
                {.raises: [IOError, Defect].} =
  writeValue(writer, distinctBase value)

proc readValue*(reader: var JsonReader, value: var ValidatorIndex)
               {.raises: [IOError, SerializationError, Defect].} =
  value = ValidatorIndex reader.readValue(distinctBase ValidatorIndex)

proc writeValue*(writer: var JsonWriter, value: CommitteeIndex)
                {.raises: [IOError, Defect].} =
  writeValue(writer, distinctBase value)

proc readValue*(reader: var JsonReader, value: var CommitteeIndex)
               {.raises: [IOError, SerializationError, Defect].} =
  value = CommitteeIndex reader.readValue(distinctBase CommitteeIndex)

proc writeValue*(writer: var JsonWriter, value: SubnetId)
                {.raises: [IOError, Defect].} =
  writeValue(writer, distinctBase value)

proc readValue*(reader: var JsonReader, value: var SubnetId)
               {.raises: [IOError, SerializationError, Defect].} =
  let v = reader.readValue(distinctBase SubnetId)
  if v > ATTESTATION_SUBNET_COUNT:
    raiseUnexpectedValue(
      reader, "Subnet id must be <= " & $ATTESTATION_SUBNET_COUNT)
  value = SubnetId(v)

proc writeValue*(writer: var JsonWriter, value: HashList)
                {.raises: [IOError, SerializationError, Defect].} =
  writeValue(writer, value.data)

proc readValue*(reader: var JsonReader, value: var HashList)
               {.raises: [IOError, SerializationError, Defect].} =
  value.resetCache()
  readValue(reader, value.data)

template writeValue*(writer: var JsonWriter, value: Version | ForkDigest) =
  writeValue(writer, $value)

proc readValue*(reader: var JsonReader, value: var Version)
               {.raises: [IOError, SerializationError, Defect].} =
  let hex = reader.readValue(string)
  try:
    hexToByteArray(hex, array[4, byte](value))
  except ValueError:
    raiseUnexpectedValue(reader, "Hex string of 4 bytes expected")

proc readValue*(reader: var JsonReader, value: var ForkDigest)
               {.raises: [IOError, SerializationError, Defect].} =
  let hex = reader.readValue(string)
  try:
    hexToByteArray(hex, array[4, byte](value))
  except ValueError:
    raiseUnexpectedValue(reader, "Hex string of 4 bytes expected")

# In general, ValidatorIndex is assumed to be convertible to/from an int. This
# should be valid for a long time, because
# https://github.com/ethereum/annotated-spec/blob/master/phase0/beacon-chain.md#configuration
# notes that "The maximum supported validator count is 2**22 (=4,194,304), or
# ~134 million ETH staking. Assuming 32 slots per epoch and 64 committees per
# slot, this gets us to a max 2048 validators in a committee."
#
# That's only active validators, so in principle, it can grow larger, but it
# should be orders of magnitude more validators than expected in the next in
# the next couple of years, than int32 indexing supports.
static: doAssert high(int) >= high(int32)

# `ValidatorIndex` seq handling.
func `[]`*[T](a: var seq[T], b: ValidatorIndex): var T =
  a[b.int]

func `[]`*[T](a: seq[T], b: ValidatorIndex): auto =
  a[b.int]

# `ValidatorIndex` Nim integration
proc `==`*(x, y: ValidatorIndex) : bool {.borrow, noSideEffect.}
proc `<`*(x, y: ValidatorIndex) : bool {.borrow, noSideEffect.}
proc hash*(x: ValidatorIndex): Hash {.borrow, noSideEffect.}
func `$`*(x: ValidatorIndex): auto = $(distinctBase(x))

# TODO Nim 1.4, but not Nim 1.2, defines a function by this name, which works
# only on openArray[int]. They do the same thing, so either's fine, when both
# overloads match. The Nim 1.4 stdlib doesn't int-convert but it's a no-op in
# its case regardless.
func toIntSet*[T](x: openArray[T]): IntSet =
  result = initIntSet()
  for item in items(x):
    result.incl(item.int)

proc `==`*(x, y: CommitteeIndex) : bool {.borrow, noSideEffect.}
proc `<`*(x, y: CommitteeIndex) : bool {.borrow, noSideEffect.}
proc hash*(x: CommitteeIndex): Hash {.borrow, noSideEffect.}
func `$`*(x: CommitteeIndex): auto = $(distinctBase(x))

proc `==`*(x, y: SubnetId) : bool {.borrow, noSideEffect.}
proc `$`*(x: SubnetId): string {.borrow, noSideEffect.}

func `as`*(d: DepositData, T: type DepositMessage): T =
  T(pubkey: d.pubkey,
    withdrawal_credentials: d.withdrawal_credentials,
    amount: d.amount)

ethTimeUnit Slot
ethTimeUnit Epoch

Json.useCustomSerialization(BeaconState.justification_bits):
  read:
    let s = reader.readValue(string)

    if s.len != 4:
      raiseUnexpectedValue(reader, "A string with 4 characters expected")

    try:
      s.parseHexInt.uint8
    except ValueError:
      raiseUnexpectedValue(reader, "The `justification_bits` value must be a hex string")

  write:
    writer.writeValue "0x" & value.toHex

Json.useCustomSerialization(BitSeq):
  read:
    try:
      BitSeq reader.readValue(string).hexToSeqByte
    except ValueError:
      raiseUnexpectedValue(reader, "A BitSeq value should be a valid hex string")

  write:
    writer.writeValue "0x" & seq[byte](value).toHex

template readValue*(reader: var JsonReader, value: var List) =
  value = type(value)(readValue(reader, seq[type value[0]]))

template writeValue*(writer: var JsonWriter, value: List) =
  writeValue(writer, asSeq value)

template readValue*(reader: var JsonReader, value: var BitList) =
  type T = type(value)
  value = T readValue(reader, BitSeq)

template writeValue*(writer: var JsonWriter, value: BitList) =
  writeValue(writer, BitSeq value)

template newClone*[T: not ref](x: T): ref T =
  # TODO not nil in return type: https://github.com/nim-lang/Nim/issues/14146
  # TODO use only when x is a function call that returns a new instance!
  let res = new typeof(x) # TODO safe to do noinit here?
  res[] = x
  res

template assignClone*[T: not ref](x: T): ref T =
  # This is a bit of a mess: if x is an rvalue (temporary), RVO kicks in for
  # newClone - if it's not, `genericAssign` will be called which is ridiculously
  # slow - so `assignClone` should be used when RVO doesn't work. sigh.
  let res = new typeof(x) # TODO safe to do noinit here?
  assign(res[], x)
  res

# TODO Careful, not nil analysis is broken / incomplete and the semantics will
#      likely change in future versions of the language:
#      https://github.com/nim-lang/RFCs/issues/250
template newClone*[T](x: ref T not nil): ref T =
  newClone(x[])

template lenu64*(x: untyped): untyped =
  x.len.uint64

func `$`*(v: ForkDigest | Version): string =
  toHex(array[4, byte](v))

func toGaugeValue*(x: uint64 | Epoch | Slot): int64 =
  if x > uint64(int64.high):
    int64.high
  else:
    int64(x)

# TODO where's borrow support when you need it
func `==`*(a, b: ForkDigest | Version): bool =
  array[4, byte](a) == array[4, byte](b)
func len*(v: ForkDigest | Version): int = sizeof(v)
func low*(v: ForkDigest | Version): int = 0
func high*(v: ForkDigest | Version): int = len(v) - 1
func `[]`*(v: ForkDigest | Version, idx: int): byte = array[4, byte](v)[idx]

func shortLog*(s: Slot): uint64 =
  s - GENESIS_SLOT

func shortLog*(e: Epoch): uint64 =
  e - GENESIS_EPOCH

func shortLog*(v: SomeBeaconBlock): auto =
  (
    slot: shortLog(v.slot),
    proposer_index: v.proposer_index,
    parent_root: shortLog(v.parent_root),
    state_root: shortLog(v.state_root),
    eth1data: v.body.eth1_data,
    graffiti: $v.body.graffiti,
    proposer_slashings_len: v.body.proposer_slashings.len(),
    attester_slashings_len: v.body.attester_slashings.len(),
    attestations_len: v.body.attestations.len(),
    deposits_len: v.body.deposits.len(),
    voluntary_exits_len: v.body.voluntary_exits.len(),
  )

func shortLog*(v: SomeSignedBeaconBlock): auto =
  (
    blck: shortLog(v.message),
    signature: shortLog(v.signature)
  )

func shortLog*(v: BeaconBlockHeader): auto =
  (
    slot: shortLog(v.slot),
    proposer_index: v.proposer_index,
    parent_root: shortLog(v.parent_root),
    state_root: shortLog(v.state_root)
  )

func shortLog*(v: SomeSignedBeaconBlockHeader): auto =
  (
    message: shortLog(v.message),
    signature: shortLog(v.signature)
  )

func shortLog*(v: DepositData): auto =
  (
    pubkey: shortLog(v.pubkey),
    withdrawal_credentials: shortlog(v.withdrawal_credentials),
    amount: v.amount,
    signature: shortLog(v.signature)
  )

func shortLog*(v: Checkpoint): auto =
  (
    epoch: shortLog(v.epoch),
    root: shortLog(v.root),
  )

func shortLog*(v: AttestationData): auto =
  (
    slot: shortLog(v.slot),
    index: v.index,
    beacon_block_root: shortLog(v.beacon_block_root),
    source: shortLog(v.source),
    target: shortLog(v.target),
  )

func shortLog*(v: PendingAttestation): auto =
  (
    aggregation_bits: v.aggregation_bits,
    data: shortLog(v.data),
    inclusion_delay: v.inclusion_delay,
    proposer_index: v.proposer_index
  )

func shortLog*(v: SomeAttestation): auto =
  (
    aggregation_bits: v.aggregation_bits,
    data: shortLog(v.data),
    signature: shortLog(v.signature)
  )

func shortLog*(v: SomeIndexedAttestation): auto =
  (
    attestating_indices: v.attesting_indices,
    data: shortLog(v.data),
    signature: shortLog(v.signature)
  )

func shortLog*(v: SomeAttesterSlashing): auto =
  (
    attestation_1: shortLog(v.attestation_1),
    attestation_2: shortLog(v.attestation_2),
  )

func shortLog*(v: SomeProposerSlashing): auto =
  (
    signed_header_1: shortLog(v.signed_header_1),
    signed_header_2: shortLog(v.signed_header_2)
  )

func shortLog*(v: VoluntaryExit): auto =
  (
    epoch: shortLog(v.epoch),
    validator_index: v.validator_index
  )

func shortLog*(v: SomeSignedVoluntaryExit): auto =
  (
    message: shortLog(v.message),
    signature: shortLog(v.signature)
  )

chronicles.formatIt Slot: it.shortLog
chronicles.formatIt Epoch: it.shortLog
chronicles.formatIt BeaconBlock: it.shortLog
chronicles.formatIt AttestationData: it.shortLog
chronicles.formatIt Attestation: it.shortLog
chronicles.formatIt Checkpoint: it.shortLog

const
  # http://facweb.cs.depaul.edu/sjost/it212/documents/ascii-pr.htm
  PrintableAsciiChars = {'!'..'~'}

func `$`*(value: GraffitiBytes): string =
  result = strip(string.fromBytes(distinctBase value),
                 leading = false,
                 chars = Whitespace + {'\0'})

  # TODO: Perhaps handle UTF-8 at some point
  if not allCharsInSet(result, PrintableAsciiChars):
    result = "0x" & toHex(distinctBase value)

func init*(T: type GraffitiBytes, input: string): GraffitiBytes
          {.raises: [ValueError, Defect].} =
  if input.len > 2 and input[0] == '0' and input[1] == 'x':
    if input.len > sizeof(GraffitiBytes) * 2 + 2:
      raise newException(ValueError, "The graffiti bytes should be less than 32")
    elif input.len mod 2 != 0:
      raise newException(ValueError, "The graffiti hex string should have an even length")

    hexToByteArray(input, distinctBase(result))
  else:
    if input.len > MAX_GRAFFITI_SIZE:
      raise newException(ValueError, "The graffiti value should be 32 characters or less")
    distinctBase(result)[0 ..< input.len] = toBytes(input)

func defaultGraffitiBytes*(): GraffitiBytes =
  const graffitiBytes =
    toBytes("Nimbus/" & fullVersionStr)
  static: doAssert graffitiBytes.len <= MAX_GRAFFITI_SIZE
  distinctBase(result)[0 ..< graffitiBytes.len] = graffitiBytes

proc writeValue*(w: var JsonWriter, value: GraffitiBytes)
                {.raises: [IOError, Defect].} =
  w.writeValue $value

template `==`*(lhs, rhs: GraffitiBytes): bool =
  distinctBase(lhs) == distinctBase(rhs)

proc readValue*(r: var JsonReader, T: type GraffitiBytes): T
               {.raises: [IOError, SerializationError, Defect].} =
  try:
    init(GraffitiBytes, r.readValue(string))
  except ValueError as err:
    r.raiseUnexpectedValue err.msg

static:
  # Sanity checks - these types should be trivial enough to copy with memcpy
  doAssert supportsCopyMem(Validator)
  doAssert supportsCopyMem(Eth2Digest)
  doAssert ATTESTATION_SUBNET_COUNT <= high(distinctBase SubnetId).int
