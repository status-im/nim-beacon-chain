# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, nimcrypto, eth/common, sequtils, options, blscurve,
  ../beacon_chain/ssz, ../beacon_chain/spec/datatypes

func filled[N: static[int], T](typ: type array[N, T], value: T): array[N, T] =
  for val in result.mitems:
    val = value

func filled(T: type MDigest, value: byte): T =
  for val in result.data.mitems:
    val = value

suite "Simple serialization":
  # pending spec updates in
  #   - https://github.com/ethereum/eth2.0-specs
  type
    Foo = object
      f0: uint8
      f1: uint32
      f2: EthAddress
      f3: MDigest[256]
      f4: seq[byte]
      f5: ValidatorIndex

  let expected_deser = Foo(
      f0: 5,
      f1: 0'u32 - 3,
      f2: EthAddress.filled(byte 35),
      f3: MDigest[256].filled(byte 35),
      f4: @[byte 'c'.ord, 'o'.ord, 'w'.ord],
      f5: ValidatorIndex(79)
    )

  var expected_ser = @[
      byte 67, 0, 0, 0, # length
      5,
      0xFD, 0xFF, 0xFF, 0xFF,
    ]
  expected_ser &= EthAddress.filled(byte 35)
  expected_ser &= MDigest[256].filled(byte 35).data
  expected_ser &= [byte 3, 0, 0, 0, 'c'.ord, 'o'.ord, 'w'.ord]
  expected_ser &= [byte 79, 0, 0]

  test "Object deserialization":
    let deser = expected_ser.deserialize(Foo).get()
    check: expected_deser == deser

  test "Object serialization":
    let ser = expected_deser.serialize()
    check: expected_ser == ser

  test "Not enough data":
    check:
      expected_ser[0..^2].deserialize(Foo).isNone()
      expected_ser[1..^1].deserialize(Foo).isNone()

  test "ValidatorIndex roundtrip":
    # https://github.com/nim-lang/Nim/issues/10027
    let v = 79.ValidatorIndex
    let ser = v.serialize()
    check:
      ser.len() == 3
      deserialize(ser, type(v)).get() == v

  test "Array roundtrip":
    let v = [1, 2, 3]
    let ser = v.serialize()
    check:
      deserialize(ser, type(v)).get() == v

  test "Seq roundtrip":
    let v = @[1, 2, 3]
    let ser = v.serialize()

    check:
      deserialize(ser, type(v)).get() == v

  test "Key roundtrip":
    let v = SigKey.random().getKey()
    let ser = v.serialize()

    check:
      deserialize(ser, type(v)).get() == v

  # Just to see that we can serialize stuff at all
  test "Roundtrip main eth2 types":
    let
      bb = BeaconBlock(
        slot: 42,
        signature: sign(SigKey.random(), 0'u64, "")
        )
      bs = BeaconState(slot: 42)

    check:
      bb.serialize().deserialize(BeaconBlock).get() == bb
      bs.serialize().deserialize(BeaconState).get() == bs

suite "Tree hashing":
  # TODO Nothing but smoke tests for now..

  test "Hash Validator":
    let vr = Validator()
    check: hash_tree_root(vr).len > 0

  test "Hash ShardCommittee":
    let sc = ShardCommittee()
    check: hash_tree_root(sc).len > 0

  test "Hash BeaconBlock":
    ## TODO: Test genesis hash when spec is updated
    let bb = BeaconBlock()
    check: hash_tree_root(bb).len > 0

  test "Hash integer":
    check: hash_tree_root(0x01'u32) == [1'u8, 0, 0, 0] # little endian!
    check: hash_tree_root(ValidatorIndex(0x01)) == [1'u8, 0, 0] # little endian!
