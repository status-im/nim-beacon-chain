# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.
import std/[sequtils, strutils, os, tables, options]
import confutils, chronicles, chronos
import libp2p/[switch, builders, multiaddress, multicodec, peerinfo]
import libp2p/crypto/crypto as lcrypto
import libp2p/crypto/secp as lsecp
import libp2p/protocols/pubsub/[pubsub, gossipsub]
import eth/p2p/discoveryv5/enr as enr
import eth/p2p/discoveryv5/[protocol, node]
import eth/keys as ethkeys
import stew/[results, objects]
import stew/byteutils as bu
import stew/shims/net
import nimcrypto/[hash, keccak]
import secp256k1 as s
import stint
import snappy
import ssz_serialization/ssz
import ../beacon_chain/spec/[crypto, datatypes, network, digest]
import ../beacon_chain/ssz/spec_types

const
  InspectorName* = "Beacon-Chain Network Inspector"
  InspectorMajor*: int = 0
  InspectorMinor*: int = 0
  InspectorPatch*: int = 3
  InspectorVersion* = $InspectorMajor & "." & $InspectorMinor & "." &
                      $InspectorPatch
  InspectorIdent* = "Inspector/$1 ($2/$3)" % [InspectorVersion,
                                              hostCPU, hostOS]
  InspectorCopyright* = "Copyright(C) 2020" &
                        " Status Research & Development GmbH"
  InspectorHeader* = InspectorName & ", Version " & InspectorVersion &
                     " [" & hostOS & ": " & hostCPU & "]\r\n" &
                     InspectorCopyright & "\r\n"

  DISCV5BN* = mapAnd(UDP, mapEq("p2p"))
  ETH2BN* = mapAnd(TCP, mapEq("p2p"))

type
  DiscoveryProtocol* = protocol.Protocol

  ENRFieldPair* = object
    eth2: seq[byte]
    attnets: seq[byte]

  TopicFilter* {.pure.} = enum
    Blocks, Attestations, Exits, ProposerSlashing, AttesterSlashings

  BootstrapKind* {.pure.} = enum
    Enr, MultiAddr

  StartUpCommand* {.pure.} = enum
    noCommand

  BootstrapAddress* = object
    case kind*: BootstrapKind
    of BootstrapKind.Enr:
      addressRec: enr.Record
    of BootstrapKind.MultiAddr:
      addressMa: MultiAddress

  InspectorConf* = object
    logLevel* {.
      defaultValue: LogLevel.TRACE
      desc: "Sets the inspector's verbosity log level"
      abbr: "v"
      name: "verbosity" }: LogLevel

    fullPeerId* {.
      defaultValue: false
      desc: "Sets the inspector full PeerID output"
      abbr: "p"
      name: "fullpeerid" }: bool

    floodSub* {.
      defaultValue: true
      desc: "Sets inspector engine to FloodSub"
      abbr: "f"
      name: "floodsub" }: bool

    gossipSub* {.
      defaultValue: false
      desc: "Sets inspector engine to GossipSub"
      abbr: "g"
      name: "gossipsub" }: bool

    forkDigest* {.
      defaultValue: "",
      desc: "Sets the fork-digest value used to construct all topic names"
      name: "forkdigest"}: string

    signFlag* {.
      defaultValue: false
      desc: "Sets the inspector's to send/verify signatures in pubsub messages"
      abbr: "s"
      name: "sign" }: bool

    topics* {.
      desc: "Sets monitored topics, where `*` - all, " &
            "[a]ttestations, [b]locks, [e]xits, " &
            "[ps]roposer slashings, [as]ttester slashings"
      abbr: "t"
      name: "topics" }: seq[string]

    customTopics* {.
      desc: "Sets custom monitored topics"
      abbr: "c"
      name: "custom" }: seq[string]

    bootstrapFile* {.
      defaultValue: ""
      desc: "Specifies file which holds bootstrap nodes multiaddresses " &
            "delimeted by CRLF"
      abbr: "l"
      name: "bootfile" }: string

    bootstrapNodes* {.
      desc: "Specifies one or more bootstrap nodes" &
            " to use when connecting to the network"
      abbr: "b"
      name: "bootnodes" }: seq[string]

    decode* {.
      desc: "Try to decode message using SSZ"
      abbr: "d"
      defaultValue: false }: bool

    discoveryPort* {.
      desc: "DiscoveryV5 UDP port number"
      defaultValue: 9000 }: int

    ethPort* {.
      desc: "Ethereum2 TCP port number",
      defaultValue: 9000 }: int

    bindAddress* {.
      desc: "Bind Discovery to MultiAddress",
      defaultValue: "/ip4/0.0.0.0".}: string

    maxPeers* {.
      desc: "Maximum number of peers",
      defaultValue: 100.}: int

    noDiscovery* {.
      desc: "Disable discovery",
      defaultValue: false.}: bool

  StrRes[T] = Result[T, string]

func `==`(a, b: ENRFieldPair): bool =
  result = (a.eth2 == b.eth2)

func hasTCP(a: PeerInfo): bool =
  for ma in a.addrs:
    if TCP.match(ma):
      return true

func toNodeId(a: PeerID): Option[NodeId] =
  var buffer: array[64, byte]
  if a.hasPublicKey():
    var pubkey: lcrypto.PublicKey
    if extractPublicKey(a, pubkey):
      if pubkey.scheme == PKScheme.Secp256k1:
        let tmp = s.SkPublicKey(pubkey.skkey).toRaw()
        copyMem(addr buffer[0], unsafeAddr tmp[1], 64)
        result = some(readUintBE[256](keccak256.digest(buffer).data))

chronicles.formatIt PeerInfo: it.shortLog
chronicles.formatIt seq[PeerInfo]:
  var res = newSeq[string]()
  for item in it.items(): res.add($item.shortLog())
  "[" & res.join(", ") & "]"

func getTopics(forkDigest: ForkDigest,
               filter: TopicFilter): seq[string] =
  case filter
  of TopicFilter.Blocks:
    let topic = getBeaconBlocksTopic(forkDigest)
    @[topic & "_snappy"]
  of TopicFilter.Exits:
    let topic = getVoluntaryExitsTopic(forkDigest)
    @[topic & "_snappy"]
  of TopicFilter.ProposerSlashing:
    let topic = getProposerSlashingsTopic(forkDigest)
    @[topic & "_snappy"]
  of TopicFilter.AttesterSlashings:
    let topic = getAttesterSlashingsTopic(forkDigest)
    @[topic & "_snappy"]
  of TopicFilter.Attestations:
    mapIt(
      0'u64 ..< ATTESTATION_SUBNET_COUNT.uint64,
      getAttestationTopic(forkDigest, SubnetId(it)) & "_snappy")

proc loadBootFile(name: string): seq[string] =
  try:
    result = readFile(name).splitLines()
  except:
    discard

func unpackYmlLine(line: string): string =
  result = line
  let stripped = line.strip()
  var parts = stripped.split({'"'})
  if len(parts) == 3:
    if parts[0].startsWith("-") and len(parts[2]) == 0:
      result = parts[1]

proc getBootstrapAddress(bootnode: string): Option[BootstrapAddress] =
  var rec: enr.Record
  try:
    var stripped = bootnode.strip()
    if stripped.startsWith("-"):
      stripped = unpackYmlLine(stripped)
    if len(stripped) > 0:
      if stripped.startsWith("enr:"):
        if fromURI(rec, EnrUri(stripped)):
          let res = BootstrapAddress(kind: BootstrapKind.Enr, addressRec: rec)
          return some(res)
        else:
          warn "Incorrect or empty ENR bootstrap address", address = stripped
      else:
        let maRes = MultiAddress.init(stripped)
        let ma = if maRes.isOk: maRes.get
                 else: return
        if ETH2BN.match(ma) or DISCV5BN.match(ma):
          let res = BootstrapAddress(kind: BootstrapKind.MultiAddr,
                                     addressMa: ma)
          return some(res)
        else:
          warn "Incorrect MultiAddress bootstrap address", address = stripped
  except CatchableError as exc:
    warn "Incorrect bootstrap address", address = bootnode, errMsg = exc.msg

func tryGetForkDigest(bootnode: enr.Record): Option[ForkDigest] =
  let sszForkData = bootnode.tryGet("eth2", seq[byte])
  if sszForkData.isSome():
    try:
      let forkId = SSZ.decode(sszForkData.get(), ENRForkID)
      result = some(forkId.fork_digest)
    except CatchableError:
      discard

func tryGetFieldPairs(bootnode: enr.Record): Option[ENRFieldPair] =
  var sszEth2 = bootnode.tryGet("eth2", seq[byte])
  var sszAttnets = bootnode.tryGet("attnets", seq[byte])
  if sszEth2.isSome() and sszAttnets.isSome():
    result = some(ENRFieldPair(eth2: sszEth2.get(),
                               attnets: sszAttnets.get()))

func tryGetForkDigest(hexdigest: string): Option[ForkDigest] =
  var res: ForkDigest
  if len(hexdigest) > 0:
    try:
      hexToByteArray(hexdigest, array[4 ,byte](res))
      result = some(res)
    except CatchableError:
      discard

func tryGetMultiAddress(address: string): Option[MultiAddress] =
  let maRes = MultiAddress.init(address)
  let ma = if maRes.isOk: maRes.get
           else: return
  if IP4.match(ma) or IP6.match(ma):
    result = some(ma)

proc loadBootstrapNodes(conf: InspectorConf): seq[BootstrapAddress] =
  result = newSeq[BootstrapAddress]()

  if len(conf.bootstrapFile) > 0:
    info "Loading bootstrap nodes from file", filename = conf.bootstrapFile
    var nodes = loadBootFile(conf.bootstrapFile)
    for nodeString in nodes:
      let res = getBootstrapAddress(nodeString)
      if res.isSome():
        result.add(res.get())

  for nodeString in conf.bootstrapNodes:
    let res = getBootstrapAddress(nodeString)
    if res.isSome():
      result.add(res.get())

proc init(p: typedesc[PeerInfo],
          maddr: MultiAddress): StrRes[PeerInfo] =
  ## Initialize PeerInfo using address which includes PeerID.
  if IPFS.match(maddr):
    let peerid = ? protoAddress(? maddr[2])
    result = ok(PeerInfo.init(
      ? (PeerID.init(peerid).mapErr(proc (v: cstring): string = $v)),
      [(? maddr[0]) & (? maddr[1])]))

proc init(p: typedesc[PeerInfo],
           enraddr: enr.Record): StrRes[PeerInfo] =
  var trec: enr.TypedRecord
  try:
    let trecOpt = enraddr.toTypedRecord()
    if trecOpt.isOk():
      trec = trecOpt.get()
      if trec.secp256k1.isSome():
        let skpubkey = ethkeys.PublicKey.fromRaw(trec.secp256k1.get())
        if skpubkey.isOk():
          let peerid = PeerID.init(
            PublicKey(scheme: Secp256k1,
                      skkey: lsecp.SkPublicKey(skpubkey.get())))
          var mas = newSeq[MultiAddress]()
          if trec.ip.isSome() and trec.tcp.isSome():
            let ma = (? MultiAddress.init(multiCodec("ip4"), trec.ip.get())) &
                     (? MultiAddress.init(multiCodec("tcp"), trec.tcp.get()))
            mas.add(ma)
          if trec.ip6.isSome() and trec.tcp6.isSome():
            let ma = (? MultiAddress.init(multiCodec("ip6"), trec.ip6.get())) &
                     (? MultiAddress.init(multiCodec("tcp"), trec.tcp6.get()))
            mas.add(ma)
          if trec.ip.isSome() and trec.udp.isSome():
            let ma = (? MultiAddress.init(multiCodec("ip4"), trec.ip.get())) &
                     (? MultiAddress.init(multiCodec("udp"), trec.udp.get()))
            mas.add(ma)
          if trec.ip6.isSome() and trec.udp6.isSome():
            let ma = (? MultiAddress.init(multiCodec("ip6"), trec.ip6.get())) &
                     (? MultiAddress.init(multiCodec("udp"), trec.udp6.get()))
            mas.add(ma)
          result = ok PeerInfo.init(peerid.tryGet(), mas)
  except CatchableError as exc:
    warn "Error", errMsg = exc.msg, record = enraddr.toUri()

proc connectToNetwork(switch: Switch, nodes: seq[PeerInfo],
                      timeout: Duration): Future[seq[PeerInfo]] {.async.} =
  var pending = newSeq[Future[void]]()
  var res = newSeq[PeerInfo]()
  var timed, succeed, failed: int

  for pinfo in nodes:
    pending.add(switch.connect(pinfo.peerId, pinfo.addrs))

  debug "Connecting to peers", count = $len(pending), peers = nodes

  if len(pending) > 0:
    var timer = sleepAsync(timeout)
    discard await one(timer, allFutures(pending))
    for i in 0 ..< len(pending):
      let fut = pending[i]
      if fut.finished():
        if fut.failed():
          inc(failed)
          warn "Unable to connect to node", address = nodes[i],
               errMsg = fut.readError().msg
        else:
          inc(succeed)
          info "Connected to node", address = nodes[i]
          res.add(nodes[i])
      else:
        inc(timed)
        fut.cancel()
        warn "Connection to node timed out", address = nodes[i]

  debug "Connection statistics", succeed = succeed, failed = failed,
                                 timeout = timed, count = $len(pending)

  result = res

proc connectLoop(switch: Switch,
                 peerQueue: AsyncQueue[PeerInfo],
                 peerTable: TableRef[PeerID, PeerInfo],
                 timeout: Duration): Future[void] {.async.} =
  var addresses = newSeq[PeerInfo]()
  trace "Starting connection loop", queue_size = len(peerQueue),
                                    table_size = len(peerTable),
                                    timeout = timeout
  while true:
    if len(addresses) > 0:
      addresses.setLen(0)
    let ma = await peerQueue.popFirst()
    addresses.add(ma)
    while not(peerQueue.empty()):
      addresses.add(peerQueue.popFirstNoWait())
    trace "Got new peers", count = len(addresses)
    var infos = await switch.connectToNetwork(addresses, timeout)
    for item in infos:
      peerTable[item.peerId] = item

func toIpAddress(ma: MultiAddress): Option[ValidIpAddress] =
  if IP4.match(ma):
    let addressRes = ma.protoAddress()
    let address = if addressRes.isOk: addressRes.get
                  else: return
    result = some(ipv4 toArray(4, address))
  elif IP6.match(ma):
    let addressRes = ma.protoAddress()
    let address = if addressRes.isOk: addressRes.get
                  else: return
    result = some(ipv6 toArray(16, address))

proc bootstrapDiscovery(conf: InspectorConf,
                        host: MultiAddress,
                        privkey: lcrypto.PrivateKey,
                        bootnodes: seq[enr.Record],
                        enrFields: Option[ENRFieldPair]): DiscoveryProtocol =
  var pk = ethkeys.PrivateKey(privkey.skkey)
  let udpPort = Port(conf.discoveryPort)
  let tcpPort = Port(conf.ethPort)
  let host = host.toIpAddress()
  if enrFields.isSome():
    let fields = enrFields.get()
    let pairs = {"eth2": fields.eth2, "attnets": fields.attnets}
    result = newProtocol(pk, host, some(tcpPort), some(udpPort), pairs,
      bootnodes, bindPort = udpPort)
  else:
    result = newProtocol(pk, host, some(tcpPort), some(udpPort), [],
      bootnodes, bindPort = udpPort)
  result.open()
  result.start()

proc logEnrAddress(address: string) =
  var
    rec: enr.Record
    trec: enr.TypedRecord
    eth2fork_digest, eth2next_fork_version, eth2next_fork_epoch: string
    attnets: string

  if fromURI(rec, EnrUri(address)):
    var eth2Data = rec.tryGet("eth2", seq[byte])
    var attnData = rec.tryGet("attnets", seq[byte])
    var optrec = rec.toTypedRecord()

    if optrec.isOk():
      trec = optrec.get()

      if eth2Data.isSome():
        try:
          var forkid = SSZ.decode(eth2Data.get(), ENRForkID)
          eth2fork_digest = $forkid.fork_digest
          eth2next_fork_version = $forkid.next_fork_version
          eth2next_fork_epoch = strutils.toHex(uint64(forkid.next_fork_epoch))
        except CatchableError:
          eth2fork_digest = "Error"
          eth2next_fork_version = "Error"
          eth2next_fork_epoch = "Error"
      else:
        eth2fork_digest = "None"
        eth2next_fork_version = "None"
        eth2next_fork_epoch = "None"

      if attnData.isSome():
        var attn = SSZ.decode(attnData.get(), List[byte, 9999999]) # TODO: what's the limit on that list?
        attnets = bu.toHex(attn.asSeq)
      else:
        attnets = "None"

      info "ENR bootstrap address fileds",
        enr_uri = address,
        enr_id = trec.id,
        secp256k1 = if trec.secp256k1.isSome():
            bu.toHex(trec.secp256k1.get())
          else:
            "None",
        ip4 = if trec.ip.isSome():
            $MultiAddress.init(multiCodec("ip4"), trec.ip.get())
          else:
            "None",
        ip6 = if trec.ip6.isSome():
            $MultiAddress.init(multiCodec("ip6"), trec.ip6.get())
          else:
            "None",
        tcp = if trec.tcp.isSome(): $trec.tcp.get() else: "None",
        udp = if trec.udp.isSome(): $trec.udp.get() else: "None",
        tcp6 = if trec.tcp6.isSome(): $trec.tcp6.get() else: "None",
        udp6 = if trec.udp6.isSome(): $trec.udp6.get() else: "None",
        eth2_fork_digest = eth2fork_digest,
        eth2_next_fork_version = eth2next_fork_version,
        eth2_next_fork_epoch = eth2next_fork_epoch,
        eth2_attnets = attnets
    else:
      info "ENR bootstrap address is wrong or incomplete", enr_uri = address
  else:
    info "ENR bootstrap address is wrong or incomplete", enr_uri = address

func init(p: typedesc[PeerInfo],
          enruri: EnrUri): Option[PeerInfo] =
  var rec: enr.Record
  if fromURI(rec, enruri):
    logEnrAddress(rec.toUri())
    result = PeerInfo.init(rec)

proc pubsubLogger(conf: InspectorConf, switch: Switch,
                  resolveQueue: AsyncQueue[PeerID], topic: string,
                  data: seq[byte]): Future[void] {.async.} =
  info "Received pubsub message", size = len(data),
                                  topic = topic,
                                  message = bu.toHex(data)
  var buffer: seq[byte]
  if conf.decode:
    if topic.endsWith("_snappy"):
      try:
        buffer = snappy.decode(data, GOSSIP_MAX_SIZE)
      except CatchableError as exc:
        warn "Unable to decompress message", errMsg = exc.msg
    else:
      buffer = data

    try:
      if topic.endsWith(topicBeaconBlocksSuffix & "_snappy"):
        info "SignedBeaconBlock", msg = SSZ.decode(buffer, SignedBeaconBlock)
      elif topic.endsWith("_snappy") and topic.contains("/beacon_attestation_"):
        info "Attestation", msg = SSZ.decode(buffer, Attestation)
      elif topic.endsWith(topicVoluntaryExitsSuffix & "_snappy"):
        info "SignedVoluntaryExit", msg = SSZ.decode(buffer,
                                                     SignedVoluntaryExit)
      elif topic.endsWith(topicProposerSlashingsSuffix & "_snappy"):
        info "ProposerSlashing", msg = SSZ.decode(buffer, ProposerSlashing)
      elif topic.endsWith(topicAttesterSlashingsSuffix & "_snappy"):
        info "AttesterSlashing", msg = SSZ.decode(buffer, AttesterSlashing)
      elif topic.endsWith(topicAggregateAndProofsSuffix & "_snappy"):
        info "AggregateAndProof", msg = SSZ.decode(buffer, AggregateAndProof)

    except CatchableError as exc:
      info "Unable to decode message", errMsg = exc.msg

proc resolveLoop(conf: InspectorConf,
                 discovery: DiscoveryProtocol,
                 switch: Switch,
                 peerQueue: AsyncQueue[PeerID],
                 peers: TableRef[PeerID, PeerInfo]) {.async.} =
  debug "Starting resolution loop"
  while true:
    let peerId = await peerQueue.popFirst()
    let idOpt = peerId.toNodeId()
    if idOpt.isSome():
      try:
        let nodeOpt = await discovery.resolve(idOpt.get())
        if nodeOpt.isSome():
          let peerOpt = PeerInfo.init(nodeOpt.get().record)
          if peerOpt.isOk():
            let peer = peerOpt.get()
            trace "Peer resolved", peer_id = peerId,
                                   node_id = idOpt.get(),
                                   peer_info = peer
            peers[peerId] = peer
          else:
            warn "Peer's record is invalid", peer_id = peerId,
                                             node_id = idOpt.get(),
                                             peer_record = nodeOpt.get().record
        else:
          trace "Node resolution returns empty answer", peer_id = peerId,
                                                       node_id = idOpt.get()

      except CatchableError as exc:
        warn "Node address resolution failed", errMsg = exc.msg,
                                               peer_id = peerId,
                                               node_id = idOpt.get()

proc discoveryLoop(conf: InspectorConf,
                   discovery: DiscoveryProtocol,
                   switch: Switch,
                   connQueue: AsyncQueue[PeerInfo],
                   peers: TableRef[PeerID, PeerInfo]) {.async.} =
  debug "Starting discovery loop"
  let wantedPeers = conf.maxPeers
  while true:
    try:
      let discoveredPeers = discovery.randomNodes(wantedPeers - len(peers))
      for peer in discoveredPeers:
        let pinfoOpt = PeerInfo.init(peer.record)
        if pinfoOpt.isOk():
          let pinfo = pinfoOpt.get()
          if pinfo.hasTCP():
            if not switch.isConnected(pinfo.peerId):
              debug "Discovered new peer", peer = pinfo,
                                           peers_count = len(peers)
              await connQueue.addLast(pinfo)
          else:
            debug "Found discovery only peer", peer = pinfo

    except CatchableError as exc:
      debug "Error in discovery", errMsg = exc.msg

    await sleepAsync(1.seconds)

proc run(conf: InspectorConf) {.async.} =
  var
    topics: set[TopicFilter] = {}
    forkDigest: Option[ForkDigest]
    enrFields: Option[ENRFieldPair]

  var pubsubPeers = newTable[PeerID, PeerInfo]()
  var resolveQueue = newAsyncQueue[PeerID](10)
  var connectQueue = newAsyncQueue[PeerInfo](10)
  let rng = lcrypto.newRng()

  let bootnodes = loadBootstrapNodes(conf)
  if len(bootnodes) == 0:
    error "Not enough bootnodes to establish connection with network"
    quit(1)

  var eth2bootnodes = newSeq[PeerInfo]()
  var disc5bootnodes = newSeq[enr.Record]()

  for item in bootnodes:
    if item.kind == BootstrapKind.Enr:
      logEnrAddress(item.addressRec.toUri())

      let pinfoOpt = PeerInfo.init(item.addressRec)
      if pinfoOpt.isOk():
        let pinfo = pinfoOpt.get()
        for ma in pinfo.addrs:
          if TCP.match(ma):
            eth2bootnodes.add(pinfo)
            break
        for ma in pinfo.addrs:
          if UDP.match(ma):
            disc5bootnodes.add(item.addressRec)
            break

      let forkOpt = tryGetForkDigest(item.addressRec)
      if forkOpt.isSome():
        if forkDigest.isSome():
          if forkDigest.get() != forkOpt.get():
            warn "Bootstrap node address has different forkDigest",
                 address = item.addressRec.toUri(),
                 address_fork_digest = $(forkOpt.get()),
                 stored_fork_digest = $(forkDigest.get())
        else:
          forkDigest = forkOpt

      let enrFieldsOpt = tryGetFieldPairs(item.addressRec)
      if enrFieldsOpt.isSome():
        if enrFields.isSome():
          if enrFields.get() != enrFieldsOpt.get():
            warn "Bootstrap node address has different eth2 values",
                 address = item.addressRec.toUri(),
                 eth2_field_stored = bu.toHex(enrFields.get().eth2),
                 eth2_field_address = bu.toHex(enrFieldsOpt.get().eth2)
        else:
          enrFields = enrFieldsOpt

    elif item.kind == BootstrapKind.MultiAddr:
      if ETH2BN.match(item.addressMa):
        eth2bootnodes.add(PeerInfo.init(item.addressMa).get())

  if len(eth2bootnodes) == 0:
    error "Not enough Ethereum2 bootnodes to establish connection with network"
    quit(1)

  if len(disc5bootnodes) == 0:
    warn "Not enough DiscoveryV5 bootnodes, discovery will be disabled"

  var argForkDigest = tryGetForkDigest(conf.forkDigest)

  if forkDigest.isNone():
    if argForkDigest.isNone():
      error "forkDigest argument and bootstrap forkDigest are missing"
      quit(1)
    else:
      forkDigest = argForkDigest
  else:
    if argForkDigest.isSome():
      if forkDigest.isSome() != argForkDigest.isSome():
        warn "forkDigest argument value is different, using argument value",
             argument_fork_digest = argForkDigest.get(),
             bootstrap_fork_digest = forkDigest.get()
        forkDigest = argForkDigest

  let seckey = lcrypto.PrivateKey.random(PKScheme.Secp256k1, rng[]).tryGet()
  # let pubkey = seckey.getKey()

  let hostAddress = tryGetMultiAddress(conf.bindAddress)
  if hostAddress.isNone():
    error "Bind address is incorrect MultiAddress", address = conf.bindAddress
    quit(1)

  let switch = newStandardSwitch(some(seckey), hostAddress.get(), rng = rng)

  let pubsub = GossipSub.init(
    switch = switch,
    triggerSelf = true, sign = false,
    verifySignature = false).PubSub

  switch.mount(pubsub)

  if len(conf.topics) > 0:
    for item in conf.topics:
      let lcitem = item.toLowerAscii()

      if lcitem == "*":
        topics.incl({TopicFilter.Blocks, TopicFilter.Attestations,
                     TopicFilter.Exits, TopicFilter.ProposerSlashing,
                     TopicFilter.AttesterSlashings})
        break
      elif lcitem == "a":
        topics.incl(TopicFilter.Attestations)
      elif lcitem == "b":
        topics.incl(TopicFilter.Blocks)
      elif lcitem == "e":
        topics.incl(TopicFilter.Exits)
      elif lcitem == "ps":
        topics.incl(TopicFilter.ProposerSlashing)
      elif lcitem == "as":
        topics.incl(TopicFilter.AttesterSlashings)
      else:
        discard
  else:
    topics.incl({TopicFilter.Blocks, TopicFilter.Attestations,
                 TopicFilter.Exits, TopicFilter.ProposerSlashing,
                 TopicFilter.AttesterSlashings})

  proc pubsubTrampoline(topic: string,
                        data: seq[byte]): Future[void] {.gcsafe.} =
    result = pubsubLogger(conf, switch, resolveQueue, topic, data)

  discard await switch.start()
  await pubsub.start()

  var topicFilters = newSeq[string]()
  try:
    for filter in topics:
      for topic in getTopics(forkDigest.get(), filter):
        pubsub.subscribe(topic, pubsubTrampoline)
        topicFilters.add(topic)
        trace "Subscribed to topic", topic = topic
    for filter in conf.customTopics:
      pubsub.subscribe(filter, pubsubTrampoline)
      topicFilters.add(filter)
      trace "Subscribed to custom topic", topic = filter
  except CatchableError as exc:
    error "Could not subscribe to topics", errMsg = exc.msg
    quit(1)

  info InspectorIdent & " starting", topic_filters = topicFilters,
                                     eth2_bootnodes = eth2bootnodes,
                                     disc5_bootnodes = disc5bootnodes

  asyncCheck connectLoop(switch, connectQueue,
                         pubsubPeers, 10.seconds)

  for node in eth2bootnodes:
    await connectQueue.addLast(node)

  if len(disc5bootnodes) > 0:
    var proto = bootstrapDiscovery(conf, hostAddress.get(), seckey,
                                   disc5bootnodes, enrFields)
    if not(conf.noDiscovery):
      asyncCheck discoveryLoop(conf, proto, switch, connectQueue,
                               pubsubPeers)

    asyncCheck resolveLoop(conf, proto, switch, resolveQueue,
                           pubsubPeers)

  # We are not going to exit from this procedure
  var emptyFut = newFuture[void]()
  await emptyFut

when isMainModule:
  echo InspectorHeader
  var conf = InspectorConf.load(version = InspectorVersion)
  waitFor run(conf)
