"""
Setup Besu (scenario B) — a lancer une fois apres le deploiement.

Sur Besu, personne n'est finance automatiquement (contrairement a Anvil). Il faut :
  - envoyer de l'ETH (gas) au grid, a l'operator, et aux prosumers,
  - minter des EEUR au grid et aux prosumers,
  - approuver le backend pour le grid (infra systeme).

Les prosumers approuvent eux-memes (scenario B) -> joue par simulate_approvals_besu
pour la validation. Ici on ne fait QUE financer + mint.

Lit prosumers_nice.json { "id": "0xAdresse" } (adresses remplies par ce script si absentes).
Lancer : uv run python setup_besu.py
"""

import json
from pathlib import Path
from web3 import Web3
import besu_common as bc

MINT_EEUR = 1_000_000 * 10**18
GAS_ETH   = 10**17          # 0.1 ETH de gas par compte
MAX_UINT  = 2**256 - 1

ROOT = Path(__file__).resolve().parent
token = bc.contract("EnergyEuro", bc.dep["EnergyEuro"])
backend_addr = bc.dep["TokenBackend"]

prosumers = json.loads((ROOT / "prosumers_nice.json").read_text())


def main():
    # 1. financer grid + operator en ETH (gas)
    bc.send_eth(bc.deployer, bc.grid.address, GAS_ETH)
    bc.send_eth(bc.deployer, bc.operator.address, GAS_ETH * 5)  # l'operator paie bcp de gas
    print("grid + operator finances en ETH")

    # 2. grid : mint EEUR + approve (infra systeme)
    bc.send(token.functions.mint(bc.grid.address, MINT_EEUR), bc.deployer)
    bc.send(token.functions.approve(backend_addr, MAX_UINT), bc.grid)
    print("grid : mint + approve")

    # 3. prosumers : ETH (gas) + mint EEUR (approvals faits par eux-memes -> scenario B)
    for pid, addr in prosumers.items():
        addr = Web3.to_checksum_address(addr)
        bc.send_eth(bc.deployer, addr, GAS_ETH)
        bc.send(token.functions.mint(addr, MINT_EEUR), bc.deployer)
    print(f"{len(prosumers)} prosumers finances (ETH + EEUR), sans approval")

    print("Setup Besu termine.")


if __name__ == "__main__":
    main()
