#!/bin/bash

set -eux

. $(dirname $0)/vars.sh

DATA_DIR=$SIMULATION_DIR/node-${1}

V_PREFIX="$VALIDATORS_DIR/v$(printf '%06d' ${1})"
PORT=$(printf '5%04d' ${1})

NAT_FLAG=""
if [ "${NAT:-}" == "1" ]; then
  NAT_FLAG="--nat:extip:$(curl -s ifconfig.me)"
fi

$BEACON_NODE_BIN \
  --network:$NETWORK_METADATA_FILE \
  --dataDir:$DATA_DIR \
  --validator:${V_PREFIX}0.privkey \
  --validator:${V_PREFIX}1.privkey \
  --validator:${V_PREFIX}2.privkey \
  --validator:${V_PREFIX}3.privkey \
  --validator:${V_PREFIX}4.privkey \
  --validator:${V_PREFIX}5.privkey \
  --validator:${V_PREFIX}6.privkey \
  --validator:${V_PREFIX}7.privkey \
  --validator:${V_PREFIX}8.privkey \
  --validator:${V_PREFIX}9.privkey \
  --tcpPort:$PORT \
  --udpPort:$PORT \
  $NAT_FLAG \
  --stateSnapshot:$SNAPSHOT_FILE
