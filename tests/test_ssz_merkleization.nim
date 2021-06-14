import
  std/[strutils, sequtils, macros, bitops],
  stew/[bitops2, endians2], ssz_serialization,
  ../beacon_chain/spec/[beaconstate, datatypes, digest, helpers],
  ../beacon_chain/eth1/merkle_minimal,
  mocking/mock_deposits

func round_step_down(x: Natural, step: static Natural): int =
  ## Round the input to the previous multiple of "step"
  when (step and (step - 1)) == 0:
    # Step is a power of 2. (If compiler cannot prove that x>0 it does not make the optim)
    x and not(step - 1)
  else:
    x - x mod step

type SparseMerkleTree[Depth: static int] = object
  ## Sparse Merkle tree
  # There is an extra "depth" layer to store leaf nodes
  # This stores leaves at depth = 0
  # and the root hash at the last depth
  nnznodes*: array[Depth+1, seq[Eth2Digest]]  # nodes that leads to non-zero leaves

func merkleTreeFromLeaves(
        values: openArray[Eth2Digest],
        Depth: static[int] = DEPOSIT_CONTRACT_TREE_DEPTH
      ): SparseMerkleTree[Depth] =
  ## Depth should be the same as is_valid_merkle_branch

  result.nnznodes[0] = @values

  for depth in 1 .. Depth: # Inclusive range
    let prev_depth_len = result.nnznodes[depth-1].len
    let stop = round_step_down(prev_depth_len, 2)
    for i in countup(0, stop-1, 2):
      # hash by pair of previous nodes
      let nodeHash = computeDigest:
        h.update result.nnznodes[depth-1][i]
        h.update result.nnznodes[depth-1][i+1]
      result.nnznodes[depth].add nodeHash

    if prev_depth_len != stop:
      # If length is odd, the last one was skipped,
      # we need to combine it
      # with the zeroHash corresponding to the current depth
      let nodeHash = computeDigest:
        h.update result.nnznodes[depth-1][^1]
        h.update zeroHashes[depth-1]
      result.nnznodes[depth].add nodeHash

func getMerkleProof[Depth: static int](tree: SparseMerkleTree[Depth],
                                       index: int,
                                       depositMode = false): array[Depth, Eth2Digest] =
  # Descend down the tree according to the bit representation
  # of the index:
  #   - 0 --> go left
  #   - 1 --> go right
  let path = uint32(index)

  # This is what the nnznodes[depth].len would be if `index` had been the last
  # deposit on the Merkle tree
  var depthLen = index + 1

  for depth in 0 ..< Depth:
    let nodeIdx = int((path shr depth) xor 1)

    # depositMode simulates only having constructed SparseMerkleTree[Depth]
    # through exactly deposit specified.
    if nodeIdx < tree.nnznodes[depth].len and
        (nodeIdx < depthLen or not depositMode):
      result[depth] = tree.nnznodes[depth][nodeIdx]
    else:
      result[depth] = zeroHashes[depth]

    # Round up, i.e. a half-pair of Merkle nodes/leaves still requires a node
    # in the next Merkle tree layer calculated
    depthLen = (depthLen + 1) div 2

proc testMerkleMinimal*(): bool =
  proc toDigest[N: static int](x: array[N, byte]): Eth2Digest =
    result.data[0 .. N-1] = x

  let a = [byte 0x01, 0x02, 0x03].toDigest
  let b = [byte 0x04, 0x05, 0x06].toDigest
  let c = [byte 0x07, 0x08, 0x09].toDigest

  block: # SSZ Sanity checks vs Python impl
    block: # 3 leaves
      let leaves = List[Eth2Digest, 3](@[a, b, c])
      let root = hash_tree_root(leaves)
      doAssert $root == "9ff412e827b7c9d40fc7df2725021fd579ab762581d1ff5c270316682868456e".toUpperAscii

    block: # 2^3 leaves
      let leaves = List[Eth2Digest, int64(1 shl 3)](@[a, b, c])
      let root = hash_tree_root(leaves)
      doAssert $root == "5248085b588fab1dd1e03f3cd62201602b12e6560665935964f46e805977e8c5".toUpperAscii

    block: # 2^10 leaves
      let leaves = List[Eth2Digest, int64(1 shl 10)](@[a, b, c])
      let root = hash_tree_root(leaves)
      doAssert $root == "9fb7d518368dc14e8cc588fb3fd2749beef9f493fef70ae34af5721543c67173".toUpperAscii

  block:
    macro roundTrips(): untyped =
      result = newStmtList()

      # compile-time unrolled test
      for nleaves in [3, 4, 5, 7, 8, 1 shl 10, 1 shl 32]:
        let depth = fastLog2(nleaves-1) + 1

        result.add quote do:
          block:
            let tree = merkleTreeFromLeaves([a, b, c], Depth = `depth`)
            #echo "Tree: ", tree

            doAssert tree.nnznodes[`depth`].len == 1
            let root = tree.nnznodes[`depth`][0]
            #echo "Root: ", root

            block: # proof for a
              let index = 0

              doAssert is_valid_merkle_branch(
                a, tree.getMerkleProof(index = index),
                depth = `depth`,
                index = index.uint64,
                root = root
              ), "Failed (depth: " & $`depth` &
                ", nleaves: " & $`nleaves` & ')'

            block: # proof for b
              let index = 1

              doAssert is_valid_merkle_branch(
                b, tree.getMerkleProof(index = index),
                depth = `depth`,
                index = index.uint64,
                root = root
              ), "Failed (depth: " & $`depth` &
                ", nleaves: " & $`nleaves` & ')'

            block: # proof for c
              let index = 2

              doAssert is_valid_merkle_branch(
                c, tree.getMerkleProof(index = index),
                depth = `depth`,
                index = index.uint64,
                root = root
              ), "Failed (depth: " & $`depth` &
                ", nleaves: " & $`nleaves` & ')'

    roundTrips()
    true

doAssert testMerkleMinimal()

proc compareTreeVsMerkleizer(hashes: openArray[Eth2Digest], limit: static Limit) =
  const treeHeight = binaryTreeHeight(limit)
  let tree = merkleTreeFromLeaves(hashes, treeHeight)

  var merkleizer = createMerkleizer(limit)
  for hash in hashes:
    merkleizer.addChunk hash.data

  doAssert merkleizer.getFinalHash() == tree.nnznodes[treeHeight - 1][0]

proc testMultiProofsGeneration(preludeRecords: int,
                               totalProofs: int,
                               followUpRecords: int,
                               limit: static Limit) =
  var
    m1 = createMerkleizer(limit)
    m2 = createMerkleizer(limit)

  var preludeHashes = newSeq[Eth2Digest]()
  for i in 0 ..< preludeRecords:
    let hash = eth2digest toBytesLE(uint64(100000000 + i))
    m1.addChunk hash.data
    m2.addChunk hash.data
    preludeHashes.add hash

  var proofsHashes = newSeq[Eth2Digest]()
  for i in 0 ..< totalProofs:
    let hash = eth2digest toBytesLE(uint64(200000000 + i))
    m1.addChunk hash.data
    proofsHashes.add hash

  var proofs = addChunksAndGenMerkleProofs(m2, proofsHashes)

  const treeHeight = binaryTreeHeight(limit)
  let merkleTree = merkleTreeFromLeaves(preludeHashes & proofsHashes,
                                        treeHeight)

  doAssert m1.getFinalHash == merkleTree.nnznodes[treeHeight - 1][0]
  doAssert m1.getFinalHash == m2.getFinalHash

  for i in 0 ..< totalProofs:
    let
      referenceProof = merkle_tree.getMerkleProof(preludeRecords + i, false)
      startPos = i * treeHeight
      endPos = startPos + treeHeight - 1

    doAssert referenceProof == proofs.toOpenArray(startPos, endPos)

  for i in 0 ..< followUpRecords:
    let hash = eth2digest toBytesLE(uint64(300000000 + i))
    m1.addChunk hash.data
    m2.addChunk hash.data

    doAssert m1.getFinalHash == m2.getFinalHash

for prelude in [0, 1, 2, 5, 6, 12, 13, 16]:
  for proofs in [1, 2, 4, 17, 64]:
    for followUpHashes in [0, 1, 2, 5, 7, 8, 15, 48]:
      testMultiProofsGeneration(prelude, proofs, followUpHashes, 128)
      testMultiProofsGeneration(prelude, proofs, followUpHashes, 5000)

iterator hash_tree_roots_prefix[T](lst: openArray[T],
                                   limit: static Limit): Eth2Digest =
  # This is a particular type's instantiation of a general fold, reduce,
  # accumulation, prefix sums, etc family of operations. As long as that
  # Eth1 deposit case is the only notable example -- the usual uses of a
  # list involve, at some point, tree-hashing it -- finalized hashes are
  # the only abstraction that escapes from this module this way.
  var merkleizer = createMerkleizer(limit)
  for i, elem in lst:
    merkleizer.addChunk(hash_tree_root(elem).data)
    yield mixInLength(merkleizer.getFinalHash(), i + 1)

func attachMerkleProofsReferenceImpl(deposits: var openArray[Deposit]) =
  let
    deposit_data_roots = mapIt(deposits, it.data.hash_tree_root)
    merkle_tree = merkleTreeFromLeaves(deposit_data_roots)
  var
    deposit_data_sums: seq[Eth2Digest]
  for prefix_root in hash_tree_roots_prefix(
      deposit_data_roots, 1'i64 shl DEPOSIT_CONTRACT_TREE_DEPTH):
    deposit_data_sums.add prefix_root

  for val_idx in 0 ..< deposits.len:
    deposits[val_idx].proof[0..31] = merkle_tree.getMerkleProof(val_idx, true)
    deposits[val_idx].proof[32] = default(Eth2Digest)
    deposits[val_idx].proof[32].data[0..7] = uint_to_bytes8((val_idx + 1).uint64)

    doAssert is_valid_merkle_branch(
      deposit_data_roots[val_idx], deposits[val_idx].proof,
      DEPOSIT_CONTRACT_TREE_DEPTH + 1, val_idx.uint64,
      deposit_data_sums[val_idx])

let
  digests = mapIt(1..65, eth2digest toBytesLE(uint64 it))

proc testMerkleizer =
  for i in 0 ..< digests.len:
    compareTreeVsMerkleizer(digests.toOpenArray(0, i), 128)
    compareTreeVsMerkleizer(digests.toOpenArray(0, i), 5000)

  var deposits = mockGenesisBalancedDeposits(65, 100000)
  var depositsCopy = deposits

  attachMerkleProofsReferenceImpl(deposits)
  attachMerkleProofs(depositsCopy)

  for i in 0 ..< deposits.len:
    doAssert deposits[i].proof == depositsCopy[i].proof

testMerkleizer()
