import sys
import json
import hashlib
from pathlib import Path
from web3 import Web3

RPC      = "http://127.0.0.1:8545"
FUND_ETH = 10**17          # 0.1 ETH pour le gas de l'approve
MAX_UINT = 2**256 - 1

ROOT = Path(__file__).resolve().parent
w3 = Web3(Web3.HTTPProvider(RPC))
assert w3.is_connected(), "Anvil n'est pas lance"

dep = json.loads((ROOT / "deployed.json").read_text())
deployer     = dep["deployer"]
backend_addr = dep["TokenBackend"]
w3.eth.default_account = deployer

PROSUMERS_FILE = ROOT / "prosumers.json"


def load_abi(name):
    art = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
    return art["abi"]


def account_for_id(pid: str):
    """Compte de test deterministe derive de l'id (TEST uniquement)."""
    pk = "0x" + hashlib.sha256(pid.encode()).hexdigest()
    return w3.eth.account.from_key(pk)


def generate(n: int):
    """Cree prosumers.json avec n comptes de test {id: address}."""
    data = {}
    for i in range(n):
        pid = f"prosumer-{i}"
        data[pid] = account_for_id(pid).address
    PROSUMERS_FILE.write_text(json.dumps(data, indent=2))
    print(f"prosumers.json genere : {n} comptes de test")


def approve_all():
    """Pour chaque prosumer : fund ETH (gas) puis approve le backend (signe par lui)."""
    token = w3.eth.contract(address=dep["EnergyEuro"], abi=load_abi("EnergyEuro"))
    prosumers = json.loads(PROSUMERS_FILE.read_text())

    for pid in prosumers:
        acct = account_for_id(pid)
        # gas (le deployer finance le compte de test)
        w3.eth.send_transaction({"from": deployer, "to": acct.address, "value": FUND_ETH})
        # approve signe PAR le prosumer (simule son wallet)
        tx = token.functions.approve(backend_addr, MAX_UINT).build_transaction({
            "from": acct.address,
            "nonce": w3.eth.get_transaction_count(acct.address),
            "gas": 200_000,
            "gasPrice": w3.eth.gas_price,
            "chainId": w3.eth.chain_id,
        })
        signed = w3.eth.account.sign_transaction(tx, acct.key)
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
        w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(raw))

    print(f"{len(prosumers)} approvals simules (en prod : faits par les prosumers)")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--generate":
        generate(int(sys.argv[2]))
    else:
        approve_all()
