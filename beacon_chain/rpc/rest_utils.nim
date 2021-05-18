import presto,
       libp2p/peerid,
       stew/[base10, byteutils],
       faststreams/[outputs],
       serialization, json_serialization,
       nimcrypto/utils as ncrutils,
       ../spec/[crypto, datatypes, digest, forkedbeaconstate_helpers],
       ../beacon_node_common,
       ../consensus_object_pools/[block_pools_types, blockchain_dag]
export blockchain_dag, presto

const
  DecimalSet = {'0' .. '9'}
    # Base10 (decimal) set of chars
  HexadecimalSet = {'0'..'9', 'A'..'F', 'a'..'f'}
    # Base16 (hexadecimal) set of chars
  Base58Set = {'1'..'9', 'A'..'H', 'J'..'N', 'P'..'Z', 'a'..'k', 'm'..'z'}
    # Base58 set of chars
  MaxDecimalSize = len($high(uint64))
    # Maximum size of `uint64` decimal value
  MaxPeerIdSize = 128
    # Maximum size of `PeerID` base58 encoded value
  ValidatorKeySize = RawPubKeySize * 2
    # Size of `ValidatorPubKey` hexadecimal value (without 0x)
  ValidatorSigSize = RawSigSize * 2
    # Size of `ValidatorSig` hexadecimal value (without 0x)
  RootHashSize = sizeof(Eth2Digest) * 2
    # Size of `xxx_root` hexadecimal value (without 0x)
  FarFutureEpochString* = "18446744073709551615"
  MaxEpoch* = compute_epoch_at_slot(not(0'u64))

  BlockValidationError* =
    "The block failed validation, but was successfully broadcast anyway. It " &
    "was not integrated into the beacon node's database."
  BlockValidationSuccess* =
    "The block was validated successfully and has been broadcast"
  BeaconNodeInSyncError* =
    "Beacon node is currently syncing and not serving request on that endpoint"
  BlockNotFoundError* =
    "Block header/data has not been found"
  BlockProduceError* =
    "Could not produce the block"
  EmptyRequestBodyError* =
    "Empty request's body"
  InvalidBlockObjectError* =
    "Unable to decode block object(s)"
  InvalidAttestationObjectError* =
    "Unable to decode attestation object(s)"
  AttestationValidationError* =
    "Some errors happened while validating attestation(s)"
  AttestationValidationSuccess* =
    "Attestation object(s) was broadcasted"
  InvalidAttesterSlashingObjectError* =
    "Unable to decode attester slashing object(s)"
  AttesterSlashingValidationError* =
    "Invalid attester slashing, it will never pass validation so it's rejected"
  AttesterSlashingValidationSuccess* =
    "Attester slashing object was broadcasted"
  InvalidProposerSlashingObjectError* =
    "Unable to decode proposer slashing object(s)"
  ProposerSlashingValidationError* =
    "Invalid proposer slashing, it will never pass validation so it's rejected"
  ProposerSlashingValidationSuccess* =
    "Proposer slashing object was broadcasted"
  InvalidVoluntaryExitObjectError* =
    "Unable to decode voluntary exit object(s)"
  VoluntaryExitValidationError* =
    "Invalid voluntary exit, it will never pass validation so it's rejected"
  VoluntaryExitValidationSuccess* =
    "Voluntary exit object(s) was broadcasted"
  InvalidAggregateAndProofObjectError* =
    "Unable to decode aggregate and proof object(s)"
  AggregateAndProofValidationError* =
    "Invalid aggregate and proof, it will never pass validation so it's " &
    "rejected"
  AggregateAndProofValidationSuccess* =
    "Aggregate and proof object(s) was broadcasted"
  InvalidParentRootValueError* =
    "Invalid parent root value"
  MissingSlotValueError* =
    "Missing `slot` value"
  InvalidSlotValueError* =
    "Invalid slot value"
  MissingCommitteeIndexValueError* =
    "Missing `committee_index` value"
  InvalidCommitteeIndexValueError* =
    "Invalid committee index value"
  MissingAttestationDataRootValueError* =
    "Missing `attestation_data_root` value"
  InvalidAttestationDataRootValueError* =
    "Invalid attestation data root value"
  UnableToGetAggregatedAttestationError* =
    "Unable to retrieve an aggregated attestation"
  MissingRandaoRevealValue* =
    "Missing `randao_reveal` value"
  InvalidRandaoRevealValue* =
    "Invalid randao reveal value"
  InvalidGraffitiBytesValye* =
    "Invalid graffiti bytes value"
  InvalidEpochValueError* =
    "Invalid epoch value"
  InvalidStateIdValueError* =
    "Invalid state identifier value"
  InvalidBlockIdValueError* =
    "Invalid block identifier value"
  InvalidValidatorIdValueError* =
    "Invalid validator's identifier value(s)"
  MaximumNumberOfValidatorIdsError* =
    "Maximum number of validator identifier values exceeded"
  InvalidValidatorStatusValueError* =
    "Invalid validator's status value error"
  InvalidValidatorIndexValueError* =
    "Invalid validator's index value(s)"
  EmptyValidatorIndexArrayError* =
    "Empty validator's index array"
  InvalidSubscriptionRequestValueError* =
    "Invalid subscription request object(s)"
  ValidatorNotFoundError* =
    "Could not find validator"
  ValidatorStatusNotFoundError* =
    "Could not obtain validator's status"
  UniqueValidatorKeyError* =
    "Only unique validator's keys are allowed"
  TooHighValidatorIndexValueError* =
    "Validator index exceeds maximum number of validators allowed"
  UnsupportedValidatorIndexValueError* =
    "Validator index exceeds maximum supported number of validators"
  UniqueValidatorIndexError* =
    "Only unique validator's index are allowed"
  StateNotFoundError* =
    "State not found"
  SlotNotFoundError* =
    "Slot number is too far away"
  SlotNotInNextWallSlotEpochError* =
    "Requested slot not in next wall-slot epoch"
  SlotFromThePastError* =
    "Requested slot from the past"
  ProposerNotFoundError* =
    "Could not find proposer for the head and slot"
  NoHeadForSlotError* =
    "Cound not find head for slot"
  EpochOverflowValueError* =
    "Requesting epoch for which slot would overflow"
  InvalidPeerStateValueError* =
    "Invalid peer's state value(s) error"
  InvalidPeerDirectionValueError* =
    "Invalid peer's direction value(s) error"
  InvalidPeerIdValueError* =
    "Invalid peer's id value(s) error"
  PeerNotFoundError* =
    "Peer not found"
  InvalidLogLevelValueError* =
    "Invalid log level value error"
  InternalServerError* =
    "Internal server error"
  NoImplementationError* =
    "Not implemented yet"

type
  ValidatorQueryKind* {.pure.} = enum
    Index, Key

  RestValidatorIndex* = distinct uint64

  ValidatorIndexError* {.pure.} = enum
    UnsupportedValue, TooHighValue

  ValidatorIdent* = object
    case kind*: ValidatorQueryKind
    of ValidatorQueryKind.Index:
      index*: RestValidatorIndex
    of ValidatorQueryKind.Key:
      key*: ValidatorPubKey

  ValidatorFilterKind* {.pure.} = enum
    PendingInitialized, PendingQueued,
    ActiveOngoing, ActiveExiting, ActiveSlashed,
    ExitedUnslashed, ExitedSlashed,
    WithdrawalPossible, WithdrawalDone

  ValidatorFilter* = set[ValidatorFilterKind]

  StateQueryKind* {.pure.} = enum
    Slot, Root, Named

  StateIdentType* {.pure.} = enum
    Head, Genesis, Finalized, Justified

  StateIdent* = object
    case kind*: StateQueryKind
    of StateQueryKind.Slot:
      slot*: Slot
    of StateQueryKind.Root:
      root*: Eth2Digest
    of StateQueryKind.Named:
      value*: StateIdentType

  BlockQueryKind* {.pure.} = enum
    Slot, Root, Named
  BlockIdentType* {.pure.} = enum
    Head, Genesis, Finalized

  BlockIdent* = object
    case kind*: BlockQueryKind
    of BlockQueryKind.Slot:
      slot*: Slot
    of BlockQueryKind.Root:
      root*: Eth2Digest
    of BlockQueryKind.Named:
      value*: BlockIdentType

  PeerStateKind* {.pure.} = enum
    Disconnected, Connecting, Connected, Disconnecting

  PeerDirectKind* {.pure.} = enum
    Inbound, Outbound

  EventTopic* {.pure.} = enum
    Head, Block, Attestation, VoluntaryExit, FinalizedCheckpoint, ChainReorg

  EventTopics* = set[EventTopic]

func match(data: openarray[char], charset: set[char]): int =
  for ch in data:
    if ch notin charset:
      return 1
  0

proc validate(key: string, value: string): int =
  ## This is rough validation procedure which should be simple and fast,
  ## because it will be used for query routing.
  case key
  of "{epoch}":
    0
  of "{slot}":
    0
  of "{peer_id}":
    0
  of "{state_id}":
    0
  of "{block_id}":
    0
  of "{validator_id}":
    0
  else:
    1

proc parseRoot(value: string): Result[Eth2Digest, cstring] =
  try:
    ok(Eth2Digest(data: hexToByteArray[32](value)))
  except ValueError:
    err("Unable to decode root value")

proc decodeString*(t: typedesc[Slot], value: string): Result[Slot, cstring] =
  let res = ? Base10.decode(uint64, value)
  ok(Slot(res))

proc decodeString*(t: typedesc[Epoch], value: string): Result[Epoch, cstring] =
  let res = ? Base10.decode(uint64, value)
  ok(Epoch(res))

proc decodeString*(t: typedesc[StateIdent],
                   value: string): Result[StateIdent, cstring] =
  if len(value) > 2:
    if (value[0] == '0') and (value[1] == 'x'):
      if len(value) != RootHashSize + 2:
        err("Incorrect state root value length")
      else:
        let res = ? parseRoot(value)
        ok(StateIdent(kind: StateQueryKind.Root, root: res))
    elif (value[0] in DecimalSet) and (value[1] in DecimalSet):
      let res = ? Base10.decode(uint64, value)
      ok(StateIdent(kind: StateQueryKind.Slot, slot: Slot(res)))
    else:
      case value
      of "head":
        ok(StateIdent(kind: StateQueryKind.Named,
                      value: StateIdentType.Head))
      of "genesis":
        ok(StateIdent(kind: StateQueryKind.Named,
                      value: StateIdentType.Genesis))
      of "finalized":
        ok(StateIdent(kind: StateQueryKind.Named,
                      value: StateIdentType.Finalized))
      of "justified":
        ok(StateIdent(kind: StateQueryKind.Named,
                      value: StateIdentType.Justified))
      else:
        err("Incorrect state identifier value")
  else:
    let res = ? Base10.decode(uint64, value)
    ok(StateIdent(kind: StateQueryKind.Slot, slot: Slot(res)))

proc decodeString*(t: typedesc[BlockIdent],
                   value: string): Result[BlockIdent, cstring] =
  if len(value) > 2:
    if (value[0] == '0') and (value[1] == 'x'):
      if len(value) != RootHashSize + 2:
        err("Incorrect block root value length")
      else:
        let res = ? parseRoot(value)
        ok(BlockIdent(kind: BlockQueryKind.Root, root: res))
    elif (value[0] in DecimalSet) and (value[1] in DecimalSet):
      let res = ? Base10.decode(uint64, value)
      ok(BlockIdent(kind: BlockQueryKind.Slot, slot: Slot(res)))
    else:
      case value
        of "head":
          ok(BlockIdent(kind: BlockQueryKind.Named,
                        value: BlockIdentType.Head))
        of "genesis":
          ok(BlockIdent(kind: BlockQueryKind.Named,
                        value: BlockIdentType.Genesis))
        of "finalized":
          ok(BlockIdent(kind: BlockQueryKind.Named,
                        value: BlockIdentType.Finalized))
        else:
          err("Incorrect block identifier value")
  else:
    let res = ? Base10.decode(uint64, value)
    ok(BlockIdent(kind: BlockQueryKind.Slot, slot: Slot(res)))

proc decodeString*(t: typedesc[ValidatorIdent],
                   value: string): Result[ValidatorIdent, cstring] =
  if len(value) > 2:
    if (value[0] == '0') and (value[1] == 'x'):
      if len(value) != ValidatorKeySize + 2:
        err("Incorrect validator's key value length")
      else:
        let res = ? ValidatorPubKey.fromHex(value)
        ok(ValidatorIdent(kind: ValidatorQueryKind.Key,
                          key: res))
    elif (value[0] in DecimalSet) and (value[1] in DecimalSet):
      let res = ? Base10.decode(uint64, value)
      ok(ValidatorIdent(kind: ValidatorQueryKind.Index,
                        index: RestValidatorIndex(res)))
    else:
      err("Incorrect validator identifier value")
  else:
    let res = ? Base10.decode(uint64, value)
    ok(ValidatorIdent(kind: ValidatorQueryKind.Index,
                      index: RestValidatorIndex(res)))

proc decodeString*(t: typedesc[PeerID],
                   value: string): Result[PeerID, cstring] =
  PeerID.init(value)

proc decodeString*(t: typedesc[CommitteeIndex],
                   value: string): Result[CommitteeIndex, cstring] =
  let res = ? Base10.decode(uint64, value)
  ok(CommitteeIndex(res))

proc decodeString*(t: typedesc[Eth2Digest],
                   value: string): Result[Eth2Digest, cstring] =
  if len(value) != RootHashSize + 2:
    return err("Incorrect root value length")
  if value[0] != '0' and value[1] != 'x':
    return err("Incorrect root value encoding")
  parseRoot(value)

proc decodeString*(t: typedesc[ValidatorFilter],
                   value: string): Result[ValidatorFilter, cstring] =
  case value
  of "pending_initialized":
    ok({ValidatorFilterKind.PendingInitialized})
  of "pending_queued":
    ok({ValidatorFilterKind.PendingQueued})
  of "active_ongoing":
    ok({ValidatorFilterKind.ActiveOngoing})
  of "active_exiting":
    ok({ValidatorFilterKind.ActiveExiting})
  of "active_slashed":
    ok({ValidatorFilterKind.ActiveSlashed})
  of "exited_unslashed":
    ok({ValidatorFilterKind.ExitedUnslashed})
  of "exited_slashed":
    ok({ValidatorFilterKind.ExitedSlashed})
  of "withdrawal_possible":
    ok({ValidatorFilterKind.WithdrawalPossible})
  of "withdrawal_done":
    ok({ValidatorFilterKind.WithdrawalDone})
  of "pending":
    ok({
      ValidatorFilterKind.PendingInitialized,
      ValidatorFilterKind.PendingQueued
    })
  of "active":
    ok({
      ValidatorFilterKind.ActiveOngoing,
      ValidatorFilterKind.ActiveExiting,
      ValidatorFilterKind.ActiveSlashed
    })
  of "exited":
    ok({
      ValidatorFilterKind.ExitedUnslashed,
      ValidatorFilterKind.ExitedSlashed
    })
  of "withdrawal":
    ok({
      ValidatorFilterKind.WithdrawalPossible,
      ValidatorFilterKind.WithdrawalDone
    })
  else:
    err("Incorrect validator state identifier value")

proc decodeString*(t: typedesc[PeerStateKind],
                   value: string): Result[PeerStateKind, cstring] =
  case value
  of "disconnected":
    ok(PeerStateKind.Disconnected)
  of "connecting":
    ok(PeerStateKind.Connecting)
  of "connected":
    ok(PeerStateKind.Connected)
  of "disconnecting":
    ok(PeerStateKind.Disconnecting)
  else:
    err("Incorrect peer's state value")

proc decodeString*(t: typedesc[PeerDirectKind],
                   value: string): Result[PeerDirectKind, cstring] =
  case value
  of "inbound":
    ok(PeerDirectKind.Inbound)
  of "outbound":
    ok(PeerDirectKind.Outbound)
  else:
    err("Incorrect peer's direction value")

proc decodeString*(t: typedesc[EventTopic],
                   value: string): Result[EventTopic, cstring] =
  case value
  of "head":
    ok(EventTopic.Head)
  of "block":
    ok(EventTopic.Block)
  of "attestation":
    ok(EventTopic.Attestation)
  of "voluntary_exit":
    ok(EventTopic.VoluntaryExit)
  of "finalized_checkpoint":
    ok(EventTopic.FinalizedCheckpoint)
  of "chain_reorg":
    ok(EventTopic.ChainReorg)
  else:
    err("Incorrect event's topic value")

proc decodeString*(t: typedesc[ValidatorSig],
                   value: string): Result[ValidatorSig, cstring] =
  if len(value) != ValidatorSigSize + 2:
    return err("Incorrect validator signature value length")
  if value[0] != '0' and value[1] != 'x':
    return err("Incorrect validator signature encoding")
  ValidatorSig.fromHex(value)

proc decodeString*(t: typedesc[GraffitiBytes],
                   value: string): Result[GraffitiBytes, cstring] =
  try:
    ok(GraffitiBytes.init(value))
  except ValueError:
    err("Unable to decode graffiti value")

proc decodeString*(t: typedesc[string],
                   value: string): Result[string, cstring] =
  ok(value)

proc getRouter*(): RestRouter =
  RestRouter.init(validate)

proc getCurrentHead*(node: BeaconNode,
                     slot: Slot): Result[BlockRef, cstring] =
  let res = node.dag.head
  # if not(node.isSynced(res)):
  #   return err("Cannot fulfill request until node is synced")
  if res.slot + uint64(2 * SLOTS_PER_EPOCH) < slot:
    return err("Requesting way ahead of the current head")
  ok(res)

proc getCurrentHead*(node: BeaconNode,
                     epoch: Epoch): Result[BlockRef, cstring] =
  if epoch > MaxEpoch:
    return err("Requesting epoch for which slot would overflow")
  node.getCurrentHead(compute_start_slot_at_epoch(epoch))

proc toBlockSlot*(blckRef: BlockRef): BlockSlot =
  blckRef.atSlot(blckRef.slot)

proc getBlockSlot*(node: BeaconNode,
                   stateIdent: StateIdent): Result[BlockSlot, cstring] =
  case stateIdent.kind
  of StateQueryKind.Slot:
    let head = ? getCurrentHead(node, stateIdent.slot)
    let bslot = head.atSlot(stateIdent.slot)
    if isNil(bslot.blck):
      return err("Block not found")
    ok(bslot)
  of StateQueryKind.Root:
    let blckRef = node.dag.getRef(stateIdent.root)
    if isNil(blckRef):
      return err("Block not found")
    ok(blckRef.toBlockSlot())
  of StateQueryKind.Named:
    case stateIdent.value
    of StateIdentType.Head:
      ok(node.dag.head.toBlockSlot())
    of StateIdentType.Genesis:
      ok(node.dag.getGenesisBlockSlot())
    of StateIdentType.Finalized:
      ok(node.dag.finalizedHead)
    of StateIdentType.Justified:
      ok(node.dag.head.atEpochStart(getStateField(
        node.dag.headState.data, current_justified_checkpoint).epoch))

proc getBlockDataFromBlockIdent*(node: BeaconNode,
                                 id: BlockIdent): Result[BlockData, cstring] =
  case id.kind
  of BlockQueryKind.Named:
    case id.value
    of BlockIdentType.Head:
      ok(node.dag.get(node.dag.head))
    of BlockIdentType.Genesis:
      ok(node.dag.getGenesisBlockData())
    of BlockIdentType.Finalized:
      ok(node.dag.get(node.dag.finalizedHead.blck))
  of BlockQueryKind.Root:
    let res = node.dag.get(id.root)
    if res.isNone():
      return err("Block not found")
    ok(res.get())
  of BlockQueryKind.Slot:
    let head = ? node.getCurrentHead(id.slot)
    let blockSlot = head.atSlot(id.slot)
    if isNil(blockSlot.blck):
      return err("Block not found")
    ok(node.dag.get(blockSlot.blck))

template withStateForBlockSlot*(node: BeaconNode,
                                blockSlot: BlockSlot, body: untyped): untyped =
  template isState(state: StateData): bool =
    state.blck.atSlot(getStateField(state.data, slot)) == blockSlot

  if isState(node.dag.headState):
    withStateVars(node.dag.headState):
      var cache {.inject.}: StateCache
      body
  else:
    let rpcState = assignClone(node.dag.headState)
    node.dag.withState(rpcState[], blockSlot):
      body

proc toValidatorIndex*(value: RestValidatorIndex): Result[ValidatorIndex,
                                                          ValidatorIndexError] =
  when sizeof(ValidatorIndex) == 4:
    if uint64(value) < VALIDATOR_REGISTRY_LIMIT:
      # On x86 platform Nim allows only `int32` indexes, so all the indexes in
      # range `2^31 <= x < 2^32` are not supported.
      if uint64(value) <= uint64(high(int32)):
        ok(ValidatorIndex(value))
      else:
        err(ValidatorIndexError.UnsupportedValue)
    else:
      err(ValidatorIndexError.TooHighValue)
  elif sizeof(ValidatorIndex) == 8:
    if uint64(value) < VALIDATOR_REGISTRY_LIMIT:
      ok(ValidatorIndex(value))
    else:
      err(ValidatorIndexError.TooHighValue)
  else:
    doAssert(false, "ValidatorIndex type size is incorrect")

proc init*(t: typedesc[StateIdent], v: StateIdentType): StateIdent =
  StateIdent(kind: StateQueryKind.Named, value: v)

proc init*(t: typedesc[StateIdent], v: Slot): StateIdent =
  StateIdent(kind: StateQueryKind.Slot, slot: v)

proc init*(t: typedesc[StateIdent], v: Eth2Digest): StateIdent =
  StateIdent(kind: StateQueryKind.Root, root: v)

proc init*(t: typedesc[ValidatorIdent], v: ValidatorIndex): ValidatorIdent =
  ValidatorIdent(kind: ValidatorQueryKind.Index, index: RestValidatorIndex(v))

proc init*(t: typedesc[ValidatorIdent], v: ValidatorPubKey): ValidatorIdent =
  ValidatorIdent(kind: ValidatorQueryKind.Key, key: v)
