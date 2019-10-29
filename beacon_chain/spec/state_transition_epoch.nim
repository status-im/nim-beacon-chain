# beacon_chain
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# State transition - epoch processing, as described in
# https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#beacon-chain-state-transition-function
#
# The purpose of this code right is primarily educational, to help piece
# together the mechanics of the beacon state and to discover potential problem
# areas.
#
# The entry point is `process_epoch` which is at the bottom of this file.
#
# General notes about the code (TODO):
# * It's inefficient - we quadratically copy, allocate and iterate when there
#   are faster options
# * Weird styling - the sections taken from the spec use python styling while
#   the others use NEP-1 - helps grepping identifiers in spec
# * We mix procedural and functional styles for no good reason, except that the
#   spec does so also.
# * There are likely lots of bugs.
# * For indices, we get a mix of uint64, ValidatorIndex and int - this is currently
#   swept under the rug with casts
# * The spec uses uint64 for data types, but functions in the spec often assume
#   signed bigint semantics - under- and overflows ensue
# * Sane error handling is missing in most cases (yay, we'll get the chance to
#   debate exceptions again!)
# When updating the code, add TODO sections to mark where there are clear
# improvements to be made - other than that, keep things similar to spec for
# now.

import # TODO - cleanup imports
  math, options, sequtils, tables,
  stew/[bitseqs, bitops2], chronicles, json_serialization/std/sets,
  metrics, ../ssz,
  beaconstate, crypto, datatypes, digest, helpers, validator,
  state_transition_helpers

# Logging utilities
# --------------------------------------------------------

logScope: topics = "consens"

# https://github.com/ethereum/eth2.0-metrics/blob/master/metrics.md#interop-metrics
declareGauge beacon_finalized_epoch, "Current finalized epoch" # On epoch transition
declareGauge beacon_finalized_root, "Current finalized root" # On epoch transition
declareGauge beacon_current_justified_epoch, "Current justified epoch" # On epoch transition
declareGauge beacon_current_justified_root, "Current justified root" # On epoch transition
declareGauge beacon_previous_justified_epoch, "Current previously justified epoch" # On epoch transition
declareGauge beacon_previous_justified_root, "Current previously justified root" # On epoch transition

# Spec
# --------------------------------------------------------

# https://github.com/ethereum/eth2.0-specs/blob/v0.9.0/specs/core/0_beacon-chain.md#get_total_active_balance
func get_total_active_balance*(state: BeaconState): Gwei =
  # Return the combined effective balance of the active validators.
  return get_total_balance(
    state,
    get_active_validator_indices(state, get_current_epoch(state)))

# https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#helper-functions-1
func get_matching_source_attestations(state: BeaconState, epoch: Epoch):
    seq[PendingAttestation] =
  doAssert epoch in [get_current_epoch(state), get_previous_epoch(state)]
  if epoch == get_current_epoch(state):
    state.current_epoch_attestations
  else:
    state.previous_epoch_attestations

func get_matching_target_attestations(state: BeaconState, epoch: Epoch):
    seq[PendingAttestation] =
  filterIt(
    get_matching_source_attestations(state, epoch),
    it.data.target.root == get_block_root(state, epoch)
  )

func get_matching_head_attestations(state: BeaconState, epoch: Epoch):
    seq[PendingAttestation] =
  filterIt(
     get_matching_source_attestations(state, epoch),
     it.data.beacon_block_root ==
       get_block_root_at_slot(state, get_attestation_data_slot(state, it.data))
  )

func get_attesting_balance(
    state: BeaconState, attestations: seq[PendingAttestation],
    stateCache: var StateCache): Gwei =
  get_total_balance(state, get_unslashed_attesting_indices(
    state, attestations, stateCache))

# Not exactly in spec, but for get_winning_crosslink_and_attesting_indices
func lowerThan(candidate, current: Eth2Digest): bool =
  # return true iff candidate is "lower" than current, per spec rule:
  # "ties broken in favor of lexicographically higher hash
  for i, v in current.data:
    if v > candidate.data[i]: return true
  false

func get_winning_crosslink_and_attesting_indices(
    state: BeaconState, epoch: Epoch, shard: Shard,
    stateCache: var StateCache): tuple[a: Crosslink, b: HashSet[ValidatorIndex]] =
  let
    attestations =
      filterIt(
        get_matching_source_attestations(state, epoch),
        it.data.crosslink.shard == shard)
    root_current_shard_crosslink =
      hash_tree_root(state.current_crosslinks[shard])
    crosslinks =
      filterIt(
        mapIt(attestations, it.data.crosslink),
        root_current_shard_crosslink == it.parent_root or
          root_current_shard_crosslink == hash_tree_root(it))

  # default=Crosslink()
  if len(crosslinks) == 0:
    return (Crosslink(), initSet[ValidatorIndex]())

  ## Not from spec. Don't repeatedly search/filter attestations in an O(n^2)
  ## way, but create lookup table in O(n) time with O(1) lookup by crosslink
  ## to cut out expensive inner loop.
  ##
  ## Could also sort attestations by .data.crosslink first, and rely on that
  ## ordering, among other approaches which don't change this function sig.
  var attesting_indices = initTable[Eth2Digest, HashSet[ValidatorIndex]]()
  for attestation in attestations:
    let
      crosslink = attestation.data.crosslink
      crosslink_key = crosslink.data_root
    var crosslink_attestation_indices =
      if crosslink_key in attesting_indices:
        attesting_indices[crosslink_key]
      else:
        initSet[ValidatorIndex]()

    ## See also how get_attesting_balance(...) works. This inverts the loop
    ## nesting order. Also, this ensures no duplicate indices, though it is
    ## not supposed to happen, regardless, if validators are only attesting
    ## on their assigned shards. Still, the right response there is slashed
    ## balances, not crashing clients.
    crosslink_attestation_indices.incl(
      get_unslashed_attesting_indices(state, [attestation], stateCache))
    attesting_indices[crosslink_key] = crosslink_attestation_indices

  ## Winning crosslink has the crosslink data root with the most balance voting
  ## for it (ties broken lexicographically)
  var
    winning_crosslink: Crosslink
    winning_crosslink_balance = 0.Gwei

  for candidate_crosslink in crosslinks:
    ## TODO when confident this exactly reproduces the spec version,
    ## remove the when false'd scaffolding.
    when false:
      let crosslink_balance_uncached =
        get_attesting_balance(
          state,
          filterIt(attestations, it.data.crosslink == candidate_crosslink),
          stateCache)
    # TODO verify if one can assume this cached balance always exists here, by
    # doAsserting candidate_crosslink_key in attesting_indices
    let
      candidate_crosslink_key = candidate_crosslink.data_root
      crosslink_balance =
        if candidate_crosslink_key in attesting_indices:
          get_total_balance(state, attesting_indices[candidate_crosslink_key])
        else:
          ## See `get_total_balance(...)`
          ## But see above, this branch might never happen.
          1.Gwei
    ## TODO factor out precalculation mechanism; consider adding compilation
    ## flag to enable long calculation & consistency/assumption checking.
    when false:
      doAssert crosslink_balance == crosslink_balance_uncached
    if (crosslink_balance > winning_crosslink_balance or
        (winning_crosslink_balance == crosslink_balance and
         lowerThan(winning_crosslink.data_root,
                   candidate_crosslink.data_root))):
      winning_crosslink = candidate_crosslink
      winning_crosslink_balance = crosslink_balance

  let winning_attestations =
    filterIt(attestations, it.data.crosslink == winning_crosslink)

  (winning_crosslink,
   get_unslashed_attesting_indices(state, winning_attestations, stateCache))

# https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#justification-and-finalization
proc process_justification_and_finalization*(
    state: var BeaconState, stateCache: var StateCache) =

  logScope: pcs = "process_justification_and_finalization"

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
  # TODO JUSTIFICATION_BITS_LENGTH is a constant in spec, move there or fix
  # BitVector serialization in SSZ layer
  const JUSTIFICATION_BITS_LENGTH = 4
  state.justification_bits = (state.justification_bits shl 1) and
    cast[uint8]((2^JUSTIFICATION_BITS_LENGTH) - 1)

  # This is a somewhat expensive approach
  let active_validator_indices =
    toSet(mapIt(
      get_active_validator_indices(state, get_current_epoch(state)), it.int))

  let matching_target_attestations_previous =
    get_matching_target_attestations(state, previous_epoch)  # Previous epoch

  ## This epoch processing is the last time these previous attestations can
  ## matter -- in the next epoch, they'll be 2 epochs old, when BeaconState
  ## tracks current_epoch_attestations and previous_epoch_attestations only
  ## per
  ## https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#attestations
  ## and `get_matching_source_attestations(...)` via
  ## https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#helper-functions-1
  ## and
  ## https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#final-updates
  ## after which the state.previous_epoch_attestations is replaced.
  trace "Non-attesting indices in previous epoch",
    missing_all_validators=
      difference(active_validator_indices,
        toSet(mapIt(get_attesting_indices(state,
          matching_target_attestations_previous, stateCache), it.int))),
    missing_unslashed_validators=
      difference(active_validator_indices,
        toSet(mapIt(get_unslashed_attesting_indices(state,
          matching_target_attestations_previous, stateCache), it.int))),
    prev_attestations_len=len(state.previous_epoch_attestations),
    cur_attestations_len=len(state.current_epoch_attestations),
    num_active_validators=len(active_validator_indices),
    required_balance = get_total_active_balance(state) * 2,
    attesting_balance_prev = get_attesting_balance(state, matching_target_attestations_previous, stateCache)
  if get_attesting_balance(state, matching_target_attestations_previous,
      stateCache) * 3 >= get_total_active_balance(state) * 2:
    state.current_justified_checkpoint =
      Checkpoint(epoch: previous_epoch,
                 root: get_block_root(state, previous_epoch))
    state.justification_bits.raiseBit 1

    debug "Justified with previous epoch",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.current_justified_checkpoint),
      cat = "justification"

  let matching_target_attestations_current =
    get_matching_target_attestations(state, current_epoch)  # Current epoch
  if get_attesting_balance(state, matching_target_attestations_current,
      stateCache) * 3 >= get_total_active_balance(state) * 2:
    state.current_justified_checkpoint =
      Checkpoint(epoch: current_epoch,
                 root: get_block_root(state, current_epoch))
    state.justification_bits.raiseBit 0

    debug "Justified with current epoch",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.current_justified_checkpoint),
      cat = "justification"

  # Process finalizations
  let bitfield = state.justification_bits

  ## The 2nd/3rd/4th most recent epochs are justified, the 2nd using the 4th
  ## as source
  if (bitfield and 0b1110) == 0b1110 and
     old_previous_justified_checkpoint.epoch + 3 == current_epoch:
    state.finalized_checkpoint = old_previous_justified_checkpoint

    debug "Finalized with rule 234",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint),
      cat = "finalization"

  ## The 2nd/3rd most recent epochs are justified, the 2nd using the 3rd as
  ## source
  if (bitfield and 0b110) == 0b110 and
     old_previous_justified_checkpoint.epoch + 2 == current_epoch:
    state.finalized_checkpoint = old_previous_justified_checkpoint

    debug "Finalized with rule 23",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint),
      cat = "finalization"

  ## The 1st/2nd/3rd most recent epochs are justified, the 1st using the 3rd as
  ## source
  if (bitfield and 0b111) == 0b111 and
     old_current_justified_checkpoint.epoch + 2 == current_epoch:
    state.finalized_checkpoint = old_current_justified_checkpoint

    debug "Finalized with rule 123",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint),
      cat = "finalization"

  ## The 1st/2nd most recent epochs are justified, the 1st using the 2nd as
  ## source
  if (bitfield and 0b11) == 0b11 and
     old_current_justified_checkpoint.epoch + 1 == current_epoch:
    state.finalized_checkpoint = old_current_justified_checkpoint

    debug "Finalized with rule 12",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint),
      cat = "finalization"

# https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#rewards-and-penalties-1
func get_base_reward(state: BeaconState, index: ValidatorIndex): Gwei =
  let
    total_balance = get_total_active_balance(state)
    effective_balance = state.validators[index].effective_balance
  effective_balance * BASE_REWARD_FACTOR div
    integer_squareroot(total_balance) div BASE_REWARDS_PER_EPOCH

# https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#rewards-and-penalties-1
func get_attestation_deltas(state: BeaconState, stateCache: var StateCache):
    tuple[a: seq[Gwei], b: seq[Gwei]] =
  let
    previous_epoch = get_previous_epoch(state)
    total_balance = get_total_active_balance(state)
  var
    rewards = repeat(0'u64, len(state.validators))
    penalties = repeat(0'u64, len(state.validators))
    eligible_validator_indices : seq[ValidatorIndex] = @[]

  for index, v in state.validators:
    if is_active_validator(v, previous_epoch) or
        (v.slashed and previous_epoch + 1 < v.withdrawable_epoch):
      eligible_validator_indices.add index.ValidatorIndex

  # Micro-incentives for matching FFG source, FFG target, and head
  let
    matching_source_attestations =
      get_matching_source_attestations(state, previous_epoch)
    matching_target_attestations =
      get_matching_target_attestations(state, previous_epoch)
    matching_head_attestations =
      get_matching_head_attestations(state, previous_epoch)

  for attestations in
      [matching_source_attestations, matching_target_attestations,
       matching_head_attestations]:
    let
      unslashed_attesting_indices =
        get_unslashed_attesting_indices(state, attestations, stateCache)
      attesting_balance = get_total_balance(state, unslashed_attesting_indices)
    for index in eligible_validator_indices:
      if index in unslashed_attesting_indices:
        rewards[index] +=
          get_base_reward(state, index) * attesting_balance div total_balance
      else:
        penalties[index] += get_base_reward(state, index)

  # Proposer and inclusion delay micro-rewards
  ## This depends on matching_source_attestations being an indexable seq, not a
  ## set, hash table, etc.
  let source_attestation_attesting_indices =
    mapIt(
      matching_source_attestations,
      get_attesting_indices(state, it.data, it.aggregation_bits, stateCache))

  ## TODO if this is still a profiling issue, do higher-level semantic
  ## translation
  for index in get_unslashed_attesting_indices(
      state, matching_source_attestations, stateCache):
    # Translation of attestation = min([...])
    doAssert matching_source_attestations.len > 0

    # Start by filtering the right attestations
    var filtered_matching_source_attestations: seq[PendingAttestation]

    for source_attestation_index, a in matching_source_attestations:
      if index notin
          source_attestation_attesting_indices[source_attestation_index]:
        continue
      filtered_matching_source_attestations.add a

    # The first filtered attestation serves as min until we find something
    # better
    var attestation = filtered_matching_source_attestations[0]
    for source_attestation_index, a in filtered_matching_source_attestations:
      if a.inclusion_delay < attestation.inclusion_delay:
        attestation = a

    let proposer_reward =
      (get_base_reward(state, index) div PROPOSER_REWARD_QUOTIENT).Gwei

    rewards[attestation.proposer_index.int] += proposer_reward
    let max_attester_reward = get_base_reward(state, index) - proposer_reward

    rewards[index] +=
      ((max_attester_reward *
       ((SLOTS_PER_EPOCH + MIN_ATTESTATION_INCLUSION_DELAY).uint64 -
       attestation.inclusion_delay)) div SLOTS_PER_EPOCH).Gwei

  # Inactivity penalty
  let finality_delay = previous_epoch - state.finalized_checkpoint.epoch
  if finality_delay > MIN_EPOCHS_TO_INACTIVITY_PENALTY:
    let matching_target_attesting_indices =
      get_unslashed_attesting_indices(
        state, matching_target_attestations, stateCache)
    for index in eligible_validator_indices:
      penalties[index] +=
        BASE_REWARDS_PER_EPOCH.uint64 * get_base_reward(state, index)
      if index notin matching_target_attesting_indices:
        penalties[index] +=
          state.validators[index].effective_balance *
            finality_delay div INACTIVITY_PENALTY_QUOTIENT

  (rewards, penalties)

# https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#rewards-and-penalties-1
func get_crosslink_deltas*(state: BeaconState, cache: var StateCache):
    tuple[a: seq[Gwei], b: seq[Gwei]] =

  var
    rewards = repeat(0'u64, len(state.validators))
    penalties = repeat(0'u64, len(state.validators))
  let epoch = get_previous_epoch(state)
  for offset in 0'u64 ..< get_committee_count(state, epoch):
    let
      shard = (get_start_shard(state, epoch) + offset) mod SHARD_COUNT
      crosslink_committee =
        toSet(get_crosslink_committee(state, epoch, shard, cache))
      (_, attesting_indices) =
        get_winning_crosslink_and_attesting_indices(
          state, epoch, shard, cache)
      attesting_balance = get_total_balance(state, attesting_indices)
      committee_balance = get_total_balance(state, crosslink_committee)

    for index in crosslink_committee:
      let base_reward = get_base_reward(state, index)
      if index in attesting_indices:
        rewards[index] +=
          base_reward * attesting_balance div committee_balance
      else:
        penalties[index] += base_reward

  (rewards, penalties)

# https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#rewards-and-penalties-1
func process_rewards_and_penalties(
    state: var BeaconState, cache: var StateCache) =
  if get_current_epoch(state) == GENESIS_EPOCH:
    return

  let
    (rewards1, penalties1) = get_attestation_deltas(state, cache)
    (rewards2, penalties2) = get_crosslink_deltas(state, cache)

  for i in 0 ..< len(state.validators):
    increase_balance(state, i.ValidatorIndex, rewards1[i] + rewards2[i])
    decrease_balance(state, i.ValidatorIndex, penalties1[i] + penalties2[i])

# https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#slashings
func process_slashings*(state: var BeaconState) =
  let
    epoch = get_current_epoch(state)
    total_balance = get_total_active_balance(state)

  for index, validator in state.validators:
    if validator.slashed and epoch + EPOCHS_PER_SLASHINGS_VECTOR div 2 ==
        validator.withdrawable_epoch:
      let increment = EFFECTIVE_BALANCE_INCREMENT # Factored out from penalty
                                                  # numerator to avoid uint64 overflow
      let penalty_numerator =
        validator.effective_balance div increment *
          min(sum(state.slashings) * 3, total_balance)
      let penalty = penalty_numerator div total_balance * increment
      decrease_balance(state, index.ValidatorIndex, penalty)

# https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#final-updates
proc process_final_updates*(state: var BeaconState) =
  let
    current_epoch = get_current_epoch(state)
    next_epoch = current_epoch + 1

  # Reset eth1 data votes
  if (state.slot + 1) mod SLOTS_PER_ETH1_VOTING_PERIOD == 0:
    state.eth1_data_votes = @[]

  # Update effective balances with hysteresis
  for index, validator in state.validators:
    let balance = state.balances[index]
    const HALF_INCREMENT = EFFECTIVE_BALANCE_INCREMENT div 2
    if balance < validator.effective_balance or
        validator.effective_balance + 3'u64 * HALF_INCREMENT < balance:
      state.validators[index].effective_balance =
        min(
          balance - balance mod EFFECTIVE_BALANCE_INCREMENT,
          MAX_EFFECTIVE_BALANCE)

  # Set active index root
  let
    index_epoch = next_epoch + MAX_SEED_LOOKAHEAD
    index_root_position = index_epoch mod EPOCHS_PER_HISTORICAL_VECTOR
    indices_list = get_active_validator_indices(state, index_epoch)

  state.active_index_roots[index_root_position] = hash_tree_root(
    # TODO The +1 on the next line is not conforming to the spec.
    # Without it, our merkleization padding is missing one final
    # level of mixing with a zero hash. We need to investigate
    # why this is happening only in the particular case here.
    sszList(indices_list, VALIDATOR_REGISTRY_LIMIT + 1))

  # Set committees root
  let committee_root_position = next_epoch mod EPOCHS_PER_HISTORICAL_VECTOR
  state.compact_committees_roots[committee_root_position] =
    get_compact_committees_root(state, next_epoch)

  # Reset slashings
  state.slashings[next_epoch mod EPOCHS_PER_SLASHINGS_VECTOR] = 0.Gwei

  # Set randao mix
  state.randao_mixes[next_epoch mod EPOCHS_PER_HISTORICAL_VECTOR] =
    get_randao_mix(state, current_epoch)

  # Set historical root accumulator
  if next_epoch mod (SLOTS_PER_HISTORICAL_ROOT div SLOTS_PER_EPOCH).uint64 == 0:
    let historical_batch = HistoricalBatch(
      block_roots: state.block_roots,
      state_roots: state.state_roots,
    )
    state.historical_roots.add (hash_tree_root(historical_batch))

  # Update start shard
  state.start_shard =
    (state.start_shard + get_shard_delta(state, current_epoch)) mod
      SHARD_COUNT

  # Rotate current/previous epoch attestations
  state.previous_epoch_attestations = state.current_epoch_attestations
  state.current_epoch_attestations = @[]

# https://github.com/ethereum/eth2.0-specs/blob/v0.9.0/specs/core/0_beacon-chain.md#epoch-processing
proc process_epoch*(state: var BeaconState) =
  # @proc are placeholders

  trace "process_epoch",
    current_epoch = get_current_epoch(state)

  var per_epoch_cache = get_empty_per_epoch_cache()

  # https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#justification-and-finalization
  process_justification_and_finalization(state, per_epoch_cache)

  trace "ran process_justification_and_finalization",
    current_epoch = get_current_epoch(state)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#rewards-and-penalties-1
  process_rewards_and_penalties(state, per_epoch_cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#registry-updates
  # Don't rely on caching here.
  process_registry_updates(state)

  ## Caching here for get_crosslink_committee(...) can break otherwise, since
  ## get_active_validator_indices(...) usually changes.
  clear(per_epoch_cache.crosslink_committee_cache)

  # @process_reveal_deadlines
  # @process_challenge_deadlines

  # https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#slashings
  process_slashings(state)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/core/0_beacon-chain.md#final-updates
  process_final_updates(state)

  # @after_process_final_updates

  # Once per epoch metrics
  beacon_finalized_epoch.set(state.finalized_checkpoint.epoch.int64)
  beacon_finalized_root.set(state.finalized_checkpoint.root.toGaugeValue)
  beacon_current_justified_epoch.set(
    state.current_justified_checkpoint.epoch.int64)
  beacon_current_justified_root.set(
    state.current_justified_checkpoint.root.toGaugeValue)
  beacon_previous_justified_epoch.set(
    state.previous_justified_checkpoint.epoch.int64)
  beacon_previous_justified_root.set(
    state.previous_justified_checkpoint.root.toGaugeValue)
