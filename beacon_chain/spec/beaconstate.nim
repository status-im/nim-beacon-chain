# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[tables, algorithm, math, sequtils, options],
  json_serialization/std/sets,
  chronicles,
  ../extras, ../ssz/merkleization,
  ./crypto, ./datatypes, ./digest, ./helpers, ./signatures, ./validator,
  ../../nbench/bench_lab

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#is_valid_merkle_branch
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

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#increase_balance
func increase_balance*(
    state: var BeaconState, index: ValidatorIndex, delta: Gwei) =
  ## Increase the validator balance at index ``index`` by ``delta``.
  state.balances[index] += delta

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#decrease_balance
func decrease_balance*(
    state: var BeaconState, index: ValidatorIndex, delta: Gwei) =
  ## Decrease the validator balance at index ``index`` by ``delta``, with
  ## underflow protection.
  state.balances[index] =
    if delta > state.balances[index]:
      0'u64
    else:
      state.balances[index] - delta

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#deposits
func get_validator_from_deposit(state: BeaconState, deposit: DepositData):
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

proc process_deposit*(preset: RuntimePreset,
                      state: var BeaconState,
                      deposit: Deposit,
                      flags: UpdateFlags = {}): Result[void, cstring] {.nbench.}=
  ## Process an Eth1 deposit, registering a validator or increasing its balance.

  # Verify the Merkle branch
  if not is_valid_merkle_branch(
    hash_tree_root(deposit.data),
    deposit.proof,
    DEPOSIT_CONTRACT_TREE_DEPTH + 1,  # Add 1 for the `List` length mix-in
    state.eth1_deposit_index,
    state.eth1_data.deposit_root,
  ):
    return err("process_deposit: deposit Merkle validation failed")

  # Deposits must be processed in order
  state.eth1_deposit_index += 1

  let
    pubkey = deposit.data.pubkey
    pubkey_inited = pubkey.initPubKey
    amount = deposit.data.amount
  var index = -1

  for i, validator in state.validators:
    if pubkey_inited == validator.pubkey.initPubKey:
      index = i
      break

  if index == -1:
    # Verify the deposit signature (proof of possession) which is not checked
    # by the deposit contract
    if skipBLSValidation notin flags:
      if not verify_deposit_signature(preset, deposit.data):
        # It's ok that deposits fail - they get included in blocks regardless
        trace "Skipping deposit with invalid signature",
          deposit = shortLog(deposit.data)
        return ok()

    # Add validator and balance entries
    state.validators.add(get_validator_from_deposit(state, deposit.data))
    state.balances.add(amount)
  else:
     # Increase balance by deposit amount
     increase_balance(state, index.ValidatorIndex, amount)

  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#compute_activation_exit_epoch
func compute_activation_exit_epoch(epoch: Epoch): Epoch =
  ## Return the epoch during which validator activations and exits initiated in
  ## ``epoch`` take effect.
  epoch + 1 + MAX_SEED_LOOKAHEAD

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#get_validator_churn_limit
func get_validator_churn_limit(state: BeaconState, cache: var StateCache): uint64 =
  ## Return the validator churn limit for the current epoch.
  max(
    MIN_PER_EPOCH_CHURN_LIMIT,
    count_active_validators(
      state, state.get_current_epoch(), cache) div CHURN_LIMIT_QUOTIENT)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#initiate_validator_exit
func initiate_validator_exit*(state: var BeaconState,
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
  for v in state.validators:
    if v.exit_epoch != FAR_FUTURE_EPOCH and v.exit_epoch > exit_queue_epoch:
      exit_queue_epoch = v.exit_epoch

  let
    exit_queue_churn = countIt(
      state.validators, it.exit_epoch == exit_queue_epoch)

  if exit_queue_churn.uint64 >= get_validator_churn_limit(state, cache):
    exit_queue_epoch += 1

  # Set validator exit epoch and withdrawable epoch
  validator.exit_epoch = exit_queue_epoch
  validator.withdrawable_epoch =
    validator.exit_epoch + MIN_VALIDATOR_WITHDRAWABILITY_DELAY

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#slash_validator
proc slash_validator*(state: var BeaconState, slashed_index: ValidatorIndex,
    cache: var StateCache) =
  ## Slash the validator with index ``index``.
  let epoch = get_current_epoch(state)
  initiate_validator_exit(state, slashed_index, cache)
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
  decrease_balance(state, slashed_index,
    validator.effective_balance div MIN_SLASHING_PENALTY_QUOTIENT)

  # The rest doesn't make sense without there being any proposer index, so skip
  let proposer_index = get_beacon_proposer_index(state, cache)
  if proposer_index.isNone:
    debug "No beacon proposer index and probably no active validators"
    return

  # Apply proposer and whistleblower rewards
  let
    # Spec has whistleblower_index as optional param, but it's never used.
    whistleblower_index = proposer_index.get
    whistleblowing_reward =
      (validator.effective_balance div WHISTLEBLOWER_REWARD_QUOTIENT).Gwei
    proposer_reward = whistleblowing_reward div PROPOSER_REWARD_QUOTIENT
  increase_balance(state, proposer_index.get, proposer_reward)
  # TODO: evaluate if spec bug / underflow can be triggered
  doAssert(whistleblowing_reward >= proposer_reward, "Spec bug: underflow in slash_validator")
  increase_balance(
    state, whistleblower_index, whistleblowing_reward - proposer_reward)

func genesis_time_from_eth1_timestamp*(preset: RuntimePreset, eth1_timestamp: uint64): uint64 =
  eth1_timestamp + preset.GENESIS_DELAY

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#genesis
proc initialize_beacon_state_from_eth1*(
    preset: RuntimePreset,
    eth1_block_hash: Eth2Digest,
    eth1_timestamp: uint64,
    deposits: openArray[DepositData],
    flags: UpdateFlags = {}): BeaconStateRef {.nbench.} =
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

  var state = BeaconStateRef(
    fork: Fork(
      previous_version: preset.GENESIS_FORK_VERSION,
      current_version: preset.GENESIS_FORK_VERSION,
      epoch: GENESIS_EPOCH),
    genesis_time: genesis_time_from_eth1_timestamp(preset, eth1_timestamp),
    eth1_data:
      Eth1Data(block_hash: eth1_block_hash, deposit_count: uint64(len(deposits))),
    latest_block_header:
      BeaconBlockHeader(
        body_root: hash_tree_root(BeaconBlockBody(
          # This differs from the spec intentionally.
          # We must specify the default value for `ValidatorSig`
          # in order to get a correct `hash_tree_root`.
          randao_reveal: ValidatorSig(kind: OpaqueBlob)
        ))
      )
  )

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
         verify_deposit_signature(preset, deposit):
        pubkeyToIndex[pubkey] = state.validators.len
        state.validators.add(get_validator_from_deposit(state[], deposit))
        state.balances.add(amount)
      else:
        # Invalid deposits are perfectly possible
        trace "Skipping deposit with invalid signature",
          deposit = shortLog(deposit)

  # Process activations
  for validator_index in 0 ..< state.validators.len:
    let
      balance = state.balances[validator_index]
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
    preset: RuntimePreset,
    eth1_block_hash: Eth2Digest,
    eth1_timestamp: uint64,
    deposits: openArray[DepositData],
    flags: UpdateFlags = {}): HashedBeaconState =
  let genesisState = initialize_beacon_state_from_eth1(
    preset, eth1_block_hash, eth1_timestamp, deposits, flags)
  HashedBeaconState(data: genesisState[], root: hash_tree_root(genesisState[]))

func emptyBeaconBlockBody(): BeaconBlockBody =
  # TODO: This shouldn't be necessary if OpaqueBlob is the default
  BeaconBlockBody(randao_reveal: ValidatorSig(kind: OpaqueBlob))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#genesis-block
func get_initial_beacon_block*(state: BeaconState): SignedBeaconBlock =
  let message = BeaconBlock(
    slot: state.slot,
    state_root: hash_tree_root(state),
    body: emptyBeaconBlockBody())
    # parent_root, randao_reveal, eth1_data, signature, and body automatically
    # initialized to default values.
  SignedBeaconBlock(message: message, root: hash_tree_root(message))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#get_block_root_at_slot
func get_block_root_at_slot*(state: BeaconState,
                             slot: Slot): Eth2Digest =
  ## Return the block root at a recent ``slot``.

  # Potential overflow/wrap shouldn't occur, as get_block_root_at_slot() called
  # from internally controlled sources, but flag this explicitly, in case.
  doAssert slot + SLOTS_PER_HISTORICAL_ROOT > slot

  doAssert state.slot <= slot + SLOTS_PER_HISTORICAL_ROOT
  doAssert slot < state.slot
  state.block_roots[slot mod SLOTS_PER_HISTORICAL_ROOT]

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#get_block_root
func get_block_root*(state: BeaconState, epoch: Epoch): Eth2Digest =
  ## Return the block root at the start of a recent ``epoch``.
  get_block_root_at_slot(state, compute_start_slot_at_epoch(epoch))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#get_total_balance
func get_total_balance*(state: BeaconState, validators: auto): Gwei =
  ## Return the combined effective balance of the ``indices``.
  ## ``EFFECTIVE_BALANCE_INCREMENT`` Gwei minimum to avoid divisions by zero.
  ## Math safe up to ~10B ETH, afterwhich this overflows uint64.
  max(EFFECTIVE_BALANCE_INCREMENT,
    foldl(validators, a + state.validators[b].effective_balance, 0'u64)
  )

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#is_eligible_for_activation_queue
func is_eligible_for_activation_queue(validator: Validator): bool =
  ## Check if ``validator`` is eligible to be placed into the activation queue.
  validator.activation_eligibility_epoch == FAR_FUTURE_EPOCH and
    validator.effective_balance == MAX_EFFECTIVE_BALANCE

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#is_eligible_for_activation
func is_eligible_for_activation(state: BeaconState, validator: Validator):
    bool =
  ## Check if ``validator`` is eligible for activation.

  # Placement in queue is finalized
  validator.activation_eligibility_epoch <= state.finalized_checkpoint.epoch and
  # Has not yet been activated
    validator.activation_epoch == FAR_FUTURE_EPOCH

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#registry-updates
proc process_registry_updates*(state: var BeaconState,
    cache: var StateCache) {.nbench.} =
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
  for index, validator in state.validators:
    if is_eligible_for_activation_queue(validator):
      state.validators[index].activation_eligibility_epoch =
        get_current_epoch(state) + 1

    if is_active_validator(validator, get_current_epoch(state)) and
        validator.effective_balance <= EJECTION_BALANCE:
      initiate_validator_exit(state, index.ValidatorIndex, cache)

  ## Queue validators eligible for activation and not dequeued for activation
  var activation_queue : seq[tuple[a: Epoch, b: int]] = @[]
  for index, validator in state.validators:
    if is_eligible_for_activation(state, validator):
      activation_queue.add (
        state.validators[index].activation_eligibility_epoch, index)

  activation_queue.sort(system.cmp)

  ## Dequeued validators for activation up to churn limit (without resetting
  ## activation epoch)
  let churn_limit = get_validator_churn_limit(state, cache)
  for i, epoch_and_index in activation_queue:
    if i.uint64 >= churn_limit:
      break
    let
      (_, index) = epoch_and_index
      validator = addr state.validators[index]
    validator.activation_epoch =
      compute_activation_exit_epoch(get_current_epoch(state))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#is_valid_indexed_attestation
proc is_valid_indexed_attestation*(
    state: BeaconState, indexed_attestation: SomeIndexedAttestation,
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
  if skipBLSValidation notin flags:
    let pubkeys = mapIt(
      indexed_attestation.attesting_indices, state.validators[it].pubkey)
    if not verify_attestation_signature(
        state.fork, state.genesis_validators_root, indexed_attestation.data,
        pubkeys, indexed_attestation.signature):
      return err("indexed attestation: signature verification failure")

  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#get_attesting_indices
iterator get_attesting_indices*(bits: CommitteeValidatorsBits,
                                committee: openArray[ValidatorIndex]):
                                  ValidatorIndex =
  if bits.len == committee.len:
    for i, index in committee:
      if bits[i]:
        yield index
  else:
    # This shouldn't happen if one begins with a valid BeaconState and applies
    # valid updates, but one can construct a BeaconState where it does. Do not
    # do anything here since the PendingAttestation wouldn't have made it past
    # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#attestations
    # which checks len(attestation.aggregation_bits) == len(committee) that in
    # nimbus-eth2 lives in check_attestation(...).
    # Addresses https://github.com/status-im/nimbus-eth2/issues/922

    trace "get_attesting_indices: inconsistent aggregation and committee length"

func get_attesting_indices*(bits: CommitteeValidatorsBits,
                            committee: openArray[ValidatorIndex]):
                            HashSet[ValidatorIndex] =
  for idx in get_attesting_indices(bits, committee):
    result.incl idx

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#get_attesting_indices
iterator get_attesting_indices*(state: BeaconState,
                                data: AttestationData,
                                bits: CommitteeValidatorsBits,
                                cache: var StateCache): ValidatorIndex =
  if bits.lenu64 != get_beacon_committee_len(state, data.slot, data.index.CommitteeIndex, cache):
    trace "get_attesting_indices: inconsistent aggregation and committee length"
  else:
    var i = 0
    for index in get_beacon_committee(state, data.slot, data.index.CommitteeIndex, cache):
      if bits[i]:
        yield index
      inc i

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#get_attesting_indices
func get_attesting_indices*(state: BeaconState,
                            data: AttestationData,
                            bits: CommitteeValidatorsBits,
                            cache: var StateCache):
                            HashSet[ValidatorIndex] =
  # Return the set of attesting indices corresponding to ``data`` and ``bits``.
  for index in get_attesting_indices(state, data, bits, cache):
    result.incl index

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#get_indexed_attestation
func get_indexed_attestation(state: BeaconState, attestation: Attestation,
    cache: var StateCache): IndexedAttestation =
  ## Return the indexed attestation corresponding to ``attestation``.
  let
    attesting_indices =
      get_attesting_indices(
        state, attestation.data, attestation.aggregation_bits, cache)

  IndexedAttestation(
    attesting_indices:
      List[uint64, Limit MAX_VALIDATORS_PER_COMMITTEE].init(
        sorted(mapIt(attesting_indices.toSeq, it.uint64), system.cmp)),
    data: attestation.data,
    signature: attestation.signature
  )

func get_indexed_attestation(state: BeaconState, attestation: TrustedAttestation,
    cache: var StateCache): TrustedIndexedAttestation =
  ## Return the indexed attestation corresponding to ``attestation``.
  let
    attesting_indices =
      get_attesting_indices(
        state, attestation.data, attestation.aggregation_bits, cache)

  TrustedIndexedAttestation(
    attesting_indices:
      List[uint64, Limit MAX_VALIDATORS_PER_COMMITTEE].init(
        sorted(mapIt(attesting_indices.toSeq, it.uint64), system.cmp)),
    data: attestation.data,
    signature: attestation.signature
  )

# Attestation validation
# ------------------------------------------------------------------------------------------
# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#attestations
# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#beacon_attestation_subnet_id

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

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/beacon-chain.md#attestations
proc check_attestation*(
    state: BeaconState, attestation: SomeAttestation, flags: UpdateFlags,
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

  ? is_valid_indexed_attestation(
      state, get_indexed_attestation(state, attestation, cache), flags)

  ok()

proc process_attestation*(
    state: var BeaconState, attestation: SomeAttestation, flags: UpdateFlags,
    cache: var StateCache): Result[void, cstring] {.nbench.} =
  # In the spec, attestation validation is mixed with state mutation, so here
  # we've split it into two functions so that the validation logic can be
  # reused when looking for suitable blocks to include in attestations.

  let proposer_index = get_beacon_proposer_index(state, cache)
  if proposer_index.isNone:
    return err("process_attestation: no beacon proposer index and probably no active validators")

  ? check_attestation(state, attestation, flags, cache)

  let
    attestation_slot = attestation.data.slot
    pending_attestation = PendingAttestation(
      data: attestation.data,
      aggregation_bits: attestation.aggregation_bits,
      inclusion_delay: state.slot - attestation_slot,
      proposer_index: proposer_index.get.uint64,
    )

  if attestation.data.target.epoch == get_current_epoch(state):
    trace "current_epoch_attestations.add",
      attestation = shortLog(attestation),
      pending_attestation = shortLog(pending_attestation),
      indices = get_attesting_indices(
        state, attestation.data, attestation.aggregation_bits, cache).len
    state.current_epoch_attestations.add(pending_attestation)
  else:
    trace "previous_epoch_attestations.add",
      attestation = shortLog(attestation),
      pending_attestation = shortLog(pending_attestation),
      indices = get_attesting_indices(
        state, attestation.data, attestation.aggregation_bits, cache).len
    state.previous_epoch_attestations.add(pending_attestation)

  ok()

func makeAttestationData*(
    state: BeaconState, slot: Slot, committee_index: CommitteeIndex,
    beacon_block_root: Eth2Digest): AttestationData =
  ## Create an attestation / vote for the block `beacon_block_root` using the
  ## data in `state` to fill in the rest of the fields.
  ## `state` is the state corresponding to the `beacon_block_root` advanced to
  ## the slot we're attesting to.

  let
    current_epoch = get_current_epoch(state)
    start_slot = compute_start_slot_at_epoch(current_epoch)
    epoch_boundary_block_root =
      if start_slot == state.slot: beacon_block_root
      else: get_block_root_at_slot(state, start_slot)

  doAssert slot.compute_epoch_at_slot == current_epoch,
    "Computed epoch was " & $slot.compute_epoch_at_slot &
    "  while the state current_epoch was " & $current_epoch

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#attestation-data
  AttestationData(
    slot: slot,
    index: committee_index.uint64,
    beacon_block_root: beacon_block_root,
    source: state.current_justified_checkpoint,
    target: Checkpoint(
      epoch: current_epoch,
      root: epoch_boundary_block_root
    )
  )
