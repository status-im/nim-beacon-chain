# beacon_chain
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/macros,
  chronicles,
  stew/[assign2, results], ssz_serialization,
  ../extras,
  ../spec/[
    beaconstate, digest, helpers, presets, state_transition_block, validator],
  ./datatypes/[phase0, altair]

type
  BeaconStateFork* = enum
    forkPhase0,
    forkAltair

  ForkedHashedBeaconState* = object
    case beaconStateFork*: BeaconStateFork
    of forkPhase0: hbsPhase0*: phase0.HashedBeaconState
    of forkAltair: hbsAltair*: altair.HashedBeaconState

# State-related functionality based on ForkedHashedBeaconState instead of BeaconState

# Dispatch functions
func assign*(tgt: var ForkedHashedBeaconState, src: ForkedHashedBeaconState) =
  if tgt.beaconStateFork == src.beaconStateFork:
    if tgt.beaconStateFork == forkPhase0:
      assign(tgt.hbsPhase0, src.hbsPhase0):
    elif tgt.beaconStateFork == forkAltair:
      assign(tgt.hbsAltair, src.hbsAltair):
    else:
      doAssert false
  else:
    # Ensure case object and discriminator get updated simultaneously, even
    # with nimOldCaseObjects. This is infrequent.
    tgt = src

macro getStateField*(s, y: untyped): untyped =
  result = quote do:
    (if `s`.beaconStateFork == forkPhase0:
       unsafeAddr (`s`.hbsPhase0.data.`y`) else:
         unsafeAddr (`s`.hbsAltair.data.`y`))[]

template getStateRoot*(x: ForkedHashedBeaconState): Eth2Digest =
  case x.beaconStateFork:
  of forkPhase0: x.hbsPhase0.root
  of forkAltair: x.hbsAltair.root

template hash_tree_root*(x: ForkedHashedBeaconState): Eth2Digest =
  case x.beaconStateFork:
  of forkPhase0: hash_tree_root(x.hbsPhase0.data)
  of forkAltair: hash_tree_root(x.hbsAltair.data)

func get_beacon_committee*(
    state: ForkedHashedBeaconState, slot: Slot, index: CommitteeIndex,
    cache: var StateCache): seq[ValidatorIndex] =
  # This one is used by tests/, ncli/, and a couple of places in RPC
  # TODO use the iterator version alone, to remove the risk of using
  # diverging get_beacon_committee() in tests and beacon_chain/ by a
  # wrapper approach (e.g., toSeq). This is a perf tradeoff for test
  # correctness/consistency.
  case state.beaconStateFork:
  of forkPhase0: get_beacon_committee(state.hbsPhase0.data, slot, index, cache)
  of forkAltair: get_beacon_committee(state.hbsAltair.data, slot, index, cache)
  
func get_committee_count_per_slot*(state: ForkedHashedBeaconState,
                                   epoch: Epoch,
                                   cache: var StateCache): uint64 =
  ## Return the number of committees at ``epoch``.
  case state.beaconStateFork:
  of forkPhase0: get_committee_count_per_slot(state.hbsPhase0.data, epoch, cache)
  of forkAltair: get_committee_count_per_slot(state.hbsAltair.data, epoch, cache)

func get_beacon_proposer_index*(state: ForkedHashedBeaconState,
                                cache: var StateCache, slot: Slot):
                                Option[ValidatorIndex] =
  case state.beaconStateFork:
  of forkPhase0: get_beacon_proposer_index(state.hbsPhase0.data, cache, slot)
  of forkAltair: get_beacon_proposer_index(state.hbsAltair.data, cache, slot)

func get_shuffled_active_validator_indices*(
    cache: var StateCache, state: ForkedHashedBeaconState, epoch: Epoch):
    seq[ValidatorIndex] =
  case state.beaconStateFork:
  of forkPhase0:
    cache.get_shuffled_active_validator_indices(state.hbsPhase0.data, epoch)
  of forkAltair:
    cache.get_shuffled_active_validator_indices(state.hbsAltair.data, epoch)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_block_root_at_slot
func get_block_root_at_slot*(state: ForkedHashedBeaconState,
                             slot: Slot): Eth2Digest =
  ## Return the block root at a recent ``slot``.
  case state.beaconStateFork:
  of forkPhase0: get_block_root_at_slot(state.hbsPhase0.data, slot)
  of forkAltair: get_block_root_at_slot(state.hbsAltair.data, slot)

proc get_attesting_indices*(state: ForkedHashedBeaconState;
                            data: AttestationData;
                            bits: CommitteeValidatorsBits;
                            cache: var StateCache): seq[ValidatorIndex] =
  # TODO when https://github.com/nim-lang/Nim/issues/18188 fixed, use an
  # iterator

  var idxBuf: seq[ValidatorIndex]

  doAssert  state.beaconStateFork == forkPhase0
  for vidx in state.hbsPhase0.data.get_attesting_indices(data, bits, cache):
    idxBuf.add vidx
  if true: return idxBuf

  if state.beaconStateFork == forkPhase0:
    for vidx in state.hbsPhase0.data.get_attesting_indices(data, bits, cache):
      idxBuf.add vidx
  elif state.beaconStateFork == forkAltair:
    for vidx in state.hbsAltair.data.get_attesting_indices(data, bits, cache):
      idxBuf.add vidx
  else:
    doAssert false

  idxBuf

proc check_attester_slashing*(
    state: var ForkedHashedBeaconState; attester_slashing: SomeAttesterSlashing;
    flags: UpdateFlags): Result[seq[ValidatorIndex], cstring] =
  case state.beaconStateFork:
  of forkPhase0:
    check_attester_slashing(state.hbsPhase0.data, attester_slashing, flags)
  of forkAltair:
    check_attester_slashing(state.hbsAltair.data, attester_slashing, flags)

proc check_proposer_slashing*(
    state: var ForkedHashedBeaconState; proposer_slashing: SomeProposerSlashing;
    flags: UpdateFlags): Result[void, cstring] =
  case state.beaconStateFork:
  of forkPhase0:
    check_proposer_slashing(state.hbsPhase0.data, proposer_slashing, flags)
  of forkAltair:
    check_proposer_slashing(state.hbsAltair.data, proposer_slashing, flags)

proc check_voluntary_exit*(
    state: ForkedHashedBeaconState; signed_voluntary_exit: SomeSignedVoluntaryExit;
    flags: UpdateFlags): Result[void, cstring] =
  case state.beaconStateFork:
  of forkPhase0:
    check_voluntary_exit(state.hbsPhase0.data, signed_voluntary_exit, flags)
  of forkAltair:
    check_voluntary_exit(state.hbsAltair.data, signed_voluntary_exit, flags)

# Derived utilities

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_current_epoch
func get_current_epoch*(stateData: ForkedHashedBeaconState): Epoch =
  ## Return the current epoch.
  getStateField(stateData, slot).epoch

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_previous_epoch
func get_previous_epoch*(stateData: ForkedHashedBeaconState): Epoch =
  ## Return the previous epoch (unless the current epoch is ``GENESIS_EPOCH``).
  let current_epoch = get_current_epoch(stateData)
  if current_epoch == GENESIS_EPOCH:
    GENESIS_EPOCH
  else:
    current_epoch - 1
