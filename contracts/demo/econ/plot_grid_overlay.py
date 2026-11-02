# community exchange with the grid, Nash equilibrium and social planner on the same axes
# reads out/nash_<rule>.json and out/planner.json, writes figures/fig_eq_grid_overlay_<rule>.pdf
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
ap = argparse.ArgumentParser()
ap.add_argument("--rule", choices=("mmr", "sdr", "hyperbolic"), default="mmr")
ap.add_argument("--out", default=str(HERE / "figures"))
args = ap.parse_args()

LABEL = {"mmr": "mid-market rate", "sdr": "supply-demand ratio", "hyperbolic": "hyperbolic rule"}
OUT = HERE / "out"
FIG = Path(args.out)
FIG.mkdir(exist_ok=True)


def mean_net(run):
    # community net position (kW), positive when it sells to the grid, averaged over days per quarter hour
    sched = run["schedules"]
    q = sum(np.array(s["sell_kw"]) - np.array(s["buy_kw"]) for s in sched.values())
    return q.reshape(-1, 96).mean(axis=0)


nash = mean_net(json.loads((OUT / f"nash_{args.rule}.json").read_text()))
planner = mean_net(json.loads((OUT / "planner.json").read_text()))
edges = np.arange(97) / 4  # quarter-hour edges, so each step covers its session

plt.rcParams.update({"font.size": 8, "axes.labelsize": 8, "xtick.labelsize": 7, "ytick.labelsize": 7})
fig, ax = plt.subplots(figsize=(7.0, 3.0))
for y, color, label in ((nash, "tab:red", f"Nash equilibrium, {LABEL[args.rule]}"),
                        (planner, "tab:blue", "social planner")):
    yy = np.append(y, y[-1])  # repeat the last value so the last step is drawn to 24 h
    ax.fill_between(edges, 0, yy, step="post", color=color, alpha=0.35, lw=0, label=label)
    ax.step(edges, yy, where="post", color=color, lw=0.9)
ax.axhline(0, color="k", lw=0.6)
ax.set_xlim(0, 24)
ax.set_xticks(range(0, 25, 4))
ax.set_xlabel("hour of the day")
ax.set_ylabel("exchange with the grid (kW)\nimports < 0 < exports")
ax.grid(alpha=0.25, lw=0.5)
ax.legend(frameon=False, loc="lower right")
fig.tight_layout()
fig.savefig(FIG / f"fig_eq_grid_overlay_{args.rule}.pdf", bbox_inches="tight", pad_inches=0.02)
print(f"written {FIG / f'fig_eq_grid_overlay_{args.rule}.pdf'}")
