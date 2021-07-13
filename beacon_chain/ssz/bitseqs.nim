# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  stew/[bitops2, endians2, ptrops]

type
  Bytes = seq[byte]

  BitSeq* = distinct Bytes
    ## The current design of BitSeq tries to follow precisely
    ## the bitwise representation of the SSZ bitlists.
    ## This is a relatively compact representation, but as
    ## evident from the code below, many of the operations
    ## are not trivial.

  BitArray*[bits: static int] = object
    bytes*: array[(bits + 7) div 8, byte]

func bitsLen*(bytes: openArray[byte]): int =
  let
    bytesCount = bytes.len
    lastByte = bytes[bytesCount - 1]
    markerPos = log2trunc(lastByte)

  bytesCount * 8 - (8 - markerPos)

template len*(s: BitSeq): int =
  bitsLen(Bytes s)

template len*(a: BitArray): int =
  a.bits

func add*(s: var BitSeq, value: bool) =
  let
    lastBytePos = s.Bytes.len - 1
    lastByte = s.Bytes[lastBytePos]

  if (lastByte and byte(128)) == 0:
    # There is at least one leading zero, so we have enough
    # room to store the new bit
    let markerPos = log2trunc(lastByte)
    s.Bytes[lastBytePos].changeBit markerPos, value
    s.Bytes[lastBytePos].setBit markerPos + 1
  else:
    s.Bytes[lastBytePos].changeBit 7, value
    s.Bytes.add byte(1)

func toBytesLE(x: uint): array[sizeof(x), byte] =
  # stew/endians2 supports explicitly sized uints only
  when sizeof(uint) == 4:
    static: doAssert sizeof(uint) == sizeof(uint32)
    toBytesLE(x.uint32)
  elif sizeof(uint) == 8:
    static: doAssert sizeof(uint) == sizeof(uint64)
    toBytesLE(x.uint64)
  else:
    static: doAssert false, "requires a 32-bit or 64-bit platform"

func loadLEBytes(WordType: type, bytes: openArray[byte]): WordType =
  # TODO: this is a temporary proc until the endians API is improved
  var shift = 0
  for b in bytes:
    result = result or (WordType(b) shl shift)
    shift += 8

func storeLEBytes(value: SomeUnsignedInt, dst: var openArray[byte]) =
  doAssert dst.len <= sizeof(value)
  let bytesLE = toBytesLE(value)
  copyMem(addr dst[0], unsafeAddr bytesLE[0], dst.len)

template loopOverWords(lhs, rhs: BitSeq,
                       lhsIsVar, rhsIsVar: static bool,
                       WordType: type,
                       lhsBits, rhsBits, body: untyped) =
  const hasRhs = astToStr(lhs) != astToStr(rhs)

  let bytesCount = len Bytes(lhs)
  when hasRhs: doAssert len(Bytes(rhs)) == bytesCount

  var fullWordsCount = bytesCount div sizeof(WordType)
  let lastWordSize = bytesCount mod sizeof(WordType)

  block:
    var lhsWord: WordType
    when hasRhs:
      var rhsWord: WordType
    var firstByteOfLastWord, lastByteOfLastWord: int

    # TODO: Returning a `var` value from an iterator is always safe due to
    # the way inlining works, but currently the compiler reports an error
    # when a local variable escapes. We have to cheat it with this location
    # obfuscation through pointers:
    template lhsBits: auto = (addr(lhsWord))[]

    when hasRhs:
      template rhsBits: auto = (addr(rhsWord))[]

    template lastWordBytes(bitseq): auto =
      Bytes(bitseq).toOpenArray(firstByteOfLastWord, lastByteOfLastWord)

    template initLastWords =
      lhsWord = loadLEBytes(WordType, lastWordBytes(lhs))
      when hasRhs: rhsWord = loadLEBytes(WordType, lastWordBytes(rhs))

    if lastWordSize == 0:
      firstByteOfLastWord = bytesCount - sizeof(WordType)
      lastByteOfLastWord  = bytesCount - 1
      dec fullWordsCount
    else:
      firstByteOfLastWord = bytesCount - lastWordSize
      lastByteOfLastWord  = bytesCount - 1

    initLastWords()
    let markerPos = log2trunc(lhsWord)
    when hasRhs: doAssert log2trunc(rhsWord) == markerPos

    lhsWord.clearBit markerPos
    when hasRhs: rhsWord.clearBit markerPos

    body

    when lhsIsVar or rhsIsVar:
      let
        markerBit = uint(1 shl markerPos)
        mask = markerBit - 1'u

      when lhsIsVar:
        let lhsEndResult = (lhsWord and mask) or markerBit
        storeLEBytes(lhsEndResult, lastWordBytes(lhs))

      when rhsIsVar:
        let rhsEndResult = (rhsWord and mask) or markerBit
        storeLEBytes(rhsEndResult, lastWordBytes(rhs))

  var lhsCurrAddr = cast[ptr WordType](unsafeAddr Bytes(lhs)[0])
  let lhsEndAddr = offset(lhsCurrAddr, fullWordsCount)
  when hasRhs:
    var rhsCurrAddr = cast[ptr WordType](unsafeAddr Bytes(rhs)[0])

  while lhsCurrAddr < lhsEndAddr:
    template lhsBits: auto = lhsCurrAddr[]
    when hasRhs:
      template rhsBits: auto = rhsCurrAddr[]

    body

    lhsCurrAddr = offset(lhsCurrAddr, 1)
    when hasRhs: rhsCurrAddr = offset(rhsCurrAddr, 1)

iterator words*(x: var BitSeq): var uint =
  loopOverWords(x, x, true, false, uint, word, wordB):
    yield word

iterator words*(x: BitSeq): uint =
  loopOverWords(x, x, false, false, uint, word, word):
    yield word

iterator words*(a, b: BitSeq): (uint, uint) =
  loopOverWords(a, b, false, false, uint, wordA, wordB):
    yield (wordA, wordB)

iterator words*(a: var BitSeq, b: BitSeq): (var uint, uint) =
  loopOverWords(a, b, true, false, uint, wordA, wordB):
    yield (wordA, wordB)

iterator words*(a, b: var BitSeq): (var uint, var uint) =
  loopOverWords(a, b, true, true, uint, wordA, wordB):
    yield (wordA, wordB)

func `[]`*(s: BitSeq, pos: Natural): bool {.inline.} =
  doAssert pos < s.len
  s.Bytes.getBit pos

func `[]=`*(s: var BitSeq, pos: Natural, value: bool) {.inline.} =
  doAssert pos < s.len
  s.Bytes.changeBit pos, value

func setBit*(s: var BitSeq, pos: Natural) {.inline.} =
  doAssert pos < s.len
  setBit s.Bytes, pos

func clearBit*(s: var BitSeq, pos: Natural) {.inline.} =
  doAssert pos < s.len
  clearBit s.Bytes, pos

func init*(T: type BitSeq, len: int): T =
  result = BitSeq newSeq[byte](1 + len div 8)
  Bytes(result).setBit len

func init*(T: type BitArray): T =
  # The default zero-initializatio is fine
  discard

template `[]`*(a: BitArray, pos: Natural): bool =
  getBit a.bytes, pos

template `[]=`*(a: var BitArray, pos: Natural, value: bool) =
  changeBit a.bytes, pos, value

template setBit*(a: var BitArray, pos: Natural) =
  setBit a.bytes, pos

template clearBit*(a: var BitArray, pos: Natural) =
  clearBit a.bytes, pos

# TODO: Submit this to the standard library as `cmp`
# At the moment, it doesn't work quite well because Nim selects
# the generic cmp[T] from the system module instead of choosing
# the openArray overload
func compareArrays[T](a, b: openArray[T]): int =
  result = cmp(a.len, b.len)
  if result != 0: return

  for i in 0 ..< a.len:
    result = cmp(a[i], b[i])
    if result != 0: return

template cmp*(a, b: BitSeq): int =
  compareArrays(Bytes a, Bytes b)

template `==`*(a, b: BitSeq): bool =
  cmp(a, b) == 0

func `$`*(a: BitSeq | BitArray): string =
  let length = a.len
  result = newStringOfCap(2 + length)
  result.add "0b"
  for i in countdown(length - 1, 0):
    result.add if a[i]: '1' else: '0'

func incl*(tgt: var BitSeq, src: BitSeq) =
  # Update `tgt` to include the bits of `src`, as if applying `or` to each bit
  doAssert tgt.len == src.len
  for tgtWord, srcWord in words(tgt, src):
    tgtWord = tgtWord or srcWord

func overlaps*(a, b: BitSeq): bool =
  for wa, wb in words(a, b):
    if (wa and wb) != 0:
      return true

func countOverlap*(a, b: BitSeq): int =
  var res = 0
  for wa, wb in words(a, b):
    res += countOnes(wa and wb)
  res

func isSubsetOf*(a, b: BitSeq): bool =
  let alen = a.len
  doAssert b.len == alen
  for i in 0 ..< alen:
    if a[i] and not b[i]:
      return false
  true

func isZeros*(x: BitSeq): bool =
  for w in words(x):
    if w != 0: return false
  return true

func countOnes*(x: BitSeq): int =
  # Count the number of set bits
  var res = 0
  for w in words(x):
    res += w.countOnes()
  res

func clear*(x: var BitSeq) =
  for w in words(x):
    w = 0

func countZeros*(x: BitSeq): int =
  x.len() - x.countOnes()

template bytes*(x: BitSeq): untyped =
  seq[byte](x)

iterator items*(x: BitArray): bool =
  for i in 0..<x.bits:
    yield x[i]

iterator pairs*(x: BitArray): (int, bool) =
  for i in 0..<x.bits:
    yield (i, x[i])

func incl*(a: var BitArray, b: BitArray) =
  # Update `a` to include the bits of `b`, as if applying `or` to each bit
  for i in 0..<a.bytes.len:
    a[i] = a[i] or b[i]

func clear*(a: var BitArray) =
  for b in a.bytes.mitems(): b = 0

# Set operations
func `+`*(a, b: BitArray): BitArray =
  for i in 0..<a.bytes.len:
    result.bytes[i] = a.bytes[i] or b.bytes[i]

func `-`*(a, b: BitArray): BitArray =
  for i in 0..<a.bytes.len:
    result.bytes[i] = a.bytes[i] and (not b.bytes[i])

iterator oneIndices*(a: BitArray): int =
  for i in 0..<a.len:
    if a[i]: yield i

func countOnes*(a: BitArray): int =
  # TODO: This can be optimised to work on words
  for bit in a:
    if bit: inc result

