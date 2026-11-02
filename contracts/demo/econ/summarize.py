# Prints the tables of the strategic study (multiple starts, stability, fine-grid check) in plain text
# and as LaTeX rows. Reads out/planner.json, out/nash_<rule>*.json, out/ms, out/stab and out/cert; writes nothing.
# Run from contracts/: python demo/econ/summarize.py
import json

import numpy as np

from common import HERE

OUT = HERE / "out"  # committed results
RULES = ("mmr", "sdr", "hyperbolic")
LABEL = {"mmr": "MMR", "sdr": "SDR", "hyperbolic": "Hyperbolic"}
TOL = 0.01  # two bills closer than one cent count as the same equilibrium

planner = json.loads((OUT / "planner.json").read_text())
c_star = planner["community_bill"]  # planner bill
c0 = planner["solo_total"]  # everyone optimising alone against the grid


def eff(c):
    # share of the planner's gain captured by a bill c
    return (c0 - c) / (c0 - c_star)


def load(pattern):
    return [json.loads(f.read_text()) | {"file": f.stem} for f in sorted(OUT.glob(pattern))]  # runs matching pattern, with their file name


def net(run):
    return np.array([np.array(s["sell_kw"]) - np.array(s["buy_kw"]) for s in run["schedules"].values()])  # households x sessions, kW


lines_ms, lines_stab, lines_cert = [], [], []  # LaTeX rows of the three tables
print(f"planner {c_star:.2f} USD, alone {c0:.2f} USD, planner gain {c0 - c_star:.2f} USD")
print(f"upper bound on the price of anarchy from individual rationality: {c0 / c_star:.3f}\n")

# ---------- multiple starts ----------
print("MULTIPLE STARTS")
for rule in RULES:
    runs = load(f"ms/{rule}_*.json")
    if not runs:
        continue
    bills = np.array([r["community_bill"] for r in runs])
    eps = np.array([r["epsilon_usd"] for r in runs])
    conv = sum(r["converged"] for r in runs)  # runs where a pass moved nobody
    distinct = len(np.unique(np.round(bills / TOL)))  # distinct equilibria, by bill
    worst, best = bills.max(), bills.min()
    base = json.loads((OUT / f"nash_{rule}.json").read_text())["community_bill"]  # the paper's equilibrium
    rank = (bills < base - 1e-9).mean() * 100  # share of runs that found a cheaper equilibrium
    print(f"{rule}: {len(runs)} runs, {conv} converged, max eps {eps.max():.5f} USD, "
          f"bills {best:.2f} to {worst:.2f} (median {np.median(bills):.2f}), {distinct} distinct, "
          f"empirical PoA {worst / c_star:.3f}, PoS {best / c_star:.3f}, "
          f"efficiency {eff(worst) * 100:.1f} to {eff(best) * 100:.1f}%, "
          f"paper's equilibrium ({base:.2f}) beaten by {rank:.0f}% of runs")
    lines_ms.append(f"{LABEL[rule]} & {len(runs)} & {conv} & {eps.max():.5f} & {best:.2f} & {worst:.2f} & "
                    f"{distinct} & {worst / c_star:.3f} & {eff(worst) * 100:.1f} to {eff(best) * 100:.1f} \\\\")

# ---------- stability ----------
print("\nSTABILITY")
for rule in RULES:
    runs = load(f"stab/{rule}_*.json")
    if not runs:
        continue
    base = json.loads((OUT / f"nash_{rule}.json").read_text())
    q0 = net(base)  # positions before the kick
    for k in sorted({len(r["perturbed"]) for r in runs}):
        sub = [r for r in runs if len(r["perturbed"]) == k]
        dbill = np.array([r["community_bill"] - base["community_bill"] for r in sub])
        dist = np.array([np.abs(net(r) - q0).max() for r in sub])  # largest change of a net position, kW
        back = int((np.abs(dbill) <= TOL).sum())  # runs back to the same bill
        print(f"{rule}, {k} household(s) kicked: {len(sub)} runs, {back} back to the same bill, "
              f"max |change of bill| {np.abs(dbill).max():.3f} USD, median largest position change {np.median(dist):.2f} kW")
        lines_stab.append(f"{LABEL[rule]} & {k} & {len(sub)} & {back} & {np.abs(dbill).max():.3f} & "
                          f"{np.median(dist):.2f} \\\\")

# ---------- fine-grid check ----------
print("\nFINE-GRID CHECK")
for rule in RULES:
    for name in (f"nash_{rule}", f"nash_{rule}_from_planner"):
        base_f = OUT / f"{name}.json"
        # only cert/<name>_<points>.json, not cert/<name>_from_planner_<points>.json
        certs = [c for c in load(f"cert/{name}_*.json") if c["file"][len(name) + 1:].isdigit()]
        if not base_f.exists() or not certs:
            continue
        base = json.loads(base_f.read_text())
        for c in certs:
            print(f"{name}: eps with {base['points']} points {base['epsilon_usd']:.5f} USD, "
                  f"with {c['points']} points {c['epsilon_usd']:.5f} USD")
            lines_cert.append(f"{LABEL[rule]} & {'planner' if 'planner' in name else 'grid alone'} & "
                              f"{base['epsilon_usd']:.5f} & {c['epsilon_usd']:.5f} \\\\")

print("\n% LaTeX rows: rule & runs & converged & max eps & best & worst & distinct & empirical PoA & efficiency (%)")
print("\n".join(lines_ms))
print("\n% LaTeX rows: rule & households kicked & runs & back to same bill & max |change| (USD) & median position change (kW)")
print("\n".join(lines_stab))
print("\n% LaTeX rows: rule & start & eps (points of the run) & eps (fine grid)")
print("\n".join(lines_cert))
