import
  std/[typetraits],
  stew/[results, base10, byteutils],
  chronicles, presto,
  faststreams/[outputs],
  serialization, json_serialization,
  nimcrypto/utils as ncrutils,
  ../beacon_node_common, ../networking/eth2_network,
  ../consensus_object_pools/[blockchain_dag, exit_pool],
  ../spec/[crypto, digest, datatypes],
  ../ssz/merkleization,
  rest_utils
export json_serialization

Json.createFlavor RestJson

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

template hexCompressed(data: openarray[byte]): string =
  let offset =
    block:
      var res = 0
      for i in 0 ..< len(data):
        if data[i] != 0x00'u8:
          res = i
          break
      res
  "0x" & ncrutils.toHex(data.toOpenArray(offset, len(data) - 1), true)

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
  writeValue(writer, hexCompressed(value.bytes()))

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

## EthAddress
proc readValue*(reader: var JsonReader[RestJson], value: var EthAddress) {.
     raises: [IOError, SerializationError, Defect].} =
  try:
    hexToByteArray(reader.readValue(string), value.data)
  except ValueError:
    raiseUnexpectedValue(reader,
                         "EthAddress value should be a valid hex string")

proc writeValue*(writer: var JsonWriter[RestJson], value: EthAddress) {.
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
    except SerializationError as exc:
      return err("Unable to deserialize data")
    except CatchableError as exc:
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
