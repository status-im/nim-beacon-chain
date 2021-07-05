import common

type
  ApiResponse*[T] = Result[T, string]
  ApiOperation = enum
    Success, Timeout, Failure, Interrupt

proc checkCompatible*(vc: ValidatorClientRef,
                      node: BeaconNodeServerRef) {.async.} =
  logScope: endpoint = node
  let info =
    try:
      debug "Requesting beacon node network configuration"
      let res = await node.client.getConfig()
      res.data.data
    except CancelledError as exc:
      error "Configuration request was interrupted"
      node.status = RestBeaconNodeStatus.Offline
      raise exc
    except RestError as exc:
      error "Unable to obtain beacon node's configuration",
            error_name = exc.name, error_message = exc.msg
      node.status = RestBeaconNodeStatus.Offline
      return
    except CatchableError as exc:
      error "Unexpected exception", error_name = exc.name,
            error_message = exc.msg
      node.status = RestBeaconNodeStatus.Offline
      return

  let genesis =
    try:
      debug "Requesting beacon node genesis information"
      let res = await node.client.getBeaconGenesis()
      res.data.data
    except CancelledError as exc:
      error "Genesis request was interrupted"
      node.status = RestBeaconNodeStatus.Offline
      raise exc
    except RestError as exc:
      error "Unable to obtain beacon node's genesis",
            error_name = exc.name, error_message = exc.msg
      node.status = RestBeaconNodeStatus.Offline
      return
    except CatchableError as exc:
      error "Unexpected exception", error_name = exc.name,
            error_message = exc.msg
      node.status = RestBeaconNodeStatus.Offline
      return

  let genesisFlag = (genesis != vc.beaconGenesis)
  let configFlag =
    info.MAX_VALIDATORS_PER_COMMITTEE != MAX_VALIDATORS_PER_COMMITTEE or
    info.SLOTS_PER_EPOCH != SLOTS_PER_EPOCH or
    info.SECONDS_PER_SLOT != SECONDS_PER_SLOT or
    info.EPOCHS_PER_ETH1_VOTING_PERIOD != EPOCHS_PER_ETH1_VOTING_PERIOD or
    info.SLOTS_PER_HISTORICAL_ROOT != SLOTS_PER_HISTORICAL_ROOT or
    info.EPOCHS_PER_HISTORICAL_VECTOR != EPOCHS_PER_HISTORICAL_VECTOR or
    info.EPOCHS_PER_SLASHINGS_VECTOR != EPOCHS_PER_SLASHINGS_VECTOR or
    info.HISTORICAL_ROOTS_LIMIT != HISTORICAL_ROOTS_LIMIT or
    info.VALIDATOR_REGISTRY_LIMIT != VALIDATOR_REGISTRY_LIMIT or
    info.MAX_PROPOSER_SLASHINGS != MAX_PROPOSER_SLASHINGS or
    info.MAX_ATTESTER_SLASHINGS != MAX_ATTESTER_SLASHINGS or
    info.MAX_ATTESTATIONS != MAX_ATTESTATIONS or
    info.MAX_DEPOSITS != MAX_DEPOSITS or
    info.MAX_VOLUNTARY_EXITS != MAX_VOLUNTARY_EXITS or
    info.DOMAIN_BEACON_PROPOSER != DOMAIN_BEACON_PROPOSER or
    info.DOMAIN_BEACON_ATTESTER != DOMAIN_BEACON_ATTESTER or
    info.DOMAIN_RANDAO != DOMAIN_RANDAO or
    info.DOMAIN_DEPOSIT != DOMAIN_DEPOSIT or
    info.DOMAIN_VOLUNTARY_EXIT != DOMAIN_VOLUNTARY_EXIT or
    info.DOMAIN_SELECTION_PROOF != DOMAIN_SELECTION_PROOF or
    info.DOMAIN_AGGREGATE_AND_PROOF != DOMAIN_AGGREGATE_AND_PROOF

  if configFlag or genesisFlag:
    node.status = RestBeaconNodeStatus.Incompatible
    warn "Beacon node has incompatible configuration",
          genesis_flag = genesisFlag, config_flag = configFlag
  else:
    info "Beacon node has compatible configuration"
    node.config = some(info)
    node.genesis = some(genesis)
    node.status = RestBeaconNodeStatus.Online

proc checkSync*(vc: ValidatorClientRef,
                node: BeaconNodeServerRef) {.async.} =
  logScope: endpoint = node
  let syncInfo =
    try:
      debug "Requesting beacon node sync status"
      let res = await node.client.getSyncingStatus()
      res.data.data
    except CancelledError as exc:
      error "Sync status request was interrupted"
      node.status = RestBeaconNodeStatus.Offline
      raise exc
    except RestError as exc:
      error "Unable to obtain beacon node's sync status",
            error_name = exc.name, error_message = exc.msg
      node.status = RestBeaconNodeStatus.Offline
      return
    except CatchableError as exc:
      error "Unexpected exception", error_name = exc.name,
            error_message = exc.msg
      node.status = RestBeaconNodeStatus.Offline
      return
  node.syncInfo = some(syncInfo)
  node.status =
    if not(syncInfo.is_syncing) or (syncInfo.sync_distance < SYNC_TOLERANCE):
      info "Beacon node is in sync", sync_distance = syncInfo.sync_distance,
           head_slot = syncInfo.head_slot
      RestBeaconNodeStatus.Online
    else:
      warn "Beacon node not in sync", sync_distance = syncInfo.sync_distance,
           head_slot = syncInfo.head_slot
      RestBeaconNodeStatus.NotSynced

proc checkOnline*(node: BeaconNodeServerRef) {.async.} =
  logScope: endpoint = node
  debug "Checking beacon node status"
  let agent =
    try:
      let res = await node.client.getVersion()
      res.data.data
    except CancelledError as exc:
      error "Status request was interrupted"
      node.status = RestBeaconNodeStatus.Offline
      raise exc
    except RestError as exc:
      error "Unable to check beacon node's status",
            error_name = exc.name, error_message = exc.msg
      node.status = RestBeaconNodeStatus.Offline
      return
    except CatchableError as exc:
      error "Unexpected exception", error_name = exc.name,
            error_message = exc.msg
      node.status = RestBeaconNodeStatus.Offline
      return
  debug "Beacon node has been identified", agent = agent.version
  node.ident = some(agent.version)
  node.status = RestBeaconNodeStatus.Online

proc checkNode*(vc: ValidatorClientRef,
                node: BeaconNodeServerRef) {.async.} =
  debug "Checking beacon node", endpoint = node
  await node.checkOnline()
  if node.status != RestBeaconNodeStatus.Online:
    return
  await vc.checkCompatible(node)
  if node.status != RestBeaconNodeStatus.Online:
    return
  await vc.checkSync(node)

proc checkNodes*(vc: ValidatorClientRef,
                 nodeStatuses: set[RestBeaconNodeStatus]) {.async.} =
  doAssert(RestBeaconNodeStatus.Online notin nodeStatuses)
  let nodesToCheck =
    vc.beaconNodes.filterIt(it.status in nodeStatuses)
  let pending =
    block:
      var res: seq[Future[void]]
      for node in nodesToCheck:
        res.add(vc.checkNode(node))
      res
  if len(pending) > 0:
    try:
      await allFutures(pending)
    except CancelledError as exc:
      # allFutures() did not cancel passed Futures, so we need to send
      # cancellation to all the children.
      for fut in pending:
        if not(fut.finished()):
          fut.cancel()
      await allFutures(pending)
      raise exc

template onceToAll*(vc: ValidatorClientRef, responseType: typedesc,
                    timeout: Duration, body: untyped,
                    handlers: untyped): untyped =
  var it {.inject.}: RestClientRef
  var operationResult {.inject.}: bool = false
  type BodyType = typeof(body)

  let onlineNodes =
    vc.beaconNodes.filterIt(it.status == RestBeaconNodeStatus.Online)

  if len(onlineNodes) > 0:
    var pending =
      block:
        var res: seq[BodyType]
        for node {.inject.} in onlineNodes:
          it = node.client
          it = node.client
          let fut = body
          res.add(fut)
        res

    let opres =
      try:
        await allFutures(pending).wait(timeout)
        ApiOperation.Success
      except AsyncTimeoutError:
        ApiOperation.Timeout
      except CancelledError:
        ApiOperation.Interrupt

    for idx, node {.inject.} in onlineNodes.pairs():
      it = node.client
      let apiResponse {.inject.} =
        block:
          let fut = pending[idx]
          if fut.finished():
            if fut.failed() or fut.cancelled():
              let exc = fut.readError()
              ApiResponse[responseType].err("[" & $exc.name & "] " & $exc.msg)
            else:
              ApiResponse[responseType].ok(fut.read())
          else:
            case opres
            of ApiOperation.Interrupt:
              fut.cancel()
              onlineNodes[idx].status = RestBeaconNodeStatus.Offline
              ApiResponse[responseType].err("Operation interrupted")
            of ApiOperation.Timeout:
              fut.cancel()
              onlineNodes[idx].status = RestBeaconNodeStatus.Offline
              ApiResponse[responseType].err("Operation timeout exceeded")
            of ApiOperation.Success, ApiOperation.Failure:
              # This should not be happened, because all Futures should be
              # finished, and `Failure` processed when Future is finished.
              ApiResponse[responseType].err("Unexpected error")

      node.status = handlers
      if node.status == RestBeaconNodeStatus.Online:
        operationResult = true

template firstSuccessTimeout*(vc: ValidatorClientRef, respType: typedesc,
                              timeout: Duration, body: untyped,
                              handlers: untyped): untyped =
  doAssert(timeout != ZeroDuration)
  var it {.inject.}: RestClientRef

  var timerFut =
    if timeout != InfiniteDuration:
      sleepAsync(timeout)
    else:
      nil

  var iterationsCount = 0

  while true:
    let onlineNodes =
      vc.beaconNodes.filterIt(it.status == RestBeaconNodeStatus.Online)

    if iterationsCount != 0:
      debug "Request got failed", iterations_count = iterationsCount

    var exitNow = false

    for node {.inject.} in onlineNodes:
      it = node.client
      var bodyFut = body

      let resOp =
        block:
          if isNil(timerFut):
            try:
              # We use `allFutures()` to keep result in `bodyFut`, but still
              # be able to check errors.
              await allFutures(bodyFut)
              ApiOperation.Success
            except CancelledError:
              # `allFutures()` could not cancel Futures.
              await bodyFut.cancelAndWait()
              ApiOperation.Interrupt
            except CatchableError as exc:
              # This only could happened if `allFutures()` start raise
              # exceptions.
              ApiOperation.Failure
          else:
            try:
              discard await race(bodyFut, timerFut)
              if bodyFut.finished():
                ApiOperation.Success
              else:
                await bodyFut.cancelAndWait()
                ApiOperation.Timeout
            except CancelledError:
              # `race()` could not cancel Futures.
              if not(bodyFut.finished()):
                if not(timerFut.finished()):
                  timerFut.cancel()
                await allFutures(bodyFut.cancelAndWait(), timerFut)
              else:
                await cancelAndWait(timerFut)
              ApiOperation.Interrupt
            except CatchableError as exc:
              # This only could happened if `race()` start raise exceptions.
              ApiOperation.Failure

      block:
        let apiResponse {.inject.} =
          block:
            if bodyFut.finished():
              if bodyFut.failed() or bodyFut.cancelled():
                let exc = bodyFut.readError()
                ApiResponse[respType].err("[" & $exc.name & "] " & $exc.msg)
              else:
                ApiResponse[respType].ok(bodyFut.read())
            else:
              case resOp
              of ApiOperation.Interrupt:
                ApiResponse[respType].err("Operation was interrupted")
              of ApiOperation.Timeout:
                ApiResponse[respType].err("Operation timeout exceeded")
              of ApiOperation.Success, ApiOperation.Failure:
                # This should not be happened, because all Futures should be
                # finished, and `Failure` processed when Future is finished.
                ApiResponse[respType].err("Unexpected error")

        let status =
          try:
            handlers
          except CatchableError:
            raiseAssert("Response handler must not raise exceptions")

        node.status = status

      if resOp == ApiOperation.Success:
        if node.status == RestBeaconNodeStatus.Online:
          exitNow = true
          break
      else:
        exitNow = true
        break

    if exitNow:
      break

    let offlineMask = {RestBeaconNodeStatus.Offline,
                       RestBeaconNodeStatus.NotSynced,
                       RestBeaconNodeStatus.Uninitalized}
    let offlineNodes = vc.beaconNodes.filterIt(it.status in offlineMask)

    warn "There no beacon nodes available, refreshing nodes status",
         online_nodes = len(onlineNodes), offline_nodes = len(offlineNodes)

    var checkFut = vc.checkNodes(offlineMask)

    let checkOp =
      block:
        var dontRushFut = sleepAsync(500.milliseconds)
        if isNil(timerFut):
          try:
            # We use `allFutures()` to keep result in `checkFut`, but still
            # be able to check errors.
            await allFutures(checkFut, dontRushFut)
            ApiOperation.Success
          except CancelledError:
            # `allFutures()` could not cancel Futures.
            if not(checkFut.finished()):
              checkFut.cancel()
            if not(dontRushFut.finished()):
              dontRushFut.cancel()
            await allFutures(checkFut, dontRushFut)
            ApiOperation.Interrupt
          except CatchableError as exc:
            # This only could happened if `race()` or `allFutures()` start raise
            # exceptions.
            ApiOperation.Failure
        else:
          try:
            discard await race(allFutures(checkFut, dontRushFut), timerFut)
            if checkFut.finished():
              ApiOperation.Success
            else:
              checkFut.cancel()
              if not(dontRushFut.finished()):
                dontRushFut.cancel()
              await allFutures(checkFut, dontRushFut)
              ApiOperation.Timeout
          except CancelledError:
            # `race()` and `allFutures()` could not cancel Futures.
            if not(timerFut.finished()):
              timerFut.cancel()
            if not(dontRushFut.finished()):
              dontRushFut.cancel()
            if not(checkFut.finished()):
              checkFut.cancel()
            await allFutures(checkFut, dontRushFut, timerFut)
            ApiOperation.Interrupt
          except CatchableError as exc:
            # This only could happened if `race` or `allFutures` start raise
            # exceptions.
            ApiOperation.Failure

    if checkOp != ApiOperation.Success:
      exitNow = true
      break

proc getProposerDuties*(vc: ValidatorClientRef,
                        epoch: Epoch): Future[DataRestProposerDuties] {.
     async.} =
  logScope: request = "getProposerDuties"
  vc.firstSuccessTimeout(RestResponse[DataRestProposerDuties], SlotDuration,
                         getProposerDuties(it, epoch)):
    if apiResponse.isErr():
      debug "Unable to retrieve proposer duties", endpoint = node,
            error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status
      of 200:
        debug "Received successfull response", endpoint = node
        return response.data
      of 400:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 503:
        debug "Received not synced error response",
              response_code = 503, endpoint = node
        RestBeaconNodeStatus.NotSynced
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError, "Unable to retrieve proposer duties")

proc getAttesterDuties*(vc: ValidatorClientRef, epoch: Epoch,
                        validators: seq[ValidatorIndex]
                       ): Future[DataRestAttesterDuties] {.async.} =
  logScope: request = "getAttesterDuties"
  vc.firstSuccessTimeout(RestResponse[DataRestAttesterDuties], SlotDuration,
                         getAttesterDuties(it, epoch, validators)):
    if apiResponse.isErr():
      debug "Unable to retrieve attester duties", endpoint = node,
            error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status
      of 200:
        debug "Received successfull response", endpoint = node
        return response.data
      of 400:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 503:
        debug "Received not synced error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.NotSynced
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError, "Unable to retrieve attester duties")

proc getHeadStateFork*(vc: ValidatorClientRef): Future[Fork] {.async.} =
  logScope: request = "getHeadStateFork"
  let stateIdent = StateIdent.init(StateIdentType.Head)
  vc.firstSuccessTimeout(RestResponse[DataRestFork], SlotDuration,
                         getStateFork(it, stateIdent)):
    if apiResponse.isErr():
      debug "Unable to retrieve head state's fork", endpoint = node,
            error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status
      of 200:
        debug "Received successfull response", endpoint = node
        return response.data.data
      of 400, 404:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError, "Unable to retrieve head state's fork")

proc getValidators*(vc: ValidatorClientRef,
                    id: seq[ValidatorIdent]): Future[seq[RestValidator]] {.
     async.} =
  logScope: request = "getStateValidators"
  let stateIdent = StateIdent.init(StateIdentType.Head)
  vc.firstSuccessTimeout(RestResponse[DataRestValidatorList], SlotDuration,
                         getStateValidators(it, stateIdent, id)):
    if apiResponse.isErr():
      debug "Unable to retrieve head state's validator information",
            endpoint = node, error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status
      of 200:
        debug "Received successfull response", endpoint = node
        return response.data.data
      of 400, 404:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError,
                     "Unable to retrieve head state's validator information")

proc produceAttestationData*(vc: ValidatorClientRef,  slot: Slot,
                             committee_index: CommitteeIndex
                            ): Future[AttestationData] {.async.} =
  logScope: request = "produceAttestationData"
  vc.firstSuccessTimeout(RestResponse[DataRestAttestationData],
                         OneThirdDuration,
                         produceAttestationData(it, slot, committee_index)):
    if apiResponse.isErr():
      debug "Unable to retrieve attestation data", endpoint = node,
            error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status
      of 200:
        debug "Received successfull response", endpoint = node
        return response.data.data
      of 400:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 503:
        debug "Received not synced error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.NotSynced
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError, "Unable to retrieve attestation data")

proc getAttestationErrorMessage(response: RestPlainResponse): string =
  let res = decodeBytes(RestAttestationError, response.data,
                        response.contentType)
  if res.isOk():
    let errorObj = res.get()
    let failures = errorObj.failures.mapIt(Base10.toString(it.index) & ": " &
                                           it.message)
    errorObj.message & ": [" & failures.join(", ") & "]"
  else:
    "Unable to decode error response: [" & $res.error() & "]"

proc getGenericErrorMessage(response: RestPlainResponse): string =
  let res = decodeBytes(RestGenericError, response.data,
                        response.contentType)
  if res.isOk():
    let errorObj = res.get()
    if errorObj.stacktraces.isSome():
      errorObj.message & ": [" & errorObj.stacktraces.get().join("; ") & "]"
    else:
      errorObj.message
  else:
    "Unable to decode error response: [" & $res.error() & "]"

proc submitPoolAttestations*(vc: ValidatorClientRef,
                             data: seq[Attestation]): Future[bool] {.
     async.} =
  logScope: request = "submitPoolAttestations"
  vc.firstSuccessTimeout(RestPlainResponse, SlotDuration,
                         submitPoolAttestations(it, data)):
    if apiResponse.isErr():
      debug "Unable to submit attestation", endpoint = node,
            error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status
      of 200:
        debug "Attestation was sucessfully published", endpoint = node
        return true
      of 400:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node,
              response_error = response.getAttestationErrorMessage()
        RestBeaconNodeStatus.Offline
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node,
              response_error = response.getAttestationErrorMessage()
        RestBeaconNodeStatus.Offline
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node,
              response_error = response.getAttestationErrorMessage()
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError, "Unable to submit attestation")

proc getAggregatedAttestation*(vc: ValidatorClientRef, slot: Slot,
                               root: Eth2Digest): Future[Attestation] {.
     async.} =
  logScope: request = "getAggregatedAttestation"
  vc.firstSuccessTimeout(RestResponse[DataRestAttestation],
                         OneThirdDuration,
                         getAggregatedAttestation(it, root, slot)):
    if apiResponse.isErr():
      debug "Unable to retrieve aggregated attestation data", endpoint = node,
            error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status:
      of 200:
        debug "Received successfull response", endpoint = node
        return response.data.data
      of 400:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError,
                     "Unable to retrieve aggregated attestation data")

proc publishAggregateAndProofs*(vc: ValidatorClientRef,
                            data: seq[SignedAggregateAndProof]): Future[bool] {.
     async.} =
  logScope: request = "publishAggregateAndProofs"
  vc.firstSuccessTimeout(RestPlainResponse, SlotDuration,
                         publishAggregateAndProofs(it, data)):
    if apiResponse.isErr():
      debug "Unable to publish aggregate and proofs", endpoint = node,
            error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status:
      of 200:
        debug "Aggregate and proofs was sucessfully published", endpoint = node
        return true
      of 400:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        RestBeaconNodeStatus.Offline
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        RestBeaconNodeStatus.Offline
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError,
                     "Unable to publish aggregate and proofs")

proc produceBlock*(vc: ValidatorClientRef, slot: Slot,
                   randao_reveal: ValidatorSig,
                   graffiti: GraffitiBytes): Future[BeaconBlock] {.async.} =
  logScope: request = "produceBlock"
  vc.firstSuccessTimeout(RestResponse[DataRestBeaconBlock],
                         SlotDuration,
                         produceBlock(it, slot, randao_reveal, graffiti)):
    if apiResponse.isErr():
      debug "Unable to retrieve block data", endpoint = node,
            error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status:
      of 200:
        debug "Received successfull response", endpoint = node
        return response.data.data
      of 400:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline
      of 503:
        debug "Received not synced error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.NotSynced
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError, "Unable to retrieve block data")

proc publishBlock*(vc: ValidatorClientRef,
                   data: SignedBeaconBlock): Future[bool] {.async.} =
  logScope: request = "publishBlock"
  vc.firstSuccessTimeout(RestPlainResponse,
                         SlotDuration, publishBlock(it, data)):
    if apiResponse.isErr():
      debug "Unable to publish block", endpoint = node,
            error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status:
      of 200:
        debug "Block was successfully published", endpoint = node
        return true
      of 202:
        debug "Block not passed validation, but still published",
              endpoint = node
        return true
      of 400:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        RestBeaconNodeStatus.Offline
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        RestBeaconNodeStatus.Offline
      of 503:
        debug "Received not synced error response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        RestBeaconNodeStatus.NotSynced
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError, "Unable to publish block")

proc prepareBeaconCommitteeSubnet*(vc: ValidatorClientRef,
                                   data: seq[RestCommitteeSubscription]
                                  ): Future[bool] {.async.} =
  logScope: request = "prepareBeaconCommitteeSubnet"
  vc.firstSuccessTimeout(RestPlainResponse, OneThirdDuration,
                         prepareBeaconCommitteeSubnet(it, data)):
    if apiResponse.isErr():
      debug "Unable to prepare committee subnet", endpoint = node,
            error = apiResponse.error()
      RestBeaconNodeStatus.Offline
    else:
      let response = apiResponse.get()
      case response.status
      of 200:
        debug "Commitee subnet was successfully prepared", endpoint = node
        return true
      of 400:
        debug "Received invalid request response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        return false
      of 500:
        debug "Received internal error response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        RestBeaconNodeStatus.Offline
      of 503:
        debug "Received not synced error response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        RestBeaconNodeStatus.NotSynced
      else:
        debug "Received unexpected error response",
              response_code = response.status, endpoint = node,
              response_error = response.getGenericErrorMessage()
        RestBeaconNodeStatus.Offline

  raise newException(ValidatorApiError, "Unable to prepare committee subnet")
