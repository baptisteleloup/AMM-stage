"""
Helpers to talk to the Besu QBFT network from Python.
"""

import json
from pathlib import Path
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware
from eth_account import Account

ROOT = Path(__file__).resolve().parent
OUT  = ROOT / "out"

# addresses + rpc written by deploy_besu.py
dep = json.loads((ROOT / "deployed_besu.json").read_text())
RPC      = dep["rpc"]
CHAIN_ID = dep["chainId"]

w3 = Web3(Web3.HTTPProvider(RPC))
w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)   # without this web3 rejects QBFT blocks
assert w3.eth.block_number >= 0, "Besu network unreachable ?"   # is_connected() is buggy, force a real call

# test keys (public) -> NEVER in production
DEPLOYER_KEY = "0x8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63"  # pre-funded account from the genesis
GRID_KEY     = "0x" + "11" * 32
OPERATOR_KEY = "0x" + "22" * 32

deployer = Account.from_key(DEPLOYER_KEY)
grid     = Account.from_key(GRID_KEY)
operator = Account.from_key(OPERATOR_KEY)


def load_abi(name):
    # out/<name>.sol/<name>.json = Foundry artifact
    art = json.loads((OUT / f"{name}.sol" / f"{name}.json").read_text())
    return art["abi"]


def contract(name, addr):
    return w3.eth.contract(address=Web3.to_checksum_address(addr), abi=load_abi(name))


def _sign_raw(func_or_dict, signer, nonce, value=0):
    # build the tx and sign it, without sending
    if isinstance(func_or_dict, dict):
        # raw ETH transfer (dict already prepared)
        tx = dict(func_or_dict)
        tx["nonce"] = nonce
        tx.setdefault("chainId", CHAIN_ID)
        tx.setdefault("gasPrice", w3.eth.gas_price)
        tx.setdefault("gas", 21000)
    else:
        # contract call -> build_transaction handles the encoding
        tx = func_or_dict.build_transaction({
            "gas": 6_000_000,
            "gasPrice": w3.eth.gas_price,
            "nonce": nonce,
            "chainId": CHAIN_ID,
            "value": value,
        })
    signed = signer.sign_transaction(tx)
    return getattr(signed, "raw_transaction", None) or signed.rawTransaction  # attribute name varies across versions


def send(func, signer, value=0):
    # one tx, wait for it to be mined before returning
    nonce = w3.eth.get_transaction_count(signer.address)
    raw = _sign_raw(func, signer, nonce, value)
    return w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(raw))


def send_eth(from_signer, to_addr, wei):
    # just send ETH (to fund accounts for gas)
    nonce = w3.eth.get_transaction_count(from_signer.address)
    tx = {"to": Web3.to_checksum_address(to_addr), "value": int(wei),
          "gas": 21000, "gasPrice": w3.eth.gas_price, "chainId": CHAIN_ID}
    raw = _sign_raw(tx, from_signer, nonce)
    return w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(raw))


def send_batch(funcs, signer):
    # sign everything with consecutive nonces, fire them all, wait only for the last one.
    # nonces are consecutive, so if the last one goes through the others already did.
    # -> several txs per block instead of one, big time saver.
    start_nonce = w3.eth.get_transaction_count(signer.address)
    hashes = []
    for i, func in enumerate(funcs):
        raw = _sign_raw(func, signer, start_nonce + i)
        hashes.append(w3.eth.send_raw_transaction(raw))
    w3.eth.wait_for_transaction_receipt(hashes[-1])
    return hashes