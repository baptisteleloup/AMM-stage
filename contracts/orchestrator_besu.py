"""
Orchestrateur Besu — rejoue les sessions de la journee (netputs Nice), en LOT,
avec re-ancrage des prix grid par plage horaire (heures pleines / creuses).

netputs_nice.json indexe par pas de temps : { "0": {id: netput}, "4": {...}, ... }
Chaque pas de temps = une session : re-ancrage si changement de plage,
puis les 50 submitOrder en LOT, puis settle.

Prix grid (papier, section 6.2, tarif francais) :
  - feed-in  (lambda_low)  = 8.86  c€/kWh, constant toute la journee
  - retail   (lambda_high) = 21.46 en HEURES PLEINES, 16.96 en HEURES CREUSES
  - heures pleines : 8h-12h et 13h-20h  (t in [32,48) U [52,80), pas de 15 min)
Le re-ancrage n'est appele qu'aux TRANSITIONS de plage (pas a chaque session).

Deux modes :
  uv run python orchestrator_besu.py --t 48    # UNE session (chronometrer)
  uv run python orchestrator_besu.py --run     # LA journee, delai cible entre sessions
"""

import sys
import json
import time
import argparse
from pathlib import Path
from web3 import Web3
import besu_common as bc

DELAI_CIBLE = 15  # secondes entre deux debuts de session (cible)

# --- prix grid (echelle 1e18) ---
LAMBDA_LOW       = 8_860_000_000_000_000_000     # feed-in, constant
LAMBDA_HIGH_PEAK = 21_460_000_000_000_000_000    # retail heures pleines
LAMBDA_HIGH_OFF  = 16_960_000_000_000_000_000    # retail heures creuses

ROOT = Path(__file__).resolve().parent
market    = bc.contract("Market", bc.dep["Market"])
prosumers = json.loads((ROOT / "prosumers_nice.json").read_text())   # {id: address}
sessions  = json.loads((ROOT / "netputs_nice.json").read_text())     # {t: {id: netput}}


def is_peak(t: int) -> bool:
    """Heures pleines : 8h-12h (t in [32,48)) et 13h-20h (t in [52,80)). 96 tranches de 15 min."""
    return (32 <= t < 48) or (52 <= t < 80)


def grid_high_for(t: int) -> int:
    """lambda_high selon la plage horaire (lambda_low est constant)."""
    return LAMBDA_HIGH_PEAK if is_peak(t) else LAMBDA_HIGH_OFF


def submit_and_settle(t: str):
    """Une session : submit tous les ordres EN LOT, puis settle."""
    netputs = sessions[t]
    funcs = []
    for pid, netput in netputs.items():
        addr = Web3.to_checksum_address(prosumers[pid])
        funcs.append(market.functions.submitOrder(addr, int(netput)))
    bc.send_batch(funcs, bc.operator)
    bc.send(market.functions.settle(), bc.operator)


def play_one(t: str, current_high=None):
    """
    Joue une session au pas de temps t. Re-ancre lambda_high si la plage a change
    (compare a current_high). Renvoie le lambda_high effectif de cette session.
    """
    ti = int(t)
    target_high = grid_high_for(ti)
    plage = "PLEINE" if is_peak(ti) else "creuse"

    # re-ancrage seulement si la plage a change depuis la session precedente
    if current_high != target_high:
        bc.send(market.functions.setGridPrices(LAMBDA_LOW, target_high), bc.operator)
        print(f"[t={t}] re-ancrage grid -> heures {plage} (lambda_high={target_high/1e18:.2f})")

    print(f"[t={t}] ({plage}) {len(sessions[t])} ordres en lot...", end=" ", flush=True)
    submit_and_settle(t)
    print("regle")
    return target_high


def run_day():
    timesteps = sorted(sessions.keys(), key=int)
    print(f"Journee : {len(timesteps)} sessions (t={timesteps[0]}..{timesteps[-1]}), delai cible {DELAI_CIBLE}s\n")
    current_high = None
    for k, t in enumerate(timesteps):
        start = time.time()
        current_high = play_one(t, current_high)
        if k < len(timesteps) - 1:
            reste = DELAI_CIBLE - (time.time() - start)
            if reste > 0:
                time.sleep(reste)
            else:
                print(f"  (session en {time.time()-start:.0f}s > {DELAI_CIBLE}s : on enchaine)")
    print("\nJournee terminee.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--t", type=str, help="jouer UNE session (ce pas de temps)")
    ap.add_argument("--run", action="store_true", help="jouer toute la journee")
    args = ap.parse_args()

    if args.run:
        run_day()
    elif args.t is not None:
        # une session isolee : on force le re-ancrage a la plage de ce pas de temps
        play_one(args.t, current_high=None)
    else:
        print("Usage : --t <pas> (une session) ou --run (la journee)")
