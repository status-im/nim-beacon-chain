# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  chronos, chronicles,
  ./spec/[datatypes, helpers]

from times import Time, getTime, fromUnix, `<`, `-`, inNanoseconds

export chronos.Duration, Moment, now

type
  BeaconClock* = object
    ## The beacon clock represents time as it passes on a beacon chain. Beacon
    ## time is locked to unix time, starting at a particular offset set during
    ## beacon chain instantiation.
    ##
    ## Time on the beacon chain determines what actions should be taken and
    ## which blocks are valid - in particular, blocks are not valid if they
    ## come from the future as seen from the local clock.
    ##
    ## https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/fork-choice.md#fork-choice
    ##
    # TODO consider NTP and network-adjusted timestamps as outlined here:
    #      https://ethresear.ch/t/network-adjusted-timestamps/4187
    genesis: Time

  BeaconTime* = distinct Duration ## Nanoseconds from beacon genesis time

  GetTimeFn* = proc(): Time {.gcsafe, raises: [Defect].}

proc init*(T: type BeaconClock, genesis_time: uint64): T =
  # ~290 billion years into the future
  doAssert genesis_time <= high(int64).uint64

  let
    unixGenesis = fromUnix(genesis_time.int64)
    # GENESIS_SLOT offsets slot time, but to simplify calculations, we apply that
    # offset to genesis instead of applying it at every time conversion
    unixGenesisOffset = times.seconds(int(GENESIS_SLOT * SECONDS_PER_SLOT))

  T(genesis: unixGenesis - unixGenesisOffset)

template `<`*(a, b: BeaconTime): bool =
  Duration(a) < Duration(b)

template `<=`*(a, b: BeaconTime): bool =
  Duration(a) <= Duration(b)

template `+`*(t: BeaconTime, offset: Duration): BeaconTime =
  BeaconTime(Duration(t) + offset)

template `-`*(t: BeaconTime, offset: Duration): BeaconTime =
  BeaconTime(nanoseconds(nanoseconds(Duration(t)) - nanoseconds(offset)))

template `-`*(a, b: BeaconTime): Duration =
  nanoseconds(nanoseconds(Duration(a)) - nanoseconds(Duration(b)))

func toSlot*(t: BeaconTime): tuple[afterGenesis: bool, slot: Slot] =
  let ti = seconds(Duration(t))
  if ti >= 0:
    (true, Slot(uint64(ti) div SECONDS_PER_SLOT))
  else:
    (false, Slot(uint64(-ti) div SECONDS_PER_SLOT))

func slotOrZero*(time: BeaconTime): Slot =
  let exSlot = time.toSlot
  if exSlot.afterGenesis: exSlot.slot
  else: Slot(0)

func toBeaconTime*(c: BeaconClock, t: Time): BeaconTime =
  BeaconTime(nanoseconds(inNanoseconds(t - c.genesis)))

func toSlot*(c: BeaconClock, t: Time): tuple[afterGenesis: bool, slot: Slot] =
  c.toBeaconTime(t).toSlot()

func toBeaconTime*(s: Slot, offset = Duration()): BeaconTime =
  # BeaconTime/Duration stores nanoseconds, internally
  const maxSlot = (not 0'u64 div 2 div SECONDS_PER_SLOT div 1_000_000_000).Slot
  var slot = s
  if slot > maxSlot:
    slot = maxSlot
  BeaconTime(seconds(int64(uint64(slot) * SECONDS_PER_SLOT)) + offset)

proc now*(c: BeaconClock): BeaconTime =
  ## Current time, in slots - this may end up being less than GENESIS_SLOT(!)
  toBeaconTime(c, getTime())

proc fromNow*(c: BeaconClock, t: BeaconTime): tuple[inFuture: bool, offset: Duration] =
  let now = c.now()
  if t > now:
    (true, t - now)
  else:
    (false, now - t)

proc fromNow*(c: BeaconClock, slot: Slot): tuple[inFuture: bool, offset: Duration] =
  c.fromNow(slot.toBeaconTime())

proc durationToNextSlot*(c: BeaconClock): Duration =
  let (afterGenesis, slot) = c.now().toSlot()
  if afterGenesis:
    c.fromNow(Slot(slot) + 1'u64).offset
  else:
    c.fromNow(Slot(0)).offset

proc durationToNextEpoch*(c: BeaconClock): Duration =
  let (afterGenesis, slot) = c.now().toSlot()
  if afterGenesis:
    c.fromNow(compute_start_slot_at_epoch(slot.epoch() + 1'u64)).offset
  else:
    c.fromNow(compute_start_slot_at_epoch(Epoch(0))).offset

func saturate*(d: tuple[inFuture: bool, offset: Duration]): Duration =
  if d.inFuture: d.offset else: seconds(0)

proc addTimer*(fromNow: Duration, cb: CallbackFunc, udata: pointer = nil) =
  discard setTimer(Moment.now() + fromNow, cb, udata)

func shortLog*(d: Duration): string =
  $d

func toFloatSeconds*(d: Duration): float =
  float(milliseconds(d)) / 1000.0

func `$`*(v: BeaconTime): string = $(Duration v)
func shortLog*(v: BeaconTime): string = $(Duration v)

chronicles.formatIt Duration: $it
chronicles.formatIt BeaconTime: $(Duration it)
