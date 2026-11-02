# Social planner: one model with the 10 households that minimises the community's grid bill,
# then the payment of each household under the three rules on that allocation.
# Reads out/solo.json, writes out/planner.json. Run from contracts/: python demo/econ/planner.py [--solo PATH] [--out PATH]
import argparse
import json

import numpy as np
from gurobipy import GRB, quicksum

from common import HERE, Data, add_household, new_model, schedule, session_prices

ap = argparse.ArgumentParser()
ap.add_argument("--solo", default=str(HERE / "out" / "solo.json"))
ap.add_argument("--out", default=str(HERE / "out" / "planner.json"))
args = ap.parse_args()

data = Data()
T, dt = data.T, data.dt
solo = json.loads(open(args.solo).read())["bills"]  # grid-alone bills, to compare

m = new_model()  # one model for the whole community
m.Params.TimeLimit = 1800  # 30 min max just in case
hv = {name: add_household(m, data, name) for name in data.names}  # the 10 households in the same model
g_out = m.addVars(T, lb=0.0, name="grid_export")  # what the community sells to the grid
g_in = m.addVars(T, lb=0.0, name="grid_import")  # what it buys from the grid
for t in range(T):
    # one meter: what a household sells and a neighbour buys cancels out here
    m.addConstr(g_out[t] - g_in[t] == quicksum(hv[n]["sell"][t] - hv[n]["buy"][t] for n in data.names))

cost = quicksum((data.high[t] * g_in[t] - data.low[t] * g_out[t]) * dt for t in range(T))  # community bill
exchange = quicksum((hv[n]["sell"][t] + hv[n]["buy"][t]) * dt for n in data.names for t in range(T))  # energy exchanged
m.ModelSense = GRB.MINIMIZE
# objective 1 (first) = cost, objective 2 = among the optimal ones, least exchange (removes pointless trades)
m.setObjectiveN(cost, index=0, priority=2, name="community_grid_cost")
m.setObjectiveN(exchange, index=1, priority=1, name="household_exchange")
m.optimize()
if m.SolCount == 0:
    raise SystemExit(f"no solution, solver status {m.Status}")
m.Params.ObjNumber = 0  # to read the value of objective 1
print(f"solver status {m.Status} (2 = optimal, 9 = time limit), cost {m.ObjNVal:.4f} USD")

sch = {n: schedule(hv[n], T) for n in data.names}  # optimal schedules
sell = np.array([sch[n]["sell_kw"] for n in data.names])  # households x sessions
buy = np.array([sch[n]["buy_kw"] for n in data.names])
S, D = sell.sum(axis=0), buy.sum(axis=0)  # total supply and demand per session
net = S - D  # community position, + = exports to the grid
community_bill = float(np.sum(data.high * np.clip(-net, 0, None) - data.low * np.clip(net, 0, None)) * dt)  # 68.03 USD in the paper
matched = float(np.minimum(S, D).sum() * dt)  # energy traded locally
solo_total = sum(solo[n]["solo"] for n in data.names)  # everyone optimised alone
raw_total = sum(solo[n]["raw"] for n in data.names)  # recorded curves, nothing optimised

print(f"\ncommunity bill: raw {raw_total:.2f}, solo {solo_total:.2f}, planner {community_bill:.2f} USD")
print(f"gain of the planner over solo: {solo_total - community_bill:.2f} USD")
print(f"matched locally: {matched:.1f} kWh out of {D.sum() * dt:.1f} kWh bought by households")
both = int(((sell > 1e-6) & (buy > 1e-6)).sum())  # check: nobody sells and buys at the same time
print(f"household-steps selling and buying at once: {both}")

out = {"settings": data.cfg, "dates": data.dates, "community_bill": community_bill,
       "solo_total": solo_total, "raw_total": raw_total, "matched_kwh": matched, "rules": {},
       "schedules": {n: {k: v.round(6).tolist() for k, v in sch[n].items()} for n in data.names}}

# afterwards: how much each household would pay with the AMM prices on this allocation
for rule in ("mmr", "sdr", "hyperbolic"):
    r, c, _ = session_prices(S, D, data.low, data.high, rule)  # seller price r and buyer price c per session
    pay = (buy * c - sell * r).sum(axis=1) * dt  # payment of each household
    # the sum should give back the community bill (budget balance)
    print(f"\n{rule}: payments sum to {pay.sum():.4f} USD (community bill {community_bill:.4f})")
    print(f"  {'household':12} {'solo':>8} {'planner':>8} {'gain':>8}")
    worse = 0
    for i, n in enumerate(data.names):
        gain = solo[n]["solo"] - pay[i]
        worse += gain < -1e-9  # households worse off than alone
        print(f"  {n:12} {solo[n]['solo']:8.2f} {pay[i]:8.2f} {gain:8.2f}")
    print(f"  households worse off than alone: {worse}")
    out["rules"][rule] = {n: float(pay[i]) for i, n in enumerate(data.names)}

with open(args.out, "w") as f:
    json.dump(out, f)
print(f"\nwrote {args.out}")
