# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[algorithm, collections/heapqueue, math, options, sequtils, tables],
  stew/assign2,
  json_serialization/std/sets,
  chronicles,
  ../extras, ../ssz/merkleization,
  ./crypto, ./datatypes/[phase0, altair], ./digest, ./helpers, ./signatures, ./validator,
  ../../nbench/bench_lab

import blscurve # TODO bad

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#is_valid_merkle_branch
func is_valid_merkle_branch*(leaf: Eth2Digest, branch: openArray[Eth2Digest],
                             depth: int, index: uint64,
                             root: Eth2Digest): bool {.nbench.}=
  ## Check if ``leaf`` at ``index`` verifies against the Merkle ``root`` and
  ## ``branch``.
  var
    value = leaf
    buf: array[64, byte]

  for i in 0 ..< depth:
    if (index div (1'u64 shl i)) mod 2 != 0:
      buf[0..31] = branch[i].data
      buf[32..63] = value.data
    else:
      buf[0..31] = value.data
      buf[32..63] = branch[i].data
    value = eth2digest(buf)
  value == root

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#increase_balance
func increase_balance*(balance: var Gwei, delta: Gwei) =
  balance += delta

func increase_balance*(
    state: var SomeBeaconState, index: ValidatorIndex, delta: Gwei) =
  ## Increase the validator balance at index ``index`` by ``delta``.
  if delta != 0: # avoid dirtying the balance cache if not needed
    increase_balance(state.balances[index], delta)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#decrease_balance
func decrease_balance*(balance: var Gwei, delta: Gwei) =
  balance =
    if delta > balance:
      0'u64
    else:
      balance - delta

func decrease_balance*(
    state: var SomeBeaconState, index: ValidatorIndex, delta: Gwei) =
  ## Decrease the validator balance at index ``index`` by ``delta``, with
  ## underflow protection.
  if delta != 0: # avoid dirtying the balance cache if not needed
    decrease_balance(state.balances[index], delta)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#deposits
# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#modified-process_deposit
func get_validator_from_deposit*(deposit: DepositData):
    Validator =
  let
    amount = deposit.amount
    effective_balance = min(
      amount - amount mod EFFECTIVE_BALANCE_INCREMENT, MAX_EFFECTIVE_BALANCE)

  Validator(
    pubkey: deposit.pubkey,
    withdrawal_credentials: deposit.withdrawal_credentials,
    activation_eligibility_epoch: FAR_FUTURE_EPOCH,
    activation_epoch: FAR_FUTURE_EPOCH,
    exit_epoch: FAR_FUTURE_EPOCH,
    withdrawable_epoch: FAR_FUTURE_EPOCH,
    effective_balance: effective_balance
  )

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#compute_activation_exit_epoch
func compute_activation_exit_epoch(epoch: Epoch): Epoch =
  ## Return the epoch during which validator activations and exits initiated in
  ## ``epoch`` take effect.
  epoch + 1 + MAX_SEED_LOOKAHEAD

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_validator_churn_limit
func get_validator_churn_limit(
      cfg: RuntimeConfig, state: SomeBeaconState, cache: var StateCache):
    uint64 =
  ## Return the validator churn limit for the current epoch.
  max(
    cfg.MIN_PER_EPOCH_CHURN_LIMIT,
    count_active_validators(
      state, state.get_current_epoch(), cache) div cfg.CHURN_LIMIT_QUOTIENT)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#initiate_validator_exit
func initiate_validator_exit*(cfg: RuntimeConfig, state: var SomeBeaconState,
                              index: ValidatorIndex, cache: var StateCache) =
  ## Initiate the exit of the validator with index ``index``.

  # Return if validator already initiated exit
  let validator = addr state.validators[index]
  if validator.exit_epoch != FAR_FUTURE_EPOCH:
    return

  trace "Validator exiting",
    index = index,
    num_validators = state.validators.len,
    current_epoch = get_current_epoch(state),
    validator_slashed = validator.slashed,
    validator_withdrawable_epoch = validator.withdrawable_epoch,
    validator_exit_epoch = validator.exit_epoch,
    validator_effective_balance = validator.effective_balance

  var exit_queue_epoch = compute_activation_exit_epoch(get_current_epoch(state))
  # Compute max exit epoch
  for idx in 0..<state.validators.len:
    let exit_epoch = state.validators.asSeq()[idx].exit_epoch
    if exit_epoch != FAR_FUTURE_EPOCH and exit_epoch > exit_queue_epoch:
      exit_queue_epoch = exit_epoch

  var
    exit_queue_churn: int
  for idx in 0..<state.validators.len:
    if state.validators.asSeq()[idx].exit_epoch == exit_queue_epoch:
      exit_queue_churn += 1

  if exit_queue_churn.uint64 >= get_validator_churn_limit(cfg, state, cache):
    exit_queue_epoch += 1

  # Set validator exit epoch and withdrawable epoch
  validator.exit_epoch = exit_queue_epoch
  validator.withdrawable_epoch =
    validator.exit_epoch + cfg.MIN_VALIDATOR_WITHDRAWABILITY_DELAY

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#slash_validator
# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#modified-slash_validator
proc slash_validator*(
    cfg: RuntimeConfig, state: var SomeBeaconState,
    slashed_index: ValidatorIndex, cache: var StateCache) =
  ## Slash the validator with index ``index``.
  let epoch = get_current_epoch(state)
  initiate_validator_exit(cfg, state, slashed_index, cache)
  let validator = addr state.validators[slashed_index]

  trace "slash_validator: ejecting validator via slashing (validator_leaving)",
    index = slashed_index,
    num_validators = state.validators.len,
    current_epoch = get_current_epoch(state),
    validator_slashed = validator.slashed,
    validator_withdrawable_epoch = validator.withdrawable_epoch,
    validator_exit_epoch = validator.exit_epoch,
    validator_effective_balance = validator.effective_balance

  validator.slashed = true
  validator.withdrawable_epoch =
    max(validator.withdrawable_epoch, epoch + EPOCHS_PER_SLASHINGS_VECTOR)
  state.slashings[int(epoch mod EPOCHS_PER_SLASHINGS_VECTOR)] +=
    validator.effective_balance

  # TODO Consider whether this is better than splitting the functions apart; in
  # each case, tradeoffs. Here, it's just changing a couple of constants.
  when state is phase0.BeaconState:
    decrease_balance(state, slashed_index,
      validator.effective_balance div MIN_SLASHING_PENALTY_QUOTIENT)
  elif state is altair.BeaconState:
    decrease_balance(state, slashed_index,
      validator.effective_balance div MIN_SLASHING_PENALTY_QUOTIENT_ALTAIR)
  else:
    raiseAssert "invalid BeaconState type"

  # The rest doesn't make sense without there being any proposer index, so skip
  let proposer_index = get_beacon_proposer_index(state, cache)
  if proposer_index.isNone:
    debug "No beacon proposer index and probably no active validators"
    return

  # Apply proposer and whistleblower rewards
  let
    # Spec has whistleblower_index as optional param, but it's never used.
    whistleblower_index = proposer_index.get
    whistleblower_reward =
      (validator.effective_balance div WHISTLEBLOWER_REWARD_QUOTIENT).Gwei
    proposer_reward =
      when state is phase0.BeaconState:
        whistleblower_reward div PROPOSER_REWARD_QUOTIENT
      elif state is altair.BeaconState:
        whistleblower_reward * PROPOSER_WEIGHT div WEIGHT_DENOMINATOR
      else:
        raiseAssert "invalid BeaconState type"

  increase_balance(state, proposer_index.get, proposer_reward)
  # TODO: evaluate if spec bug / underflow can be triggered
  doAssert(whistleblower_reward >= proposer_reward, "Spec bug: underflow in slash_validator")
  increase_balance(
    state, whistleblower_index, whistleblower_reward - proposer_reward)

func genesis_time_from_eth1_timestamp*(cfg: RuntimeConfig, eth1_timestamp: uint64): uint64 =
  eth1_timestamp + cfg.GENESIS_DELAY

func genesisFork*(cfg: RuntimeConfig): Fork =
  Fork(
    previous_version: cfg.GENESIS_FORK_VERSION,
    current_version: cfg.GENESIS_FORK_VERSION,
    epoch: GENESIS_EPOCH)

func altairFork*(cfg: RuntimeConfig): Fork =
  Fork(
    previous_version: cfg.GENESIS_FORK_VERSION,
    current_version: cfg.ALTAIR_FORK_VERSION,
    epoch: cfg.ALTAIR_FORK_EPOCH)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#genesis
proc initialize_beacon_state_from_eth1*(
    cfg: RuntimeConfig,
    eth1_block_hash: Eth2Digest,
    eth1_timestamp: uint64,
    deposits: openArray[DepositData],
    flags: UpdateFlags = {}): phase0.BeaconStateRef {.nbench.} =
  ## Get the genesis ``BeaconState``.
  ##
  ## Before the beacon chain starts, validators will register in the Eth1 chain
  ## and deposit ETH. When enough many validators have registered, a
  ## `ChainStart` log will be emitted and the beacon chain can start beaconing.
  ##
  ## Because the state root hash is part of the genesis block, the beacon state
  ## must be calculated before creating the genesis block.

  # Induct validators
  # Not in spec: the system doesn't work unless there are at least SLOTS_PER_EPOCH
  # validators - there needs to be at least one member in each committee -
  # good to know for testing, though arguably the system is not that useful at
  # at that point :)
  doAssert deposits.lenu64 >= SLOTS_PER_EPOCH

  var state = phase0.BeaconStateRef(
    fork: genesisFork(cfg),
    genesis_time: genesis_time_from_eth1_timestamp(cfg, eth1_timestamp),
    eth1_data:
      Eth1Data(block_hash: eth1_block_hash, deposit_count: uint64(len(deposits))),
    latest_block_header:
      BeaconBlockHeader(
        body_root: hash_tree_root(default(phase0.BeaconBlockBody))))

  # Seed RANDAO with Eth1 entropy
  state.randao_mixes.fill(eth1_block_hash)

  var merkleizer = createMerkleizer(2'i64^DEPOSIT_CONTRACT_TREE_DEPTH)
  for i, deposit in deposits:
    let htr = hash_tree_root(deposit)
    merkleizer.addChunk(htr.data)

  # This is already known in the Eth1 monitor, but it would be too
  # much work to refactor all the existing call sites in the test suite
  state.eth1_data.deposit_root = mixInLength(merkleizer.getFinalHash(),
                                             deposits.len)
  state.eth1_deposit_index = deposits.lenu64

  var pubkeyToIndex = initTable[ValidatorPubKey, int]()
  for idx, deposit in deposits:
    let
      pubkey = deposit.pubkey
      amount = deposit.amount

    pubkeyToIndex.withValue(pubkey, foundIdx) do:
      # Increase balance by deposit amount
      increase_balance(state[], ValidatorIndex foundIdx[], amount)
    do:
      if skipBlsValidation in flags or
         verify_deposit_signature(cfg, deposit):
        pubkeyToIndex[pubkey] = state.validators.len
        if not state.validators.add(get_validator_from_deposit(deposit)):
          raiseAssert "too many validators"
        if not state.balances.add(amount):
          raiseAssert "same as validators"

      else:
        # Invalid deposits are perfectly possible
        trace "Skipping deposit with invalid signature",
          deposit = shortLog(deposit)

  # Process activations
  for validator_index in 0 ..< state.validators.len:
    let
      balance = state.balances.asSeq()[validator_index]
      validator = addr state.validators[validator_index]

    validator.effective_balance = min(
      balance - balance mod EFFECTIVE_BALANCE_INCREMENT, MAX_EFFECTIVE_BALANCE)

    if validator.effective_balance == MAX_EFFECTIVE_BALANCE:
      validator.activation_eligibility_epoch = GENESIS_EPOCH
      validator.activation_epoch = GENESIS_EPOCH

  # Set genesis validators root for domain separation and chain versioning
  state.genesis_validators_root = hash_tree_root(state.validators)

  state

proc initialize_hashed_beacon_state_from_eth1*(
    cfg: RuntimeConfig,
    eth1_block_hash: Eth2Digest,
    eth1_timestamp: uint64,
    deposits: openArray[DepositData],
    flags: UpdateFlags = {}): phase0.HashedBeaconState =
  let genesisState = initialize_beacon_state_from_eth1(
    cfg, eth1_block_hash, eth1_timestamp, deposits, flags)
  phase0.HashedBeaconState(
    data: genesisState[], root: hash_tree_root(genesisState[]))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#genesis-block
func get_initial_beacon_block*(state: phase0.BeaconState):
    phase0.TrustedSignedBeaconBlock =
  # The genesis block is implicitly trusted
  let message = phase0.TrustedBeaconBlock(
    slot: state.slot,
    state_root: hash_tree_root(state),)
    # parent_root, randao_reveal, eth1_data, signature, and body automatically
    # initialized to default values.
  phase0.TrustedSignedBeaconBlock(
    message: message, root: hash_tree_root(message))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_block_root_at_slot
func get_block_root_at_slot*(state: SomeBeaconState,
                             slot: Slot): Eth2Digest =
  ## Return the block root at a recent ``slot``.

  # Potential overflow/wrap shouldn't occur, as get_block_root_at_slot() called
  # from internally controlled sources, but flag this explicitly, in case.
  doAssert slot + SLOTS_PER_HISTORICAL_ROOT > slot

  doAssert state.slot <= slot + SLOTS_PER_HISTORICAL_ROOT
  doAssert slot < state.slot
  state.block_roots[slot mod SLOTS_PER_HISTORICAL_ROOT]

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_block_root
func get_block_root*(state: SomeBeaconState, epoch: Epoch): Eth2Digest =
  ## Return the block root at the start of a recent ``epoch``.
  get_block_root_at_slot(state, compute_start_slot_at_epoch(epoch))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_total_balance
func get_total_balance*(state: SomeBeaconState, validators: auto): Gwei =
  ## Return the combined effective balance of the ``indices``.
  ## ``EFFECTIVE_BALANCE_INCREMENT`` Gwei minimum to avoid divisions by zero.
  ## Math safe up to ~10B ETH, afterwhich this overflows uint64.
  max(EFFECTIVE_BALANCE_INCREMENT,
    foldl(validators, a + state.validators[b].effective_balance, 0'u64)
  )

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#is_eligible_for_activation_queue
func is_eligible_for_activation_queue(validator: Validator): bool =
  ## Check if ``validator`` is eligible to be placed into the activation queue.
  validator.activation_eligibility_epoch == FAR_FUTURE_EPOCH and
    validator.effective_balance == MAX_EFFECTIVE_BALANCE

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#is_eligible_for_activation
func is_eligible_for_activation(state: SomeBeaconState, validator: Validator):
    bool =
  ## Check if ``validator`` is eligible for activation.

  # Placement in queue is finalized
  validator.activation_eligibility_epoch <= state.finalized_checkpoint.epoch and
  # Has not yet been activated
    validator.activation_epoch == FAR_FUTURE_EPOCH

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#registry-updates
proc process_registry_updates*(
    cfg: RuntimeConfig, state: var SomeBeaconState, cache: var StateCache) {.nbench.} =
  ## Process activation eligibility and ejections

  # Make visible, e.g.,
  # https://github.com/status-im/nimbus-eth2/pull/608
  # https://github.com/sigp/lighthouse/pull/657
  let epoch {.used.} = get_current_epoch(state)
  trace "process_registry_updates validator balances",
    balances=state.balances,
    active_validator_indices=get_active_validator_indices(state, epoch),
    epoch=epoch

  # is_active_validator(...) is activation_epoch <= epoch < exit_epoch,
  # and changes here to either activation_epoch or exit_epoch only take
  # effect with a compute_activation_exit_epoch(...) delay of, based on
  # the current epoch, 1 + MAX_SEED_LOOKAHEAD epochs ahead. Thus caches
  # remain valid for this epoch through though this function along with
  # the rest of the epoch transition.
  for index in 0..<state.validators.len():
    if is_eligible_for_activation_queue(state.validators.asSeq()[index]):
      state.validators[index].activation_eligibility_epoch =
        get_current_epoch(state) + 1

    if is_active_validator(state.validators.asSeq()[index], get_current_epoch(state)) and
        state.validators.asSeq()[index].effective_balance <= cfg.EJECTION_BALANCE:
      initiate_validator_exit(cfg, state, index.ValidatorIndex, cache)

  ## Queue validators eligible for activation and not dequeued for activation
  var activation_queue : seq[tuple[a: Epoch, b: int]] = @[]
  for index in 0..<state.validators.len():
    let validator = unsafeAddr state.validators.asSeq()[index]
    if is_eligible_for_activation(state, validator[]):
      activation_queue.add (
        validator[].activation_eligibility_epoch, index)

  activation_queue.sort(system.cmp)

  ## Dequeued validators for activation up to churn limit (without resetting
  ## activation epoch)
  let churn_limit = get_validator_churn_limit(cfg, state, cache)
  for i, epoch_and_index in activation_queue:
    if i.uint64 >= churn_limit:
      break
    let
      (_, index) = epoch_and_index
    state.validators[index].activation_epoch =
      compute_activation_exit_epoch(get_current_epoch(state))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#is_valid_indexed_attestation
proc is_valid_indexed_attestation*(
    state: SomeBeaconState, indexed_attestation: SomeIndexedAttestation,
    flags: UpdateFlags): Result[void, cstring] =
  ## Check if ``indexed_attestation`` is not empty, has sorted and unique
  ## indices and has a valid aggregate signature.

  template is_sorted_and_unique(s: untyped): bool =
    var res = true
    for i in 1 ..< s.len:
      if s[i - 1].uint64 >= s[i].uint64:
        res = false
        break
    res

  if len(indexed_attestation.attesting_indices) == 0:
    return err("indexed_attestation: no attesting indices")

  # Not from spec, but this function gets used in front-line roles, not just
  # behind firewall.
  let num_validators = state.validators.lenu64
  if anyIt(indexed_attestation.attesting_indices, it >= num_validators):
    return err("indexed attestation: not all indices valid validators")

  if not is_sorted_and_unique(indexed_attestation.attesting_indices):
    return err("indexed attestation: indices not sorted and unique")

  # Verify aggregate signature
  if not (skipBLSValidation in flags or indexed_attestation.signature is TrustedSig):
    let pubkeys = mapIt(
      indexed_attestation.attesting_indices, state.validators[it].pubkey)
    if not verify_attestation_signature(
        state.fork, state.genesis_validators_root, indexed_attestation.data,
        pubkeys, indexed_attestation.signature):
      return err("indexed attestation: signature verification failure")

  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_attesting_indices
func get_attesting_indices*(state: SomeBeaconState,
                            data: AttestationData,
                            bits: CommitteeValidatorsBits,
                            cache: var StateCache): seq[ValidatorIndex] =
  ## Return the set of attesting indices corresponding to ``data`` and ``bits``.

  var res: seq[ValidatorIndex]
  # Can't be an iterator due to https://github.com/nim-lang/Nim/issues/18188
  if bits.lenu64 != get_beacon_committee_len(
      state, data.slot, data.index.CommitteeIndex, cache):
    trace "get_attesting_indices: inconsistent aggregation and committee length"
  else:
    var i = 0
    for index in get_beacon_committee(
        state, data.slot, data.index.CommitteeIndex, cache):
      if bits[i]:
        res.add index
      inc i

  res

proc is_valid_indexed_attestation*(
    state: SomeBeaconState, attestation: SomeAttestation, flags: UpdateFlags,
    cache: var StateCache): Result[void, cstring] =
  # This is a variation on `is_valid_indexed_attestation` that works directly
  # with an attestation instead of first constructing an `IndexedAttestation`
  # and then validating it - for the purpose of validating the signature, the
  # order doesn't matter and we can proceed straight to validating the
  # signature instead

  let sigs = attestation.aggregation_bits.countOnes()
  if sigs == 0:
    return err("is_valid_indexed_attestation: no attesting indices")

  # Verify aggregate signature
  if not (skipBLSValidation in flags or attestation.signature is TrustedSig):
    var
      pubkeys = newSeqOfCap[ValidatorPubKey](sigs)
    for index in get_attesting_indices(
        state, attestation.data, attestation.aggregation_bits, cache):
      pubkeys.add(state.validators[index].pubkey)

    if not verify_attestation_signature(
        state.fork, state.genesis_validators_root, attestation.data,
        pubkeys, attestation.signature):
      return err("indexed attestation: signature verification failure")

  ok()

# Attestation validation
# ------------------------------------------------------------------------------------------
# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#attestations
# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/p2p-interface.md#beacon_attestation_subnet_id

func check_attestation_slot_target*(data: AttestationData): Result[void, cstring] =
  if not (data.target.epoch == compute_epoch_at_slot(data.slot)):
    return err("Target epoch doesn't match attestation slot")

  ok()

func check_attestation_target_epoch(
    data: AttestationData, current_epoch: Epoch): Result[void, cstring] =
  if not (data.target.epoch == get_previous_epoch(current_epoch) or
      data.target.epoch == current_epoch):
    return err("Target epoch not current or previous epoch")

  ok()

func check_attestation_inclusion(data: AttestationData,
                                 current_slot: Slot): Result[void, cstring] =
  # Check for overflow
  static:
    doAssert SLOTS_PER_EPOCH >= MIN_ATTESTATION_INCLUSION_DELAY
  if data.slot + SLOTS_PER_EPOCH <= data.slot:
    return err("attestation data.slot overflow, malicious?")

  if not (data.slot + MIN_ATTESTATION_INCLUSION_DELAY <= current_slot):
    return err("Attestation too new")

  if not (current_slot <= data.slot + SLOTS_PER_EPOCH):
    return err("Attestation too old")

  ok()

func check_attestation_index(
    data: AttestationData, committees_per_slot: uint64): Result[void, cstring] =
  if not (data.index < committees_per_slot):
    return err("Data index exceeds committee count")

  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.7/specs/altair/beacon-chain.md#get_attestation_participation_flag_indices
func get_attestation_participation_flag_indices(state: altair.BeaconState,
                                                data: AttestationData,
                                                inclusion_delay: uint64): seq[int] =
  ## Return the flag indices that are satisfied by an attestation.
  let justified_checkpoint =
    if data.target.epoch == get_current_epoch(state):
      state.current_justified_checkpoint
    else:
      state.previous_justified_checkpoint

  # Matching roots
  let
    is_matching_source = data.source == justified_checkpoint
    is_matching_target = is_matching_source and data.target.root == get_block_root(state, data.target.epoch)
    is_matching_head = is_matching_target and data.beacon_block_root == get_block_root_at_slot(state, data.slot)

  # TODO probably this needs to be robustly failable
  doAssert is_matching_source

  var participation_flag_indices: seq[int]
  if is_matching_source and inclusion_delay <= integer_squareroot(SLOTS_PER_EPOCH):
    participation_flag_indices.add(TIMELY_SOURCE_FLAG_INDEX)
  if is_matching_target and inclusion_delay <= SLOTS_PER_EPOCH:
    participation_flag_indices.add(TIMELY_TARGET_FLAG_INDEX)
  if is_matching_head and inclusion_delay == MIN_ATTESTATION_INCLUSION_DELAY:
    participation_flag_indices.add(TIMELY_HEAD_FLAG_INDEX)

  participation_flag_indices

# TODO these aren't great here
# TODO these duplicate some stuff in state_transition_epoch which uses TotalBalances
# better to centralize around that if feasible

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_total_active_balance
func get_total_active_balance*(state: SomeBeaconState, cache: var StateCache): Gwei =
  ## Return the combined effective balance of the active validators.
  # Note: ``get_total_balance`` returns ``EFFECTIVE_BALANCE_INCREMENT`` Gwei
  # minimum to avoid divisions by zero.

  let epoch = state.get_current_epoch()

  get_total_balance(
    state, cache.get_shuffled_active_validator_indices(state, epoch))

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.8/specs/altair/beacon-chain.md#get_base_reward_per_increment
func get_base_reward_per_increment*(
    state: altair.BeaconState, cache: var StateCache): Gwei =
  EFFECTIVE_BALANCE_INCREMENT * BASE_REWARD_FACTOR div
    integer_squareroot(get_total_active_balance(state, cache))

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.8/specs/altair/beacon-chain.md#get_base_reward
func get_base_reward(
    state: altair.BeaconState, index: ValidatorIndex,
    base_reward_per_increment: Gwei): Gwei =
  ## Return the base reward for the validator defined by ``index`` with respect
  ## to the current ``state``.
  let increments =
    state.validators[index].effective_balance div EFFECTIVE_BALANCE_INCREMENT
  increments * base_reward_per_increment

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#attestations
proc check_attestation*(
    state: SomeBeaconState, attestation: SomeAttestation, flags: UpdateFlags,
    cache: var StateCache): Result[void, cstring] =
  ## Check that an attestation follows the rules of being included in the state
  ## at the current slot. When acting as a proposer, the same rules need to
  ## be followed!

  let
    data = attestation.data

  ? check_attestation_target_epoch(data, state.get_current_epoch())
  ? check_attestation_slot_target(data)
  ? check_attestation_inclusion(data, state.slot)
  ? check_attestation_index(
      data,
      get_committee_count_per_slot(state, data.target.epoch, cache))

  let committee_len = get_beacon_committee_len(
    state, data.slot, data.index.CommitteeIndex, cache)

  if attestation.aggregation_bits.lenu64 != committee_len:
    return err("Inconsistent aggregation and committee length")

  if data.target.epoch == get_current_epoch(state):
    if not (data.source == state.current_justified_checkpoint):
      return err("FFG data not matching current justified epoch")
  else:
    if not (data.source == state.previous_justified_checkpoint):
      return err("FFG data not matching previous justified epoch")

  ? is_valid_indexed_attestation(state, attestation, flags, cache)

  ok()

proc process_attestation*(
    state: var SomeBeaconState, attestation: SomeAttestation, flags: UpdateFlags,
    base_reward_per_increment: Gwei, cache: var StateCache):
    Result[void, cstring] {.nbench.} =
  # In the spec, attestation validation is mixed with state mutation, so here
  # we've split it into two functions so that the validation logic can be
  # reused when looking for suitable blocks to include in attestations.
  #
  # TODO this should be two separate functions, but
  # https://github.com/nim-lang/Nim/issues/18202 means that this being called
  # by process_operations() in state_transition_block fails that way.

  let proposer_index = get_beacon_proposer_index(state, cache)
  if proposer_index.isNone:
    return err("process_attestation: no beacon proposer index and probably no active validators")

  ? check_attestation(state, attestation, flags, cache)

  # For phase0
  template addPendingAttestation(attestations: typed) =
    # The genericSeqAssign generated by the compiler to copy the attestation
    # data sadly is a processing hotspot - the business with the addDefault
    # pointer is here simply to work around the poor codegen
    var pa = attestations.addDefault()
    if pa.isNil:
      return err("process_attestation: too many pending attestations")
    assign(pa[].aggregation_bits, attestation.aggregation_bits)
    pa[].data = attestation.data
    pa[].inclusion_delay = state.slot - attestation.data.slot
    pa[].proposer_index = proposer_index.get().uint64

  # For Altair
  template updateParticipationFlags(epoch_participation: untyped) =
    var proposer_reward_numerator = 0'u64

    # Participation flag indices
    let
      participation_flag_indices =
        get_attestation_participation_flag_indices(
          state, attestation.data, state.slot - attestation.data.slot)

    for index in get_attesting_indices(state, attestation.data, attestation.aggregation_bits, cache):
        for flag_index, weight in PARTICIPATION_FLAG_WEIGHTS:
            if flag_index in participation_flag_indices and not has_flag(epoch_participation[index], flag_index):
              epoch_participation[index] = add_flag(epoch_participation[index], flag_index)
              proposer_reward_numerator += get_base_reward(
                state, index, base_reward_per_increment) * weight.uint64 # these are all valid, #TODO statically verify or do it type-safely

    # Reward proposer
    let
      # TODO use correct type at source
      proposer_reward_denominator = (WEIGHT_DENOMINATOR.uint64 - PROPOSER_WEIGHT.uint64) * WEIGHT_DENOMINATOR.uint64 div PROPOSER_WEIGHT.uint64
      proposer_reward = Gwei(proposer_reward_numerator div proposer_reward_denominator)
    increase_balance(state, proposer_index.get, proposer_reward)

  when state is phase0.BeaconState:
    doAssert base_reward_per_increment == 0.Gwei
    if attestation.data.target.epoch == get_current_epoch(state):
      addPendingAttestation(state.current_epoch_attestations)
    else:
      addPendingAttestation(state.previous_epoch_attestations)
  elif state is altair.BeaconState:
    doAssert base_reward_per_increment > 0.Gwei
    if attestation.data.target.epoch == get_current_epoch(state):
      updateParticipationFlags(state.current_epoch_participation)
    else:
      updateParticipationFlags(state.previous_epoch_participation)
  else:
    static: doAssert false

  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.7/specs/altair/beacon-chain.md#get_next_sync_committee_indices
func get_next_sync_committee_indices(state: altair.BeaconState):
    seq[ValidatorIndex] =
  ## Return the sequence of sync committee indices (which may include
  ## duplicate indices) for the next sync committee, given a ``state`` at a
  ## sync committee period boundary.

  # TODO this size is known statically, so return array[] if possible
  let epoch = get_current_epoch(state) + 1

  const MAX_RANDOM_BYTE = 255
  let
    active_validator_indices = get_active_validator_indices(state, epoch)
    active_validator_count = uint64(len(active_validator_indices))
    seed = get_seed(state, epoch, DOMAIN_SYNC_COMMITTEE)
  var
    i = 0'u64
    sync_committee_indices: seq[ValidatorIndex]
    hash_buffer: array[40, byte]
  hash_buffer[0..31] = seed.data
  while len(sync_committee_indices) < SYNC_COMMITTEE_SIZE:
    hash_buffer[32..39] = uint_to_bytes8(uint64(i div 32))
    let
      shuffled_index = compute_shuffled_index(uint64(i mod active_validator_count), active_validator_count, seed)
      candidate_index = active_validator_indices[shuffled_index]
      random_byte = eth2digest(hash_buffer).data[i mod 32]
      effective_balance = state.validators[candidate_index].effective_balance
    if effective_balance * MAX_RANDOM_BYTE >= MAX_EFFECTIVE_BALANCE * random_byte:
      sync_committee_indices.add candidate_index
    i += 1'u64
  sync_committee_indices

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.7/specs/altair/beacon-chain.md#get_next_sync_committee
proc get_next_sync_committee*(state: altair.BeaconState): SyncCommittee =
  ## Return the *next* sync committee for a given ``state``.
  let indices = get_next_sync_committee_indices(state)
  # TODO not robust
  doAssert indices.len == SYNC_COMMITTEE_SIZE

  var res: SyncCommittee
  for i, index in indices:
    res.pubkeys.data[i] = state.validators[index].pubkey
  res.pubkeys.resetCache()

  # see signatures_batch, TODO shouldn't be here
  # Deposit processing ensures all keys are valid
  var attestersAgg: AggregatePublicKey
  attestersAgg.init(res.pubkeys.data[0].loadWithCache().get)
  for i in 1 ..< res.pubkeys.data.len:
    attestersAgg.aggregate(res.pubkeys.data[i].loadWithCache().get)

  res.aggregate_pubkey = finish(attestersAgg).toPubKey()
  res

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/fork.md#upgrading-the-state
func translate_participation(
    state: var altair.BeaconState,
    pending_attestations: openArray[phase0.PendingAttestation]) =

  var cache = StateCache()
  for attestation in pending_attestations:
    let
      data = attestation.data
      inclusion_delay = attestation.inclusion_delay

      # Translate attestation inclusion info to flag indices
      participation_flag_indices =
        get_attestation_participation_flag_indices(state, data, inclusion_delay)

    # Apply flags to all attesting validators
    for index in get_attesting_indices(
        state, data, attestation.aggregation_bits, cache):
      for flag_index in participation_flag_indices:
        state.previous_epoch_participation[index] =
          add_flag(state.previous_epoch_participation[index], flag_index)

proc upgrade_to_altair*(cfg: RuntimeConfig, pre: phase0.BeaconState): ref altair.BeaconState =
  var
    empty_participation =
      HashList[ParticipationFlags, Limit VALIDATOR_REGISTRY_LIMIT]()
    inactivity_scores = HashList[uint64, Limit VALIDATOR_REGISTRY_LIMIT]()

  doAssert empty_participation.data.setLen(pre.validators.len)
  empty_participation.resetCache()

  doAssert inactivity_scores.data.setLen(pre.validators.len)
  inactivity_scores.resetCache()

  var post = (ref altair.BeaconState)(
    genesis_time: pre.genesis_time,
    genesis_validators_root: pre.genesis_validators_root,
    slot: pre.slot,
    fork: altairFork(cfg),

    # History
    latest_block_header: pre.latest_block_header,
    block_roots: pre.block_roots,
    state_roots: pre.state_roots,
    historical_roots: pre.historical_roots,

    # Eth1
    eth1_data: pre.eth1_data,
    eth1_data_votes: pre.eth1_data_votes,
    eth1_deposit_index: pre.eth1_deposit_index,

    # Registry
    validators: pre.validators,
    balances: pre.balances,

    # Randomness
    randao_mixes: pre.randao_mixes,

    # Slashings
    slashings: pre.slashings,

    # Attestations
    previous_epoch_participation: empty_participation,
    current_epoch_participation: empty_participation,

    # Finality
    justification_bits: pre.justification_bits,
    previous_justified_checkpoint: pre.previous_justified_checkpoint,
    current_justified_checkpoint: pre.current_justified_checkpoint,
    finalized_checkpoint: pre.finalized_checkpoint,

    # Inactivity
    inactivity_scores: inactivity_scores
  )

  # Fill in previous epoch participation from the pre state's pending
  # attestations
  translate_participation(post[], pre.previous_epoch_attestations.asSeq)

  # Fill in sync committees
  # Note: A duplicate committee is assigned for the current and next committee
  # at the fork boundary
  post[].current_sync_committee = get_next_sync_committee(post[])
  post[].next_sync_committee = get_next_sync_committee(post[])

  post
