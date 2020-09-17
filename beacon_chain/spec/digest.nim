# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Serenity hash function / digest
#
# https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/beacon-chain.md#hash
#
# In Phase 0 the beacon chain is deployed with SHA256 (SHA2-256).
# Note that is is different from Keccak256 (often mistakenly called SHA3-256)
# and SHA3-256.
#
# In Eth1.0, the default hash function is Keccak256 and SHA256 is available as a precompiled contract.
#
# In our code base, to enable a smooth transition
# (already did Blake2b --> Keccak256 --> SHA2-256),
# we call this function `eth2digest`, and it outputs a `Eth2Digest`. Easy to sed :)

{.push raises: [Defect].}

import
  # Standard library
  std/hashes,
  #Status libraries
  chronicles,
  nimcrypto/[sha2, hash],
  stew/byteutils,
  hashes,
  eth/common/eth_types_json_serialization,
  blscurve

export
  hash.`$`, sha2, readValue, writeValue

type
  Eth2Digest* = MDigest[32 * 8] ## `hash32` from spec

when BLS_BACKEND == BLST:
  export blscurve.update
  type Eth2DigestCtx* = BLST_SHA256_CTX
else:
  type Eth2DigestCtx* = sha2.sha256

func shortLog*(x: Eth2Digest): string =
  x.data.toOpenArray(0, 3).toHex()

chronicles.formatIt Eth2Digest:
  shortLog(it)

# TODO: expose an in-place digest function
#       when hashing in loop or into a buffer
#       See: https://github.com/cheatfate/nimcrypto/blob/b90ba3abd/nimcrypto/sha2.nim#L570
func eth2digest*(v: openArray[byte]): Eth2Digest =
  ## Apply the Eth2 Hash function
  ## Do NOT use for secret data.
  # We use the init-update-finish interface to avoid
  # the expensive burning/clearing memory (20~30% perf)
  when BLS_BACKEND == BLST:
    # BLST has a fast assembly optimized SHA256
    result.data.bls_sha256_digest(v)
  else:
    var ctx: Eth2DigestCtx
    ctx.init()
    ctx.update(v)
    ctx.finish()

when BLS_BACKEND == BLST:
  func update*(ctx: var BLST_SHA256_CTX; digest: Eth2Digest) =
    ctx.update digest.data
func update*(ctx: var sha256; digest: Eth2Digest) =
  ctx.update digest.data

template withEth2Hash*(body: untyped): Eth2Digest =
  ## This little helper will init the hash function and return the sliced
  ## hash:
  ## let hashOfData = withHash: h.update(data)
  when nimvm:
    # In SSZ, computeZeroHashes require compile-time SHA256
    block:
      var h {.inject.}: sha256
      init(h)
      body
      finish(h)
  else:
    when BLS_BACKEND == BLST:
      block:
        var h  {.inject.}: Eth2DigestCtx
        init(h)
        body
        var res {.noInit.}: Eth2Digest
        finalize(res.data, h)
        res
    else:
      block:
        var h  {.inject.}: Eth2DigestCtx
        init(h)
        body
        finish(h)

func hash*(x: Eth2Digest): Hash =
  ## Hash for digests for Nim hash tables
  # Stub for BeaconChainDB

  # We just slice the first 4 or 8 bytes of the block hash
  # depending of if we are on a 32 or 64-bit platform
  result = cast[ptr Hash](unsafeAddr x)[]
