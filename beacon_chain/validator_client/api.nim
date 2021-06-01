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
      node.status = BeaconNodeStatus.Offline
      raise exc
    except RestError as exc:
      error "Unable to obtain beacon node's configuration",
            error_name = exc.name, error_message = exc.msg
      node.status = BeaconNodeStatus.Offline
      return
    except CatchableError as exc:
      error "Unexpected exception", error_name = exc.name,
            error_message = exc.msg
      node.status = BeaconNodeStatus.Offline
      return

  let genesis =
    try:
      debug "Requesting beacon node genesis information"
      let res = await node.client.getBeaconGenesis()
      res.data.data
    except CancelledError as exc:
      error "Genesis request was interrupted"
      node.status = BeaconNodeStatus.Offline
      raise exc
    except RestError as exc:
      error "Unable to obtain beacon node's genesis",
            error_name = exc.name, error_message = exc.msg
      node.status = BeaconNodeStatus.Offline
      return
    except CatchableError as exc:
      error "Unexpected exception", error_name = exc.name,
            error_message = exc.msg
      node.status = BeaconNodeStatus.Offline
      return

  let genesisFlag = (genesis != vc.beaconGenesis)
  let configFlag =
    info.MAX_VALIDATORS_PER_COMMITTEE != MAX_VALIDATORS_PER_COMMITTEE or
    info.SLOTS_PER_EPOCH != SLOTS_PER_EPOCH or
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
    info.MAX_VOLUNTARY_EXITS != MAX_VOLUNTARY_EXITS

  if configFlag or genesisFlag:
    node.status = BeaconNodeStatus.Incompatible
    warn "Beacon node has incompatible configuration",
          genesis_flag = genesisFlag, config_flag = configFlag
  else:
    info "Beacon node has compatible configuration"
    node.config = some(info)
    node.genesis = some(genesis)
    node.status = BeaconNodeStatus.Online

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
      node.status = BeaconNodeStatus.Offline
      raise exc
    except RestError as exc:
      error "Unable to obtain beacon node's sync status",
            error_name = exc.name, error_message = exc.msg
      node.status = BeaconNodeStatus.Offline
      return
    except CatchableError as exc:
      error "Unexpected exception", error_name = exc.name,
            error_message = exc.msg
      node.status = BeaconNodeStatus.Offline
      return
  node.syncInfo = some(syncInfo)
  node.status =
    if not(syncInfo.is_syncing) or (syncInfo.sync_distance < SYNC_TOLERANCE):
      info "Beacon node is in sync", sync_distance = syncInfo.sync_distance,
           head_slot = syncInfo.head_slot
      BeaconNodeStatus.Online
    else:
      warn "Beacon node not in sync", sync_distance = syncInfo.sync_distance,
           head_slot = syncInfo.head_slot
      BeaconNodeStatus.NotSynced

proc checkOnline*(node: BeaconNodeServerRef) {.async.} =
  logScope: endpoint = node
  debug "Checking beacon node status"
  let agent =
    try:
      let res = await node.client.getVersion()
      res.data.data
    except CancelledError as exc:
      error "Status request was interrupted"
      node.status = BeaconNodeStatus.Offline
      raise exc
    except RestError as exc:
      error "Unable to check beacon node's status",
            error_name = exc.name, error_message = exc.msg
      node.status = BeaconNodeStatus.Offline
      return
    except CatchableError as exc:
      error "Unexpected exception", error_name = exc.name,
            error_message = exc.msg
      node.status = BeaconNodeStatus.Offline
      return
  debug "Beacon node has been identified", agent = agent.version
  node.ident = some(agent.version)
  node.status = BeaconNodeStatus.Online

proc checkNode*(vc: ValidatorClientRef,
                node: BeaconNodeServerRef) {.async.} =
  debug "Checking beacon node", endpoint = node
  await node.checkOnline()
  if node.status != BeaconNodeStatus.Online:
    return
  await vc.checkCompatible(node)
  if node.status != BeaconNodeStatus.Online:
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
      of BeaconNodeStatus.Online:
        it = node.client
        let optresp =
          try:
            let res = body
            some(res)
          except CancelledError as exc:
            debug "Received interrupt", endpoint = node
            node.status = BeaconNodeStatus.Offline
            raise exc
          except RestError as exc:
            var m {.used.} = exc
            debug "Communication error", error_name = exc.name,
                  error_msg = exc.msg, endpoint = node
            node.status = BeaconNodeStatus.Offline
            none[ResType]()
          except CatchableError as exc:
            var m {.used.} = exc
            debug "Unexpected exception", error_name = exc.name,
                  error_msg = exc.msg, endpoint = node
            node.status = BeaconNodeStatus.Offline
            none[ResType]()

        if optresp.isSome():
          let response {.inject.} = optresp.get()
          let status = handlers
          debug "Handler returned status", status = status
          case status
            of BeaconNodeStatus.Uninitalized, BeaconNodeStatus.Offline:
              retryErrorNodes.add(node)
            of BeaconNodeStatus.NotSynced:
              retryNonsyncNodes.add(node)
            of BeaconNodeStatus.Incompatible, BeaconNodeStatus.Online:
              discard
          node.status = status
        else:
          retryErrorNodes.add(node)
      of BeaconNodeStatus.Uninitalized, BeaconNodeStatus.Offline:
        retryErrorNodes.add(node)
      of BeaconNodeStatus.NotSynced:
        retryNonsyncNodes.add(node)
      of BeaconNodeStatus.Incompatible:
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
        item.status = BeaconNodeStatus.Offline
        raise exc

    await sleepAsync(1.seconds)

proc getProposerDuties*(vc: ValidatorClientRef,
                        epoch: Epoch): Future[DataRestProposerDuties] {.
     async.} =
  vc.untilSuccess(await getProposerDuties(it, epoch)):
    case response.status
    of 200:
      debug "Received successfull response", endpoint = node
      return response.data
    of 400:
      debug "Received invalid request response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline
    of 500:
      debug "Received internal error response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline
    of 503:
      debug "Received not synced error response",
            response_code = 503, endpoint = node
      BeaconNodeStatus.NotSynced
    else:
      debug "Received unexpected error response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline

proc getAttesterDuties*(vc: ValidatorClientRef, epoch: Epoch,
                        validators: seq[ValidatorIndex]
                       ): Future[DataRestAttesterDuties] {.async.} =
  vc.untilSuccess(await getAttesterDuties(it, epoch, validators)):
    case response.status
    of 200:
      debug "Received successfull response", endpoint = node
      return response.data
    of 400:
      debug "Received invalid request response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline
    of 500:
      debug "Received internal error response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline
    of 503:
      debug "Received not synced error response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.NotSynced
    else:
      debug "Received unexpected error response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline

proc getHeadStateFork*(vc: ValidatorClientRef): Future[DataRestFork] {.async.} =
  let stateIdent = StateIdent.init(StateIdentType.Head)
  vc.untilSuccess(await getStateFork(it, stateIdent)):
    case response.status
    of 200:
      debug "Received successfull response", endpoint = node
      return response.data
    of 400, 404:
      debug "Received invalid request response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline
    of 500:
      debug "Received internal error response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline
    else:
      debug "Received unexpected error response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline

proc getValidators*(vc: ValidatorClientRef,
                    id: seq[ValidatorIdent]): Future[seq[RestValidator]] {.
     async.} =
  let stateIdent = StateIdent.init(StateIdentType.Head)
  vc.untilSuccess(await getStateValidators(it, stateIdent, id)):
    case response.status
    of 200:
      debug "Received successfull response", endpoint = node
      return response.data.data
    of 400, 404:
      debug "Received invalid request response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline
    of 500:
      debug "Received internal error response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline
    else:
      debug "Received unexpected error response",
            response_code = response.status, endpoint = node
      BeaconNodeStatus.Offline
