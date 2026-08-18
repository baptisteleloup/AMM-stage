"""
build_profiles.py — ResStock (EnergyPlus) -> the three series Fabi's solver needs.

Fabi's solve_horizon takes, per agent:
    omega[t]        gross on-site generation           (kW)
    alpha_base[t]   gross INFLEXIBLE consumption       (kW)
    alpha_flex[d]   flexible energy to serve in day d  (kWh)

and returns x_pos / x_neg, the netput. So this script does NOT compute netputs:
it prepares the solver's inputs and records where every number came from.

Input : ResStock End-Use Load Profiles, individual-building parquet, 15-min.
        https://data.openei.org/submissions/4520
Output: profiles/<agent>.parquet, agents.json, manifest.json

Usage:
    python build_profiles.py --ids 12345,67890 --state MA --days 2018-07-01:2018-07-07
    python build_profiles.py --local raw/ --days 2018-07-01:2018-07-07
"""

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

SESSIONS = 96
BASE_URL = ("https://oedi-data-lake.s3.amazonaws.com/nrel-pds-building-stock/"
            "end-use-load-profiles-for-us-building-stock/2024/"
            "resstock_amy2018_release_2/timeseries_individual_buildings/"
            "by_state/upgrade=0/state={state}/{bid}-0.parquet")

# End uses whose timing can be shifted without changing the service delivered.
# Thermal mass (building envelope, water tank) is the physical justification.
FLEXIBLE_PATTERNS = [
    r"\.cooling",
    r"\.heating",
    r"\.hot_water",
    r"\.water_systems",
]

# Explicitly NOT flexible even though the name may match above: fans and pumps
# follow the equipment they serve, and are already counted inside it.
FLEXIBLE_EXCLUDE = [
    r"_fans_pumps",
    r"\.total",
    r"\.net",
]

PV_PATTERNS = [r"\.pv\b", r"photovoltaic", r"\.pv_"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def matches(name, patterns):
    return any(re.search(p, name) for p in patterns)


def classify(columns):
    """Split ResStock electricity columns into pv / flexible / base."""
    elec = [c for c in columns
            if c.startswith("out.electricity.") and c.endswith("energy_consumption")]
    pv = [c for c in elec if matches(c, PV_PATTERNS)]
    flex = [c for c in elec
            if matches(c, FLEXIBLE_PATTERNS)
            and not matches(c, FLEXIBLE_EXCLUDE)
            and c not in pv]
    skip = set(pv) | set(flex)
    base = [c for c in elec
            if c not in skip and not matches(c, [r"\.total", r"\.net"])]
    return pv, flex, base


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


def load_building(path, day_from, day_to):
    df = pd.read_parquet(path)
    tcol = "timestamp" if "timestamp" in df.columns else df.columns[0]
    df[tcol] = pd.to_datetime(df[tcol])
    df = df.set_index(tcol).sort_index()

    # ResStock stamps the END of each 15-minute interval: "12:15" is the energy
    # used between 12:00 and 12:15. Shift back so the index labels the START,
    # which is what every downstream calculation assumes.
    df.index = df.index - pd.Timedelta(minutes=15)

    df = df.loc[day_from:day_to]
    if len(df) == 0:
        raise SystemExit(f"no rows in {day_from}..{day_to} for {path}")
    return df


def build_agent(df, name):
    pv_cols, flex_cols, base_cols = classify(df.columns)

    # kWh per 15-min interval -> kW (average power over the interval).
    to_kw = 4.0

    pv_kwh = df[pv_cols].sum(axis=1) if pv_cols else pd.Series(0.0, index=df.index)
    flex_kwh = df[flex_cols].sum(axis=1) if flex_cols else pd.Series(0.0, index=df.index)
    base_kwh = df[base_cols].sum(axis=1) if base_cols else pd.Series(0.0, index=df.index)

    # ResStock reports PV as consumption, i.e. negative. Generation is positive
    # for the solver, so take the magnitude and record the sign convention seen.
    pv_sign = "negative" if float(pv_kwh.sum()) < 0 else "positive"
    omega_kw = pv_kwh.abs() * to_kw

    alpha_base_kw = base_kwh * to_kw
    flex_daily_kwh = flex_kwh.groupby(flex_kwh.index.normalize()).sum()

    out = pd.DataFrame({
        "omega_kw": omega_kw.values,
        "alpha_base_kw": alpha_base_kw.values,
        "flex_kw": flex_kwh.values * to_kw,
    }, index=df.index)

    stats = {
        "name": name,
        "pv_columns": pv_cols,
        "flexible_columns": flex_cols,
        "base_columns_count": len(base_cols),
        "pv_sign_convention": pv_sign,
        "has_pv": bool(pv_cols) and float(pv_kwh.abs().sum()) > 0,
        "generation_kwh_per_day": round(float(omega_kw.sum() / to_kw) / max(1, len(flex_daily_kwh)), 2),
        "base_kwh_per_day": round(float(base_kwh.sum()) / max(1, len(flex_daily_kwh)), 2),
        "flexible_kwh_per_day": round(float(flex_kwh.sum()) / max(1, len(flex_daily_kwh)), 2),
        "flexible_share": round(float(flex_kwh.sum() / max(1e-9, flex_kwh.sum() + base_kwh.sum())), 3),
    }
    return out, flex_daily_kwh, stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", help="comma-separated ResStock building IDs")
    ap.add_argument("--state", default="MA", help="two-letter state used in the S3 path")
    ap.add_argument("--local", help="directory of already-downloaded <id>-0.parquet files")
    ap.add_argument("--days", required=True, help="YYYY-MM-DD:YYYY-MM-DD, inclusive")
    ap.add_argument("--out", default="profiles")
    ap.add_argument("--cache", default="raw")
    args = ap.parse_args()

    day_from, day_to = args.days.split(":")
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

    for bid, path in zip(ids, paths):
        name = f"prosumer-{len(agents)}"
        print(f"[{name}] building {bid}")
        df = load_building(path, day_from, day_to_end)
        series, flex, stats = build_agent(df, name)
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
              f"flex {stats['flexible_kwh_per_day']:>7} kWh/d "
              f"({stats['flexible_share']:.0%})")

    days = sorted({d.date().isoformat() for d in next(iter(frames.values())).index})
    n_expected = len(days) * SESSIONS
    for name, series in frames.items():
        if len(series) != n_expected:
            raise SystemExit(f"{name}: {len(series)} rows, expected {n_expected} "
                             f"({len(days)} days x {SESSIONS}). Gaps in the source?")
        series.to_parquet(os.path.join(args.out, f"{name}.parquet"))

    with open(os.path.join(args.out, "agents.json"), "w") as f:
        json.dump({
            "sessions_per_day": SESSIONS,
            "days": days,
            "agents": agents,
            "flex_daily_kwh": {n: {str(k.date()): round(float(v), 4)
                                   for k, v in s.items()}
                               for n, s in flex_daily.items()},
        }, f, indent=1)

    community_gen = sum(a["generation_kwh_per_day"] for a in agents)
    community_load = sum(a["base_kwh_per_day"] + a["flexible_kwh_per_day"] for a in agents)

    manifest = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "script": os.path.basename(__file__),
        "dataset": {
            "name": "End-Use Load Profiles for the U.S. Building Stock (ResStock)",
            "publisher": "NREL / U.S. Department of Energy",
            "landing_page": "https://data.openei.org/submissions/4520",
            "engine": "EnergyPlus (via OpenStudio-HPXML)",
            "native_resolution_minutes": 15,
            "units_in_source": "kWh per interval",
            "timestamp_convention_in_source": "end of interval",
            "timezone_in_source": "Eastern Standard Time",
        },
        "transformations": [
            "timestamps shifted back 15 min so the index labels the START of each interval",
            "kWh per interval converted to average kW by multiplying by 4",
            "electricity end uses split into generation / flexible / inflexible",
            "flexible = cooling, heating, hot water; fans and pumps excluded as "
            "they are already accounted for inside the equipment they serve",
            "flexible load aggregated to one energy figure per day, as the solver expects",
        ],
        "selection": {
            "note": "PV penetration in the ResStock baseline reflects the real US "
                    "stock, so a seller/buyer mix is obtained by FILTERING on "
                    "building characteristics, not by random sampling. This is a "
                    "composition choice and must be declared as such.",
            "state": args.state,
            "date_range": args.days,
            "building_ids": ids,
        },
        "known_limitations": [
            "ResStock does not size PV to the dwelling's own consumption, so an "
            "oversized array can produce large net surplus; NREL warns that "
            "PV-equipped units may skew distributional analysis",
            "PV is assigned only to single-family detached units, capped at 14 kW DC",
            "US building stock and US weather; a French collective self-consumption "
            "case is not represented",
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
    print(f"wrote {len(agents)} agent file(s), agents.json and manifest.json to {args.out}/")
    sellers = sum(1 for a in agents if a["has_pv"])
    print(f"{sellers} agent(s) with PV, {len(agents) - sellers} without")
    if sellers == 0:
        print("WARNING: no PV anywhere — every agent will only ever buy, and the "
              "market will have nothing to clear internally.")


if __name__ == "__main__":
    main()
