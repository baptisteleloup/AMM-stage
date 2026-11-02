import argparse
import json
import os
import sys
from datetime import datetime, timezone

import numpy as np
import pandas as pd

SESSIONS = 96


def load_driver(reference_dir):
    sys.path.insert(0, reference_dir)
    try:
        from rollingHorizon import runRH
    except ImportError as e:
        raise SystemExit(f"cannot import the paper's driver from {reference_dir}: {e}\n"
                         f"point --reference at the folder holding rollingHorizon.py")
    return runRH


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profiles", default="profiles")
    ap.add_argument("--reference", required=True, help="folder holding rollingHorizon.py")
    ap.add_argument("--out", default="netputs_resstock.json")
    ap.add_argument("--force", action="store_true", help="allow writing over an existing file")
    ap.add_argument("--prices", default=None,
                    help="prices.json from fetch_prices.py; the solver then optimises "
                         "against the same vectors the chain will price with")
    ap.add_argument("--lam-under", type=float, default=None, help="flat feed-in, if no --prices")
    ap.add_argument("--lam-over-peak", type=float, default=None)
    ap.add_argument("--lam-over-offpeak", type=float, default=None)
    ap.add_argument("--peak-window", default="64800-79200")
    ap.add_argument("--battery-kwh", type=float, default=10.0)
    ap.add_argument("--battery-kw", type=float, default=5.0)
    ap.add_argument("--trade-kw", type=float, default=0.0,
                    help="max power tradeable per step; 0 = size it from the data")
    ap.add_argument("--headroom", type=float, default=1.3)
    ap.add_argument("--lookahead", type=int, default=1)
    ap.add_argument("--gamma", type=float, default=1.0)
    args = ap.parse_args()

    if os.path.basename(args.out) == "netputs_nice.json" and not args.force:
        raise SystemExit(
            f"{args.out} holds the Nice netputs from the paper's own simulation.\n"
            f"Writing ResStock data into a file named 'nice' would destroy that\n"
            f"dataset and mislabel this one. Choose another name, or pass --force.")
    if os.path.exists(args.out) and not args.force:
        raise SystemExit(f"{args.out} already exists; pass --force to overwrite it")

    runRH = load_driver(args.reference)

    with open(os.path.join(args.profiles, "agents.json")) as f:
        meta = json.load(f)
    names = [a["name"] for a in meta["agents"]]
    days = meta["days"]

    series = {n: pd.read_parquet(os.path.join(args.profiles, f"{n}.parquet")) for n in names}
    index = series[names[0]].index

    T = SESSIONS
    time_interval = 24.0 / T
    L = args.lookahead
    sim_days = days[:max(1, len(days) - L)]
    peak_base = max(float(series[n]["alpha_base_kw"].max()) for n in names)
    peak_gen = max(float(series[n]["omega_kw"].max()) for n in names)
    if args.trade_kw <= 0:
        args.trade_kw = round(max(peak_base, peak_gen) * args.headroom + 0.5, 1)
        print(f"trade cap sized from the data: peak base load {peak_base:.2f} kW, "
              f"peak generation {peak_gen:.2f} kW  ->  X = {args.trade_kw} kW")

    price_feed = None
    flat_under = flat_over = None
    if args.prices:
        with open(args.prices) as f:
            price_feed = json.load(f)
        print(f"prices: day-ahead feed for zone {price_feed.get('zone', '?')}, "
              f"{len(price_feed['days'])} day(s), delivery adder "
              f"{price_feed.get('delivery_adder', '?')}/kWh")
    else:
        lam_u = args.lam_under if args.lam_under is not None else float(os.environ.get("FEED_IN_C", 8.86)) / 100
        lam_peak = args.lam_over_peak if args.lam_over_peak is not None else float(os.environ.get("PEAK_C", 21.46)) / 100
        lam_off = args.lam_over_offpeak if args.lam_over_offpeak is not None else float(os.environ.get("OFF_PEAK_C", 16.96)) / 100
        flat_under = np.full(T, lam_u)
        flat_over = np.full(T, lam_off)
        for win in args.peak_window.split(","):
            if win.strip():
                a, b = (int(x) for x in win.split("-"))
                for t in range(T):
                    if a <= t * 900 < b:
                        flat_over[t] = lam_peak
        print(f"tariffs: feed-in {lam_u:.4f}, off-peak {lam_off:.4f}, peak {lam_peak:.4f} per kWh")

    stacked = np.vstack([(series[n]["omega_kw"] - series[n]["alpha_base_kw"]).values for n in names])
    agg_s = pd.DataFrame({"supply_kw": np.maximum(stacked, 0).sum(axis=0)}, index=index)
    agg_d = pd.DataFrame({"demand_kw": np.maximum(-stacked, 0).sum(axis=0)}, index=index)

    print(f"{len(names)} agents, {len(days)} day(s) of data, simulating {len(sim_days)} day(s) at T={T}")
    print("each prosumer optimises against the community aggregate, taken as given")

    day_starts = [pd.Timestamp(d) for d in days]
    plans = {}
    failures = []

    for n in names:
        s = series[n]
        omega = pd.DataFrame({"supply_kw": s["omega_kw"].values}, index=index)
        alpha_base = pd.Series(s["alpha_base_kw"].values, index=index)
        flex_profile = pd.DataFrame({"demand_kw": s["flex_kw"].values}, index=index)
        total_demand = pd.DataFrame(
            {"demand_kw": (s["alpha_base_kw"] + s["flex_kw"]).values}, index=index)

        net = np.zeros(len(sim_days) * T)
        b0 = 0.0

        for di, day in enumerate(sim_days):
            start = day_starts[di]
            window = slice(start, start + pd.Timedelta(days=L + 1) - pd.Timedelta(minutes=15))

            if price_feed is not None:
                pf = price_feed["prices"][price_feed["days"][di % len(price_feed["days"])]]
                lam_under = np.array(pf["low"], dtype=float)
                lam_over = np.array(pf["high"], dtype=float)
            else:
                lam_under, lam_over = flat_under, flat_over

        
            try:
                res = runRH(
                    T, 1, alpha_base.loc[window], b0, L,
                    omega.loc[window], agg_s.loc[window], agg_d.loc[window],
                    flex_profile.loc[window], 1.0, np.zeros((1, L + 1)),
                    args.battery_kwh, args.trade_kw, args.battery_kw,
                    lam_under, lam_over, args.gamma,
                    total_demand.loc[window], save=False,
                )
            except Exception as e:
                failures.append((n, day, str(e)[:70]))
                continue

            if res is None or len(res) < T:
                failures.append((n, day, "solver returned nothing"))
                continue
            net[di * T:(di + 1) * T] = res["net_grid_trade_kw"].values[:T]
            b0 = float(np.clip(res["battery_soc_kwh"].values[T - 1], 0, args.battery_kwh))

        plans[n] = net
        print(f"  {n}: done")

    if failures:
        print()
        print(f"WARNING: {len(failures)} agent-day(s) unsolved, left at zero:")
        for n, d, why in failures[:6]:
            print(f"    {n} on {d}: {why}")

    profiles = {}
    totals = {"sold": 0, "bought": 0}
    for n in names:
        per_day = {}
        for di in range(len(sim_days)):
            rows = []
            for t in range(T):
                v = plans[n][di * T + t] * 1000
                sell = int(round(v)) if v > 0 else 0
                buy = int(round(-v)) if v < 0 else 0
                rows.append([sell, buy])
                totals["sold"] += sell
                totals["bought"] += buy
            per_day[str(di)] = rows
        profiles[n] = per_day

    with open(args.out, "w") as f:
        json.dump({"sessions": SESSIONS, "unit": "Wh", "baseDay": 0,
                   "days": len(sim_days), "profiles": profiles}, f)

    manifest = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "driver": "runRH from the paper's rollingHorizon.py, called unmodified",
        "method": "each prosumer optimises against the community aggregate taken "
                  "as given, as the paper does; the aggregate is the members' raw "
                  "surplus and deficit before optimisation",
        "known_limitation": "in the paper the aggregate is a population of about a "
                            "million, so price-taking is natural. In a community of "
                            "a few members each one moves the aggregate it faces, "
                            "and this run does not account for that. Iterating to a "
                            "fixed point does not converge: the AMM price curve is "
                            "kinked and the best-response map is not a contraction.",
        "departures_from_the_notebook": [
            f"T = {T} quarter-hourly instead of 24 hourly, matching the settlement "
            f"period and the native resolution of the load data",
            "flexible load taken from each building's end-use breakdown instead of "
            "a flat 30% of daily demand; runRH is used unmodified by handing it the "
            "flexible series with pct_flex = 1",
            "runRH called one day at a time so each day carries its own day-ahead "
            "prices, with the battery state carried forward as runRH does internally",
        ],
        "parameters": {
            "trade_cap_kw": args.trade_kw,
            "peak_base_load_kw": round(peak_base, 2),
            "battery_kwh": args.battery_kwh,
            "battery_kw": args.battery_kw,
            "lookahead_days": L,
            "gamma": args.gamma,
            "price_feed": args.prices,
        },
        "days_simulated": sim_days,
        "unsolved_agent_days": [f"{n}/{d}" for n, d, _ in failures],
        "totals_wh": totals,
    }
    with open(os.path.join(args.profiles, "solver_manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)

    gen = sum(float(series[n]["omega_kw"].sum()) for n in names) * time_interval
    con = sum(float((series[n]["alpha_base_kw"] + series[n]["flex_kw"]).sum()) for n in names) * time_interval
    n_days_data = len(days)
    expected_net = (con - gen) / n_days_data
    actual_net = (totals["bought"] - totals["sold"]) / 1000 / len(sim_days)
    ratio = actual_net / expected_net if abs(expected_net) > 1e-6 else float("nan")
    print()
    print(f"energy balance: the community consumes {con / n_days_data:.1f} kWh/day and "
          f"generates {gen / n_days_data:.1f}, so it should buy {expected_net:.1f} kWh/day net")
    print(f"                the netputs buy {actual_net:.1f} kWh/day net "
          f"({ratio:.2f} of expected)")
    if not (0.6 < ratio < 1.6):
        print("WARNING: that ratio should sit near 1. A factor close to 4 or 0.25 "
              "means a kW / kWh-per-interval confusion; a factor near the number of "
              "days means a per-day aggregation error.")

    print()
    print(f"wrote {args.out}: {len(names)} agents x {len(sim_days)} day(s)")
    print(f"point the daemon at it with:  NETPUTS_JSON={args.out}")
    print(f"community traded {totals['sold'] / 1000:.1f} kWh sold, "
          f"{totals['bought'] / 1000:.1f} kWh bought over the period")
    if totals["sold"] == 0 or totals["bought"] == 0:
        print("WARNING: one side is empty, so the AMM sits at a tariff bound "
              "throughout and nothing is exchanged locally.")


if __name__ == "__main__":
    main()
