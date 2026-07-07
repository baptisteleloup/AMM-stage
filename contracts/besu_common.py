"""
Module partage pour parler au reseau Besu QBFT depuis Python.

Regroupe les adaptations Besu (vs Anvil) :
  - middleware PoA (lire les blocs QBFT),
  - signature explicite des transactions,
  - transactions legacy (gasPrice, pas EIP-1559),
  - envoi SEQUENTIEL (send, attend chaque recu) OU par LOT (send_batch, plusieurs
    transactions dans les memes blocs -> beaucoup plus rapide).

Importe par setup_besu.py, orchestrator_besu.py, check_state_besu.py.
"""

import json
from pathlib import Path
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware
from eth_account import Account

ROOT = Path(__file__).resolve().parent
OUT  = ROOT / "out"

dep = json.loads((ROOT / "deployed_besu.json").read_text())
RPC      = dep["rpc"]
CHAIN_ID = dep["chainId"]

w3 = Web3(Web3.HTTPProvider(RPC))
w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
assert w3.eth.block_number >= 0, "Reseau Besu injoignable ?"

DEPLOYER_KEY = "0x8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63"
GRID_KEY     = "0x" + "11" * 32
OPERATOR_KEY = "0x" + "22" * 32

deployer = Account.from_key(DEPLOYER_KEY)
grid     = Account.from_key(GRID_KEY)
operator = Account.from_key(OPERATOR_KEY)


def load_abi(name):
    art = json.loads((OUT / f"{name}.sol" / f"{name}.json").read_text())
    return art["abi"]


def contract(name, addr):
    return w3.eth.contract(address=Web3.to_checksum_address(addr), abi=load_abi(name))


def _sign_raw(func_or_dict, signer, nonce, value=0):
    """Construit + signe une transaction (sans l'envoyer). Renvoie le raw."""
    if isinstance(func_or_dict, dict):
        tx = dict(func_or_dict)
        tx["nonce"] = nonce
        tx.setdefault("chainId", CHAIN_ID)
        tx.setdefault("gasPrice", w3.eth.gas_price)
        tx.setdefault("gas", 21000)
    else:
        tx = func_or_dict.build_transaction({
            "gas": 6_000_000,
            "gasPrice": w3.eth.gas_price,
            "nonce": nonce,
            "chainId": CHAIN_ID,
            "value": value,
        })
    signed = signer.sign_transaction(tx)
    return getattr(signed, "raw_transaction", None) or signed.rawTransaction


def send(func, signer, value=0):
    """Envoi SEQUENTIEL : signe, envoie, attend le recu. Simple mais lent."""
    nonce = w3.eth.get_transaction_count(signer.address)
    raw = _sign_raw(func, signer, nonce, value)
    return w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(raw))


def send_eth(from_signer, to_addr, wei):
    """Transfert simple d'ETH (sequentiel)."""
    nonce = w3.eth.get_transaction_count(from_signer.address)
    tx = {"to": Web3.to_checksum_address(to_addr), "value": int(wei),
          "gas": 21000, "gasPrice": w3.eth.gas_price, "chainId": CHAIN_ID}
    raw = _sign_raw(tx, from_signer, nonce)
    return w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(raw))


def send_batch(funcs, signer):
    """
    Envoi par LOT depuis UN meme signer : signe toutes les transactions avec des
    nonces consecutifs, les envoie d'affilee (sans attendre), puis attend le
    dernier recu. Plusieurs tx entrent dans les memes blocs -> bien plus rapide.

    funcs : liste d'appels de fonctions contrat (.functions.foo(...)).
    Renvoie la liste des hashes envoyes.
    """
    start_nonce = w3.eth.get_transaction_count(signer.address)
    hashes = []
    for i, func in enumerate(funcs):
        raw = _sign_raw(func, signer, start_nonce + i)
        hashes.append(w3.eth.send_raw_transaction(raw))
    # attendre que la derniere soit minee (les precedentes le sont alors aussi,
    # car nonces consecutifs = minees dans l'ordre)
    w3.eth.wait_for_transaction_receipt(hashes[-1])
    return hashes
