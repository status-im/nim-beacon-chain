# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/tests/core/pyspec/eth2spec/utils/merkle_minimal.py

# Merkle tree helpers
# ---------------------------------------------------------------

{.push raises: [Defect].}

import
  sequtils,
  stew/endians2,
  # Specs
  ../../beacon_chain/spec/[datatypes, digest],
  ../../beacon_chain/ssz/merkleization

# TODO All tests need to be moved to the test suite.

const depositContractLimit* = Limit(1'u64 shl DEPOSIT_CONTRACT_TREE_DEPTH)

func attachMerkleProofs*(deposits: var openArray[Deposit]) =
  let depositsRoots = mapIt(deposits, hash_tree_root(it.data))

  var incrementalMerkleProofs = createMerkleizer(depositContractLimit)

  for i in 0 ..< depositsRoots.len:
    incrementalMerkleProofs.addChunkAndGenMerkleProof(depositsRoots[i], deposits[i].proof)
    deposits[i].proof[32] = default(Eth2Digest)
    deposits[i].proof[32].data[0..7] = toBytesLE uint64(i + 1)

template getProof*(proofs: seq[Eth2Digest], idxParam: int): openArray[Eth2Digest] =
  let
    idx = idxParam
    startIdx = idx * DEPOSIT_CONTRACT_TREE_DEPTH
    endIdx = startIdx + DEPOSIT_CONTRACT_TREE_DEPTH - 1
  proofs.toOpenArray(startIdx, endIdx)

