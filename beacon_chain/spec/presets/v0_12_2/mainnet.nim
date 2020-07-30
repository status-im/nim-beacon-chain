# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# This file contains constants that are part of the spec and thus subject to
# serialization and spec updates.

import
  math

{.experimental: "codeReordering".} # SLOTS_PER_EPOCH is use before being defined in spec

const
  # Misc
  # ---------------------------------------------------------------
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/configs/mainnet/phase0.yaml#L6

  MAX_COMMITTEES_PER_SLOT* {.intdefine.}: uint64 = 64

  TARGET_COMMITTEE_SIZE*: uint64 = 128 ##\
  ## Number of validators in the committee attesting to one shard
  ## Per spec:
  ## For the safety of crosslinks `TARGET_COMMITTEE_SIZE` exceeds
  ## [the recommended minimum committee size of 111](https://vitalik.ca/files/Ithaca201807_Sharding.pdf);
  ## with sufficient active validators (at least
  ## `SLOTS_PER_EPOCH * TARGET_COMMITTEE_SIZE`), the shuffling algorithm ensures
  ## committee sizes at least `TARGET_COMMITTEE_SIZE`. (Unbiasable randomness
  ## with a Verifiable Delay Function (VDF) will improve committee robustness
  ## and lower the safe minimum committee size.)

  MAX_VALIDATORS_PER_COMMITTEE*: uint64 = 2048 ##\
  ## votes

  MIN_PER_EPOCH_CHURN_LIMIT*: uint64 = 4
  CHURN_LIMIT_QUOTIENT*: uint64 = 2'u64 ^ 16
  SHUFFLE_ROUND_COUNT*: uint64 = 90

  HYSTERESIS_QUOTIENT*: uint64 = 4
  HYSTERESIS_DOWNWARD_MULTIPLIER*: uint64 = 1
  HYSTERESIS_UPWARD_MULTIPLIER*: uint64 = 5

  # Gwei values
  # ---------------------------------------------------------------
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/configs/mainnet/phase0.yaml#L61

  MIN_DEPOSIT_AMOUNT*: uint64 = 2'u64^0 * 10'u64^9 ##\
  ## Minimum amounth of ETH that can be deposited in one call - deposits can
  ## be used either to top up an existing validator or commit to a new one

  MAX_EFFECTIVE_BALANCE*: uint64 = 2'u64^5 * 10'u64^9 ##\
  ## Maximum amounth of ETH that can be deposited in one call

  EJECTION_BALANCE*: uint64 = 2'u64^4 * 10'u64^9 ##\
  ## Once the balance of a validator drops below this, it will be ejected from
  ## the validator pool

  EFFECTIVE_BALANCE_INCREMENT*: uint64 = 2'u64^0 * 10'u64^9

  # Initial values
  # ---------------------------------------------------------------
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/configs/mainnet/phase0.yaml#L73
  BLS_WITHDRAWAL_PREFIX*: byte = 0

  # Time parameters
  # ---------------------------------------------------------------
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/configs/mainnet/phase0.yaml#L80
  SECONDS_PER_SLOT* {.intdefine.}: uint64 = 12'u64 # Compile with -d:SECONDS_PER_SLOT=1 for 12x faster slots
  ## TODO consistent time unit across projects, similar to C++ chrono?

  MIN_ATTESTATION_INCLUSION_DELAY*: uint64 = 1 ##\
  ## (12 seconds)
  ## Number of slots that attestations stay in the attestation
  ## pool before being added to a block.
  ## The attestation delay exists so that there is time for attestations to
  ## propagate before the block is created.
  ## When creating an attestation, the validator will look at the best
  ## information known to at that time, and may not revise it during the same
  ## slot (see `is_double_vote`) - the delay gives the validator a chance to
  ## wait towards the end of the slot and still have time to publish the
  ## attestation.

  SLOTS_PER_EPOCH* {.intdefine.}: uint64 = 32 ##\
  ## (~6.4 minutes)
  ## slots that make up an epoch, at the end of which more heavy
  ## processing is done
  ## Compile with -d:SLOTS_PER_EPOCH=4 for shorter epochs

  MIN_SEED_LOOKAHEAD*: uint64 = 1 ##\
  ## epochs (~6.4 minutes)

  MAX_SEED_LOOKAHEAD*: uint64 = 4 ##\
  ## epochs (~25.6 minutes)

  EPOCHS_PER_ETH1_VOTING_PERIOD*: uint64 = 32 ##\
  ##  epochs (~3.4 hours)

  SLOTS_PER_HISTORICAL_ROOT*: uint64 = 8192 ##\
  ## slots (13 hours)

  MIN_VALIDATOR_WITHDRAWABILITY_DELAY*: uint64 = 2'u64^8 ##\
  ## epochs (~27 hours)

  SHARD_COMMITTEE_PERIOD*: uint64 = 256 # epochs (~27 hours)

  MAX_EPOCHS_PER_CROSSLINK*: uint64 = 2'u64^6 ##\
  ## epochs (~7 hours)

  MIN_EPOCHS_TO_INACTIVITY_PENALTY*: uint64 = 2'u64^2 ##\
  ## epochs (25.6 minutes)

  # State vector lengths
  # ---------------------------------------------------------------
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/configs/mainnet/phase0.yaml#L108

  EPOCHS_PER_HISTORICAL_VECTOR*: uint64 = 65536 ##\
  ## epochs (~0.8 years)

  EPOCHS_PER_SLASHINGS_VECTOR*: uint64 = 8192 ##\
  ## epochs (~36 days)

  HISTORICAL_ROOTS_LIMIT*: uint64 = 16777216 ##\
  ## epochs (~26,131 years)

  VALIDATOR_REGISTRY_LIMIT*: uint64 = 1099511627776'u64

  # Reward and penalty quotients
  # ---------------------------------------------------------------
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/configs/mainnet/phase0.yaml#L120
  BASE_REWARD_FACTOR*: uint64 = 2'u64^6
  WHISTLEBLOWER_REWARD_QUOTIENT*: uint64 = 2'u64^9
  PROPOSER_REWARD_QUOTIENT*: uint64 = 2'u64^3
  INACTIVITY_PENALTY_QUOTIENT*: uint64 = 2'u64^24
  MIN_SLASHING_PENALTY_QUOTIENT*: uint64 = 32 # 2^5

  # Max operations per block
  # ---------------------------------------------------------------
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/configs/mainnet/phase0.yaml#L134
  MAX_PROPOSER_SLASHINGS*: uint64 = 2'u64 ^ 4
  MAX_ATTESTER_SLASHINGS*: uint64 = 2'u64 ^ 1
  MAX_ATTESTATIONS*: uint64 = 2'u64 ^ 7
  MAX_DEPOSITS*: uint64 = 2'u64 ^ 4
  MAX_VOLUNTARY_EXITS*: uint64 = 2'u64 ^ 4

  # Fork choice
  # ---------------------------------------------------------------
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.1/configs/mainnet.yaml#L32
  SAFE_SLOTS_TO_UPDATE_JUSTIFIED*: uint64 = 8 # 96 seconds

  # Validators
  # ---------------------------------------------------------------
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/configs/mainnet/phase0.yaml#L38
  ETH1_FOLLOW_DISTANCE* {.intdefine.}: uint64 = 1024 # blocks ~ 4 hours
  TARGET_AGGREGATORS_PER_COMMITTEE*: uint64 = 16 # validators
  RANDOM_SUBNETS_PER_VALIDATOR*: uint64 = 1 # subnet
  EPOCHS_PER_RANDOM_SUBNET_SUBSCRIPTION*: uint64 = 256 # epochs ~ 27 hours
  SECONDS_PER_ETH1_BLOCK* {.intdefine.}: uint64 = 14 # (estimate from Eth1 mainnet)

  # Deposit contract
  # ---------------------------------------------------------------
  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/configs/mainnet/phase0.yaml#L52

  # Ethereum PoW Mainnet
  DEPOSIT_CHAIN_ID* = 1
  DEPOSIT_NETWORK_ID* = 1
