# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# State transition - epoch processing, as described in
# https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#beacon-chain-state-transition-function
#
# The entry point is `process_epoch`, which is at the bottom of this file.
#
# General notes about the code:
# * Weird styling - the sections taken from the spec use python styling while
#   the others use NEP-1 - helps grepping identifiers in spec
# * When updating the code, add TODO sections to mark where there are clear
#   improvements to be made - other than that, keep things similar to spec unless
#   motivated by security or performance considerations

{.push raises: [Defect].}

import
  std/[math, sequtils, tables, algorithm],
  stew/[bitops2], chronicles,
  ../extras,
  ../ssz/merkleization,
  ./beaconstate, ./crypto, ./datatypes, ./digest, ./helpers, ./validator,
  ../../nbench/bench_lab

# Logging utilities
# --------------------------------------------------------

logScope: topics = "consens"

# Accessors that implement the max condition in `get_total_balance`:
# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_total_balance
template current_epoch*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.current_epoch_raw)
template previous_epoch*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.previous_epoch_raw)
template current_epoch_attesters*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.current_epoch_attesters_raw)
template current_epoch_target_attesters*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.current_epoch_target_attesters_raw)
template previous_epoch_attesters*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.previous_epoch_attesters_raw)
template previous_epoch_target_attesters*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.previous_epoch_target_attesters_raw)
template previous_epoch_head_attesters*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.previous_epoch_head_attesters_raw)

func init*(rewards: var RewardInfo, state: BeaconState) =
  rewards.total_balances = TotalBalances()
  rewards.statuses.setLen(state.validators.len)

  for i in 0..<state.validators.len:
    let v = unsafeAddr state.validators[i]
    var flags: set[RewardFlags]

    if v[].slashed:
      flags.incl(isSlashed)
    if state.get_current_epoch() >= v[].withdrawable_epoch:
      flags.incl canWithdrawInCurrentEpoch

    if v[].is_active_validator(state.get_current_epoch()):
      rewards.total_balances.current_epoch_raw += v[].effective_balance

    if v[].is_active_validator(state.get_previous_epoch()):
      flags.incl isActiveInPreviousEpoch
      rewards.total_balances.previous_epoch_raw += v[].effective_balance

    rewards.statuses[i] = RewardStatus(
      current_epoch_effective_balance: v[].effective_balance,
      flags: flags,
    )

func add(a: var RewardDelta, b: RewardDelta) =
  a.rewards += b.rewards
  a.penalties += b.penalties

func process_attestation(
    self: var RewardInfo, state: BeaconState, a: PendingAttestation,
    cache: var StateCache) =
  # Collect information about the attestation
  var
    flags: set[RewardFlags]
    is_previous_epoch_attester: Option[InclusionInfo]

  if a.data.target.epoch == state.get_current_epoch():
    flags.incl isCurrentEpochAttester

    if a.data.target.root == get_block_root(state, state.get_current_epoch()):
      flags.incl isCurrentEpochTargetAttester

  elif a.data.target.epoch == state.get_previous_epoch():
    is_previous_epoch_attester = some(InclusionInfo(
      delay: a.inclusion_delay,
      proposer_index: a.proposer_index,
    ))

    if a.data.target.root == get_block_root(state, state.get_previous_epoch()):
      flags.incl isPreviousEpochTargetAttester

      if a.data.beacon_block_root == get_block_root_at_slot(state, a.data.slot):
        flags.incl isPreviousEpochHeadAttester

  # Update the cache for all participants
  for validator_index in get_attesting_indices(
      state, a.data, a.aggregation_bits, cache):
    template v(): untyped = self.statuses[validator_index]

    v.flags = v.flags + flags

    if is_previous_epoch_attester.isSome:
      if v.isPreviousEpochAttester.isSome:
        if is_previous_epoch_attester.get().delay <
            v.is_previous_epoch_attester.get().delay:
          v.is_previous_epoch_attester = is_previous_epoch_attester
      else:
        v.is_previous_epoch_attester = is_previous_epoch_attester

func process_attestations*(
    self: var RewardInfo, state: BeaconState, cache: var StateCache) =
  # Walk state attestations and update the status information
  for a in state.previous_epoch_attestations:
    process_attestation(self, state, a, cache)
  for a in state.current_epoch_attestations:
    process_attestation(self, state, a, cache)

  for idx, v in self.statuses:
    if isSlashed in v.flags:
      continue

    let validator_balance = state.validators[idx].effective_balance

    if isCurrentEpochAttester in v.flags:
      self.total_balances.current_epoch_attesters_raw += validator_balance

    if isCurrentEpochTargetAttester in v.flags:
      self.total_balances.current_epoch_target_attesters_raw += validator_balance

    if v.is_previous_epoch_attester.isSome():
      self.total_balances.previous_epoch_attesters_raw += validator_balance

    if isPreviousEpochTargetAttester in v.flags:
      self.total_balances.previous_epoch_target_attesters_raw += validator_balance

    if isPreviousEpochHeadAttester in v.flags:
      self.total_balances.previous_epoch_head_attesters_raw += validator_balance

func is_eligible_validator*(validator: RewardStatus): bool =
  isActiveInPreviousEpoch in validator.flags or
    (isSlashed in validator.flags and
      (canWithdrawInCurrentEpoch notin validator.flags))

# Spec
# --------------------------------------------------------

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_total_active_balance
func get_total_active_balance*(state: BeaconState, cache: var StateCache): Gwei =
  ## Return the combined effective balance of the active validators.
  # Note: ``get_total_balance`` returns ``EFFECTIVE_BALANCE_INCREMENT`` Gwei
  # minimum to avoid divisions by zero.

  let epoch = state.get_current_epoch()

  get_total_balance(
    state, cache.get_shuffled_active_validator_indices(state, epoch))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#justification-and-finalization
proc process_justification_and_finalization*(state: var BeaconState,
    total_balances: TotalBalances, flags: UpdateFlags = {}) {.nbench.} =
  # Initial FFG checkpoint values have a `0x00` stub for `root`.
  # Skip FFG updates in the first two epochs to avoid corner cases that might
  # result in modifying this stub.
  if get_current_epoch(state) <= GENESIS_EPOCH + 1:
    return

  let
    previous_epoch = get_previous_epoch(state)
    current_epoch = get_current_epoch(state)
    old_previous_justified_checkpoint = state.previous_justified_checkpoint
    old_current_justified_checkpoint = state.current_justified_checkpoint

  # Process justifications
  state.previous_justified_checkpoint = state.current_justified_checkpoint

  ## Spec:
  ## state.justification_bits[1:] = state.justification_bits[:-1]
  ## state.justification_bits[0] = 0b0

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#constants
  const JUSTIFICATION_BITS_LENGTH = 4

  state.justification_bits = (state.justification_bits shl 1) and
    cast[uint8]((2^JUSTIFICATION_BITS_LENGTH) - 1)

  let total_active_balance = total_balances.current_epoch
  if total_balances.previous_epoch_target_attesters * 3 >=
      total_active_balance * 2:
    state.current_justified_checkpoint =
      Checkpoint(epoch: previous_epoch,
                 root: get_block_root(state, previous_epoch))
    state.justification_bits.setBit 1

    trace "Justified with previous epoch",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.current_justified_checkpoint)
  elif verifyFinalization in flags:
    warn "Low attestation participation in previous epoch",
      total_balances, epoch = get_current_epoch(state)

  if total_balances.current_epoch_target_attesters * 3 >=
      total_active_balance * 2:
    state.current_justified_checkpoint =
      Checkpoint(epoch: current_epoch,
                 root: get_block_root(state, current_epoch))
    state.justification_bits.setBit 0

    trace "Justified with current epoch",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.current_justified_checkpoint)

  # Process finalizations
  let bitfield = state.justification_bits

  ## The 2nd/3rd/4th most recent epochs are justified, the 2nd using the 4th
  ## as source
  if (bitfield and 0b1110) == 0b1110 and
     old_previous_justified_checkpoint.epoch + 3 == current_epoch:
    state.finalized_checkpoint = old_previous_justified_checkpoint

    trace "Finalized with rule 234",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

  ## The 2nd/3rd most recent epochs are justified, the 2nd using the 3rd as
  ## source
  if (bitfield and 0b110) == 0b110 and
     old_previous_justified_checkpoint.epoch + 2 == current_epoch:
    state.finalized_checkpoint = old_previous_justified_checkpoint

    trace "Finalized with rule 23",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

  ## The 1st/2nd/3rd most recent epochs are justified, the 1st using the 3rd as
  ## source
  if (bitfield and 0b111) == 0b111 and
     old_current_justified_checkpoint.epoch + 2 == current_epoch:
    state.finalized_checkpoint = old_current_justified_checkpoint

    trace "Finalized with rule 123",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

  ## The 1st/2nd most recent epochs are justified, the 1st using the 2nd as
  ## source
  if (bitfield and 0b11) == 0b11 and
     old_current_justified_checkpoint.epoch + 1 == current_epoch:
    state.finalized_checkpoint = old_current_justified_checkpoint

    trace "Finalized with rule 12",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#helpers
func get_base_reward_sqrt*(state: BeaconState, index: ValidatorIndex,
    total_balance_sqrt: auto): Gwei =
  # Spec function recalculates total_balance every time, which creates an
  # O(n^2) situation.
  let effective_balance = state.validators[index].effective_balance
  effective_balance * BASE_REWARD_FACTOR div
    total_balance_sqrt div BASE_REWARDS_PER_EPOCH

func get_proposer_reward(base_reward: Gwei): Gwei =
  # Spec version recalculates get_total_active_balance(state) quadratically
  base_reward div PROPOSER_REWARD_QUOTIENT

func is_in_inactivity_leak(finality_delay: uint64): bool =
  finality_delay > MIN_EPOCHS_TO_INACTIVITY_PENALTY

func get_finality_delay(state: BeaconState): uint64 =
  get_previous_epoch(state) - state.finalized_checkpoint.epoch

func get_attestation_component_delta(is_unslashed_attester: bool,
                                     attesting_balance: Gwei,
                                     total_balance: Gwei,
                                     base_reward: uint64,
                                     finality_delay: uint64): RewardDelta =
  # Helper with shared logic for use by get source, target, and head deltas
  # functions
  if is_unslashed_attester:
    if is_in_inactivity_leak(finality_delay):
      # Since full base reward will be canceled out by inactivity penalty deltas,
      # optimal participation receives full base reward compensation here.
      RewardDelta(rewards: base_reward)
    else:
      let reward_numerator =
        base_reward * (attesting_balance div EFFECTIVE_BALANCE_INCREMENT)
      RewardDelta(rewards:
        reward_numerator div (total_balance div EFFECTIVE_BALANCE_INCREMENT))
  else:
    RewardDelta(penalties: base_reward)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#components-of-attestation-deltas
func get_source_delta*(validator: RewardStatus,
                       base_reward: uint64,
                       total_balances: TotalBalances,
                       finality_delay: uint64): RewardDelta =
  ## Return attester micro-rewards/penalties for source-vote for each validator.
  get_attestation_component_delta(
    validator.is_previous_epoch_attester.isSome() and
      (isSlashed notin validator.flags),
    total_balances.previous_epoch_attesters,
    total_balances.current_epoch,
    base_reward,
    finality_delay)

func get_target_delta*(validator: RewardStatus,
                       base_reward: uint64,
                       total_balances: TotalBalances,
                       finality_delay: uint64): RewardDelta =
  ## Return attester micro-rewards/penalties for target-vote for each validator.
  get_attestation_component_delta(
    isPreviousEpochTargetAttester in validator.flags and
      (isSlashed notin validator.flags),
    total_balances.previous_epoch_target_attesters,
    total_balances.current_epoch,
    base_reward,
    finality_delay)

func get_head_delta*(validator: RewardStatus,
                     base_reward: uint64,
                     total_balances: TotalBalances,
                     finality_delay: uint64): RewardDelta =
  ## Return attester micro-rewards/penalties for head-vote for each validator.
  get_attestation_component_delta(
    isPreviousEpochHeadAttester in validator.flags and
      (isSlashed notin validator.flags),
    total_balances.previous_epoch_head_attesters,
    total_balances.current_epoch,
    base_reward,
    finality_delay)

func get_inclusion_delay_delta*(validator: RewardStatus,
                                base_reward: uint64):
                                  (RewardDelta, Option[(uint64, RewardDelta)]) =
  ## Return proposer and inclusion delay micro-rewards/penalties for each validator.
  if validator.is_previous_epoch_attester.isSome() and (isSlashed notin validator.flags):
    let
      inclusion_info = validator.is_previous_epoch_attester.get()
      proposer_reward = get_proposer_reward(base_reward)
      proposer_delta = RewardDelta(rewards: proposer_reward)

    let
      max_attester_reward = base_reward - proposer_reward
      delta = RewardDelta(rewards: max_attester_reward div inclusion_info.delay)
      proposer_index = inclusion_info.proposer_index;
    return (delta, some((proposer_index, proposer_delta)))

func get_inactivity_penalty_delta*(validator: RewardStatus,
                                   base_reward: Gwei,
                                   finality_delay: uint64): RewardDelta =
  ## Return inactivity reward/penalty deltas for each validator.
  var delta: RewardDelta

  if is_in_inactivity_leak(finality_delay):
    # If validator is performing optimally this cancels all rewards for a neutral balance
    delta.penalties +=
      BASE_REWARDS_PER_EPOCH * base_reward - get_proposer_reward(base_reward)

    # Additionally, all validators whose FFG target didn't match are penalized extra
    # This condition is equivalent to this condition from the spec:
    # `index not in get_unslashed_attesting_indices(state, matching_target_attestations)`
    if (isSlashed in validator.flags) or
        (isPreviousEpochTargetAttester notin validator.flags):
      delta.penalties +=
        validator.current_epoch_effective_balance * finality_delay div
          INACTIVITY_PENALTY_QUOTIENT

  delta

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_attestation_deltas
func get_attestation_deltas(state: BeaconState, rewards: var RewardInfo) =
  ## Update rewards with attestation reward/penalty deltas for each validator.

  let
    finality_delay = get_finality_delay(state)
    total_balance = rewards.total_balances.current_epoch
    total_balance_sqrt = integer_squareroot(total_balance)
  # Filter out ineligible validators. All sub-functions of the spec do this
  # except for `get_inclusion_delay_deltas`. It's safe to do so here because
  # any validator that is in the unslashed indices of the matching source
  # attestations is active, and therefore eligible.
  for index, validator in rewards.statuses.mpairs():
    if not is_eligible_validator(validator):
      continue

    let
      base_reward = get_base_reward_sqrt(
        state, index.ValidatorIndex, total_balance_sqrt)

    let
      source_delta = get_source_delta(
        validator, base_reward, rewards.total_balances, finality_delay)
      target_delta = get_target_delta(
        validator, base_reward, rewards.total_balances, finality_delay)
      head_delta = get_head_delta(
        validator, base_reward, rewards.total_balances, finality_delay)
      (inclusion_delay_delta, proposer_delta) =
        get_inclusion_delay_delta(validator, base_reward)
      inactivity_delta = get_inactivity_penalty_delta(
        validator, base_reward, finality_delay)

    validator.delta.add source_delta
    validator.delta.add target_delta
    validator.delta.add head_delta
    validator.delta.add inclusion_delay_delta
    validator.delta.add inactivity_delta

    if proposer_delta.isSome:
      let proposer_index = proposer_delta.get()[0]
      if proposer_index < rewards.statuses.lenu64:
        rewards.statuses[proposer_index].delta.add(
          proposer_delta.get()[1])

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#process_rewards_and_penalties
func process_rewards_and_penalties(
    state: var BeaconState, rewards: var RewardInfo) {.nbench.} =
  # No rewards are applied at the end of `GENESIS_EPOCH` because rewards are
  # for work done in the previous epoch
  doAssert rewards.statuses.len == state.validators.len

  if get_current_epoch(state) == GENESIS_EPOCH:
    return

  get_attestation_deltas(state, rewards)

  # Here almost all balances are updated (assuming most validators are active) -
  # clearing the cache becomes a bottleneck if done item by item because of the
  # recursive nature of cache clearing - instead, we clear the whole cache then
  # update the raw list directly
  state.balances.clearCache()
  for idx, v in rewards.statuses:
    increase_balance(state.balances.asSeq()[idx], v.delta.rewards)
    decrease_balance(state.balances.asSeq()[idx], v.delta.penalties)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#slashings
func process_slashings*(state: var BeaconState, total_balance: Gwei) {.nbench.}=
  let
    epoch = get_current_epoch(state)
    adjusted_total_slashing_balance =
      min(sum(state.slashings) * PROPORTIONAL_SLASHING_MULTIPLIER, total_balance)

  for index in 0..<state.validators.len:
    let validator = unsafeAddr state.validators.asSeq()[index]
    if validator[].slashed and epoch + EPOCHS_PER_SLASHINGS_VECTOR div 2 ==
        validator[].withdrawable_epoch:
      let increment = EFFECTIVE_BALANCE_INCREMENT # Factored out from penalty
                                                  # numerator to avoid uint64 overflow
      let penalty_numerator =
        validator[].effective_balance div increment *
        adjusted_total_slashing_balance
      let penalty = penalty_numerator div total_balance * increment
      decrease_balance(state, index.ValidatorIndex, penalty)

# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/phase0/beacon-chain.md#eth1-data-votes-updates
func process_eth1_data_reset*(state: var BeaconState) {.nbench.} =
  let next_epoch = get_current_epoch(state) + 1

  # Reset eth1 data votes
  if next_epoch mod EPOCHS_PER_ETH1_VOTING_PERIOD == 0:
    state.eth1_data_votes = default(type state.eth1_data_votes)

# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/phase0/beacon-chain.md#effective-balances-updates
func process_effective_balance_updates*(state: var BeaconState) {.nbench.} =
  # Update effective balances with hysteresis
  for index in 0..<state.validators.len:
    let balance = state.balances.asSeq()[index]
    const
      HYSTERESIS_INCREMENT =
        EFFECTIVE_BALANCE_INCREMENT div HYSTERESIS_QUOTIENT
      DOWNWARD_THRESHOLD =
        HYSTERESIS_INCREMENT * HYSTERESIS_DOWNWARD_MULTIPLIER
      UPWARD_THRESHOLD = HYSTERESIS_INCREMENT * HYSTERESIS_UPWARD_MULTIPLIER
    let effective_balance = state.validators.asSeq()[index].effective_balance
    if balance + DOWNWARD_THRESHOLD < effective_balance or
        effective_balance + UPWARD_THRESHOLD < balance:
      state.validators[index].effective_balance =
        min(
          balance - balance mod EFFECTIVE_BALANCE_INCREMENT,
          MAX_EFFECTIVE_BALANCE)

# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/phase0/beacon-chain.md#slashings-balances-updates
func process_slashings_reset*(state: var BeaconState) {.nbench.} =
  let next_epoch = get_current_epoch(state) + 1

  # Reset slashings
  state.slashings[int(next_epoch mod EPOCHS_PER_SLASHINGS_VECTOR)] = 0.Gwei

# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/phase0/beacon-chain.md#randao-mixes-updates
func process_randao_mixes_reset*(state: var BeaconState) {.nbench.} =
  let
    current_epoch = get_current_epoch(state)
    next_epoch = current_epoch + 1

  # Set randao mix
  state.randao_mixes[next_epoch mod EPOCHS_PER_HISTORICAL_VECTOR] =
    get_randao_mix(state, current_epoch)

# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/phase0/beacon-chain.md#historical-roots-updates
func process_historical_roots_update*(state: var BeaconState) {.nbench.} =
  # Set historical root accumulator
  let next_epoch = get_current_epoch(state) + 1

  if next_epoch mod (SLOTS_PER_HISTORICAL_ROOT div SLOTS_PER_EPOCH) == 0:
    # Equivalent to hash_tree_root(foo: HistoricalBatch), but without using
    # significant additional stack or heap.
    # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#historicalbatch
    # In response to https://github.com/status-im/nimbus-eth2/issues/921
    if not state.historical_roots.add hash_tree_root(
        [hash_tree_root(state.block_roots), hash_tree_root(state.state_roots)]):
      raiseAssert "no more room for historical roots, so long and thanks for the fish!"

# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/phase0/beacon-chain.md#participation-records-rotation
func process_participation_record_updates*(state: var BeaconState) {.nbench.} =
  # Rotate current/previous epoch attestations - using swap avoids copying all
  # elements using a slow genericSeqAssign
  state.previous_epoch_attestations.clear()
  swap(state.previous_epoch_attestations, state.current_epoch_attestations)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#final-updates
func process_final_updates*(state: var BeaconState) {.nbench.} =
  # This function's a wrapper over the HF1 split/refactored HF1 version. TODO
  # remove once test vectors become available for each HF1 function.
  process_eth1_data_reset(state)
  process_effective_balance_updates(state)
  process_slashings_reset(state)
  process_randao_mixes_reset(state)
  process_historical_roots_update(state)
  process_participation_record_updates(state)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#epoch-processing
proc process_epoch*(
    state: var BeaconState, flags: UpdateFlags, cache: var StateCache,
    rewards: var RewardInfo) {.nbench.} =
  let currentEpoch = get_current_epoch(state)
  trace "process_epoch",
    current_epoch = currentEpoch
  init(rewards, state)
  rewards.process_attestations(state, cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#justification-and-finalization
  process_justification_and_finalization(
    state, rewards.total_balances, flags)

  # state.slot hasn't been incremented yet.
  if verifyFinalization in flags and currentEpoch >= 2:
    doAssert state.current_justified_checkpoint.epoch + 2 >= currentEpoch

  if verifyFinalization in flags and currentEpoch >= 3:
    # Rule 2/3/4 finalization results in the most pessimal case. The other
    # three finalization rules finalize more quickly as long as the any of
    # the finalization rules triggered.
    doAssert state.finalized_checkpoint.epoch + 3 >= currentEpoch

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#rewards-and-penalties-1
  process_rewards_and_penalties(state, rewards)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#registry-updates
  process_registry_updates(state, cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#slashings
  process_slashings(state, rewards.total_balances.current_epoch)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#final-updates
  process_final_updates(state)
