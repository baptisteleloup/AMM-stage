"""
Smart Contracts Deployment
"""

import json
from pathlib import Path
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware
from eth_account import Account

RPC      = "http://127.0.0.1:8545"
CHAIN_ID = 1337

# Pre-funded account in Genesis (alloc). Public key = TEST ONLY.
DEPLOYER_KEY = "0x8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63"

# Grid/Operator accounts (addresses required only for Market deployment)
GRID_KEY     = "0x" + "11" * 32
OPERATOR_KEY = "0x" + "22" * 32

LAMBDA_LOW  = 8_860_000_000_000_000_000
LAMBDA_HIGH = 21_460_000_000_000_000_000

ROOT = Path(__file__).resolve().parent
OUT  = ROOT / "out"

w3 = Web3(Web3.HTTPProvider(RPC))
w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)   # read PoA blocks (QBFT)
assert w3.eth.block_number >= 0, "Besu network unreachable (node-1 on 8545)?"

deployer = Account.from_key(DEPLOYER_KEY)
grid     = Account.from_key(GRID_KEY)
operator = Account.from_key(OPERATOR_KEY)


def load(name):
    art = json.loads((OUT / f"{name}.sol" / f"{name}.json").read_text())
    return art["abi"], art["bytecode"]["object"]


def deploy(name, *args):
    abi, bytecode = load(name)
    Contract = w3.eth.contract(abi=abi, bytecode=bytecode)
    tx = Contract.constructor(*args).build_transaction({
        "gas": 6_000_000,
        "gasPrice": w3.eth.gas_price,
        "nonce": w3.eth.get_transaction_count(deployer.address),
        "chainId": CHAIN_ID,
    })
    signed = deployer.sign_transaction(tx)
    raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
    tx_hash = w3.eth.send_raw_transaction(raw)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"  {name:14s} -> {receipt.contractAddress}  (gas {receipt.gasUsed})")
    return receipt.contractAddress


def main():
    print(f"Reseau Besu (chainId {w3.eth.chain_id})")
    bal = w3.eth.get_balance(deployer.address) / 1e18
    print(f"deployeur = {deployer.address} (solde {bal} ETH)\n")

    print("Deploiement :")
    token_addr   = deploy("EnergyEuro")
    backend_addr = deploy("TokenBackend", token_addr)
    market_addr  = deploy("Market", LAMBDA_LOW, LAMBDA_HIGH, backend_addr, grid.address, operator.address)

    out = {
        "rpc": RPC, "chainId": CHAIN_ID,
        "deployer": deployer.address, "grid": grid.address, "operator": operator.address,
        "EnergyEuro": token_addr, "TokenBackend": backend_addr, "Market": market_addr,
        "lambdaLow": LAMBDA_LOW, "lambdaHigh": LAMBDA_HIGH,
    }
    (ROOT / "deployed_besu.json").write_text(json.dumps(out, indent=2))
    print("\nAdresses ecrites dans deployed_besu.json")


if __name__ == "__main__":
    main()
