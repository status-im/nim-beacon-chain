#!/usr/bin/env bash

# Copyright (c) 2018-2019 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

if [[ $OS = "Windows_NT" ]]; then
  if [ -f "$1" ]; then
    # Copy file
    cp -a "${1}" "${2}"
    DST_FILE=$2
    if [ -d "$2" ]; then
      SRC_NAME="$(basename -- $1)"
      DST_FILE=$(realpath ${2})/$SRC_NAME
    fi
    # Single file was copied, so we setting file permissions only.
    icacls "${DST_FILE}" //Q //inheritance:r //grant:r "${USERDOMAIN}\\${USERNAME}":\(F\);
  else
    if [ -d "$1" ]; then
      SRC_NAME="$(basename -- $1)"
      if [ -d "$2" ]; then
        DST_DIR=${2}/$SRC_NAME
      else
        DST_DIR=${2}
      fi
      DST_FILES=${DST_DIR}
      # Copy directory
      cp -a "${1}" "${2}"
      # Directory was copied, so we update destination directory permissions.
      icacls "${DST_DIR}" //Q //inheritance:r //grant:r "${USERDOMAIN}\\${USERNAME}":\(OI\)\(CI\)\(F\);
      # And update permissions for all files inside of destination directory.
      icacls "${DST_FILES}" //Q //T //inheritance:r //grant:r "${USERDOMAIN}\\${USERNAME}":\(F\);
    fi
  fi
else
  cp -a $1 $2;
fi
