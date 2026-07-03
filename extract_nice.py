"""
Extrait les netputs optimises de la simulation d'equilibre Mean-Field du papier
(leoneleo/Automated_Market_Making_for_Energy_Sharing) et genere une library
Solidity NiceData.sol consommable par la simulation Foundry.

Le netput d'un agent i au pas de temps t est net_i(t) = plan.s[t] - plan.d[t],
c.-a-d. la position nette apres optimisation batterie + charge flexible, a
l'equilibre. > 0 : vendeur, < 0 : acheteur.

Usage : placer ce script a la racine du repo cloné, puis :
    python3 extract_nice.py --t 48 --n 50 --out NiceData.sol
"""
import pickle
import argparse
import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pkl", default="NiceData/mpe_simulation_results_Nice.pkl")
    ap.add_argument("--t", type=int, default=48, help="pas de temps 0..95 (48 = midi)")
    ap.add_argument("--n", type=int, default=50, help="nombre d'agents echantillonnes")
    ap.add_argument("--epoch", type=int, default=0)
    ap.add_argument("--out", default="NiceData.sol")
    args = ap.parse_args()

    d = pickle.load(open(args.pkl, "rb"))
    plans = d["all_epoch_results"][args.epoch]["plans"]

    scaled, meta = [], []
    for i in range(args.n):
        p = plans[i]
        plan = p["plan"]
        net = float(np.array(plan.s)[args.t] - np.array(plan.d)[args.t])
        scaled.append(int(round(net * 1e18)))          # echelle fixed-point 1e18
        meta.append(p["category"])

    supply = sum(v for v in scaled if v > 0) / 1e18
    demand = -sum(v for v in scaled if v < 0) / 1e18
    regime = "SURPLUS" if supply > demand else "DEFICIT" if demand > supply else "EQUILIBRE"

    lines = [
        "// SPDX-License-Identifier: MIT",
        "// AUTO-GENERE par extract_nice.py depuis mpe_simulation_results_Nice.pkl",
        f"// pas t={args.t}, {args.n} agents, regime {regime} "
        f"(offre {supply:.2f} kW / demande {demand:.2f} kW)",
        "// netput = plan.s[t] - plan.d[t] (optimise, equilibre), echelle 1e18.",
        "pragma solidity >=0.8.19;",
        "",
        "library NiceData {",
        f"    uint256 internal constant N = {args.n};",
        f"    function netputs() internal pure returns (int256[{args.n}] memory a) {{",
    ]
    for i, v in enumerate(scaled):
        lines.append(f"        a[{i}] = {v};  // {meta[i]}")
    lines += ["    }", "}", ""]

    open(args.out, "w").write("\n".join(lines))
    print(f"{args.out} genere : {args.n} netputs, regime {regime} "
          f"(offre {supply:.2f} / demande {demand:.2f} kW)")


if __name__ == "__main__":
    main()
