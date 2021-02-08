import NimQml

QtObject:
  type
    FooterModel* = ref object of QObject
      finalized: string
      head: string
      syncing: string

  proc delete*(self: FooterModel) =
    self.QObject.delete

  proc setup*(self: FooterModel) =
    self.QObject.setup

  proc newFooterModel*(): FooterModel =
    let res = FooterModel()
    res.setup()
    res

  proc finalized*(self: FooterModel): string {.slot.} = self.finalized
  proc finalizedChanged*(self: FooterModel, v: string) {.signal.}
  proc `finalized=`*(self: FooterModel, v: string) =
    self.finalized = v
    self.finalizedChanged(v)
  QtProperty[string] finalized:
    read = finalized
    notify = finalizedChanged

  proc head*(self: FooterModel): string {.slot.} = self.head
  proc headChanged*(self: FooterModel, v: string) {.signal.}
  proc `head=`*(self: FooterModel, v: string) =
    self.head = v
    self.headChanged(v)
  QtProperty[string] head: read = head; notify = headChanged

  proc syncing*(self: FooterModel): string {.slot.} = self.syncing
  proc syncingChanged*(self: FooterModel, v: string) {.signal.}
  proc `syncing=`*(self: FooterModel, v: string) =
    self.syncing = v
    self.syncingChanged(v)
  QtProperty[string] syncing: read = syncing; notify = syncingChanged
