#!/bin/bash

# Copyright (c) 2020-2021 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

set -e

cd /home/user/nimbus-eth2
git config --global core.abbrev 8

if [[ -z "${1}" ]]; then
  echo "Usage: $(basename ${0}) PLATFORM"
  exit 1
fi
PLATFORM="${1}"
BINARIES="nimbus_beacon_node nimbus_signing_process"

#- we need to build everything against libraries available inside this container, including the Nim compiler
#- we disable the log file and log colours; the user only has to worry about logging stdout now
make clean
if [[ "${PLATFORM}" == "Windows_amd64" ]]; then
  # Cross-compilation using the MXE distribution of Mingw-w64
  export PATH="/usr/lib/mxe/usr/bin:${PATH}"
  make \
    -j$(nproc) \
    USE_LIBBACKTRACE=0 \
    deps
  make \
    -C vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc \
    -f Makefile.mingw \
    clean &>/dev/null
  make \
    -j$(nproc) \
    -C vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc \
    -f Makefile.mingw \
    CC=x86_64-w64-mingw32.static-gcc \
    libminiupnpc.a &>/dev/null
  make \
    -C vendor/nim-nat-traversal/vendor/libnatpmp-upstream \
    clean &>/dev/null
  make \
    -j$(nproc) \
    -C vendor/nim-nat-traversal/vendor/libnatpmp-upstream \
    CC=x86_64-w64-mingw32.static-gcc \
    CFLAGS="-Wall -Os -DWIN32 -DNATPMP_STATICLIB -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4 ${CFLAGS}" \
    libnatpmp.a &>/dev/null
  make \
    -j$(nproc) \
    USE_LIBBACKTRACE=0 \
    LOG_LEVEL="TRACE" \
    NIMFLAGS="-d:disableMarchNative -d:chronicles_sinks=textlines -d:chronicles_colors=none --os:windows --gcc.exe=x86_64-w64-mingw32.static-gcc --gcc.linkerexe=x86_64-w64-mingw32.static-gcc --passL:-static" \
    ${BINARIES}
else
  make \
    -j$(nproc) \
    LOG_LEVEL="TRACE" \
    NIMFLAGS="-d:disableMarchNative -d:chronicles_sinks=textlines -d:chronicles_colors=none" \
    PARTIAL_STATIC_LINKING=1 \
    ${BINARIES}
fi

# archive directory (we need the Nim compiler in here)
PREFIX="nimbus-eth2_${PLATFORM}_"
GIT_COMMIT="$(git rev-parse --short HEAD)"
VERSION="$(./env.sh nim --verbosity:0 --hints:off --warnings:off scripts/print_version.nims)"
DIR="${PREFIX}${VERSION}_${GIT_COMMIT}"
DIST_PATH="dist/${DIR}"
# delete old artefacts
rm -rf "dist/${PREFIX}"*.tar.gz
if [[ -d "${DIST_PATH}" ]]; then
  rm -rf "${DIST_PATH}"
fi

mkdir -p "${DIST_PATH}"
mkdir "${DIST_PATH}/scripts"
mkdir "${DIST_PATH}/build"

# copy and checksum binaries, copy scripts and docs
for BINARY in ${BINARIES}; do
  cp -a "./build/${BINARY}" "${DIST_PATH}/build/"
  cd "${DIST_PATH}/build"
  sha512sum "${BINARY}" > "${BINARY}.sha512sum"
  if [[ "${PLATFORM}" == "Windows_amd64" ]]; then
    mv "${BINARY}" "${BINARY}.exe"
  fi
  cd - >/dev/null
done
sed -e "s/GIT_COMMIT/${GIT_COMMIT}/" docker/dist/README.md > "${DIST_PATH}/README.md"
if [[ "${PLATFORM}" == "Windows_amd64" ]]; then
  cp -a docker/dist/README-Windows.md "${DIST_PATH}/"
fi
cp -a scripts/run-beacon-node.sh "${DIST_PATH}/scripts"
cp -a ./run-*-beacon-node.sh "${DIST_PATH}/"

# create the tarball
cd dist
tar czf "${DIR}.tar.gz" "${DIR}"
# don't leave the directory hanging around
rm -rf "${DIR}"
cd - >/dev/null

