# Figure of the session prices under the three rules side by side, on the most active day.
# Reads --netputs and --prices, writes --out (demo/figures_raw/fig_prices_rules.pdf). Run from contracts/:
#   python3 demo/sim/plot_prices_rules.py --netputs demo/data/netputs_raw.json
import argparse
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))  # to import report_results
from report_results import BOUGHT, GRID, RULES, SOLD, load, session_prices  # noqa: E402

demo = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser()
ap.add_argument("--netputs", default=str(demo / "data" / "netputs_raw.json"))
ap.add_argument("--prices", default=str(demo / "data" / "prices.json"))
ap.add_argument("--out", default=str(demo / "figures_raw" / "fig_prices_rules.pdf"))
args = ap.parse_args()

names, sell, buy, dates, low, high, feed = load(args.netputs, args.prices)
S, D = sell.sum(axis=0), buy.sum(axis=0)  # community aggregates [day, session], kWh
day = int(np.argmax(np.minimum(S, D).sum(axis=1)))  # most active day, as in report_results
T = S.shape[1]
hours = np.arange(T + 1) * 0.25  # one more point so the last step is drawn to 24 h

plt.rcParams.update({"font.size": 8, "axes.labelsize": 8, "xtick.labelsize": 7, "ytick.labelsize": 7})
fig, axes = plt.subplots(1, 3, figsize=(7.0, 3.0), sharey=True)
titles = {"mmr": "Mid-market rate", "sdr": "Supply--demand ratio", "hyperbolic": "Hyperbolic"}  # panel titles


# Draws a per-session series as steps.
def step(ax, y, **kw):
    ax.step(hours, np.append(y, y[-1]), where="post", **kw)


for ax, rule in zip(axes, RULES):
    r, c, rho = session_prices(S, D, low, high, rule)  # same formulas as Pricing.sol
    step(ax, 100 * high[day], color=BOUGHT, lw=1.1, label="retail rate")
    step(ax, 100 * c[day], color=BOUGHT, lw=0.9, ls="--", label="buyer price $c$")
    step(ax, 100 * rho[day], color=GRID, lw=0.8, label="midpoint")
    step(ax, 100 * r[day], color=SOLD, lw=0.9, ls="--", label="seller price $r$")
    step(ax, 100 * low[day], color=SOLD, lw=1.1, label="feed-in rate")
    ax.set_title(titles[rule].replace("--", "–"), fontsize=8)
    ax.set_xlim(0, 24)
    ax.set_xticks([0, 6, 12, 18, 24])
    ax.set_xlabel("hour of day")
    ax.grid(alpha=0.25, lw=0.5)
axes[0].set_ylabel("cents/kWh")  # prices are in currency per kWh, x100
handles, labels = axes[0].get_legend_handles_labels()
fig.tight_layout(rect=(0, 0, 1, 0.92))
# one legend for the three panels
fig.legend(handles, labels, loc="upper center", ncol=5, frameon=False, fontsize=7, bbox_to_anchor=(0.5, 1.0))
Path(args.out).parent.mkdir(parents=True, exist_ok=True)
fig.savefig(args.out, bbox_inches="tight", pad_inches=0.02)  # no white margin around the figure
print(f"written {args.out} (day {dates[day]})")
