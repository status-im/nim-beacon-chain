#!/usr/bin/env bash

# Copyright (c) 2018-2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

[[ -z "$1" ]] && { echo "Usage: $(basename $0) path"; exit 1; }

if uname | grep -qiE "mingw|msys"; then
	ON_WINDOWS=1
else
	ON_WINDOWS=0
fi

if [[ "${ON_WINDOWS}" == "1" ]]; then
  if [[ ! -d "$1" ]]; then
    # Create full path.
    mkdir -p "$1";
    # Remove all inherited ACEs from path $1 ACL and grant full access rights
    # to current user only in $1 ACL.
    icacls "$1" //Q //inheritance:r //grant:r $USERDOMAIN\\$USERNAME:\(OI\)\(CI\)\(F\);
  fi
else
  # Create full path with proper permissions.
  mkdir -m 0700 -p $1
fi

