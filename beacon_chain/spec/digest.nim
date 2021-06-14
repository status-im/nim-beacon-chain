# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Serenity hash function / digest
#
# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#hash
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
  # Status libraries
  chronicles,
  nimcrypto/[sha2, hash],
  stew/byteutils,
  json_serialization,
  blscurve

export
  # Exports from sha2 / hash are explicit to avoid exporting upper-case `$` and
  # constant-time `==`
  sha2.update, hash.fromHex, json_serialization

type
  Eth2Digest* = MDigest[32 * 8] ## `hash32` from spec

when BLS_BACKEND == BLST:
  export blscurve.update
  type Eth2DigestCtx* = BLST_SHA256_CTX
else:
  type Eth2DigestCtx* = sha2.sha256

func `$`*(x: Eth2Digest): string =
  x.data.toHex()

func shortLog*(x: Eth2Digest): string =
  x.data.toOpenArray(0, 3).toHex()

chronicles.formatIt Eth2Digest:
  shortLog(it)

# TODO: expose an in-place digest function
#       when hashing in loop or into a buffer
#       See: https://github.com/cheatfate/nimcrypto/blob/b90ba3abd/nimcrypto/sha2.nim#L570
func eth2digest*(v: openArray[byte]): Eth2Digest {.noInit.} =
  ## Apply the Eth2 Hash function
  ## Do NOT use for secret data.
  when BLS_BACKEND == BLST:
    # BLST has a fast assembly optimized SHA256
    result.data.bls_sha256_digest(v)
  else:
    # We use the init-update-finish interface to avoid
    # the expensive burning/clearing memory (20~30% perf)
    var ctx: Eth2DigestCtx
    ctx.init()
    ctx.update(v)
    ctx.finish()

template hash*(x: Eth2Digest): Hash =
  ## Hash for digests for Nim hash tables
  # digests are already good hashes
  cast[ptr Hash](unsafeAddr x.data[0])[]

func `==`*(a, b: Eth2Digest): bool =
  when nimvm:
    a.data == b.data
  else:
    # nimcrypto uses a constant-time comparison for all MDigest types which for
    # Eth2Digest is unnecessary - the type should never hold a secret!
    equalMem(unsafeAddr a.data[0], unsafeAddr b.data[0], sizeof(a.data))

proc writeValue*(w: var JsonWriter, a: Eth2Digest) {.raises: [Defect, IOError, SerializationError].} =
  w.writeValue $a

proc readValue*(r: var JsonReader, a: var Eth2Digest) {.raises: [Defect, IOError, SerializationError].} =
  try:
    a = fromHex(type(a), r.readValue(string))
  except ValueError:
    raiseUnexpectedValue(r, "Hex string expected")
