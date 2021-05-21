import
  stew/results,
  presto,
  chronicles,
  eth/p2p/discoveryv5/enr,
  libp2p/[multiaddress, multicodec],
  nimcrypto/utils as ncrutils,
  ../version, ../beacon_node_common, ../sync/sync_manager,
  ../networking/[eth2_network, peer_pool],
  ../spec/datatypes/base,
  ../spec/[digest, presets],
  ../spec/eth2_apis/callsigs_types,
  ./eth2_json_rest_serialization, ./rest_utils

logScope: topics = "rest_node"

type
  ConnectionStateSet* = set[ConnectionState]
  PeerTypeSet* = set[PeerType]

  RestNodePeerCount* = object
    disconnected*: uint64
    connecting*: uint64
    connected*: uint64
    disconnecting*: uint64

proc validateState(states: seq[PeerStateKind]): Result[ConnectionStateSet,
                                                       cstring] =
  var res: set[ConnectionState]
  for item in states:
    case item
    of PeerStateKind.Disconnected:
      if ConnectionState.Disconnected in res:
        return err("Peer connection states must be unique")
      res.incl(ConnectionState.Disconnected)
    of PeerStateKind.Connecting:
      if ConnectionState.Connecting in res:
        return err("Peer connection states must be unique")
      res.incl(ConnectionState.Connecting)
    of PeerStateKind.Connected:
      if ConnectionState.Connected in res:
        return err("Peer connection states must be unique")
      res.incl(ConnectionState.Connected)
    of PeerStateKind.Disconnecting:
      if ConnectionState.Disconnecting in res:
        return err("Peer connection states must be unique")
      res.incl(ConnectionState.Disconnecting)
  if res == {}:
    res = {ConnectionState.Connecting, ConnectionState.Connected,
           ConnectionState.Disconnecting, ConnectionState.Disconnected}
  ok(res)

proc validateDirection(directions: seq[PeerDirectKind]): Result[PeerTypeSet,
                                                                cstring] =
  var res: set[PeerType]
  for item in directions:
    case item
    of PeerDirectKind.Inbound:
      if PeerType.Incoming in res:
        return err("Peer direction states must be unique")
      res.incl(PeerType.Incoming)
    of PeerDirectKind.Outbound:
      if PeerType.Outgoing in res:
        return err("Peer direction states must be unique")
      res.incl(PeerType.Outgoing)
  if res == {}:
    res = {PeerType.Incoming, PeerType.Outgoing}
  ok(res)

proc toString(state: ConnectionState): string =
  case state
  of ConnectionState.Disconnected:
    "disconnected"
  of ConnectionState.Connecting:
    "connecting"
  of ConnectionState.Connected:
    "connected"
  of ConnectionState.Disconnecting:
    "disconnecting"
  else:
    ""

proc toString(direction: PeerType): string =
  case direction:
  of PeerType.Incoming:
    "inbound"
  of PeerType.Outgoing:
    "outbound"

proc getLastSeenAddress(info: PeerInfo): string =
  # TODO (cheatfate): We need to provide filter here, which will be able to
  # filter such multiaddresses like `/ip4/0.0.0.0` or local addresses or
  # addresses with peer ids.
  if len(info.addrs) > 0:
    $info.addrs[len(info.addrs) - 1]
  else:
    ""

proc getDiscoveryAddresses(node: BeaconNode): Option[seq[string]] =
  let restr = node.network.enrRecord().toTypedRecord()
  if restr.isErr():
    return none[seq[string]]()
  let respa = restr.get().toPeerAddr(udpProtocol)
  if respa.isErr():
    return none[seq[string]]()
  let pa = respa.get()
  let mpa = MultiAddress.init(multicodec("p2p"), pa.peerId)
  if mpa.isErr():
    return none[seq[string]]()
  var addresses = newSeqOfCap[string](len(pa.addrs))
  for item in pa.addrs:
    let resa = concat(item, mpa.get())
    if resa.isOk():
      addresses.add($(resa.get()))
  return some(addresses)

proc getP2PAddresses(node: BeaconNode): Option[seq[string]] =
  let pinfo = node.network.switch.peerInfo
  let mpa = MultiAddress.init(multicodec("p2p"), pinfo.peerId)
  if mpa.isErr():
    return none[seq[string]]()
  var addresses = newSeqOfCap[string](len(pinfo.addrs))
  for item in pinfo.addrs:
    let resa = concat(item, mpa.get())
    if resa.isOk():
      addresses.add($(resa.get()))
  return some(addresses)

proc installNodeApiHandlers*(router: var RestRouter, node: BeaconNode) =
  router.api(MethodGet, "/api/eth/v1/node/identity") do () -> RestApiResponse:
    let discoveryAddresses =
      block:
        let res = node.getDiscoveryAddresses()
        if res.isSome():
          res.get()
        else:
          newSeq[string](0)

    let p2pAddresses =
      block:
        let res = node.getP2PAddresses()
        if res.isSome():
          res.get()
        else:
          newSeq[string]()

    return RestApiResponse.jsonResponse(
      (
        peer_id: $node.network.peerId(),
        enr: node.network.enrRecord().toUri(),
        p2p_addresses: p2pAddresses,
        discovery_addresses: discoveryAddresses,
        metadata: (
          seq_number: node.network.metadata.seq_number,
          attnets: "0x" & ncrutils.toHex(node.network.metadata.attnets.bytes)
        )
      )
    )

  router.api(MethodGet, "/api/eth/v1/node/peers") do (
    state: seq[PeerStateKind],
    direction: seq[PeerDirectKind]) -> RestApiResponse:
    let connectionMask =
      block:
        if state.isErr():
          return RestApiResponse.jsonError(Http400, InvalidPeerStateValueError,
                                           $state.error())
        let sres = validateState(state.get())
        if sres.isErr():
          return RestApiResponse.jsonError(Http400, InvalidPeerStateValueError,
                                           $sres.error())
        sres.get()
    let directionMask =
      block:
        if direction.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidPeerDirectionValueError,
                                           $direction.error())
        let dres = validateDirection(direction.get())
        if dres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidPeerDirectionValueError,
                                           $dres.error())
        dres.get()

    var res: seq[NodePeerTuple]
    for item in node.network.peers.values():
      if (item.connectionState in connectionMask) and
         (item.direction in directionMask):
        let peer = (
          peer_id: $item.info.peerId,
          enr: if item.enr.isSome(): item.enr.get().toUri() else: "",
          last_seen_p2p_address: item.info.getLastSeenAddress(),
          state: item.connectionState.toString(),
          direction: item.direction.toString(),
          agent: item.info.agentVersion, # Fields `agent` and `proto` are not
          proto: item.info.protoVersion  # part of specification.
        )
        res.add(peer)
    return RestApiResponse.jsonResponseWMeta(res, (count: uint64(len(res))))

  router.api(MethodGet, "/api/eth/v1/node/peer_count") do () -> RestApiResponse:
    var res: RestNodePeerCount
    for item in node.network.peers.values():
      case item.connectionState
      of Connecting:
        inc(res.connecting)
      of Connected:
        inc(res.connected)
      of Disconnecting:
        inc(res.disconnecting)
      of Disconnected:
        inc(res.disconnected)
      of ConnectionState.None:
        discard
    return RestApiResponse.jsonResponse(res)

  router.api(MethodGet, "/api/eth/v1/node/peers/{peer_id}") do (
    peer_id: PeerID) -> RestApiResponse:
    let peer =
      block:
        if peer_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidPeerIdValueError,
                                           $peer_id.error())
        let res = node.network.peers.getOrDefault(peer_id.get())
        if isNil(res):
          return RestApiResponse.jsonError(Http404, PeerNotFoundError)
        res
    return RestApiResponse.jsonResponse(
      (
        peer_id: $peer.info.peerId,
        enr: if peer.enr.isSome(): peer.enr.get().toUri() else: "",
        last_seen_p2p_address: peer.info.getLastSeenAddress(),
        state: peer.connectionState.toString(),
        direction: peer.direction.toString(),
        agent: peer.info.agentVersion, # Fields `agent` and `proto` are not
        proto: peer.info.protoVersion  # part of specification
      )
    )

  router.api(MethodGet, "/api/eth/v1/node/version") do () -> RestApiResponse:
    return RestApiResponse.jsonResponse(
      (version: "Nimbus/" & fullVersionStr)
    )

  router.api(MethodGet, "/api/eth/v1/node/syncing") do () -> RestApiResponse:
    return RestApiResponse.jsonResponse(node.syncManager.getInfo())

  router.api(MethodGet, "/api/eth/v1/node/health") do () -> RestApiResponse:
    # TODO: Add ability to detect node's issues and return 503 error according
    # to specification.
    let res =
      if node.syncManager.inProgress:
        (health: 206)
      else:
        (health: 200)
    return RestApiResponse.jsonResponse(res)

  router.redirect(
    MethodGet,
    "/eth/v1/node/identity",
    "/api/eth/v1/node/identity"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/node/peers",
    "/api/eth/v1/node/peers"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/node/peer_count",
    "/api/eth/v1/node/peer_count"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/node/peers/{peer_id}",
    "/api/eth/v1/node/peers/{peer_id}"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/node/version",
    "/api/eth/v1/node/version"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/node/syncing",
    "/api/eth/v1/node/syncing"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/node/health",
    "/api/eth/v1/node/health"
  )

proc getSyncingStatus*(): RestResponse[DataRestSyncInfo] {.
     rest, endpoint: "/api/eth/v1/node/syncing",
     meth: MethodGet.}
  ## https://ethereum.github.io/eth2.0-APIs/#/Node/getSyncingStatus

proc getVersion*(): RestResponse[DataRestVersion] {.
     rest, endpoint: "/api/eth/v1/node/version",
     meth: MethodGet.}
  ## https://ethereum.github.io/eth2.0-APIs/#/Node/getNodeVersion
