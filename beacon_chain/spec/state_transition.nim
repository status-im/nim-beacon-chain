# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# State transition, as described in
# https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#beacon-chain-state-transition-function
#
# The purpose of this code right is primarily educational, to help piece
# together the mechanics of the beacon state and to discover potential problem
# areas. The entry point is `state_transition` which is at the bottom of the file!
#
# General notes about the code (TODO):
# * Weird styling - the sections taken from the spec use python styling while
#   the others use NEP-1 - helps grepping identifiers in spec
# * We mix procedural and functional styles for no good reason, except that the
#   spec does so also.
# * For indices, we get a mix of uint64, ValidatorIndex and int - this is currently
#   swept under the rug with casts
# * Sane error handling is missing in most cases (yay, we'll get the chance to
#   debate exceptions again!)
# When updating the code, add TODO sections to mark where there are clear
# improvements to be made - other than that, keep things similar to spec for
# now.

{.push raises: [Defect].}

import
  tables,
  chronicles,
  stew/results,
  ../extras, ../ssz/merkleization, metrics,
  datatypes, crypto, digest, helpers, signatures, validator,
  state_transition_block, state_transition_epoch,
  ../../nbench/bench_lab

# https://github.com/ethereum/eth2.0-metrics/blob/master/metrics.md#additional-metrics
declareGauge beacon_current_validators, """Number of status="pending|active|exited|withdrawable" validators in current epoch""" # On epoch transition
declareGauge beacon_previous_validators, """Number of status="pending|active|exited|withdrawable" validators in previous epoch""" # On epoch transition

func get_epoch_validator_count(state: BeaconState): int64 {.nbench.} =
  # https://github.com/ethereum/eth2.0-metrics/blob/master/metrics.md#additional-metrics
  #
  # This O(n) loop doesn't add to the algorithmic complexity of the epoch
  # transition -- registry update already does this. It is not great, but
  # isn't new, either. If profiling shows issues some of this can be loop
  # fusion'ed.
  for index, validator in state.validators:
    # These work primarily for the `beacon_current_validators` metric defined
    # as 'Number of status="pending|active|exited|withdrawable" validators in
    # current epoch'. This is, in principle, equivalent to checking whether a
    # validator's either at less than MAX_EFFECTIVE_BALANCE, or has withdrawn
    # already because withdrawable_epoch has passed, which more precisely has
    # intuitive meaning of all-the-current-relevant-validators. So, check for
    # not-(either (not-even-pending) or withdrawn). That is validators change
    # from not-even-pending to pending to active to exited to withdrawable to
    # withdrawn, and this avoids bugs on potential edge cases and off-by-1's.
    if (validator.activation_epoch != FAR_FUTURE_EPOCH or
          validator.effective_balance > MAX_EFFECTIVE_BALANCE) and
       validator.withdrawable_epoch > get_current_epoch(state):
      result += 1

# https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
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

# https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
proc verifyStateRoot(state: BeaconState, blck: BeaconBlock): bool =
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
  RollbackHashedProc* = proc(state: var HashedBeaconState) {.gcsafe.}

# Hashed-state transition functions
# ---------------------------------------------------------------

# https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
func process_slot*(state: var HashedBeaconState) {.nbench.} =
  # Cache state root
  let previous_slot_state_root = state.root
  state.data.state_roots[state.data.slot mod SLOTS_PER_HISTORICAL_ROOT] =
    previous_slot_state_root

  # Cache latest block header state root
  if state.data.latest_block_header.state_root == ZERO_HASH:
    state.data.latest_block_header.state_root = previous_slot_state_root

  # Cache block root
  state.data.block_roots[state.data.slot mod SLOTS_PER_HISTORICAL_ROOT] =
    hash_tree_root(state.data.latest_block_header)

func clear_epoch_from_cache(cache: var StateCache, epoch: Epoch) =
  cache.shuffled_active_validator_indices.del epoch
  let
    start_slot = epoch.compute_start_slot_at_epoch
    end_slot = (epoch + 1).compute_start_slot_at_epoch

  for i in start_slot ..< end_slot:
    cache.beacon_proposer_indices.del i

# https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
proc advance_slot*(
    state: var HashedBeaconState, updateFlags: UpdateFlags,
    epochCache: var StateCache) {.nbench.} =
  # Special case version of process_slots that moves one slot at a time - can
  # run faster if the state root is known already (for example when replaying
  # existing slots)
  process_slot(state)
  let is_epoch_transition = (state.data.slot + 1).isEpoch
  if is_epoch_transition:
    # Note: Genesis epoch = 0, no need to test if before Genesis
    beacon_previous_validators.set(get_epoch_validator_count(state.data))
    process_epoch(state.data, updateFlags, epochCache)
    clear_epoch_from_cache(
      epochCache, (state.data.slot + 1).compute_epoch_at_slot)
  state.data.slot += 1
  if is_epoch_transition:
    beacon_current_validators.set(get_epoch_validator_count(state.data))

  state.root = hash_tree_root(state.data)

# https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/beacon-chain.md#beacon-chain-state-transition-function
proc process_slots*(state: var HashedBeaconState, slot: Slot,
    updateFlags: UpdateFlags = {}): bool {.nbench.} =
  # TODO this function is not _really_ necessary: when replaying states, we
  #      advance slots one by one before calling `state_transition` - this way,
  #      we avoid the state root calculation - as such, instead of advancing
  #      slots "automatically" in `state_transition`, perhaps it would be better
  #      to keep a pre-condition that state must be at the right slot already?
  if not (state.data.slot < slot):
    notice(
      "Unusual request for a slot in the past",
      state_root = shortLog(state.root),
      current_slot = state.data.slot,
      target_slot = slot
    )
    return false

  # Catch up to the target slot
  var cache = StateCache()
  while state.data.slot < slot:
    advance_slot(state, updateFlags, cache)

  true

proc noRollback*(state: var HashedBeaconState) =
  trace "Skipping rollback of broken state"

proc state_transition*(
    preset: RuntimePreset,
    state: var HashedBeaconState, signedBlock: SomeSignedBeaconBlock,
    # TODO this is ... okay, but not perfect; align with EpochRef
    stateCache: var StateCache,
    flags: UpdateFlags, rollback: RollbackHashedProc): bool {.nbench.} =
  ## Time in the beacon chain moves by slots. Every time (haha.) that happens,
  ## we will update the beacon state. Normally, the state updates will be driven
  ## by the contents of a new block, but it may happen that the block goes
  ## missing - the state updates happen regardless.
  ##
  ## The flags are used to specify that certain validations should be skipped
  ## for the new block. This is done during block proposal, to create a state
  ## whose hash can be included in the new block.
  ##
  ## `rollback` is called if the transition fails and the given state has been
  ## partially changed. If a temporary state was given to `state_transition`,
  ## it is safe to use `noRollback` and leave it broken, else the state
  ## object should be rolled back to a consistent state. If the transition fails
  ## before the state has been updated, `rollback` will not be called.
  doAssert not rollback.isNil, "use noRollback if it's ok to mess up state"

  if not process_slots(state, signedBlock.message.slot, flags):
    rollback(state)
    return false

  # Block updates - these happen when there's a new block being suggested
  # by the block proposer. Every actor in the network will update its state
  # according to the contents of this block - but first they will validate
  # that the block is sane.
  if skipBLSValidation in flags or
      verify_block_signature(state.data, signedBlock):

    # TODO after checking scaffolding, remove this
    trace "state_transition: processing block, signature passed",
      signature = shortLog(signedBlock.signature),
      blockRoot = shortLog(signedBlock.root)
    if process_block(preset, state.data, signedBlock.message, flags, stateCache):
      if skipStateRootValidation in flags or verifyStateRoot(state.data, signedBlock.message):
        # State root is what it should be - we're done!

        # TODO when creating a new block, state_root is not yet set.. comparing
        #      with zero hash here is a bit fragile however, but this whole thing
        #      should go away with proper hash caching
        # TODO shouldn't ever have to recalculate; verifyStateRoot() does it
        state.root =
          if signedBlock.message.state_root == Eth2Digest(): hash_tree_root(state.data)
          else: signedBlock.message.state_root

        return true

  # Block processing failed, roll back changes
  rollback(state)

  false

proc state_transition*(
    preset: RuntimePreset,
    state: var HashedBeaconState, signedBlock: SomeSignedBeaconBlock,
    flags: UpdateFlags, rollback: RollbackHashedProc): bool {.nbench.} =
  # TODO consider moving this to testutils or similar, since non-testing
  # and fuzzing code should always be coming from block pool which should
  # always be providing cache or equivalent
  var cache = StateCache()
  state_transition(preset, state, signedBlock, cache, flags, rollback)

# https://github.com/ethereum/eth2.0-specs/blob/v0.12.1/specs/phase0/validator.md#preparing-for-a-beaconblock
# TODO There's more to do here - the spec has helpers that deal set up some of
#      the fields in here!
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
      attestations: List[Attestation, Limit MAX_ATTESTATIONS](attestations),
      deposits: List[Deposit, Limit MAX_DEPOSITS](deposits)))

  let ok = process_block(preset, state.data, blck, {skipBlsValidation}, cache)

  if not ok:
    warn "Unable to apply new block to state", blck = shortLog(blck)
    rollback(state)
    return

  state.root = hash_tree_root(state.data)
  blck.state_root = state.root

  some(blck)
