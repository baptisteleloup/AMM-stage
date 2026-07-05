"""
Orchestrateur d'une session (production) — destine au cron (toutes les 15 min).

Une execution = une session : lire les netputs -> l'operator soumet -> settle.
"""

import json
from pathlib import Path
from web3 import Web3

RPC = "http://127.0.0.1:8545"

ROOT = Path(__file__).resolve().parent
w3 = Web3(Web3.HTTPProvider(RPC))
assert w3.is_connected(), "Anvil n'est pas lance"

dep = json.loads((ROOT / "deployed.json").read_text())
operator  = dep["operator"]
prosumers = json.loads((ROOT / "prosumers.json").read_text())  # {id: address}


def load_abi(name):
    art = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
    return art["abi"]


market = w3.eth.contract(address=dep["Market"], abi=load_abi("Market"))


def lire_netputs() -> dict:
    """
    Renvoie les netputs de la tranche courante : { "id-prosumer": netput_1e18, ... }
    (echelle 1e18, > 0 vendeur, < 0 acheteur). Les ids correspondent a prosumers.json.

    """
    # --- Pour TESTER sur Anvil, decommenter
    ids = list(prosumers.keys())
    net = {}
    for k, pid in enumerate(ids):
        net[pid] = int(2.5e18) if k % 2 == 0 else int(-0.05e18)
    return net


def submit_orders(netputs: dict):
    """L'operator soumet un netput par prosumer."""
    for pid, netput in netputs.items():
        addr = Web3.to_checksum_address(prosumers[pid])
        tx = market.functions.submitOrder(addr, int(netput)).transact({"from": operator})
        w3.eth.wait_for_transaction_receipt(tx)
    print(f"{len(netputs)} ordres soumis")


def settle():
    """L'operator declenche le reglement puis le reset de la session."""
    tx = market.functions.settle().transact({"from": operator})
    w3.eth.wait_for_transaction_receipt(tx)
    print("session reglee")


def run_session():
    netputs = lire_netputs()
    if not netputs:
        print("lire_netputs() vide : rien a soumettre")
        return
    submit_orders(netputs)
    settle()


if __name__ == "__main__":
    run_session()
