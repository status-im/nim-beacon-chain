import std/[sets, sequtils]
import chronicles
import common, api, block_service

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

proc pollForAttesterDuties*(vc: ValidatorClientRef,
                            epoch: Epoch): Future[int] {.async.} =
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

  let
    relevantDuties = duties.filterIt(
      checkDuty(it) and (it.pubkey in vc.attachedValidators)
    )
    dependentRoot = currentRoot.get()
    fork = vc.fork.get()
    genesisRoot = vc.beaconGenesis.genesis_validators_root

  let addOrReplaceItems =
    block:
      var alreadyWarned = false
      var res: seq[tuple[epoch: Epoch, duty: RestAttesterDuty]]
      for duty in relevantDuties:
        let map = vc.attesters.getOrDefault(duty.pubkey)
        let epochDuty = map.duties.getOrDefault(epoch, DefaultDutyAndProof)
        if not(epochDuty.isDefault()):
          if epochDuty.dependentRoot != dependentRoot:
            res.add((epoch, duty))
            if not(alreadyWarned):
              warn "Attester duties re-organization",
                   prior_dependent_root = epochDuty.dependentRoot,
                   dependent_root = dependentRoot
              alreadyWarned = true
        else:
          info "Received new attester duty", duty, epoch = epoch,
                                             dependent_root = dependentRoot
          res.add((epoch, duty))
      res

  if len(addOrReplaceItems) > 0:
    var pending: seq[Future[ValidatorSig]]
    for item in addOrReplaceItems:
      let validator = vc.attachedValidators.getValidator(item.duty.pubkey)
      let future = validator.getSlotSig(fork, genesisRoot, item.duty.slot)
      pending.add(future)

    await allFutures(pending)

    for index, fut in pending.pairs():
      let item = addOrReplaceItems[index]
      let dap =
        if fut.done():
          DutyAndProof.init(item.epoch, dependentRoot, item.duty,
                            some(fut.read()))
        else:
          DutyAndProof.init(item.epoch, dependentRoot, item.duty,
                            none[ValidatorSig]())

      var validatorDuties = vc.attesters.getOrDefault(item.duty.pubkey)
      validatorDuties.duties[item.epoch] = dap
      vc.attesters[item.duty.pubkey] = validatorDuties

  return len(addOrReplaceItems)

proc pruneAttesterDuties(vc: ValidatorClientRef, epoch: Epoch) =
  var attesters: AttesterMap
  for key, item in vc.attesters.pairs():
    var v = EpochDuties()
    for epochKey, epochDuty in item.duties.pairs():
      if (epochKey + HISTORICAL_DUTIES_EPOCHS) >= epoch:
        v.duties[epochKey] = epochDuty
      else:
        debug "Attester duties for the epoch has been pruned", validator = key,
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
      var counts: array[2, tuple[epoch: Epoch, count: int]]
      counts[0] = (currentEpoch, await vc.pollForAttesterDuties(currentEpoch))
      counts[1] = (nextEpoch, await vc.pollForAttesterDuties(nextEpoch))

      if (counts[0].count == 0) and (counts[1].count == 0):
        debug "No new attester's duties received", slot = currentSlot

      let subscriptions =
        block:
          var res: seq[RestCommitteeSubscription]
          for item in counts:
            if item.count > 0:
              for duty in vc.attesterDutiesForEpoch(item.epoch):
                if currentSlot + SUBSCRIPTION_BUFFER_SLOTS < duty.data.slot:
                  let isAggregator =
                    if duty.slotSig.isSome():
                      is_aggregator(duty.data.committee_length,
                                    duty.slotSig.get())
                    else:
                      false
                  let sub = RestCommitteeSubscription(
                    validator_index: duty.data.validator_index,
                    committee_index: duty.data.committee_index,
                    committees_at_slot: duty.data.committees_at_slot,
                    slot: duty.data.slot,
                    is_aggregator: isAggregator
                  )
                  res.add(sub)
          res

      if len(subscriptions) > 0:
        let res = await vc.prepareBeaconCommitteeSubnet(subscriptions)
        if not(res):
          error "Failed to subscribe validators"

    vc.pruneAttesterDuties(currentEpoch)

proc pruneBeaconProposers(vc: ValidatorClientRef, epoch: Epoch) =
  var proposers: ProposerMap
  for epochKey, data in vc.proposers.pairs():
    if (epochKey + HISTORICAL_DUTIES_EPOCHS) >= epoch:
      proposers[epochKey] = data
    else:
      debug "Proposer duty has been pruned", epoch = epochKey,
            loop = ProposerLoop
  vc.proposers = proposers

proc pollForBeaconProposers*(vc: ValidatorClientRef) {.async.} =
  let sres = vc.getCurrentSlot()
  if sres.isSome():
    let
      currentSlot = sres.get()
      currentEpoch = currentSlot.epoch()

    if vc.attachedValidators.count() != 0:
      let res = await vc.getProposerDuties(currentEpoch)
      let
        dependentRoot = res.dependent_root
        duties = res.data
        relevantDuties = duties.filterIt(it.pubkey in vc.attachedValidators)

      if len(relevantDuties) > 0:
        vc.addOrReplaceProposers(currentEpoch, dependentRoot, relevantDuties)
      else:
        debug "No relevant proposer duties received", slot = currentSlot,
              duties_count = len(duties)

    vc.pruneBeaconProposers(currentEpoch)

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
