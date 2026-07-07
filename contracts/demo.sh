#!/usr/bin/env bash
#
# Demo de bout en bout de l'AMM energy market sur reseau Besu QBFT.
#
# Deux usages :
#   ./demo.sh          -> demarre la chaine + joue la journee (contrats deja deployes)
#   ./demo.sh --full   -> repart de zero : deploie + setup + approvals + journee
#
# Prerequis : Docker Desktop lance, JAVA_HOME configure (dans ~/.zshrc).

set -e  # stoppe a la premiere erreur

# --- chemins (a adapter si besoin) ---
NETWORK_DIR=~/Desktop/"Stage Telecom"/Network
CONTRACTS_DIR=~/Desktop/"Stage Telecom"/"1 - AMM"/contracts

RPC="http://127.0.0.1:8545"

echo "=== 1. Demarrage du reseau Besu (4 noeuds QBFT) ==="
cd "$NETWORK_DIR"
docker compose up -d

echo "   Attente que la chaine produise des blocs..."
until curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$RPC" | grep -q result; do
  sleep 2
done
echo "   Chaine active."

cd "$CONTRACTS_DIR"

if [ "$1" == "--full" ]; then
  echo ""
  echo "=== 2. Deploiement des contrats ==="
  uv run python deploy_besu.py

  echo ""
  echo "=== 3. Setup : financement (ETH + EEUR) grid + operator + prosumers ==="
  uv run python setup_besu.py

  echo ""
  echo "=== 4. Approvals des prosumers (scenario B, simule) ==="
  uv run python simulate_approvals_besu.py
fi

echo ""
echo "=== Etat AVANT la journee ==="
uv run python check_state_besu.py

echo ""
echo "=== Rejeu de la journee (sessions Nice, 1 pas de temps sur 4) ==="
uv run python orchestrator_besu.py --run

echo ""
echo "=== Etat APRES la journee (verifier conservation) ==="
uv run python check_state_besu.py

echo ""
echo "=== Demo terminee. Pour arreter le reseau : cd $NETWORK_DIR && docker compose down ==="
