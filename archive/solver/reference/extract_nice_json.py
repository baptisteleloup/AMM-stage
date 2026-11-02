"""
Extrait les netputs optimises (Nice) sur PLUSIEURS pas de temps -> JSON indexe.

Genere netputs_nice.json = { "0": {prosumer-i: netput_1e18}, "4": {...}, ... }
Chaque cle = un pas de temps (tranche de 15 min) ; l'orchestrateur les rejoue
en sequence (une session par pas de temps).

netput = plan.s[t] - plan.d[t] (optimise, equilibre), echelle 1e18.

A lancer a la racine du repo clone (la ou est le .pkl), avec les deps installees
(tqdm numpy pandas scipy) UNE fois :
    python3 extract_nice_json.py --step 4 --n 50
Puis copier netputs_nice.json dans contracts/.
"""

import json
import argparse
import pickle
import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pkl", default="NiceData/mpe_simulation_results_Nice.pkl")
    ap.add_argument("--step", type=int, default=4, help="1 pas de temps sur 'step' (4 -> 24 sessions)")
    ap.add_argument("--tmax", type=int, default=96, help="nombre total de tranches (96 = journee)")
    ap.add_argument("--n", type=int, default=50, help="nombre d'agents")
    ap.add_argument("--epoch", type=int, default=0)
    args = ap.parse_args()

    d = pickle.load(open(args.pkl, "rb"))
    plans = d["all_epoch_results"][args.epoch]["plans"]

    timesteps = list(range(0, args.tmax, args.step))
    out = {}
    summary = []

    for t in timesteps:
        session = {}
        for i in range(args.n):
            plan = plans[i]["plan"]
            net = float(np.array(plan.s)[t] - np.array(plan.d)[t])
            session[f"prosumer-{i}"] = int(round(net * 1e18))
        out[str(t)] = session

        supply = sum(v for v in session.values() if v > 0) / 1e18
        demand = -sum(v for v in session.values() if v < 0) / 1e18
        regime = "SURPLUS" if supply > demand else "DEFICIT" if demand > supply else "EQUIL"
        summary.append((t, regime, supply, demand))

    json.dump(out, open("netputs_nice.json", "w"), indent=2)

    print(f"netputs_nice.json genere : {len(timesteps)} sessions (pas de temps {timesteps[0]}..{timesteps[-1]}, step {args.step})")
    print(f"{'t':>4}  {'regime':<8}{'offre':>10}{'demande':>10}")
    for t, regime, s, dem in summary:
        print(f"{t:>4}  {regime:<8}{s:>10.2f}{dem:>10.2f}")


if __name__ == "__main__":
    main()
