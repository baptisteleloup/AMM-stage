"""
check_state.py — lit l'etat on-chain et l'affiche en tableau.

Lance-le avant/apres une session pour verifier en vrai :
  - solde EEUR et collateral de chaque prosumer,
  - solde du grid et du Market,
  - total (doit etre conserve entre deux etats : rien cree ni detruit).

Lancer : uv run python check_state.py
"""

import json
from pathlib import Path
from web3 import Web3

RPC = "http://127.0.0.1:8545"

ROOT = Path(__file__).resolve().parent
w3 = Web3(Web3.HTTPProvider(RPC))
assert w3.is_connected(), "Anvil n'est pas lance ?"

dep = json.loads((ROOT / "deployed.json").read_text())
prosumers = json.loads((ROOT / "prosumers.json").read_text())  # {id: address}


def load_abi(name):
    art = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
    return art["abi"]


token  = w3.eth.contract(address=dep["EnergyEuro"], abi=load_abi("EnergyEuro"))
market = w3.eth.contract(address=dep["Market"],     abi=load_abi("Market"))


def eeur(addr):
    """Solde EEUR en unites lisibles (divise par 1e18)."""
    return token.functions.balanceOf(Web3.to_checksum_address(addr)).call() / 1e18


def collat(addr):
    return market.functions.collateralOf(Web3.to_checksum_address(addr)).call() / 1e18


def main():
    print(f"{'compte':<22}{'EEUR':>16}{'collateral':>16}")
    print("-" * 54)

    total = 0.0

    # prosumers
    for pid, addr in prosumers.items():
        bal = eeur(addr)
        col = collat(addr)
        total += bal
        # n'affiche que les non-nuls pour rester lisible si beaucoup de comptes
        if bal != 0 or col != 0:
            print(f"{pid:<22}{bal:>16.4f}{col:>16.4f}")

    # infrastructure
    grid_bal   = eeur(dep["grid"])
    market_bal = eeur(dep["Market"])
    total += grid_bal + market_bal

    print("-" * 54)
    print(f"{'grid':<22}{grid_bal:>16.4f}")
    print(f"{'MARKET (depot)':<22}{market_bal:>16.4f}")
    print("-" * 54)
    print(f"{'TOTAL EEUR':<22}{total:>16.4f}")
    print(f"\nsession en cours : {market.functions.prosumerCount().call()} prosumers")


if __name__ == "__main__":
    main()
