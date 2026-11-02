import argparse
import json
import re
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "data"

ap = argparse.ArgumentParser()
ap.add_argument("--agents", type=Path, default=DATA / "profiles" / "agents.json")
ap.add_argument("--raw", type=Path, default=DATA / "raw")
ap.add_argument("--start", default="2018-07-01")
ap.add_argument("--days", type=int, default=4)
args = ap.parse_args()

FLEX = [r"\.cooling", r"\.heating", r"\.hot_water", r"\.water_systems"]
EXCLUDE = [r"_fans_pumps", r"\.total", r"\.net"]
PV = [r"\.pv\b", r"photovoltaic", r"\.pv_"]


def matches(name, patterns):
    return any(re.search(p, name) for p in patterns)


def label(col):
    if matches(col, PV):
        return "pv"
    if matches(col, FLEX) and not matches(col, EXCLUDE):
        return "FLEX"
    return "base"


agents = json.loads(args.agents.read_text())["agents"]
start = pd.Timestamp(args.start)
end = start + pd.Timedelta(days=args.days) - pd.Timedelta(minutes=15)

table = {}
for a in agents:
    path = args.raw / f"{a['resstock_building_id']}-0.parquet"
    df = pd.read_parquet(path)
    tcol = "timestamp" if "timestamp" in df.columns else df.columns[0]
    df[tcol] = pd.to_datetime(df[tcol])
    df = df.set_index(tcol).sort_index()
    df.index = df.index - pd.Timedelta(minutes=15)
    df = df.loc[start:end]
    cols = [c for c in df.columns
            if c.startswith("out.electricity.") and c.endswith("energy_consumption")
            and not matches(c, [r"\.total", r"\.net"])]
    per_day = df[cols].sum() / args.days
    table[a["name"]] = per_day

res = pd.DataFrame(table).fillna(0.0)
res = res[(res.abs() > 0.05).any(axis=1)]
res.index = [f"{label(c):4} {c.removeprefix('out.electricity.').removesuffix('.energy_consumption')}"
             for c in res.index]
res = res.sort_index()

pd.set_option("display.width", 250)
pd.set_option("display.max_columns", None)
pd.set_option("display.max_rows", None)
pd.set_option("display.float_format", "{:.1f}".format)
print(f"kWh per day, {args.start} + {args.days} days, end uses above 0.05 kWh/day")
print(res)
