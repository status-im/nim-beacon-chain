#!/bin/bash

set -eu

# Read in variables
. $(dirname $0)/vars.sh

# Set a default value for the env vars usually supplied by nimbus Makefile

export NUM_VALIDATORS=${VALIDATORS:-721}
export NUM_NODES=${NODES:-1}
export NUM_MISSING_NODES=${MISSING_NODES:-0}

# Set DEPOSIT_WEB3_URL_ARG to empty to get genesis state from file, not using web3
export DEPOSIT_WEB3_URL_ARG=
export DEPOSIT_CONTRACT_ADDRESS=0x


cd "$SIM_ROOT"
mkdir -p "$SIMULATION_DIR"
mkdir -p "$VALIDATORS_DIR"

cd "$GIT_ROOT"
mkdir -p $BUILD_OUTPUTS_DIR

# Run with "SHARD_COUNT=4 ./start.sh" to change these
DEFS="-d:chronicles_log_level=DEBUG "
DEFS+="-d:SHARD_COUNT=${SHARD_COUNT:-16} "      # Spec default: 1024
DEFS+="-d:SLOTS_PER_EPOCH=${SLOTS_PER_EPOCH:-16} "   # Spec default: 64
DEFS+="-d:SECONDS_PER_SLOT=${SECONDS_PER_SLOT:-18} " # Spec default: 6

LAST_VALIDATOR_NUM=$(( $NUM_VALIDATORS - 1 ))
LAST_VALIDATOR="$VALIDATORS_DIR/v$(printf '%07d' $LAST_VALIDATOR_NUM).deposit.json"

if [ ! -f $LAST_VALIDATOR ]; then
  if [[ -z "$SKIP_BUILDS" ]]; then
    nim c -o:"$VALIDATOR_KEYGEN_BIN" $DEFS -d:release beacon_chain/validator_keygen
    nim c -o:"$DEPLOY_DEPOSIT_CONTRACT_BIN" $DEFS -d:release beacon_chain/deploy_deposit_contract

  fi

  if [ "$DEPOSIT_WEB3_URL_ARG" != "" ]; then
    export DEPOSIT_CONTRACT_ADDRESS=$($DEPLOY_DEPOSIT_CONTRACT_BIN $DEPOSIT_WEB3_URL_ARG)
  fi

  $VALIDATOR_KEYGEN_BIN \
    --totalValidators=$NUM_VALIDATORS \
    --outputDir="$VALIDATORS_DIR" \
    --generateFakeKeys=yes \
    $DEPOSIT_WEB3_URL_ARG \
    --depositContractAddress=$DEPOSIT_CONTRACT_ADDRESS
fi

if [[ -z "$SKIP_BUILDS" ]]; then
  nim c -o:"$BEACON_NODE_BIN" $DEFS --opt:speed --debuginfo beacon_chain/beacon_node
fi

if [ ! -f $SNAPSHOT_FILE ]; then
  $BEACON_NODE_BIN \
    --dataDir=$SIMULATION_DIR/node-0 \
    createTestnet \
    --networkId=1000 \
    --validatorsDir=$VALIDATORS_DIR \
    --totalValidators=$NUM_VALIDATORS \
    --outputGenesis=$SNAPSHOT_FILE \
    --outputNetwork=$NETWORK_METADATA_FILE \
    --bootstrapAddress=127.0.0.1 \
    --bootstrapPort=50000 \
    --genesisOffset=5 # Delay in seconds
fi

# Delete any leftover address files from a previous session
if [ -f $MASTER_NODE_ADDRESS_FILE ]; then
  rm $MASTER_NODE_ADDRESS_FILE
fi

# multitail support
MULTITAIL="${MULTITAIL:-multitail}" # to allow overriding the program name
USE_MULTITAIL="${USE_MULTITAIL:-no}" # make it an opt-in
type "$MULTITAIL" &>/dev/null || USE_MULTITAIL="no"

# Kill child processes on Ctrl-C by sending SIGTERM to the whole process group,
# passing the negative PID of this shell instance to the "kill" command.
# Trap and ignore SIGTERM, so we don't kill this process along with its children.
if [ "$USE_MULTITAIL" = "no" ]; then
  trap '' SIGTERM
  trap "kill -- -$$" SIGINT EXIT
fi

COMMANDS=()
LAST_NODE=$(( $NUM_NODES - 1 ))

for i in $(seq 0 $LAST_NODE); do
  if [[ "$i" == "0" ]]; then
    sleep 0
  elif [ "$USE_MULTITAIL" = "no" ]; then
    # Wait for the master node to write out its address file
    while [ ! -f $MASTER_NODE_ADDRESS_FILE ]; do
      sleep 0.1
    done
  fi

  CMD="${SIM_ROOT}/run_node.sh $i"

  if [ "$USE_MULTITAIL" != "no" ]; then
    if [ "$i" = "0" ]; then
      SLEEP="0"
    else
      SLEEP="2"
    fi
    # "multitail" closes the corresponding panel when a command exits, so let's make sure it doesn't exit
    COMMANDS+=( " -cT ansi -t 'node #$i' -l 'sleep $SLEEP; $CMD; echo [node execution completed]; while true; do sleep 100; done'" )
  else
    eval $CMD &
  fi
done

if [ "$USE_MULTITAIL" != "no" ]; then
  eval $MULTITAIL -s 3 -M 0 -x \"Nimbus beacon chain\" "${COMMANDS[@]}"
else
  wait # Stop when all nodes have gone down
fi
