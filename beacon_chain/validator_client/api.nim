import common

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

template untilSuccess*(vc: ValidatorClientRef, body: untyped,
                       handlers: untyped): untyped =
  var it {.inject.}: RestClientRef
  type ResType = typeof(body)
  var mainres: ResType
  while true:
    var retryErrorNodes: seq[BeaconNodeServerRef]
    var retryNonsyncNodes: seq[BeaconNodeServerRef]

    for node {.inject.} in vc.beaconNodes:
      case node.status
      of RestBeaconNodeStatus.Online:
        it = node.client
        let optresp =
          try:
            let res = body
            some(res)
          except CancelledError as exc:
            debug "Received interrupt", endpoint = node
            node.status = RestBeaconNodeStatus.Offline
            raise exc
          except RestError as exc:
            var m {.used.} = exc
            debug "Communication error", error_name = exc.name,
                  error_msg = exc.msg, endpoint = node
            node.status = RestBeaconNodeStatus.Offline
            none[ResType]()
          except CatchableError as exc:
            var m {.used.} = exc
            debug "Unexpected exception", error_name = exc.name,
                  error_msg = exc.msg, endpoint = node
            node.status = RestBeaconNodeStatus.Offline
            raiseAssert "Error happens"
            # none[ResType]()

        if optresp.isSome():
          let response {.inject.} = optresp.get()
          let status = handlers
          debug "Handler returned status", status = status
          case status
            of RestBeaconNodeStatus.Uninitalized, RestBeaconNodeStatus.Offline:
              retryErrorNodes.add(node)
            of RestBeaconNodeStatus.NotSynced:
              retryNonsyncNodes.add(node)
            of RestBeaconNodeStatus.Incompatible, RestBeaconNodeStatus.Online:
              discard
          node.status = status
        else:
          retryErrorNodes.add(node)
      of RestBeaconNodeStatus.Uninitalized, RestBeaconNodeStatus.Offline:
        retryErrorNodes.add(node)
      of RestBeaconNodeStatus.NotSynced:
        retryNonsyncNodes.add(node)
      of RestBeaconNodeStatus.Incompatible:
        # We are not going to repeat requests to incompatible beacon node.
        discard

    warn "There no beacon nodes available, refreshing nodes status",
         retry_error_nodes_count = len(retryErrorNodes),
         retry_nonsync_nodes_count = len(retryNonsyncNodes)

    for item in retryErrorNodes:
      try:
        await vc.checkNode(item)
      except CancelledError as exc:
        debug "Received interrupt", endpoint = item
        item.status = RestBeaconNodeStatus.Offline
        raise exc

    await sleepAsync(1.seconds)

proc getProposerDuties*(vc: ValidatorClientRef,
                        epoch: Epoch): Future[DataRestProposerDuties] {.
     async.} =
  logScope: request = "getProposerDuties"
  vc.untilSuccess(await getProposerDuties(it, epoch)):
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

proc getAttesterDuties*(vc: ValidatorClientRef, epoch: Epoch,
                        validators: seq[ValidatorIndex]
                       ): Future[DataRestAttesterDuties] {.async.} =
  logScope: request = "getAttesterDuties"
  vc.untilSuccess(await getAttesterDuties(it, epoch, validators)):
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

proc getHeadStateFork*(vc: ValidatorClientRef): Future[Fork] {.async.} =
  logScope: request = "getHeadStateFork"
  let stateIdent = StateIdent.init(StateIdentType.Head)
  vc.untilSuccess(await getStateFork(it, stateIdent)):
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

proc getValidators*(vc: ValidatorClientRef,
                    id: seq[ValidatorIdent]): Future[seq[RestValidator]] {.
     async.} =
  logScope: request = "getStateValidators"
  let stateIdent = StateIdent.init(StateIdentType.Head)
  vc.untilSuccess(await getStateValidators(it, stateIdent, id)):
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

proc produceAttestationData*(vc: ValidatorClientRef,  slot: Slot,
                             committee_index: CommitteeIndex
                            ): Future[AttestationData] {.async.} =
  logScope: request = "produceAttestationData"
  vc.untilSuccess(await produceAttestationData(it, slot, committee_index)):
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
  vc.untilSuccess(await submitPoolAttestations(it, data)):
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

proc getAggregatedAttestation*(vc: ValidatorClientRef, slot: Slot,
                               root: Eth2Digest): Future[Attestation] {.
     async.} =
  logScope: request = "getAggregatedAttestation"
  vc.untilSuccess(await getAggregatedAttestation(it, root, slot)):
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

proc publishAggregateAndProofs*(vc: ValidatorClientRef,
                            data: seq[SignedAggregateAndProof]): Future[bool] {.
     async.} =
  logScope: request = "publishAggregateAndProofs"
  vc.untilSuccess(await publishAggregateAndProofs(it, data)):
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

proc produceBlock*(vc: ValidatorClientRef, slot: Slot,
                   randao_reveal: ValidatorSig,
                   graffiti: GraffitiBytes): Future[BeaconBlock] {.
     async.} =
  logScope: request = "produceBlock"
  vc.untilSuccess(await produceBlock(it, slot, randao_reveal, graffiti)):
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

proc publishBlock*(vc: ValidatorClientRef,
                   data: SignedBeaconBlock): Future[bool] {.async.} =
  logScope: request = "produceBlock"
  vc.untilSuccess(await publishBlock(it, data)):
    case response.status:
    of 200:
      debug "Block was successfully published", endpoint = node
      return true
    of 202:
      debug "Block not passed validation, but still published", endpoint = node
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

proc prepareBeaconCommitteeSubnet*(vc: ValidatorClientRef,
                                   body: seq[RestCommitteeSubscription]
                                  ): Future[bool] {.async.} =
  logScope: request = "prepareBeaconCommitteeSubnet"
  vc.untilSuccess(await prepareBeaconCommitteeSubnet(it, body)):
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
