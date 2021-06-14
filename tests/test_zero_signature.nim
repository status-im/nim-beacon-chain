# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2, ssz_serialization,
  ../beacon_chain/spec/[datatypes, crypto],
  ../beacon_chain/ssz/spec_types

# Sanity checks to make sure all the workarounds introduced
# to deal with https://github.com/status-im/nimbus-eth2/issues/374
# and https://github.com/ethereum/eth2.0-specs/issues/1396
# don't blow up.

suite "Zero signature sanity checks":
  # Using signature directly triggers a bug
  # in object_serialization/stew: https://github.com/status-im/nimbus-eth2/issues/396

  # test "SSZ serialization round-trip doesn't un-zero the signature":

  #   let zeroSig = BlsValue[Signature](kind: OpaqueBlob)
  #   check:
  #     block:
  #       var allZeros = true
  #       for val in zeroSig.blob:
  #         allZeros = allZeros and val == 0
  #       allZeros

  #   let sszZeroSig = SSZ.encode(zeroSig)
  #   let deserZeroSig = SSZ.decode(sszZeroSig, ValidatorSig)

  #   check(zeroSIg == deserZeroSig)

  test "SSZ serialization roundtrip of SignedBeaconBlockHeader":

    let defaultBlockHeader = SignedBeaconBlockHeader()

    check:
      block:
        var allZeros = true
        for val in defaultBlockHeader.signature.blob:
          allZeros = allZeros and val == 0
        allZeros

    let sszDefaultBlockHeader = SSZ.encode(defaultBlockHeader)
    let deserBlockHeader =
      SSZ.decode(sszDefaultBlockHeader, SignedBeaconBlockHeader)

    check(defaultBlockHeader == deserBlockHeader)
