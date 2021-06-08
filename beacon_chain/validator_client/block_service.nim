import common
import chronicles

logScope: service = "block_service"

proc mainLoop(service: BlockServiceRef) {.async.} =
  let vc = service.client
  service.state = ServiceState.Running
  debug "Service started"
  while true:
    await sleepAsync(10.seconds)

proc init*(t: typedesc[BlockServiceRef],
           vc: ValidatorClientRef): Future[BlockServiceRef] {.async.} =
  debug "Initializing service"
  var res = BlockServiceRef(client: vc, state: ServiceState.Initialized)
  return res

proc start*(service: BlockServiceRef) =
  service.lifeFut = mainLoop(service)
