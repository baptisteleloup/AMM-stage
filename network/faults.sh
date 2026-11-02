#!/bin/bash
# Fault-tolerance experiment on the four-validator QBFT network.
#
# Phases: all four up, one validator stopped, two stopped, one restarted, all
# restarted. QBFT with four validators tolerates one fault: the chain should keep
# producing blocks with three, stop with two, and resume without any fork.
#
# Run from Network/ while the network is up:
#   bash faults.sh
# Options (environment):
#   PHASE_S=120              length of each phase in seconds
#   CONTRACTS=../contracts   where node_modules and js_scripts/besu live
#   STOP_CMD / START_CMD     how to stop or start node {n}; Docker by default

set -euo pipefail
PHASE_S="${PHASE_S:-120}"
CONTRACTS="${CONTRACTS:-../contracts}"
BENCH="${BENCH:-js_scripts/besu}"
DEFAULT_STOP='docker stop besu-node-{n}'
DEFAULT_START='docker start besu-node-{n}'
STOP_CMD="${STOP_CMD:-$DEFAULT_STOP}"
START_CMD="${START_CMD:-$DEFAULT_START}"
RPC_URLS="${RPC_URLS:-http://127.0.0.1:8545,http://127.0.0.1:8546,http://127.0.0.1:8547,http://127.0.0.1:8548}"
RESULTS="$(pwd)/besu_results"
mkdir -p "$RESULTS"
WATCH="$RESULTS/watch.jsonl"; EVENTS="$RESULTS/events.jsonl"
rm -f "$WATCH" "$EVENTS"

now_ms() { python3 -c "import time; print(int(time.time() * 1000))"; }
mark()  { echo "{\"t\":$(now_ms),\"phase\":\"$1\"}" >> "$EVENTS"; echo "[$(date +%T)] $1"; }
node_cmd() { local p='{n}'; local c="${1//$p/$2}"; eval "$c" >/dev/null; }

(cd "$CONTRACTS" && RPC_URLS="$RPC_URLS" OUT="$WATCH" npx tsx "$BENCH/chainwatch.ts") &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null || true' EXIT
sleep 3

mark "4 validators up";         sleep "$PHASE_S"
node_cmd "$STOP_CMD" 4;  mark "node-4 stopped (3 up)";  sleep "$PHASE_S"
node_cmd "$STOP_CMD" 3;  mark "node-3 stopped (2 up)";  sleep "$PHASE_S"
node_cmd "$START_CMD" 3; mark "node-3 restarted (3 up)"; sleep "$PHASE_S"
node_cmd "$START_CMD" 4; mark "node-4 restarted (4 up)"; sleep "$PHASE_S"

kill $WATCHER; wait $WATCHER 2>/dev/null || true
(cd "$CONTRACTS" && RPC_URLS="$RPC_URLS" WATCH="$WATCH" EVENTS="$EVENTS" OUT="$RESULTS/faults.json" npx tsx "$BENCH/faultreport.ts")
