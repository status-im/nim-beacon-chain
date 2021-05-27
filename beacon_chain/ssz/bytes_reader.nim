# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

{.pragma: raisesssz, raises: [Defect, MalformedSszError, SszSizeMismatchError].}

import
  std/[typetraits, options],
  stew/[endians2, objects],
  ../spec/[digest, datatypes], ./types, ./spec_types, ./merkleization

template raiseIncorrectSize(T: type) =
  const typeName = name(T)
  raise newException(MalformedSszError,
                     "SSZ " & typeName & " input of incorrect size")

template setOutputSize[R, T](a: var array[R, T], length: int) =
  if length != a.len:
    raiseIncorrectSize a.type

proc setOutputSize(list: var List, length: int) {.raisesssz.} =
  if not list.setLen length:
    raise newException(MalformedSszError, "SSZ list maximum size exceeded")

# fromSszBytes copies the wire representation to a Nim variable,
# assuming there's enough data in the buffer
func fromSszBytes*(T: type UintN, data: openArray[byte]): T {.raisesssz.} =
  ## Convert directly to bytes the size of the int. (e.g. ``uint16 = 2 bytes``)
  ## All integers are serialized as **little endian**.
  if data.len != sizeof(result):
    raiseIncorrectSize T

  T.fromBytesLE(data)

func fromSszBytes*(T: type bool, data: openArray[byte]): T {.raisesssz.} =
  # Strict: only allow 0 or 1
  if data.len != 1 or byte(data[0]) > byte(1):
    raise newException(MalformedSszError, "invalid boolean value")
  data[0] == 1

func fromSszBytes*(T: type Eth2Digest, data: openArray[byte]): T {.raisesssz.} =
  if data.len != sizeof(result.data):
    raiseIncorrectSize T
  copyMem(result.data.addr, unsafeAddr data[0], sizeof(result.data))

func fromSszBytes*(T: type GraffitiBytes, data: openArray[byte]): T {.raisesssz.} =
  if data.len != sizeof(result):
    raiseIncorrectSize T
  copyMem(result.addr, unsafeAddr data[0], sizeof(result))

template fromSszBytes*(T: type Slot, bytes: openArray[byte]): T =
  T fromSszBytes(uint64, bytes)

template fromSszBytes*(T: type Epoch, bytes: openArray[byte]): T =
  T fromSszBytes(uint64, bytes)

template fromSszBytes*(T: type ValidatorIndex, bytes: openArray[byte]): T =
  T fromSszBytes(uint64, bytes)

func fromSszBytes*(T: type ForkDigest, bytes: openArray[byte]): T {.raisesssz.} =
  if bytes.len != sizeof(result):
    raiseIncorrectSize T
  copyMem(result.addr, unsafeAddr bytes[0], sizeof(result))

func fromSszBytes*(T: type Version, bytes: openArray[byte]): T {.raisesssz.} =
  if bytes.len != sizeof(result):
    raiseIncorrectSize T
  copyMem(result.addr, unsafeAddr bytes[0], sizeof(result))

template fromSszBytes*(T: type BitSeq, bytes: openArray[byte]): auto =
  BitSeq @bytes

proc `[]`[T, U, V](s: openArray[T], x: HSlice[U, V]) {.error:
  "Please don't use openArray's [] as it allocates a result sequence".}

template checkForForbiddenBits(ResulType: type,
                               input: openArray[byte],
                               expectedBits: static int64) =
  ## This checks if the input contains any bits set above the maximum
  ## sized allowed. We only need to check the last byte to verify this:
  const bitsInLastByte = (expectedBits mod 8)
  when bitsInLastByte != 0:
    # As an example, if there are 3 bits expected in the last byte,
    # we calculate a bitmask equal to 11111000. If the input has any
    # raised bits in range of the bitmask, this would be a violation
    # of the size of the BitArray:
    const forbiddenBitsMask = byte(byte(0xff) shl bitsInLastByte)

    if (input[^1] and forbiddenBitsMask) != 0:
      raiseIncorrectSize ResulType

func readSszValue*[T](input: openArray[byte],
                      val: var T, updateRoot: bool = true) {.raisesssz.} =
  mixin fromSszBytes, toSszType

  template readOffsetUnchecked(n: int): uint32 {.used.}=
    fromSszBytes(uint32, input.toOpenArray(n, n + offsetSize - 1))

  template readOffset(n: int): int {.used.} =
    let offset = readOffsetUnchecked(n)
    if offset > input.len.uint32:
      raise newException(MalformedSszError, "SSZ list element offset points past the end of the input")
    int(offset)

  #when result is List:
  #  result.setOutputSize input.len
  #  readOpenArray(toSeq result, input)

  #elif result is array:
  #  result.checkOutputSize input.len
  #  readOpenArray(result, input)

  when val is BitList:
    if input.len == 0:
      raise newException(MalformedSszError, "Invalid empty SSZ BitList value")

    # Since our BitLists have an in-memory representation that precisely
    # matches their SSZ encoding, we can deserialize them as regular Lists:
    const maxExpectedSize = (val.maxLen div 8) + 1
    type MatchingListType = List[byte, maxExpectedSize]

    when false:
      # TODO: Nim doesn't like this simple type coercion,
      #       we'll rely on `cast` for now (see below)
      readSszValue(input, MatchingListType val)
    else:
      static:
        # As a sanity check, we verify that the coercion is accepted by the compiler:
        doAssert MatchingListType(val) is MatchingListType
      readSszValue(input, cast[ptr MatchingListType](addr val)[])

    let resultBytesCount = len bytes(val)

    if bytes(val)[resultBytesCount - 1] == 0:
      raise newException(MalformedSszError, "SSZ BitList is not properly terminated")

    if resultBytesCount == maxExpectedSize:
      checkForForbiddenBits(T, input, val.maxLen + 1)

  elif val is HashList | HashArray:
    readSszValue(input, val.data)
    val.resetCache()

  elif val is List|array:
    type E = type val[0]

    when E is byte:
      val.setOutputSize input.len
      if input.len > 0:
        copyMem(addr val[0], unsafeAddr input[0], input.len)

    elif isFixedSize(E):
      const elemSize = fixedPortionSize(E)
      if input.len mod elemSize != 0:
        var ex = new SszSizeMismatchError
        ex.deserializedType = cstring typetraits.name(T)
        ex.actualSszSize = input.len
        ex.elementSize = elemSize
        raise ex
      val.setOutputSize input.len div elemSize
      for i in 0 ..< val.len:
        let offset = i * elemSize
        readSszValue(input.toOpenArray(offset, offset + elemSize - 1), val[i])

    else:
      if input.len == 0:
        # This is an empty list.
        # The default initialization of the return value is fine.
        val.setOutputSize 0
        return
      elif input.len < offsetSize:
        raise newException(MalformedSszError, "SSZ input of insufficient size")

      var offset = readOffset 0
      let resultLen = offset div offsetSize

      if resultLen == 0:
        # If there are too many elements, other constraints detect problems
        # (not monotonically increasing, past end of input, or last element
        # not matching up with its nextOffset properly)
        raise newException(MalformedSszError, "SSZ list incorrectly encoded of zero length")

      val.setOutputSize resultLen
      for i in 1 ..< resultLen:
        let nextOffset = readOffset(i * offsetSize)
        if nextOffset <= offset:
          raise newException(MalformedSszError, "SSZ list element offsets are not monotonically increasing")
        else:
          readSszValue(input.toOpenArray(offset, nextOffset - 1), val[i - 1])
        offset = nextOffset

      readSszValue(input.toOpenArray(offset, input.len - 1), val[resultLen - 1])

  elif val is UintN|bool:
    val = fromSszBytes(T, input)

  elif val is BitArray:
    if sizeof(val) != input.len:
      raiseIncorrectSize(T)
    checkForForbiddenBits(T, input, val.bits)
    copyMem(addr val.bytes[0], unsafeAddr input[0], input.len)

  elif val is object|tuple:
    let inputLen = uint32 input.len
    const minimallyExpectedSize = uint32 fixedPortionSize(T)

    if inputLen < minimallyExpectedSize:
      raise newException(MalformedSszError, "SSZ input of insufficient size")

    enumInstanceSerializedFields(val, fieldName, field):
      const boundingOffsets = getFieldBoundingOffsets(T, fieldName)

      # type FieldType = type field # buggy
      # For some reason, Nim gets confused about the alias here. This could be a
      # generics caching issue caused by the use of distinct types. Such an
      # issue is very scary in general.
      # The bug can be seen with the two List[uint64, N] types that exist in
      # the spec, with different N.

      type SszType = type toSszType(declval type(field))

      when isFixedSize(SszType):
        const
          startOffset = boundingOffsets[0]
          endOffset = boundingOffsets[1]
      else:
        let
          startOffset = readOffsetUnchecked(boundingOffsets[0])
          endOffset = if boundingOffsets[1] == -1: inputLen
                      else: readOffsetUnchecked(boundingOffsets[1])

        when boundingOffsets.isFirstOffset:
          if startOffset != minimallyExpectedSize:
            raise newException(MalformedSszError, "SSZ object dynamic portion starts at invalid offset")

        if startOffset > endOffset:
          raise newException(MalformedSszError, "SSZ field offsets are not monotonically increasing")
        elif endOffset > inputLen:
          raise newException(MalformedSszError, "SSZ field offset points past the end of the input")
        elif startOffset < minimallyExpectedSize:
          raise newException(MalformedSszError, "SSZ field offset points outside bounding offsets")

      # TODO The extra type escaping here is a work-around for a Nim issue:
      when type(field) is type(SszType):
        readSszValue(
          input.toOpenArray(int(startOffset), int(endOffset - 1)),
          field)
      else:
        field = fromSszBytes(
          type(field),
          input.toOpenArray(int(startOffset), int(endOffset - 1)))

    when val is SignedBeaconBlock | TrustedSignedBeaconBlock:
      if updateRoot:
        val.root = hash_tree_root(val.message)
  else:
    unsupported T
