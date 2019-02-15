import
  random,
  chronos,
  spec/[datatypes, helpers]

type
  Timestamp* = uint64 # Unix epoch timestamp in millisecond resolution

var
  detectedClockDrift: int64

template now*: auto = fastEpochTime()

# TODO underflow when genesis has not yet happened!
proc timeSinceGenesis*(s: BeaconState): Timestamp =
  Timestamp(int64(fastEpochTime() - s.genesis_time * 1000) -
            detectedClockDrift)

proc getSlotFromTime*(s: BeaconState, t = now()): SlotNumber =
  GENESIS_SLOT + uint64((int64(t - s.genesis_time * 1000) - detectedClockDrift) div
                         int64(SLOT_DURATION * 1000))

func slotStart*(s: BeaconState, slot: SlotNumber): Timestamp =
  (s.genesis_time + (slot * SLOT_DURATION)) * 1000

func slotMiddle*(s: BeaconState, slot: SlotNumber): Timestamp =
  s.slotStart(slot) + SLOT_DURATION * 500

func slotEnd*(s: BeaconState, slot: SlotNumber): Timestamp =
  # TODO this is actually past the end, by nim inclusive semantics (sigh)
  s.slotStart(slot + 1)

proc randomTimeInSlot*(s: BeaconState,
                       slot: SlotNumber,
                       interval: HSlice[float, float]): Timestamp =
  ## Returns a random moment within the slot.
  ## The interval must be a sub-interval of [0..1].
  ## Zero marks the begginning of the slot and One marks the end.
  s.slotStart(slot) + Timestamp(rand(interval) * float(SLOT_DURATION * 1000))

proc slotDistanceFromNow*(s: BeaconState): int64 =
  ## Returns how many slots have passed since a particular BeaconState was finalized
  int64(s.getSlotFromTime() - s.finalized_epoch.get_epoch_start_slot)

proc synchronizeClock*() {.async.} =
  ## This should determine the offset of the local clock against a global
  ## trusted time (e.g. it can be obtained from multiple time servers).

  # TODO: implement this properly
  detectedClockDrift = 0

