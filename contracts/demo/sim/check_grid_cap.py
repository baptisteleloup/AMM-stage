import argparse
import json
from pathlib import Path

import gurobipy as gp
import pandas as pd
from gurobipy import GRB

HERE = Path(__file__).resolve().parent
PROFILES = HERE.parent / "data" / "profiles"

ap = argparse.ArgumentParser()
ap.add_argument("--profiles", type=Path, default=PROFILES)
ap.add_argument("--start", default="2018-07-01")
ap.add_argument("--days", type=int, default=4)
ap.add_argument("--battery-kwh", type=float, default=20.0)
ap.add_argument("--battery-kw", type=float, default=5.0)
ap.add_argument("--step-h", type=float, default=0.25)
args = ap.parse_args()

T = 96 * args.days
dt = args.step_h
B, K = args.battery_kwh, args.battery_kw
start = pd.Timestamp(args.start)
cycles_all = json.loads((args.profiles / "cycles.json").read_text())["agents"]


def window(df):
    idx = df.index
    s = start.tz_localize(idx.tz) if idx.tz is not None else start
    out = df[idx >= s].iloc[:T]
    if len(out) < T:
        raise SystemExit(f"only {len(out)} rows after {args.start}, need {T}")
    return out


def in_horizon(cycles):
    kept = []
    for c in cycles:
        day = (pd.Timestamp(c["date"]) - start).days
        if 0 <= day < args.days:
            kept.append({**c, "day": day})
    return kept


def min_cap(df, cycles):
    omega = df["omega_kw"].to_numpy()
    base = df["alpha_base_kw"].to_numpy()
    flex = df["flex_kw"].to_numpy()
    cap = float(df["flex_cap_kw"].iloc[0])

    m = gp.Model()
    m.Params.OutputFlag = 0
    X = m.addVar(lb=0.0)
    f = m.addVars(T, lb=0.0, ub=cap)
    k = m.addVars(T, lb=-K, ub=K)
    b = m.addVars(T, lb=0.0, ub=B)
    s = m.addVars(T, lb=0.0)
    d = m.addVars(T, lb=0.0)

    load = {t: gp.LinExpr() for t in range(T)}
    start_of = {}
    for c in cycles:
        prof = c["profile_kw"]
        L = len(prof)
        first = 96 * c["day"]
        taus = [tau for tau in range(first, first + 96) if tau + L <= T]
        z = m.addVars(taus, vtype=GRB.BINARY)
        m.addConstr(z.sum() == 1)
        start_of[c["id"]] = gp.quicksum(tau * z[tau] for tau in taus)
        for tau in taus:
            for j, p in enumerate(prof):
                load[tau + j] += p * z[tau]
    for c in cycles:
        if c["after"] in start_of:
            m.addConstr(start_of[c["id"]] >= start_of[c["after"]] + c["min_lag_steps"])

    for t in range(T):
        m.addConstr(omega[t] + d[t] == base[t] + f[t] + load[t] + k[t] + s[t])
        m.addConstr(b[t] == (b[t - 1] if t > 0 else 0.0) + k[t] * dt)
        m.addConstr(s[t] <= X)
        m.addConstr(d[t] <= X)
    m.addConstr(b[T - 1] == 0.0)
    for day in range(args.days):
        ts = range(96 * day, 96 * (day + 1))
        m.addConstr(gp.quicksum(f[t] for t in ts) == sum(flex[t] for t in ts))
    m.setObjective(X, GRB.MINIMIZE)
    m.optimize()
    if m.Status != GRB.OPTIMAL:
        return None
    return X.X


rows = []
for path in sorted(args.profiles.glob("prosumer-*.parquet")):
    name = path.stem
    df = window(pd.read_parquet(path))
    cycles = in_horizon(cycles_all.get(name, []))
    rows.append({
        "household": name,
        "max_base_kw": df["alpha_base_kw"].max(),
        "flex_kwh_per_day": df["flex_kw"].sum() * dt / args.days,
        "flex_cap_kw": float(df["flex_cap_kw"].iloc[0]),
        "cycles": len(cycles),
        "cycle_kwh_per_day": sum(c["energy_kwh"] for c in cycles) / args.days,
        "max_cycle_kw": max((max(c["profile_kw"]) for c in cycles), default=0.0),
        "min_cap_kw": min_cap(df, cycles),
    })

res = pd.DataFrame(rows).set_index("household")
pd.set_option("display.float_format", "{:.2f}".format)
pd.set_option("display.width", 200)
pd.set_option("display.max_columns", None)
print(res)
caps = res["min_cap_kw"].dropna()
if len(caps) < len(res):
    print("\nsome households are infeasible at any cap, check the data")
print(f"\nsmallest common cap: {caps.max():.2f} kW")
print(json.dumps({"battery_kwh": B, "battery_kw": K, "days": args.days, "start": args.start}))
