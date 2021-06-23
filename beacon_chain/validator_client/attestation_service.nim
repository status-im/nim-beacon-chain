import std/[sets, sequtils]
import chronicles
import common, api

logScope: service = "attestation_service"

proc getDelay*(vc: ValidatorClientRef, instant: Duration): Duration =
  let currentBeaconTime = vc.beaconClock.now()
  let currentTime = Duration(currentBeaconTime)
  let slotStartTime = currentBeaconTime.slotOrZero().toBeaconTime()
  let idealTime = Duration(slotStartTime) + instant
  currentTime - idealTime

proc produceAndPublishAttestations*(service: AttestationServiceRef,
                                    slot: Slot, committee_index: CommitteeIndex,
                                    duties: seq[RestAttesterDuty]
                                   ): Future[AttestationData] {.
     async.} =
  doAssert(MAX_VALIDATORS_PER_COMMITTEE <= uint64(high(int)))
  let vc = service.client
  let ad = await vc.produceAttestationData(slot, committee_index)
  let attestations =
    block:
      var res: seq[Attestation]
      for duty in duties:
        debug "Serving attestation duty", duty = duty, epoch = slot.epoch()
        if (duty.slot != ad.slot) or
           (uint64(duty.committee_index) != ad.index):
          error "Inconsistent validator duties during attestation signing",
                validator = duty.pubkey, duty_slot = duty.slot,
                duty_index = duty.committee_index,
                attestation_slot = ad.slot, attestation_index = ad.index
          continue

        let validator = vc.attachedValidators.getValidator(duty.pubkey)

        if validator.index.isNone():
          warn "Validator index is missing", validator = validator.pubKey
          continue

        # TODO: signing_root is recomputed in signBlockProposal just after,
        # but not for locally attached validators.
        let signing_root =
          compute_attestation_root(vc.fork.get(),
                                   vc.beaconGenesis.genesis_validators_root,
                                   ad)

        let vindex = validator.index.get()
        let notSlashable = vc.attachedValidators.slashingProtection
          .registerAttestation(vindex, validator.pubKey,
                               ad.source.epoch, ad.target.epoch, signing_root)
        if notSlashable.isErr():
          warn "Slashing protection activated for attestation",
               validator = validator.pubKey,
               badVoteDetails = $notSlashable.error
          continue

        let attestation = await validator.produceAndSignAttestation(ad,
          int(duty.committee_length), Natural(duty.validator_committee_index),
          vc.fork.get(), vc.beaconGenesis.genesis_validators_root)

        res.add(attestation)
      res

  let count = len(attestations)
  if count > 0:
    let res = await vc.submitPoolAttestations(attestations)
    if res:
      notice "Successfully published attestations", count = count
    else:
      warn "Failed to publish attestations", count = count
  else:
    warn "No attestations produced"
  return ad

proc produceAndPublishAggregates(service: AttestationServiceRef,
                                 adata: AttestationData,
                                 duties: seq[RestAttesterDuty]) {.async.} =
  let
    vc = service.client
    slot = adata.slot
    committeeIndex = CommitteeIndex(adata.index)
    attestationRoot = adata.hash_tree_root()
    genesisRoot = vc.beaconGenesis.genesis_validators_root

  let aggAttestation = await vc.getAggregatedAttestation(slot, attestationRoot)

  let aggregateAndProofs =
    block:
      var res: seq[SignedAggregateAndProof]
      for duty in duties:
        let validator = vc.attachedValidators.getValidator(duty.pubkey)
        let slotSignature = await getSlotSig(validator, vc.fork.get(),
                                             genesisRoot, slot)
        if (duty.slot != slot) or (duty.committee_index != committeeIndex):
          error "Inconsistent validator duties during aggregate signing",
                duty_slot = duty.slot, slot = slot,
                duty_committee_index = duty.committee_index,
                committee_index = committeeIndex
          continue

        if is_aggregator(duty.committee_length, slotSignature):
          notice "Aggregating", slot = slot, validator = duty.pubkey

          let aggAndProof = AggregateAndProof(
            aggregator_index: uint64(duty.validator_index),
            aggregate: aggAttestation,
            selection_proof: slot_signature
          )
          let signature = await signAggregateAndProof(validator, aggAndProof,
                                                      vc.fork.get(),
                                                      genesisRoot)
          res.add(SignedAggregateAndProof(message: aggAndProof,
                                          signature: signature))
      res

  let count = len(aggregateAndProofs)
  if count > 0:
    let res = await vc.publishAggregateAndProofs(aggregateAndProofs)
    if res:
      notice "Successfully published aggregate and proofs", count = count
    else:
      warn "Failed to publish aggregate and proofs", count = count
  else:
    warn "No aggregate and proofs produced"

proc publishAttestationsAndAggregates(service: AttestationServiceRef,
                                      slot: Slot,
                                      committee_index: CommitteeIndex,
                                      duties: seq[RestAttesterDuty]) {.async.} =
  let vc = service.client
  let aggregateTime =
    # chronos.Duration substraction could not return negative value, in such
    # case it will return `ZeroDuration`.
    vc.beaconClock.durationToNextSlot() - seconds(int64(SECONDS_PER_SLOT) div 3)

  block:
    let delay = vc.getDelay(seconds(int64(SECONDS_PER_SLOT) div 3))
    notice "Producing attestations", delay = delay
  let ad = await service.produceAndPublishAttestations(slot, committee_index,
                                                       duties)

  if aggregateTime != ZeroDuration:
    await sleepAsync(aggregateTime)

  block:
    let delay = vc.getDelay(seconds((int64(SECONDS_PER_SLOT) div 3) * 2))
    notice "Producing aggregate and proofs", delay = delay
  await service.produceAndPublishAggregates(ad, duties)

proc spawnAttestationTasks(service: AttestationServiceRef,
                           slot: Slot) =
  let vc = service.client
  let dutiesByCommittee =
    block:
      var res: Table[CommitteeIndex, seq[RestAttesterDuty]]
      let attesters = vc.getAttesterDutiesForSlot(slot)
      var default: seq[RestAttesterDuty]
      for item in attesters:
        res.mgetOrPut(item.committee_index, default).add(item)
      res
  for index, duties in dutiesByCommittee.pairs():
    if len(duties) > 0:
      asyncSpawn service.publishAttestationsAndAggregates(slot, index, duties)

proc mainLoop(service: AttestationServiceRef) {.async.} =
  let vc = service.client
  service.state = ServiceState.Running
  while true:
    let sleepTime = vc.beaconClock.durationToNextSlot() +
                      seconds(int64(SECONDS_PER_SLOT) div 3)
    let sres = vc.getCurrentSlot()
    if sres.isSome():
      let currentSlot = sres.get()
      service.spawnAttestationTasks(currentSlot)
    await sleepAsync(sleepTime)

proc init*(t: typedesc[AttestationServiceRef],
           vc: ValidatorClientRef): Future[AttestationServiceRef] {.async.} =
  debug "Initializing service"
  var res = AttestationServiceRef(client: vc, state: ServiceState.Initialized)
  return res

proc start*(service: AttestationServiceRef) =
  service.lifeFut = mainLoop(service)
