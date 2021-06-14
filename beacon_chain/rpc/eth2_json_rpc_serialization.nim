# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

# The serializations in this file are approximations of
# https://ethereum.github.io/eth2.0-APIs/#/ but where written before the standard
# had materialized - they've now made it out to releases which means the easiest
# thing to do is to maintain them as-is, even if there are mismatches. In
# particular, numbers are serialized as strings in the eth2 API - here, they
# use numbers instead.
#
# Using numbers creates problems - uint64 which often appears in eth2 can't
# portably be represented since many json parsers balk at anything >2^53 and
# start losing precision. The other issue is the json parser in nim - it can't
# handle numbers >2^63, either crashing or giving wrong results:
# https://github.com/status-im/nimbus-eth2/issues/2430

import
  # Standard library
  std/[tables, typetraits],

  # Nimble packages
  stew/byteutils,
  json_rpc/jsonmarshal,

  # Local modules
  ../spec/[datatypes, crypto, digest]

export jsonmarshal, datatypes, crypto, digest

proc toJsonHex(data: openArray[byte]): string =
  # Per the eth2 API spec, hex arrays are printed with leading 0x
  "0x" & toHex(data)

proc fromJson*(n: JsonNode, argName: string, result: var ValidatorPubKey) {.raises: [Defect, ValueError].} =
  n.kind.expect(JString, argName)
  var tmp = ValidatorPubKey.fromHex(n.getStr()).tryGet()
  if not tmp.loadWithCache().isSome():
    raise (ref ValueError)(msg: "Invalid public BLS key")
  result = tmp

proc `%`*(pubkey: ValidatorPubKey): JsonNode =
  newJString(toJsonHex(toRaw(pubkey)))

proc fromJson*(n: JsonNode, argName: string, result: var List) {.raises: [Defect, ValueError].} =
  fromJson(n, argName, asSeq result)

proc `%`*(list: List): JsonNode = %(asSeq(list))

proc fromJson*(n: JsonNode, argName: string, result: var BitList) {.raises: [Defect, ValueError].} =
  n.kind.expect(JString, argName)
  result = type(result)(hexToSeqByte(n.getStr()))

proc `%`*(bitlist: BitList): JsonNode =
  newJString(toJsonHex(seq[byte](BitSeq(bitlist))))

proc fromJson*(n: JsonNode, argName: string, result: var ValidatorSig) {.raises: [Defect, ValueError].} =
  n.kind.expect(JString, argName)
  result = ValidatorSig.fromHex(n.getStr()).tryGet()

proc `%`*(value: ValidatorSig): JsonNode =
  newJString(toJsonHex(toRaw(value)))

proc fromJson*(n: JsonNode, argName: string, result: var TrustedSig) {.raises: [Defect, ValueError].} =
  n.kind.expect(JString, argName)
  hexToByteArray(n.getStr(), result.data)

proc `%`*(value: TrustedSig): JsonNode =
  newJString(toJsonHex(toRaw(value)))

proc fromJson*(n: JsonNode, argName: string, result: var Version) {.raises: [Defect, ValueError].} =
  n.kind.expect(JString, argName)
  hexToByteArray(n.getStr(), array[4, byte](result))

proc `%`*(value: Version): JsonNode =
  newJString(toJsonHex(distinctBase(value)))

template genFromJsonForIntType(T: untyped) =
  proc fromJson*(n: JsonNode, argName: string, result: var T) {.raises: [Defect, ValueError].} =
    n.kind.expect(JInt, argName)
    let asInt = n.getBiggestInt()
    when T is Epoch:
      if asInt == -1:
        # TODO: This is a major hack here. Since the json library
        # cannot handle properly 0xffffffff when serializing and
        # deserializing uint64 values, we detect one known wrong
        # result, appering in most `Validator` records. To fix
        # this issue, we'll have to switch to nim-json-serialization
        # in nim-json-rpc or work towards implementing a fix upstream.
        result = FAR_FUTURE_EPOCH
        return
    if asInt < 0:
      # signed -> unsigned conversions are unchecked
      # https://github.com/nim-lang/RFCs/issues/175
      raise newException(
        ValueError, "JSON-RPC input is an unexpected negative value")
    result = T(asInt)

genFromJsonForIntType(Epoch)
genFromJsonForIntType(Slot)
genFromJsonForIntType(CommitteeIndex)
genFromJsonForIntType(ValidatorIndex)

proc `%`*(value: Epoch): JsonNode =
  # In nim <= 1.2.6, `uint64` was silently cast to int64 resulting in
  # FAR_FUTURE_EPOCH showing as -1 - this is a hack to maintain that behaviour
  # in a world where a Defect or an actual correct value is used - the eth2
  # REST api instead prints all epochs and similar large numbers as strings!
  # See also https://github.com/status-im/nimbus-eth2/issues/2430
  newJInt(cast[int64](value))

proc `%`*(value: Slot): JsonNode =
  newJInt(cast[int64](value))

proc `%`*(value: GraffitiBytes): JsonNode =
  newJString(toJsonHex(distinctBase(value)))

proc fromJson*(n: JsonNode, argName: string, value: var GraffitiBytes) {.raises: [Defect, ValueError].} =
  n.kind.expect(JString, argName)
  value = GraffitiBytes.init n.getStr()

proc `%`*(value: CommitteeIndex): JsonNode =
  newJInt(value.BiggestInt)

proc `%`*(value: ValidatorIndex): JsonNode =
  newJInt(value.BiggestInt)

proc `%`*(value: Eth2Digest): JsonNode =
  newJString(toJsonHex(value.data))

proc fromJson*(n: JsonNode, argName: string, result: var Eth2Digest) {.raises: [Defect, ValueError].} =
  n.kind.expect(JString, argName)
  hexToByteArray(n.getStr(), result.data)

proc `%`*(value: BitSeq): JsonNode =
  newJString(toJsonHex(value.bytes))

proc fromJson*(n: JsonNode, argName: string, result: var BitSeq) {.raises: [Defect, ValueError].} =
  n.kind.expect(JString, argName)
  result = BitSeq(hexToSeqByte(n.getStr()))
