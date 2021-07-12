import NimQml

import
  std/[sequtils, json, times],
  NimQml,
  ../beacon_chain/eth2_json_rpc_serialization,
  ../beacon_chain/spec/[datatypes, crypto],
  ./attestationlist, ./depositlist, ./utils

QtObject:
  type
    BlockModel* = ref object of QObject
      blck: SignedBeaconBlock
      attestationsx: AttestationList
      depositsx: DepositList
      genesis_time*: uint64

  proc delete*(self: BlockModel) =
    self.QObject.delete

  proc setup*(self: BlockModel) =
    self.QObject.setup

  proc newBlockModel*(blck: SignedBeaconBlock, genesis_time: uint64): BlockModel =
    let res = BlockModel(
      blck: blck,
      attestationsx: newAttestationList(blck.message.body.attestations.mapIt(it.toAttestationInfo())),
      depositsx: newDepositList(blck.message.body.deposits.mapIt(it.toDepositInfo())),
      genesis_time: genesis_time,
    )
    res.setup()
    res

  proc `blck=`*(self: BlockModel, blck: SignedBeaconBlock) =
      self.blck = blck
      self.attestationsx.setNewData(blck.message.body.attestations.mapIt(it.toAttestationInfo()))
      self.depositsx.setNewData(blck.message.body.deposits.mapIt(it.toDepositInfo()))

  proc slot*(self: BlockModel): int {.slot.} = self.blck.message.slot.int
  QtProperty[int] slot: read = slot

  proc time*(self: BlockModel): string {.slot.} =
    let t = self.genesis_time + self.blck.message.slot * SECONDS_PER_SLOT
    $fromUnix(t.int64).utc
  QtProperty[string] time: read = time

  proc root*(self: BlockModel): string {.slot.} = toDisplayHex(self.blck.root.data)
  QtProperty[string] root: read = root

  proc proposer_index*(self: BlockModel): int {.slot.} = self.blck.message.proposer_index.int
  QtProperty[int] proposer_index: read = proposer_index

  proc parent_root*(self: BlockModel): string {.slot.} = toBlockLink(self.blck.message.parent_root)
  QtProperty[string] parent_root: read = parent_root

  proc state_root*(self: BlockModel): string {.slot.} = toDisplayHex(self.blck.message.state_root.data)
  QtProperty[string] state_root: read = state_root

  proc randao_reveal*(self: BlockModel): string {.slot.} = toDisplayHex(self.blck.message.body.randao_reveal)
  QtProperty[string] randao_reveal: read = randao_reveal

  proc eth1_data*(self: BlockModel): string {.slot.} = (%*self.blck.message.body.eth1_data).pretty()
  QtProperty[string] eth1_data: read = eth1_data

  proc graffiti*(self: BlockModel): string {.slot.} = $self.blck.message.body.graffiti
  QtProperty[string] graffiti: read = graffiti

  proc proposer_slashings*(self: BlockModel): string {.slot.} = (%*self.blck.message.body.proposer_slashings.asSeq()).pretty()
  QtProperty[string] proposer_slashings: read = proposer_slashings

  proc attester_slashings*(self: BlockModel): string {.slot.} = (%*self.blck.message.body.attester_slashings.asSeq()).pretty()
  QtProperty[string] attester_slashings: read = attester_slashings

  proc attestations*(self: BlockModel): QVariant {.slot.} = newQVariant(self.attestationsx)
  QtProperty[QVariant] attestations: read = attestations

  proc deposits*(self: BlockModel): QVariant {.slot.} = newQVariant(self.depositsx)
  QtProperty[QVariant] deposits: read = deposits

  proc voluntary_exits*(self: BlockModel): string {.slot.} = (%*self.blck.message.body.voluntary_exits.asSeq()).pretty()
  QtProperty[string] voluntary_exits: read = voluntary_exits

  proc signature*(self: BlockModel): string {.slot.} = toDisplayHex(self.blck.signature)
  QtProperty[string] signature: read = signature
