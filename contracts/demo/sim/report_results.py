#!/usr/bin/env python3
"""Results report of the fixed-profile demo under one pricing rule.

Reads --netputs and --prices and writes a PDF report (--out, default demo/results_raw_<rule>.pdf)
and, with --figdir, the paper's standalone figures and LaTeX tables. Session prices follow
src/Pricing.sol; gains are measured against trading with the grid alone. Run from contracts/:
    python3 demo/sim/report_results.py --rule mmr --figdir demo/figures_raw_mmr
"""

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

SOLD = "#c08214"  # colours shared with plot_prices_rules.py
BOUGHT = "#3b5ba9"
MATCHED = "#2e7d5b"
GAIN = "#2e7d5b"
GRID = "#9a9a9a"
INK = "#222222"

PAGE = (11.69, 8.27)  # A4 landscape, inches


# Netputs as kWh arrays [member, day, session] and the band of each day.
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
            sell[i, d, :] = arr[:, 0] / 1000.0  # Wh -> kWh
            buy[i, d, :] = arr[:, 1] / 1000.0

    dates = [feed["days"][d % len(feed["days"])] for d in range(n_days)]  # price day of each netput day
    low = np.array([feed["prices"][dt]["low"] for dt in dates])
    high = np.array([feed["prices"][dt]["high"] for dt in dates])

    return names, sell, buy, dates, low, high, feed


RULES = ("mmr", "sdr", "hyperbolic")


def session_prices(S, D, low, high, rule="mmr"):
    """Seller and buyer rates per session under one of the three rules, element-wise."""
    rho = (low + high) / 2.0
    with np.errstate(divide="ignore", invalid="ignore"):
        y = np.where(D > 0, S / np.where(D > 0, D, 1.0), 0.0)  # supply-demand ratio, guarded against D = 0
        if rule == "mmr":
            # share of supply sold to the grid
            u = np.clip(1.0 - np.where(S > 0, D / np.where(S > 0, S, 1.0), 0.0), 0.0, None)
            v = np.clip(1.0 - y, 0.0, None)  # share of demand bought from the grid
            r = rho - (rho - low) * u
            c = rho + (high - rho) * v
        elif rule == "sdr":
            Dd = (high - low) * np.minimum(y, 1.0) + low  # denominator of r in excess demand
            r_dem = np.where(Dd > 0, high * low / np.where(Dd > 0, Dd, 1.0), 0.0)
            r = np.where(y > 1.0, low, r_dem)
            c = np.where(y > 1.0, low, y * r_dem + (1.0 - y) * high)
        elif rule == "hyperbolic":
            a, b = np.sqrt(low), np.sqrt(high)
            gap = np.where(b > a, b - a, 1.0)  # b - a, guarded for a flat band
            chi = a * b / gap
            ab = a * b
            u = np.clip(1.0 - np.where(y > 0, 1.0 / np.where(y > 0, y, 1.0), 0.0), 0.0, None)
            z = chi / np.where(u + a / gap > 0, u + a / gap, 1.0)   # chi / (u + chi/b)
            r = np.where(y > 1.0, chi * (z - a) + u * low, ab)
            c = np.where(y > 1.0, a * z, y * ab + (1.0 - y) * high)
            # Zero feed-in rate: the limit of the rule, as in the contract.
            r = np.where(low <= 0, 0.0, r)
            c = np.where(low <= 0, np.where(y > 1.0, 0.0, (1.0 - y) * high), c)
        else:
            raise ValueError(f"unknown rule {rule}")
    # Conventions shared with the contract: an empty side, or a zero-width band.
    empty = (S <= 0) | (D <= 0) | (high <= low)
    r = np.where(empty, low, r)
    c = np.where(empty, high, c)
    return r, c, rho


def price_impacts(sell, buy, low, high, rule, h=1e-6):
    """Marginal price impact of each member on its own side, and the gap between its
    marginal and average price, from the derivatives of the rule in y = S/D.

    A buyer moves y at rate -y/D, a seller at rate 1/D, so
        d c / d d_n = -(y/D) c'(y)        d r / d s_n = r'(y) / D
    and the gaps are d_n * |d c / d d_n| and s_n * |d r / d s_n|. Only sessions with
    both sides present are considered; elsewhere nobody moves a price."""
    S = sell.sum(axis=0)
    D = buy.sum(axis=0)
    both = (S > 0) & (D > 0) & (high > low)
    y = np.where(both, S / np.where(D > 0, D, 1.0), 1.0)
    ones = np.ones_like(y)

    def prices_at(yy):
        return session_prices(yy, ones, low, high, rule)[:2]

    r_up, c_up = prices_at(y * (1 + h))
    r_dn, c_dn = prices_at(y * (1 - h))
    dr = (r_up - r_dn) / (2 * h * y)
    dc = (c_up - c_dn) / (2 * h * y)
    imp_buy = np.where(both, np.abs(-(y / np.where(D > 0, D, 1.0)) * dc), 0.0)
    imp_sell = np.where(both, np.abs(dr / np.where(D > 0, D, 1.0)), 0.0)
    gap_buy = buy * imp_buy[None, :, :]
    gap_sell = sell * imp_sell[None, :, :]

    r, c, _ = session_prices(S, D, low, high, rule)
    marg_cost = c[None, :, :] + gap_buy
    marg_rev = r[None, :, :] - gap_sell
    tol = 1e-12
    return {
        "sessions_both": int(both.sum()),
        "excess_supply": int((both & (S > D)).sum()),
        "excess_demand": int((both & (S < D)).sum()),
        "impact_buy": imp_buy[both & (imp_buy > tol)],
        "impact_sell": imp_sell[both & (imp_sell > tol)],
        "gap_buy": gap_buy[(buy > 0) & (gap_buy > tol)],
        "gap_sell": gap_sell[(sell > 0) & (gap_sell > tol)],
        "ir_buy_broken": int(((buy > 0) & (marg_cost > high[None, :, :] + tol)).sum()),
        "ir_sell_broken": int(((sell > 0) & (marg_rev < low[None, :, :] - tol)).sum()),
        "buyer_sessions": int(((buy > 0) & both[None, :, :]).sum()),
        "seller_sessions": int(((sell > 0) & both[None, :, :]).sum()),
    }


# Number with thin thousands separators.
def fmt(x, dec=2):
    return f"{x:,.{dec}f}".replace(",", " ")


# One PDF page holding a table.
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
    ap.add_argument("--netputs", default=str(demo / "data" / "netputs_raw.json"))
    ap.add_argument("--prices", default=str(demo / "data" / "prices.json"))
    ap.add_argument("--out", default=None, help="default demo/results_raw_<rule>.pdf")
    ap.add_argument("--rule", default="mmr", choices=RULES,
                    help="pricing rule, as fixed in the Pricing contract (default mmr)")
    ap.add_argument("--figdir", default=None,
                    help="also export each figure as a standalone PDF plus two LaTeX "
                         "tables (booktabs) into this folder, sized for a report")
    args = ap.parse_args()
    if args.out is None:
        args.out = str(demo / f"results_raw_{args.rule}.pdf")  # default depends on the rule

    names, sell, buy, dates, low, high, feed = load(args.netputs, args.prices)
    n, n_days, T = sell.shape
    slots = [f"slot {i + 1}" for i in range(n)]  # members as the chain numbers them

    S = sell.sum(axis=0)
    D = buy.sum(axis=0)
    matched = np.minimum(S, D)  # energy matched locally per session
    spread = high - low  # gain per matched kWh
    r, c, rho = session_prices(S, D, low, high, args.rule)

    amm = r[None, :, :] * sell - c[None, :, :] * buy  # cash flows with the market
    base = low[None, :, :] * sell - high[None, :, :] * buy  # cash flows with the grid alone
    gain = amm - base  # member gain per session
    gain_sell = (r - low)[None, :, :] * sell  # earned selling above feed-in
    gain_buy = (high - c)[None, :, :] * buy  # saved buying below retail

    community_gain = gain.sum(axis=0)
    check = np.abs(community_gain - spread * matched).max()  # budget balance: community gain = spread x matched
    assert check < 1e-9, f"settlement identity violated by {check}"
    impacts = price_impacts(sell, buy, low, high, args.rule)

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

    w_r = np.divide((r * S).sum(), S.sum()) if S.sum() > 0 else 0.0  # volume-weighted prices over the run
    w_c = np.divide((c * D).sum(), D.sum()) if D.sum() > 0 else 0.0
    w_low = (low * S).sum() / S.sum() if S.sum() > 0 else 0.0
    w_high = (high * D).sum() / D.sum() if D.sum() > 0 else 0.0

    per_agent = pd.DataFrame(index=slots)  # per-member table
    per_agent["sold kWh"] = sell.sum(axis=(1, 2))
    per_agent["bought kWh"] = buy.sum(axis=(1, 2))
    per_agent["grid only USD"] = base.sum(axis=(1, 2))
    per_agent["with AMM USD"] = amm.sum(axis=(1, 2))
    per_agent["gain USD"] = gain.sum(axis=(1, 2))
    per_agent["gain seller side"] = gain_sell.sum(axis=(1, 2))
    per_agent["gain buyer side"] = gain_buy.sum(axis=(1, 2))
    traded = per_agent["sold kWh"] + per_agent["bought kWh"]
    per_agent["gain c/kWh traded"] = 100 * per_agent["gain USD"] / traded.replace(0, np.nan)
    per_agent["share of gain %"] = 100 * per_agent["gain USD"] / per_agent["gain USD"].sum()

    per_day = pd.DataFrame(index=day_labels)  # per-day table
    per_day["offered kWh"] = sold_day
    per_day["demanded kWh"] = bought_day
    per_day["matched kWh"] = matched_day
    per_day["covered %"] = 100 * matched_day / bought_day  # share of demand served locally
    per_day["absorbed %"] = 100 * matched_day / sold_day  # share of supply sold locally
    per_day["gain USD"] = gain_day

    with PdfPages(args.out) as pdf:

        fig, ax = plt.subplots(figsize=PAGE)
        ax.axis("off")
        y = 0.95
        # Page 1: setting and headline results.
        ax.text(0.02, y, f"ResStock demo, market results ({args.rule})", fontsize=22, color=INK, weight="bold")
        y -= 0.07
        ax.text(0.02, y, "Local energy sharing AMM on measured building data and real day-ahead prices",
                fontsize=12, color="#555555")
        y -= 0.09
        lines = [
            ("Community", f"{n} prosumers (5 with rooftop PV, 5 without), single Massachusetts county, ResStock amy2018 release 2"),
            ("Period", f"{n_days} trading days, {dates[0]} to {dates[-1]}, {T} sessions of 15 minutes per day"),
            ("Prices", f"ISO New England day-ahead LMP, zone {feed.get('zone', '?')}, retail = wholesale + {feed.get('delivery_adder', 0)} USD/kWh delivery adder"),
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
            f"Community gain over {n_days} days: {fmt(community_gain.sum())} USD "
            f"({fmt(community_gain.sum() / n_days)} USD/day), entirely the delivery spread earned on locally matched energy",
            f"Locally matched energy: {fmt(matched.sum(), 1)} kWh of {fmt(D.sum(), 1)} kWh demanded, "
            f"{fmt(100 * matched.sum() / D.sum(), 1)} % of demand served locally "
            f"({fmt(100 * matched.sum() / S.sum(), 1)} % of the surplus absorbed locally)",
            f"Sellers received on average {fmt(100 * w_r, 2)} c/kWh against {fmt(100 * w_low, 2)} wholesale; "
            f"buyers paid {fmt(100 * w_c, 2)} c/kWh against {fmt(100 * w_high, 2)} retail",
            f"Spread high - low = the {fmt(100 * (high - low).mean(), 0)} c/kWh delivery adder in every session, "
            "so the gain is 0.12 USD per matched kWh and matching volume is the only lever",
        ]
        import textwrap
        for txt in heads:
            wrapped = textwrap.fill(txt, 128)
            ax.text(0.02, y, "\u2022  " + wrapped, fontsize=10.5, color=INK, va="top")
            y -= 0.045 + 0.032 * wrapped.count("\n")
        pdf.savefig(fig)
        plt.close(fig)

        # Pages of the report, one figure or table each.
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
        axes[0].set_ylabel("USD per session")
        axes[0].set_title("Community gain per session versus the status quo", loc="left", fontsize=12)
        axes[1].plot(x, np.cumsum(flat_gain), color=GAIN, lw=1.6)
        for d in range(1, n_days):
            axes[0].axvline(d * T, color=GRID, lw=0.7, ls=":")
            axes[1].axvline(d * T, color=GRID, lw=0.7, ls=":")
        axes[1].set_ylabel("USD cumulative")
        axes[1].set_xlabel("session")
        axes[1].set_xticks([d * T + T // 2 for d in range(n_days)])
        axes[1].set_xticklabels(day_labels)
        axes[1].set_title("Cumulative community gain across the run", loc="left", fontsize=12)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        d_star = int(np.argmax(matched_day))  # most active day
        fig, axes = plt.subplots(2, 1, figsize=PAGE, sharex=True,
                                 gridspec_kw={"height_ratios": [1.5, 1.0]})
        ax = axes[0]
        ax.step(hours, 100 * high[d_star], where="post", color=BOUGHT, lw=1.3, label="high (retail)")
        ax.step(hours, 100 * c[d_star], where="post", color=BOUGHT, lw=1.1, ls="--", label="c (buyers pay)")
        ax.step(hours, 100 * rho[d_star], where="post", color=GRID, lw=1.0, label="midpoint")
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
            "Cash flows in USD, negative = net payment. Gain = with AMM - grid only; "
            "it is non negative for every member in every session.",
            dec={"gain c/kWh traded": 3, "share of gain %": 1},
        )

        fig, ax = plt.subplots(figsize=PAGE)
        cmap = plt.get_cmap("tab10")
        cum_gain = np.cumsum(gain.reshape(n, -1), axis=1)  # cumulative gain per member
        for i in range(n):
            ax.plot(x, cum_gain[i], lw=1.4, color=cmap(i % 10), label=slots[i])
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.7, ls=":")
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels(day_labels)
        ax.set_ylabel("USD cumulative")
        ax.set_title("Individual gains versus the status quo, cumulative across sessions",
                     loc="left", fontsize=13)
        ax.legend(loc="upper left", frameon=False, fontsize=9, ncol=2)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        fig, ax = plt.subplots(figsize=PAGE)
        cum_amm = np.cumsum(amm.reshape(n, -1), axis=1)  # cumulative cash, with the market
        cum_base = np.cumsum(base.reshape(n, -1), axis=1)
        for i in range(n):
            ax.plot(x, cum_amm[i], lw=1.4, color=cmap(i % 10), label=slots[i])
            ax.plot(x, cum_base[i], lw=0.9, color=cmap(i % 10), alpha=0.45, ls="--")
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.7, ls=":")
        ax.axhline(0, color=INK, lw=0.6)
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels(day_labels)
        ax.set_ylabel("USD cumulative")
        ax.set_title("Net cash position per member, with the AMM (solid) and grid only (dashed)",
                     loc="left", fontsize=13)
        ax.legend(loc="lower left", frameon=False, fontsize=9, ncol=2)
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        fig, ax = plt.subplots(figsize=PAGE)
        gs = per_agent["gain seller side"].values  # gain decomposition per member
        gb = per_agent["gain buyer side"].values
        idx = np.arange(n)
        ax.bar(idx, gs, color=SOLD, label="earned selling above wholesale")
        ax.bar(idx, gb, bottom=gs, color=BOUGHT, label="saved buying below retail")
        ax.set_xticks(idx)
        ax.set_xticklabels(slots, rotation=0)
        ax.set_ylabel("USD over the run")
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


    if args.figdir:  # standalone figures and tables of the paper
        figdir = Path(args.figdir)
        figdir.mkdir(parents=True, exist_ok=True)
        W = 6.3  # text width of the paper, inches

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
        save(fig, "fig_sessions.pdf")  # supply, demand and matched energy

        fig, ax = plt.subplots(figsize=(W, 2.9))
        ax.plot(x, np.cumsum(flat_gain), color=GAIN, lw=1.4)
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.6, ls=":")
        ax.set_ylabel("USD, cumulative")
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels([dt for dt in dates], fontsize=8)
        save(fig, "fig_gain.pdf")  # cumulative community gain

        d_star2 = int(np.argmax(matched_day))
        fig, ax = plt.subplots(figsize=(W, 3.2))
        ax.step(hours, 100 * high[d_star2], where="post", color=BOUGHT, lw=1.1, label="high (retail)")
        ax.step(hours, 100 * c[d_star2], where="post", color=BOUGHT, lw=0.9, ls="--", label="c (buyers pay)")
        ax.step(hours, 100 * rho[d_star2], where="post", color=GRID, lw=0.8, label="midpoint")
        ax.step(hours, 100 * r[d_star2], where="post", color=SOLD, lw=0.9, ls="--", label="r (sellers get)")
        ax.step(hours, 100 * low[d_star2], where="post", color=SOLD, lw=1.1, label="low (wholesale)")
        ax.set_xlabel("hour of day")
        ax.set_ylabel("c/kWh")
        ax.legend(loc="upper left", frameon=False, fontsize=7, ncol=2)
        save(fig, "fig_prices.pdf")  # prices on the most active day

        fig, ax = plt.subplots(figsize=(W, 3.4))
        cmap2 = plt.get_cmap("tab10")
        cg = np.cumsum(gain.reshape(n, -1), axis=1)
        for i in range(n):
            ax.plot(x, cg[i], lw=1.0, color=cmap2(i % 10), label=slots[i])
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.6, ls=":")
        ax.set_ylabel("USD, cumulative")
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels([dt for dt in dates], fontsize=8)
        ax.legend(loc="upper left", frameon=False, fontsize=6.5, ncol=2)
        save(fig, "fig_individual.pdf")  # cumulative gain per member

        fig, ax = plt.subplots(figsize=(W, 3.4))
        ca = np.cumsum(amm.reshape(n, -1), axis=1)
        cb = np.cumsum(base.reshape(n, -1), axis=1)
        for i in range(n):
            ax.plot(x, ca[i], lw=1.0, color=cmap2(i % 10), label=slots[i])
            ax.plot(x, cb[i], lw=0.7, color=cmap2(i % 10), alpha=0.45, ls="--")
        ax.axhline(0, color=INK, lw=0.5)
        for d in range(1, n_days):
            ax.axvline(d * T, color=GRID, lw=0.6, ls=":")
        ax.set_ylabel("USD, cumulative")
        ax.set_xticks([d * T + T // 2 for d in range(n_days)])
        ax.set_xticklabels([dt for dt in dates], fontsize=8)
        ax.legend(loc="lower left", frameon=False, fontsize=6.5, ncol=2)
        save(fig, "fig_cash.pdf")  # cash position per member

        fig, ax = plt.subplots(figsize=(W, 2.9))
        gsv = per_agent["gain seller side"].values
        gbv = per_agent["gain buyer side"].values
        idx2 = np.arange(n)
        ax.bar(idx2, gsv, color=SOLD, label="earned selling above wholesale")
        ax.bar(idx2, gbv, bottom=gsv, color=BOUGHT, label="saved buying below retail")
        ax.set_xticks(idx2)
        ax.set_xticklabels(slots, fontsize=7)
        ax.set_ylabel("USD over the run")
        ax.legend(loc="upper right", frameon=False, fontsize=7)
        save(fig, "fig_decomposition.pdf")  # seller and buyer sides of each gain

        # Number for LaTeX, with thin spaces and a math minus.
        def fr(v, dec=2):
            txt = f"{abs(v):,.{dec}f}".replace(",", "\\,")
            return f"$-{txt}$" if v < 0 else txt

        lines = ["\\begin{tabular}{lrrrrrr}", "\\toprule",
                 "Day & Offered & Demanded & Matched & Covered & Absorbed & Gain \\\\",
                 " & (kWh) & (kWh) & (kWh) & (\\%) & (\\%) & (USD) \\\\",
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
        (figdir / "table_days.tex").write_text("\n".join(lines), encoding="utf-8")  # per-day table

        lines = ["\\begin{tabular}{lrrrrrr}", "\\toprule",
                 "Household & Sold & Bought & Grid only & With AMM & Gain & Share of gain \\\\",
                 " & (kWh) & (kWh) & (USD) & (USD) & (USD) & (\\%) \\\\",
                 "\\midrule"]
        tot_g = per_agent["gain USD"].sum()
        for i, slot in enumerate(slots):
            row = per_agent.iloc[i]
            lines.append(f"{i + 1} & {fr(row['sold kWh'], 1)} & {fr(row['bought kWh'], 1)} & "
                         f"{fr(row['grid only USD'])} & {fr(row['with AMM USD'])} & {fr(row['gain USD'])} & "
                         f"{fr(100 * row['gain USD'] / tot_g, 1)} \\\\")
        lines += ["\\bottomrule", "\\end{tabular}"]
        (figdir / "table_households.tex").write_text("\n".join(lines), encoding="utf-8")  # per-member table
        print(f"exported figures and tables to {figdir}")

    print(f"wrote {args.out}")  # summary on stdout
    print(f"rule: {args.rule}")
    print(f"community gain: {community_gain.sum():.2f} USD over {n_days} days, "
          f"{100 * matched.sum() / D.sum():.1f} % of demand served locally")
    print(f"grid-only net cost: {-base.sum():.2f} USD, saving {100 * community_gain.sum() / -base.sum():.1f} %")
    print(f"split of the gain: sellers {gain_sell.sum():.2f} USD, buyers {gain_buy.sum():.2f} USD")
    print(f"volume-weighted prices (cents/kWh): sellers {100 * w_r:.2f} vs feed-in {100 * w_low:.2f}, "
          f"buyers {100 * w_c:.2f} vs retail {100 * w_high:.2f}")
    print(f"household gains: {per_agent['gain USD'].min():.2f} to {per_agent['gain USD'].max():.2f} USD")
    imp = impacts

    # Percentile in cents.
    def q(a, p):
        return 100 * float(np.percentile(a, p)) if len(a) else float("nan")
    print(f"price impact: {imp['sessions_both']} sessions with both sides "
          f"({imp['excess_supply']} excess supply, {imp['excess_demand']} excess demand)")
    for side in ("buy", "sell"):
        a, g = imp[f"impact_{side}"], imp[f"gap_{side}"]
        who = "buyers " if side == "buy" else "sellers"
        if len(a):
            print(f"  {who} impact of one more kWh (cents/kWh): median {q(a, 50):.2f}, p90 {q(a, 90):.2f}, "
                  f"max {q(a, 100):.2f} over {len(a)} sessions; gap: median {q(g, 50):.2f}, "
                  f"p90 {q(g, 90):.2f}, max {q(g, 100):.2f} over {len(g)} member-sessions")
        else:
            print(f"  {who} no price impact in any session")
    print(f"  marginal price outside the band: {imp['ir_buy_broken']} of {imp['buyer_sessions']} buyer-sessions, "
          f"{imp['ir_sell_broken']} of {imp['seller_sessions']} seller-sessions")


if __name__ == "__main__":
    main()
