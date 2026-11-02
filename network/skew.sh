#!/bin/bash
# Clock-skew experiment on one validator (node-4 by default).
#
# In QBFT the proposer stamps its block with its own clock. The other validators
# accept it only if the timestamp is at least 5 s after the parent and at most
# 1 s ahead of their own clock. A validator running ahead should therefore see
# its blocks refused, and one running behind should produce backdated blocks.
# The market derives its sessions and deadlines from these timestamps, so this
# measures how far a single validator can shift them.
#
# Run from Network/ while the network is up (build the faketime image first,
# see README-besu.md):
#   bash skew.sh
# Options (environment):
#   SKEWS="+2s -3s -8s -30s"  offsets applied in turn to the skewed node
#   PHASE_S=240               length of each phase in seconds (a restarted node
#                             needs time to start and resync before it proposes)
#   NODE=4                    which validator to skew
#   RESTART_CMD               how to restart node {n} with offset {skew}

set -euo pipefail
SKEWS="${SKEWS:-+2s -3s -8s -30s}"
PHASE_S="${PHASE_S:-240}"
NODE="${NODE:-4}"
CONTRACTS="${CONTRACTS:-../contracts}"
BENCH="${BENCH:-js_scripts/besu}"
DEFAULT_RESTART='SKEW={skew} docker compose -f docker-compose.yml -f docker-compose.skew.yml up -d --force-recreate node-{n}'
RESTART_CMD="${RESTART_CMD:-$DEFAULT_RESTART}"
RPC_URLS="${RPC_URLS:-http://127.0.0.1:8545,http://127.0.0.1:8546,http://127.0.0.1:8547,http://127.0.0.1:8548}"
RESULTS="$(pwd)/besu_results"
mkdir -p "$RESULTS"
WATCH="$RESULTS/skew_watch.jsonl"; EVENTS="$RESULTS/skew_events.jsonl"
rm -f "$WATCH" "$EVENTS"

# Validator address of each node, from its key (see nodes/node-N/data/key).
# A function rather than an associative array: macOS ships bash 3.2.
addr_of() {
  case "$1" in
    1) echo 0x2c8beb6e002cba9262cc28ecbe01f0eb31f3d2a2 ;;
    2) echo 0xeb7e550eef9b3c51b987d180700e043ba53b2778 ;;
    3) echo 0x6f5dd510a68ff60773120ac2a3bc67cdce75f8e5 ;;
    4) echo 0xfb39d09605c3c8788b37222b22a677a401477a31 ;;
  esac
}

now_ms() { python3 -c "import time; print(int(time.time() * 1000))"; }
mark() { echo "{\"t\":$(now_ms),\"phase\":\"$1\"}" >> "$EVENTS"; echo "[$(date +%T)] $1"; }
restart() { local pn='{n}' ps='{skew}'; local c="${RESTART_CMD//$pn/$NODE}"; c="${c//$ps/$1}"; eval "$c" >/dev/null; }

(cd "$CONTRACTS" && RPC_URLS="$RPC_URLS" OUT="$WATCH" npx tsx "$BENCH/chainwatch.ts") &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null || true' EXIT
sleep 3

mark "no skew"; sleep "$PHASE_S"
for s in $SKEWS; do
  restart "$s"; mark "node-$NODE clock $s"; sleep "$PHASE_S"
done
restart "+0s"; mark "node-$NODE clock restored"; sleep "$PHASE_S"

kill $WATCHER; wait $WATCHER 2>/dev/null || true
(cd "$CONTRACTS" && WATCH="$WATCH" EVENTS="$EVENTS" OUT="$RESULTS/skew.json" SKEWED="$(addr_of "$NODE")" npx tsx "$BENCH/skewreport.ts")
