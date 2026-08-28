#!/usr/bin/env python3
"""Results report for the ResStock demo.

Reads demo/data/netputs_resstock.json and demo/data/prices.json and writes a
PDF with tables and charts: market volumes, prices, community gains and
individual gains, all measured against the status quo in which every kWh is
traded with the grid alone (exports paid the wholesale price, imports paid
the retail price).

Prices per session follow src/Pricing.sol exactly:
    rho = (low + high) / 2
    c   = rho + (high - rho) * max(0, 1 - S/D)     price paid by buyers
    r   = rho - (rho - low)  * max(0, 1 - D/S)     price received by sellers
with S and D the community aggregates of the session. The identity
r*S + (high - c)*D - low*S = (high - low) * min(S, D) makes the community
gain equal to the tariff spread times the locally matched volume.

This file lives in demo/sim/ and resolves its defaults relative to itself,
so it runs from anywhere:
    python3 demo/sim/report_results.py
    python3 demo/sim/report_results.py --out somewhere/else.pdf
"""

import argparse
import json
import math
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

SOLD = "#c08214"
BOUGHT = "#3b5ba9"
MATCHED = "#2e7d5b"
GAIN = "#2e7d5b"
GRID = "#9a9a9a"
INK = "#222222"

PAGE = (11.69, 8.27)


def load(netputs_path, prices_path):
    with open(netputs_path) as f:
        net = json.load(f)
    with open(prices_path) as f:
        feed = json.load(f)

    T = net["sessions"]
    n_days = net["days"]
    names = list(net["profiles"].keys())
    n = len(names)

    sell = np.zeros((n, n_days, T))
    buy = np.zeros((n, n_days, T))
    for i, name in enumerate(names):
        prof = net["profiles"][name]
        for d in range(n_days):
            arr = np.asarray(prof[str(d)], dtype=float)
            sell[i, d, :] = arr[:, 0] / 1000.0
            buy[i, d, :] = arr[:, 1] / 1000.0

    dates = [feed["days"][d % len(feed["days"])] for d in range(n_days)]
    low = np.array([feed["prices"][dt]["low"] for dt in dates])
    high = np.array([feed["prices"][dt]["high"] for dt in dates])

    return names, sell, buy, dates, low, high, feed


def session_prices(S, D, low, high):
    rho = (low + high) / 2.0
    ratio_sd = np.divide(S, D, out=np.zeros_like(S), where=D > 0)
    ratio_ds = np.divide(D, S, out=np.zeros_like(D), where=S > 0)
    c = rho + (high - rho) * np.clip(1.0 - ratio_sd, 0.0, None)
    r = rho - (rho - low) * np.clip(1.0 - ratio_ds, 0.0, None)
    return r, c, rho


def fmt(x, dec=2):
    return f"{x:,.{dec}f}".replace(",", " ")


def table_page(pdf, df, title, subtitle="", col_w=None, dec=None):
    fig, ax = plt.subplots(figsize=PAGE)
    ax.axis("off")
    ax.set_title(title, fontsize=15, loc="left", pad=18, color=INK)
    if subtitle:
        import textwrap
        ax.text(0, 1.015, textwrap.fill(subtitle, 150), transform=ax.transAxes,
                fontsize=9.5, color="#555555", va="bottom")
    show = df.copy()
    for col in show.columns:
        if pd.api.types.is_float_dtype(show[col]):
            d = 2 if dec is None else dec.get(col, 2)
            show[col] = show[col].map(lambda v: fmt(v, d))
    tbl = ax.table(cellText=show.values, colLabels=show.columns,
                   rowLabels=show.index, loc="upper center",
                   cellLoc="right", rowLoc="left")
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(9.5)
    tbl.auto_set_column_width(col=list(range(len(show.columns))))
    tbl.scale(1.0, 1.55)
    for (row, col), cell in tbl.get_celld().items():
        cell.set_edgecolor("#dddddd")
        if row == 0:
            cell.set_text_props(weight="bold", color=INK)
            cell.set_facecolor("#f2f0ea")
        if col == -1:
            cell.set_text_props(color=INK)
    pdf.savefig(fig)
    plt.close(fig)


def main():
    demo = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description="Results PDF for the ResStock demo")
    ap.add_argument("--netputs", default=str(demo / "data" / "netputs_resstock.json"))
    ap.add_argument("--prices", default=str(demo / "data" / "prices.json"))
    ap.add_argument("--out", default=str(demo / "results_resstock.pdf"))
    ap.add_argument("--figdir", default=None,
                    help="also export each figure as a standalone PDF plus two LaTeX "
                         "tables (booktabs) into this folder, sized for a report")
    args = ap.parse_args()

    names, sell, buy, dates, low, high, feed = load(args.netputs, args.prices)
    n, n_days, T = sell.shape
    slots = [f"slot {i + 1}" for i in range(n)]

    S = sell.sum(axis=0)
    D = buy.sum(axis=0)
    matched = np.minimum(S, D)
    spread = high - low
    r, c, rho = session_prices(S, D, low, high)

    amm = r[None, :, :] * sell - c[None, :, :] * buy
    base = low[None, :, :] * sell - high[None, :, :] * buy
    gain = amm - base
    gain_sell = (r - low)[None, :, :] * sell
    gain_buy = (high - c)[None, :, :] * buy

    community_gain = gain.sum(axis=0)
    check = np.abs(community_gain - spread * matched).max()
    assert check < 1e-9, f"settlement identity violated by {check}"

    flat_S = S.reshape(-1)
    flat_D = D.reshape(-1)
    flat_matched = matched.reshape(-1)
    flat_gain = community_gain.reshape(-1)
    x = np.arange(n_days * T)

    day_labels = [f"{dt} ({pd.Timestamp(dt).day_name()[:3]})" for dt in dates]
    hours = np.array([t * 0.25 for t in range(T)])

    sold_day = sell.sum(axis=(0, 2))
    bought_day = buy.sum(axis=(0, 2))
    matched_day = matched.sum(axis=1)
    gain_day = community_gain.sum(axis=1)

    w_r = np.divide((r * S).sum(), S.sum()) if S.sum() > 0 else 0.0
    w_c = np.divide((c * D).sum(), D.sum()) if D.sum() > 0 else 0.0
    w_low = (low * S).sum() / S.sum() if S.sum() > 0 else 0.0
    w_high = (high * D).sum() / D.sum() if D.sum() > 0 else 0.0

    per_agent = pd.DataFrame(index=slots)
    per_agent["sold kWh"] = sell.sum(axis=(1, 2))
    per_agent["bought kWh"] = buy.sum(axis=(1, 2))
    per_agent["grid only EUR"] = base.sum(axis=(1, 2))
    per_agent["with AMM EUR"] = amm.sum(axis=(1, 2))
    per_agent["gain EUR"] = gain.sum(axis=(1, 2))
    per_agent["gain seller side"] = gain_sell.sum(axis=(1, 2))
    per_agent["gain buyer side"] = gain_buy.sum(axis=(1, 2))
    traded = per_agent["sold kWh"] + per_agent["bought kWh"]
    per_agent["gain c/kWh traded"] = 100 * per_agent["gain EUR"] / traded.replace(0, np.nan)
    per_agent["share of gain %"] = 100 * per_agent["gain EUR"] / per_agent["gain EUR"].sum()

    per_day = pd.DataFrame(index=day_labels)
    per_day["offered kWh"] = sold_day
    per_day["demanded kWh"] = bought_day
    per_day["matched kWh"] = matched_day
    per_day["covered %"] = 100 * matched_day / bought_day
    per_day["absorbed %"] = 100 * matched_day / sold_day
    per_day["gain EUR"] = gain_day

    rng = np.random.default_rng(0)
    sizes = np.arange(2, n + 1)
    sub_mean = np.zeros(len(sizes))
    sub_std = np.zeros(len(sizes))
    adder = float(spread.mean())
    for j, Nsub in enumerate(sizes):
        draws = min(2000, 10 * math.comb(n, int(Nsub))) if Nsub < n else 1
        vals = np.empty(draws)
        for k in range(draws):
            idx = rng.choice(n, size=int(Nsub), replace=False)
            m = np.minimum(sell[idx].sum(axis=0), buy[idx].sum(axis=0)).sum()
            vals[k] = adder * m / Nsub / n_days
        sub_mean[j] = vals.mean()
        sub_std[j] = vals.std()

    with PdfPages(args.out) as pdf:

        fig, ax = plt.subplots(figsize=PAGE)
        ax.axis("off")
        y = 0.95
        ax.text(0.02, y, "ResStock demo, market results", fontsize=22, color=INK, weight="bold")
        y -= 0.07
        ax.text(0.02, y, "Local energy sharing AMM on measured building data and real day-ahead prices",
                fontsize=12, color="#555555")
        y -= 0.09
        lines = [
            ("Community", f"{n} prosumers (5 with rooftop PV, 5 without), single Massachusetts county, ResStock amy2018 release 2"),
            ("Period", f"{n_days} trading days, {dates[0]} to {dates[-1]}, {T} sessions of 15 minutes per day"),
            ("Prices", f"ISO New England day-ahead LMP, zone {feed.get('zone', '?')}, retail = wholesale + {feed.get('delivery_adder', 0)} EUR/kWh delivery adder"),
            ("Status quo", "every kWh traded with the grid alone: exports paid low (wholesale), imports paid high (retail)"),
        ]
        for label, txt in lines:
            ax.text(0.02, y, label, fontsize=10.5, weight="bold", color=INK)
            ax.text(0.17, y, txt, fontsize=10.5, color=INK)
            y -= 0.045
        y -= 0.04
        ax.text(0.02, y, "Headline results", fontsize=14, weight="bold", color=INK)
        y -= 0.055
        heads = [
            f"Community gain over {n_days} days: {fmt(community_gain.sum())} EUR "
            f"({fmt(community_gain.sum() / n_days)} EUR/day), entirely the delivery spread earned on locally matched energy",
            f"Locally matched energy: {fmt(matched.sum(), 1)} kWh of {fmt(D.sum(), 1)} kWh demanded, "
            f"{fmt(100 * matched.sum() / D.sum(), 1)} % of demand served locally "
            f"({fmt(100 * matched.sum() / S.sum(), 1)} % of the surplus absorbed locally)",
            f"Sellers received on average {fmt(100 * w_r, 2)} c/kWh against {fmt(100 * w_low, 2)} wholesale; "
            f"buyers paid {fmt(100 * w_c, 2)} c/kWh against {fmt(100 * w_high, 2)} retail",
            f"Spread high - low = the {fmt(100 * (high - low).mean(), 0)} c/kWh delivery adder in every session, "
            "so the gain is 0.12 EUR per matched kWh and matching volume is the only lever",
        ]
        import textwrap
        for txt in heads:
            wrapped = textwrap.fill(txt, 128)
            ax.text(0.02, y, "\u2022  " + wrapped, fontsize=10.5, color=INK, va="top")
            y -= 0.045 + 0.032 * wrapped.count("\n")
        pdf.savefig(fig)
        plt.close(fig)

        table_page(pdf, per_day, "Daily market summary")

        fig, ax = plt.subplots(figsize=PAGE)
        ax.plot(x, flat_S, color=SOLD, lw=1.1, label="supply offered")
        ax.plot(x, flat_D, color=BOUGHT, lw=1.1, label="demand")
        ax.fill_between(x, 0, flat_matched, color=MATCHED, alpha=0.35, lw=0,
                        label="matched locally")
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.7, ls=":")
        ax.set_ylabel("kWh per 15 min session")
        ax.set_xlabel(f"session ({n_days} days of {T} sessions)")
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels(day_labels)
        ax.set_title("Community supply, demand and locally matched energy, session by session",
                     loc="left", fontsize=13)
        ax.legend(loc="upper right", frameon=False, fontsize=9)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        fig, axes = plt.subplots(2, 1, figsize=PAGE, sharex=True,
                                 gridspec_kw={"height_ratios": [1.0, 1.6]})
        axes[0].bar(x, flat_gain, width=1.0, color=GAIN, alpha=0.8)
        axes[0].set_ylabel("EUR per session")
        axes[0].set_title("Community gain per session versus the status quo", loc="left", fontsize=12)
        axes[1].plot(x, np.cumsum(flat_gain), color=GAIN, lw=1.6)
        for d in range(1, n_days):
            axes[0].axvline(d * T, color=GRID, lw=0.7, ls=":")
            axes[1].axvline(d * T, color=GRID, lw=0.7, ls=":")
        axes[1].set_ylabel("EUR cumulative")
        axes[1].set_xlabel("session")
        axes[1].set_xticks([d * T + T // 2 for d in range(n_days)])
        axes[1].set_xticklabels(day_labels)
        axes[1].set_title("Cumulative community gain across the run", loc="left", fontsize=12)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        d_star = int(np.argmax(matched_day))
        fig, axes = plt.subplots(2, 1, figsize=PAGE, sharex=True,
                                 gridspec_kw={"height_ratios": [1.5, 1.0]})
        ax = axes[0]
        ax.step(hours, 100 * high[d_star], where="post", color=BOUGHT, lw=1.3, label="high (retail)")
        ax.step(hours, 100 * c[d_star], where="post", color=BOUGHT, lw=1.1, ls="--", label="c (buyers pay)")
        ax.step(hours, 100 * rho[d_star], where="post", color=GRID, lw=1.0, label="mid")
        ax.step(hours, 100 * r[d_star], where="post", color=SOLD, lw=1.1, ls="--", label="r (sellers get)")
        ax.step(hours, 100 * low[d_star], where="post", color=SOLD, lw=1.3, label="low (wholesale)")
        ax.set_ylabel("c/kWh")
        ax.set_title(f"Session prices on {day_labels[d_star]}, the most active day",
                     loc="left", fontsize=13)
        ax.legend(loc="upper left", frameon=False, fontsize=9, ncol=2)
        ax2 = axes[1]
        ax2.bar(hours, S[d_star], width=0.25, color=SOLD, alpha=0.7, label="supply")
        ax2.bar(hours, -D[d_star], width=0.25, color=BOUGHT, alpha=0.7, label="demand")
        ax2.axhline(0, color=INK, lw=0.6)
        ax2.set_ylabel("kWh (demand below)")
        ax2.set_xlabel("hour of day")
        ax2.legend(loc="lower left", frameon=False, fontsize=9)
        ax2.set_title("The side in excess pushes its price toward the grid price of that side",
                      loc="left", fontsize=11)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        table_page(
            pdf, per_agent.drop(columns=["gain seller side", "gain buyer side"]),
            "Individual results over the whole run",
            "Cash flows in EUR, negative = net payment. Gain = with AMM - grid only; "
            "it is non negative for every member in every session.",
            dec={"gain c/kWh traded": 3, "share of gain %": 1},
        )

        fig, ax = plt.subplots(figsize=PAGE)
        cmap = plt.get_cmap("tab10")
        cum_gain = np.cumsum(gain.reshape(n, -1), axis=1)
        for i in range(n):
            ax.plot(x, cum_gain[i], lw=1.4, color=cmap(i % 10), label=slots[i])
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.7, ls=":")
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels(day_labels)
        ax.set_ylabel("EUR cumulative")
        ax.set_title("Individual gains versus the status quo, cumulative across sessions",
                     loc="left", fontsize=13)
        ax.legend(loc="upper left", frameon=False, fontsize=9, ncol=2)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        fig, ax = plt.subplots(figsize=PAGE)
        cum_amm = np.cumsum(amm.reshape(n, -1), axis=1)
        cum_base = np.cumsum(base.reshape(n, -1), axis=1)
        for i in range(n):
            ax.plot(x, cum_amm[i], lw=1.4, color=cmap(i % 10), label=slots[i])
            ax.plot(x, cum_base[i], lw=0.9, color=cmap(i % 10), alpha=0.45, ls="--")
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.7, ls=":")
        ax.axhline(0, color=INK, lw=0.6)
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels(day_labels)
        ax.set_ylabel("EUR cumulative")
        ax.set_title("Net cash position per member, with the AMM (solid) and grid only (dashed)",
                     loc="left", fontsize=13)
        ax.legend(loc="lower left", frameon=False, fontsize=9, ncol=2)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        fig, ax = plt.subplots(figsize=PAGE)
        gs = per_agent["gain seller side"].values
        gb = per_agent["gain buyer side"].values
        idx = np.arange(n)
        ax.bar(idx, gs, color=SOLD, label="earned selling above wholesale")
        ax.bar(idx, gb, bottom=gs, color=BOUGHT, label="saved buying below retail")
        ax.set_xticks(idx)
        ax.set_xticklabels(slots, rotation=0)
        ax.set_ylabel("EUR over the run")
        ax.set_title("Where each member's gain comes from", loc="left", fontsize=13)
        ax.legend(loc="upper right", frameon=False, fontsize=9)
        for i in idx:
            ax.text(i, gs[i] + gb[i] + 0.02, fmt(gs[i] + gb[i]), ha="center", fontsize=8.5)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        fig, ax = plt.subplots(figsize=PAGE)
        idx = np.arange(n_days)
        w = 0.38
        ax.bar(idx - w / 2, per_day["covered %"], width=w, color=BOUGHT,
               label="share of demand served locally")
        ax.bar(idx + w / 2, per_day["absorbed %"], width=w, color=SOLD,
               label="share of surplus absorbed locally")
        ax.set_xticks(idx)
        ax.set_xticklabels(day_labels)
        ax.set_ylabel("%")
        ax.set_ylim(0, 100)
        ax.set_title("Local coverage per day", loc="left", fontsize=13)
        ax.legend(loc="upper right", frameon=False, fontsize=9)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        fig, ax = plt.subplots(figsize=PAGE)
        ax.errorbar(sizes, 100 * sub_mean, yerr=100 * sub_std, color=GAIN, lw=1.6,
                    marker="o", ms=4, capsize=3)
        ax.set_xlabel("community size (households drawn from the panel)")
        ax.set_ylabel("gain per household, cents per day")
        ax.set_xticks(sizes)
        ax.set_title("Average gain per household by community size, over random sub-communities "
                     "(net positions held fixed, as price-taking makes them composition independent)",
                     loc="left", fontsize=12)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)


    if args.figdir:
        figdir = Path(args.figdir)
        figdir.mkdir(parents=True, exist_ok=True)
        W = 6.3

        def save(fig, name):
            fig.tight_layout()
            fig.savefig(figdir / name)
            plt.close(fig)

        fig, ax = plt.subplots(figsize=(W, 3.2))
        ax.plot(x, flat_S, color=SOLD, lw=0.9, label="supply offered")
        ax.plot(x, flat_D, color=BOUGHT, lw=0.9, label="demand")
        ax.fill_between(x, 0, flat_matched, color=MATCHED, alpha=0.4, lw=0, label="matched locally")
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.6, ls=":")
        ax.set_ylabel("kWh per session")
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels([dt for dt in dates], fontsize=8)
        ax.legend(loc="upper right", frameon=False, fontsize=7)
        save(fig, "fig_sessions.pdf")

        fig, ax = plt.subplots(figsize=(W, 2.9))
        ax.plot(x, np.cumsum(flat_gain), color=GAIN, lw=1.4)
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.6, ls=":")
        ax.set_ylabel("EUR, cumulative")
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels([dt for dt in dates], fontsize=8)
        save(fig, "fig_gain.pdf")

        d_star2 = int(np.argmax(matched_day))
        fig, ax = plt.subplots(figsize=(W, 3.2))
        ax.step(hours, 100 * high[d_star2], where="post", color=BOUGHT, lw=1.1, label="high (retail)")
        ax.step(hours, 100 * c[d_star2], where="post", color=BOUGHT, lw=0.9, ls="--", label="c (buyers pay)")
        ax.step(hours, 100 * rho[d_star2], where="post", color=GRID, lw=0.8, label="mid")
        ax.step(hours, 100 * r[d_star2], where="post", color=SOLD, lw=0.9, ls="--", label="r (sellers get)")
        ax.step(hours, 100 * low[d_star2], where="post", color=SOLD, lw=1.1, label="low (wholesale)")
        ax.set_xlabel("hour of day")
        ax.set_ylabel("c/kWh")
        ax.legend(loc="upper left", frameon=False, fontsize=7, ncol=2)
        save(fig, "fig_prices.pdf")

        fig, ax = plt.subplots(figsize=(W, 3.4))
        cmap2 = plt.get_cmap("tab10")
        cg = np.cumsum(gain.reshape(n, -1), axis=1)
        for i in range(n):
            ax.plot(x, cg[i], lw=1.0, color=cmap2(i % 10), label=slots[i])
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.6, ls=":")
        ax.set_ylabel("EUR, cumulative")
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels([dt for dt in dates], fontsize=8)
        ax.legend(loc="upper left", frameon=False, fontsize=6.5, ncol=2)
        save(fig, "fig_individual.pdf")

        fig, ax = plt.subplots(figsize=(W, 3.4))
        ca = np.cumsum(amm.reshape(n, -1), axis=1)
        cb = np.cumsum(base.reshape(n, -1), axis=1)
        for i in range(n):
            ax.plot(x, ca[i], lw=1.0, color=cmap2(i % 10), label=slots[i])
            ax.plot(x, cb[i], lw=0.7, color=cmap2(i % 10), alpha=0.45, ls="--")
        ax.axhline(0, color=INK, lw=0.5)
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.6, ls=":")
        ax.set_ylabel("EUR, cumulative")
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels([dt for dt in dates], fontsize=8)
        ax.legend(loc="lower left", frameon=False, fontsize=6.5, ncol=2)
        save(fig, "fig_cash.pdf")

        fig, ax = plt.subplots(figsize=(W, 2.9))
        gsv = per_agent["gain seller side"].values
        gbv = per_agent["gain buyer side"].values
        idx2 = np.arange(n)
        ax.bar(idx2, gsv, color=SOLD, label="earned selling above wholesale")
        ax.bar(idx2, gbv, bottom=gsv, color=BOUGHT, label="saved buying below retail")
        ax.set_xticks(idx2)
        ax.set_xticklabels(slots, fontsize=7)
        ax.set_ylabel("EUR over the run")
        ax.legend(loc="upper right", frameon=False, fontsize=7)
        save(fig, "fig_decomposition.pdf")

        fig, ax = plt.subplots(figsize=(W, 2.9))
        ax.errorbar(sizes, 100 * sub_mean, yerr=100 * sub_std, color=GAIN, lw=1.3,
                    marker="o", ms=3.5, capsize=3)
        ax.set_xlabel("community size")
        ax.set_ylabel("gain per household, c/day")
        ax.set_xticks(sizes)
        save(fig, "fig_size.pdf")

        def fr(v, dec=2):
            return f"{v:.{dec}f}".replace(".", ",")

        lines = ["\\begin{tabular}{lrrrrrr}", "\\toprule",
                 "Jour & Offert & Demand\\'e & Appari\\'e & Couverture & Absorption & Gain \\\\",
                 " & (kWh) & (kWh) & (kWh) & (\\%) & (\\%) & (EUR) \\\\",
                 "\\midrule"]
        for i, lab in enumerate(day_labels):
            dt = dates[i]
            lines.append(f"{dt} & {fr(sold_day[i], 1)} & {fr(bought_day[i], 1)} & {fr(matched_day[i], 1)} & "
                         f"{fr(100 * matched_day[i] / bought_day[i], 1)} & {fr(100 * matched_day[i] / sold_day[i], 1)} & "
                         f"{fr(gain_day[i])} \\\\")
        lines += ["\\midrule",
                  f"Total & {fr(sold_day.sum(), 1)} & {fr(bought_day.sum(), 1)} & {fr(matched_day.sum(), 1)} & "
                  f"{fr(100 * matched_day.sum() / bought_day.sum(), 1)} & {fr(100 * matched_day.sum() / sold_day.sum(), 1)} & "
                  f"{fr(gain_day.sum())} \\\\",
                  "\\bottomrule", "\\end{tabular}"]
        (figdir / "table_days.tex").write_text("\n".join(lines), encoding="utf-8")

        lines = ["\\begin{tabular}{lrrrrrr}", "\\toprule",
                 "M\\'enage & Vendu & Achet\\'e & R\\'eseau seul & Avec AMM & Gain & Part du gain \\\\",
                 " & (kWh) & (kWh) & (EUR) & (EUR) & (EUR) & (\\%) \\\\",
                 "\\midrule"]
        tot_g = per_agent["gain EUR"].sum()
        for i, slot in enumerate(slots):
            row = per_agent.iloc[i]
            lines.append(f"{i + 1} & {fr(row['sold kWh'], 1)} & {fr(row['bought kWh'], 1)} & "
                         f"{fr(row['grid only EUR'])} & {fr(row['with AMM EUR'])} & {fr(row['gain EUR'])} & "
                         f"{fr(100 * row['gain EUR'] / tot_g, 1)} \\\\")
        lines += ["\\bottomrule", "\\end{tabular}"]
        (figdir / "table_households.tex").write_text("\n".join(lines), encoding="utf-8")
        print(f"exported figures and tables to {figdir}")

    print(f"wrote {args.out}")
    print(f"community gain: {community_gain.sum():.2f} EUR over {n_days} days, "
          f"{100 * matched.sum() / D.sum():.1f} % of demand served locally")


if __name__ == "__main__":
    main()
