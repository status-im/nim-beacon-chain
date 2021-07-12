{.push raises: [Defect].}

import NimQml

import
  std/[algorithm, tables]

type ObjectTableModelImpl*[T] = object
  items*: seq[T]
  sortColumn*: int
  direction*: bool

func rowCount*(self: ObjectTableModelImpl, index: QModelIndex = nil): int =
  self.items.len

func columnCount*(self: ObjectTableModelImpl, index: QModelIndex = nil): int =
  for j in default(type(self.items[0])).fields(): # TODO avoid default
    result += 1

func headerData*(self: ObjectTableModelImpl, section: int, orientation: QtOrientation, role: int): QVariant =
  ## Returns the data for the given role and section in the header with the specified orientation
  var i = 0
  for n, v in default(self.T).fieldPairs(): # TODO avoid default
    if i == section:
      return newQVariant(n)
    i += 1

func data*(self: ObjectTableModelImpl, index: QModelIndex, role: int): QVariant =
  if not index.isValid:
    return
  if index.row < 0 or index.row >= self.items.len:
    return
  let peer = self.items[index.row]
  var i = 0
  for j in peer.fields():
    if i == index.column:
      return newQVariant(j)
    i += 1

func roleNames*(self: ObjectTableModelImpl): Table[int, string] =
  {0: "display",}.toTable

func doSort(self: var ObjectTableModelImpl) =
  let
    column = self.sortColumn
    dir = self.direction
  func myCmp(x, y: self.T): int =
    var i = 0
    for xv, yv in fields(x, y):
      if i == column:
        let c = cmp(xv, yv)
        return if not dir: c else: -c
      i += 1
    0

  sort(self.items, myCmp)

func setNewData*(self: var ObjectTableModelImpl, model: QAbstractTableModel, items: seq[self.T]) =
  model.beginResetModel()
  self.items = items
  self.doSort()
  model.endResetModel()

func sort*(self: var ObjectTableModelImpl, model: QAbstractTableModel, section: int) =
  model.beginResetModel()
  if self.sortColumn == section:
    self.direction = not self.direction
  else:
    self.direction = false
    self.sortColumn = section

  self.doSort()

  model.endResetModel()

func init*[E](T: type ObjectTableModelImpl[E], items: seq[E]): T =
  var res = T(items: items)
  res.doSort()
  res
