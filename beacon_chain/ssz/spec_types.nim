# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}
{.pragma: raisesssz, raises: [Defect, MalformedSszError, SszSizeMismatchError].}

import
  std/[typetraits], ssz_serialization/[bytes_reader, merkleization],
  ../spec/[crypto, digest, datatypes],
  ../spec/datatypes/[phase0, altair]

# Eth2-spec-specific type handling that is not generic to SSZ

template toSszType*(x: auto): auto =
  mixin toSszType

  # Please note that BitArray doesn't need any special treatment here
  # because it can be considered a regular fixed-size object type.

  # enum should not be added here as nim will raise Defect when value is out
  # of range
  when x is Slot|Epoch|ValidatorIndex: uint64(x)
  elif x is Eth2Digest: x.data
  elif x is BlsCurveType: toRaw(x)
  elif x is ForkDigest|Version|GraffitiBytes: distinctBase(x)
  else: x

func fromSszBytes*(T: type Eth2Digest, data: openArray[byte]): T
    {.raisesssz.} =
  if data.len != sizeof(result.data):
    raiseIncorrectSize T
  copyMem(result.data.addr, unsafeAddr data[0], sizeof(result.data))

func fromSszBytes*(T: type GraffitiBytes, data: openArray[byte]): T
    {.raisesssz.} =
  if data.len != sizeof(result):
    raiseIncorrectSize T
  copyMem(result.addr, unsafeAddr data[0], sizeof(result))

template fromSszBytes*(T: type Slot, bytes: openArray[byte]): T =
  T fromSszBytes(uint64, bytes)

template fromSszBytes*(T: type Epoch, bytes: openArray[byte]): T =
  T fromSszBytes(uint64, bytes)

func fromSszBytes*(T: type ForkDigest, bytes: openArray[byte]): T
    {.raisesssz.} =
  if bytes.len != sizeof(result):
    raiseIncorrectSize T
  copyMem(result.addr, unsafeAddr bytes[0], sizeof(result))

func fromSszBytes*(T: type Version, bytes: openArray[byte]): T
    {.raisesssz.} =
  if bytes.len != sizeof(result):
    raiseIncorrectSize T
  copyMem(result.addr, unsafeAddr bytes[0], sizeof(result))

template postReadValue*(x:auto) =
  when x is phase0.SignedBeaconBlock | phase0.TrustedSignedBeaconBlock |
              altair.SignedBeaconBlock | altair.TrustedSignedBeaconBlock:
    if updateRoot:
      val.root = hash_tree_root(val.message)
