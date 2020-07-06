import strutils

if defined(release):
  switch("nimcache", "nimcache/release/$projectName")
else:
  switch("nimcache", "nimcache/debug/$projectName")

const stack_size {.intdefine.}: int = 0
when defined(stack_size):
  when defined(gcc):
    # conservative compile-time estimation for single functions
    switch("passC", "-Werror=stack-usage=" & $stack_size)
  when defined(posix):
    # limit the stack at runtime, on POSIX systems
    switch("import", "stew/rlimits")
  when defined(windows):
    switch("passL", "-Wl,--stack," & $stack_size)

if defined(windows):
  # disable timestamps in Windows PE headers - https://wiki.debian.org/ReproducibleBuilds/TimestampsInPEBinaries
  switch("passL", "-Wl,--no-insert-timestamp")
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
  switch("passC", "-msse3")
else:
  switch("passC", "-march=native")
  if defined(windows):
    # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=65782
    # ("-fno-asynchronous-unwind-tables" breaks Nim's exception raising, sometimes)
    switch("passC", "-mno-avx512vl")

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

switch("import", "testutils/moduletests")

const useLibStackTrace = not defined(macosx) and
                         not (defined(windows) and defined(i386)) and
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

