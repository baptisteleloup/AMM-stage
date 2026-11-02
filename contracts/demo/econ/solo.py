# baseline: each household optimises alone against the grid, no community
import argparse
import json

import numpy as np
from gurobipy import GRB, quicksum

from common import HERE, Data, add_household, new_model, schedule

ap = argparse.ArgumentParser()
ap.add_argument("--out", default=str(HERE / "out" / "solo.json"))
args = ap.parse_args()

data = Data()
T, dt = data.T, data.dt
rows, schedules = [], {}

for name in data.names:
    m = new_model()  # one model per household, they are independent
    hv = add_household(m, data, name)
    # grid bill: buy at retail - sell at feed-in
    m.setObjective(quicksum((data.high[t] * hv["buy"][t] - data.low[t] * hv["sell"][t]) * dt
                            for t in range(T)), GRB.MINIMIZE)
    m.optimize()
    if m.Status != GRB.OPTIMAL:
        raise SystemExit(f"{name}: solver status {m.Status}")
    sch = schedule(hv, T)
    net = sch["sell_kw"] - sch["buy_kw"]  # net position
    h = data.hh[name]
    # check: the energy balance should be exact (error ~1e-14)
    energy_gap = np.abs(h["omega"] + sch["buy_kw"] - h["base"] - sch["flex_kw"]
                        - sch["cycle_kw"] - sch["batt_kw"] - sch["sell_kw"]).max()
    raw = data.grid_bill(data.observed_net(name))  # raw curves bill, should match the demo without optimisation
    opt = data.grid_bill(net)  # optimised bill
    # cycled = energy through the battery (charge + discharge) / 2
    rows.append((name, raw, opt, raw - opt, sch["soc_kwh"].max(),
                 np.abs(sch["batt_kw"]).sum() * dt / 2, energy_gap))
    schedules[name] = {k: v.round(6).tolist() for k, v in sch.items()}

print(f"{'household':12} {'raw bill':>10} {'solo bill':>10} {'saving':>9} {'max soc':>8} {'cycled':>8} {'balance err':>12}")
for r in rows:
    print(f"{r[0]:12} {r[1]:10.2f} {r[2]:10.2f} {r[3]:9.2f} {r[4]:8.2f} {r[5]:8.2f} {r[6]:12.1e}")
tot_raw = sum(r[1] for r in rows)
tot_opt = sum(r[2] for r in rows)
print(f"{'community':12} {tot_raw:10.2f} {tot_opt:10.2f} {tot_raw - tot_opt:9.2f}")
print("bills in USD over the period, a negative bill is a net income; "
      "max soc in kWh; cycled = energy through the battery in kWh")

# save everything, planner and equilibrium read this file back
out = {"settings": data.cfg, "dates": data.dates, "objective": "each household alone against the grid",
       "bills": {r[0]: {"raw": r[1], "solo": r[2]} for r in rows}, "schedules": schedules}
HERE.joinpath("out").mkdir(exist_ok=True)
with open(args.out, "w") as f:
    json.dump(out, f)
print(f"wrote {args.out}")
