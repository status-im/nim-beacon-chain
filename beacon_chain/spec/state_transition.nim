# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# State transition, as described in
# https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#beacon-chain-state-transition-function
#
# The entry point is `state_transition` which is at the bottom of the file!
#
# General notes about the code:
# * Weird styling - the sections taken from the spec use python styling while
#   the others use NEP-1 - helps grepping identifiers in spec
# * When updating the code, add TODO sections to mark where there are clear
#   improvements to be made - other than that, keep things similar to spec unless
#   motivated by security or performance considerations
#
# Performance notes:
# * The state transition is used in two contexts: to verify that incoming blocks
#   are correct and to replay existing blocks from database. Incoming blocks
#   are processed one-by-one while replay happens multiple blocks at a time.
# * Although signature verification is the slowest operation in the state
#   state transition, we skip it during replay - this is also when we repeatedly
#   call the state transition, making the non-signature part of the code
#   important from a performance point of view.
# * It's important to start with a prefilled cache - generating the shuffled
#   list of active validators is generally very slow.
# * Throughout, the code is affected by inefficient for loop codegen, meaning
#   that we have to iterate over indices and pick out the value manually:
#   https://github.com/nim-lang/Nim/issues/14421
# * Throughout, we're affected by inefficient `let` borrowing, meaning we
#   often have to take the address of a sequence item due to the above - look
#   for `let ... = unsafeAddr sequence[idx]`
# * Throughout, we're affected by the overloading rules that prefer a `var`
#   overload to a non-var overload - look for `asSeq()` - when the `var`
#   overload is used, the hash tree cache is cleared, which, aside from being
#   slow itself, causes additional processing to recalculate the merkle tree.

{.push raises: [Defect].}

import
  std/tables,
  chronicles,
  stew/results,
  ../extras, ../ssz/merkleization, metrics,
  ./datatypes, ./crypto, ./digest, ./helpers, ./signatures, ./validator,
  ./state_transition_block, ./state_transition_epoch,
  ../../nbench/bench_lab

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
proc verify_block_signature*(
    state: BeaconState, signed_block: SomeSignedBeaconBlock): bool {.nbench.} =
  let
    proposer_index = signed_block.message.proposer_index
  if proposer_index >= state.validators.lenu64:
    notice "Invalid proposer index in block",
      blck = shortLog(signed_block.message)
    return false

  if not verify_block_signature(
      state.fork, state.genesis_validators_root, signed_block.message.slot,
      signed_block.message, state.validators[proposer_index].pubkey,
      signed_block.signature):
    notice "Block: signature verification failed",
      blck = shortLog(signedBlock)
    return false

  true

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
proc verifyStateRoot(state: BeaconState, blck: BeaconBlock or SigVerifiedBeaconBlock): bool =
  # This is inlined in state_transition(...) in spec.
  let state_root = hash_tree_root(state)
  if state_root != blck.state_root:
    notice "Block: root verification failed",
      block_state_root = shortLog(blck.state_root), state_root = shortLog(state_root)
    false
  else:
    true

proc verifyStateRoot(state: BeaconState, blck: TrustedBeaconBlock): bool =
  # This is inlined in state_transition(...) in spec.
  true

type
  RollbackProc* = proc(v: var BeaconState) {.gcsafe, raises: [Defect].}

proc noRollback*(state: var BeaconState) =
  trace "Skipping rollback of broken state"

type
  RollbackHashedProc* = proc(state: var HashedBeaconState) {.gcsafe, raises: [Defect].}

# Hashed-state transition functions
# ---------------------------------------------------------------

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
func process_slot*(
    state: var BeaconState, pre_state_root: Eth2Digest) {.nbench.} =
  # `process_slot` is the first stage of per-slot processing - it is run for
  # every slot, including epoch slots - it does not however update the slot
  # number! `pre_state_root` refers to the state root of the incoming
  # state before any slot processing has been done.

  # Cache state root
  state.state_roots[state.slot mod SLOTS_PER_HISTORICAL_ROOT] = pre_state_root

  # Cache latest block header state root
  if state.latest_block_header.state_root == ZERO_HASH:
    state.latest_block_header.state_root = pre_state_root

  # Cache block root
  state.block_roots[state.slot mod SLOTS_PER_HISTORICAL_ROOT] =
    hash_tree_root(state.latest_block_header)

func clear_epoch_from_cache(cache: var StateCache, epoch: Epoch) =
  cache.shuffled_active_validator_indices.del epoch
  let
    start_slot = epoch.compute_start_slot_at_epoch
    end_slot = (epoch + 1).compute_start_slot_at_epoch

  for i in start_slot ..< end_slot:
    cache.beacon_proposer_indices.del i

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
proc advance_slot(
    state: var BeaconState, previous_slot_state_root: Eth2Digest,
    flags: UpdateFlags, cache: var StateCache, rewards: var RewardInfo) {.nbench.} =
  # Do the per-slot and potentially the per-epoch processing, then bump the
  # slot number - we've now arrived at the slot state on top of which a block
  # optionally can be applied.
  process_slot(state, previous_slot_state_root)

  rewards.statuses.setLen(0)
  rewards.total_balances = TotalBalances()

  let is_epoch_transition = (state.slot + 1).isEpoch
  if is_epoch_transition:
    # Note: Genesis epoch = 0, no need to test if before Genesis
    process_epoch(state, flags, cache, rewards)
    clear_epoch_from_cache(cache, (state.slot + 1).compute_epoch_at_slot)

  state.slot += 1

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
proc process_slots*(state: var HashedBeaconState, slot: Slot,
    cache: var StateCache, rewards: var RewardInfo,
    flags: UpdateFlags = {}): bool {.nbench.} =
  ## Process one or more slot transitions without blocks - if the slot transtion
  ## passes an epoch boundary, epoch processing will run and `rewards` will be
  ## updated, else it will be cleared
  if not (state.data.slot < slot):
    if slotProcessed notin flags or state.data.slot != slot:
      notice(
        "Unusual request for a slot in the past",
        state_root = shortLog(state.root),
        current_slot = state.data.slot,
        target_slot = slot
      )
      return false

  # Catch up to the target slot
  while state.data.slot < slot:
    advance_slot(state.data, state.root, flags, cache, rewards)

    # The root must be updated on every slot update, or the next `process_slot`
    # will be incorrect
    state.root = hash_tree_root(state.data)

  true

proc noRollback*(state: var HashedBeaconState) =
  trace "Skipping rollback of broken state"

proc state_transition*(
    preset: RuntimePreset,
    state: var HashedBeaconState, signedBlock: SomeSignedBeaconBlock,
    cache: var StateCache, rewards: var RewardInfo, flags: UpdateFlags,
    rollback: RollbackHashedProc): bool {.nbench.} =
  ## Apply a block to the state, advancing the slot counter as necessary. The
  ## given state must be of a lower slot, or, in case the `slotProcessed` flag
  ## is set, can be the slot state of the same slot as the block (where the
  ## slot state is the state without any block applied). To create a slot state,
  ## advance the state corresponding to the the parent block using
  ## `process_slots`.
  ##
  ## To run the state transition function in preparation for block production,
  ## use `makeBeaconBlock` instead.
  ##
  ## `rollback` is called if the transition fails and the given state has been
  ## partially changed. If a temporary state was given to `state_transition`,
  ## it is safe to use `noRollback` and leave it broken, else the state
  ## object should be rolled back to a consistent state. If the transition fails
  ## before the state has been updated, `rollback` will not be called.
  doAssert not rollback.isNil, "use noRollback if it's ok to mess up state"

  let slot = signedBlock.message.slot
  if not (state.data.slot < slot):
    if slotProcessed notin flags or state.data.slot != slot:
      notice "State must precede block",
        state_root = shortLog(state.root),
        current_slot = state.data.slot,
        blck = shortLog(signedBlock)
      return false

  # Update the state so its slot matches that of the block
  while state.data.slot < slot:
    advance_slot(state.data, state.root, flags, cache, rewards)

    if state.data.slot < slot:
      # Don't update state root for the slot of the block
      state.root = hash_tree_root(state.data)

  # Block updates - these happen when there's a new block being suggested
  # by the block proposer. Every actor in the network will update its state
  # according to the contents of this block - but first they will validate
  # that the block is sane.
  if not (skipBLSValidation in flags or
      verify_block_signature(state.data, signedBlock)):
    rollback(state)
    return false

  trace "state_transition: processing block, signature passed",
    signature = shortLog(signedBlock.signature),
    blockRoot = shortLog(signedBlock.root)

  let res = process_block(preset, state.data, signedBlock.message, flags, cache)

  if not res.isOk():
    debug "state_transition: process_block failed",
      blck = shortLog(signedBlock.message),
      slot = state.data.slot,
      eth1_deposit_index = state.data.eth1_deposit_index,
      deposit_root = shortLog(state.data.eth1_data.deposit_root),
      error = res.error
    rollback(state)
    return false

  if not (skipStateRootValidation in flags or
        verifyStateRoot(state.data, signedBlock.message)):
    rollback(state)
    return false

  # only blocks currently being produced have an empty state root - we use a
  # separate function for those
  doAssert signedBlock.message.state_root != Eth2Digest(),
    "see makeBeaconBlock for block production"
  state.root = signedBlock.message.state_root

  true

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#preparing-for-a-beaconblock
proc makeBeaconBlock*(
    preset: RuntimePreset,
    state: var HashedBeaconState,
    proposer_index: ValidatorIndex,
    parent_root: Eth2Digest,
    randao_reveal: ValidatorSig,
    eth1_data: Eth1Data,
    graffiti: GraffitiBytes,
    attestations: seq[Attestation],
    deposits: seq[Deposit],
    proposerSlashings: seq[ProposerSlashing],
    attesterSlashings: seq[AttesterSlashing],
    voluntaryExits: seq[SignedVoluntaryExit],
    executionPayload: ExecutionPayload,
    rollback: RollbackHashedProc,
    cache: var StateCache): Option[BeaconBlock] =
  ## Create a block for the given state. The last block applied to it must be
  ## the one identified by parent_root and process_slots must be called up to
  ## the slot for which a block is to be created.

  # To create a block, we'll first apply a partial block to the state, skipping
  # some validations.

  var blck = BeaconBlock(
    slot: state.data.slot,
    proposer_index: proposer_index.uint64,
    parent_root: parent_root,
    body: BeaconBlockBody(
      randao_reveal: randao_reveal,
      eth1_data: eth1data,
      graffiti: graffiti,
      proposer_slashings: List[ProposerSlashing, Limit MAX_PROPOSER_SLASHINGS](
        proposerSlashings),
      attester_slashings: List[AttesterSlashing, Limit MAX_ATTESTER_SLASHINGS](
        attesterSlashings),
      attestations: List[Attestation, Limit MAX_ATTESTATIONS](attestations),
      deposits: List[Deposit, Limit MAX_DEPOSITS](deposits),
      voluntary_exits:
        List[SignedVoluntaryExit, Limit MAX_VOLUNTARY_EXITS](voluntaryExits),
      execution_payload: executionPayload))

  let res = process_block(preset, state.data, blck, {skipBlsValidation}, cache)

  if res.isErr:
    warn "Unable to apply new block to state",
      blck = shortLog(blck),
      slot = state.data.slot,
      eth1_deposit_index = state.data.eth1_deposit_index,
      deposit_root = shortLog(state.data.eth1_data.deposit_root),
      error = res.error
    rollback(state)
    return

  state.root = hash_tree_root(state.data)
  blck.state_root = state.root

  return some(blck)
