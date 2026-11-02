# Pure Nash equilibrium of the households under one pricing rule, by iterated best responses (Gurobi,
# revenue as a broken line), then a check pass that gives the certificate epsilon.
# Reads out/solo.json (and out/planner.json or --from), writes out/nash_<rule>[_from_<init>].json or out/<tag>.json.
# Run from contracts/: python demo/econ/equilibrium.py --rule mmr [--init planner] [--points 201] ...
import argparse
import json
import time
from pathlib import Path

import numpy as np
from gurobipy import GRB

from common import HERE, Data, add_household, new_model, schedule, session_prices

ap = argparse.ArgumentParser()
ap.add_argument("--rule", choices=("mmr", "sdr", "hyperbolic"), required=True)
ap.add_argument("--points", type=int, default=201)  # number of points of the broken line
ap.add_argument("--tol", type=float, default=1e-4)  # min gain for a household to switch schedule
ap.add_argument("--max-passes", type=int, default=60)  # 0 = only the final check
ap.add_argument("--solo", default=str(HERE / "out" / "solo.json"))
ap.add_argument("--init", choices=("solo", "planner", "mix", "file"), default="solo")  # starting point
ap.add_argument("--from", dest="from_file", default=None)  # with --init file: json with the starting schedules
# with --init mix: chance each household starts from its planner schedule
ap.add_argument("--mix-p", type=float, default=0.5)
ap.add_argument("--perturb", type=int, default=0)  # put this many random households back on their solo schedule
ap.add_argument("--shuffle", action="store_true")  # random order of the households at each pass
ap.add_argument("--seed", type=int, default=0)  # for mix, perturb and shuffle
ap.add_argument("--tag", default=None)  # output = out/<tag>.json (default: nash_<rule>.json as before)
args = ap.parse_args()
rng = np.random.default_rng(args.seed)  # reproducible random starts and orders

data = Data()
T, dt, X = data.T, data.dt, data.cfg["grid_kw"]
names = data.names
idx = {n: i for i, n in enumerate(names)}  # name -> row of q
solo = json.loads(open(args.solo).read())  # solo bills and schedules


def load_schedules(path):
    return json.loads(Path(path).read_text())["schedules"]  # schedules of a saved run


# starting schedule of each household (always feasible: it is one of its real schedules)
start = {}
if args.init == "solo":
    start = dict(solo["schedules"])
elif args.init == "planner":
    start = load_schedules(HERE / "out" / "planner.json")
elif args.init == "file":
    start = load_schedules(args.from_file)  # e.g. an equilibrium already found
else:  # mix: each household starts from its planner schedule with prob mix_p, else from its solo one
    plan = load_schedules(HERE / "out" / "planner.json")
    start = {n: (plan[n] if rng.random() < args.mix_p else solo["schedules"][n]) for n in names}
perturbed = []
if args.perturb > 0:
    # kick a few households off: they go back to their solo schedule (used for the stability test)
    perturbed = sorted(rng.choice(len(names), size=min(args.perturb, len(names)), replace=False).tolist())
    for i in perturbed:
        start[names[i]] = solo["schedules"][names[i]]
init = {"schedules": start}
# q = net positions of everyone (households x sessions), + = sells, - = buys
q = np.array([np.array(init["schedules"][n]["sell_kw"]) - np.array(init["schedules"][n]["buy_kw"])
              for n in names])


def payments(q):
    # exact payment of each household with the real formulas
    sell, buy = np.clip(q, 0, None), np.clip(-q, 0, None)
    r, c, _ = session_prices(sell.sum(0), buy.sum(0), data.low, data.high, args.rule)  # session prices of the profile
    return (buy * c - sell * r).sum(axis=1) * dt  # USD per household, + = pays


def revenue_curve(i, t, xs):
    # exact revenue of household i in session t for each position xs, the others being fixed
    others = np.delete(q[:, t], i)  # positions of the others in session t
    S = np.clip(others, 0, None).sum() + np.clip(xs, 0, None)  # total supply if the household plays xs
    D = np.clip(-others, 0, None).sum() + np.clip(-xs, 0, None)  # total demand
    r, c, _ = session_prices(S, D, np.full_like(xs, data.low[t]), np.full_like(xs, data.high[t]), args.rule)
    return (r * np.clip(xs, 0, None) - c * np.clip(-xs, 0, None)) * dt


def best_response(name):
    # best schedule of the household against the current schedules of the others
    i = idx[name]
    m = new_model()
    hv = add_household(m, data, name)
    qv = m.addVars(T, lb=-X, ub=X, name="net")  # net position
    for t in range(T):
        m.addConstr(qv[t] == hv["sell"][t] - hv["buy"][t])
    m.ModelSense = GRB.MAXIMIZE
    base = np.linspace(-X, X, args.points)  # 201 points between -5 and 5 kW
    for t in range(T):
        others = np.delete(q[:, t], i)
        # position where the session balances, the formula changes regime there so we add that point
        kink = np.clip(-others, 0, None).sum() - np.clip(others, 0, None).sum()
        xs = np.unique(np.concatenate([base, [0.0], [kink] if -X < kink < X else []]))
        m.setPWLObj(qv[t], xs.tolist(), revenue_curve(i, t, xs).tolist())  # gurobi joins the points
    m.optimize()
    if m.SolCount == 0:
        raise SystemExit(f"{name}: solver status {m.Status}")
    sch = schedule(hv, T)
    return sch["sell_kw"] - sch["buy_kw"], sch, m.ObjVal  # net position, schedule, approximate revenue


def own_value(i, qi):
    # what household i earns if it plays qi and the others stay the same (exact formula)
    trial = q.copy()
    trial[i] = qi
    return -payments(trial)[i]


schedules = {n: {k: np.array(v) for k, v in init["schedules"][n].items()} for n in names}
print(f"start from {args.init}: community bill {payments(q).sum():.4f} USD")
t0 = time.time()
converged = False  # set when a pass moves nobody
p = 0  # number of passes done (stays 0 with --max-passes 0, i.e. only the final check)
for p in range(1, args.max_passes + 1):
    moved, best_gain, pwl_err = 0, 0.0, 0.0
    order = list(rng.permutation(names)) if args.shuffle else names  # who plays first this pass
    for n in order:  # each one in turn
        i = idx[n]
        q_br, sch, obj = best_response(n)
        gain = own_value(i, q_br) - own_value(i, q[i])  # exact gain if it switches
        # gap between the broken line and the real revenue, to check the approximation
        pwl_err = max(pwl_err, abs(obj + payments(np.vstack([q[:i], q_br, q[i + 1:]]))[i]))
        best_gain = max(best_gain, gain)
        if gain > args.tol:  # only switches if it's worth it
            q[i] = q_br
            schedules[n] = sch
            moved += 1
    pay = payments(q)
    print(f"pass {p:2}: {moved} household(s) moved, largest gain {best_gain:.5f} USD, "
          f"community bill {pay.sum():.4f}, pwl error {pwl_err:.1e}, {time.time() - t0:.0f} s", flush=True)
    if moved == 0:  # nobody moved = equilibrium
        converged = True
        break

# check pass: move nothing, just look at what each one could still gain -> epsilon
regret = {}
for n in names:
    i = idx[n]
    q_br, _, _ = best_response(n)
    regret[n] = max(0.0, own_value(i, q_br) - own_value(i, q[i]))
epsilon = max(regret.values())  # largest gain from deviating, reported in the paper

pay = payments(q)  # final payments
sell, buy = np.clip(q, 0, None), np.clip(-q, 0, None)
matched = float(np.minimum(sell.sum(0), buy.sum(0)).sum() * dt)  # local trade
status = "check only, no passes" if args.max_passes == 0 else ("converged" if converged else "NOT converged")
print(f"\nnash under {args.rule}: {status}")
print(f"certificate on the final schedules: no household can gain more than {epsilon:.5f} USD "
      f"by deviating (largest regret: {max(regret, key=regret.get)})")
print(f"community bill {pay.sum():.2f} USD (solo {sum(solo['bills'][n]['solo'] for n in names):.2f}), "
      f"matched {matched:.1f} kWh")
print(f"{'household':12} {'solo':>8} {'eq.':>8} {'gain':>8}")
for n in names:
    s0 = solo["bills"][n]["solo"]
    print(f"{n:12} {s0:8.2f} {pay[idx[n]]:8.2f} {s0 - pay[idx[n]]:8.2f}")

out = {"rule": args.rule, "init": args.init, "from": args.from_file, "mix_p": args.mix_p,
       "perturbed": [names[i] for i in perturbed], "shuffle": args.shuffle, "seed": args.seed,
       "converged": converged, "epsilon_usd": epsilon,
       "regret_usd": regret, "passes": p,
       "points": args.points, "community_bill": float(pay.sum()), "matched_kwh": matched,
       "payments": {n: float(pay[idx[n]]) for n in names},
       "schedules": {n: {k: np.asarray(v).round(6).tolist() for k, v in schedules[n].items()} for n in names}}
if args.tag:
    path = HERE / "out" / f"{args.tag}.json"  # campaign runs: out/ms, out/stab, out/cert
else:
    suffix = "" if args.init == "solo" else f"_from_{args.init}"  # so it doesn't overwrite the run from solo
    path = HERE / "out" / f"nash_{args.rule}{suffix}.json"
path.parent.mkdir(parents=True, exist_ok=True)
with open(path, "w") as f:
    json.dump(out, f)
print(f"wrote {path}")
