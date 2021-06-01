import
  std/[typetraits],
  stew/[results, base10, byteutils, endians2],
  chronicles, presto,
  faststreams/[outputs],
  serialization, json_serialization,
  nimcrypto/utils as ncrutils,
  ../beacon_node_common, ../networking/eth2_network,
  ../consensus_object_pools/[blockchain_dag, exit_pool],
  ../spec/[crypto, digest, datatypes, eth2_apis/callsigs_types],
  ../ssz/merkleization,
  rest_utils
export json_serialization

Json.createFlavor RestJson

type
  RestAttesterDuty* = object
    pubkey*: ValidatorPubKey
    validator_index*: ValidatorIndex
    committee_index*: CommitteeIndex
    committee_length*: uint64
    committees_at_slot*: uint64
    validator_committee_index*: ValidatorIndex
    slot*: Slot

  RestProposerDuty* = object
    pubkey*: ValidatorPubKey
    validator_index*: ValidatorIndex
    slot*: Slot

  RestCommitteeSubscription* = object
    validator_index*: ValidatorIndex
    committee_index*: CommitteeIndex
    committees_at_slot*: uint64
    slot*: Slot
    is_aggregator*: bool

  RestBeaconGenesis* = object
    genesis_time*: uint64
    genesis_validators_root*: Eth2Digest
    genesis_fork_version*: Version

  RestValidatorBalance* = object
    index*: ValidatorIndex
    balance*: string

  RestBeaconStatesCommittees* = object
    index*: CommitteeIndex
    slot*: Slot
    validators*: seq[ValidatorIndex]

  RestAttestationsFailure* = object
    index*: uint64
    message*: string

  RestValidator* = object
    index*: ValidatorIndex
    balance*: string
    status*: string
    validator*: Validator

  RestVersion* = object
    version*: string

  RestSyncInfo* = object
    head_slot*: Slot
    sync_distance*: uint64
    is_syncing*: bool

  RestConfig* = object
    MAX_COMMITTEES_PER_SLOT*: uint64
    TARGET_COMMITTEE_SIZE*: uint64
    MAX_VALIDATORS_PER_COMMITTEE*: uint64
    MIN_PER_EPOCH_CHURN_LIMIT*: uint64
    CHURN_LIMIT_QUOTIENT*: uint64
    SHUFFLE_ROUND_COUNT*: uint64
    MIN_GENESIS_ACTIVE_VALIDATOR_COUNT*: uint64
    MIN_GENESIS_TIME*: uint64
    HYSTERESIS_QUOTIENT*: uint64
    HYSTERESIS_DOWNWARD_MULTIPLIER*: uint64
    HYSTERESIS_UPWARD_MULTIPLIER*: uint64
    SAFE_SLOTS_TO_UPDATE_JUSTIFIED*: uint64
    ETH1_FOLLOW_DISTANCE*: uint64
    TARGET_AGGREGATORS_PER_COMMITTEE*: uint64
    RANDOM_SUBNETS_PER_VALIDATOR*: uint64
    EPOCHS_PER_RANDOM_SUBNET_SUBSCRIPTION*: uint64
    SECONDS_PER_ETH1_BLOCK*: uint64
    DEPOSIT_CHAIN_ID*: uint64
    DEPOSIT_NETWORK_ID*: uint64
    DEPOSIT_CONTRACT_ADDRESS*: Eth1Address
    MIN_DEPOSIT_AMOUNT*: uint64
    MAX_EFFECTIVE_BALANCE*: uint64
    EJECTION_BALANCE*: uint64
    EFFECTIVE_BALANCE_INCREMENT*: uint64
    GENESIS_FORK_VERSION*: Version
    BLS_WITHDRAWAL_PREFIX*: byte
    GENESIS_DELAY*: uint64
    SECONDS_PER_SLOT*: uint64
    MIN_ATTESTATION_INCLUSION_DELAY*: uint64
    SLOTS_PER_EPOCH*: uint64
    MIN_SEED_LOOKAHEAD*: uint64
    MAX_SEED_LOOKAHEAD*: uint64
    EPOCHS_PER_ETH1_VOTING_PERIOD*: uint64
    SLOTS_PER_HISTORICAL_ROOT*: uint64
    MIN_VALIDATOR_WITHDRAWABILITY_DELAY*: uint64
    SHARD_COMMITTEE_PERIOD*: uint64
    MIN_EPOCHS_TO_INACTIVITY_PENALTY*: uint64
    EPOCHS_PER_HISTORICAL_VECTOR*: uint64
    EPOCHS_PER_SLASHINGS_VECTOR*: uint64
    HISTORICAL_ROOTS_LIMIT*: uint64
    VALIDATOR_REGISTRY_LIMIT*: uint64
    BASE_REWARD_FACTOR*: uint64
    WHISTLEBLOWER_REWARD_QUOTIENT*: uint64
    PROPOSER_REWARD_QUOTIENT*: uint64
    INACTIVITY_PENALTY_QUOTIENT*: uint64
    MIN_SLASHING_PENALTY_QUOTIENT*: uint64
    PROPORTIONAL_SLASHING_MULTIPLIER*: uint64
    MAX_PROPOSER_SLASHINGS*: uint64
    MAX_ATTESTER_SLASHINGS*: uint64
    MAX_ATTESTATIONS*: uint64
    MAX_DEPOSITS*: uint64
    MAX_VOLUNTARY_EXITS*: uint64
    DOMAIN_BEACON_PROPOSER*: DomainType
    DOMAIN_BEACON_ATTESTER*: DomainType
    DOMAIN_RANDAO*: DomainType
    DOMAIN_DEPOSIT*: DomainType
    DOMAIN_VOLUNTARY_EXIT*: DomainType
    DOMAIN_SELECTION_PROOF*: DomainType
    DOMAIN_AGGREGATE_AND_PROOF*: DomainType

  DataEnclosedObject*[T] = object
    data*: T

  DataRootEnclosedObject*[T] = object
    dependent_root*: Eth2Digest
    data*: T

  DataRestBeaconGenesis* = DataEnclosedObject[RestBeaconGenesis]
  DataRestFork* = DataEnclosedObject[Fork]
  DataRestProposerDuties* = DataRootEnclosedObject[seq[RestProposerDuty]]
  DataRestAttesterDuties* = DataRootEnclosedObject[seq[RestAttesterDuty]]
  DataRestBeaconBlock* = DataEnclosedObject[BeaconBlock]
  DataRestAttestationData* = DataEnclosedObject[AttestationData]
  DataRestAttestation* = DataEnclosedObject[Attestation]
  DataRestSyncInfo* = DataEnclosedObject[RestSyncInfo]
  DataRestValidator* = DataEnclosedObject[RestValidator]
  DataRestValidatorList* = DataEnclosedObject[seq[RestValidator]]
  DataRestVersion* = DataEnclosedObject[RestVersion]
  DataRestConfig* = DataEnclosedObject[RestConfig]

  EncodeTypes* = SignedBeaconBlock |
                 seq[AttestationData] | seq[SignedAggregateAndProof] |
                 seq[RestCommitteeSubscription]

  DecodeTypes* = DataRestBeaconGenesis | DataRestFork | DataRestProposerDuties |
                 DataRestAttesterDuties | DataRestBeaconBlock |
                 DataRestAttestationData | DataRestAttestation |
                 DataRestSyncInfo | DataRestValidator |
                 DataRestValidatorList | DataRestVersion |
                 DataRestConfig

proc jsonResponseWRoot*(t: typedesc[RestApiResponse],
                        data: auto,
                        dependent_root: Eth2Digest): RestApiResponse =
  var stream = memoryOutput()
  var writer = JsonWriter[RestJson].init(stream)
  writer.beginRecord()
  writer.writeField("dependent_root", dependent_root)
  writer.writeField("data", data)
  writer.endRecord()
  RestApiResponse.response(stream.getOutput(seq[byte]), Http200,
                           "application/json")

proc jsonResponse*(t: typedesc[RestApiResponse],
                   data: auto): RestApiResponse =
  var stream = memoryOutput()
  var writer = JsonWriter[RestJson].init(stream)
  writer.beginRecord()
  writer.writeField("data", data)
  writer.endRecord()
  RestApiResponse.response(stream.getOutput(seq[byte]), Http200,
                           "application/json")

proc jsonResponseWMeta*(t: typedesc[RestApiResponse],
                        data: auto, meta: auto): RestApiResponse =
  var stream = memoryOutput()
  var writer = JsonWriter[RestJson].init(stream)
  writer.beginRecord()
  writer.writeField("data", data)
  writer.writeField("meta", meta)
  writer.endRecord()
  RestApiResponse.response(stream.getOutput(seq[byte]), Http200,
                           "application/json")

proc jsonError*(t: typedesc[RestApiResponse], status: HttpCode = Http200,
                msg: string = "", stacktrace: string = ""): RestApiResponse =
  let data =
    block:
      var stream = memoryOutput()
      var writer = JsonWriter[RestJson].init(stream)
      writer.beginRecord()
      writer.writeField("code", Base10.toString(uint64(status.toInt())))
      writer.writeField("message", msg)
      if len(stacktrace) > 0:
        writer.writeField("stacktrace", stacktrace)
      writer.endRecord()
      stream.getOutput(string)
  RestApiResponse.error(status, data, "application/json")

proc jsonErrorList*(t: typedesc[RestApiResponse],
                    status: HttpCode = Http200,
                    msg: string = "", failures: auto): RestApiResponse =
  let data =
    block:
      var stream = memoryOutput()
      var writer = JsonWriter[RestJson].init(stream)
      writer.beginRecord()
      writer.writeField("code", Base10.toString(uint64(status.toInt())))
      writer.writeField("message", msg)
      writer.writeField("failures", failures)
      writer.endRecord()
      stream.getOutput(string)
  RestApiResponse.error(status, data, "application/json")

template hexOriginal(data: openarray[byte]): string =
  "0x" & ncrutils.toHex(data, true)

## uint64
proc writeValue*(w: var JsonWriter[RestJson], value: uint64) =
  writeValue(w, Base10.toString(value))

proc readValue*(reader: var JsonReader[RestJson], value: var uint64) {.
     raises: [IOError, SerializationError, Defect].} =
  let svalue = reader.readValue(string)
  let res = Base10.decode(uint64, svalue)
  if res.isOk():
    value = res.get()
  else:
    reader.raiseUnexpectedValue($res.error())

## byte
proc writeValue*(w: var JsonWriter[RestJson], value: byte) =
  var data: array[1, byte]
  data[0] = value
  writeValue(w, hexOriginal(data))

proc readValue*(reader: var JsonReader[RestJson], value: var byte) {.
     raises: [IOError, SerializationError, Defect].} =
  var data: array[1, byte]
  try:
    hexToByteArray(reader.readValue(string), data)
    value = data[0]
  except ValueError:
    raiseUnexpectedValue(reader,
                         "byte value should be a valid hex string")

## DomainType
proc writeValue*(w: var JsonWriter[RestJson], value: DomainType) =
  writeValue(w, hexOriginal(uint32(value).toBytesLE()))

proc readValue*(reader: var JsonReader[RestJson], value: var DomainType) {.
     raises: [IOError, SerializationError, Defect].} =
  var data: array[4, byte]
  try:
    hexToByteArray(reader.readValue(string), data)
    let res = uint32.fromBytesLE(data)
    if res >= uint32(low(DomainType)) and res <= uint32(high(DomainType)):
      value = cast[DomainType](res)
    else:
      raiseUnexpectedValue(reader, "Incorrect DomainType value")
  except ValueError:
    raiseUnexpectedValue(reader,
                         "DomainType value should be a valid hex string")

## Slot
proc writeValue*(writer: var JsonWriter[RestJson], value: Slot) {.
     raises: [IOError, Defect].} =
  writeValue(writer, Base10.toString(uint64(value)))

proc readValue*(reader: var JsonReader[RestJson], value: var Slot) {.
     raises: [IOError, SerializationError, Defect].} =
  let svalue = reader.readValue(string)
  let res = Base10.decode(uint64, svalue)
  if res.isOk():
    value = Slot(res.get())
  else:
    reader.raiseUnexpectedValue($res.error())

## Epoch
proc writeValue*(writer: var JsonWriter[RestJson], value: Epoch) {.
     raises: [IOError, Defect].} =
  writeValue(writer, Base10.toString(uint64(value)))

proc readValue*(reader: var JsonReader[RestJson], value: var Epoch) {.
     raises: [IOError, SerializationError, Defect].} =
  let svalue = reader.readValue(string)
  let res = Base10.decode(uint64, svalue)
  if res.isOk():
    value = Epoch(res.get())
  else:
    reader.raiseUnexpectedValue($res.error())

## ValidatorIndex
proc writeValue*(writer: var JsonWriter[RestJson], value: ValidatorIndex) {.
     raises: [IOError, Defect].} =
  writeValue(writer, Base10.toString(uint64(value)))

proc readValue*(reader: var JsonReader[RestJson], value: var ValidatorIndex) {.
     raises: [IOError, SerializationError, Defect].} =
  let svalue = reader.readValue(string)
  let res = Base10.decode(uint64, svalue)
  if res.isOk():
    let v = res.get()
    if v < VALIDATOR_REGISTRY_LIMIT:
      value = ValidatorIndex(v)
    else:
      reader.raiseUnexpectedValue(
        "Validator index is bigger then VALIDATOR_REGISTRY_LIMIT")
  else:
    reader.raiseUnexpectedValue($res.error())

## RestValidatorIndex
proc writeValue*(writer: var JsonWriter[RestJson],
                 value: RestValidatorIndex) {.
     raises: [IOError, Defect].} =
  writeValue(writer, Base10.toString(uint64(value)))

proc readValue*(reader: var JsonReader[RestJson],
                value: var RestValidatorIndex) {.
     raises: [IOError, SerializationError, Defect].} =
  let svalue = reader.readValue(string)
  let res = Base10.decode(uint64, svalue)
  if res.isOk():
    let v = res.get()
    value = RestValidatorIndex(v)
  else:
    reader.raiseUnexpectedValue($res.error())

## CommitteeIndex
proc writeValue*(writer: var JsonWriter[RestJson], value: CommitteeIndex) {.
     raises: [IOError, Defect].} =
  writeValue(writer, Base10.toString(uint64(value)))

proc readValue*(reader: var JsonReader[RestJson], value: var CommitteeIndex) {.
     raises: [IOError, SerializationError, Defect].} =
  let svalue = reader.readValue(string)
  let res = Base10.decode(uint64, svalue)
  if res.isOk():
    value = CommitteeIndex(res.get())
  else:
    reader.raiseUnexpectedValue($res.error())

## ValidatorSig
proc writeValue*(writer: var JsonWriter[RestJson], value: ValidatorSig) {.
     raises: [IOError, Defect].} =
  writeValue(writer, hexOriginal(toRaw(value)))

proc readValue*(reader: var JsonReader[RestJson], value: var ValidatorSig) {.
     raises: [IOError, SerializationError, Defect].} =
  let hexValue = reader.readValue(string)
  let res = ValidatorSig.fromHex(hexValue)
  if res.isOk():
    value = res.get()
  else:
    reader.raiseUnexpectedValue($res.error())

## TrustedSig
proc writeValue*(writer: var JsonWriter[RestJson], value: TrustedSig) {.
     raises: [IOError, Defect].} =
  writeValue(writer, hexOriginal(toRaw(value)))

proc readValue*(reader: var JsonReader[RestJson], value: var TrustedSig) {.
     raises: [IOError, SerializationError, Defect].} =
  let hexValue = reader.readValue(string)
  let res = ValidatorSig.fromHex(hexValue)
  if res.isOk():
    value = cast[TrustedSig](res.get())
  else:
    reader.raiseUnexpectedValue($res.error())

## ValidatorPubKey
proc writeValue*(writer: var JsonWriter[RestJson], value: ValidatorPubKey) {.
     raises: [IOError, Defect].} =
  writeValue(writer, hexOriginal(toRaw(value)))

proc readValue*(reader: var JsonReader[RestJson], value: var ValidatorPubKey) {.
     raises: [IOError, SerializationError, Defect].} =
  let hexValue = reader.readValue(string)
  let res = ValidatorPubKey.fromHex(hexValue)
  if res.isOk():
    value = res.get()
  else:
    reader.raiseUnexpectedValue($res.error())

## BitSeq
proc readValue*(reader: var JsonReader[RestJson], value: var BitSeq) {.
     raises: [IOError, SerializationError, Defect].} =
  try:
    value = BitSeq hexToSeqByte(reader.readValue(string))
  except ValueError:
    raiseUnexpectedValue(reader, "A BitSeq value should be a valid hex string")

proc writeValue*(writer: var JsonWriter[RestJson], value: BitSeq) {.
     raises: [IOError, Defect].} =
  writeValue(writer, hexOriginal(value.bytes()))

## BitList
proc readValue*(reader: var JsonReader[RestJson], value: var BitList) =
  type T = type(value)
  value = T readValue(reader, BitSeq)

proc writeValue*(writer: var JsonWriter[RestJson], value: BitList) =
  writeValue(writer, BitSeq value)

## Eth2Digest
proc readValue*(reader: var JsonReader[RestJson], value: var Eth2Digest) {.
     raises: [IOError, SerializationError, Defect].} =
  try:
    hexToByteArray(reader.readValue(string), value.data)
  except ValueError:
    raiseUnexpectedValue(reader,
                         "Eth2Digest value should be a valid hex string")

proc writeValue*(writer: var JsonWriter[RestJson], value: Eth2Digest) {.
     raises: [IOError, Defect].} =
  writeValue(writer, hexOriginal(value.data))

## BloomLogs
proc readValue*(reader: var JsonReader[RestJson], value: var BloomLogs) {.
     raises: [IOError, SerializationError, Defect].} =
  try:
    hexToByteArray(reader.readValue(string), value.data)
  except ValueError:
    raiseUnexpectedValue(reader,
                         "BloomLogs value should be a valid hex string")

proc writeValue*(writer: var JsonWriter[RestJson], value: BloomLogs) {.
     raises: [IOError, Defect].} =
  writeValue(writer, hexOriginal(value.data))

## HashArray
proc readValue*(reader: var JsonReader[RestJson], value: var HashArray) {.
     raises: [IOError, SerializationError, Defect].} =
  readValue(reader, value.data)

proc writeValue*(writer: var JsonWriter[RestJson], value: HashArray) {.
     raises: [IOError, Defect].} =
  writeValue(writer, value.data)

## HashList
proc readValue*(reader: var JsonReader[RestJson], value: var HashList) {.
     raises: [IOError, SerializationError, Defect].} =
  readValue(reader, value.data)

proc writeValue*(writer: var JsonWriter[RestJson], value: HashList) {.
     raises: [IOError, Defect].} =
  writeValue(writer, value.data)

## Eth1Address
proc readValue*(reader: var JsonReader[RestJson], value: var Eth1Address) {.
     raises: [IOError, SerializationError, Defect].} =
  try:
    hexToByteArray(reader.readValue(string), distinctBase(value))
  except ValueError:
    raiseUnexpectedValue(reader,
                         "Eth1Address value should be a valid hex string")

proc writeValue*(writer: var JsonWriter[RestJson], value: Eth1Address) {.
     raises: [IOError, Defect].} =
  writeValue(writer, hexOriginal(distinctBase(value)))

## Version
proc readValue*(reader: var JsonReader[RestJson], value: var Version) {.
     raises: [IOError, SerializationError, Defect].} =
  try:
    hexToByteArray(reader.readValue(string), distinctBase(value))
  except ValueError:
    raiseUnexpectedValue(reader,
                         "Version value should be a valid hex string")

proc writeValue*(writer: var JsonWriter[RestJson], value: Version) {.
     raises: [IOError, Defect].} =
  writeValue(writer, hexOriginal(distinctBase(value)))

## ForkDigest
proc readValue*(reader: var JsonReader[RestJson], value: var ForkDigest) {.
     raises: [IOError, SerializationError, Defect].} =
  try:
    hexToByteArray(reader.readValue(string), distinctBase(value))
  except ValueError:
    raiseUnexpectedValue(reader,
                         "ForkDigest value should be a valid hex string")

proc writeValue*(writer: var JsonWriter[RestJson], value: ForkDigest) {.
     raises: [IOError, Defect].} =
  writeValue(writer, hexOriginal(distinctBase(value)))

## GraffitiBytes
proc readValue*(reader: var JsonReader[RestJson], value: var GraffitiBytes) {.
     raises: [IOError, SerializationError, Defect].} =
  try:
    hexToByteArray(reader.readValue(string), distinctBase(value))
  except ValueError:
    raiseUnexpectedValue(reader,
                         "GraffitiBytes value should be a valid hex string")

proc writeValue*(writer: var JsonWriter[RestJson], value: GraffitiBytes) {.
     raises: [IOError, Defect].} =
  writeValue(writer, hexOriginal(distinctBase(value)))

proc decodeBody*[T](t: typedesc[T],
                    body: ContentBody): Result[T, cstring] =
  if body.contentType != "application/json":
    return err("Unsupported content type")
  let data =
    try:
      RestJson.decode(cast[string](body.data), T)
    except SerializationError:
      return err("Unable to deserialize data")
    except CatchableError:
      return err("Unexpected deserialization error")
  ok(data)

RestJson.useCustomSerialization(BeaconState.justification_bits):
  read:
    let s = reader.readValue(string)
    if s.len != 4:
      raiseUnexpectedValue(reader, "A string with 4 characters expected")
    try:
      hexToByteArray(s, 1)[0]
    except ValueError:
      raiseUnexpectedValue(reader,
                          "The `justification_bits` value must be a hex string")
  write:
    writer.writeValue "0x" & toHex([value])

proc encodeBytes*[T: EncodeTypes](value: T,
                                  contentType: string): RestResult[seq[byte]] =
  case contentType
  of "application/json":
    var stream = memoryOutput()
    var writer = JsonWriter[RestJson].init(stream)
    writer.beginRecord()
    writer.writeField("data", value)
    writer.endRecord()
    ok(stream.getOutput(seq[byte]))
  else:
    err("Content-Type not supported")

proc encodeBytes*(value: seq[ValidatorIndex],
                  contentType: string): RestResult[seq[byte]] =
  case contentType
  of "application/json":
    var stream = memoryOutput()
    var writer = JsonWriter[RestJson].init(stream)
    writer.writeArray(value)
    ok(stream.getOutput(seq[byte]))
  else:
    err("Content-Type not supported")

proc decodeBytes*[T: DecodeTypes](t: typedesc[T], value: openarray[byte],
                                  contentType: string): RestResult[T] =
  case contentType
  of "application/json":
    let res =
      try:
        RestJson.decode(value, T)
      except SerializationError:
        return err("Serialization error")
    ok(res)
  else:
    err("Content-Type not supported")

proc encodeString*(value: string): RestResult[string] =
  ok(value)

proc encodeString*(value: Epoch|Slot|CommitteeIndex): RestResult[string] =
  ok(Base10.toString(uint64(value)))

proc encodeString*(value: ValidatorSig): RestResult[string] =
  ok(hexOriginal(toRaw(value)))

proc encodeString*(value: GraffitiBytes): RestResult[string] =
  ok(hexOriginal(distinctBase(value)))

proc encodeString*(value: Eth2Digest): RestResult[string] =
  ok(hexOriginal(value.data))

proc encodeString*(value: ValidatorIdent): RestResult[string] =
  case value.kind
  of ValidatorQueryKind.Index:
    ok(Base10.toString(uint64(value.index)))
  of ValidatorQueryKind.Key:
    ok(hexOriginal(toRaw(value.key)))

proc encodeString*(value: StateIdent): RestResult[string] =
  case value.kind
  of StateQueryKind.Slot:
    ok(Base10.toString(uint64(value.slot)))
  of StateQueryKind.Root:
    ok(hexOriginal(value.root.data))
  of StateQueryKind.Named:
    case value.value
    of StateIdentType.Head:
      ok("head")
    of StateIdentType.Genesis:
      ok("genesis")
    of StateIdentType.Finalized:
      ok("finalized")
    of StateIdentType.Justified:
      ok("justified")
