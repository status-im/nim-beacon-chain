import common
import fallback_service, duties_service

proc initGenesis*(vc: ValidatorClientRef): Future[RestBeaconGenesis] {.async.} =
  info "Initializing genesis", nodes_count = len(vc.beaconNodes)
  var nodes = vc.beaconNodes
  while true:
    var pending: seq[Future[RestResponse[DataRestBeaconGenesis]]]
    for node in nodes:
      debug "Requesting genesis information", endpoint = node
      pending.add(node.client.getBeaconGenesis())

    try:
      await allFutures(pending)
    except CancelledError as exc:
      warn "Unexpected cancellation interrupt"
      raise exc

    let (errorNodes, genesisList) =
      block:
        var gres: seq[RestBeaconGenesis]
        var bres: seq[BeaconNodeServerRef]
        for i in 0 ..< len(pending):
          let fut = pending[i]
          if fut.done():
            let resp = fut.read()
            if resp.status == 200:
              debug "Received genesis information", endpoint = nodes[i],
                    genesis_time = resp.data.data.genesis_time,
                    genesis_fork_version = resp.data.data.genesis_fork_version,
                    genesis_root = resp.data.data.genesis_validators_root
              gres.add(resp.data.data)
            else:
              debug "Received unsuccessfull response code", endpoint = nodes[i],
                    response_code = resp.status
              bres.add(nodes[i])
          elif fut.failed():
            let error = fut.readError()
            debug "Could not obtain genesis information from beacon node",
                  endpoint = nodes[i], error_name = error.name,
                  error_msg = error.msg
            bres.add(nodes[i])
          else:
            debug "Interrupted while requesting information from beacon node",
                  endpoint = nodes[i]
            bres.add(nodes[i])
        (bres, gres)

    if len(genesisList) == 0:
      let sleepDuration = 2.seconds
      info "Could not obtain network genesis information from nodes, repeating",
           sleep_time = sleepDuration
      await sleepAsync(sleepDuration)
      nodes = errorNodes
    else:
      # Boyer-Moore majority vote algorithm
      var melem: RestBeaconGenesis
      var counter = 0
      for item in genesisList:
        if counter == 0:
          melem = item
          inc(counter)
        else:
          if melem == item:
            inc(counter)
          else:
            dec(counter)
      return melem

proc initValidators*(vc: ValidatorClientRef): Future[bool] {.async.} =
  info "Initializaing validators", path = vc.config.validatorsDir()
  var duplicates: seq[ValidatorPubKey]
  for key in vc.config.validatorKeys():
    let pubkey = key.toPubKey()
    if pubkey in duplicates:
      error "Duplicate validator's key found", validator_pubkey = pubkey
      return false
    else:
      duplicates.add(pubkey)
      vc.attachedValidators.addLocalValidator(pubkey, key)
  return true

proc asyncInit*(vc: ValidatorClientRef) {.async.} =
  vc.beaconGenesis = await vc.initGenesis()
  info "Genesis information", genesis_time = vc.beaconGenesis.genesis_time,
    genesis_fork_version = vc.beaconGenesis.genesis_fork_version,
    genesis_root = vc.beaconGenesis.genesis_validators_root
  vc.beaconClock = BeaconClock.init(vc.beaconGenesis.genesis_time)

  if not(await initValidators(vc)):
    fatal "Could not initialize local validators"

  info "Initializing slashing protection", path = vc.config.validatorsDir()
  vc.attachedValidators.slashingProtection =
    SlashingProtectionDB.init(
      vc.beaconGenesis.genesis_validators_root,
      vc.config.validatorsDir(), "slashing_protection"
    )

  vc.fallbackService = FallbackServiceRef.start(vc)
  vc.dutiesService = DutiesServiceRef.start(vc)

proc onSlotStart(vc: ValidatorClientRef, wallTime: BeaconTime,
                 lastSlot: Slot) {.async.} =
  ## Called at the beginning of a slot - usually every slot, but sometimes might
  ## skip a few in case we're running late.
  ## wallTime: current system time - we will strive to perform all duties up
  ##           to this point in time
  ## lastSlot: the last slot that we successfully processed, so we know where to
  ##           start work from - there might be jumps if processing is delayed

  let
    # The slot we should be at, according to the clock
    beaconTime = wallTime
    wallSlot = wallTime.toSlot()

  let
    # If everything was working perfectly, the slot that we should be processing
    expectedSlot = lastSlot + 1
    delay = wallTime - expectedSlot.toBeaconTime()

  info "Slot start",
    lastSlot = shortLog(lastSlot),
    wallSlot = shortLog(wallSlot.slot),
    delay = shortLog(delay)

proc asyncRun*(vc: ValidatorClientRef) {.async.} =
  await runSlotLoop(vc, vc.beaconClock.now(), onSlotStart)

programMain:
  let config = makeBannerAndConfig("Nimbus validator client " & fullVersionStr,
                                   ValidatorClientConf)

  setupStdoutLogging(config.logLevel)
  setupLogging(config.logLevel, config.logFile)

  case config.cmd
    of VCNoCommand:
      let beaconNodes =
        block:
          var servers: seq[BeaconNodeServerRef]
          let flags = {RestClientFlag.CommaSeparatedArray}
          for url in config.beaconNodes:
            let res = RestClientRef.new(url, flags = flags)
            if res.isErr():
              warn "Unable to resolve remote beacon node server's hostname",
                   url = url
            else:
              servers.add(BeaconNodeServerRef(client: res.get(), endpoint: url))
          servers

      if len(beaconNodes) == 0:
        fatal "Not enough beacon nodes in command line"
        quit 1

      debug "Launching validator client", version = fullVersionStr,
                                          cmdParams = commandLineParams(),
                                          config,
                                          beacon_nodes_count = len(beaconNodes)

      var vc = ValidatorClientRef(
        config: config,
        beaconNodes: beaconNodes,
        graffitiBytes: if config.graffiti.isSome:
                         config.graffiti.get()
                       else:
                         defaultGraffitiBytes(),
        nodesAvailable: newAsyncEvent()
      )

      waitFor asyncInit(vc)
      waitFor asyncRun(vc)
