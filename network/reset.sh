#!/bin/bash
# Restarts the four-validator Besu network from block zero on genesis.json. Keeps the
# validator keys (nodes/node-N/data/key), deletes the rest of each data folder, then
# waits until the chain produces blocks.
# Run from network/:  bash reset.sh

set -euo pipefail
cd "$(dirname "$0")" # works from any directory

docker compose down --remove-orphans >/dev/null 2>&1 || true # stop the nodes if running

for n in 1 2 3 4; do
  d="nodes/node-$n/data"
  [ -f "$d/key" ] || { echo "missing $d/key"; exit 1; } # the key fixes the validator address
  find "$d" -mindepth 1 -maxdepth 1 ! -name key -exec rm -rf {} + # wipe chain data, keep the key
done
echo "chain data wiped, validator keys kept"

docker compose pull -q
docker compose up -d
echo "waiting for the first blocks..."
for i in $(seq 1 60); do # up to 60 x 5 s
  h=$(curl -s -m 2 -X POST -H 'content-type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
      http://127.0.0.1:8545 | sed -n 's/.*"result":"\(0x[0-9a-f]*\)".*/\1/p' || true)
  if [ -n "$h" ] && [ "$((h))" -ge 2 ]; then # two blocks: the validators reach consensus
    echo "network up, block $((h))"
    docker compose exec -T node-1 /opt/besu/bin/besu --version 2>/dev/null | tail -1 || true # record the Besu version
    exit 0
  fi
  sleep 5
done
echo "no blocks after 5 minutes; check 'docker compose logs node-1'"
exit 1
