import common, api

logScope: service = "fallback_service"

proc checkNodes*(service: FallbackServiceRef) {.async.} =
  let nodesToCheck =
    block:
      var res: seq[BeaconNodeServerRef]
      for item in service.client.beaconNodes:
        if item.status != RestBeaconNodeStatus.Online:
          res.add(item)
      res
  let pendingChecks =
    block:
      var res: seq[Future[void]]
      for item in nodesToCheck:
        res.add(service.client.checkNode(item))
      res
  try:
    await allFutures(pendingChecks)
  except CancelledError as exc:
    var pendingCancel: seq[Future[void]]
    for fut in pendingChecks:
      if not(fut.finished()):
        pendingCancel.add(fut.cancelAndWait())
    await allFutures(pendingCancel)
    raise exc

proc mainLoop(service: FallbackServiceRef) {.async.} =
  service.state = ServiceState.Running
  while true:
    await service.checkNodes()
    # Calculating time we need to sleep until `time(next_slot) - SLOT_LOOKAHEAD`
    let waitTime =
      block:
        let nextTime = service.client.beaconClock.durationToNextSlot()
        if nextTime < SLOT_LOOKAHEAD:
          nextTime + seconds(int64(SECONDS_PER_SLOT))
        else:
          nextTime - SLOT_LOOKAHEAD
    await sleepAsync(waitTime)

proc init*(t: typedesc[FallbackServiceRef],
            vc: ValidatorClientRef): Future[FallbackServiceRef] {.async.} =
  debug "Initializing service"
  var res = FallbackServiceRef(client: vc, state: ServiceState.Initialized)
  # Perform initial nodes check.
  await res.checkNodes()
  return res

proc start*(service: FallbackServiceRef) =
  service.lifeFut = mainLoop(service)
