# Shared code of the strategic study: loads the fixed profiles, cycles and prices of 1 to 4 July 2018
# (demo/data/profiles, demo/data/prices.json) and builds the Gurobi model of one household.
# Imported by solo.py, planner.py, equilibrium.py and the plotting scripts, not run on its own.
import json
import sys
from pathlib import Path

import gurobipy as gp
import numpy as np
import pandas as pd
from gurobipy import GRB

HERE = Path(__file__).resolve().parent  # demo/econ
DEMO = HERE.parent  # demo/
sys.path.insert(0, str(DEMO / "sim"))  # so we can import report_results
from report_results import session_prices  # the 3 pricing rules, same formulas as the contract  # noqa: E402

# experiment settings (those of the theory paper, adapted to the recorded data)
SETTINGS = {
    "start": "2018-07-01",  # first day
    "days": 4,  # 4 days in one block
    "step_h": 0.25,  # one session = 15 min
    "battery_kwh": 20.0,  # battery capacity
    "battery_kw": 5.0,  # max charge/discharge power
    "grid_kw": 5.0,  # connection limit
}


class Data:
    # loads profiles, cycles and prices for the 4 days
    def __init__(self, profiles=DEMO / "data" / "profiles", prices=DEMO / "data" / "prices.json",
                 settings=SETTINGS):
        self.cfg = dict(settings)  # copy, so callers can change it safely
        self.T = 96 * self.cfg["days"]  # total number of sessions (384)
        self.dt = self.cfg["step_h"]  # to go from kW to kWh
        start = pd.Timestamp(self.cfg["start"])
        dates = [(start + pd.Timedelta(days=i)).date().isoformat() for i in range(self.cfg["days"])]

        # ISO-NE prices: low = feed-in (wholesale), high = retail (wholesale + 12 c), already in the json
        feed = json.loads(Path(prices).read_text())
        self.low = np.concatenate([feed["prices"][d]["low"] for d in dates])  # glue the 4 days together
        self.high = np.concatenate([feed["prices"][d]["high"] for d in dates])
        self.dates = dates  # ISO dates of the 4 days

        cycles = json.loads((Path(profiles) / "cycles.json").read_text())["agents"]  # dishwasher etc cycles
        self.names = []  # prosumer-0 ... prosumer-9
        self.hh = {}  # name -> series of that household
        # sort by number, otherwise prosumer-10 comes before prosumer-2
        for path in sorted(Path(profiles).glob("prosumer-*.parquet"), key=lambda p: int(p.stem.split("-")[1])):
            df = pd.read_parquet(path)  # quarter-hour profile written by build_profiles.py
            df = df[df.index >= start].iloc[:self.T]  # keep only the 4 days (the file has 5)
            if len(df) < self.T:
                raise SystemExit(f"{path.name}: {len(df)} rows, need {self.T}")
            cyc = []
            for c in cycles.get(path.stem, []):
                day = (pd.Timestamp(c["date"]) - start).days  # day of the cycle, 0 to 3
                if 0 <= day < self.cfg["days"]:  # drop the cycles of 5 July
                    cyc.append({**c, "day": day})
            self.names.append(path.stem)
            self.hh[path.stem] = {
                "omega": df["omega_kw"].to_numpy(),  # PV
                "base": df["alpha_base_kw"].to_numpy(),  # base load, can't be moved
                "flex": df["flex_kw"].to_numpy(),  # observed hot water + pumps (we only keep the daily energy)
                "flex_cap": float(df["flex_cap_kw"].iloc[0]),  # max power of hot water + pumps
                "cycle_obs": df["cycle_kw"].to_numpy(),  # cycle consumption as recorded
                "cycles": cyc,
            }

    def observed_net(self, name):
        # net position of the raw curves, nothing optimised
        h = self.hh[name]
        return h["omega"] - h["base"] - h["flex"] - h["cycle_obs"]

    def grid_bill(self, net):
        # bill against the grid alone: sell at feed-in, buy at retail
        sell = np.clip(net, 0, None)  # kW sold
        buy = np.clip(-net, 0, None)  # kW bought
        return float(np.sum(self.high * buy - self.low * sell) * self.dt)


def add_household(m, data, name):
    # adds all physical constraints of one household to model m
    # everything is in kW, multiply by dt when we need kWh
    h = data.hh[name]
    T, dt, cfg = data.T, data.dt, data.cfg
    K, B, X = cfg["battery_kw"], cfg["battery_kwh"], cfg["grid_kw"]  # battery power, capacity, connection

    f = m.addVars(T, lb=0.0, ub=h["flex_cap"], name=f"{name}_flex")  # hot water + pumps power, capped
    k = m.addVars(T, lb=-K, ub=K, name=f"{name}_batt")  # battery, + = charge, - = discharge
    b = m.addVars(T, lb=0.0, ub=B, name=f"{name}_soc")  # stored energy
    s = m.addVars(T, lb=0.0, ub=X, name=f"{name}_sell")  # sale, max 5 kW
    d = m.addVars(T, lb=0.0, ub=X, name=f"{name}_buy")  # purchase, max 5 kW

    # cycle consumption at each step, depends on the chosen start time
    load = {t: gp.LinExpr() for t in range(T)}
    start_of, starts = {}, {}  # cycle id -> start time expression, start binaries
    for c in h["cycles"]:
        prof = c["profile_kw"]  # power of the cycle, quarter hour by quarter hour
        first = 96 * c["day"]  # first session of the cycle's day
        taus = [tau for tau in range(first, first + 96) if tau + len(prof) <= T]  # possible starts in the day
        z = m.addVars(taus, vtype=GRB.BINARY, name=f"{name}_{c['appliance']}_{c['day']}")  # z=1 if it starts at tau
        m.addConstr(z.sum() == 1)  # exactly one start
        start_of[c["id"]] = gp.quicksum(tau * z[tau] for tau in taus)  # start time (used for washer/dryer)
        starts[c["id"]] = z
        for tau in taus:
            for j, p in enumerate(prof):
                load[tau + j] += p * z[tau]  # if it starts at tau, the profile lands on tau, tau+1, ...
    for c in h["cycles"]:
        if c["after"] in start_of:
            # dryer after its washer, with at least the observed lag
            m.addConstr(start_of[c["id"]] >= start_of[c["after"]] + c["min_lag_steps"])

    for t in range(T):
        # balance: what comes in = what goes out, PV can't be thrown away
        m.addConstr(h["omega"][t] + d[t] == h["base"][t] + f[t] + load[t] + k[t] + s[t])
        # battery: stock = previous stock + what goes in, starts at 0
        m.addConstr(b[t] == (b[t - 1] if t > 0 else 0.0) + k[t] * dt)
    m.addConstr(b[T - 1] == 0.0)  # battery empty at the end
    for day in range(cfg["days"]):
        ts = range(96 * day, 96 * (day + 1))  # sessions of that day
        # hot water + pumps: same energy as in the data every day, but whenever we want
        m.addConstr(gp.quicksum(f[t] for t in ts) == float(sum(h["flex"][t] for t in ts)))

    # handles for objectives and readout
    return {"sell": s, "buy": d, "flex": f, "batt": k, "soc": b, "cycle_load": load, "starts": starts}


def values(v, T):
    # gets the solution of a variable over all steps
    return np.array([v[t].X for t in range(T)])


def schedule(hv, T):
    # schedule of one household after solving, to save it in json
    return {
        "sell_kw": values(hv["sell"], T),
        "buy_kw": values(hv["buy"], T),
        "flex_kw": values(hv["flex"], T),
        "batt_kw": values(hv["batt"], T),
        "soc_kwh": values(hv["soc"], T),
        "cycle_kw": np.array([hv["cycle_load"][t].getValue() for t in range(T)]),
    }


def new_model(gap=1e-6):
    # silent gurobi model with a very small gap (otherwise it stops too early on the MIPs)
    m = gp.Model()
    m.Params.OutputFlag = 0  # no solver log
    m.Params.MIPGap = gap  # relative optimality gap
    return m
