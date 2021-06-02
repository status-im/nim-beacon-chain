import std/sequtils
import common, api

proc pollForValidatorIndices*(vc: ValidatorClientRef) {.async.} =
  let stateIdent = StateIdent.init(StateIdentType.Head)
  let validatorIdents =
    block:
      var res: seq[ValidatorIdent]
      for pubkey in vc.attachedValidators.publicKeys():
        res.add(ValidatorIdent.init(pubkey))
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

  let relevantDuties = duties.filterIt(it.pubkey in vc.attachedValidators)
  let dependentRoot = currentRoot.get()
  var alreadyWarned = false

  for duty in relevantDuties:
    let dutyAndProof = DutyAndProof.init(epoch, dependentRoot, duty)
    debug "Received attester duty and proof", epoch = epoch,
          dependent_root = dependentRoot, duty
    var map = vc.attesters.getOrDefault(duty.pubkey)
    let epochDuty = map.getOrDefault(epoch, DefaultDutyAndProof)
    if not(epochDuty.isDefault()):
      if epochDuty.dependentRoot != dependentRoot:
        if not(alreadyWarned):
          warn "Attester duties re-organization",
               prior_dependent_root = epochDuty.dependentRoot,
               dependent_root = dependentRoot
          alreadyWarned = true
    map[epoch] = dutyAndProof
    vc.attesters[duty.pubkey] = map

proc pollForBeaconProposers*(vc: ValidatorClientRef, epoch: Epoch) {.async.} =
  discard

proc mainLoop(service: DutiesServiceRef) {.async.} =
  while true:
    await service.client.pollForValidatorIndices()
    let currentEpoch = service.client.beaconClock.now().slotOrZero().epoch()
    let nextEpoch = currentEpoch + 1'u64
    await service.client.pollForAttesterDuties(currentEpoch)
    await service.client.pollForAttesterDuties(nextEpoch)
    let sleepTime = service.client.beaconClock.durationToNextSlot()
    debug "Duties service going to sleep", sleep_time = sleepTime
    await sleepAsync(service.client.beaconClock.durationToNextSlot())

proc start*(t: typedesc[DutiesServiceRef],
            vc: ValidatorClientRef): DutiesServiceRef =
  var res = DutiesServiceRef(client: vc, state: ServiceState.Running)
  res.lifeFut = mainLoop(res)
  res
