type
  NetworkBackendType* = enum
    libp2pBackend
    libp2pDaemonBackend
    rlpxBackend

const
  network_type {.strdefine.} = "libp2p_daemon"

  networkBackend* = when network_type == "rlpx": rlpxBackend
                    elif network_type == "libp2p": libp2pBackend
                    elif network_type == "libp2p_daemon": libp2pDaemonBackend
                    else: {.fatal: "The 'network_type' should be either 'libp2p', 'libp2p_daemon' or 'rlpx'" .}

const
  copyrights* = "Copyright (c) 2019 Status Research & Development GmbH"

  versionMajor* = 0
  versionMinor* = 3
  versionBuild* = 0

  semanticVersion* = 2
    # Bump this up every time a breaking change is introduced
    # Clients having different semantic versions won't be able
    # to join the same testnets.

  useInsecureFeatures* = defined(insecure)
    # TODO This is temporarily set to true, so it's easier for other teams to
    # launch the beacon_node with metrics enabled during the interop lock-in.
    # We'll disable it once the lock-in is over.

  gitRevision* = staticExec("git rev-parse --short HEAD")

  versionAsStr* =
    $versionMajor & "." & $versionMinor & "." & $versionBuild

  fullVersionStr* =
    versionAsStr & " (" & gitRevision & ", " & network_type & ")"

