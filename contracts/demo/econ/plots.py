# Figures of the planner and Nash section: price bands, gains, battery, net positions, consumption and grid exchange.
# Reads out/solo.json, out/planner.json and out/nash_<rule>.json; writes figures/fig_eq_*.pdf.
# Run from contracts/: python demo/econ/plots.py [--rule mmr] [--out DIR]
import argparse
import json

import matplotlib
matplotlib.use("Agg")  # no window, just save the files
import matplotlib.pyplot as plt
import numpy as np

from common import HERE, Data, session_prices

ap = argparse.ArgumentParser()
ap.add_argument("--rule", choices=("mmr", "sdr", "hyperbolic"), default="mmr")  # rule for the profile figures
ap.add_argument("--out", default=str(HERE / "figures"))  # output folder
args = ap.parse_args()

RULES = ("mmr", "sdr", "hyperbolic")
LABEL = {"mmr": "Mid-market rate", "sdr": "Supply-demand ratio", "hyperbolic": "Hyperbolic"}
OUT = HERE / "out"
# figures folder
FIG = HERE.joinpath("figures") if args.out == str(HERE / "figures") else __import__("pathlib").Path(args.out)
FIG.mkdir(exist_ok=True)

data = Data()
T, dt, days = data.T, data.dt, data.cfg["days"]
names = data.names
hours = np.arange(96) / 4  # x axis, hour of the day
solo = json.loads((OUT / "solo.json").read_text())  # bills alone
planner = json.loads((OUT / "planner.json").read_text())  # planner bills and schedules
# equilibria found from solo
nash = {r: json.loads((OUT / f"nash_{r}.json").read_text()) for r in RULES if (OUT / f"nash_{r}.json").exists()}
pv = [n for n in names if data.hh[n]["omega"].sum() > 0]  # households with photovoltaics
nopv = [n for n in names if n not in pv]


def arr(run, n, key):
    # one series of one household from a json run, as a numpy array
    return np.array(run["schedules"][n][key])


def by_hour(x):
    # (..., T) -> (..., days, 96), to take quantiles over days for each quarter hour
    return x.reshape(*x.shape[:-1], days, 96)


def band(ax, x, color, label):
    # median line + 25-75 and 5-95 bands over the first axis
    ax.fill_between(hours, np.quantile(x, 0.05, axis=0), np.quantile(x, 0.95, axis=0), color=color, alpha=0.15, lw=0)
    ax.fill_between(hours, np.quantile(x, 0.25, axis=0), np.quantile(x, 0.75, axis=0), color=color, alpha=0.35, lw=0)
    ax.plot(hours, np.median(x, axis=0), color=color, lw=1.6, label=label)


def hour_axis(ax):
    # common x axis: 0 to 24 h
    ax.set_xlim(0, 24)
    ax.set_xticks(range(0, 25, 4))
    ax.set_xlabel("hour of the day")
    ax.grid(alpha=0.3)


# 1) price bands at the Nash equilibrium of each rule
fig, axes = plt.subplots(1, len(nash), figsize=(4.2 * len(nash), 3.4), sharey=True, squeeze=False)
for ax, (rule, run) in zip(axes[0], nash.items()):
    q = np.array([arr(run, n, "sell_kw") - arr(run, n, "buy_kw") for n in names])
    S, D = np.clip(q, 0, None).sum(0), np.clip(-q, 0, None).sum(0)  # aggregates of every session
    r, c, _ = session_prices(S, D, data.low, data.high, rule)
    for x, color, lab in ((c, "tab:red", "buyer price $c$"), (r, "tab:green", "seller price $r$")):
        xd = by_hour(x * 100)  # cents per kWh, days x 96
        ax.fill_between(hours, np.quantile(xd, 0.1, axis=0), np.quantile(xd, 0.9, axis=0), color=color, alpha=0.25, lw=0)
        ax.plot(hours, np.median(xd, axis=0), color=color, lw=1.6, label=lab)
    # tariff bounds: the range over the 4 days, so every price stays inside the outer lines
    hi_d = by_hour(data.high * 100)  # retail rate, days x 96
    lo_d = by_hour(data.low * 100)  # feed-in rate, days x 96
    ax.fill_between(hours, hi_d.min(0), hi_d.max(0), color="0.5", alpha=0.2, lw=0)  # retail range over days
    ax.fill_between(hours, lo_d.min(0), lo_d.max(0), color="0.5", alpha=0.2, lw=0)  # feed-in range over days
    ax.plot(hours, hi_d.max(0), "k--", lw=1, label="highest retail rate")  # nobody pays more than this
    ax.plot(hours, lo_d.min(0), "k:", lw=1, label="lowest feed-in rate")  # nobody receives less than this
    ax.set_title(LABEL[rule])
    hour_axis(ax)
axes[0][0].set_ylabel("price (c/kWh)")
axes[0][0].legend(fontsize=8, loc="upper left")
fig.tight_layout()
fig.savefig(FIG / "fig_eq_prices.pdf")
plt.close(fig)

# 2) gains of each household and bill of the community
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 3.6), gridspec_kw={"width_ratios": [1.6, 1]})
x = np.arange(len(names))
w = 0.8 / max(1, len(nash))  # bar width, one bar per rule
for j, (rule, run) in enumerate(nash.items()):
    gain = [solo["bills"][n]["solo"] - run["payments"][n] for n in names]  # gain over optimising alone
    ax1.bar(x + (j - (len(nash) - 1) / 2) * w, gain, w, label=LABEL[rule])
ax1.set_xticks(x)
ax1.set_xticklabels([str(i + 1) for i in range(len(names))])  # numbering of the paper's tables
ax1.set_xlabel("household")
ax1.set_ylabel("gain over optimising alone (USD)")
ax1.legend(fontsize=8)
ax1.grid(axis="y", alpha=0.3)
bills = {"Recorded\ncurves": planner["raw_total"], "Alone,\noptimised": planner["solo_total"]}
bills.update({f"Nash\n{r.upper() if r != 'hyperbolic' else 'hyp.'}": run["community_bill"] for r, run in nash.items()})
bills["Planner"] = planner["community_bill"]
ax2.bar(range(len(bills)), list(bills.values()), color=["0.6", "0.4"] + ["tab:blue"] * len(nash) + ["tab:green"])
ax2.set_xticks(range(len(bills)))
ax2.set_xticklabels(list(bills.keys()), fontsize=8)
ax2.set_ylabel("community bill (USD)")
ax2.grid(axis="y", alpha=0.3)
fig.tight_layout()
fig.savefig(FIG / "fig_eq_gains.pdf")
plt.close(fig)

run = nash[args.rule]  # the rule used for the profile figures


def profile_figure(key_fn, ylabel, fname):
    # bands over households and days, PV households left, others right
    fig, axes = plt.subplots(1, 2, figsize=(10, 3.4), sharey=True)
    for ax, group, title in ((axes[0], pv, "households with photovoltaics"), (axes[1], nopv, "households without")):
        if not group:
            ax.set_visible(False)
            continue
        x = np.concatenate([by_hour(key_fn(n)) for n in group])  # (households x days) x 96
        for row in x:
            ax.scatter(hours, row, s=2, color="0.5", alpha=0.3)  # individual days, as dots
        band(ax, x, "tab:blue", "median")
        ax.axhline(0, color="k", lw=0.6)
        ax.set_title(title)
        hour_axis(ax)
    axes[0].set_ylabel(ylabel)
    fig.tight_layout()
    fig.savefig(FIG / fname)
    plt.close(fig)


# 3) battery, + = charging
profile_figure(lambda n: arr(run, n, "batt_kw"), "battery power (kW), charging > 0", f"fig_eq_battery_{args.rule}.pdf")
# 4) net trade, + = selling
profile_figure(lambda n: arr(run, n, "sell_kw") - arr(run, n, "buy_kw"), "net position (kW), selling > 0",
               f"fig_eq_net_{args.rule}.pdf")

# 5) community consumption by hour, base / flexible energy / cycles, with the retail rate
base = by_hour(sum(data.hh[n]["base"] for n in names)).mean(0)  # mean over days, kW
flex = by_hour(sum(arr(run, n, "flex_kw") for n in names)).mean(0)
cyc = by_hour(sum(arr(run, n, "cycle_kw") for n in names)).mean(0)
fig, ax = plt.subplots(figsize=(8, 3.4))
ax.bar(hours, base, width=0.25, align="edge", color="peachpuff", label="inflexible")
ax.bar(hours, flex, width=0.25, align="edge", bottom=base, color="tab:green", label="water heating and pumps")
ax.bar(hours, cyc, width=0.25, align="edge", bottom=base + flex, color="tab:blue", label="cycles")
ax.plot(hours + 0.125, base + flex + cyc, color="darkgreen", lw=1.2, label="total")
ax.set_ylabel("community consumption (kW)")
hour_axis(ax)
ax2 = ax.twinx()
ax2.plot(hours + 0.125, np.median(by_hour(data.high * 100), axis=0), "--", color="0.4", lw=1)
ax2.set_ylabel("retail rate (c/kWh)", color="0.4")
ax.legend(fontsize=8, loc="upper left")
fig.tight_layout()
fig.savefig(FIG / f"fig_eq_consumption_{args.rule}.pdf")
plt.close(fig)

# 6) exchanges of the community with the grid, Nash against planner
fig, axes = plt.subplots(1, 2, figsize=(10, 3.4), sharey=True)
for ax, (title, src) in zip(axes, ((f"Nash, {LABEL[args.rule].lower()}", run), ("Social planner", planner))):
    q = sum(arr(src, n, "sell_kw") - arr(src, n, "buy_kw") for n in names)  # community net position
    exp_ = by_hour(np.clip(q, 0, None)).mean(0)  # exported to the grid
    imp_ = by_hour(np.clip(-q, 0, None)).mean(0)  # imported from the grid
    ax.bar(hours, exp_, width=0.25, align="edge", color="tab:green", label="sold to the grid")
    ax.bar(hours, -imp_, width=0.25, align="edge", color="tab:red", label="bought from the grid")
    ax.plot(hours + 0.125, exp_ - imp_, color="tab:blue", lw=1.2, label="net")
    ax.axhline(0, color="k", lw=0.6)
    ax.set_title(title)
    hour_axis(ax)
axes[0].set_ylabel("community exchange with the grid (kW)")
axes[0].legend(fontsize=8, loc="lower left")
fig.tight_layout()
fig.savefig(FIG / f"fig_eq_grid_{args.rule}.pdf")
plt.close(fig)

print(f"figures written to {FIG}")
