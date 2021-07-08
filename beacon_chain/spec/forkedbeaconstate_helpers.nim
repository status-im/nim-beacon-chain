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
  stew/[assign2, results],
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

  BeaconBlockFork* {.pure.} = enum
    Phase0
    Altair

  ForkedSignedBeaconBlock* = object
    case kind*: BeaconBlockFork
    of BeaconBlockFork.Phase0:
      phase0Block*: phase0.SignedBeaconBlock
    of BeaconBlockFork.Altair:
      altairBlock*: altair.SignedBeaconBlock

  ForkedTrustedSignedBeaconBlock* = object
    case kind*: BeaconBlockFork
    of BeaconBlockFork.Phase0:
      phase0Block*: phase0.TrustedSignedBeaconBlock
    of BeaconBlockFork.Altair:
      altairBlock*: altair.TrustedSignedBeaconBlock

  ForkDigests* = object
    phase0*: ForkDigest
    altair*: ForkDigest
    altairTopicPrefix*: string # Used by isAltairTopic

  ForkDigestsRef* = ref ForkDigests

template init*(T: type ForkedSignedBeaconBlock, blck: phase0.SignedBeaconBlock): T =
  T(kind: BeaconBlockFork.Phase0, phase0Block: blck)
template init*(T: type ForkedSignedBeaconBlock, blck: altair.SignedBeaconBlock): T =
  T(kind: BeaconBlockFork.Altair, altairBlock: blck)

template init*(T: type ForkedTrustedSignedBeaconBlock, blck: phase0.TrustedSignedBeaconBlock): T =
  T(kind: BeaconBlockFork.Phase0, phase0Block: blck)
template init*(T: type ForkedTrustedSignedBeaconBlock, blck: altair.TrustedSignedBeaconBlock): T =
  T(kind: BeaconBlockFork.Altair, altairBlock: blck)

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

func setStateRoot*(x: var ForkedHashedBeaconState, root: Eth2Digest) =
  case x.beaconStateFork:
  of forkPhase0: x.hbsPhase0.root = root
  of forkAltair: x.hbsAltair.root = root

template hash_tree_root*(x: ForkedHashedBeaconState): Eth2Digest =
  case x.beaconStateFork:
  of forkPhase0: hash_tree_root(x.hbsPhase0.data)
  of forkAltair: hash_tree_root(x.hbsAltair.data)

func get_active_validator_indices_len*(
    state: ForkedHashedBeaconState; epoch: Epoch): uint64 =
  case state.beaconStateFork:
  of forkPhase0:
    get_active_validator_indices_len(state.hbsPhase0.data, epoch)
  of forkAltair:
    get_active_validator_indices_len(state.hbsAltair.data, epoch)

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
    cfg: RuntimeConfig, state: ForkedHashedBeaconState;
    signed_voluntary_exit: SomeSignedVoluntaryExit;
    flags: UpdateFlags): Result[void, cstring] =
  case state.beaconStateFork:
  of forkPhase0:
    check_voluntary_exit(cfg, state.hbsPhase0.data, signed_voluntary_exit, flags)
  of forkAltair:
    check_voluntary_exit(cfg, state.hbsAltair.data, signed_voluntary_exit, flags)

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

func init*(T: type ForkDigests,
           cfg: RuntimeConfig,
           genesisValidatorsRoot: Eth2Digest): T =
  let altairForkDigest = compute_fork_digest(
    cfg.ALTAIR_FORK_VERSION,
    genesisValidatorsRoot)

  T(phase0: compute_fork_digest(
      cfg.GENESIS_FORK_VERSION,
      genesisValidatorsRoot),
    altair: altairForkDigest,
    altairTopicPrefix: $altairForkDigest)

template asSigned*(x: phase0.TrustedSignedBeaconBlock or phase0.SigVerifiedBeaconBlock):
    phase0.SignedBeaconBlock =
  isomorphicCast[phase0.SignedBeaconBlock](x)

template asSigned*(x: altair.TrustedSignedBeaconBlock or altair.SigVerifiedBeaconBlock):
    altair.SignedBeaconBlock =
  isomorphicCast[altair.SignedBeaconBlock](x)

template asSigned*(x: ForkedTrustedSignedBeaconBlock): ForkedSignedBeaconBlock =
  isomorphicCast[ForkedSignedBeaconBlock](x)

template asTrusted*(x: phase0.SignedBeaconBlock or phase0.SigVerifiedBeaconBlock):
    phase0.TrustedSignedBeaconBlock =
  isomorphicCast[phase0.TrustedSignedBeaconBlock](x)

template asTrusted*(x: altair.SignedBeaconBlock or altair.SigVerifiedBeaconBlock):
    altair.TrustedSignedBeaconBlock =
  isomorphicCast[altair.TrustedSignedBeaconBlock](x)

template asTrusted*(x: ForkedSignedBeaconBlock): ForkedSignedBeaconBlock =
  isomorphicCast[ForkedTrustedSignedBeaconBlock](x)

template withBlck*(x: ForkedSignedBeaconBlock | ForkedTrustedSignedBeaconBlock, body: untyped): untyped =
  case x.kind
  of BeaconBlockFork.Phase0:
    template blck: untyped = x.phase0Block
    body
  of BeaconBlockFork.Altair:
    template blck: untyped = x.altairBlock
    body

template getForkedBlockField*(x: ForkedSignedBeaconBlock | ForkedTrustedSignedBeaconBlock, y: untyped): untyped =
  withBlck(x): blck.message.y

template signature*(x: ForkedSignedBeaconBlock): ValidatorSig =
  withBlck(x): blck.signature

template signature*(x: ForkedTrustedSignedBeaconBlock): TrustedSig =
  withBlck(x): blck.signature

template root*(x: ForkedSignedBeaconBlock | ForkedTrustedSignedBeaconBlock): Eth2Digest =
  withBlck(x): blck.root

template slot*(x: ForkedSignedBeaconBlock | ForkedTrustedSignedBeaconBlock): Slot =
  getForkedBlockField(x, slot)

func shortLog*(x: ForkedSignedBeaconBlock | ForkedTrustedSignedBeaconBlock): auto =
  withBlck(x): shortLog(blck.message)

chronicles.formatIt ForkedSignedBeaconBlock: it.shortLog
chronicles.formatIt ForkedTrustedSignedBeaconBlock: it.shortLog
