{.used.}

import
  unittest2,
  std/[sequtils, strformat],
  ssz_serialization/bitseqs,
  ./testutil

suite "Bit fields":
  test "roundtrips BitArray":
    var
      a = BitArray[100]()
      b = BitArray[100]()
      c = BitArray[100]()

    check:
      not a[0]

    a.setBit 1

    check:
      not a[0]
      a[1]
      toSeq(a.oneIndices()) == [1]

      a + b == a
      a - b == a
      a - a == c # empty

      b + a == a
      b - b == c # b is empty

    b.setBit 2

    check:
      (a + b)[2]
      (b - a)[2]
      not (b - a)[1]

    a.setBit 99

    check:
      (a + b)[99]
      (b - a)[2]
      not (b - a)[1]
      not (b - a)[99]
      toSeq(a.oneIndices()) == [1, 99]

    a.incl(b)

    check:
      not a[0]
      a[1]
      a[2]

    a.clear()
    check:
      not a[1]

  test "roundtrips BitSeq":
    var
      a = BitSeq.init(100)
      b = BitSeq.init(100)

    check:
      not a[0]
      a.isZeros()

    a.setBit 1

    check:
      not a[0]
      a[1]
      a.countOnes() == 1
      a.countZeros() == 99
      not a.isZeros()
      a.countOverlap(a) == 1

    b.setBit 2

    a.incl(b)

    check:
      not a[0]
      a[1]
      a[2]
      a.countOverlap(a) == 2
      a.countOverlap(b) == 1
      b.countOverlap(a) == 1
      b.countOverlap(b) == 1
    a.clear()
    check:
      not a[1]

  test "iterating words":
    for bitCount in [8, 3, 7, 8, 14, 15, 16, 19, 260]:
      checkpoint &"trying bit count {bitCount}"
      var
        a = BitSeq.init(bitCount)
        b = BitSeq.init(bitCount)
        bitsInWord = sizeof(uint) * 8
        expectedWordCount = (bitCount div bitsInWord) + 1

      for i in 0 ..< expectedWordCount:
        let every3rdBit = i * sizeof(uint) * 8 + 2
        a[every3rdBit] = true
        b[every3rdBit] = true

      for word in words(a):
        check word == 4
        word = 2

      for wa, wb in words(a, b):
        check wa == 2 and wb == 4
        wa = 1
        wb = 2

      for i in 0 ..< expectedWordCount:
        for j in 0 ..< bitsInWord:
          let bitPos = i * bitsInWord + j
          if bitPos < bitCount:
            check a[j] == (j == 0)
            check b[j] == (j == 1)

  test "overlaps":
    for bitCount in [1, 62, 63, 64, 91, 127, 128, 129]:
      checkpoint &"trying bit count {bitCount}"
      var
        a = BitSeq.init(bitCount)
        b = BitSeq.init(bitCount)

      for pos in [4, 8, 9, 12, 29, 32, 63, 64, 67]:
        if pos + 2 < bitCount:
          a.setBit(pos)
          b.setBit(pos + 2)

      check:
        not a.overlaps(b)
        not b.overlaps(a)
        a.countOverlap(b) == 0
