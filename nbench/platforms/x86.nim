# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Cpu Name
# -------------------------------------------------------

{.passC:"-std=gnu99".} # TODO may conflict with milagro "-std=c99"

proc cpuID(eaxi, ecxi: int32): tuple[eax, ebx, ecx, edx: int32] =
  when defined(vcc):
    proc cpuidVcc(cpuInfo: ptr int32; functionID: int32)
      {.importc: "__cpuidex", header: "intrin.h".}
    cpuidVcc(addr result.eax, eaxi, ecxi)
  else:
    var (eaxr, ebxr, ecxr, edxr) = (0'i32, 0'i32, 0'i32, 0'i32)
    asm """
      cpuid
      :"=a"(`eaxr`), "=b"(`ebxr`), "=c"(`ecxr`), "=d"(`edxr`)
      :"a"(`eaxi`), "c"(`ecxi`)"""
    (eaxr, ebxr, ecxr, edxr)

proc cpuName*(): string =
  var leaves {.global.} = cast[array[48, char]]([
    cpuID(eaxi = 0x80000002'i32, ecxi = 0),
    cpuID(eaxi = 0x80000003'i32, ecxi = 0),
    cpuID(eaxi = 0x80000004'i32, ecxi = 0)])
  result = $cast[cstring](addr leaves[0])

# Counting cycles
# -------------------------------------------------------

# From Linux
#
# The RDTSC instruction is not ordered relative to memory
# access.  The Intel SDM and the AMD APM are both vague on this
# point, but empirically an RDTSC instruction can be
# speculatively executed before prior loads.  An RDTSC
# immediately after an appropriate barrier appears to be
# ordered as a normal load, that is, it provides the same
# ordering guarantees as reading from a global memory location
# that some other imaginary CPU is updating continuously with a
# time stamp.
#
# From Intel SDM
# https://www.intel.com/content/dam/www/public/us/en/documents/white-papers/ia-32-ia-64-benchmark-code-execution-paper.pdf

proc getTicks*(): int64 {.inline.} =
  when defined(vcc):
    proc rdtsc(): int64 {.sideeffect, importc: "__rdtsc", header: "<intrin.h>".}
    proc lfence() {.importc: "__mm_lfence", header: "<intrin.h>".}

    lfence()
    return rdtsc()

  else:
    when defined(amd64):
      var lo, hi: int64
      # TODO: Provide a compile-time flag for RDTSCP support
      #       and use it instead of lfence + RDTSC
      {.emit: """asm volatile(
        "lfence\n"
        "rdtsc\n"
        : "=a"(`lo`), "=d"(`hi`)
        :
        : "memory"
      );""".}
      return (hi shl 32) or lo
    else: # 32-bit x86
      var res: int32
      # TODO: Provide a compile-time flag for RDTSCP support
      #       and use it instead of lfence + RDTSC
      {.emit: """asm volatile(
        "lfence\n"
        "rdtsc\n"
        : "=a"(`res`)
        :
        : "memory"
      );""".}
      return res

# Sanity check
# -------------------------------------------------------

when isMainModule:

  import std/[times, monotimes, math, volatile, os]

  block: # CpuName
    echo "Your CPU is:    "
    echo "   ", cpuName()

  block: # Cycle Count
    echo "The cost of an int64 modulo operation on your platform is:"

    # Dealing with compiler optimization on microbenchmarks is hard
    {.pragma: volatile, codegenDecl: "volatile $# $#".}

    proc modNtimes(a, b: int64, N: int) {.noinline.} =
      var c{.volatile.}: int64
      for i in 0 ..< N:
        c.addr.volatileStore(a.unsafeAddr.volatileLoad() mod b.unsafeAddr.volatileLoad())

    let a {.volatile.} = 1000003'i64 # a prime number
    let b {.volatile.} = 10007'i64   # another prime number
    let N {.volatile.} = 3_000_000

    let startMono = getMonoTime()
    let startCycles = getTicks()
    modNtimes(a, b, N)
    let stopCycles = getTicks()
    let stopMono = getMonoTime()


    let elapsedMono = inNanoseconds(stopMono - startMono)
    let elapsedCycles = stopCycles - startCycles
    let timerResolutionGHz = round(elapsedCycles.float32 / elapsedMono.float32, 3)

    echo "   ", (elapsedCycles) div N, " cycles"
    echo "   ", (elapsedMono) div N, " ns/iter"
    echo "   ", timerResolutionGHz, " GHz (timer resolution)"

  block: # CPU Frequency
    discard # TODO, surprisingly this is very complex
