# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# All non-pure SSZ tests that require the -d:ssz_testing
# to ignore invalid BLS signature in EF test vectors
# https://github.com/status-im/nim-beacon-chain/issues/374

import
  ./test_fixture_sanity_slots,
  ./test_fixture_sanity_blocks,
  ./test_fixture_state_transition_epoch,
  ./test_fixture_operations_attestations,
  ./test_fixture_operations_block_header,
  ./test_fixture_operations_transfer
