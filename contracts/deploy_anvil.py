import json
from pathlib import Path
from web3 import Web3

RPC = "http://127.0.0.1:8545"
w3 = Web3(Web3.HTTPProvider(RPC))
assert w3.is_connected(), "Anvil pas lancé ?"

deployer = w3.eth.accounts[0]
grid     = w3.eth.accounts[1]
operator = w3.eth.accounts[2]
w3.eth.default_account = deployer

LAMBDA_LOW  = 8_860_000_000_000_000_000    # 8.86  feed-in
LAMBDA_HIGH = 21_460_000_000_000_000_000   # 21.46 retail

# racine du projet Foundry (contient out/)
ROOT = Path(__file__).resolve().parent
OUT  = ROOT / "out"


def load(contract_name: str):
    """Charge ABI + bytecode depuis les artefacts Foundry out/<name>.sol/<name>.json."""
    path = OUT / f"{contract_name}.sol" / f"{contract_name}.json"
    art = json.loads(path.read_text())
    return art["abi"], art["bytecode"]["object"]


def deploy(contract_name: str, *args):
    """Deploie un contrat et renvoie (adresse, instance)."""
    abi, bytecode = load(contract_name)
    Contract = w3.eth.contract(abi=abi, bytecode=bytecode)
    tx_hash = Contract.constructor(*args).transact({"from": deployer})
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    addr = receipt.contractAddress
    print(f"  {contract_name:14s} -> {addr}  (gas {receipt.gasUsed})")
    return addr, w3.eth.contract(address=addr, abi=abi)


def main():
    print(f"Connecte a {RPC} (chainId {w3.eth.chain_id})")
    print(f"deployeur={deployer}\ngrid     ={grid}\noperator ={operator}\n")

    print("Deploiement (ordre des dependances) :")
    token_addr,   _ = deploy("EnergyEuro")
    backend_addr, _ = deploy("TokenBackend", token_addr)
    market_addr,  _ = deploy(
        "Market", LAMBDA_LOW, LAMBDA_HIGH, backend_addr, grid, operator
    )

    # sauvegarde pour l'orchestrateur
    out = {
        "rpc": RPC,
        "chainId": w3.eth.chain_id,
        "deployer": deployer,
        "grid": grid,
        "operator": operator,
        "EnergyEuro": token_addr,
        "TokenBackend": backend_addr,
        "Market": market_addr,
        "lambdaLow": LAMBDA_LOW,
        "lambdaHigh": LAMBDA_HIGH,
    }
    (ROOT / "deployed.json").write_text(json.dumps(out, indent=2))
    print("\nAdresses ecrites dans deployed.json")


if __name__ == "__main__":
    main()
