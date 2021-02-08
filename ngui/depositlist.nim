import
  std/[tables],
  NimQml,
  ../beacon_chain/spec/[eth2_apis/beacon_rpc_client],
  ./objecttablemodel, ./utils

type
  DepositInfo* = object
    pubkey*: string
    withdrawal_credentials*: string
    amount*: uint64
    signature*: string

proc toDepositInfo*(v: Deposit): DepositInfo =
  DepositInfo(
    pubkey: toDisplayHex(v.data.pubkey.toRaw()),
    withdrawal_credentials: toDisplayHex(v.data.withdrawal_credentials),
    amount: v.data.amount,
    signature: toDisplayHex(v.data.signature),
  )

QtObject:
  type DepositList* = ref object of QAbstractTableModel
    # TODO this could be a generic ObjectTableModel, except generics + method don't work..
    data: ObjectTableModelImpl[DepositInfo]

  proc setup(self: DepositList) = self.QAbstractTableModel.setup

  proc delete(self: DepositList) =
    self.QAbstractTableModel.delete

  proc newDepositList*(data: seq[DepositInfo]): DepositList =
    new(result, delete)
    result.data = ObjectTableModelImpl[DepositInfo](items: data)
    result.setup

  method rowCount(self: DepositList, index: QModelIndex = nil): int =
    self.data.rowCount(index)

  method columnCount(self: DepositList, index: QModelIndex = nil): int =
    self.data.columnCount(index)

  method headerData*(self: DepositList, section: int, orientation: QtOrientation, role: int): QVariant =
    self.data.headerData(section, orientation, role)

  method data(self: DepositList, index: QModelIndex, role: int): QVariant =
    self.data.data(index, role)

  method roleNames(self: DepositList): Table[int, string] =
    self.data.roleNames()

  proc setNewData*(self: DepositList,  v: seq[DepositInfo]) =
    self.data.setNewData(self, v)

  proc sort*(self: DepositList, section: int) {.slot.} =
    self.data.sort(self, section)
