#!/bin/bash
# Clock-skew experiment: restarts one validator (node-4) with its clock shifted by each offset
# in turn and measures how far it can move block timestamps, from which the market derives
# sessions and deadlines. Writes besu_results/skew_watch.jsonl, skew_events.jsonl and skew.json.
# Only node-4 is skewed in docker-compose.skew.yml, so NODE must stay at 4.
# Run from network/ while the network is up, after building the image (see Dockerfile.faketime):  bash skew.sh
#
# QBFT validators accept a block only if its timestamp is at least 5 s after the parent and at
# most 1 s ahead of their own clock: a node running ahead gets its blocks refused, one running
# behind produces backdated blocks.
# Options (environment):
#   SKEWS="+2s -3s -8s -30s"  offsets applied in turn to the skewed node
#   PHASE_S=240               length of each phase in seconds (a restarted node
#                             needs time to start and resync before it proposes)
#   NODE=4                    which validator to skew (keep 4, see above)
#   RESTART_CMD               how to restart node {n} with offset {skew}

set -euo pipefail
SKEWS="${SKEWS:-+2s -3s -8s -30s}"
PHASE_S="${PHASE_S:-240}"
NODE="${NODE:-4}"
CONTRACTS="${CONTRACTS:-../contracts}"
BENCH="${BENCH:-js_scripts/besu}" # measurement scripts, relative to CONTRACTS
# recreates the node from docker-compose.skew.yml with SKEW set
DEFAULT_RESTART='SKEW={skew} docker compose -f docker-compose.yml -f docker-compose.skew.yml up -d --force-recreate node-{n}'
RESTART_CMD="${RESTART_CMD:-$DEFAULT_RESTART}"
RPC_URLS="${RPC_URLS:-http://127.0.0.1:8545,http://127.0.0.1:8546,http://127.0.0.1:8547,http://127.0.0.1:8548}"
RESULTS="$(pwd)/besu_results"
mkdir -p "$RESULTS"
WATCH="$RESULTS/skew_watch.jsonl"; EVENTS="$RESULTS/skew_events.jsonl"
rm -f "$WATCH" "$EVENTS" # start each run from empty logs

# Validator address of each node, from its key (nodes/node-N/data/key). A function because macOS has bash 3.2.
addr_of() {
  case "$1" in
    1) echo 0x2c8beb6e002cba9262cc28ecbe01f0eb31f3d2a2 ;;
    2) echo 0xeb7e550eef9b3c51b987d180700e043ba53b2778 ;;
    3) echo 0x6f5dd510a68ff60773120ac2a3bc67cdce75f8e5 ;;
    4) echo 0xfb39d09605c3c8788b37222b22a677a401477a31 ;;
  esac
}

now_ms() { python3 -c "import time; print(int(time.time() * 1000))"; }
# mark: timestamps a phase change in skew_events.jsonl
mark() { echo "{\"t\":$(now_ms),\"phase\":\"$1\"}" >> "$EVENTS"; echo "[$(date +%T)] $1"; }
# restart OFFSET: recreates node NODE with its clock shifted by OFFSET
restart() { local pn='{n}' ps='{skew}'; local c="${RESTART_CMD//$pn/$NODE}"; c="${c//$ps/$1}"; eval "$c" >/dev/null; }

# polls every node in the background
(cd "$CONTRACTS" && RPC_URLS="$RPC_URLS" OUT="$WATCH" npx tsx "$BENCH/chainwatch.ts") &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null || true' EXIT
sleep 3 # let the watcher connect

mark "no skew"; sleep "$PHASE_S"
for s in $SKEWS; do
  restart "$s"; mark "node-$NODE clock $s"; sleep "$PHASE_S"
done
restart "+0s"; mark "node-$NODE clock restored"; sleep "$PHASE_S"

kill $WATCHER; wait $WATCHER 2>/dev/null || true
# report: skewed node's share of blocks, block intervals and timestamp lag per phase
(cd "$CONTRACTS" && WATCH="$WATCH" EVENTS="$EVENTS" OUT="$RESULTS/skew.json" SKEWED="$(addr_of "$NODE")" npx tsx "$BENCH/skewreport.ts")
