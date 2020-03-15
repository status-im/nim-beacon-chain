# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  os, unittest, strutils, streams, strformat, strscans,
  macros, typetraits,
  # Status libraries
  faststreams, stint, stew/bitseqs, ../testutil,
  # Third-party
  yaml,
  # Beacon chain internals
  ../../beacon_chain/spec/[datatypes, digest],
  ../../beacon_chain/ssz,
  # Test utilities
  ./fixtures_utils

# Parsing definitions
# ------------------------------------------------------------------------

const
  SSZDir = FixturesDir/"tests-v0.11.0"/"general"/"phase0"/"ssz_generic"

type
  SSZHashTreeRoot = object
    # The test files have the values at the "root"
    # so we **must** use "root" as a field name
    root: string
    # Containers have a root (thankfully) and signing_root field
    signing_root: string

  UnconsumedInput* = object of CatchableError
  TestSizeError* = object of ValueError

# Make signing root optional
setDefaultValue(SSZHashTreeRoot, signing_root, "")

type
  # Heterogeneous containers
  SingleFieldTestStruct = object
    A: byte

  SmallTestStruct = object
    A, B: uint16

  FixedTestStruct = object
    A: uint8
    B: uint64
    C: uint32

  VarTestStruct = object
    A: uint16
    B: List[uint16, 1024]
    C: uint8

  ComplexTestStruct = object
    A: uint16
    B: List[uint16, 128]
    C: uint8
    D: array[256, byte]
    E: VarTestStruct
    F: array[4, FixedTestStruct]
    G: array[2, VarTestStruct]

  BitsStruct = object
    A: BitList[5]
    B: BitArray[2]
    C: BitArray[1]
    D: BitList[6]
    E: BitArray[8]

# Type specific checks
# ------------------------------------------------------------------------

proc checkBasic(T: typedesc,
                dir: string,
                expectedHash: SSZHashTreeRoot) =
  var fileContents = readFile(dir/"serialized.ssz")
  var stream = memoryStream(fileContents)
  var reader = init(SszReader, stream)

  # We are using heap allocation to avoid stack overflow
  # issues caused by large objects such as `BeaconState`:
  var deserialized = new T
  reader.readValue(deserialized[])

  if not stream[].eof:
    raise newException(UnconsumedInput, "Remaining bytes in the input")

  let
    expectedHash = expectedHash.root
    actualHash = "0x" & toLowerASCII($deserialized.hashTreeRoot())
  check expectedHash == actualHash

  # TODO check the value

macro testVector(typeIdent: string, size: int): untyped =
  # find the compile-time type to test
  # against the runtime combination (cartesian product) of
  #
  # types: bool, uint8, uint16, uint32, uint64, uint128, uint256
  # sizes: 1, 2, 3, 4, 5, 8, 16, 31, 512, 513
  #
  # We allocate in a ref array to not run out of stack space
  let types = ["bool", "uint8", "uint16", "uint32", "uint64"] # "uint128", "uint256"]
  let sizes = [1, 2, 3, 4, 5, 8, 16, 31, 512, 513]

  var dispatcher = nnkIfStmt.newTree()
  for t in types:
    # if typeIdent == t // elif typeIdent == t
    var sizeDispatch = nnkIfStmt.newTree()
    for s in sizes:
      # if size == s // elif size == s
      let T = nnkBracketExpr.newTree(
        ident"array", newLit(s), ident(t)
      )
      var testStmt = quote do:
        checkBasic(`T`, dir, expectedHash)
      sizeDispatch.add nnkElifBranch.newTree(
        newCall(ident"==", size, newLit(s)),
        testStmt
      )
    sizeDispatch.add nnkElse.newTree quote do:
      raise newException(TestSizeError,
        "Unsupported **size** in type/size combination: array[" &
        $size & "," & typeIdent & ']')
    dispatcher.add nnkElifBranch.newTree(
      newCall(ident"==", typeIdent, newLit(t)),
      sizeDispatch
    )
  dispatcher.add nnkElse.newTree quote do:
    # TODO: support uint128 and uint256
    if `typeIdent` != "uint128" and `typeIdent` != "uint256":
      raise newException(ValueError,
        "Unsupported **type** in type/size combination: array[" &
        $`size` & ", " & `typeIdent` & ']')

  result = dispatcher
  # echo result.toStrLit() # view the generated code

proc checkVector(sszSubType, dir: string, expectedHash: SSZHashTreeRoot) =
  var typeIdent: string
  var size: int
  let wasMatched = scanf(sszSubType, "vec_$+_$i", typeIdent, size)
  doAssert wasMatched
  testVector(typeIdent, size)

proc checkBitVector(sszSubType, dir: string, expectedHash: SSZHashTreeRoot) =
  var size: int
  let wasMatched = scanf(sszSubType, "bitvec_$i", size)
  doAssert wasMatched
  case size
  of 1: checkBasic(BitArray[1], dir, expectedHash)
  of 2: checkBasic(BitArray[2], dir, expectedHash)
  of 3: checkBasic(BitArray[3], dir, expectedHash)
  of 4: checkBasic(BitArray[4], dir, expectedHash)
  of 5: checkBasic(BitArray[5], dir, expectedHash)
  of 8: checkBasic(BitArray[8], dir, expectedHash)
  of 9: checkBasic(BitArray[9], dir, expectedHash)
  of 16: checkBasic(BitArray[16], dir, expectedHash)
  of 31: checkBasic(BitArray[31], dir, expectedHash)
  of 32: checkBasic(BitArray[32], dir, expectedHash)
  of 512: checkBasic(BitArray[512], dir, expectedHash)
  of 513: checkBasic(BitArray[513], dir, expectedHash)
  else:
    raise newException(TestSizeError, "Unsupported BitVector of size " & $size)

# TODO: serialization of "type BitList[maxLen] = distinct BitSeq is not supported"
#       https://github.com/status-im/nim-beacon-chain/issues/518
# proc checkBitList(sszSubType, dir: string, expectedHash: SSZHashTreeRoot) =
#   var maxLen: int
#   let wasMatched = scanf(sszSubType, "bitlist_$i", maxLen)
#   case maxLen
#   of 1: checkBasic(BitList[1], dir, expectedHash)
#   of 2: checkBasic(BitList[2], dir, expectedHash)
#   of 3: checkBasic(BitList[3], dir, expectedHash)
#   of 4: checkBasic(BitList[4], dir, expectedHash)
#   of 5: checkBasic(BitList[5], dir, expectedHash)
#   of 8: checkBasic(BitList[8], dir, expectedHash)
#   of 16: checkBasic(BitList[16], dir, expectedHash)
#   of 31: checkBasic(BitList[31], dir, expectedHash)
#   of 512: checkBasic(BitList[512], dir, expectedHash)
#   of 513: checkBasic(BitList[513], dir, expectedHash)
#   else:
#     raise newException(ValueError, "Unsupported Bitlist of max length " & $maxLen)

# Test dispatch for valid inputs
# ------------------------------------------------------------------------

proc sszCheck(baseDir, sszType, sszSubType: string) =
  let dir = baseDir/sszSubType

  # Hash tree root
  var expectedHash: SSZHashTreeRoot
  if fileExists(dir/"meta.yaml"):
    var s = openFileStream(dir/"meta.yaml")
    defer: close(s)
    yaml.load(s, expectedHash)

  # Deserialization and checks
  case sszType
  of "boolean": checkBasic(bool, dir, expectedHash)
  of "uints":
    var bitsize: int
    let wasMatched = scanf(sszSubType, "uint_$i", bitsize)
    doAssert wasMatched
    case bitsize
    of 8:  checkBasic(uint8, dir, expectedHash)
    of 16: checkBasic(uint16, dir, expectedHash)
    of 32: checkBasic(uint32, dir, expectedHash)
    of 64: checkBasic(uint64, dir, expectedHash)
    of 128:
      # Compile-time issues
      discard # checkBasic(Stuint[128], dir, expectedHash)
    of 256:
      # Compile-time issues
      discard # checkBasic(Stuint[256], dir, expectedHash)
    else:
      raise newException(ValueError, "unknown uint in test: " & sszSubType)
  of "basic_vector": checkVector(sszSubType, dir, expectedHash)
  of "bitvector": checkBitVector(sszSubType, dir, expectedHash)
  # of "bitlist": checkBitList(sszSubType, dir, expectedHash)
  of "containers":
    var name: string
    let wasMatched = scanf(sszSubtype, "$+_", name)
    doAssert wasMatched
    case name
    of "SingleFieldTestStruct": checkBasic(SingleFieldTestStruct, dir, expectedHash)
    of "SmallTestStruct": checkBasic(SmallTestStruct, dir, expectedHash)
    of "FixedTestStruct": checkBasic(FixedTestStruct, dir, expectedHash)
    of "VarTestStruct":
      # Runtime issues
      discard # checkBasic(VarTestStruct, dir, expectedHash)
    of "ComplexTestStruct":
      # Compile-time issues
      discard # checkBasic(ComplexTestStruct, dir, expectedHash)
    of "BitsStruct":
      # Compile-time issues
      discard # checkBasic(BitsStruct, dir, expectedHash)
    else:
      raise newException(ValueError, "unknown container in test: " & sszSubType)
  else:
    raise newException(ValueError, "unknown ssz type in test: " & sszType)

# Test dispatch for invalid inputs
# ------------------------------------------------------------------------

# TODO

# Test runner
# ------------------------------------------------------------------------

proc runSSZtests() =
  doAssert existsDir(SSZDir), "You need to run the \"download_test_vectors.sh\" script to retrieve the official test vectors."
  for pathKind, sszType in walkDir(SSZDir, relative = true):
    doAssert pathKind == pcDir
    if sszType == "bitlist":
      timedTest &"**Skipping** {sszType} inputs - valid - skipped altogether":
        # TODO: serialization of "type BitList[maxLen] = distinct BitSeq is not supported"
        #       https://github.com/status-im/nim-beacon-chain/issues/518
        discard
      continue

    var skipped: string
    case sszType
    of "uints":
      skipped = " - skipping uint128 and uint256"
    of "basic_vector":
      skipped = " - skipping Vector[uint128, N] and Vector[uint256, N]"
    of "containers":
      skipped = " - skipping VarTestStruct, ComplexTestStruct, BitsStruct"

    timedTest &"Testing {sszType:12} inputs - valid" & skipped:
      let path = SSZDir/sszType/"valid"
      for pathKind, sszSubType in walkDir(path, relative = true):
        if pathKind != pcDir: continue
        sszCheck(path, sszType, sszSubType)

    timedTest &"Testing {sszType:12} inputs - invalid" & skipped:
      let path = SSZDir/sszType/"invalid"
      for pathKind, sszSubType in walkDir(path, relative = true):
        if pathKind != pcDir: continue
        try:
          sszCheck(path, sszType, sszSubType)
        except SszError, UnconsumedInput:
          discard
        except TestSizeError as err:
          echo err.msg
          skip()
        except:
          checkpoint getStackTrace(getCurrentException())
          checkpoint getCurrentExceptionMsg()
          check false

  # TODO: nim-serialization forces us to use exceptions as control flow
  #       as we always have to check user supplied inputs
  # Skipped
  # test "Testing " & name & " inputs (" & $T & ") - invalid":
  #   const path = SSZDir/name/"invalid"

suiteReport "Official - SSZ generic types":
  runSSZtests()

summarizeLongTests("FixtureSSZGeneric")
