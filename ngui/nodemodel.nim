import NimQml

import
  std/[sequtils, json, times],
  NimQml,
  ../beacon_chain/eth2_json_rpc_serialization,
  ../beacon_chain/spec/[datatypes, crypto],
  ./attestationlist, ./utils,
  ../beacon_chain/[spec/eth2_apis/beacon_rpc_client]

template xxx(body): string =
  try:
    $(body)
  except CatchableError as exc:
    exc.msg

QtObject:
  type
    NodeModel* = ref object of QObject
      client: RpcHttpClient
      genesis: string
      attestations: string
      attester_slashings: string
      proposer_slashings: string
      voluntary_exits: string
      heads: string
      identity: string
      version: string
      health: string

  proc delete*(self: NodeModel) =
    self.QObject.delete

  proc setup*(self: NodeModel) =
    self.QObject.setup

  proc newNodeModel*(client: RpcHttpClient): NodeModel =
    let res = NodeModel(client: client)
    res.setup()
    res

  proc getGenesis*(self: NodeModel): string {.slot.} = self.genesis
  proc genesisChanged*(self: NodeModel, v: string) {.signal.}
  proc setGenesis*(self: NodeModel, v: string) =
    self.genesis = v
    self.genesisChanged(v)
  QtProperty[string] genesis:
    read = getgenesis
    notify = genesisChanged
    write = setgenesis

  proc getattestations*(self: NodeModel): string {.slot.} = self.attestations
  proc attestationsChanged*(self: NodeModel, v: string) {.signal.}
  proc setattestations*(self: NodeModel, v: string) =
    self.attestations = v
    self.attestationsChanged(v)
  QtProperty[string] attestations:
    read = getattestations
    notify = attestationsChanged
    write = setattestations

  proc getattester_slashings*(self: NodeModel): string {.slot.} = self.attester_slashings
  proc attester_slashingsChanged*(self: NodeModel, v: string) {.signal.}
  proc setattester_slashings*(self: NodeModel, v: string) =
    self.attester_slashings = v
    self.attester_slashingsChanged(v)
  QtProperty[string] attester_slashings:
    read = getattester_slashings
    notify = attester_slashingsChanged
    write = setattester_slashings

  proc getproposer_slashings*(self: NodeModel): string {.slot.} = self.proposer_slashings
  proc proposer_slashingsChanged*(self: NodeModel, v: string) {.signal.}
  proc setproposer_slashings*(self: NodeModel, v: string) =
    self.proposer_slashings = v
    self.proposer_slashingsChanged(v)
  QtProperty[string] proposer_slashings:
    read = getproposer_slashings
    notify = proposer_slashingsChanged
    write = setproposer_slashings

  proc getvoluntary_exits*(self: NodeModel): string {.slot.} = self.voluntary_exits
  proc voluntary_exitsChanged*(self: NodeModel, v: string) {.signal.}
  proc setvoluntary_exits*(self: NodeModel, v: string) =
    self.voluntary_exits = v
    self.voluntary_exitsChanged(v)
  QtProperty[string] voluntary_exits:
    read = getvoluntary_exits
    notify = voluntary_exitsChanged
    write = setvoluntary_exits

  proc getheads*(self: NodeModel): string {.slot.} = self.heads
  proc headsChanged*(self: NodeModel, v: string) {.signal.}
  proc setheads*(self: NodeModel, v: string) =
    self.heads = v
    self.headsChanged(v)
  QtProperty[string] heads:
    read = getheads
    notify = headsChanged
    write = setheads

  proc getidentity*(self: NodeModel): string {.slot.} = self.identity
  proc identityChanged*(self: NodeModel, v: string) {.signal.}
  proc setidentity*(self: NodeModel, v: string) =
    self.identity = v
    self.identityChanged(v)
  QtProperty[string] identity:
    read = getidentity
    notify = identityChanged
    write = setidentity

  proc getversion*(self: NodeModel): string {.slot.} = self.version
  proc versionChanged*(self: NodeModel, v: string) {.signal.}
  proc setversion*(self: NodeModel, v: string) =
    self.version = v
    self.versionChanged(v)
  QtProperty[string] version:
    read = getversion
    notify = versionChanged
    write = setversion

  proc gethealth*(self: NodeModel): string {.slot.} = self.health
  proc healthChanged*(self: NodeModel, v: string) {.signal.}
  proc sethealth*(self: NodeModel, v: string) =
    self.health = v
    self.healthChanged(v)
  QtProperty[string] health:
    read = gethealth
    notify = healthChanged
    write = sethealth

  proc update*(self: NodeModel) {.slot.} =
    self.setgenesis(xxx(waitFor self.client.get_v1_beacon_genesis()))
    self.setattestations(xxx(waitFor self.client.get_v1_beacon_pool_attestations(none(uint64), none(uint64))))
    self.setattester_slashings(xxx(waitFor self.client.get_v1_beacon_pool_attester_slashings()))
    self.setproposer_slashings(xxx(waitFor self.client.get_v1_beacon_pool_proposer_slashings()))
    self.setvoluntary_exits(xxx(waitFor self.client.get_v1_beacon_pool_voluntary_exits()))
    self.setheads(xxx(waitFor self.client.get_v1_debug_beacon_heads()))
    self.setidentity(xxx(waitFor self.client.get_v1_node_identity()))
    self.setversion(xxx(waitFor self.client.get_v1_node_version()))
    self.sethealth(xxx(waitFor self.client.get_v1_node_health()))
