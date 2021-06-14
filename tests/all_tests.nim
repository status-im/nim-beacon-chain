# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ./testutil

import # Official constants
  ./official/test_fixture_const_sanity_check

import # Unit test
  ./test_attestation_pool,
  ./test_beacon_chain_db,
  ./test_beaconstate,
  ./test_bitseqs,
  ./test_block_pool,
  ./test_datatypes,
  ./test_discovery,
  ./test_eth1_monitor,
  ./test_exit_pool,
  ./test_gossip_validation,
  ./test_helpers,
  ./test_honest_validator,
  ./test_interop,
  ./test_peer_pool,
  ./test_statediff,
  ./test_sync_manager,
  ./test_zero_signature,
  ./fork_choice/tests_fork_choice,
  ./slashing_protection/test_slashing_interchange,
  ./slashing_protection/test_slashing_protection_db,
  ./slashing_protection/test_migration

import # Refactor state transition unit tests
  # In mainnet these take 2 minutes and are empty TODOs
  ./spec_block_processing/test_process_deposits,
  ./spec_block_processing/test_process_attestation,
  ./spec_epoch_processing/test_process_justification_and_finalization

# TODO: json tests were removed

# import # Official fixtures that don't require SSZ parsing of invalid BLS signatures
#        # https://github.com/status-im/nimbus-eth2/issues/374
#   ./official/test_fixture_bls

summarizeLongTests("AllTests")
