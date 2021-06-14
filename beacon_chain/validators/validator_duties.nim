# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  # Standard library
  std/[os, osproc, sequtils, streams, tables],

  # Nimble packages
  stew/[assign2, byteutils, objects],
  chronos, metrics,
  chronicles,
  json_serialization/std/[options, sets, net], serialization/errors,
  eth/db/kvstore,
  eth/keys, eth/p2p/discoveryv5/[protocol, enr],

  # Local modules
  ../spec/[
    datatypes, digest, crypto, forkedbeaconstate_helpers, helpers, network,
    signatures, state_transition],
  ../conf, ../beacon_clock,
  ../consensus_object_pools/[
    spec_cache, blockchain_dag, block_clearance,
    attestation_pool, exit_pool],
  ../eth1/eth1_monitor,
  ../networking/eth2_network,
  ".."/[beacon_node_common, beacon_node_types, version],
  ../ssz/[sszdump, spec_types], ../sync/sync_manager,
  ./slashing_protection, ./attestation_aggregation,
  ./validator_pool, ./keystore_management,
  ../gossip_processing/consensus_manager

# Metrics for tracking attestation and beacon block loss
const delayBuckets = [-Inf, -4.0, -2.0, -1.0, -0.5, -0.1, -0.05,
                      0.05, 0.1, 0.5, 1.0, 2.0, 4.0, 8.0, Inf]

declareCounter beacon_attestations_sent,
  "Number of beacon chain attestations sent by this peer"
declareHistogram beacon_attestation_sent_delay,
  "Time(s) between slot start and attestation sent moment",
  buckets = delayBuckets
declareCounter beacon_blocks_proposed,
  "Number of beacon chain blocks sent by this peer"

declareGauge(attached_validator_balance,
  "Validator balance at slot end of the first 64 validators, in Gwei",
  labels = ["pubkey"])
declarePublicGauge(attached_validator_balance_total,
  "Validator balance of all attached validators, in Gwei")

logScope: topics = "beacval"

proc findValidator(validators: auto, pubKey: ValidatorPubKey):
    Option[ValidatorIndex] =
  let idx = validators.findIt(it.pubKey == pubKey)
  if idx == -1:
    # We allow adding a validator even if its key is not in the state registry:
    # it might be that the deposit for this validator has not yet been processed
    notice "Validator deposit not yet processed, monitoring", pubKey
    none(ValidatorIndex)
  else:
    some(idx.ValidatorIndex)

proc addLocalValidator(node: BeaconNode,
                       validators: openArray[Validator],
                       privKey: ValidatorPrivKey) =
  let pubKey = privKey.toPubKey()
  node.attachedValidators[].addLocalValidator(
    pubKey, privKey,
    findValidator(validators, pubKey.toPubKey()))

proc addLocalValidators*(node: BeaconNode) =
  for validatorKey in node.config.validatorKeys:
    node.addLocalValidator(
      getStateField(node.dag.headState.data, validators).asSeq, validatorKey)

proc addRemoteValidators*(node: BeaconNode) {.raises: [Defect, OSError, IOError].} =
  # load all the validators from the child process - loop until `end`
  var line = newStringOfCap(120).TaintedString
  while line != "end" and running(node.vcProcess):
    if node.vcProcess.outputStream.readLine(line) and line != "end":
      let
        key = ValidatorPubKey.fromHex(line).get()
        index = findValidator(
          getStateField(node.dag.headState.data, validators).asSeq, key)
        pk = key.load()
      if pk.isSome():
        let v = AttachedValidator(pubKey: pk.get(),
                                  index: index,
                                  kind: ValidatorKind.remote,
                                  connection: ValidatorConnection(
                                    inStream: node.vcProcess.inputStream,
                                    outStream: node.vcProcess.outputStream,
                                    pubKeyStr: $key))
        node.attachedValidators[].addRemoteValidator(pk.get(), v)
      else:
        warn "Could not load public key", line

proc getAttachedValidator*(node: BeaconNode,
                           pubkey: ValidatorPubKey): AttachedValidator =
  node.attachedValidators[].getValidator(pubkey)

proc getAttachedValidator*(node: BeaconNode,
                           state_validators: auto,
                           idx: ValidatorIndex): AttachedValidator =
  if idx < state_validators.len.ValidatorIndex:
    let validator = node.getAttachedValidator(state_validators[idx].pubkey)
    if validator != nil and validator.index != some(idx.ValidatorIndex):
      # Update index, in case the validator was activated!
      notice "Validator activated", pubkey = validator.pubkey, index = idx
      validator.index  = some(idx.ValidatorIndex)
    validator
  else:
    warn "Validator index out of bounds",
      idx, validators = state_validators.len
    nil

proc getAttachedValidator*(node: BeaconNode,
                           epochRef: EpochRef,
                           idx: ValidatorIndex): AttachedValidator =
  let key = epochRef.validatorKey(idx)
  if key.isSome():
    let validator = node.getAttachedValidator(key.get().toPubKey())
    if validator != nil and validator.index != some(idx.ValidatorIndex):
      # Update index, in case the validator was activated!
      notice "Validator activated", pubkey = validator.pubkey, index = idx
      validator.index  = some(idx.ValidatorIndex)
    validator
  else:
    warn "Validator key not found",
      idx, epoch = epochRef.epoch
    nil

proc isSynced*(node: BeaconNode, head: BlockRef): bool =
  ## TODO This function is here as a placeholder for some better heurestics to
  ##      determine if we're in sync and should be producing blocks and
  ##      attestations. Generally, the problem is that slot time keeps advancing
  ##      even when there are no blocks being produced, so there's no way to
  ##      distinguish validators geniunely going missing from the node not being
  ##      well connected (during a network split or an internet outage for
  ##      example). It would generally be correct to simply keep running as if
  ##      we were the only legit node left alive, but then we run into issues:
  ##      with enough many empty slots, the validator pool is emptied leading
  ##      to empty committees and lots of empty slot processing that will be
  ##      thrown away as soon as we're synced again.

  let
    # The slot we should be at, according to the clock
    beaconTime = node.beaconClock.now()
    wallSlot = beaconTime.toSlot()

  # TODO: MaxEmptySlotCount should likely involve the weak subjectivity period.

  # TODO if everyone follows this logic, the network will not recover from a
  #      halt: nobody will be producing blocks because everone expects someone
  #      else to do it
  if wallSlot.afterGenesis and head.slot + MaxEmptySlotCount < wallSlot.slot:
    false
  else:
    true

proc sendAttestation*(
    node: BeaconNode, attestation: Attestation,
    subnet_id: SubnetId, checkSignature: bool): Future[bool] {.async.} =
  # Validate attestation before sending it via gossip - validation will also
  # register the attestation with the attestation pool. Notably, although
  # libp2p calls the data handler for any subscription on the subnet
  # topic, it does not perform validation.
  let ok = await node.processor.attestationValidator(
    attestation, subnet_id, checkSignature)

  return case ok
    of ValidationResult.Accept:
      node.network.broadcast(
        getAttestationTopic(node.forkDigest, subnet_id), attestation)
      beacon_attestations_sent.inc()
      true
    else:
      notice "Produced attestation failed validation",
        attestation = shortLog(attestation),
        result = $ok
      false

proc sendVoluntaryExit*(node: BeaconNode, exit: SignedVoluntaryExit) =
  node.network.broadcast(getVoluntaryExitsTopic(node.forkDigest), exit)

proc sendAttesterSlashing*(node: BeaconNode, slashing: AttesterSlashing) =
  node.network.broadcast(getAttesterSlashingsTopic(node.forkDigest),
                         slashing)

proc sendProposerSlashing*(node: BeaconNode, slashing: ProposerSlashing) =
  node.network.broadcast(getProposerSlashingsTopic(node.forkDigest),
                         slashing)

proc sendAttestation*(node: BeaconNode, attestation: Attestation): Future[bool] =
  # For the validator API, which doesn't supply the subnet id.
  let attestationBlck =
    node.dag.getRef(attestation.data.beacon_block_root)
  if attestationBlck.isNil:
    debug "Attempt to send attestation without corresponding block"
    return
  let
    epochRef = node.dag.getEpochRef(
      attestationBlck, attestation.data.target.epoch)
    subnet_id = compute_subnet_for_attestation(
      get_committee_count_per_slot(epochRef), attestation.data.slot,
      attestation.data.index.CommitteeIndex)

  node.sendAttestation(attestation, subnet_id, checkSignature = true)

proc createAndSendAttestation(node: BeaconNode,
                              fork: Fork,
                              genesis_validators_root: Eth2Digest,
                              validator: AttachedValidator,
                              attestationData: AttestationData,
                              committeeLen: int,
                              indexInCommittee: int,
                              subnet_id: SubnetId) {.async.} =
  try:
    var
      attestation = await validator.produceAndSignAttestation(
        attestationData, committeeLen, indexInCommittee, fork,
        genesis_validators_root)

    let ok = await node.sendAttestation(
      attestation, subnet_id, checkSignature = false)
    if not ok: # Logged in sendAttestation
      return

    if node.config.dumpEnabled:
      dump(node.config.dumpDirOutgoing, attestation.data, validator.pubKey.toPubKey())

    let wallTime = node.beaconClock.now()
    let deadline = attestationData.slot.toBeaconTime() +
                  seconds(int(SECONDS_PER_SLOT div 3))

    let (delayStr, delaySecs) =
      if wallTime < deadline:
        ("-" & $(deadline - wallTime), -toFloatSeconds(deadline - wallTime))
      else:
        ($(wallTime - deadline), toFloatSeconds(wallTime - deadline))

    notice "Attestation sent", attestation = shortLog(attestation),
                              validator = shortLog(validator), delay = delayStr,
                              indexInCommittee = indexInCommittee

    beacon_attestation_sent_delay.observe(delaySecs)
  except CatchableError as exc:
    # An error could happen here when the signature task fails - we must
    # not leak the exception because this is an asyncSpawn task
    notice "Error sending attestation", err = exc.msg

proc getBlockProposalEth1Data*(node: BeaconNode,
                               state: ForkedHashedBeaconState):
                               BlockProposalEth1Data =
  if node.eth1Monitor.isNil:
    var pendingDepositsCount =
      getStateField(state, eth1_data).deposit_count -
        getStateField(state, eth1_deposit_index)
    if pendingDepositsCount > 0:
      result.hasMissingDeposits = true
    else:
      result.vote = getStateField(state, eth1_data)
  else:
    let finalizedEpochRef = node.dag.getFinalizedEpochRef()
    result = node.eth1Monitor.getBlockProposalData(
      state, finalizedEpochRef.eth1_data,
      finalizedEpochRef.eth1_deposit_index)

func getOpaqueTransaction(s: string): OpaqueTransaction =
  try:
    # Effectively an internal logic error in the Eth1/Eth2 client system, as
    # it's not possible to just omit a malformatted transaction: it would be
    # the wrong ExecutionPayload blockHash overall, and rejected by newBlock
    # when one attempted to reinsert it into Geth (which, while not all Eth2
    # clients might connect to, some will). It's also not possible to skip a
    # whole ExecutionPayload being that it's an integral part of BeaconBlock
    # construction. So not much better to do than bail if an incoming string
    # representation of the OpaqueTransaction is invalid. init() could catch
    # this, but it'd make its interface clumsier in a way it doesn't .add().
    let opaqueTransactionSeq = hexToSeqByte(s)
    if opaqueTransactionSeq.len > MAX_BYTES_PER_OPAQUE_TRANSACTION:
      raiseAssert "Execution engine returned too-long opaque transaction"
    OpaqueTransaction(List[byte, MAX_BYTES_PER_OPAQUE_TRANSACTION].init(
      opaqueTransactionSeq))
  except ValueError:
    raiseAssert "Execution engine returned invalidly formatted transaction"

proc makeBeaconBlockForHeadAndSlot*(node: BeaconNode,
                                    randao_reveal: ValidatorSig,
                                    validator_index: ValidatorIndex,
                                    graffiti: GraffitiBytes,
                                    head: BlockRef,
                                    slot: Slot): Future[Option[BeaconBlock]] {.async.} =
  # Advance state to the slot that we're proposing for

  let
    proposalState = assignClone(node.dag.headState)
    proposalStateAddr = unsafeAddr proposalState[]

  node.dag.withState(proposalState[], head.atSlot(slot)):
    let
      eth1Proposal = node.getBlockProposalEth1Data(stateData.data)
      poolPtr = unsafeAddr node.dag # safe because restore is short-lived

    if eth1Proposal.hasMissingDeposits:
      error "Eth1 deposits not available. Skipping block proposal", slot
      return none(BeaconBlock)

    func restore(v: var HashedBeaconState) =
      # TODO address this ugly workaround - there should probably be a
      #      `state_transition` that takes a `StateData` instead and updates
      #      the block as well
      doAssert v.addr == addr proposalStateAddr.data
      assign(proposalStateAddr[], poolPtr.headState)

    return makeBeaconBlock(
      node.runtimePreset,
      stateData.data.hbsPhase0,
      validator_index,
      head.root,
      randao_reveal,
      eth1Proposal.vote,
      graffiti,
      node.attestationPool[].getAttestationsForBlock(
        stateData.data.hbsPhase0, cache),
      eth1Proposal.deposits,
      node.exitPool[].getProposerSlashingsForBlock(),
      node.exitPool[].getAttesterSlashingsForBlock(),
      node.exitPool[].getVoluntaryExitsForBlock(),
      default(ExecutionPayload),
      restore,
      cache)

proc proposeSignedBlock*(node: BeaconNode,
                         head: BlockRef,
                         validator: AttachedValidator,
                         newBlock: SignedBeaconBlock): BlockRef =
  let newBlockRef = node.dag.addRawBlock(node.quarantine, newBlock) do (
      blckRef: BlockRef, trustedBlock: TrustedSignedBeaconBlock,
      epochRef: EpochRef, state: HashedBeaconState):
    # Callback add to fork choice if signed block valid (and becomes trusted)
    node.attestationPool[].addForkChoice(
      epochRef, blckRef, trustedBlock.message,
      node.beaconClock.now().slotOrZero())

  if newBlockRef.isErr:
    warn "Unable to add proposed block to block pool",
      newBlock = shortLog(newBlock.message),
      blockRoot = shortLog(newBlock.root)

    return head

  notice "Block proposed",
    blck = shortLog(newBlock.message),
    blockRoot = shortLog(newBlockRef[].root),
    validator = shortLog(validator)

  if node.config.dumpEnabled:
    dump(node.config.dumpDirOutgoing, newBlock)

  node.network.broadcast(node.topicBeaconBlocks, newBlock)

  beacon_blocks_proposed.inc()

  return newBlockRef[]

proc proposeBlock(node: BeaconNode,
                  validator: AttachedValidator,
                  validator_index: ValidatorIndex,
                  head: BlockRef,
                  slot: Slot): Future[BlockRef] {.async.} =
  if head.slot >= slot:
    # We should normally not have a head newer than the slot we're proposing for
    # but this can happen if block proposal is delayed
    warn "Skipping proposal, have newer head already",
      headSlot = shortLog(head.slot),
      headBlockRoot = shortLog(head.root),
      slot = shortLog(slot)
    return head

  let
    fork = getStateField(node.dag.headState.data, fork)
    genesis_validators_root =
      getStateField(node.dag.headState.data, genesis_validators_root)
    randao = await validator.genRandaoReveal(
      fork, genesis_validators_root, slot)
    message = await makeBeaconBlockForHeadAndSlot(
      node, randao, validator_index, node.graffitiBytes, head, slot)

  if not message.isSome():
    return head # already logged elsewhere!

  var
    newBlock = SignedBeaconBlock(
      message: message.get()
    )

  newBlock.root = hash_tree_root(newBlock.message)

  # TODO: recomputed in block proposal
  let signing_root = compute_block_root(
    fork, genesis_validators_root, slot, newBlock.root)
  let notSlashable = node.attachedValidators
    .slashingProtection
    .registerBlock(validator_index, validator.pubkey.toPubKey(), slot, signing_root)

  if notSlashable.isErr:
    warn "Slashing protection activated",
      validator = validator.pubkey,
      slot = slot,
      existingProposal = notSlashable.error
    return head

  newBlock.signature = await validator.signBlockProposal(
    fork, genesis_validators_root, slot, newBlock.root)

  return node.proposeSignedBlock(head, validator, newBlock)

proc handleAttestations(node: BeaconNode, head: BlockRef, slot: Slot) =
  ## Perform all attestations that the validators attached to this node should
  ## perform during the given slot
  if slot + SLOTS_PER_EPOCH < head.slot:
    # The latest block we know about is a lot newer than the slot we're being
    # asked to attest to - this makes it unlikely that it will be included
    # at all.
    # TODO the oldest attestations allowed are those that are older than the
    #      finalized epoch.. also, it seems that posting very old attestations
    #      is risky from a slashing perspective. More work is needed here.
    warn "Skipping attestation, head is too recent",
      headSlot = shortLog(head.slot),
      slot = shortLog(slot)
    return

  let attestationHead = head.atSlot(slot)
  if head != attestationHead.blck:
    # In rare cases, such as when we're busy syncing or just slow, we'll be
    # attesting to a past state - we must then recreate the world as it looked
    # like back then
    notice "Attesting to a state in the past, falling behind?",
      headSlot = shortLog(head.slot),
      attestationHeadSlot = shortLog(attestationHead.slot),
      attestationSlot = shortLog(slot)

  trace "Checking attestations",
    attestationHeadRoot = shortLog(attestationHead.blck.root),
    attestationSlot = shortLog(slot)

  # We need to run attestations exactly for the slot that we're attesting to.
  # In case blocks went missing, this means advancing past the latest block
  # using empty slots as fillers.
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#validator-assignments
  let
    epochRef = node.dag.getEpochRef(
      attestationHead.blck, slot.compute_epoch_at_slot())
    committees_per_slot = get_committee_count_per_slot(epochRef)
    fork = getStateField(node.dag.headState.data, fork)
    genesis_validators_root =
      getStateField(node.dag.headState.data, genesis_validators_root)

  for committee_index in get_committee_indices(epochRef):
    let committee = get_beacon_committee(epochRef, slot, committee_index)

    for index_in_committee, validator_index in committee:
      let validator = node.getAttachedValidator(epochRef, validator_index)
      if validator == nil:
        continue

      let
        data = makeAttestationData(epochRef, attestationHead, committee_index)
        # TODO signing_root is recomputed in produceAndSignAttestation/signAttestation just after
        signing_root = compute_attestation_root(
          fork, genesis_validators_root, data)
        registered = node.attachedValidators
          .slashingProtection
          .registerAttestation(
            validator_index,
            validator.pubkey.toPubKey(),
            data.source.epoch,
            data.target.epoch,
            signing_root)
      if registered.isOk():
        let subnet_id = compute_subnet_for_attestation(
          committees_per_slot, data.slot, data.index.CommitteeIndex)
        asyncSpawn createAndSendAttestation(
          node, fork, genesis_validators_root, validator, data,
          committee.len(), index_in_committee, subnet_id)
      else:
        warn "Slashing protection activated for attestation",
          validator = validator.pubkey,
          badVoteDetails = $registered.error()

proc handleProposal(node: BeaconNode, head: BlockRef, slot: Slot):
    Future[BlockRef] {.async.} =
  ## Perform the proposal for the given slot, iff we have a validator attached
  ## that is supposed to do so, given the shuffling at that slot for the given
  ## head - to compute the proposer, we need to advance a state to the given
  ## slot
  let proposer = node.dag.getProposer(head, slot)
  if proposer.isNone():
    return head

  let
    proposerKey = node.dag.validatorKey(proposer.get()).get().toPubKey()
    validator = node.attachedValidators[].getValidator(proposerKey)

  if validator != nil:
    return await proposeBlock(node, validator, proposer.get(), head, slot)

  debug "Expecting block proposal",
    headRoot = shortLog(head.root),
    slot = shortLog(slot),
    proposer_index = proposer.get(),
    proposer = shortLog(proposerKey)

  return head

proc broadcastAggregatedAttestations(
    node: BeaconNode, aggregationHead: BlockRef, aggregationSlot: Slot) {.async.} =
  # The index is via a
  # locally attested validator. Unlike in handleAttestations(...) there's a
  # single one at most per slot (because that's how aggregation attestation
  # works), so the machinery that has to handle looping across, basically a
  # set of locally attached validators is in principle not necessary, but a
  # way to organize this. Then the private key for that validator should be
  # the corresponding one -- whatver they are, they match.

  let
    epochRef = node.dag.getEpochRef(aggregationHead, aggregationSlot.epoch)
    fork = getStateField(node.dag.headState.data, fork)
    genesis_validators_root =
      getStateField(node.dag.headState.data, genesis_validators_root)
    committees_per_slot = get_committee_count_per_slot(epochRef)

  var
    slotSigs: seq[Future[ValidatorSig]] = @[]
    slotSigsData: seq[tuple[committee_index: uint64,
                            validator_idx: ValidatorIndex,
                            v: AttachedValidator]] = @[]

  for committee_index in 0'u64..<committees_per_slot:
    let committee = get_beacon_committee(
      epochRef, aggregationSlot, committee_index.CommitteeIndex)

    for index_in_committee, validatorIdx in committee:
      let validator = node.getAttachedValidator(epochRef, validatorIdx)
      if validator != nil:
        # the validator index and private key pair.
        slotSigs.add getSlotSig(validator, fork,
          genesis_validators_root, aggregationSlot)
        slotSigsData.add (committee_index, validatorIdx, validator)

  await allFutures(slotSigs)

  for curr in zip(slotSigsData, slotSigs):
    let aggregateAndProof =
      aggregate_attestations(node.attestationPool[], epochRef, aggregationSlot,
                             curr[0].committee_index.CommitteeIndex,
                             curr[0].validator_idx,
                             curr[1].read)

    # Don't broadcast when, e.g., this node isn't aggregator
    if aggregateAndProof.isSome:
      let sig = await signAggregateAndProof(curr[0].v,
        aggregateAndProof.get, fork, genesis_validators_root)
      var signedAP = SignedAggregateAndProof(
        message: aggregateAndProof.get,
        signature: sig)
      node.network.broadcast(node.topicAggregateAndProofs, signedAP)
      notice "Aggregated attestation sent",
        attestation = shortLog(signedAP.message.aggregate),
        validator = shortLog(curr[0].v),
        aggregationSlot

proc updateValidatorMetrics*(node: BeaconNode) =
  when defined(metrics):
    # Technically, this only needs to be done on epoch transitions and if there's
    # a reorg that spans an epoch transition, but it's easier to implement this
    # way for now..

    # We'll limit labelled metrics to the first 64, so that we don't overload
    # prom

    var total: Gwei
    var i = 0
    for _, v in node.attachedValidators[].validators:
      let balance =
        if v.index.isNone():
          0.Gwei
        elif v.index.get().uint64 >=
            getStateField(node.dag.headState.data, balances).lenu64:
          debug "Cannot get validator balance, index out of bounds",
            pubkey = shortLog(v.pubkey), index = v.index.get(),
            balances = getStateField(node.dag.headState.data, balances).len,
            stateRoot = getStateRoot(node.dag.headState.data)
          0.Gwei
        else:
          getStateField(node.dag.headState.data, balances)[v.index.get()]

      if i < 64:
        attached_validator_balance.set(
          balance.toGaugeValue, labelValues = [shortLog(v.pubkey)])
      else:
        inc i
      total += balance

    node.attachedValidatorBalanceTotal = total
    attached_validator_balance_total.set(total.toGaugeValue)
  else:
    discard

proc handleValidatorDuties*(node: BeaconNode, lastSlot, slot: Slot) {.async.} =
  ## Perform validator duties - create blocks, vote and aggregate existing votes
  if node.attachedValidators[].count == 0:
    # Nothing to do because we have no validator attached
    return

  # The dag head might be updated by sync while we're working due to the
  # await calls, thus we use a local variable to keep the logic straight here
  var head = node.dag.head
  if not node.isSynced(head):
    notice "Syncing in progress; skipping validator duties for now",
      slot, headSlot = head.slot

    # Rewards will be growing though, as we sync..
    updateValidatorMetrics(node)

    return

  var curSlot = lastSlot + 1

  # If broadcastStartEpoch is 0, it hasn't had time to initialize yet, which
  # means that it'd be okay not to continue, but it won't gossip regardless.
  if  curSlot.epoch <
        node.processor[].doppelgangerDetection.broadcastStartEpoch and
      node.config.doppelgangerDetection:
    debug "Waiting to gossip out to detect potential duplicate validators",
      broadcastStartEpoch =
        node.processor[].doppelgangerDetection.broadcastStartEpoch
    return

  # Start by checking if there's work we should have done in the past that we
  # can still meaningfully do
  while curSlot < slot:
    notice "Catching up on validator duties",
      curSlot = shortLog(curSlot),
      lastSlot = shortLog(lastSlot),
      slot = shortLog(slot)

    # For every slot we're catching up, we'll propose then send
    # attestations - head should normally be advancing along the same branch
    # in this case
    head = await handleProposal(node, head, curSlot)

    # For each slot we missed, we need to send out attestations - if we were
    # proposing during this time, we'll use the newly proposed head, else just
    # keep reusing the same - the attestation that goes out will actually
    # rewind the state to what it looked like at the time of that slot
    handleAttestations(node, head, curSlot)

    curSlot += 1

  head = await handleProposal(node, head, slot)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#attesting
  # Milliseconds to wait from the start of the slot before sending out
  # attestations
  const attestationOffset = SECONDS_PER_SLOT.int64 * 1000 div 3

  let
    # The latest point in time when we'll be sending out attestations
    attestationCutoffTime = slot.toBeaconTime(millis(attestationOffset))
    attestationCutoff = node.beaconClock.fromNow(attestationCutoffTime)

  if attestationCutoff.inFuture:
    debug "Waiting to send attestations",
      head = shortLog(head),
      attestationCutoff = shortLog(attestationCutoff.offset)

    # Wait either for the block or the attestation cutoff time to arrive
    if await node.consensusManager[].expectBlock(slot).withTimeout(attestationCutoff.offset):
      # The expected block arrived (or expectBlock was called again which
      # shouldn't happen as this is the only place we use it) - in our async
      # loop however, we might have been doing other processing that caused delays
      # here so we'll cap the waiting to the time when we would have sent out
      # attestations had the block not arrived.
      # An opposite case is that we received (or produced) a block that has
      # not yet reached our neighbours. To protect against our attestations
      # being dropped (because the others have not yet seen the block), we'll
      # impose a minimum delay of 250ms. The delay is enforced only when we're
      # not hitting the "normal" cutoff time for sending out attestations.

      const afterBlockDelay = 250
      let
        afterBlockTime = node.beaconClock.now() + millis(afterBlockDelay)
        afterBlockCutoff = node.beaconClock.fromNow(
          min(afterBlockTime, attestationCutoffTime))

      if afterBlockCutoff.inFuture:
        debug "Got block, waiting to send attestations",
          head = shortLog(head),
          afterBlockCutoff = shortLog(afterBlockCutoff.offset)

        await sleepAsync(afterBlockCutoff.offset)

    # Time passed - we might need to select a new head in that case
    node.consensusManager[].updateHead(slot)
    head = node.dag.head

  handleAttestations(node, head, slot)

  updateValidatorMetrics(node) # the important stuff is done, update the vanity numbers

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#broadcast-aggregate
  # If the validator is selected to aggregate (is_aggregator), then they
  # broadcast their best aggregate as a SignedAggregateAndProof to the global
  # aggregate channel (beacon_aggregate_and_proof) two-thirds of the way
  # through the slot-that is, SECONDS_PER_SLOT * 2 / 3 seconds after the start
  # of slot.
  if slot > 2:
    let
      aggregateWaitTime = node.beaconClock.fromNow(
        slot.toBeaconTime(seconds(int64(SECONDS_PER_SLOT * 2) div 3)))
    if aggregateWaitTime.inFuture:
      debug "Waiting to send aggregate attestations",
        aggregateWaitTime = shortLog(aggregateWaitTime.offset)
      await sleepAsync(aggregateWaitTime.offset)

    await broadcastAggregatedAttestations(node, head, slot)

  if node.eth1Monitor != nil and (slot mod SLOTS_PER_EPOCH) == 0:
    let finalizedEpochRef = node.dag.getFinalizedEpochRef()
    discard node.eth1Monitor.trackFinalizedState(
      finalizedEpochRef.eth1_data, finalizedEpochRef.eth1_deposit_index)
