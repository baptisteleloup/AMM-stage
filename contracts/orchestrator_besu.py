"""
Besu orchestrator — replays the day's sessions (Nice netputs), batched,
with grid-price re-anchoring per tariff window (peak / off-peak).

netputs_nice.json is indexed by time step: { "0": {id: netput}, "4": {...}, ... }
Each time step = one session: re-anchor if the window changed, submit the 50
orders in one batch, then settle.

Grid prices (paper, section 6.2, French tariff):
  - feed-in (lambda_low)  = 8.86  c€/kWh, constant all day
  - retail  (lambda_high) = 21.46 at PEAK, 16.96 OFF-PEAK
  - peak hours: 8h-12h and 13h-20h  (t in [32,48) U [52,80), 15-min steps)
Re-anchoring only fires at window TRANSITIONS, not every session.

Two modes:
  uv run python orchestrator_besu.py --t 48    # one session (to time it)
  uv run python orchestrator_besu.py --run     # the whole day, target delay between sessions
"""

import sys
import json
import time
import argparse
from pathlib import Path
from web3 import Web3
import besu_common as bc

TARGET_DELAY = 15  # target seconds between two session starts

# grid prices (1e18 scale)
LAMBDA_LOW       = 8_860_000_000_000_000_000     # feed-in, constant
LAMBDA_HIGH_PEAK = 21_460_000_000_000_000_000    # retail, peak
LAMBDA_HIGH_OFF  = 16_960_000_000_000_000_000    # retail, off-peak

ROOT = Path(__file__).resolve().parent
market    = bc.contract("Market", bc.dep["Market"])
prosumers = json.loads((ROOT / "prosumers_nice.json").read_text())   # {id: address}
sessions  = json.loads((ROOT / "netputs_nice.json").read_text())     # {t: {id: netput}}


def is_peak(t: int) -> bool:
    # peak: 8h-12h (t in [32,48)) and 13h-20h (t in [52,80)). 96 steps of 15 min.
    return (32 <= t < 48) or (52 <= t < 80)


def grid_high_for(t: int) -> int:
    # only lambda_high changes with the window; lambda_low is constant
    return LAMBDA_HIGH_PEAK if is_peak(t) else LAMBDA_HIGH_OFF


def submit_and_settle(t: str):
    # build the 50 submitOrder calls, batch them, then settle
    netputs = sessions[t]
    funcs = []
    for pid, netput in netputs.items():
        addr = Web3.to_checksum_address(prosumers[pid])
        funcs.append(market.functions.submitOrder(addr, int(netput)))
    bc.send_batch(funcs, bc.operator)
    bc.send(market.functions.settle(), bc.operator)


def play_one(t: str, current_high=None):
    # play one session; re-anchor lambda_high only if the window changed.
    # returns this session's lambda_high so the caller can track it.
    ti = int(t)
    target_high = grid_high_for(ti)
    window = "peak" if is_peak(ti) else "off-peak"

    if current_high != target_high:
        bc.send(market.functions.setGridPrices(LAMBDA_LOW, target_high), bc.operator)
        print(f"[t={t}] re-anchor grid -> {window} (lambda_high={target_high/1e18:.2f})")

    print(f"[t={t}] ({window}) {len(sessions[t])} orders batched...", end=" ", flush=True)
    submit_and_settle(t)
    print("settled")
    return target_high


def run_day():
    timesteps = sorted(sessions.keys(), key=int)
    print(f"Day: {len(timesteps)} sessions (t={timesteps[0]}..{timesteps[-1]}), target delay {TARGET_DELAY}s\n")
    current_high = None
    for k, t in enumerate(timesteps):
        start = time.time()
        current_high = play_one(t, current_high)
        if k < len(timesteps) - 1:
            left = TARGET_DELAY - (time.time() - start)
            if left > 0:
                time.sleep(left)
            else:
                print(f"  (session took {time.time()-start:.0f}s > {TARGET_DELAY}s: no wait, moving on)")
    print("\nDay done.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--t", type=str, help="play one session (this time step)")
    ap.add_argument("--run", action="store_true", help="play the whole day")
    args = ap.parse_args()

    if args.run:
        run_day()
    elif args.t is not None:
        # single session: force re-anchor to this step's window
        play_one(args.t, current_high=None)
    else:
        print("Usage: --t <step> (one session) or --run (the day)")