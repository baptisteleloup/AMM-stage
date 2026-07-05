"""
Le deployer (owner du token) mint des EEUR pour :
  - le grid (infrastructure systeme : mint + approve, car controle par l'exploitant)
  - chaque prosumer liste dans prosumers.json (mint SEULEMENT)

Les prosumers etant souverains, ils approuvent le backend EUX-MEMES depuis leur
wallet. Ce script ne signe donc AUCUN approval de prosumer.
Pour la validation sur Anvil, ces approvals sont joues par simulate_approvals.py
(echafaudage de test).

prosumers.json : { "id-prosumer": "0xAdresse", ... }
"""

import json
from pathlib import Path
from web3 import Web3

RPC       = "http://127.0.0.1:8545"
MINT_EEUR = 1_000_000 * 10**18
MAX_UINT  = 2**256 - 1

ROOT = Path(__file__).resolve().parent
w3 = Web3(Web3.HTTPProvider(RPC))
assert w3.is_connected(), "Anvil n'est pas lance"

dep = json.loads((ROOT / "deployed.json").read_text())
deployer, grid = dep["deployer"], dep["grid"]
backend_addr   = dep["TokenBackend"]
w3.eth.default_account = deployer

prosumers = json.loads((ROOT / "prosumers.json").read_text())  # {id: address}


def load_abi(name):
    art = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
    return art["abi"]


token = w3.eth.contract(address=dep["EnergyEuro"], abi=load_abi("EnergyEuro"))


def main():
    # grid : infrastructure systeme -> mint + approve 
    token.functions.mint(grid, MINT_EEUR).transact({"from": deployer})
    token.functions.approve(backend_addr, MAX_UINT).transact({"from": grid})
    print("grid : finance + approuve (infrastructure)")

    # prosumers : mint SEULEMENT (ils approuvent eux-memes)
    for pid, addr in prosumers.items():
        token.functions.mint(Web3.to_checksum_address(addr), MINT_EEUR).transact({"from": deployer})
        print(f"  mint EEUR -> {pid} ({addr})")

    print(f"Setup termine : {len(prosumers)} prosumers finances (sans approval).")


if __name__ == "__main__":
    main()
