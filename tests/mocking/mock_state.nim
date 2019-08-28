# beacon_chain
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Mocking helpers for BeaconState
# ---------------------------------------------------------------

import
  # Specs
  ../../beacon_chain/spec/[datatypes],
  # Internals
  ../../beacon_chain/state_transition

proc nextEpoch*(state: var BeaconState) =
  ## Transition to the start of the next epoch
  let slot = state.slot + SLOTS_PER_EPOCH - (state.slot mod SLOTS_PER_EPOCH)
  process_slots(state, slot)

proc nextSlot*(state: var BeaconState) =
  ## Transition to the next slot
  process_slots(state, state.slot + 1)
