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
  stew/[assign2, objects],
  chronos, metrics,
  chronicles,
  json_serialization/std/[options, sets, net], serialization/errors,
  eth/db/kvstore,
  eth/[keys, async_utils], eth/p2p/discoveryv5/[protocol, enr],

  # Local modules
  ../spec/[
    datatypes, digest, crypto, helpers, network, signatures, state_transition,
    validator],
  ../conf, ../beacon_clock,
  ../consensus_object_pools/[
    spec_cache, blockchain_dag, block_clearance,
    attestation_pool, exit_pool],
  ../eth1/eth1_monitor,
  ../networking/eth2_network,
  ".."/[beacon_node_common, beacon_node_types, version],
  ../ssz, ../ssz/sszdump, ../sync/sync_manager,
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

proc findValidator(state: BeaconState, pubKey: ValidatorPubKey):
    Option[ValidatorIndex] =
  let idx = state.validators.asSeq.findIt(it.pubKey == pubKey)
  if idx == -1:
    # We allow adding a validator even if its key is not in the state registry:
    # it might be that the deposit for this validator has not yet been processed
    notice "Validator deposit not yet processed, monitoring", pubKey
    none(ValidatorIndex)
  else:
    some(idx.ValidatorIndex)

proc addLocalValidator*(node: BeaconNode,
                        state: BeaconState,
                        privKey: ValidatorPrivKey) =
  let pubKey = privKey.toPubKey()
  node.attachedValidators[].addLocalValidator(
    pubKey, privKey, findValidator(state, pubKey))

proc addLocalValidators*(node: BeaconNode) =
  for validatorKey in node.config.validatorKeys:
    node.addLocalValidator node.chainDag.headState.data.data, validatorKey

proc addRemoteValidators*(node: BeaconNode) {.raises: [Defect, OSError, IOError].} =
  # load all the validators from the child process - loop until `end`
  var line = newStringOfCap(120).TaintedString
  while line != "end" and running(node.vcProcess):
    if node.vcProcess.outputStream.readLine(line) and line != "end":
      let
        key = ValidatorPubKey.fromHex(line).get()
        index = findValidator(node.chainDag.headState.data.data, key)

      let v = AttachedValidator(pubKey: key,
                                index: index,
                                kind: ValidatorKind.remote,
                                connection: ValidatorConnection(
                                  inStream: node.vcProcess.inputStream,
                                  outStream: node.vcProcess.outputStream,
                                  pubKeyStr: $key))
      node.attachedValidators[].addRemoteValidator(key, v)

proc getAttachedValidator*(node: BeaconNode,
                           pubkey: ValidatorPubKey): AttachedValidator =
  node.attachedValidators[].getValidator(pubkey)

proc getAttachedValidator*(node: BeaconNode,
                           state: BeaconState,
                           idx: ValidatorIndex): AttachedValidator =
  if idx < state.validators.len.ValidatorIndex:
    let validator = node.getAttachedValidator(state.validators[idx].pubkey)
    if validator != nil and validator.index != some(idx.ValidatorIndex):
      # Update index, in case the validator was activated!
      notice "Validator activated", pubkey = validator.pubkey, index = idx
      validator.index  = some(idx.ValidatorIndex)
    validator
  else:
    warn "Validator index out of bounds",
      idx, stateSlot = state.slot, validators = state.validators.len
    nil

proc getAttachedValidator*(node: BeaconNode,
                           epochRef: EpochRef,
                           idx: ValidatorIndex): AttachedValidator =
  if idx < epochRef.validator_keys.len.ValidatorIndex:
    let validator = node.getAttachedValidator(epochRef.validator_keys[idx])
    if validator != nil and validator.index != some(idx.ValidatorIndex):
      # Update index, in case the validator was activated!
      notice "Validator activated", pubkey = validator.pubkey, index = idx
      validator.index  = some(idx.ValidatorIndex)
    validator
  else:
    warn "Validator index out of bounds",
      idx, epoch = epochRef.epoch, validators = epochRef.validator_keys.len
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
    node: BeaconNode, attestation: Attestation, num_active_validators: uint64) =
  let subnet_index =
    compute_subnet_for_attestation(
      get_committee_count_per_slot(num_active_validators), attestation.data.slot,
      attestation.data.index.CommitteeIndex)
  node.network.broadcast(
    getAttestationTopic(node.forkDigest, subnet_index), attestation)

  # Ensure node's own broadcast attestations end up in its attestation pool
  discard node.processor[].attestationValidator(
    attestation, subnet_index, false)

  beacon_attestations_sent.inc()

proc sendVoluntaryExit*(node: BeaconNode, exit: SignedVoluntaryExit) =
  node.network.broadcast(getVoluntaryExitsTopic(node.forkDigest), exit)

proc sendAttesterSlashing*(node: BeaconNode, slashing: AttesterSlashing) =
  node.network.broadcast(getAttesterSlashingsTopic(node.forkDigest),
                         slashing)

proc sendProposerSlashing*(node: BeaconNode, slashing: ProposerSlashing) =
  node.network.broadcast(getProposerSlashingsTopic(node.forkDigest),
                         slashing)

proc sendAttestation*(node: BeaconNode, attestation: Attestation) =
  # For the validator API, which doesn't supply num_active_validators.
  let attestationBlck =
    node.chainDag.getRef(attestation.data.beacon_block_root)
  if attestationBlck.isNil:
    debug "Attempt to send attestation without corresponding block"
    return

  node.sendAttestation(
    attestation,
    count_active_validators(
      node.chainDag.getEpochRef(attestationBlck, attestation.data.target.epoch)))

proc createAndSendAttestation(node: BeaconNode,
                              fork: Fork,
                              genesis_validators_root: Eth2Digest,
                              validator: AttachedValidator,
                              attestationData: AttestationData,
                              committeeLen: int,
                              indexInCommittee: int,
                              num_active_validators: uint64) {.async.} =
  var attestation = await validator.produceAndSignAttestation(
    attestationData, committeeLen, indexInCommittee, fork,
    genesis_validators_root)

  node.sendAttestation(attestation, num_active_validators)

  if node.config.dumpEnabled:
    dump(node.config.dumpDirOutgoing, attestation.data, validator.pubKey)

  let wallTime = node.beaconClock.now()
  let deadline = attestationData.slot.toBeaconTime() +
                 seconds(int(SECONDS_PER_SLOT div 3))

  let (delayStr, delayMillis) =
    if wallTime < deadline:
      ("-" & $(deadline - wallTime), -toFloatSeconds(deadline - wallTime))
    else:
      ($(wallTime - deadline), toFloatSeconds(wallTime - deadline))

  notice "Attestation sent", attestation = shortLog(attestation),
                             validator = shortLog(validator), delay = delayStr,
                             indexInCommittee = indexInCommittee

  beacon_attestation_sent_delay.observe(delayMillis)

proc getBlockProposalEth1Data*(node: BeaconNode,
                               state: BeaconState): BlockProposalEth1Data =
  if node.eth1Monitor.isNil:
    var pendingDepositsCount = state.eth1_data.deposit_count -
                               state.eth1_deposit_index
    if pendingDepositsCount > 0:
      result.hasMissingDeposits = true
    else:
      result.vote = state.eth1_data
  else:
    let finalizedEpochRef = node.chainDag.getFinalizedEpochRef()
    result = node.eth1Monitor.getBlockProposalData(
      state, finalizedEpochRef.eth1_data, finalizedEpochRef.eth1_deposit_index)

proc makeBeaconBlockForHeadAndSlot*(node: BeaconNode,
                                    randao_reveal: ValidatorSig,
                                    validator_index: ValidatorIndex,
                                    graffiti: GraffitiBytes,
                                    head: BlockRef,
                                    slot: Slot): Option[BeaconBlock] =
  # Advance state to the slot that we're proposing for

  let
    proposalState = assignClone(node.chainDag.headState)
    proposalStateAddr = unsafeAddr proposalState[]

  node.chainDag.withState(proposalState[], head.atSlot(slot)):
    let
      eth1Proposal = node.getBlockProposalEth1Data(state)
      poolPtr = unsafeAddr node.chainDag # safe because restore is short-lived

    if eth1Proposal.hasMissingDeposits:
      error "Eth1 deposits not available. Skipping block proposal", slot
      return none(BeaconBlock)

    func restore(v: var HashedBeaconState) =
      # TODO address this ugly workaround - there should probably be a
      #      `state_transition` that takes a `StateData` instead and updates
      #      the block as well
      doAssert v.addr == addr proposalStateAddr.data
      assign(proposalStateAddr[], poolPtr.headState)

    makeBeaconBlock(
      node.runtimePreset,
      hashedState,
      validator_index,
      head.root,
      randao_reveal,
      eth1Proposal.vote,
      graffiti,
      node.attestationPool[].getAttestationsForBlock(state, cache),
      eth1Proposal.deposits,
      node.exitPool[].getProposerSlashingsForBlock(),
      node.exitPool[].getAttesterSlashingsForBlock(),
      node.exitPool[].getVoluntaryExitsForBlock(),
      restore,
      cache)

proc proposeSignedBlock*(node: BeaconNode,
                         head: BlockRef,
                         validator: AttachedValidator,
                         newBlock: SignedBeaconBlock): BlockRef =
  let newBlockRef = node.chainDag.addRawBlock(node.quarantine, newBlock) do (
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

  let notSlashable = node.attachedValidators
                        .slashingProtection
                        .checkSlashableBlockProposal(validator.pubkey, slot)
  if notSlashable.isErr:
    warn "Slashing protection activated",
      validator = validator.pubkey,
      slot = slot,
      existingProposal = notSlashable.error
    return head

  let
    fork = node.chainDag.headState.data.data.fork
    genesis_validators_root =
      node.chainDag.headState.data.data.genesis_validators_root
  let
    randao = await validator.genRandaoReveal(
      fork, genesis_validators_root, slot)
    message = makeBeaconBlockForHeadAndSlot(
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
  node.attachedValidators
    .slashingProtection
    .registerBlock(validator.pubkey, slot, signing_root)

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

  var attestations: seq[tuple[
    data: AttestationData, committeeLen, indexInCommittee: int,
    validator: AttachedValidator]]

  # We need to run attestations exactly for the slot that we're attesting to.
  # In case blocks went missing, this means advancing past the latest block
  # using empty slots as fillers.
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#validator-assignments
  let
    epochRef = node.chainDag.getEpochRef(
      attestationHead.blck, slot.compute_epoch_at_slot())
    committees_per_slot =
      get_committee_count_per_slot(epochRef)
    num_active_validators = count_active_validators(epochRef)
    fork = node.chainDag.headState.data.data.fork
    genesis_validators_root =
      node.chainDag.headState.data.data.genesis_validators_root

  for committee_index in 0'u64..<committees_per_slot:
    let committee = get_beacon_committee(
      epochRef, slot, committee_index.CommitteeIndex)

    for index_in_committee, validatorIdx in committee:
      let validator = node.getAttachedValidator(epochRef, validatorIdx)
      if validator != nil:
        let ad = makeAttestationData(
          epochRef, attestationHead, committee_index.CommitteeIndex)
        attestations.add((ad, committee.len, index_in_committee, validator))

  for a in attestations:
    let notSlashable = node.attachedValidators
                           .slashingProtection
                           .checkSlashableAttestation(
                             a.validator.pubkey,
                             a.data.source.epoch,
                             a.data.target.epoch)

    if notSlashable.isOk():
      # TODO signing_root is recomputed in produceAndSignAttestation/signAttestation just after
      let signing_root = compute_attestation_root(
            fork, genesis_validators_root, a.data)
      node.attachedValidators
          .slashingProtection
          .registerAttestation(
            a.validator.pubkey,
            a.data.source.epoch,
            a.data.target.epoch,
            signing_root
          )

      traceAsyncErrors createAndSendAttestation(
        node, fork, genesis_validators_root, a.validator, a.data,
        a.committeeLen, a.indexInCommittee, num_active_validators)
      node.processor.trackedAttestations.add((a.validator.pubkey, slot))
    else:
      warn "Slashing protection activated for attestation",
        validator = a.validator.pubkey,
        badVoteDetails = $notSlashable.error

proc handleProposal(node: BeaconNode, head: BlockRef, slot: Slot):
    Future[BlockRef] {.async.} =
  ## Perform the proposal for the given slot, iff we have a validator attached
  ## that is supposed to do so, given the shuffling at that slot for the given
  ## head - to compute the proposer, we need to advance a state to the given
  ## slot

  let proposer = node.chainDag.getProposer(head, slot)
  if proposer.isNone():
    return head

  let validator =
    node.attachedValidators[].getValidator(proposer.get()[1])

  if validator != nil:
    return await proposeBlock(node, validator, proposer.get()[0], head, slot)

  debug "Expecting block proposal",
    headRoot = shortLog(head.root),
    slot = shortLog(slot),
    proposer_index = proposer.get()[0],
    proposer = shortLog(proposer.get()[1])

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
    epochRef = node.chainDag.getEpochRef(aggregationHead, aggregationSlot.epoch)
    fork = node.chainDag.headState.data.data.fork
    genesis_validators_root =
      node.chainDag.headState.data.data.genesis_validators_root
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

    template state: untyped = node.chainDag.headState.data.data

    var total: Gwei
    var i = 0
    for _, v in node.attachedValidators[].validators:
      let balance =
        if v.index.isNone():
          0.Gwei
        elif v.index.get().uint64 >= state.balances.lenu64:
          debug "Cannot get validator balance, index out of bounds",
            pubkey = shortLog(v.pubkey), index = v.index.get(),
            balances = state.balances.len,
            stateRoot = node.chainDag.headState.data.root
          0.Gwei
        else:
          state.balances[v.index.get()]

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

  # The chainDag head might be updated by sync while we're working due to the
  # await calls, thus we use a local variable to keep the logic straight here
  var head = node.chainDag.head
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
    head = node.chainDag.head

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
    let finalizedEpochRef = node.chainDag.getFinalizedEpochRef()
    discard node.eth1Monitor.trackFinalizedState(
      finalizedEpochRef.eth1_data, finalizedEpochRef.eth1_deposit_index)
