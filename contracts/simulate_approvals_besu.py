"""
Simmulate approvals (read README).
"""

import sys
import json
import hashlib
from pathlib import Path
from web3 import Web3
import besu_common as bc

MAX_UINT = 2**256 - 1
ROOT = Path(__file__).resolve().parent
PROSUMERS_FILE = ROOT / "prosumers_nice.json"

backend_addr = bc.dep["TokenBackend"]
token = bc.contract("EnergyEuro", bc.dep["EnergyEuro"])


def account_for_id(pid: str):
    pk = "0x" + hashlib.sha256(pid.encode()).hexdigest()
    return bc.w3.eth.account.from_key(pk)


def generate(n: int):
    data = {f"prosumer-{i}": account_for_id(f"prosumer-{i}").address for i in range(n)}
    PROSUMERS_FILE.write_text(json.dumps(data, indent=2))
    print(f"prosumers_nice.json generated : {n} comptes de test")


def approve_all():
    prosumers = json.loads(PROSUMERS_FILE.read_text())
    for pid in prosumers:
        acct = account_for_id(pid)
        bc.send(token.functions.approve(backend_addr, MAX_UINT), acct)
    print(f"{len(prosumers)} approvals simulated")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--generate":
        generate(int(sys.argv[2]))
    else:
        approve_all()
