import NimQml

import
  ./slotlist,
  ../beacon_chain/[spec/eth2_apis/beacon_rpc_client]

QtObject:
  type
    EpochModel* = ref object of QObject
      client: RpcHttpClient
      epoch: int
      slotList: SlotList

  proc delete*(self: EpochModel) =
    self.QObject.delete

  proc setup*(self: EpochModel) =
    self.QObject.setup

  proc newEpochModel*(client: RpcHttpClient, epoch: int): EpochModel =
    let data = client.loadSlots(epoch.Epoch)
    let res = EpochModel(client: client, epoch: epoch, slotList: newSlotList(data))
    res.setup()
    res

  proc epoch*(self: EpochModel): int {.slot.} = self.epoch
  proc epochChanged*(self: EpochModel, v: int) {.signal.}
  QtProperty[int] epoch:
    read = epoch
    notify = epochChanged

  proc getSlotList*(self: EpochModel): QVariant {.slot.} = newQVariant(self.slotList)
  QtProperty[QVariant] slotList: read = getSlotList

  proc setNewData*(self: EpochModel, epoch: int, data: seq[SlotInfo]) =
    self.epoch = epoch
    self.epochChanged(epoch)

    self.slotList.setNewData(data)

  proc reload(self: EpochModel) {.slot.} =
    self.slotList.setNewData(self.client.loadSlots(self.epoch.Epoch))

  proc next(self: EpochModel) {.slot.} =
    self.epoch = self.epoch + 1
    self.epochChanged(self.epoch)
    self.reload() # TODO listen to epochchanged

  proc prev(self: EpochModel) {.slot.} =
    self.epoch = self.epoch - 1
    self.epochChanged(self.epoch)
    self.reload() # TODO listen to epochchanged
