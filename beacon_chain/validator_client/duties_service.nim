import std/[sets, sequtils]
import chronicles
import common, api

logScope: service = "duties_service"

type
  DutiesServiceLoop* = enum
    AttesterLoop, ProposerLoop, IndicesLoop

chronicles.formatIt(DutiesServiceLoop):
  case it
  of AttesterLoop: "attester_loop"
  of ProposerLoop: "proposer_loop"
  of IndicesLoop: "index_loop"

proc checkDuty(duty: RestAttesterDuty): bool =
  (duty.committee_length <= MAX_VALIDATORS_PER_COMMITTEE) and
  (uint64(duty.committee_index) <= MAX_COMMITTEES_PER_SLOT) and
  (uint64(duty.validator_committee_index) <= duty.committee_length) and
  (uint64(duty.validator_index) <= VALIDATOR_REGISTRY_LIMIT)

proc pollForValidatorIndices*(vc: ValidatorClientRef) {.async.} =
  let stateIdent = StateIdent.init(StateIdentType.Head)
  let validatorIdents =
    block:
      var res: seq[ValidatorIdent]
      for validator in vc.attachedValidators.items():
        if validator.index.isNone():
          res.add(ValidatorIdent.init(validator.pubkey))
      res

  var validators: seq[RestValidator]
  var offset = 0

  while offset < len(validatorIdents):
    let arraySize = min(MaximumValidatorIds, len(validatorIdents))

    let idents =
      block:
        var res = newSeq[ValidatorIdent](arraySize)
        var k = 0
        for i in offset ..< arraySize:
          res[k] = validatorIdents[i]
          inc(k)
        res

    let res = await vc.getValidators(idents)
    for item in res:
      validators.add(item)

    offset += arraySize

  for item in validators:
    if item.validator.pubkey notin vc.attachedValidators:
      warn "Beacon node returned missing validator",
           pubKey = item.validator.pubKey, index = item.index
    else:
      debug "Local validator updated with index",
            pubKey = item.validator.pubkey, index = item.index
      vc.attachedValidators.updateValidator(item.validator.pubkey,
                                            item.index)

proc pollForAttesterDuties*(vc: ValidatorClientRef, epoch: Epoch) {.async.} =
  let validatorIndices =
    block:
      var res: seq[ValidatorIndex]
      for index in vc.attachedValidators.indices():
        res.add(index)
      res

  var duties: seq[RestAttesterDuty]
  var currentRoot: Option[Eth2Digest]

  var offset = 0
  while offset < len(validatorIndices):
    let arraySize = min(MaximumValidatorIds, len(validatorIndices))
    let indices =
      block:
        var res = newSeq[ValidatorIndex](arraySize)
        var k = 0
        for i in offset ..< arraySize:
          res[k] = validatorIndices[i]
          inc(k)
        res

    let res = await vc.getAttesterDuties(epoch, indices)

    if currentRoot.isNone():
      # First request
      currentRoot = some(res.dependent_root)
    else:
      if currentRoot.get() != res.dependent_root:
        # `dependent_root` must be equal for all requests/response, if it got
        # changed it means that some reorg was happened in beacon node and we
        # should re-request all queries again.
        offset = 0
        continue

    for item in res.data:
      duties.add(item)

    offset += arraySize

  let relevantDuties = duties.filterIt(
    checkDuty(it) and (it.pubkey in vc.attachedValidators)
  )
  let dependentRoot = currentRoot.get()
  var alreadyWarned = false

  for duty in relevantDuties:
    let dutyAndProof = DutyAndProof.init(epoch, dependentRoot, duty)
    var map = vc.attesters.getOrDefault(duty.pubkey)
    let epochDuty = map.getOrDefault(epoch, DefaultDutyAndProof)
    if not(epochDuty.isDefault()):
      if epochDuty.dependentRoot != dependentRoot:
        if not(alreadyWarned):
          warn "Attester duties re-organization",
               prior_dependent_root = epochDuty.dependentRoot,
               dependent_root = dependentRoot
          alreadyWarned = true
    else:
      info "Received new attester duty", duty, epoch = epoch,
                                         dependent_root = dependentRoot
    map[epoch] = dutyAndProof
    vc.attesters[duty.pubkey] = map

proc pruneAttesterDuties*(vc: ValidatorClientRef, epoch: Epoch) =
  var attesters: AttesterMap
  for key, item in vc.attesters.pairs():
    var v: Table[Epoch, DutyAndProof]
    for epochKey, duty in item.pairs():
      if (epochKey + HISTORICAL_DUTIES_EPOCHS) >= epoch:
        v[epochKey] = duty
      else:
        debug "Attester duty has been pruned", validator = key,
              epoch = epochKey, loop = AttesterLoop
    attesters[key] = v
  vc.attesters = attesters

proc pollForAttesterDuties*(vc: ValidatorClientRef) {.async.} =
  ## Query the beacon node for attestation duties for all known validators.
  ##
  ## This function will perform (in the following order):
  ##
  ## 1. Poll for current-epoch duties and update the local `attesters` map.
  ## 2. Poll for next-epoch duties and update the local `attesters` map.
  ## 3. Push out any attestation subnet subscriptions to the BN.
  let sres = vc.getCurrentSlot()
  if sres.isSome():
    let
      currentSlot = sres.get()
      currentEpoch = currentSlot.epoch()
      nextEpoch = currentEpoch + 1'u64

    if vc.attachedValidators.count() != 0:
      await vc.pollForAttesterDuties(currentEpoch)
      await vc.pollForAttesterDuties(nextEpoch)

proc getBlockProposers*(vc: ValidatorClientRef,
                        slot: Slot): HashSet[ValidatorPubKey] =
  ## Creates HashSet of local validator's public keys which must propose the
  ## block at specific slot ``slot``.
  var hashset = initHashSet[ValidatorPubKey]()
  let data = vc.proposers.getOrDefault(slot.epoch())
  if not(data.isDefault()):
    for item in data.duties:
      if (item.slot == slot) and (item.pubkey in vc.attachedValidators) and
         (item.pubkey notin hashset):
        hashset.incl(item.pubkey)
  hashset

proc toList*(s: HashSet[ValidatorPubKey]): seq[ValidatorPubKey] =
  var res = newSeqOfCap[ValidatorPubKey](len(s))
  for item in s.items():
    res.add(item)
  res

proc notifyBlockProductionService*(vc: ValidatorClientRef, slot: Slot,
                                   keys: seq[ValidatorPubKey]) {.async.} =
  let event = BlockServiceEventRef(slot: slot, proposers: keys)
  await vc.blocksQueue.addLast(event)

proc pruneBeaconProposers*(vc: ValidatorClientRef, epoch: Epoch) =
  var proposers: ProposerMap
  for epochKey, data in vc.proposers.pairs():
    if (epochKey + HISTORICAL_DUTIES_EPOCHS) >= epoch:
      proposers[epochKey] = data
    else:
      debug "Proposer duty has been pruned", epoch = epochKey,
            loop = ProposerLoop
  vc.proposers = proposers

proc pollForBeaconProposers*(vc: ValidatorClientRef) {.async.} =
  ## Poll for the proposer duties for the current epoch and store them in
  ## `DutiesServiceRef.proposers`.
  ## If there are any proposer for this slot, send out a notification to the
  ## `BlockServiceRef`.
  ##
  ## Note
  ##
  ## This function will potentially send *two* notifications to the
  ## `BlockServiceRef`; it will send a notification initially, then it will
  ## query beacon node for the latest duties and send a *second* notification
  ## if those duties have changed. This behaviour simultaneously achieves the
  ## following:
  ##
  ## 1. Block production can happen immediately and does not have to wait for
  ##    the proposer duties to download.
  ## 2. We won't miss a block if the duties for the current slot happen to
  ##    change with this poll.
  ##
  ## This sounds great, but is it safe? Firstly, the additional notification
  ## will only contain block producers that were not included in the first
  ## notification. This should be safety enough. However, we also have the
  ## slashing protection as a second line of defence. These two factors
  ## provide an acceptable level of safety.
  ##
  ## It's important to note that since there is a 0-epoch look-ahead (i.e.,
  ## no look-ahead) for block proposers then it's very likely that a proposal
  ## for the first slot of the epoch will need go through the slow path every
  ## time. I.e., the proposal will only happen after we've been able to
  ## download and process the duties from the BN. This means it is very
  ## important to ensure this function is as fast as possible.
  let sres = vc.getCurrentSlot()
  if sres.isSome():
    let
      currentSlot = sres.get()
      currentEpoch = currentSlot.epoch()

    # Query cached proposers for current slot.
    let initialProposers = vc.getBlockProposers(currentSlot)

    if len(initialProposers) > 0:
      info "Block proposers detected", slot = currentSlot,
            validators_count = vc.attachedValidators.count(),
            proposers_count = len(initialProposers)
      # Notify the `BlockServiceRef` for any proposals that we have in our
      # cache.
      await vc.notifyBlockProductionService(currentSlot,
                                            initialProposers.toList())

    if vc.attachedValidators.count() != 0:
      # Only download duties and notify `BlockServiceRef` if we have some
      # validators.
      let res = await vc.getProposerDuties(currentEpoch)
      let
        dependentRoot = res.dependent_root
        duties = res.data
        relevantDuties = duties.filterIt(it.pubkey in vc.attachedValidators)
        propData = ProposedData.init(currentEpoch,
                                     dependentRoot, relevantDuties)
      if len(relevantDuties) > 0:
        let epochDuty = vc.proposers.getOrDefault(currentEpoch)
        if not(epochDuty.isDefault()):
          if epochDuty.dependentRoot != dependentRoot:
            warn "Proposer duties re-organization",
                 prior_dependent_root = epochDuty.dependentRoot,
                 dependent_root = dependentRoot, loop = ProposerLoop
      else:
        debug "No relevant proposer duties received", slot = currentSlot,
              duties_count = len(duties)
      vc.proposers[currentEpoch] = propData

      # Compute the block proposers for this slot again, now that we've received
      # an update from the beacon node. Then, compute the difference between two
      # sets to obtain set of block proposers which were not included in the
      # initial notification to `BlockServiceRef`.
      let additionalProposers = difference(initialProposers,
                                           vc.getBlockProposers(currentSlot))
      if len(additionalProposers) > 0:
        info "Additional block proposers detected", slot = currentSlot,
              validators_count = vc.attachedValidators.count(),
              proposers_count = len(additionalProposers)

        await vc.notifyBlockProductionService(currentSlot,
                                              additionalProposers.toList())

proc waitForNextSlot(service: DutiesServiceRef,
                     serviceLoop: DutiesServiceLoop) {.async.} =
  let vc = service.client
  let sleepTime = vc.beaconClock.durationToNextSlot()
  await sleepAsync(sleepTime)

proc attesterDutiesLoop(service: DutiesServiceRef) {.async.} =
  let vc = service.client
  while true:
    await vc.pollForAttesterDuties()
    await service.waitForNextSlot(AttesterLoop)

proc proposerDutiesLoop(service: DutiesServiceRef) {.async.} =
  let vc = service.client
  while true:
    await vc.pollForBeaconProposers()
    await service.waitForNextSlot(ProposerLoop)

proc validatorIndexLoop(service: DutiesServiceRef) {.async.} =
  let vc = service.client
  while true:
    await vc.pollForValidatorIndices()
    await service.waitForNextSlot(IndicesLoop)

template checkAndRestart(serviceLoop: DutiesServiceLoop,
                         future: Future[void], body: untyped): untyped =
  if future.finished():
    if future.failed():
      let error = future.readError()
      debug "The loop ended unexpectedly with an error",
            error_name = error.name, error_msg = error.msg, loop = serviceLoop
    elif future.cancelled():
      debug "The loop is interrupted unexpectedly", loop = serviceLoop
    else:
      debug "The loop is finished unexpectedly without an error",
            loop = serviceLoop
    future = body

proc mainLoop(service: DutiesServiceRef) {.async.} =
  service.state = ServiceState.Running
  let vc = service.client
  var
    fut1 = service.attesterDutiesLoop()
    fut2 = service.proposerDutiesLoop()
    fut3 = service.validatorIndexLoop()

  while true:
    var breakLoop = false
    try:
      discard await race(fut1, fut2, fut3)
    except CancelledError:
      if not(fut1.finished()): fut1.cancel()
      if not(fut2.finished()): fut2.cancel()
      if not(fut3.finished()): fut3.cancel()
      await allFutures(fut1, fut2, fut3)
      breakLoop = true

    if breakLoop:
      break

    checkAndRestart(AttesterLoop, fut1, service.attesterDutiesLoop())
    checkAndRestart(ProposerLoop, fut2, service.proposerDutiesLoop())
    checkAndRestart(IndicesLoop, fut3, service.validatorIndexLoop())

proc init*(t: typedesc[DutiesServiceRef],
           vc: ValidatorClientRef): Future[DutiesServiceRef] {.async.} =
  var res = DutiesServiceRef(client: vc, state: ServiceState.Initialized)
  debug "Initializing service"
  # We query for indices first, to avoid empty queries for duties.
  await vc.pollForValidatorIndices()
  return res

proc start*(service: DutiesServiceRef) =
  service.lifeFut = mainLoop(service)
