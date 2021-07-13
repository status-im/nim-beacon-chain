# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/tables,
  chronicles,
  stew/[assign2, results],
  eth/keys,
  ../extras, ../beacon_clock,
  ../spec/[
    crypto, digest, forkedbeaconstate_helpers, helpers, signatures,
    signatures_batch, state_transition],
  ../spec/datatypes/[phase0, altair],
  ./block_pools_types, ./blockchain_dag, ./block_quarantine

from libp2p/protocols/pubsub/pubsub import ValidationResult

export results, ValidationResult

# Clearance
# ---------------------------------------------
#
# This module is in charge of making the
# "quarantined" network blocks
# pass the firewall and be stored in the chain DAG

logScope:
  topics = "clearance"

## At the GC-level, the GC is type-agnostic; it's all type-erased so
## casting between seq[Attestation] and seq[TrustedAttestation] will
## not disrupt GC operations.
##
## These SHOULD be used in function calls to avoid expensive temporary.
## see https://github.com/status-im/nimbus-eth2/pull/2250#discussion_r562010679
template asSigVerified(x: phase0.SignedBeaconBlock):
    phase0.SigVerifiedSignedBeaconBlock =
  ## This converts a signed beacon block to a sig verified beacon clock.
  ## This assumes that their bytes representation is the same.
  isomorphicCast[phase0.SigVerifiedSignedBeaconBlock](x)

template asSigVerified(x: altair.SignedBeaconBlock):
    altair.SigVerifiedSignedBeaconBlock =
  ## This converts a signed beacon block to a sig verified beacon clock.
  ## This assumes that their bytes representation is the same.
  isomorphicCast[altair.SigVerifiedSignedBeaconBlock](x)

template asTrusted(x: phase0.SignedBeaconBlock or phase0.SigVerifiedBeaconBlock):
    phase0.TrustedSignedBeaconBlock =
  ## This converts a sigverified beacon block to a trusted beacon clock.
  ## This assumes that their bytes representation is the same.
  isomorphicCast[phase0.TrustedSignedBeaconBlock](x)

template asTrusted(x: altair.SignedBeaconBlock or altair.SigVerifiedBeaconBlock):
    altair.TrustedSignedBeaconBlock =
  ## This converts a sigverified beacon block to a trusted beacon clock.
  ## This assumes that their bytes representation is the same.
  isomorphicCast[altair.TrustedSignedBeaconBlock](x)

func batchVerify(quarantine: QuarantineRef, sigs: openArray[SignatureSet]): bool =
  var secureRandomBytes: array[32, byte]
  quarantine.rng[].brHmacDrbgGenerate(secureRandomBytes)

  # TODO: For now only enable serial batch verification
  return batchVerifySerial(quarantine.sigVerifCache, sigs, secureRandomBytes)

proc addRawBlock*(
      dag: ChainDAGRef, quarantine: QuarantineRef,
      signedBlock: phase0.SignedBeaconBlock | altair.SignedBeaconBlock,
      onBlockAdded: OnPhase0BlockAdded | OnAltairBlockAdded
     ): Result[BlockRef, (ValidationResult, BlockError)] {.gcsafe.}

# Now that we have the new block, we should see if any of the previously
# unresolved blocks magically become resolved
# TODO This code is convoluted because when there are more than ~1.5k
#      blocks being synced, there's a stack overflow as `add` gets called
#      for the whole chain of blocks. Instead we use this ugly field in `dag`
#      which could be avoided by refactoring the code
# TODO unit test the logic, in particular interaction with fork choice block parents
proc resolveQuarantinedBlocks(
    dag: ChainDAGRef, quarantine: QuarantineRef,
    onBlockAdded: OnPhase0BlockAdded) =
  if not quarantine.inAdd:
    quarantine.inAdd = true
    defer: quarantine.inAdd = false
    var entries = 0
    while entries != quarantine.orphansPhase0.len:
      entries = quarantine.orphansPhase0.len # keep going while quarantine is shrinking
      var resolved: seq[phase0.SignedBeaconBlock]
      for _, v in quarantine.orphansPhase0:
        if v.message.parent_root in dag:
          resolved.add(v)

      for v in resolved:
        discard addRawBlock(dag, quarantine, v, onBlockAdded)

proc resolveQuarantinedBlocks(
    dag: ChainDAGRef, quarantine: QuarantineRef,
    onBlockAdded: OnAltairBlockAdded) =
  if not quarantine.inAdd:
    quarantine.inAdd = true
    defer: quarantine.inAdd = false
    var entries = 0
    while entries != quarantine.orphansAltair.len:
      entries = quarantine.orphansAltair.len # keep going while quarantine is shrinking
      var resolved: seq[altair.SignedBeaconBlock]
      for _, v in quarantine.orphansAltair:
        if v.message.parent_root in dag:
          resolved.add(v)

      for v in resolved:
        discard addRawBlock(dag, quarantine, v, onBlockAdded)

proc addResolvedBlock(
       dag: ChainDAGRef, quarantine: QuarantineRef,
       state: var StateData,
       trustedBlock: phase0.TrustedSignedBeaconBlock | altair.TrustedSignedBeaconBlock,
       parent: BlockRef, cache: var StateCache,
       onBlockAdded: OnPhase0BlockAdded | OnAltairBlockAdded,
       stateDataDur, sigVerifyDur,
       stateVerifyDur: Duration
     ) =
  doAssert getStateField(state.data, slot) == trustedBlock.message.slot,
    "state must match block"
  doAssert state.blck.root == trustedBlock.message.parent_root,
    "the StateData passed into the addResolved function not yet updated!"

  let
    blockRoot = trustedBlock.root
    blockRef = BlockRef.init(blockRoot, trustedBlock.message)
    startTick = Moment.now()

  link(parent, blockRef)

  dag.blocks.incl(KeyedBlockRef.init(blockRef))

  # Resolved blocks should be stored in database
  dag.putBlock(trustedBlock)
  let putBlockTick = Moment.now()

  var foundHead: bool
  for head in dag.heads.mitems():
    if head.isAncestorOf(blockRef):
      head = blockRef
      foundHead = true
      break

  if not foundHead:
    dag.heads.add(blockRef)

  # Up to here, state.data was referring to the new state after the block had
  # been applied but the `blck` field was still set to the parent
  state.blck = blockRef

  # Regardless of the chain we're on, the deposits come in the same order so
  # as soon as we import a block, we'll also update the shared public key
  # cache

  dag.updateValidatorKeys(getStateField(state.data, validators).asSeq())

  # Getting epochRef with the state will potentially create a new EpochRef
  let
    epochRef = dag.getEpochRef(state, cache)
    epochRefTick = Moment.now()

  debug "Block resolved",
    blck = shortLog(trustedBlock.message),
    blockRoot = shortLog(blockRoot),
    heads = dag.heads.len(),
    stateDataDur, sigVerifyDur, stateVerifyDur,
    putBlockDur = putBlockTick - startTick,
    epochRefDur = epochRefTick - putBlockTick

  # Notify others of the new block before processing the quarantine, such that
  # notifications for parents happens before those of the children
  if onBlockAdded != nil:
    onBlockAdded(blockRef, trustedBlock, epochRef)

  resolveQuarantinedBlocks(dag, quarantine, onBlockAdded)

# TODO workaround for https://github.com/nim-lang/Nim/issues/18095
type SomeSignedBlock =
  phase0.SignedBeaconBlock | phase0.SigVerifiedSignedBeaconBlock |
  phase0.TrustedSignedBeaconBlock |
  altair.SignedBeaconBlock | altair.SigVerifiedSignedBeaconBlock |
  altair.TrustedSignedBeaconBlock
proc checkStateTransition(
       dag: ChainDAGRef, signedBlock: SomeSignedBlock,
       cache: var StateCache): (ValidationResult, BlockError) =
  ## Ensure block can be applied on a state
  func restore(v: var ForkedHashedBeaconState) =
    # TODO address this ugly workaround - there should probably be a
    #      `state_transition` that takes a `StateData` instead and updates
    #      the block as well
    doAssert v.addr == addr dag.clearanceState.data
    assign(dag.clearanceState, dag.headState)

  logScope:
    blck = shortLog(signedBlock.message)
    blockRoot = shortLog(signedBlock.root)

  if not state_transition_block(
      dag.cfg, dag.clearanceState.data, signedBlock,
      cache, dag.updateFlags, restore):
    info "Invalid block"

    return (ValidationResult.Reject, Invalid)
  return (ValidationResult.Accept, default(BlockError))

proc advanceClearanceState*(dag: ChainDAGRef) =
  # When the chain is synced, the most likely block to be produced is the block
  # right after head - we can exploit this assumption and advance the state
  # to that slot before the block arrives, thus allowing us to do the expensive
  # epoch transition ahead of time.
  # Notably, we use the clearance state here because that's where the block will
  # first be seen - later, this state will be copied to the head state!
  if dag.clearanceState.blck.slot == getStateField(dag.clearanceState.data, slot):
    let next =
      dag.clearanceState.blck.atSlot(dag.clearanceState.blck.slot + 1)

    let startTick = Moment.now()
    var cache = StateCache()
    updateStateData(dag, dag.clearanceState, next, true, cache)

    debug "Prepared clearance state for next block",
      next, updateStateDur = Moment.now() - startTick

proc addRawBlockKnownParent(
       dag: ChainDAGRef, quarantine: QuarantineRef,
       signedBlock: phase0.SignedBeaconBlock | altair.SignedBeaconBlock,
       parent: BlockRef,
       onBlockAdded: OnPhase0BlockAdded | OnAltairBlockAdded
     ): Result[BlockRef, (ValidationResult, BlockError)] =
  ## Add a block whose parent is known, after performing validity checks

  if parent.slot >= signedBlock.message.slot:
    # A block whose parent is newer than the block itself is clearly invalid -
    # discard it immediately
    debug "Invalid block slot",
      parentBlock = shortLog(parent)

    return err((ValidationResult.Reject, Invalid))

  if (parent.slot < dag.finalizedHead.slot) or
      (parent.slot == dag.finalizedHead.slot and
        parent != dag.finalizedHead.blck):
    # We finalized a block that's newer than the parent of this block - this
    # block, although recent, is thus building on a history we're no longer
    # interested in pursuing. This can happen if a client produces a block
    # while syncing - ie it's own head block will be old, but it'll create
    # a block according to the wall clock, in its own little world - this is
    # correct - from their point of view, the head block they have is the
    # latest thing that happened on the chain and they're performing their
    # duty correctly.
    debug "Unviable block, dropping",
      finalizedHead = shortLog(dag.finalizedHead),
      tail = shortLog(dag.tail)

    return err((ValidationResult.Ignore, Unviable))

  # The block might have been in either of `orphans` or `missing` - we don't
  # want any more work done on its behalf
  quarantine.removeOrphan(signedBlock)

  # The block is resolved, now it's time to validate it to ensure that the
  # blocks we add to the database are clean for the given state
  let startTick = Moment.now()

  var cache = StateCache()
  updateStateData(
    dag, dag.clearanceState, parent.atSlot(signedBlock.message.slot), true, cache)
  let stateDataTick = Moment.now()

  # First, batch-verify all signatures in block
  if skipBLSValidation notin dag.updateFlags:
    # TODO: remove skipBLSValidation
    var sigs: seq[SignatureSet]
    if sigs.collectSignatureSets(
        signedBlock, dag.db.immutableValidators.byIndex,
        dag.clearanceState.data,
        dag.forkAtSlot(signedBlock.message.slot),
        getStateField(dag.clearanceState.data, genesis_validators_root),
        cache).isErr():
      # A PublicKey or Signature isn't on the BLS12-381 curve
      return err((ValidationResult.Reject, Invalid))
    if not quarantine.batchVerify(sigs):
      return err((ValidationResult.Reject, Invalid))

  let sigVerifyTick = Moment.now()
  let (valRes, blockErr) = checkStateTransition(
    dag, signedBlock.asSigVerified(), cache)
  if valRes != ValidationResult.Accept:
    return err((valRes, blockErr))

  let stateVerifyTick = Moment.now()
  # Careful, clearanceState.data has been updated but not blck - we need to
  # create the BlockRef first!
  addResolvedBlock(
    dag, quarantine, dag.clearanceState,
    signedBlock.asTrusted(),
    parent, cache,
    onBlockAdded,
    stateDataDur = stateDataTick - startTick,
    sigVerifyDur = sigVerifyTick - stateDataTick,
    stateVerifyDur = stateVerifyTick - sigVerifyTick)

  return ok dag.clearanceState.blck

proc addRawBlockUnresolved(
       dag: ChainDAGRef,
       quarantine: QuarantineRef,
       signedBlock: phase0.SignedBeaconBlock | altair.SignedBeaconBlock,
     ): Result[BlockRef, (ValidationResult, BlockError)] =
  ## addRawBlock - Block is unresolved / has no parent

  logScope:
    blck = shortLog(signedBlock.message)
    blockRoot = shortLog(signedBlock.root)

  # This is an unresolved block - add it to the quarantine, which will cause its
  # parent to be scheduled for downloading
  if not quarantine.add(dag, signedBlock):
    debug "Block quarantine full"

  if signedBlock.message.parent_root in quarantine.missing or
      containsOrphan(quarantine, signedBlock):
    debug "Unresolved block (parent missing or orphaned)",
      orphansPhase0 = quarantine.orphansPhase0.len,
      orphansAltair = quarantine.orphansAltair.len,
      missing = quarantine.missing.len

    return err((ValidationResult.Ignore, MissingParent))

  # TODO if we receive spam blocks, one heurestic to implement might be to wait
  #      for a couple of attestations to appear before fetching parents - this
  #      would help prevent using up network resources for spam - this serves
  #      two purposes: one is that attestations are likely to appear for the
  #      block only if it's valid / not spam - the other is that malicious
  #      validators that are not proposers can sign invalid blocks and send
  #      them out without penalty - but signing invalid attestations carries
  #      a risk of being slashed, making attestations a more valuable spam
  #      filter.
  debug "Unresolved block (parent missing)",
    orphansPhase0 = quarantine.orphansPhase0.len,
    orphansAltair = quarantine.orphansAltair.len,
    missing = quarantine.missing.len

  return err((ValidationResult.Ignore, MissingParent))

proc addRawBlock(
       dag: ChainDAGRef, quarantine: QuarantineRef,
       signedBlock: phase0.SignedBeaconBlock | altair.SignedBeaconBlock,
       onBlockAdded: OnPhase0BlockAdded | OnAltairBlockAdded
     ): Result[BlockRef, (ValidationResult, BlockError)] =
  ## Try adding a block to the chain, verifying first that it passes the state
  ## transition function and contains correct cryptographic signature.
  ##
  ## Cryptographic checks can be skipped by adding skipBLSValidation to dag.updateFlags

  logScope:
    blck = shortLog(signedBlock.message)
    blockRoot = shortLog(signedBlock.root)

  template blck(): untyped = signedBlock.message # shortcuts without copy
  template blockRoot(): untyped = signedBlock.root

  if blockRoot in dag:
    debug "Block already exists"

    # We should not call the block added callback for blocks that already
    # existed in the pool, as that may confuse consumers such as the fork
    # choice. While the validation result won't be accessed, it's IGNORE,
    # according to the spec.
    return err((ValidationResult.Ignore, Duplicate))

  quarantine.missing.del(blockRoot)

  # If the block we get is older than what we finalized already, we drop it.
  # One way this can happen is that we start resolving a block and finalization
  # happens in the meantime - the block we requested will then be stale
  # by the time it gets here.
  if blck.slot <= dag.finalizedHead.slot:
    debug "Old block, dropping",
      finalizedHead = shortLog(dag.finalizedHead),
      tail = shortLog(dag.tail)

    # Doesn't correspond to any specific validation condition, and still won't
    # be used, but certainly would be IGNORE.
    return err((ValidationResult.Ignore, Unviable))

  let parent = dag.getRef(blck.parent_root)

  if parent != nil:
    return addRawBlockKnownParent(dag, quarantine, signedBlock, parent, onBlockAdded)
  return addRawBlockUnresolved(dag, quarantine, signedBlock)
