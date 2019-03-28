# beacon_chain
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Serenity hash function / digest
#
# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#hash
#
# In Phase 0 the beacon chain is deployed with the same hash function as
# Ethereum 1.0, i.e. Keccak-256 (also incorrectly known as SHA3).
#
# Note: We aim to migrate to a S[T/N]ARK-friendly hash function in a future
# Ethereum 2.0 deployment phase.
#
# https://crypto.stackexchange.com/questions/15727/what-are-the-key-differences-between-the-draft-sha-3-standard-and-the-keccak-sub
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
  # result = is needed to fix https://github.com/status-im/nim-beacon-chain/issues/209
  result = ($x)[0..7]

func eth2hash*(v: openArray[byte]): Eth2Digest =
  var ctx: Eth2Hash
  # We can avoid this step for Keccak/SHA3 digests because `ctx` is already
  # empty, but if digest will be changed next line must be enabled.
  # ctx.init()
  ctx.update(v)
  result = ctx.finish()

template withEth2Hash*(body: untyped): Eth2Digest =
  ## This little helper will init the hash function and return the sliced
  ## hash:
  ## let hashOfData = withHash: h.update(data)
  var h  {.inject.}: Eth2Hash
  h.init()
  body
  var res = h.finish()
  res

func hash*(x: Eth2Digest): Hash =
  ## Hash for Keccak digests for Nim hash tables
  # Stub for BeaconChainDB

  # We just slice the first 4 or 8 bytes of the block hash
  # depending of if we are on a 32 or 64-bit platform
  result = cast[ptr Hash](unsafeAddr x)[]
