import common, api
import chronicles

logScope: service = "block_service"

proc publishBlock(service: BlockServiceRef,
                  currentSlot, slot: Slot, pubkey: ValidatorPubKey) {.async.} =
  logScope:
    validator = pubkey
    slot = slot
    wallSlot = currentSlot

  let
    vc = service.client
    validator = vc.attachedValidators.validators[pubkey]
    genesisRoot = vc.beaconGenesis.genesis_validators_root
    graffiti =
      if vc.config.graffiti.isSome():
        vc.config.graffiti.get()
      else:
        defaultGraffitiBytes()
    fork = vc.fork.get()

  debug "Publishing block", validator = pubkey, genesis_root = genesisRoot,
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
                     pubkey, slot, signing_root)

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

proc mainLoop(service: BlockServiceRef) {.async.} =
  let vc = service.client
  service.state = ServiceState.Running
  while true:
    let event = await vc.blocksQueue.popFirst()
    let sres = vc.getCurrentSlot()
    if sres.isSome():
      let currentSlot = sres.get()

      let proposersList = event.proposers.mapIt($it).join(", ")
      debug "Received event ", event_slot = event.slot,
            event_proposers = "[" & proposersList & "]"

      if event.slot != currentSlot:
        warn "Skipping block production for expired slot",
             slot = event.slot, current_slot = currentSlot
      else:
        if event.slot == Slot(0):
          debug "Not producing block at genesis slot",
                proposers = len(event.proposers)
        else:
          doAssert(len(event.proposers) > 0, "Event must always has proposers")
          let proposers = event.proposers
          if len(proposers) > 1:
            error "Multiple block proposers for this slot, " &
                  "producing blocks for all proposers",
                  proposers_count = len(proposers), slot = event.slot

          for pubkey in proposers:
            asyncSpawn service.publishBlock(currentSlot, event.slot, pubkey)

proc init*(t: typedesc[BlockServiceRef],
           vc: ValidatorClientRef): Future[BlockServiceRef] {.async.} =
  debug "Initializing service"
  var res = BlockServiceRef(client: vc, state: ServiceState.Initialized)
  return res

proc start*(service: BlockServiceRef) =
  service.lifeFut = mainLoop(service)
