"""
check_state_besu.py — lit l'etat on-chain (Besu) et l'affiche.

Lance-le avant/apres une session pour verifier la conservation.
Lancer : uv run python check_state_besu.py
"""

import json
from pathlib import Path
from web3 import Web3
import besu_common as bc

ROOT = Path(__file__).resolve().parent
token     = bc.contract("EnergyEuro", bc.dep["EnergyEuro"])
market    = bc.contract("Market", bc.dep["Market"])
prosumers = json.loads((ROOT / "prosumers_nice.json").read_text())


def eeur(addr):
    return token.functions.balanceOf(Web3.to_checksum_address(addr)).call() / 1e18


def collat(addr):
    return market.functions.collateralOf(Web3.to_checksum_address(addr)).call() / 1e18


def main():
    print(f"{'compte':<22}{'EEUR':>16}{'collateral':>16}")
    print("-" * 54)

    total = 0.0
    for pid, addr in prosumers.items():
        bal, col = eeur(addr), collat(addr)
        total += bal
        if bal != 0 or col != 0:
            print(f"{pid:<22}{bal:>16.4f}{col:>16.4f}")

    grid_bal   = eeur(bc.dep["grid"])
    market_bal = eeur(bc.dep["Market"])
    total += grid_bal + market_bal

    print("-" * 54)
    print(f"{'grid':<22}{grid_bal:>16.4f}")
    print(f"{'MARKET (depot)':<22}{market_bal:>16.4f}")
    print("-" * 54)
    print(f"{'TOTAL EEUR':<22}{total:>16.4f}")
    print(f"\nsession en cours : {market.functions.prosumerCount().call()} prosumers")


if __name__ == "__main__":
    main()
