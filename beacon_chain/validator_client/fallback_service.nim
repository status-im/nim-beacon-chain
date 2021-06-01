import common, api

proc mainLoop(service: FallbackServiceRef) {.async.} =
  var processedSlot: Option[Slot]

  while true:
    let currentSlot = service.client.beaconClock.now().slotOrZero()
    if processedSlot.isNone() or (processedSlot.get() == currentSlot):
      processedSlot = some(currentSlot)
      let nodesToCheck =
        block:
          var res: seq[BeaconNodeServerRef]
          for item in service.client.beaconNodes:
            if item.status != BeaconNodeStatus.Online:
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

      # vc.validateNodes()

    # Calculating time we need to sleep until `time(next_slot) - SLOT_LOOKAHEAD`
    let waitTime =
      block:

        let curTime = service.client.beaconClock.now()
        let slot = curTime.slotOrZero()
        let nextTime = (slot + 1'u64).toBeaconTime()

        if slot == Slot(0):
          1.seconds
        else:
          if curTime + SLOT_LOOKAHEAD > nextTime:
            1.seconds
          else:
            nextTime - curTime - SLOT_LOOKAHEAD

    debug "Waiting till next check", time_to_wait = waitTime,
         current_slot = service.client.beaconClock.now().slotOrZero()
    await sleepAsync(waitTime)

proc start*(t: typedesc[FallbackServiceRef],
            vc: ValidatorClientRef): FallbackServiceRef =
  var res = FallbackServiceRef(client: vc, state: ServiceState.Running)
  res.lifeFut = mainLoop(res)
  res
