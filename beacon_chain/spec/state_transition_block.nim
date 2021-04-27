# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# State transition - block processing, as described in
# https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#beacon-chain-state-transition-function
#
# The entry point is `process_block` which is at the bottom of this file.
#
# General notes about the code:
# * Weird styling - the sections taken from the spec use python styling while
#   the others use NEP-1 - helps grepping identifiers in spec
# * When updating the code, add TODO sections to mark where there are clear
#   improvements to be made - other than that, keep things similar to spec unless
#   motivated by security or performance considerations

{.push raises: [Defect].}

import
  std/[algorithm, intsets, options, sequtils],
  chronicles,
  ../extras, ../ssz/merkleization, metrics,
  ./beaconstate, ./crypto, ./datatypes, ./digest, ./helpers, ./validator,
  ./signatures, ./presets,
  ../../nbench/bench_lab

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#block-header
func process_block_header*(
    state: var BeaconState, blck: SomeBeaconBlock, flags: UpdateFlags,
    cache: var StateCache): Result[void, cstring] {.nbench.} =
  # Verify that the slots match
  if not (blck.slot == state.slot):
    return err("process_block_header: slot mismatch")

  # Verify that the block is newer than latest block header
  if not (blck.slot > state.latest_block_header.slot):
    return err("process_block_header: block not newer than latest block header")

  # Verify that proposer index is the correct index
  let proposer_index = get_beacon_proposer_index(state, cache)
  if proposer_index.isNone:
    return err("process_block_header: proposer missing")

  if not (blck.proposer_index.ValidatorIndex == proposer_index.get):
    return err("process_block_header: proposer index incorrect")

  # Verify that the parent matches
  if not (blck.parent_root == hash_tree_root(state.latest_block_header)):
    return err("process_block_header: previous block root mismatch")

  # Verify proposer is not slashed
  if state.validators.asSeq()[blck.proposer_index].slashed:
    return err("process_block_header: proposer slashed")

  # Cache current block as the new latest block
  state.latest_block_header = BeaconBlockHeader(
    slot: blck.slot,
    proposer_index: blck.proposer_index,
    parent_root: blck.parent_root,
    # state_root: zeroed, overwritten in the next `process_slot` call
    body_root: hash_tree_root(blck.body),
  )

  ok()

func `xor`[T: array](a, b: T): T =
  for i in 0..<result.len:
    result[i] = a[i] xor b[i]

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#randao
proc process_randao(
    state: var BeaconState, body: SomeBeaconBlockBody, flags: UpdateFlags,
    cache: var StateCache): Result[void, cstring] {.nbench.} =
  let
    proposer_index = get_beacon_proposer_index(state, cache)

  if proposer_index.isNone:
    return err("process_randao: proposer index missing, probably along with any active validators")

  # Verify RANDAO reveal
  let
    epoch = state.get_current_epoch()

  if skipBLSValidation notin flags:
    let proposer_pubkey = state.validators.asSeq()[proposer_index.get].pubkey

    if not verify_epoch_signature(
        state.fork, state.genesis_validators_root, epoch, proposer_pubkey,
        body.randao_reveal):

      return err("process_randao: invalid epoch signature")

  # Mix it in
  let
    mix = get_randao_mix(state, epoch)
    rr = eth2digest(body.randao_reveal.toRaw()).data

  state.randao_mixes[epoch mod EPOCHS_PER_HISTORICAL_VECTOR].data =
    mix.data xor rr

  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#eth1-data
func process_eth1_data(state: var BeaconState, body: SomeBeaconBlockBody): Result[void, cstring] {.nbench.}=
  if not state.eth1_data_votes.add body.eth1_data:
    # Count is reset  in process_final_updates, so this should never happen
    return err("process_eth1_data: no more room for eth1 data")

  if state.eth1_data_votes.asSeq.count(body.eth1_data).uint64 * 2 >
      SLOTS_PER_ETH1_VOTING_PERIOD:
    state.eth1_data = body.eth1_data
  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#is_slashable_validator
func is_slashable_validator(validator: Validator, epoch: Epoch): bool =
  # Check if ``validator`` is slashable.
  (not validator.slashed) and
    (validator.activation_epoch <= epoch) and
    (epoch < validator.withdrawable_epoch)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#proposer-slashings
proc check_proposer_slashing*(
    state: var BeaconState, proposer_slashing: SomeProposerSlashing,
    flags: UpdateFlags):
    Result[void, cstring] {.nbench.} =

  let
    header_1 = proposer_slashing.signed_header_1.message
    header_2 = proposer_slashing.signed_header_2.message

  # Not from spec
  if header_1.proposer_index >= state.validators.lenu64:
    return err("check_proposer_slashing: invalid proposer index")

  # Verify header slots match
  if not (header_1.slot == header_2.slot):
    return err("check_proposer_slashing: slot mismatch")

  # Verify header proposer indices match
  if not (header_1.proposer_index == header_2.proposer_index):
    return err("check_proposer_slashing: proposer indices mismatch")

  # Verify the headers are different
  if not (header_1 != header_2):
    return err("check_proposer_slashing: headers not different")

  # Verify the proposer is slashable
  let proposer = unsafeAddr state.validators.asSeq()[header_1.proposer_index]
  if not is_slashable_validator(proposer[], get_current_epoch(state)):
    return err("check_proposer_slashing: slashed proposer")

  # Verify signatures
  if skipBlsValidation notin flags:
    for signed_header in [proposer_slashing.signed_header_1,
        proposer_slashing.signed_header_2]:
      if not verify_block_signature(
          state.fork, state.genesis_validators_root, signed_header.message.slot,
          signed_header.message, proposer[].pubkey, signed_header.signature):
        return err("check_proposer_slashing: invalid signature")

  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#proposer-slashings
proc process_proposer_slashing*(
    state: var BeaconState, proposer_slashing: SomeProposerSlashing,
    flags: UpdateFlags, cache: var StateCache):
    Result[void, cstring] {.nbench.} =
  ? check_proposer_slashing(state, proposer_slashing, flags)
  slash_validator(
    state,
    proposer_slashing.signed_header_1.message.proposer_index.ValidatorIndex,
    cache)
  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#is_slashable_attestation_data
func is_slashable_attestation_data*(
    data_1: AttestationData, data_2: AttestationData): bool =
  ## Check if ``data_1`` and ``data_2`` are slashable according to Casper FFG
  ## rules.

  # Double vote
  (data_1 != data_2 and data_1.target.epoch == data_2.target.epoch) or
  # Surround vote
    (data_1.source.epoch < data_2.source.epoch and
     data_2.target.epoch < data_1.target.epoch)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#attester-slashings
proc check_attester_slashing*(
       state: var BeaconState,
       attester_slashing: SomeAttesterSlashing,
       flags: UpdateFlags
     ): Result[seq[ValidatorIndex], cstring] {.nbench.} =
  let
    attestation_1 = attester_slashing.attestation_1
    attestation_2 = attester_slashing.attestation_2

  if not is_slashable_attestation_data(
      attestation_1.data, attestation_2.data):
    return err("Attester slashing: surround or double vote check failed")

  if not is_valid_indexed_attestation(state, attestation_1, flags).isOk():
    return err("Attester slashing: invalid attestation 1")

  if not is_valid_indexed_attestation(state, attestation_2, flags).isOk():
    return err("Attester slashing: invalid attestation 2")

  var slashed_indices: seq[ValidatorIndex]

  for index in sorted(toSeq(intersection(
      toIntSet(attestation_1.attesting_indices.asSeq),
      toIntSet(attestation_2.attesting_indices.asSeq)).items), system.cmp):
    if is_slashable_validator(
        state.validators.asSeq()[index], get_current_epoch(state)):
      slashed_indices.add index.ValidatorIndex
  if slashed_indices.len == 0:
    return err("Attester slashing: Trying to slash participant(s) twice")

  ok slashed_indices

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#attester-slashings
proc process_attester_slashing*(
       state: var BeaconState,
       attester_slashing: SomeAttesterSlashing,
       flags: UpdateFlags,
       cache: var StateCache
     ): Result[void, cstring] {.nbench.} =
  let attester_slashing_validity =
    check_attester_slashing(state, attester_slashing, flags)

  if attester_slashing_validity.isErr:
    return err(attester_slashing_validity.error)

  for index in attester_slashing_validity.value:
    slash_validator(state, index, cache)

  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#voluntary-exits
proc check_voluntary_exit*(
    state: BeaconState,
    signed_voluntary_exit: SomeSignedVoluntaryExit,
    flags: UpdateFlags): Result[void, cstring] {.nbench.} =

  let voluntary_exit = signed_voluntary_exit.message

  # Not in spec. Check that validator_index is in range
  if voluntary_exit.validator_index >= state.validators.lenu64:
    return err("Exit: invalid validator index")

  let validator = unsafeAddr state.validators.asSeq()[voluntary_exit.validator_index]

  # Verify the validator is active
  if not is_active_validator(validator[], get_current_epoch(state)):
    return err("Exit: validator not active")

  # Verify exit has not been initiated
  if validator[].exit_epoch != FAR_FUTURE_EPOCH:
    return err("Exit: validator has exited")

  # Exits must specify an epoch when they become valid; they are not valid
  # before then
  if not (get_current_epoch(state) >= voluntary_exit.epoch):
    return err("Exit: exit epoch not passed")

  # Verify the validator has been active long enough
  if not (get_current_epoch(state) >= validator[].activation_epoch +
      SHARD_COMMITTEE_PERIOD):
    return err("Exit: not in validator set long enough")

  # Verify signature
  if skipBlsValidation notin flags:
    if not verify_voluntary_exit_signature(
        state.fork, state.genesis_validators_root, voluntary_exit,
        validator[].pubkey, signed_voluntary_exit.signature):
      return err("Exit: invalid signature")

  # Initiate exit
  debug "Exit: checking voluntary exit (validator_leaving)",
    index = voluntary_exit.validator_index,
    num_validators = state.validators.len,
    epoch = voluntary_exit.epoch,
    current_epoch = get_current_epoch(state),
    validator_slashed = validator[].slashed,
    validator_withdrawable_epoch = validator[].withdrawable_epoch,
    validator_exit_epoch = validator[].exit_epoch,
    validator_effective_balance = validator[].effective_balance

  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#voluntary-exits
proc process_voluntary_exit*(
    state: var BeaconState,
    signed_voluntary_exit: SomeSignedVoluntaryExit,
    flags: UpdateFlags,
    cache: var StateCache): Result[void, cstring] {.nbench.} =
  ? check_voluntary_exit(state, signed_voluntary_exit, flags)
  initiate_validator_exit(
    state, signed_voluntary_exit.message.validator_index.ValidatorIndex, cache)
  ok()

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#operations
proc process_operations(preset: RuntimePreset,
                        state: var BeaconState,
                        body: SomeBeaconBlockBody,
                        flags: UpdateFlags,
                        cache: var StateCache): Result[void, cstring] {.nbench.} =
  # Verify that outstanding deposits are processed up to the maximum number of
  # deposits
  let
    req_deposits = min(MAX_DEPOSITS,
                       state.eth1_data.deposit_count - state.eth1_deposit_index)
  if state.eth1_data.deposit_count < state.eth1_deposit_index or
      body.deposits.lenu64 != req_deposits:
    return err("incorrect number of deposits")

  template for_ops(operations: auto, fn: auto) =
    for operation in operations:
      let res = fn(state, operation, flags, cache)
      if res.isErr:
        return res

  for_ops(body.proposer_slashings, process_proposer_slashing)
  for_ops(body.attester_slashings, process_attester_slashing)
  for_ops(body.attestations, process_attestation)

  for deposit in body.deposits:
    let res = process_deposit(preset, state, deposit, flags)
    if res.isErr:
      return res

  for_ops(body.voluntary_exits, process_voluntary_exit)

  ok()

# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/merge/beacon-chain.md#compute_time_at_slot
func compute_time_at_slot*(state: BeaconState, slot: Slot): uint64 =
  # Note: This function is unsafe with respect to overflows and underflows.
  # TODO check against function by same name in eth1monitor
  doAssert slot >= GENESIS_SLOT

  let slots_since_genesis = slot - GENESIS_SLOT
  state.genesis_time + slots_since_genesis * SECONDS_PER_SLOT

# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/merge/beacon-chain.md#verify_execution_state_transition
func verify_execution_state_transition(execution_payload: ExecutionPayload):
    bool =
  # TODO
  true

# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/merge/beacon-chain.md#process_execution_payload
#func process_execution_payload(
proc process_execution_payload(
    state: var BeaconState, body: SomeBeaconBlockBody) =
  # Note: This function is designed to be able to be run in parallel with the
  # other `process_block` sub-functions

  # Rayonism starts post-merge
  doAssert is_transition_completed(state)

  let execution_payload = body.execution_payload

  # test suite trips over these due to is_transition_completed being pinned on
  # for Rayonism, but they're useful to enable otherwise
  when false:
    if is_transition_completed(state):
      doAssert execution_payload.parent_hash == state.latest_execution_payload_header.block_hash
      doAssert execution_payload.number == state.latest_execution_payload_header.number + 1

    doAssert execution_payload.timestamp == compute_time_at_slot(state, state.slot)
    doAssert verify_execution_state_transition(execution_payload)

  info "FOO5, in process_execution_payload",
    execution_payload_parent_hash = execution_payload.parent_hash,
    execution_payload_block_hash = execution_payload.block_hash,
    state_latest_execution_payload_header_block_hash = state.latest_execution_payload_header.block_hash

  state.latest_execution_payload_header = ExecutionPayloadHeader(
    block_hash: execution_payload.block_hash,
    parent_hash: execution_payload.parent_hash,
    coinbase: execution_payload.coinbase,
    state_root: execution_payload.state_root,
    number: execution_payload.number,
    gas_limit: execution_payload.gas_limit,
    gas_used: execution_payload.gas_used,
    timestamp: execution_payload.timestamp,
    receipt_root: execution_payload.receipt_root,
    logs_bloom: execution_payload.logs_bloom,
    transactions_root: hash_tree_root(execution_payload.transactions)
  )

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#block-processing
# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/merge/beacon-chain.md#block-processing
proc process_block*(
    preset: RuntimePreset,
    state: var BeaconState, blck: SomeBeaconBlock, flags: UpdateFlags,
    cache: var StateCache): Result[void, cstring] {.nbench.}=
  ## When there's a new block, we need to verify that the block is sane and
  ## update the state accordingly - the state is left in an unknown state when
  ## block application fails (!)

  ? process_block_header(state, blck, flags, cache)
  ? process_randao(state, blck.body, flags, cache)
  ? process_eth1_data(state, blck.body)
  ? process_operations(preset, state, blck.body, flags, cache)

  process_execution_payload(state, blck.body)  # [New in Merge]

  ok()
