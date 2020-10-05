# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Common routines for a BeaconNode and a ValidatorClient

import
  # Standard library
  tables, random, strutils, os, typetraits,

  # Nimble packages
  chronos, confutils/defs,
  chronicles, chronicles/helpers as chroniclesHelpers,
  stew/io2,

  # Local modules
  spec/[datatypes, crypto, helpers], eth2_network, time

proc setupStdoutLogging*(logLevel: string) =
  when compiles(defaultChroniclesStream.output.writer):
    defaultChroniclesStream.outputs[0].writer =
      proc (logLevel: LogLevel, msg: LogOutputStr) {.gcsafe, raises: [Defect].} =
        try:
          stdout.write(msg)
        except IOError as err:
          logLoggingFailure(cstring(msg), err)

proc setupLogging*(logLevel: string, logFile: Option[OutFile]) =
  randomize()

  if logFile.isSome:
    when defaultChroniclesStream.outputs.type.arity > 1:
      block openLogFile:
        let
          logFile = logFile.get.string
          logFileDir = splitFile(logFile).dir
        let lres = createPath(logFileDir, 0o750)
        if lres.isErr():
          error "Failed to create directory for log file",
                path = logFileDir, err = ioErrorMsg(lres.error)
          break openLogFile

        if not defaultChroniclesStream.outputs[1].open(logFile):
          error "Failed to create log file", logFile
    else:
      warn "The --log-file option is not active in the current build"

  try:
    let directives = logLevel.split(";")
    try:
      setLogLevel(parseEnum[LogLevel](directives[0]))
    except ValueError:
      raise (ref ValueError)(msg: "Please specify one of TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL")

    if directives.len > 1:
      for topicName, settings in parseTopicDirectives(directives[1..^1]):
        if not setTopicState(topicName, settings.state, settings.logLevel):
          warn "Unrecognized logging topic", topic = topicName
  except ValueError as err:
    stderr.write "Invalid value for --log-level. " & err.msg
    quit 1

template makeBannerAndConfig*(clientId: string, ConfType: type): untyped =
  let
    version = clientId & "\p" & copyrights & "\p\p" &
      "eth2 specification v" & SPEC_VERSION & "\p\p" &
      nimBanner
  # TODO for some reason, copyrights are printed when doing `--help`
  {.push warning[ProveInit]: off.}
  let config = ConfType.load(
    version = version,
    copyrightBanner = clientId) # but a short version string makes more sense...
  {.pop.}
  config

# TODO not sure if this belongs here but it doesn't belong in `time.nim` either
proc sleepToSlotOffset*(clock: BeaconClock, extra: chronos.Duration,
                        slot: Slot, msg: static string): Future[bool] {.async.} =
  let
    fromNow = clock.fromNow(slot.toBeaconTime(extra))

  if fromNow.inFuture:
    trace msg,
      slot = shortLog(slot),
      fromNow = shortLog(fromNow.offset)

    await sleepAsync(fromNow.offset)
    return true
  return false

proc checkIfShouldStopAtEpoch*(scheduledSlot: Slot, stopAtEpoch: uint64) =
  # Offset backwards slightly to allow this epoch's finalization check to occur
  if scheduledSlot > 3 and stopAtEpoch > 0'u64 and
      (scheduledSlot - 3).compute_epoch_at_slot() >= stopAtEpoch:
    info "Stopping at pre-chosen epoch",
      chosenEpoch = stopAtEpoch,
      epoch = scheduledSlot.compute_epoch_at_slot(),
      slot = scheduledSlot

    # Brute-force, but ensure it's reliable enough to run in CI.
    quit(0)
