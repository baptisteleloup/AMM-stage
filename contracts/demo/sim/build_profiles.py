# Builds the household profiles from ResStock 15-minute load curves: PV output, base load, flexible
# load (hot water, pool and spa pumps) and appliance cycles (dishwasher, washer, dryer). Downloads
# each building once into --cache; writes prosumer-<i>.parquet, agents.json, cycles.json and
# manifest.json to --out. Run from contracts/ (ids from selection.json):
#   python3 demo/sim/build_profiles.py --ids <id,...> --state MA --days 2018-07-01:2018-07-05 --out demo/data/profiles
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

import numpy as np
import pandas as pd

SESSIONS = 96  # fifteen-minute sessions per day
# one parquet per building, baseline (upgrade 0)
BASE_URL = ("https://oedi-data-lake.s3.amazonaws.com/nrel-pds-building-stock/"
            "end-use-load-profiles-for-us-building-stock/2024/"
            "resstock_amy2018_release_2/timeseries_individual_buildings/"
            "by_state/upgrade=0/state={state}/{bid}-0.parquet")


FLEXIBLE_PATTERNS = [  # daily energy that can move freely within the day
    r"\.hot_water",
    r"\.water_systems",
    r"\.pool_pump",
    r"\.permanent_spa_pump",
]

CYCLE_APPS = ["dishwasher", "clothes_washer", "clothes_dryer"]  # appliances run as cycles whose start can move
CYCLE_PATTERN = r"\.(" + "|".join(CYCLE_APPS) + r")\."
WASH_DRY_MAX_GAP = pd.Timedelta(hours=4)  # a dryer this soon after a washer is paired with it

FLEXIBLE_EXCLUDE = [  # never flexible: fans and pumps, totals
    r"_fans_pumps",
    r"\.total",
    r"\.net",
]

PV_PATTERNS = [r"\.pv\b", r"photovoltaic", r"\.pv_"]  # PV output columns


# Hash of a source file, recorded in the manifest.
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def matches(name, patterns):
    return any(re.search(p, name) for p in patterns)


def classify(columns):
    """Split ResStock electricity columns into pv / flexible / cycle / base."""
    elec = [c for c in columns
            if c.startswith("out.electricity.") and c.endswith("energy_consumption")]
    pv = [c for c in elec if matches(c, PV_PATTERNS)]
    cyc = [c for c in elec if re.search(CYCLE_PATTERN, c) and c not in pv]
    flex = [c for c in elec
            if matches(c, FLEXIBLE_PATTERNS)
            and not matches(c, FLEXIBLE_EXCLUDE)
            and c not in pv and c not in cyc]
    skip = set(pv) | set(flex) | set(cyc)
    base = [c for c in elec
            if c not in skip and not matches(c, [r"\.total", r"\.net"])]
    return pv, flex, cyc, base


def app_of(col):
    return re.search(CYCLE_PATTERN, col).group(1)


def detect_cycles(df, cyc_cols, name, to_kw):
    """One cycle per uninterrupted run of non-zero consumption."""
    cycles = []
    for col in cyc_cols:
        app = app_of(col)
        kw = df[col] * to_kw
        on = kw > 0
        if not on.any():
            continue
        run_id = (on != on.shift()).cumsum()[on]  # one id per uninterrupted run
        for _, run in kw[on].groupby(run_id):
            start = run.index[0]
            if start == df.index[0] or run.index[-1] == df.index[-1]:  # runs cut by the window are incomplete
                print(f"  {name}: {app} cycle at {start} cut by the window, left out")
                continue
            date = start.normalize()
            cycles.append({
                "appliance": app,
                "date": date.date().isoformat(),
                "observed_step": int((start - date) / pd.Timedelta(minutes=15)),  # start session within its day
                "profile_kw": [round(float(v), 4) for v in run.values],
                "energy_kwh": round(float(run.sum()) / to_kw, 4),
                "_start": start,  # internal, removed below
            })
    cycles.sort(key=lambda c: c["_start"])
    for i, c in enumerate(cycles):
        c["id"] = f"{name}/{c['appliance']}/{i}"
        c["after"] = None
        c["min_lag_steps"] = 0

    used = set()
    # pair each dryer with the latest unpaired washer of its day
    for dryer in (c for c in cycles if c["appliance"] == "clothes_dryer"):
        washers = [w for w in cycles
                   if w["appliance"] == "clothes_washer"
                   and w["id"] not in used
                   and w["date"] == dryer["date"]
                   and w["_start"] <= dryer["_start"]
                   and dryer["_start"] - w["_start"] <= WASH_DRY_MAX_GAP]
        if washers:
            w = washers[-1]
            used.add(w["id"])
            dryer["after"] = w["id"]  # the dryer must start after this washer
            dryer["min_lag_steps"] = int((dryer["_start"] - w["_start"])
                                         / pd.Timedelta(minutes=15))
    for c in cycles:
        del c["_start"]
    return cycles


# Downloads one building's load curve once, then reuses the cached copy.
def fetch(bid, state, cache_dir):
    os.makedirs(cache_dir, exist_ok=True)
    dest = os.path.join(cache_dir, f"{bid}-0.parquet")
    if os.path.exists(dest):
        return dest, False
    url = BASE_URL.format(state=state, bid=bid)
    print(f"  downloading {bid} from {url}")
    r = subprocess.run(["curl", "-fsSL", "-o", dest, url])
    if r.returncode != 0:
        raise SystemExit(f"download failed for building {bid}; check the ID, the "
                         f"state, and that the release path is current")
    return dest, True


# Load curve of one building over the run, indexed by interval start.
def load_building(path, day_from, day_to):
    df = pd.read_parquet(path)
    tcol = "timestamp" if "timestamp" in df.columns else df.columns[0]
    df[tcol] = pd.to_datetime(df[tcol])
    df = df.set_index(tcol).sort_index()
    df.index = df.index - pd.Timedelta(minutes=15)  # ResStock labels the end of each interval

    df = df.loc[day_from:day_to]
    if len(df) == 0:
        raise SystemExit(f"no rows in {day_from}..{day_to} for {path}")
    return df


# Splits one building into PV, base, flexible and cycle series, in kW.
def build_agent(df, name):
    pv_cols, flex_cols, cyc_cols, base_cols = classify(df.columns)
    to_kw = 4.0  # kWh per 15 min -> average kW
    zero = pd.Series(0.0, index=df.index)
    pv_kwh = df[pv_cols].sum(axis=1) if pv_cols else zero
    flex_kwh = df[flex_cols].sum(axis=1) if flex_cols else zero
    cyc_kwh = df[cyc_cols].sum(axis=1) if cyc_cols else zero
    base_kwh = df[base_cols].sum(axis=1) if base_cols else zero
    # max flexible power: sum of each end use's peak
    flex_cap_kw = float(sum(df[c].max() for c in flex_cols)) * to_kw if flex_cols else 0.0
    cycles = detect_cycles(df, cyc_cols, name, to_kw)
    pv_sign = "negative" if float(pv_kwh.sum()) < 0 else "positive"  # ResStock may report PV as negative consumption
    omega_kw = pv_kwh.abs() * to_kw  # PV output, kW, positive

    alpha_base_kw = base_kwh * to_kw
    flex_daily_kwh = flex_kwh.groupby(flex_kwh.index.normalize()).sum()  # flexible energy per day

    out = pd.DataFrame({
        "omega_kw": omega_kw.values,
        "alpha_base_kw": alpha_base_kw.values,
        "flex_kw": flex_kwh.values * to_kw,
        "flex_cap_kw": flex_cap_kw,
        "cycle_kw": cyc_kwh.values * to_kw,  # observed cycles, kept so the recorded net position is unchanged
    }, index=df.index)

    stats = {
        "name": name,
        "pv_columns": pv_cols,
        "flexible_columns": flex_cols,
        "cycle_columns": cyc_cols,
        "flex_cap_kw": round(flex_cap_kw, 3),
        "cycles": len(cycles),
        "base_columns_count": len(base_cols),
        "pv_sign_convention": pv_sign,
        "has_pv": bool(pv_cols) and float(pv_kwh.abs().sum()) > 0,
        "generation_kwh_per_day": round(float(omega_kw.sum() / to_kw) / max(1, len(flex_daily_kwh)), 2),
        "base_kwh_per_day": round(float(base_kwh.sum()) / max(1, len(flex_daily_kwh)), 2),
        "flexible_kwh_per_day": round(float(flex_kwh.sum()) / max(1, len(flex_daily_kwh)), 2),
        "cycle_kwh_per_day": round(float(cyc_kwh.sum()) / max(1, len(flex_daily_kwh)), 2),
        "flexible_share": round(float((flex_kwh.sum() + cyc_kwh.sum())
                                      / max(1e-9, flex_kwh.sum() + cyc_kwh.sum() + base_kwh.sum())), 3),
    }
    return out, flex_daily_kwh, cycles, stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", help="comma-separated ResStock building IDs")
    ap.add_argument("--state", default="MA", help="two-letter state used in the S3 path")
    ap.add_argument("--local", help="directory of already-downloaded <id>-0.parquet files")
    ap.add_argument("--days", required=True, help="YYYY-MM-DD:YYYY-MM-DD, inclusive")
    ap.add_argument("--out", default="profiles")
    ap.add_argument("--cache", default="demo/data/raw")
    args = ap.parse_args()

    day_from, day_to = args.days.split(":")
    # last quarter hour of the last day
    day_to_end = pd.Timestamp(day_to) + pd.Timedelta(days=1) - pd.Timedelta(minutes=15)

    if args.local:
        paths = sorted(os.path.join(args.local, f)
                       for f in os.listdir(args.local) if f.endswith(".parquet"))
        if not paths:
            raise SystemExit(f"no parquet files in {args.local}")
        ids = [os.path.basename(p).split("-")[0] for p in paths]
    elif args.ids:
        ids = [i.strip() for i in args.ids.split(",") if i.strip()]
        paths = []
        for bid in ids:
            p, _ = fetch(bid, args.state, args.cache)
            paths.append(p)
    else:
        raise SystemExit("pass either --ids or --local")

    os.makedirs(args.out, exist_ok=True)

    agents = []
    sources = []
    frames = {}
    flex_daily = {}
    all_cycles = {}

    for bid, path in zip(ids, paths):
        name = f"prosumer-{len(agents)}"  # anonymous name, in selection order
        print(f"[{name}] building {bid}")
        df = load_building(path, day_from, day_to_end)
        series, flex, cycles, stats = build_agent(df, name)
        all_cycles[name] = cycles
        stats["resstock_building_id"] = bid
        frames[name] = series
        flex_daily[name] = flex
        agents.append(stats)
        sources.append({
            "agent": name,
            "building_id": bid,
            "file": os.path.basename(path),
            "sha256": sha256(path),
            "rows_used": int(len(df)),
        })
        print(f"          generation {stats['generation_kwh_per_day']:>7} kWh/d  "
              f"base {stats['base_kwh_per_day']:>7} kWh/d  "
              f"flex {stats['flexible_kwh_per_day']:>7} kWh/d  "
              f"cycles {stats['cycle_kwh_per_day']:>6} kWh/d in {stats['cycles']} runs "
              f"({stats['flexible_share']:.0%} shiftable)")

    days = sorted({d.date().isoformat() for d in next(iter(frames.values())).index})  # days covered by the profiles
    n_expected = len(days) * SESSIONS
    for name, series in frames.items():
        if len(series) != n_expected:
            raise SystemExit(f"{name}: {len(series)} rows, expected {n_expected} "
                             f"({len(days)} days x {SESSIONS}). Gaps in the source?")
        series.to_parquet(os.path.join(args.out, f"{name}.parquet"))

    with open(os.path.join(args.out, "agents.json"), "w") as f:  # per-household stats and daily flexible energy
        json.dump({
            "sessions_per_day": SESSIONS,
            "days": days,
            "agents": agents,
            "flex_daily_kwh": {n: {str(k.date()): round(float(v), 4)
                                   for k, v in s.items()}
                               for n, s in flex_daily.items()},
        }, f, indent=1)

    with open(os.path.join(args.out, "cycles.json"), "w") as f:  # appliance cycles, read by the econ models
        json.dump({
            "step_minutes": 15,
            "days": days,
            "wash_dry_max_gap_hours": WASH_DRY_MAX_GAP / pd.Timedelta(hours=1),
            "agents": all_cycles,
        }, f, indent=1)

    community_gen = sum(a["generation_kwh_per_day"] for a in agents)
    community_load = sum(a["base_kwh_per_day"] + a["flexible_kwh_per_day"]
                         + a["cycle_kwh_per_day"] for a in agents)

    manifest = {  # provenance of the generated profiles
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "script": os.path.basename(__file__),
        "dataset": {
            "name": "End-Use Load Profiles for the U.S. Building Stock (ResStock)",
            "publisher": "NREL / U.S. Department of Energy",
            "landing_page": "https://data.openei.org/submissions/4520",
            "native_resolution_minutes": 15,
            "units_in_source": "kWh per interval",
            "timestamp_convention_in_source": "end of interval",
            "timezone_in_source": "Eastern Standard Time",
        },
        "parameters": {
            "state": args.state,
            "date_range": args.days,
            "building_ids": ids,
        },
        "transformations": [
            "timestamps shifted back 15 min to label the start of each interval",
            "kWh per interval converted to average kW (x4)",
            "end uses split into generation, inflexible, flexible and cycles",
            "flexible: water heating, pool and spa pumps; daily energy shiftable within the day up to flex_cap_kw",
            "cycles: dishwasher, washer and dryer runs, written to cycles.json with their power profile",
            "dryer cycles paired with a washer cycle of the same day when starting within 4 h",
        ],
        "community_totals_kwh_per_day": {
            "generation": round(community_gen, 1),
            "consumption": round(community_load, 1),
            "balance": "surplus" if community_gen > community_load else "deficit",
        },
        "sources": sources,
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)

    print()
    print(f"community: {community_gen:.1f} kWh/d generated vs "
          f"{community_load:.1f} kWh/d consumed  -> {manifest['community_totals_kwh_per_day']['balance']}")
    print(f"wrote {len(agents)} agent file(s), agents.json, cycles.json and manifest.json to {args.out}/")
    sellers = sum(1 for a in agents if a["has_pv"])
    print(f"{sellers} agent(s) with PV, {len(agents) - sellers} without")
    if sellers == 0:
        print("WARNING: no PV anywhere, so every agent will only ever buy, and the "
              "market will have nothing to clear internally.")


if __name__ == "__main__":
    main()
