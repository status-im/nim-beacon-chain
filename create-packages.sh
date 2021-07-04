#!/bin/bash

# Copyright (c) 2020-2021 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

cd "$(dirname $0)"

PKG_NAME=nimbus
PKG_ARCH=amd64
PKG_IMG_DIR=package_image

if [ -z $1 ]; then
  printf "Please provide a Package Version!\n"
  exit 1
fi

PKG_VERSION=$1
if ! [[ "$PKG_VERSION" =~ ^[0-9]+\.[0-9]+ ]]; then
    echo "Invalid Package Version!"
    exit 1
fi

mkdir -p $PKG_IMG_DIR/var/lib/nimbus
mkdir -p $PKG_IMG_DIR/usr/bin

cp build/nimbus_beacon_node $PKG_IMG_DIR/usr/bin
cp build/nimbus_signing_process $PKG_IMG_DIR/usr/bin

fpm -s dir -t deb -n nimbus \
   --deb-no-default-config-files \
  -v $PKG_VERSION \
  -C $PKG_IMG_DIR \
  -d 'dialog' \
  -p ${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb \
  --after-install $PKG_IMG_DIR/postinst \
  --before-remove $PKG_IMG_DIR/prerm \
  --after-remove $PKG_IMG_DIR/postrm \
  --license "Apache 2.0 + MIT" \
  --maintainer "The Nimbus Team" \
  --description "Nim implementation of the Ethereum 2.0 blockchain" \
  --url "https://nimbus.team/"

fpm -s dir -t rpm -n nimbus \
    -v $PKG_VERSION \
    -C $PKG_IMG_DIR \
    -d 'dialog' \
    -p ${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.rpm \
    --after-install $PKG_IMG_DIR/postinst \
    --before-remove $PKG_IMG_DIR/prerm \
    --after-remove $PKG_IMG_DIR/postrm \
    --license "Apache 2.0 + MIT" \
    --maintainer "The Nimbus Team" \
    --description "Nim implementation of the Ethereum 2.0 blockchain" \
    --url "https://nimbus.team/"

# clean up to avoid committing binaries to the repository
rm -rf $PKG_IMG_DIR/usr/bin/

exit 0
