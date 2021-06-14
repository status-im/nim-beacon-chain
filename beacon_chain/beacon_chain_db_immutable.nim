# beacon_chain
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  tables,
  stew/[assign2, io2, objects, results],
  serialization, ssz_serialization,
  eth/db/[kvstore, kvstore_sqlite3],
  ./spec/[crypto, datatypes, digest],
  filepath

type
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#beaconstate
  # Memory-representation-equivalent to a v1.0.1 BeaconState for in-place SSZ reading and writing
  BeaconStateNoImmutableValidators* = object
    # Versioning
    genesis_time*: uint64
    genesis_validators_root*: Eth2Digest
    slot*: Slot
    fork*: Fork

    # History
    latest_block_header*: BeaconBlockHeader ##\
    ## `latest_block_header.state_root == ZERO_HASH` temporarily

    block_roots*: HashArray[Limit SLOTS_PER_HISTORICAL_ROOT, Eth2Digest] ##\
    ## Needed to process attestations, older to newer

    state_roots*: HashArray[Limit SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    historical_roots*: HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT]

    # Eth1
    eth1_data*: Eth1Data
    eth1_data_votes*:
      HashList[Eth1Data, Limit(EPOCHS_PER_ETH1_VOTING_PERIOD * SLOTS_PER_EPOCH)]
    eth1_deposit_index*: uint64

    # Registry
    validators*: HashList[ValidatorStatus, Limit VALIDATOR_REGISTRY_LIMIT]
    balances*: HashList[uint64, Limit VALIDATOR_REGISTRY_LIMIT]

    # Randomness
    randao_mixes*: HashArray[Limit EPOCHS_PER_HISTORICAL_VECTOR, Eth2Digest]

    # Slashings
    slashings*: HashArray[Limit EPOCHS_PER_SLASHINGS_VECTOR, uint64] ##\
    ## Per-epoch sums of slashed effective balances

    # Attestations
    previous_epoch_attestations*:
      HashList[PendingAttestation, Limit(MAX_ATTESTATIONS * SLOTS_PER_EPOCH)]
    current_epoch_attestations*:
      HashList[PendingAttestation, Limit(MAX_ATTESTATIONS * SLOTS_PER_EPOCH)]

    # Finality
    justification_bits*: uint8 ##\
    ## Bit set for every recent justified epoch
    ## Model a Bitvector[4] as a one-byte uint, which should remain consistent
    ## with ssz/hashing.

    previous_justified_checkpoint*: Checkpoint ##\
    ## Previous epoch snapshot

    current_justified_checkpoint*: Checkpoint
    finalized_checkpoint*: Checkpoint

func getSizeofSig(x: auto, n: int = 0): seq[(string, int, int)] =
  for name, value in x.fieldPairs:
    when value is tuple|object:
      result.add getSizeofSig(value, n + 1)
    result.add((name, sizeof(value), n))

template isomorphicCast*[T, U](x: U): T =
  # Each of these pairs of types has ABI-compatible memory representations, so
  # that the SSZ serialization can read and write directly from an object with
  # only mutable portions of BeaconState into a full BeaconState without using
  # extra copies.
  static:
    doAssert sizeof(T) == sizeof(U)
    doAssert getSizeofSig(T()) == getSizeofSig(U())
  cast[ptr T](unsafeAddr x)[]
