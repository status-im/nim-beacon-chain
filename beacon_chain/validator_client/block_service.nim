import common, api
import chronicles

logScope: service = "block_service"

proc publishBlock(vc: ValidatorClientRef, currentSlot, slot: Slot,
                  validator: AttachedValidator) {.async.} =
  logScope:
    validator = validator.pubKey
    slot = slot
    wallSlot = currentSlot

  let
    genesisRoot = vc.beaconGenesis.genesis_validators_root
    graffiti =
      if vc.config.graffiti.isSome():
        vc.config.graffiti.get()
      else:
        defaultGraffitiBytes()
    fork = vc.fork.get()

  debug "Publishing block", validator = validator.pubKey,
                            delay = vc.getDelay(ZeroDuration),
                            genesis_root = genesisRoot,
                            graffiti = graffiti, fork = fork, slot = slot,
                            wall_slot = currentSlot

  try:
    let randaoReveal = await validator.genRandaoReveal(fork, genesisRoot, slot)
    let beaconBlock = await vc.produceBlock(slot, randaoReveal, graffiti)
    let blockRoot = hash_tree_root(beaconBlock)
    var signedBlock = SignedBeaconBlock(message: beaconBlock,
                                        root: hash_tree_root(beaconBlock))

    # TODO: signing_root is recomputed in signBlockProposal just after
    let signing_root = compute_block_root(fork, genesisRoot, slot,
                                          signedBlock.root)
    let notSlashable = vc.attachedValidators
      .slashingProtection
      .registerBlock(ValidatorIndex(signedBlock.message.proposer_index),
                     validator.pubKey, slot, signing_root)

    if notSlashable.isOk():
      let signature = await validator.signBlockProposal(fork, genesisRoot, slot,
                                                        blockRoot)
      let signedBlock = SignedBeaconBlock(message: beaconBlock, root: blockRoot,
                                          signature: signature)
      let res = await vc.publishBlock(signedBlock)
      if res:
        notice "Successfully published block",
          deposits = len(signedBlock.message.body.deposits),
          attestations = len(signedBlock.message.body.attestations),
          graffiti = graffiti
      else:
        warn "Failed to publish block"
    else:
      warn "Slashing protection activated for block proposal",
           existingProposal = notSlashable.error
  except CatchableError as exc:
    error "Unexpected error happens while proposing block",
          error_name = exc.name, error_msg = exc.msg

proc proposeBlock(vc: ValidatorClientRef, slot: Slot,
                  proposerKey: ValidatorPubkey) {.async.} =
  let (inFuture, timeToSleep) = vc.beaconClock.fromNow(slot)
  try:
    if inFuture:
      debug "Proposing block", timeIn = timeToSleep, validator = proposerKey
      await sleepAsync(timeToSleep)
    else:
      debug "Proposing block", timeIn = 0.seconds, validator = proposerKey

    let sres = vc.getCurrentSlot()
    if sres.isSome():
      let currentSlot = sres.get()
      # We need to check that we still have validator in our pool.
      let validator = vc.attachedValidators.getValidator(proposerKey)
      if isNil(validator):
        debug "Validator is not present in pool anymore, exiting",
              validator = proposerKey
        return
      await vc.publishBlock(currentSlot, slot, validator)

  except CancelledError:
    debug "Proposing task was cancelled", slot = slot, validator = proposerKey


proc spawnProposalTask(vc: ValidatorClientRef,
                       duty: RestProposerDuty): ProposerTask =
  let future = proposeBlock(vc, duty.slot, duty.pubkey)
  ProposerTask(future: future, duty: duty)

proc contains(data: openArray[RestProposerDuty], task: ProposerTask): bool =
  for item in data:
    if (item.pubkey == task.duty.pubkey) and (item.slot == task.duty.slot):
      return true
  false

proc contains(data: openArray[ProposerTask], duty: RestProposerDuty): bool =
  for item in data:
    if (item.duty.pubkey == duty.pubkey) and (item.duty.slot == duty.slot):
      return true
  false

proc addOrReplaceProposers*(vc: ValidatorClientRef, epoch: Epoch,
                            dependentRoot: Eth2Digest,
                            duties: openArray[RestProposerDuty]) =
  let epochDuties = vc.proposers.getOrDefault(epoch)
  if not(epochDuties.isDefault()):
    if epochDuties.dependentRoot != dependentRoot:
      warn "Proposer duties re-organization",
           prior_dependent_root = epochDuties.dependentRoot,
           dependent_root = dependentRoot
      let tasks =
        block:
          var res: seq[ProposerTask]
          var hashset = initHashSet[Slot]()

          for task in epochDuties.duties:
            if task notin duties:
              # Task is no more relevant, so cancel it.
              debug "Cancelling running proposal duty task",
                    slot = task.duty.slot, validator = task.duty.pubkey
              task.future.cancel()
            else:
              # If task is already running for proper slot, we keep it alive.
              debug "Keep running previous proposal duty task",
                    slot = task.duty.slot, validator = task.duty.pubkey
              res.add(task)

          for duty in duties:
            if duty notin res:
              debug "New proposal duty received", slot = duty.slot,
                    validator = duty.pubkey
              let task = vc.spawnProposalTask(duty)
              if duty.slot in hashset:
                error "Multiple block proposers for this slot, " &
                      "producing blocks for all proposers", slot = duty.slot
              else:
                hashset.incl(duty.slot)
              res.add(task)
          res
      vc.proposers[epoch] = ProposedData.init(epoch, dependentRoot, tasks)
  else:
    # Spawn new proposer tasks and modify proposers map.
    let tasks =
      block:
        var hashset = initHashSet[Slot]()
        var res: seq[ProposerTask]
        for duty in duties:
          debug "New proposal duty received", slot = duty.slot,
                validator = duty.pubkey
          let task = vc.spawnProposalTask(duty)
          if duty.slot in hashset:
            error "Multiple block proposers for this slot, " &
                  "producing blocks for all proposers", slot = duty.slot
          else:
            hashset.incl(duty.slot)
          res.add(task)
        res
    vc.proposers[epoch] = ProposedData.init(epoch, dependentRoot, tasks)

proc waitForBlockPublished*(vc: ValidatorClientRef, slot: Slot) {.async.} =
  ## This procedure will wait for all the block proposal tasks to be finished at
  ## slot ``slot``
  let pendingTasks =
    block:
      var res: seq[Future[void]]
      let epochDuties = vc.proposers.getOrDefault(slot.epoch())
      for task in epochDuties.duties:
        if task.duty.slot == slot:
          if not(task.future.finished()):
            res.add(task.future)
      res
  if len(pendingTasks) > 0:
    await allFutures(pendingTasks)
