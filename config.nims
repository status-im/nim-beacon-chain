import strutils

const nimCachePathOverride {.strdefine.} = ""
when nimCachePathOverride == "":
  when defined(release):
    let nimCachePath = "nimcache/release/" & projectName()
  else:
    let nimCachePath = "nimcache/debug/" & projectName()
else:
  let nimCachePath = nimCachePathOverride
switch("nimcache", nimCachePath)

# `-flto` gives a significant improvement in processing speed, specially hash tree and state transition (basically any CPU-bound code implemented in nim)
# With LTO enabled, optimization flags should be passed to both compiler and linker!
if defined(release) and not defined(disableLTO):
  if defined(macosx): # Clang
    switch("passC", "-flto=thin")
    switch("passL", "-flto=thin -Wl,-object_path_lto," & nimCachePath & "/lto")
  elif defined(linux):
    switch("passC", "-flto=jobserver")
    switch("passL", "-flto=jobserver")
    switch("passC", "-finline-limit=100000")
    switch("passL", "-finline-limit=100000")
  else:
    # On windows, LTO needs more love and attention so "gcc-ar" and "gcc-ranlib" are
    # used for static libraries.
    discard

if defined(windows):
  # disable timestamps in Windows PE headers - https://wiki.debian.org/ReproducibleBuilds/TimestampsInPEBinaries
  switch("passL", "-Wl,--no-insert-timestamp")
  # increase stack size
  switch("passL", "-Wl,--stack,8388608")
  # https://github.com/nim-lang/Nim/issues/4057
  --tlsEmulation:off
  if defined(i386):
    # set the IMAGE_FILE_LARGE_ADDRESS_AWARE flag so we can use PAE, if enabled, and access more than 2 GiB of RAM
    switch("passL", "-Wl,--large-address-aware")

  # The dynamic Chronicles output currently prevents us from using colors on Windows
  # because these require direct manipulations of the stdout File object.
  switch("define", "chronicles_colors=off")

# This helps especially for 32-bit x86, which sans SSE2 and newer instructions
# requires quite roundabout code generation for cryptography, and other 64-bit
# and larger arithmetic use cases, along with register starvation issues. When
# engineering a more portable binary release, this should be tweaked but still
# use at least -msse2 or -msse3.
if defined(disableMarchNative):
  if defined(i386) or defined(amd64):
    switch("passC", "-msse3")
    switch("passL", "-msse3")
else:
  switch("passC", "-march=native")
  switch("passL", "-march=native")
  if defined(windows):
    # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=65782
    # ("-fno-asynchronous-unwind-tables" breaks Nim's exception raising, sometimes)
    switch("passC", "-mno-avx512f")
    switch("passL", "-mno-avx512f")

# omitting frame pointers in nim breaks the GC
# https://github.com/nim-lang/Nim/issues/10625
switch("passC", "-fno-omit-frame-pointer")
switch("passL", "-fno-omit-frame-pointer")

--threads:on
--opt:speed
--excessiveStackTrace:on
# enable metric collection
--define:metrics
--define:chronicles_line_numbers
# for heap-usage-by-instance-type metrics and object base-type strings
--define:nimTypeNames

# switch("define", "snappy_implementation=libp2p")

const currentDir = currentSourcePath()[0 .. ^(len("config.nims") + 1)]
switch("define", "nim_compiler_path=" & currentDir & "env.sh nim")
switch("define", "withoutPCRE")

switch("import", "testutils/moduletests")

const useLibStackTrace = not (defined(windows) and defined(i386)) and
                         not defined(disable_libbacktrace)

when useLibStackTrace:
  --define:nimStackTraceOverride
  switch("import", "libbacktrace")
else:
  --stacktrace:on
  --linetrace:on

var canEnableDebuggingSymbols = true
if defined(macosx):
  # The default open files limit is too low on macOS (512), breaking the
  # "--debugger:native" build. It can be increased with `ulimit -n 1024`.
  let openFilesLimitTarget = 1024
  var openFilesLimit = 0
  try:
    openFilesLimit = staticExec("ulimit -n").strip(chars = Whitespace + Newlines).parseInt()
    if openFilesLimit < openFilesLimitTarget:
      echo "Open files limit too low to enable debugging symbols and lightweight stack traces."
      echo "Increase it with \"ulimit -n " & $openFilesLimitTarget & "\""
      canEnableDebuggingSymbols = false
  except:
    echo "ulimit error"
# We ignore this resource limit on Windows, where a default `ulimit -n` of 256
# in Git Bash is apparently ignored by the OS, and on Linux where the default of
# 1024 is good enough for us.

if canEnableDebuggingSymbols:
  # add debugging symbols and original files and line numbers
  --debugger:native

--define:nimOldCaseObjects # https://github.com/status-im/nim-confutils/issues/9

# `switch("warning[CaseTransition]", "off")` fails with "Error: invalid command line option: '--warning[CaseTransition]'"
switch("warning", "CaseTransition:off")

# The compiler doth protest too much, methinks, about all these cases where it can't
# do its (N)RVO pass: https://github.com/nim-lang/RFCs/issues/230
switch("warning", "ObservableStores:off")

# Too many false positives for "Warning: method has lock level <unknown>, but another method has 0 [LockLevel]"
switch("warning", "LockLevel:off")

# Useful for Chronos metrics.
#--define:chronosFutureTracking

# ############################################################
#
#                    No LTO for crypto
#
# ############################################################

# This applies per-file compiler flags to C files
# which do not support {.localPassC: "-fno-lto".}
# Unfortunately this is filename based instead of path-based
# Assumes GCC

# BLST
put("server.always", "-fno-lto")
put("assembly.always", "-fno-lto")

# Secp256k1
put("secp256k1.always", "-fno-lto")

# BearSSL - only RNGs
put("aesctr_drbg.always", "-fno-lto")
put("hmac_drbg.always", "-fno-lto")
put("sysrng.always", "-fno-lto")

# Miracl - only ECP to derive public key from private key
put("ecp_BLS12381.always", "-fno-lto")

# ############################################################
#
#                    Spurious warnings
#
# ############################################################

# sqlite3.c: In function ‘sqlite3SelectNew’:
# vendor/nim-sqlite3-abi/sqlite3.c:124500: warning: function may return address of local variable [-Wreturn-local-addr]
put("sqlite3.always", "-fno-lto") # -Wno-return-local-addr

