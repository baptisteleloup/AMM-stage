# figures for the mixed-strategy equilibria, reads out/mixed_<rule>.json
import argparse
import json
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # demo/econ, where common.py lives
from common import HERE, Data, session_prices  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--rule", choices=("mmr", "sdr", "hyperbolic"), default="sdr")  # rule for the battery figure
args = ap.parse_args()

RULES = ("mmr", "sdr", "hyperbolic")
LABEL = {"mmr": "Mid-market rate", "sdr": "Supply-demand ratio", "hyperbolic": "Hyperbolic"}
OUT = HERE / "out"  # solo.json and planner.json of the paper
EXT = Path(__file__).resolve().parent  # demo/econ/extensions
FIG = EXT / "figures"
FIG.mkdir(exist_ok=True)

data = Data()
names = data.names
N, days = len(names), data.cfg["days"]
hours = np.arange(96) / 4
mixed = {r: json.loads((EXT / "out" / f"mixed_{r}.json").read_text()) for r in RULES if (EXT / "out" / f"mixed_{r}.json").exists()}
solo = json.loads((OUT / "solo.json").read_text())
planner = json.loads((OUT / "planner.json").read_text())
pv = [i for i, n in enumerate(names) if data.hh[n]["omega"].sum() > 0]


def drawn_series(run, key):
    # value of one series for every draw and household: draws x households x T
    picks = np.array(run["draws"])
    banks = [[np.array(s[key]) for s in run["banks"][n]] for n in names]
    return np.array([[banks[i][picks[j, i]] for i in range(N)] for j in range(len(picks))])


def hour_axis(ax):
    ax.set_xlim(0, 24)
    ax.set_xticks(range(0, 25, 4))
    ax.set_xlabel("hour of the day")
    ax.grid(alpha=0.3)


# 1) probability of each schedule in each household's bank, one panel per rule
fig, axes = plt.subplots(1, len(mixed), figsize=(4.2 * len(mixed), 3.2), sharey=True, squeeze=False)
for ax, (rule, run) in zip(axes[0], mixed.items()):
    for i, n in enumerate(names):
        bottom = 0.0
        for k, p in enumerate(run["sigma"][n]):
            ax.bar(i, p, bottom=bottom, color=plt.cm.tab10(k % 10), edgecolor="white", lw=0.5)  # one color per schedule
            bottom += p
    ax.set_xticks(range(N))
    ax.set_xticklabels([str(i + 1) for i in range(N)])
    ax.set_xlabel("household")
    ax.set_title(LABEL[rule])
axes[0][0].set_ylabel("probability of each schedule")
fig.tight_layout()
fig.savefig(FIG / "fig_mixed_sigma.pdf")
plt.close(fig)

# 2) distribution of the community bill over draws, with the reference bills
fig, axes = plt.subplots(1, len(mixed), figsize=(4.2 * len(mixed), 3.2), sharey=True, squeeze=False)
for ax, (rule, run) in zip(axes[0], mixed.items()):
    total = np.array(run["draw_bills"]).sum(1)
    ax.hist(total, bins=30, color="tab:blue", alpha=0.7)
    ax.axvline(planner["solo_total"], color="0.4", ls="--", label="alone, optimised")
    ax.axvline(planner["community_bill"], color="tab:green", ls="--", label="planner")
    ax.axvline(total.mean(), color="k", label="expected")
    ax.set_title(LABEL[rule])
    ax.set_xlabel("community bill (USD)")
axes[0][0].set_ylabel("number of draws")
axes[0][0].legend(fontsize=8)
fig.tight_layout()
fig.savefig(FIG / "fig_mixed_community_bill.pdf")
plt.close(fig)

# 3) distribution of each household's gain over draws, one panel per rule
fig, axes = plt.subplots(1, len(mixed), figsize=(4.2 * len(mixed), 3.2), sharey=True, squeeze=False)
for ax, (rule, run) in zip(axes[0], mixed.items()):
    gains = np.array([solo["bills"][n]["solo"] for n in names])[None, :] - np.array(run["draw_bills"])
    ax.boxplot([gains[:, i] for i in range(N)], whis=(5, 95), showfliers=False)
    ax.axhline(0, color="k", lw=0.6)
    ax.set_xticklabels([str(i + 1) for i in range(N)])
    ax.set_xlabel("household")
    ax.set_title(LABEL[rule])
    ax.grid(axis="y", alpha=0.3)
axes[0][0].set_ylabel("gain over optimising alone (USD)")
fig.tight_layout()
fig.savefig(FIG / "fig_mixed_gains.pdf")
plt.close(fig)

# 4) price bands over draws and days (like Fig. 19 of the theory paper)
fig, axes = plt.subplots(1, len(mixed), figsize=(4.2 * len(mixed), 3.4), sharey=True, squeeze=False)
for ax, (rule, run) in zip(axes[0], mixed.items()):
    q = drawn_series(run, "sell_kw") - drawn_series(run, "buy_kw")  # draws x households x T
    S, D = np.clip(q, 0, None).sum(1), np.clip(-q, 0, None).sum(1)
    lo = np.broadcast_to(data.low, S.shape)
    hi = np.broadcast_to(data.high, S.shape)
    r, c, _ = session_prices(S, D, lo, hi, rule)
    for x, color, lab in ((c, "tab:red", "buyer price $c$"), (r, "tab:green", "seller price $r$")):
        xd = (x * 100).reshape(-1, days, 96).reshape(-1, 96)  # (draws x days) x 96, cents per kWh
        ax.fill_between(hours, np.quantile(xd, 0.1, axis=0), np.quantile(xd, 0.9, axis=0), color=color, alpha=0.25, lw=0)
        ax.plot(hours, np.median(xd, axis=0), color=color, lw=1.6, label=lab)
    ax.plot(hours, np.median(data.high.reshape(days, 96) * 100, axis=0), "k--", lw=1, label="retail rate")
    ax.plot(hours, np.median(data.low.reshape(days, 96) * 100, axis=0), "k:", lw=1, label="feed-in rate")
    ax.set_title(LABEL[rule])
    hour_axis(ax)
axes[0][0].set_ylabel("price (c/kWh)")
axes[0][0].legend(fontsize=8, loc="upper left")
fig.tight_layout()
fig.savefig(FIG / "fig_mixed_prices.pdf")
plt.close(fig)

# 5) battery power over draws, days and households, PV vs not (like Fig. 23)
run = mixed[args.rule]
batt = drawn_series(run, "batt_kw")  # draws x households x T
fig, axes = plt.subplots(1, 2, figsize=(10, 3.4), sharey=True)
for ax, group, title in ((axes[0], pv, "households with photovoltaics"),
                         (axes[1], [i for i in range(N) if i not in pv], "households without")):
    if not group:
        ax.set_visible(False)
        continue
    x = batt[:, group, :].reshape(-1, days, 96).reshape(-1, 96)
    ax.fill_between(hours, np.quantile(x, 0.05, axis=0), np.quantile(x, 0.95, axis=0), color="tab:blue", alpha=0.15, lw=0)
    ax.fill_between(hours, np.quantile(x, 0.25, axis=0), np.quantile(x, 0.75, axis=0), color="tab:blue", alpha=0.35, lw=0)
    ax.plot(hours, np.median(x, axis=0), color="tab:blue", lw=1.6)
    ax.axhline(0, color="k", lw=0.6)
    ax.set_title(title)
    hour_axis(ax)
axes[0].set_ylabel("battery power (kW), charging > 0")
fig.tight_layout()
fig.savefig(FIG / f"fig_mixed_battery_{args.rule}.pdf")
plt.close(fig)

print(f"figures written to {FIG}")
