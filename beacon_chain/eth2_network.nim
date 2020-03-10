import
  options, tables, strutils, sequtils,
  json_serialization, json_serialization/std/net,
  metrics, chronos, chronicles, metrics, libp2p/crypto/crypto,
  eth/keys, eth/p2p/enode, eth/net/nat, eth/p2p/discoveryv5/enr,
  eth2_discovery, version, conf

type
  KeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

const
  clientId* = "Nimbus beacon node v" & fullVersionStr

export
  version

let
  globalListeningAddr = parseIpAddress("0.0.0.0")

# Metrics for tracking attestation and beacon block loss
declareCounter gossip_messages_sent,
  "Number of gossip messages sent by this peer"

declareCounter gossip_messages_received,
  "Number of gossip messages received by this peer"

proc setupNat(conf: BeaconNodeConf): tuple[ip: IpAddress,
                                           tcpPort: Port,
                                           udpPort: Port] =
  # defaults
  result.ip = globalListeningAddr
  result.tcpPort = Port(conf.tcpPort)
  result.udpPort = Port(conf.udpPort)

  var nat: NatStrategy
  case conf.nat.toLowerAscii:
    of "any":
      nat = NatAny
    of "none":
      nat = NatNone
    of "upnp":
      nat = NatUpnp
    of "pmp":
      nat = NatPmp
    else:
      if conf.nat.startsWith("extip:") and isIpAddress(conf.nat[6..^1]):
        # any required port redirection is assumed to be done by hand
        result.ip = parseIpAddress(conf.nat[6..^1])
        nat = NatNone
      else:
        error "not a valid NAT mechanism, nor a valid IP address", value = conf.nat
        quit(QuitFailure)

  if nat != NatNone:
    let extIP = getExternalIP(nat)
    if extIP.isSome:
      result.ip = extIP.get()
      let extPorts = redirectPorts(tcpPort = result.tcpPort,
                                   udpPort = result.udpPort,
                                   description = clientId)
      if extPorts.isSome:
        (result.tcpPort, result.udpPort) = extPorts.get()

when networkBackend in [libp2p, libp2pDaemon]:
  import
    os, random,
    stew/io, eth/async_utils,
    libp2p/[multiaddress, multicodec],
    ssz

  export
    multiaddress

  when networkBackend == libp2p:
    import
      libp2p/standard_setup, libp2p_backend, libp2p/peerinfo, peer_pool

    export
      libp2p_backend, peer_pool, peerinfo

  else:
    import
      libp2p/daemon/daemonapi, libp2p_daemon_backend

    export
      libp2p_daemon_backend

    var mainDaemon: DaemonAPI

    proc closeDaemon() {.noconv.} =
      if mainDaemon != nil:
        info "Shutting down the LibP2P daemon"
        waitFor mainDaemon.close()

    addQuitProc(closeDaemon)

  const
    netBackendName* = "libp2p"
    networkKeyFilename = "privkey.protobuf"

  func asLibp2pKey*(key: keys.PublicKey): PublicKey =
    PublicKey(scheme: Secp256k1, skkey: key)

  func asEthKey*(key: PrivateKey): keys.PrivateKey =
    keys.PrivateKey(data: key.skkey.data)

  proc initAddress*(T: type MultiAddress, str: string): T =
    let address = MultiAddress.init(str)
    if IPFS.match(address) and matchPartial(multiaddress.TCP, address):
      result = address
    else:
      raise newException(MultiAddressError,
                         "Invalid bootstrap node multi-address")

  template tcpEndPoint(address, port): auto =
    MultiAddress.init(address, Protocol.IPPROTO_TCP, port)

  proc ensureNetworkIdFile(conf: BeaconNodeConf): string =
    result = conf.dataDir / networkKeyFilename
    if not fileExists(result):
      createDir conf.dataDir.string
      let pk = PrivateKey.random(Secp256k1)
      writeFile(result, pk.getBytes)

  proc getPersistentNetKeys*(conf: BeaconNodeConf): KeyPair =
    let privKeyPath = conf.dataDir / networkKeyFilename
    var privKey: PrivateKey
    if not fileExists(privKeyPath):
      createDir conf.dataDir.string
      privKey = PrivateKey.random(Secp256k1)
      writeFile(privKeyPath, privKey.getBytes())
    else:
      let keyBytes = readFile(privKeyPath)
      privKey = PrivateKey.init(keyBytes.toOpenArrayByte(0, keyBytes.high))

    KeyPair(seckey: privKey, pubkey: privKey.getKey())

  proc createEth2Node*(conf: BeaconNodeConf,
                       bootstrapNodes: seq[ENode]): Future[Eth2Node] {.async.} =
    var
      (extIp, extTcpPort, _) = setupNat(conf)
      hostAddress = tcpEndPoint(globalListeningAddr, Port conf.tcpPort)
      announcedAddresses = if extIp == globalListeningAddr: @[]
                           else: @[tcpEndPoint(extIp, extTcpPort)]

    info "Initializing networking", hostAddress,
                                    announcedAddresses,
                                    bootstrapNodes

    when networkBackend == libp2p:
      let keys = conf.getPersistentNetKeys
      # TODO nim-libp2p still doesn't have support for announcing addresses
      # that are different from the host address (this is relevant when we
      # are running behind a NAT).
      var switch = newStandardSwitch(some keys.seckey, hostAddress,
                                     triggerSelf = true, gossip = false)
      result = Eth2Node.init(conf, switch, extIp, keys.seckey.asEthKey)
    else:
      let keyFile = conf.ensureNetworkIdFile

      var daemonFut = if bootstrapNodes.len == 0:
        newDaemonApi({PSNoSign, DHTFull, PSFloodSub},
                     id = keyFile,
                     hostAddresses = @[hostAddress],
                     announcedAddresses = announcedAddresses)
      else:
        newDaemonApi({PSNoSign, DHTFull, PSFloodSub, WaitBootstrap},
                     id = keyFile,
                     hostAddresses = @[hostAddress],
                     announcedAddresses = announcedAddresses,
                     bootstrapNodes = mapIt(bootstrapNodes, it.toMultiAddressStr),
                     peersRequired = 1)

      mainDaemon = await daemonFut

      var identity = await mainDaemon.identity()
      info "LibP2P daemon started", peer = identity.peer.pretty(),
                                    addresses = identity.addresses

      result = await Eth2Node.init(mainDaemon)

  proc getPersistenBootstrapAddr*(conf: BeaconNodeConf,
                                  ip: IpAddress, port: Port): ENode =
    let pair = getPersistentNetKeys(conf)
    initENode(pair.pubkey.skkey, Address(ip: ip, udpPort: port))

  proc shortForm*(id: KeyPair): string =
    $PeerID.init(id.pubkey)

  proc toPeerInfo(enode: ENode): PeerInfo =
    let
      peerId = PeerID.init enode.pubkey.asLibp2pKey
      addresses = @[MultiAddress.init enode.toMultiAddressStr]
    when networkBackend == libp2p:
      return PeerInfo.init(peerId, addresses)
    else:
      return PeerInfo(peer: peerId, addresses: addresses)

  proc connectToNetwork*(node: Eth2Node,
                         bootstrapNodes: seq[ENode],
                         bootstrapEnrs: seq[enr.Record]) {.async.} =
    when networkBackend == libp2pDaemon:
      var connected = false
      for bootstrapNode in bootstrapNodes:
        try:
          let peerInfo = toPeerInfo(bootstrapNode)
          when networkBackend == libp2p:
            discard await node.switch.dial(peerInfo)
          else:
            await node.daemon.connect(peerInfo.peer, peerInfo.addresses)
          var peer = node.getPeer(peerInfo)
          peer.wasDialed = true
          await initializeConnection(peer)
          connected = true
        except CatchableError as err:
          error "Failed to connect to bootstrap node",
                 node = bootstrapNode, err = err.msg

      if bootstrapNodes.len > 0 and connected == false:
        fatal "Failed to connect to any bootstrap node. Quitting."
        quit 1
    elif networkBackend == libp2p:
      for bootstrapNode in bootstrapEnrs:
        debug "Adding known peer", peer = bootstrapNode
        node.addKnownPeer bootstrapNode
      await node.start()

      proc checkIfConnectedToBootstrapNode {.async.} =
        await sleepAsync(30.seconds)
        if bootstrapEnrs.len > 0 and libp2p_successful_dials.value == 0:
          fatal "Failed to connect to any bootstrap node. Quitting", bootstrapEnrs
          quit 1

      traceAsyncErrors checkIfConnectedToBootstrapNode()

  proc saveConnectionAddressFile*(node: Eth2Node, filename: string) =
    when networkBackend == libp2p:
      writeFile(filename, $node.switch.peerInfo.addrs[0] & "/p2p/" &
                          node.switch.peerInfo.id)
    else:
      let id = waitFor node.daemon.identity()
      writeFile(filename, $id.addresses[0] & "/p2p/" & id.peer.pretty)

  func peersCount*(node: Eth2Node): int =
    when networkBackend == libp2p:
      len(node.peerPool)
    else:
      node.peers.len

  proc subscribe*[MsgType](node: Eth2Node,
                           topic: string,
                           msgHandler: proc(msg: MsgType) {.gcsafe.} ) {.async, gcsafe.} =
    template execMsgHandler(peerExpr, gossipBytes, gossipTopic) =
      inc gossip_messages_received
      trace "Incoming pubsub message received",
        peer = peerExpr, len = gossipBytes.len, topic = gossipTopic,
        message_id = `$`(sha256.digest(gossipBytes))
      msgHandler SSZ.decode(gossipBytes, MsgType)

    when networkBackend == libp2p:
      let incomingMsgHandler = proc(topic: string,
                                    data: seq[byte]) {.async, gcsafe.} =
        execMsgHandler "unknown", data, topic

      await node.switch.subscribe(topic, incomingMsgHandler)

    else:
      let incomingMsgHandler = proc(api: DaemonAPI,
                                    ticket: PubsubTicket,
                                    msg: PubSubMessage): Future[bool] {.async, gcsafe.} =
        execMsgHandler msg.peer, msg.data, msg.topics[0]
        return true

      discard await node.daemon.pubsubSubscribe(topic, incomingMsgHandler)

  proc traceMessage(fut: FutureBase, digest: MDigest[256]) =
    fut.addCallback do (arg: pointer):
      if not(fut.failed):
        trace "Outgoing pubsub message has been sent", message_id = `$`(digest)

  proc broadcast*(node: Eth2Node, topic: string, msg: auto) =
    inc gossip_messages_sent
    let broadcastBytes = SSZ.encode(msg)

    when networkBackend == libp2p:
      var fut = node.switch.publish(topic, broadcastBytes)
      traceMessage(fut, sha256.digest(broadcastBytes))
      traceAsyncErrors(fut)
    else:
      var fut = node.daemon.pubsubPublish(topic, broadcastBytes)
      traceMessage(fut, sha256.digest(broadcastBytes))
      traceAsyncErrors(fut)

  # TODO:
  # At the moment, this is just a compatiblity shim for the existing RLPx functionality.
  # The filtering is not implemented properly yet.
  iterator randomPeers*(node: Eth2Node, maxPeers: int, Protocol: type): Peer =
    var peers = newSeq[Peer]()
    for _, peer in pairs(node.peers): peers.add peer
    shuffle peers
    if peers.len > maxPeers: peers.setLen(maxPeers)
    for p in peers: yield p
else:
  {.fatal: "Unsupported network backend".}
