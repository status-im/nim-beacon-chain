import common, api
import chronicles

logScope: service = "fork_service"

proc pollForFork(vc: ValidatorClientRef) {.async.} =
  let fork = await vc.getHeadStateFork()
  if vc.fork.isNone() or vc.fork.get() != fork:
    vc.fork = some(fork)
    notice "Fork update success", fork = fork

proc waitForNextEpoch(service: ForkServiceRef) {.async.} =
  let vc = service.client
  let sleepTime = vc.beaconClock.durationToNextEpoch() + TIME_DELAY_FROM_SLOT
  debug "Sleeping until next epoch", sleep_time = sleepTime
  await sleepAsync(sleepTime)

proc mainLoop(service: ForkServiceRef) {.async.} =
  service.state = ServiceState.Running
  let vc = service.client
  debug "Service started"
  while true:
    await vc.pollForFork()
    await service.waitForNextEpoch()

proc init*(t: typedesc[ForkServiceRef],
            vc: ValidatorClientRef): Future[ForkServiceRef] {.async.} =
  debug "Initializing service"
  var res = ForkServiceRef(client: vc, state: ServiceState.Initialized)
  await vc.pollForFork()
  return res

proc start*(service: ForkServiceRef) =
  service.lifeFut = mainLoop(service)
