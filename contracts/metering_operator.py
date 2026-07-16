"""
Metering operator — the only privileged role left (it reads the meters).

Per slot: netputs (Nice replay, data step = sid % 96), Merkle tree over ALL
prosumers (netput 0 if inactive, required for challenges), ONE tx:
openSession(sid, root, s, d). Leaves + proofs go to leaves/<day>/<sid>.json
(off-chain distribution channel, one file per session here for simplicity).

End of day: recompute each prosumer's net amount from the on-chain (r, c)
with the SAME floor math as the contract, then closeDay. No submitOrder,
no setGridPrices, no settle: those are gone (contract + keepers).

  uv run python metering_operator.py --slot <sid>    # open one session
  uv run python metering_operator.py --close-day <d> # post the netting batch
  uv run python metering_operator.py --run           # live loop
"""

import os
import json
import time
import argparse
from pathlib import Path
from web3 import Web3
import besu_common as bc
import merkle

SLOT = 900                      # must match Market.SLOT
WAD  = 10**18

ROOT = Path(__file__).resolve().parent
LEAVES_DIR = ROOT / "leaves"

market    = bc.contract("Market", bc.dep["Market"])
prosumers = json.loads((ROOT / "prosumers_nice.json").read_text())   # {id: address}
sessions  = json.loads((ROOT / "netputs_nice.json").read_text())     # {t: {id: netput}}

# fixed ordering: leaf index = position in this list, same every session
IDS   = sorted(prosumers.keys(), key=int)
ADDRS = [Web3.to_checksum_address(prosumers[i]) for i in IDS]


def mul_wad(a: int, b: int) -> int:
    # PRB UD60x18 mul: floor(a * b / 1e18). The challenge compares against this.
    return a * b // WAD


def open_session(sid: int):
    step = str(sid % 96)
    netputs = sessions.get(step, {})

    leaves, salts, nps = [], [], []
    s = d = 0
    for pid, addr in zip(IDS, ADDRS):
        n = int(netputs.get(pid, 0))
        salt = os.urandom(32)
        leaves.append(merkle.leaf(addr, n, salt))
        salts.append(salt)
        nps.append(n)
        if n > 0: s += n
        else:     d += -n

    root = merkle.root(leaves)
    bc.send(market.functions.openSession(sid, root, s, d), bc.operator)

    day_dir = LEAVES_DIR / str(sid // 96)
    day_dir.mkdir(parents=True, exist_ok=True)
    (day_dir / f"{sid}.json").write_text(json.dumps({
        pid: {
            "netput": nps[i],
            "salt": "0x" + salts[i].hex(),
            "index": i,
            "proof": ["0x" + h.hex() for h in merkle.proof(leaves, i)],
        } for i, pid in enumerate(IDS)
    }))
    print(f"[sid={sid}] (t={step}) opened: s={s/1e18:.2f} d={d/1e18:.2f} root={root.hex()[:10]}..")


def close_day(day: int, wait: bool = True):
    # keeper settles; wait for it, then compute amounts from on-chain prices
    while True:
        opened  = market.functions.openedCount(day).call()
        settled = market.functions.settledCount(day).call()
        if settled == opened:
            break
        if not wait:
            raise SystemExit(f"day {day}: {opened - settled} sessions not settled yet")
        time.sleep(5)

    amounts = {a: 0 for a in ADDRS}
    day_dir = LEAVES_DIR / str(day)
    for f in sorted(day_dir.glob("*.json"), key=lambda p: int(p.stem)):
        sid = int(f.stem)
        sess = market.functions.sessions(sid).call()
        r, c = sess[5], sess[6]                       # (opened, settled, root, s, d, r, c, ...)
        data = json.loads(f.read_text())
        for pid, addr in zip(IDS, ADDRS):
            n = data[pid]["netput"]
            if n > 0: amounts[addr] += mul_wad(n, r)
            elif n < 0: amounts[addr] -= mul_wad(-n, c)

    accts = [a for a in ADDRS if amounts[a] != 0]
    amts  = [amounts[a] for a in accts]
    day_root = merkle.root([merkle.amount_leaf(a, amounts[a]) for a in accts]) if accts else b"\x00" * 32

    bc.send(market.functions.closeDay(day, day_root, accts, amts), bc.operator)
    net = sum(amts)
    print(f"[day={day}] batch posted: {len(accts)} accounts, net grid leg {net/1e18:+.2f} EEUR")


def run():
    print(f"Metering live, slot {SLOT}s, {len(IDS)} prosumers\n")
    prev_day = None
    while True:
        sid = int(time.time() // SLOT)
        day = sid // 96
        if prev_day is not None and day != prev_day:
            close_day(prev_day)
        prev_day = day
        open_session(sid)
        left = (sid + 1) * SLOT - time.time()
        if left > 0:
            time.sleep(left)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--slot", type=int, help="open one session (this sid)")
    ap.add_argument("--close-day", type=int, help="post the netting batch for a day")
    ap.add_argument("--run", action="store_true", help="live loop")
    args = ap.parse_args()

    if args.run:
        run()
    elif args.slot is not None:
        open_session(args.slot)
    elif args.close_day is not None:
        close_day(args.close_day, wait=False)
    else:
        print("Usage: --slot <sid> | --close-day <day> | --run")
