import
  NimQml, blockmodel, footermodel, epochmodel, peerlist, slotlist, nodemodel

import
  std/[os, strutils],
  chronos, metrics, json_rpc/[rpcclient],

  # Local modules
  ../beacon_chain/spec/[datatypes, digest, crypto, helpers],
  ../beacon_chain/[spec/eth2_apis/beacon_rpc_client]

QtObject:
  type MainModel* = ref object of QObject
    app: QApplication
    blck: BlockModel
    footer: FooterModel
    client: RpcHttpClient
    peerList: PeerList
    epochModel: EpochModel
    nodeModel: NodeModel

    genesis: BeaconGenesisTuple
    currentIndex: int

  proc delete*(self: MainModel) =
    self.QObject.delete
    self.blck.delete

  proc setup(self: MainModel) =
    self.QObject.setup
    self.blck.setup

  proc newMainModel*(app: QApplication): MainModel =
    let
      client = newRpcHttpClient()

    waitFor client.connect("localhost", Port(8190))

    let
      headBlock = waitFor client.get_v1_beacon_blocks_blockId("head")
      epoch = headBlock.message.slot.epoch
      genesis = waitFor client.get_v1_beacon_genesis()
      peerList = newPeerList(@[])

    peerList.setNewData(waitFor client.get_v1_node_peers(some(newseq[string]()), some(newseq[string]())))

    let res = MainModel(
      app: app,
      blck: newBlockModel(headBlock, genesis.genesis_time),
      client: client,
      footer: newFooterModel(),
      peerList: peerList,
      epochModel: newEpochModel(client, epoch.int),
      nodeModel: newNodeModel(client),
      genesis: genesis,
    )
    res.setup()
    res

  proc onLoadTriggered(self: MainModel) {.slot.} =
    echo "Load Triggered"

  proc onSaveTriggered(self: MainModel) {.slot.} =
    echo "Save Triggered"

  proc onExitTriggered(self: MainModel) {.slot.} =
    self.app.quit

  proc updateFooter(self: MainModel) {.slot.} =
    let
      checkpoints = waitFor self.client.get_v1_beacon_states_finality_checkpoints("head")
      head = waitFor self.client.get_v1_beacon_headers_blockId("head")
      syncing = waitFor self.client.get_v1_node_syncing()

    self.footer.finalized = $shortLog(checkpoints.finalized)
    self.footer.head = $shortLog(head.header.message.slot)
    self.footer.syncing = $syncing

  proc updateSlots(self: MainModel) {.slot.} =
    let
      slots = self.client.loadSlots(self.epochModel.epoch.Epoch)
    self.epochModel.setNewData(self.epochModel.epoch.int, slots)

  proc updatePeers(self: MainModel) {.slot.} =
    self.peerList.setNewData(waitFor self.client.get_v1_node_peers(some(newseq[string]()), some(newseq[string]())))

  proc getPeerList*(self: MainModel): QVariant {.slot.} =
    newQVariant(self.peerList)
  QtProperty[QVariant] peerList:
    read = getPeerList

  proc getFooter*(self: MainModel): QVariant {.slot.} =
    newQVariant(self.footer)
  QtProperty[QVariant] footer:
    read = getFooter

  proc getEpochModel*(self: MainModel): QVariant {.slot.} =
    newQVariant(self.epochModel)
  QtProperty[QVariant] epochModel:
    read = getEpochModel

  proc getBlck(self: MainModel): QVariant {.slot.} = newQVariant(self.blck)
  proc blckChanged*(self: MainModel, blck: QVariant) {.signal.}
  proc setBlck(self: MainModel, blck: SignedBeaconBlock) =
    self.blck.blck = blck
    self.blckChanged(newQVariant(self.blck))

  QtProperty[QVariant] blck:
    read = getBlck
    write = setBlck
    notify = blckChanged

  proc getCurrentIndex(self: MainModel): int {.slot.} = self.currentIndex
  proc currentIndexChanged*(self: MainModel, v: int) {.signal.}
  proc setCurrentIndex(self: MainModel, v: int) =
    self.currentIndex = v
    self.currentIndexChanged(v)

  QtProperty[int] currentIndex:
    read = getCurrentIndex
    write = setCurrentIndex
    notify = currentIndexChanged

  proc getNodeModel(self: MainModel): QVariant {.slot.} = newQVariant(self.nodeModel)
  QtProperty[QVariant] nodeModel:
    read = getNodeModel

  proc onLoadBlock(self: MainModel, root: string) {.slot.} =
    try:
      let blck = waitFor self.client.get_v1_beacon_blocks_blockId(root)
      self.setBlck(blck)
    except CatchableError as exc:
      echo exc.msg

  proc openUrl(self: MainModel, url: string) {.slot.} =
    if url.startsWith("block://"):
      self.onLoadBlock(url[8..^1])
      self.setCurrentIndex(1)
