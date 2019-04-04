# beacon_chain
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
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

import
  hashes, math, json,
  chronicles, eth/[common, rlp],
  ./bitfield, ./crypto, ./digest

# TODO Data types:
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

# TODO Many of these constants should go into a config object that can be used
#      to run.. well.. a chain with different constants!

type
  Slot* = distinct uint64
  Epoch* = distinct uint64

const
  SPEC_VERSION* = "0.5.1" ## \
  ## Spec version we're aiming to be compatible with, right now
  ## TODO: improve this scheme once we can negotiate versions in protocol

  # Misc
  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#misc
  SHARD_COUNT* {.intdefine.} = 1024 ##\
  ## Number of shards supported by the network - validators will jump around
  ## between these shards and provide attestations to their state.
  ## Compile with -d:SHARD_COUNT=4 for fewer shard (= better with low validator counts)

  TARGET_COMMITTEE_SIZE* = 2^7 ##\
  ## Number of validators in the committee attesting to one shard
  ## Per spec:
  ## For the safety of crosslinks `TARGET_COMMITTEE_SIZE` exceeds
  ## [the recommended minimum committee size of 111](https://vitalik.ca/files/Ithaca201807_Sharding.pdf);
  ## with sufficient active validators (at least
  ## `SLOTS_PER_EPOCH * TARGET_COMMITTEE_SIZE`), the shuffling algorithm ensures
  ## committee sizes at least `TARGET_COMMITTEE_SIZE`. (Unbiasable randomness
  ## with a Verifiable Delay Function (VDF) will improve committee robustness
  ## and lower the safe minimum committee size.)

  MAX_BALANCE_CHURN_QUOTIENT* = 2^5 ##\
  ## At most `1/MAX_BALANCE_CHURN_QUOTIENT` of the validators can change during
  ## each validator registry change.

  MAX_INDICES_PER_SLASHABLE_VOTE* = 2^12 ##\
  ## votes

  MAX_EXIT_DEQUEUES_PER_EPOCH* = 4

  SHUFFLE_ROUND_COUNT* = 90

  # Deposit contract
  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#deposit-contract
  DEPOSIT_CONTRACT_TREE_DEPTH* = 32

  # Gwei values
  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#gwei-values
  MIN_DEPOSIT_AMOUNT* = 2'u64^0 * 10'u64^9 ##\
  ## Minimum amounth of ETH that can be deposited in one call - deposits can
  ## be used either to top up an existing validator or commit to a new one
  MAX_DEPOSIT_AMOUNT* = 2'u64^5 * 10'u64^9 ##\
  ## Maximum amounth of ETH that can be deposited in one call

  FORK_CHOICE_BALANCE_INCREMENT* = 2'u64^0 * 10'u64^9

  EJECTION_BALANCE* = 2'u64^4 * 10'u64^9 ##\
  ## Once the balance of a validator drops below this, it will be ejected from
  ## the validator pool

  # Time parameter, here so that GENESIS_EPOCH can access it
  SLOTS_PER_EPOCH* {.intdefine.} = 64 ##\
  ## (~6.4 minutes)
  ## slots that make up an epoch, at the end of which more heavy
  ## processing is done
  ## Compile with -d:SLOTS_PER_EPOCH=4 for shorter epochs

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#initial-values
  # TODO: in 0.5.0, GENESIS_FORK_VERSION defined as int, but used as [byte]
  GENESIS_FORK_VERSION* = [0'u8, 0'u8, 0'u8, 0'u8]
  GENESIS_SLOT* = (2'u64^32).Slot
  GENESIS_EPOCH* = (GENESIS_SLOT.uint64 div SLOTS_PER_EPOCH).Epoch ##\
  ## slot_to_epoch(GENESIS_SLOT)
  GENESIS_START_SHARD* = 0'u64
  FAR_FUTURE_EPOCH* = (not 0'u64).Epoch # 2^64 - 1 in spec
  ZERO_HASH* = Eth2Digest()
  EMPTY_SIGNATURE* = ValidatorSig()
  BLS_WITHDRAWAL_PREFIX_BYTE* = 0'u8

  # Time parameters
  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#time-parameters
  SECONDS_PER_SLOT*{.intdefine.} = 6'u64 # Compile with -d:SECONDS_PER_SLOT=1 for 6x faster slots
  ## TODO consistent time unit across projects, similar to C++ chrono?

  MIN_ATTESTATION_INCLUSION_DELAY* = 2'u64^2 ##\
  ## (24 seconds)
  ## Number of slots that attestations stay in the attestation
  ## pool before being added to a block.
  ## The attestation delay exists so that there is time for attestations to
  ## propagate before the block is created.
  ## When creating an attestation, the validator will look at the best
  ## information known to at that time, and may not revise it during the same
  ## slot (see `is_double_vote`) - the delay gives the validator a chance to
  ## wait towards the end of the slot and still have time to publish the
  ## attestation.

  # SLOTS_PER_EPOCH is defined above.

  MIN_SEED_LOOKAHEAD* = 1 ##\
  ## epochs (~6.4 minutes)

  ACTIVATION_EXIT_DELAY* = 4 ##\
  ## epochs (~25.6 minutes)

  EPOCHS_PER_ETH1_VOTING_PERIOD* = 2'u64^4 ##\
  ## epochs (~1.7 hours)

  SLOTS_PER_HISTORICAL_ROOT* = 8192 ##\
  ## slots (13 hours)

  MIN_VALIDATOR_WITHDRAWABILITY_DELAY* = 2'u64^8 ##\
  ## epochs (~27 hours)

  PERSISTENT_COMMITTEE_PERIOD* = 2'u64^11 ##\
  ## epochs (9 days)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#state-list-lengths
  LATEST_RANDAO_MIXES_LENGTH* = 8192
  LATEST_ACTIVE_INDEX_ROOTS_LENGTH* = 8192 # 2'u64^13, epochs
  LATEST_SLASHED_EXIT_LENGTH* = 8192 # epochs

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#reward-and-penalty-quotients
  BASE_REWARD_QUOTIENT* = 2'u64^5 ##\
  ## The `BASE_REWARD_QUOTIENT` parameter dictates the per-epoch reward. It
  ## corresponds to ~2.54% annual interest assuming 10 million participating
  ## ETH in every epoch.
  WHISTLEBLOWER_REWARD_QUOTIENT* = 2'u64^9
  ATTESTATION_INCLUSION_REWARD_QUOTIENT* = 2'u64^3
  INACTIVITY_PENALTY_QUOTIENT* = 2'u64^24
  MIN_PENALTY_QUOTIENT* = 32 # 2^5

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#max-transactions-per-block
  MAX_PROPOSER_SLASHINGS* = 2^4
  MAX_ATTESTER_SLASHINGS* = 2^0
  MAX_ATTESTATIONS* = 2^7
  MAX_DEPOSITS* = 2^4
  MAX_VOLUNTARY_EXITS* = 2^4
  MAX_TRANSFERS* = 2^4

type
  ValidatorIndex* = range[0'u32 .. 0xFFFFFF'u32] # TODO: wrap-around

  Shard* = uint64
  Gwei* = uint64

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#proposerslashing
  ProposerSlashing* = object
    proposer_index*: uint64 ##\
    ## Proposer index

    header_1*: BeaconBlockHeader ##\
    # First block header

    header_2*: BeaconBlockHeader ##\
    # Second block header

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#attesterslashing
  AttesterSlashing* = object
    slashable_attestation_1*: SlashableAttestation ## \
    ## First slashable attestation
    slashable_attestation_2*: SlashableAttestation ## \
    ## Second slashable attestation

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#slashableattestation
  SlashableAttestation* = object
    validator_indices*: seq[uint64] ##\
    ## Validator indices

    data*: AttestationData ## \
    ## Attestation data

    custody_bitfield*: BitField ##\
    ## Custody bitfield

    aggregate_signature*: ValidatorSig ## \
    ## Aggregate signature

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#attestation
  Attestation* = object
    aggregation_bitfield*: BitField ##\
    ## Attester aggregation bitfield

    data*: AttestationData ##\
    ## Attestation data

    custody_bitfield*: BitField ##\
    ## Custody bitfield

    aggregate_signature*: ValidatorSig ##\
    ## BLS aggregate signature

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#attestationdata
  AttestationData* = object
    # LMD GHOST vote
    slot*: Slot
    beacon_block_root*: Eth2Digest

    # FFG vote
    source_epoch*: Epoch
    source_root*: Eth2Digest
    target_root*: Eth2Digest

    # Crosslink vote
    shard*: uint64
    previous_crosslink*: Crosslink
    crosslink_data_root*: Eth2Digest

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#attestationdataandcustodybit
  AttestationDataAndCustodyBit* = object
    data*: AttestationData
    custody_bit*: bool

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#deposit
  Deposit* = object
    proof*: array[DEPOSIT_CONTRACT_TREE_DEPTH, Eth2Digest] ##\
    ## Branch in the deposit tree

    index*: uint64 ##\
    ## Index in the deposit tree

    deposit_data*: DepositData ##\
    ## Data

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#depositdata
  DepositData* = object
    amount*: uint64 ## Amount in Gwei
    timestamp*: uint64 # Timestamp from deposit contract
    deposit_input*: DepositInput

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#depositinput
  DepositInput* = object
    pubkey*: ValidatorPubKey
    withdrawal_credentials*: Eth2Digest
    proof_of_possession*: ValidatorSig ##\
    ## A BLS signature of this `DepositInput`

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#voluntaryexit
  VoluntaryExit* = object
    # Minimum epoch for processing exit
    epoch*: Epoch
    # Index of the exiting validator
    validator_index*: uint64
    # Validator signature
    signature*: ValidatorSig

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#transfer
  Transfer* = object
    sender*: uint64 ##\
    ## Sender index

    recipient*: uint64 ##\
    ## Recipient index

    amount*: uint64 ##\
    ## Amount in Gwei

    fee*: uint64 ##\
    ## Fee in Gwei for block proposer

    slot*: uint64 ##\
    ## Inclusion slot

    pubkey*: ValidatorPubKey ##\
    ## Sender withdrawal pubkey

    signature*: ValidatorSig ##\
    ## Sender signature

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#beaconblock
  BeaconBlock* = object
    ## For each slot, a proposer is chosen from the validator pool to propose
    ## a new block. Once the block as been proposed, it is transmitted to
    ## validators that will have a chance to vote on it through attestations.
    ## Each block collects attestations, or votes, on past blocks, thus a chain
    ## is formed.

    slot*: Slot

    previous_block_root*: Eth2Digest ##\
    ##\ Root hash of the previous block

    state_root*: Eth2Digest ##\
    ## The state root, _after_ this block has been processed

    body*: BeaconBlockBody

    signature*: ValidatorSig ##\
    ## Proposer signature

  #https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#beaconblockheader
  BeaconBlockHeader* = object
    slot*: Slot
    previous_block_root*: Eth2Digest
    state_root*: Eth2Digest
    block_body_root*: Eth2Digest
    signature*: ValidatorSig

  BeaconBlockHeaderRLP* = object
    ## Same as BeaconBlock, except `body` is the `hash_tree_root` of the
    ## associated BeaconBlockBody.
    # TODO: Dry it up with BeaconBlock
    # TODO: As a first step, don't change RLP output; only previous user,
    # but as with others, randao_reveal and eth1_data move to body.
    # This is from before spec had a version.
    slot*: uint64
    parent_root*: Eth2Digest
    state_root*: Eth2Digest
    randao_reveal*: ValidatorSig
    eth1_data*: Eth1Data
    signature*: ValidatorSig
    body*: Eth2Digest

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#beaconblockbody
  BeaconBlockBody* = object
    randao_reveal*: ValidatorSig
    eth1_data*: Eth1Data
    proposer_slashings*: seq[ProposerSlashing]
    attester_slashings*: seq[AttesterSlashing]
    attestations*: seq[Attestation]
    deposits*: seq[Deposit]
    voluntary_exits*: seq[VoluntaryExit]
    transfers*: seq[Transfer]

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.1/specs/core/0_beacon-chain.md#beaconstate
  BeaconState* = object
    slot*: Slot
    genesis_time*: uint64
    fork*: Fork ##\
    ## For versioning hard forks

    # Validator registry
    validator_registry*: seq[Validator]
    validator_balances*: seq[uint64] ##\
    ## Validator balances in Gwei!

    validator_registry_update_epoch*: Epoch

    # Randomness and committees
    latest_randao_mixes*: array[LATEST_RANDAO_MIXES_LENGTH, Eth2Digest]
    previous_shuffling_start_shard*: uint64
    current_shuffling_start_shard*: uint64
    previous_shuffling_epoch*: Epoch
    current_shuffling_epoch*: Epoch
    previous_shuffling_seed*: Eth2Digest
    current_shuffling_seed*: Eth2Digest

    # Finality
    previous_epoch_attestations*: seq[PendingAttestation]
    current_epoch_attestations*: seq[PendingAttestation]
    previous_justified_epoch*: Epoch
    current_justified_epoch*: Epoch
    previous_justified_root*: Eth2Digest
    current_justified_root*: Eth2Digest
    justification_bitfield*: uint64
    finalized_epoch*: Epoch
    finalized_root*: Eth2Digest

    # Recent state
    latest_crosslinks*: array[SHARD_COUNT, Crosslink]
    latest_block_roots*: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest] ##\
    ## Needed to process attestations, older to newer
    latest_state_roots*: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    latest_active_index_roots*: array[LATEST_ACTIVE_INDEX_ROOTS_LENGTH, Eth2Digest]

    latest_slashed_balances*: array[LATEST_SLASHED_EXIT_LENGTH, uint64] ##\
    ## Balances penalized in the current withdrawal period

    latest_block_header*: BeaconBlockHeader ##\
    ## `latest_block_header.state_root == ZERO_HASH` temporarily
    historical_roots*: seq[Eth2Digest]

    # Ethereum 1.0 chain data
    latest_eth1_data*: Eth1Data
    eth1_data_votes*: seq[Eth1DataVote]
    deposit_index*: uint64

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#validator
  Validator* = object
    pubkey*: ValidatorPubKey ##\
    ## BLS public key

    withdrawal_credentials*: Eth2Digest ##\
    ## Withdrawal credentials

    activation_epoch*: Epoch ##\
    ## Epoch when validator activated

    exit_epoch*: Epoch ##\
    ## Epoch when validator exited

    withdrawable_epoch*: Epoch ##\
    ## Epoch when validator is eligible to withdraw

    initiated_exit*: bool ##\
    ## Did the validator initiate an exit

    slashed*: bool ##\
    ## Was the validator slashed

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#crosslink
  Crosslink* = object
    epoch*: Epoch ##\
    ## Epoch number

    crosslink_data_root*: Eth2Digest ##\
    ## Shard data since the previous crosslink

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#pendingattestation
  PendingAttestation* = object
    aggregation_bitfield*: BitField           ## Attester participation bitfield
    data*: AttestationData                    ## Attestation data
    custody_bitfield*: BitField               ## Custody bitfield
    inclusion_slot*: Slot                     ## Inclusion slot

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#historicalbatch
  HistoricalBatch* = object
    block_roots* : array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest] ##\
    ## Block roots

    state_roots* : array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest] ##\
    ## State roots

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#fork
  Fork* = object
    previous_version*: array[4, byte] ##\
    ## Previous fork version

    current_version*: array[4, byte] ##\
    ## Current fork version

    epoch*: Epoch ##\
    ## Fork epoch number

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#eth1data
  Eth1Data* = object
    deposit_root*: Eth2Digest ##\
    ## Data being voted for

    block_hash*: Eth2Digest ##\
    ## Block hash

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#eth1datavote
  Eth1DataVote* = object
    eth1_data*: Eth1Data ##\
    ## Data being voted for

    vote_count*: uint64 ##\
    ## Vote count

  ## TODO remove or otherwise conditional-compile this, since it's for light
  ## client but not in spec
  ValidatorSetDeltaFlags* {.pure.} = enum
    Activation = 0
    Exit = 1

  # https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#signature-domains
  SignatureDomain* {.pure.} = enum
    DOMAIN_BEACON_BLOCK = 0
    DOMAIN_RANDAO = 1
    DOMAIN_ATTESTATION = 2
    DOMAIN_DEPOSIT = 3
    DOMAIN_VOLUNTARY_EXIT = 4
    DOMAIN_TRANSFER = 5

  # TODO: not in spec
  CrosslinkCommittee* = tuple[committee: seq[ValidatorIndex], shard: uint64]

func shortValidatorKey*(state: BeaconState, validatorIdx: int): string =
    ($state.validator_registry[validatorIdx].pubkey)[0..7]

template ethTimeUnit(typ: type) {.dirty.} =
  proc `+`*(x: typ, y: uint64): typ {.borrow.}
  proc `-`*(x: typ, y: uint64): typ {.borrow.}
  proc `-`*(x: uint64, y: typ): typ {.borrow.}

  # Not closed over type in question (Slot or Epoch)
  proc `mod`*(x: typ, y: uint64): uint64 {.borrow.}
  proc `div`*(x: typ, y: uint64): uint64 {.borrow.}
  proc `div`*(x: uint64, y: typ): uint64 {.borrow.}
  proc `-`*(x: typ, y: typ): uint64 {.borrow.}

  proc `*`*(x: typ, y: uint64): uint64 {.borrow.}

  proc `+=`*(x: var typ, y: uint64) {.borrow.}
  proc `-=`*(x: var typ, y: uint64) {.borrow.}

  # Comparison operators
  proc `<`*(x: typ, y: typ): bool {.borrow.}
  proc `<`*(x: typ, y: uint64): bool {.borrow.}
  proc `<`*(x: uint64, y: typ): bool {.borrow.}
  proc `<=`*(x: typ, y: typ): bool {.borrow.}
  proc `<=`*(x: typ, y: uint64): bool {.borrow.}
  proc `<=`*(x: uint64, y: typ): bool {.borrow.}

  proc `==`*(x: typ, y: typ): bool {.borrow.}
  proc `==`*(x: typ, y: uint64): bool {.borrow.}
  proc `==`*(x: uint64, y: typ): bool {.borrow.}

  # Nim integration
  proc `$`*(x: typ): string {.borrow.}
  proc hash*(x: typ): Hash {.borrow.}
  proc `%`*(x: typ): JsonNode {.borrow.}

  # Serialization
  proc read*(rlp: var Rlp, T: type typ): typ {.inline.} =
    typ(rlp.read(uint64))

  proc append*(writer: var RlpWriter, value: typ) =
    writer.append uint64(value)

  proc writeValue*(writer: var JsonWriter, value: typ) =
    writeValue(writer, uint64 value)

  proc readValue*(reader: var JsonReader, value: var typ) =
    value = typ reader.readValue(uint64)

proc `%`*(i: uint64): JsonNode =
  % int(i)

ethTimeUnit Slot
ethTimeUnit Epoch

func humaneSlotNum*(s: Slot): uint64 =
  s - GENESIS_SLOT

func humaneEpochNum*(e: Epoch): uint64 =
  e - GENESIS_EPOCH

func shortLog*(v: BeaconBlock): tuple[
    slot: uint64, previous_block_root: string, state_root: string,
    #[ eth1_data ]#
    proposer_slashings_len: int, attester_slashings_len: int,
    attestations_len: int,
    deposits_len: int,
    voluntary_exits_len: int,
    transfers_len: int,
    signature: string
  ] = (
    humaneSlotNum(v.slot), shortLog(v.previous_block_root),
    shortLog(v.state_root), v.body.proposer_slashings.len(),
    v.body.attester_slashings.len(), v.body.attestations.len(),
    v.body.deposits.len(), v.body.voluntary_exits.len(), v.body.transfers.len(),
    shortLog(v.signature)
  )

func shortLog*(v: AttestationData): tuple[
      slot: uint64, beacon_block_root: string, source_epoch: uint64,
      target_root: string, source_root: string, shard: uint64,
      previous_crosslink_epoch: uint64, previous_crosslink_data_root: string,
      crosslink_data_root: string
    ] = (
      humaneSlotNum(v.slot), shortLog(v.beacon_block_root),
      humaneEpochNum(v.source_epoch), shortLog(v.target_root),
      shortLog(v.source_root),
      v.shard, humaneEpochNum(v.previous_crosslink.epoch),
      shortLog(v.previous_crosslink.crosslink_data_root),
      shortLog(v.crosslink_data_root)
    )

chronicles.formatIt Slot: it.humaneSlotNum
chronicles.formatIt Epoch: it.humaneEpochNum
chronicles.formatIt BeaconBlock: it.shortLog
chronicles.formatIt AttestationData: it.shortLog

import nimcrypto, json_serialization
export json_serialization
export writeValue, readValue, append, read

