"""
Besu setup — run once after deployment.
"""

import json
from pathlib import Path
from web3 import Web3
import besu_common as bc

MINT_EEUR = 1_000_000 * 10**18
GAS_ETH   = 10**17          # 0.1 ETH of gas per account
MAX_UINT  = 2**256 - 1

ROOT = Path(__file__).resolve().parent
token = bc.contract("EnergyEuro", bc.dep["EnergyEuro"])
backend_addr = bc.dep["TokenBackend"]

prosumers = json.loads((ROOT / "prosumers_nice.json").read_text())


def main():
    # fund grid + operator with ETH (gas)
    bc.send_eth(bc.deployer, bc.grid.address, GAS_ETH)
    bc.send_eth(bc.deployer, bc.operator.address, GAS_ETH * 5)  # operator pays a lot of gas
    print("grid + operator funded with ETH")

    # grid: mint EEUR + approve (system infra)
    bc.send(token.functions.mint(bc.grid.address, MINT_EEUR), bc.deployer)
    bc.send(token.functions.approve(backend_addr, MAX_UINT), bc.grid)
    print("grid: mint + approve")

    # prosumers: ETH (gas) + mint EEUR (they approve themselves)
    for pid, addr in prosumers.items():
        addr = Web3.to_checksum_address(addr)
        bc.send_eth(bc.deployer, addr, GAS_ETH)
        bc.send(token.functions.mint(addr, MINT_EEUR), bc.deployer)
    print(f"{len(prosumers)} prosumers funded (ETH + EEUR), no approval")

    print("Besu setup done.")


if __name__ == "__main__":
    main()