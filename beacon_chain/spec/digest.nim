# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Serenity hash function / digest
#
# From spec:
#
#  We aim to have a STARK-friendly hash function `hash(x)` for the production
# launch of the beacon chain. While the standardisation process for a
# STARK-friendly hash function takes place—led by STARKware, who will produce a
# detailed report with recommendations—we use `BLAKE2b-512` as a placeholder.
# Specifically, we set `hash(x) := BLAKE2b-512(x)[0:32]` where the `BLAKE2b-512`
# algorithm is defined in [RFC 7693](https://tools.ietf.org/html/rfc7693) and
# the input `x` is of type `bytes`.
#
# In our code base, to enable a smooth transition, we call this function
# `eth2hash`, and it outputs a `Eth2Digest`. Easy to sed :)

import
  nimcrypto/[keccak, hash], eth/common/eth_types_json_serialization,
  hashes

export
  eth_types_json_serialization, hash.`$`

type
  Eth2Digest* = MDigest[32 * 8] ## `hash32` from spec
  Eth2Hash* = keccak256 ## Context for hash function

func shortLog*(x: Eth2Digest): string =
  ($x)[0..7]

func eth2hash*(v: openArray[byte]): Eth2Digest =
  var tmp = Eth2Hash.digest v
  copyMem(result.data.addr, tmp.addr, sizeof(result))

template withEth2Hash*(body: untyped): Eth2Digest =
  ## This little helper will init the hash function and return the sliced
  ## hash:
  ## let hashOfData = withHash: h.update(data)
  var h  {.inject.}: Eth2Hash
  h.init()
  body
  var res: Eth2Digest
  var tmp = h.finish()
  copyMem(res.data.addr, tmp.data.addr, sizeof(res))
  res

func hash*(x: Eth2Digest): Hash =
  ## Hash for Keccak digests for Nim hash tables
  # Stub for BeaconChainDB

  # We just slice the first 4 or 8 bytes of the block hash
  # depending of if we are on a 32 or 64-bit platform
  result = cast[ptr Hash](unsafeAddr x)[]
