import
  std/[tables],
  NimQml,
  ../beacon_chain/spec/[helpers, eth2_apis/beacon_rpc_client],
  ../beacon_chain/ssz/merkleization,
  ./objecttablemodel, ./utils

type
  AttestationInfo* = object
    slot*: int
    index*: int
    beacon_block_root*: string
    source_epoch*: int
    source_root*: string
    target_epoch*: int
    target_root*: string
    aggregation_bits*: string

proc toAttestationInfo*(v: Attestation): AttestationInfo =
  AttestationInfo(
    slot: v.data.slot.int,
    index: v.data.index.int,
    beacon_block_root: toBlockLink(v.data.beacon_block_root),
    source_epoch: v.data.source.epoch.int,
    source_root: toBlockLink(v.data.source.root),
    target_epoch: v.data.target.epoch.int,
    target_root: toBlockLink(v.data.target.root),
    aggregation_bits: $v.aggregation_bits,
  )

QtObject:
  type AttestationList* = ref object of QAbstractTableModel
    # TODO this could be a generic ObjectTableModel, except generics + method don't work..
    data: ObjectTableModelImpl[AttestationInfo]

  proc setup(self: AttestationList) = self.QAbstractTableModel.setup

  proc delete(self: AttestationList) =
    self.QAbstractTableModel.delete

  proc newAttestationList*(data: seq[AttestationInfo]): AttestationList =
    new(result, delete)
    result.data = ObjectTableModelImpl[AttestationInfo](items: data)
    result.setup

  method rowCount(self: AttestationList, index: QModelIndex = nil): int =
    self.data.rowCount(index)

  method columnCount(self: AttestationList, index: QModelIndex = nil): int =
    self.data.columnCount(index)

  method headerData*(self: AttestationList, section: int, orientation: QtOrientation, role: int): QVariant =
    self.data.headerData(section, orientation, role)

  method data(self: AttestationList, index: QModelIndex, role: int): QVariant =
    self.data.data(index, role)

  method roleNames(self: AttestationList): Table[int, string] =
    self.data.roleNames()

  proc setNewData*(self: AttestationList, v: seq[AttestationInfo]) =
    self.data.setNewData(self, v)

  proc sort*(self: AttestationList, section: int) {.slot.} =
    self.data.sort(self, section)
