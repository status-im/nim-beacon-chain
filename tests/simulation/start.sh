#!/bin/bash

set -eo pipefail

# To allow overriding the program names
TMUX_CMD="${TMUX_CMD:-tmux}"
MULTITAIL_CMD="${MULTITAIL_CMD:-multitail}"
GANACHE_CMD="${GANACHE_CMD:-ganache-cli}"
PROMETHEUS_CMD="${PROMETHEUS_CMD:-prometheus}"
CTAIL_CMD="${CTAIL_CMD:-ctail}"

TMUX_SESSION_NAME="${TMUX_SESSION_NAME:-nbc-sim}"

WAIT_GENESIS="${WAIT_GENESIS:-no}"

USE_MULTITAIL="${USE_MULTITAIL:-no}"
if [[ "$USE_MULTITAIL" != "no" ]]; then
  type "$MULTITAIL_CMD" &>/dev/null || { echo "${MULTITAIL_CMD}" is missing; USE_MULTITAIL="no"; }
fi

USE_TMUX="${USE_TMUX:-no}"
if [[ "$USE_TMUX" == "yes" ]]; then
  type "$TMUX_CMD" &>/dev/null || { echo "${TMUX_CMD}" is missing; USE_TMUX="no"; }
fi

USE_GANACHE="${USE_GANACHE:-yes}"
if [[ "$USE_GANACHE" == "yes" ]]; then
  type "$GANACHE_CMD" &>/dev/null || { echo $GANACHE_CMD is missing; USE_GANACHE="no"; }
fi

USE_PROMETHEUS="${USE_PROMETHEUS:-yes}"
if [[ "$USE_PROMETHEUS" == "yes" ]]; then
  type "$PROMETHEUS_CMD" &>/dev/null || { echo $PROMETHEUS_CMD is missing; USE_PROMETHEUS="no"; }
fi

USE_CTAIL="${USE_CTAIL:-yes}"
if [[ "$USE_CTAIL" == "yes" ]]; then
  type "$CTAIL_CMD" &>/dev/null || { USE_CTAIL="no"; }
fi

# Read in variables
# shellcheck source=/dev/null
source "$(dirname "$0")/vars.sh"

cd "$SIM_ROOT"
mkdir -p "$SIMULATION_DIR"
mkdir -p "$VALIDATORS_DIR"
mkdir -p "$SECRETS_DIR"

cd "$GIT_ROOT"

CUSTOM_NIMFLAGS="${NIMFLAGS} -d:useSysAsserts -d:chronicles_sinks:textlines,json[file] -d:const_preset=mainnet -d:insecure -d:local_testnet"
GANACHE_BLOCK_TIME=5

# Run with "SLOTS_PER_EPOCH=8 ./start.sh" to change these
DEFS=""
DEFS+="-d:SECONDS_PER_ETH1_BLOCK=$GANACHE_BLOCK_TIME "
DEFS+="-d:MAX_COMMITTEES_PER_SLOT=${MAX_COMMITTEES_PER_SLOT:-1} "      # Spec default: 64
DEFS+="-d:SLOTS_PER_EPOCH=${SLOTS_PER_EPOCH:-6} "   # Spec default: 32
DEFS+="-d:SECONDS_PER_SLOT=${SECONDS_PER_SLOT:-6} "  # Spec default: 12

# Windows detection
if uname | grep -qiE "mingw|msys"; then
  MAKE="mingw32-make"
else
  MAKE="make"
fi

make_once () {
  target_flag_var="$1_name"
  if [[ -z "${!target_flag_var}" ]]; then
    export $target_flag_var=1
    $MAKE $1
  fi
}

mkdir -p "${METRICS_DIR}"
./scripts/make_prometheus_config.sh \
  --nodes ${TOTAL_NODES} \
  --base-metrics-port ${BASE_METRICS_PORT} \
  --config-file "${METRICS_DIR}/prometheus.yml" || true # TODO: this currently fails on macOS,
                                                        # but it can be considered non-critical

COMMANDS=()

if [[ "$USE_GANACHE" == "yes" ]]; then
  if [[ "$USE_TMUX" == "yes" ]]; then
    $TMUX_CMD new-window -d -t $TMUX_SESSION_NAME -n "$GANACHE_CMD" "$GANACHE_CMD --blockTime $GANACHE_BLOCK_TIME --gasLimit 100000000 -e 100000 --verbose"
  else
    echo NOTICE: $GANACHE_CMD will be started automatically only with USE_TMUX=yes
    USE_GANACHE="no"
  fi
fi

if [[ "$USE_PROMETHEUS" == "yes" ]]; then
  if [[ "$USE_TMUX" == "yes" ]]; then
    rm -rf "${METRICS_DIR}/data"
    mkdir -p "${METRICS_DIR}/data"
    # TODO: Prometheus is not shut down properly on tmux kill-session
    killall prometheus &>/dev/null || true
    PROMETHEUS_FLAGS="--config.file=./prometheus.yml --storage.tsdb.path=./prometheus"
    $TMUX_CMD new-window -d -t $TMUX_SESSION_NAME -n "$PROMETHEUS_CMD" "cd '$METRICS_DIR' && $PROMETHEUS_CMD $PROMETHEUS_FLAGS"
  else
    echo NOTICE: $PROMETHEUS_CMD will be started automatically only with USE_TMUX=yes
    USE_PROMETHEUS="no"
  fi
fi

$MAKE -j2 --no-print-directory NIMFLAGS="$CUSTOM_NIMFLAGS $DEFS" LOG_LEVEL="${LOG_LEVEL:-DEBUG}" nimbus_beacon_node nimbus_signing_process nimbus_validator_client

EXISTING_VALIDATORS=0
if [[ -f "$DEPOSITS_FILE" ]]; then
  # We count the number of deposits by counting the number of
  # occurrences of the 'deposit_data_root' field:
  EXISTING_VALIDATORS=$(grep -o -i deposit_data_root "$DEPOSITS_FILE" | wc -l)
fi

if [[ $EXISTING_VALIDATORS -ne $NUM_VALIDATORS ]]; then
  make_once deposit_contract

  rm -rf "$VALIDATORS_DIR"
  rm -rf "$SECRETS_DIR"

  build/deposit_contract generateSimulationDeposits \
    --count="${NUM_VALIDATORS}" \
    --out-validators-dir="$VALIDATORS_DIR" \
    --out-secrets-dir="$SECRETS_DIR" \
    --out-deposits-file="$DEPOSITS_FILE"

  echo "All deposits prepared"
fi

if [ ! -f "${SNAPSHOT_FILE}" ]; then
  if [[ "${WAIT_GENESIS}" != "yes" ]]; then
    echo Creating testnet genesis...
    $BEACON_NODE_BIN \
      --data-dir="${SIMULATION_DIR}/node-$BOOTSTRAP_NODE" \
      createTestnet \
      $WEB3_ARG \
      --deposits-file="${DEPOSITS_FILE}" \
      --total-validators="${NUM_VALIDATORS}" \
      --output-genesis="${SNAPSHOT_FILE}" \
      --output-bootstrap-file="${NETWORK_BOOTSTRAP_FILE}" \
      --bootstrap-address=127.0.0.1 \
      --bootstrap-port=$(( BASE_P2P_PORT + BOOTSTRAP_NODE )) \
      --netkey-file=network_key.json \
      --key-insecure-password=true \
      --netkey-insecure-password=true \
      --non-interactive=true \
      --genesis-offset=30 # Delay in seconds
  fi
fi

function run_cmd {
  i=$1
  CMD=$2
  bin_name=$3
  if [[ "$USE_TMUX" == "yes" ]]; then
    echo "Starting node $i..."
    $TMUX_CMD select-window -t "${TMUX_SESSION_NAME}:sim"
    $TMUX_CMD split-window -t "${TMUX_SESSION_NAME}" "if ! $CMD; then read; fi"
    $TMUX_CMD select-layout -t "${TMUX_SESSION_NAME}:sim" tiled
  elif [[ "$USE_MULTITAIL" != "no" ]]; then
    if [[ "$i" == "$BOOTSTRAP_NODE" ]]; then
      SLEEP="0"
    else
      SLEEP="3"
    fi
    # "multitail" closes the corresponding panel when a command exits, so let's make sure it doesn't exit
    COMMANDS+=( " -cT ansi -t '$bin_name #$i' -l 'sleep $SLEEP; $CMD; echo [node execution completed]; while true; do sleep 100; done'" )
  else
    eval "${CMD}" &
  fi
}

DEPOSIT_CONTRACT_ADDRESS="0x0000000000000000000000000000000000000000"
DEPOSIT_CONTRACT_BLOCK="0x0000000000000000000000000000000000000000000000000000000000000000"

if [ "$USE_GANACHE" != "no" ]; then
  make_once deposit_contract
  echo Deploying the validator deposit contract...

  DEPLOY_CMD_OUTPUT=$($DEPOSIT_CONTRACT_BIN deploy $WEB3_ARG)
  # https://stackoverflow.com/questions/918886/how-do-i-split-a-string-on-a-delimiter-in-bash
  OUTPUT_PIECES=(${DEPLOY_CMD_OUTPUT//;/ })
  DEPOSIT_CONTRACT_ADDRESS=${OUTPUT_PIECES[0]}
  DEPOSIT_CONTRACT_BLOCK=${OUTPUT_PIECES[1]}

  echo Contract deployed at $DEPOSIT_CONTRACT_ADDRESS:$DEPOSIT_CONTRACT_BLOCK

  if [[ "$WAIT_GENESIS" == "yes" ]]; then
    run_cmd "(deposit maker)" "$DEPOSIT_CONTRACT_BIN sendDeposits \
      --deposits-file='$DEPOSITS_FILE' \
      --min-delay=0 --max-delay=1 \
      $WEB3_ARG \
      --deposit-contract=${DEPOSIT_CONTRACT_ADDRESS}"
  fi
fi

echo Wrote $NETWORK_METADATA_FILE:
tee "$NETWORK_METADATA_FILE" <<EOF
{
  "runtimePreset": {
    "MIN_GENESIS_ACTIVE_VALIDATOR_COUNT": ${NUM_VALIDATORS},
    "MIN_GENESIS_TIME": 0,
    "GENESIS_DELAY": 10,
    "GENESIS_FORK_VERSION": "0x00000000",
    "ETH1_FOLLOW_DISTANCE": 1,
  },
  "depositContractAddress": "${DEPOSIT_CONTRACT_ADDRESS}",
  "depositContractDeployedAt": "${DEPOSIT_CONTRACT_BLOCK}"
}
EOF

if [[ "$USE_TMUX" == "yes" ]]; then
  $TMUX_CMD select-window -t "${TMUX_SESSION_NAME}:sim"
fi

# Delete any leftover address files from a previous session
if [ -f "${BOOTSTRAP_ENR_FILE}" ]; then
  rm "${BOOTSTRAP_ENR_FILE}"
fi

# Kill child processes on Ctrl-C/SIGTERM/exit, passing the PID of this shell
# instance as the parent and the target process name as a pattern to the
# "pkill" command.
if [[ "$USE_MULTITAIL" == "no" && "$USE_TMUX" != "yes" ]]; then
  trap 'pkill -P $$ nimbus_beacon_node' SIGINT EXIT
fi

LAST_WAITING_NODE=0

for i in $(seq $BOOTSTRAP_NODE -1 $TOTAL_USER_NODES); do
  if [[ "$i" != "$BOOTSTRAP_NODE" && "$USE_MULTITAIL" == "no" ]]; then
    # Wait for the master node to write out its address file
    while [ ! -f "${BOOTSTRAP_ENR_FILE}" ]; do
      if (( LAST_WAITING_NODE != i )); then
        echo Waiting for $BOOTSTRAP_ENR_FILE to appear...
        LAST_WAITING_NODE=i
      fi
      sleep 0.1
    done
  fi

  run_cmd $i "${SIM_ROOT}/run_node.sh ${i} --verify-finalization" "node"

  if [ "${USE_BN_VC_VALIDATOR_SPLIT:-}" == "yes" ]; then
    # start the VC with a few seconds of delay so that there are less RPC connection retries
    run_cmd $i "sleep 3 && ${SIM_ROOT}/run_validator.sh ${i}" "validator"
  fi
done

if [[ "$USE_CTAIL" != "no" ]]; then
  if [[ "$USE_TMUX" == "yes" ]]; then
    $TMUX_CMD new-window -d -t $TMUX_SESSION_NAME -n "$CTAIL_CMD" "$CTAIL_CMD tail -q -n +1 -f ${SIMULATION_DIR}/node-*/beacon_node.log"
  else
    echo NOTICE: $CTAIL_CMD will be started automatically only with USE_TMUX=1
    USE_CTAIL="no"
  fi
fi

if [[ "$USE_TMUX" == "yes" ]]; then
  # kill the console window in the pane where the simulation is running
  $TMUX_CMD kill-pane -t $TMUX_SESSION_NAME:sim.0
  $TMUX_CMD select-window -t "${TMUX_SESSION_NAME}:sim"
  $TMUX_CMD select-layout tiled
elif [[ "$USE_MULTITAIL" != "no" ]]; then
  eval $MULTITAIL_CMD -s 3 -M 0 -x \"Nimbus beacon chain\" "${COMMANDS[@]}"
else
  wait # Stop when all nodes have gone down
fi
