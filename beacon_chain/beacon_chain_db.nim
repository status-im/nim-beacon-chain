import
  os, json, tables, options,
  chronicles, serialization, json_serialization, eth/common/eth_types_json_serialization,
  spec/[datatypes, digest, crypto],
  eth/trie/db, ssz

type
  BeaconChainDB* = ref object
    ## Database storing resolved blocks and states - resolved blocks are such
    ## blocks that form a chain back to the tail block.
    backend: TrieDatabaseRef

  DbKeyKind = enum
    kHashToState
    kHashToBlock
    kHeadBlock # Pointer to the most recent block selected by the fork choice
    kTailBlock ##\
    ## Pointer to the earliest finalized block - this is the genesis block when
    ## the chain starts, but might advance as the database gets pruned
    ## TODO: determine how aggressively the database should be pruned. For a
    ##       healthy network sync, we probably need to store blocks at least
    ##       past the weak subjectivity period.

func subkey(kind: DbKeyKind): array[1, byte] =
  result[0] = byte ord(kind)

func subkey[N: static int](kind: DbKeyKind, key: array[N, byte]):
    array[N + 1, byte] =
  result[0] = byte ord(kind)
  result[1 .. ^1] = key

func subkey(kind: DbKeyKind, key: uint64): array[sizeof(key) + 1, byte] =
  result[0] = byte ord(kind)
  copyMem(addr result[1], unsafeAddr key, sizeof(key))

func subkey(kind: type BeaconState, key: Eth2Digest): auto =
  subkey(kHashToState, key.data)

func subkey(kind: type BeaconBlock, key: Eth2Digest): auto =
  subkey(kHashToBlock, key.data)

proc init*(T: type BeaconChainDB, backend: TrieDatabaseRef): BeaconChainDB =
  new result
  result.backend = backend

proc putBlock*(db: BeaconChainDB, key: Eth2Digest, value: BeaconBlock) =
  db.backend.put(subkey(type value, key), SSZ.encode(value))

proc putHead*(db: BeaconChainDB, key: Eth2Digest) =
  db.backend.put(subkey(kHeadBlock), key.data) # TODO head block?

proc putState*(db: BeaconChainDB, key: Eth2Digest, value: BeaconState) =
  # TODO prune old states - this is less easy than it seems as we never know
  #      when or if a particular state will become finalized.

  db.backend.put(subkey(type value, key), SSZ.encode(value))

proc putState*(db: BeaconChainDB, value: BeaconState) =
  db.putState(hash_tree_root(value), value)

proc putBlock*(db: BeaconChainDB, value: BeaconBlock) =
  db.putBlock(hash_tree_root(value), value)

proc putHeadBlock*(db: BeaconChainDB, key: Eth2Digest) =
  db.backend.put(subkey(kHeadBlock), key.data) # TODO head block?

proc putTailBlock*(db: BeaconChainDB, key: Eth2Digest) =
  db.backend.put(subkey(kTailBlock), key.data)

proc get(db: BeaconChainDB, key: auto, T: typedesc): Option[T] =
  let res = db.backend.get(key)
  if res.len != 0:
    try:
      some(SSZ.decode(res, T))
    except SerializationError:
      none(T)
  else:
    none(T)

proc getBlock*(db: BeaconChainDB, key: Eth2Digest): Option[BeaconBlock] =
  db.get(subkey(BeaconBlock, key), BeaconBlock)

proc getState*(db: BeaconChainDB, key: Eth2Digest): Option[BeaconState] =
  db.get(subkey(BeaconState, key), BeaconState)

proc getHeadBlock*(db: BeaconChainDB): Option[Eth2Digest] =
  db.get(subkey(kHeadBlock), Eth2Digest)

proc getTailBlock*(db: BeaconChainDB): Option[Eth2Digest] =
  db.get(subkey(kTailBlock), Eth2Digest)

proc containsBlock*(
    db: BeaconChainDB, key: Eth2Digest): bool =
  db.backend.contains(subkey(BeaconBlock, key))

proc containsState*(
    db: BeaconChainDB, key: Eth2Digest): bool =
  db.backend.contains(subkey(BeaconState, key))

iterator getAncestors*(db: BeaconChainDB, root: Eth2Digest):
    tuple[root: Eth2Digest, blck: BeaconBlock] =
  ## Load a chain of ancestors for blck - returns a list of blocks with the
  ## oldest block last (blck will be at result[0]).
  ##
  ## The search will go on until the ancestor cannot be found.

  var root = root
  while (let blck = db.getBlock(root); blck.isSome()):
    yield (root, blck.get())

    root = blck.get().previous_block_root
