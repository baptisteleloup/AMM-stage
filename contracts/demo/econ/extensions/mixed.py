# Extension, outside the paper: mixed-strategy Nash equilibrium of the households by double oracle.
# Each household mixes over a bank of schedules (fictitious play), Gurobi adds better schedules from
# outside the banks until none exists. Reads ../out/nash_<rule>*.json and ../out/solo.json, writes out/mixed_<rule>.json.
# Run from contracts/: python demo/econ/extensions/mixed.py --rule sdr [--outer 15] [--resume] ...
import argparse
import itertools
import json
import sys
import time
from pathlib import Path

import numpy as np
from gurobipy import GRB

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # demo/econ, where common.py lives
from common import HERE, Data, add_household, new_model, schedule, session_prices  # noqa: E402

EXT = Path(__file__).resolve().parent  # demo/econ/extensions

ap = argparse.ArgumentParser()
ap.add_argument("--rule", choices=("mmr", "sdr", "hyperbolic"), required=True)
ap.add_argument("--points", type=int, default=201)  # points of the broken line in a best response
ap.add_argument("--tol", type=float, default=1e-4)  # min gain (USD) to add a schedule to a bank
ap.add_argument("--outer", type=int, default=15)  # max rounds of the double oracle
ap.add_argument("--fp-iters", type=int, default=500)  # fictitious play iterations on the banks
ap.add_argument("--fp-samples", type=int, default=500)  # draws of the others inside fictitious play
ap.add_argument("--max-exact", type=int, default=2000)  # above this many profiles of the others, sample them
ap.add_argument("--seed", type=int, default=0)
ap.add_argument("--resume", action="store_true")  # start from the banks and probabilities of out/mixed_<rule>.json
args = ap.parse_args()

rng = np.random.default_rng(args.seed)  # fixed seed so the random draws are reproducible
data = Data()  # profiles, cycles and prices of the 4 days
T, dt, X = data.T, data.dt, data.cfg["grid_kw"]  # 384 sessions, 0.25 h, 5 kW connection
names = data.names
N = len(names)  # 10 households

# starting banks: the schedules of the pure Nash equilibria already computed
# (one from the grid-alone start, one from the planner start, so 1 or 2 schedules per household)
banks = [[] for _ in names]  # banks[n] = list of schedules (dicts of arrays)
for fname in (f"nash_{args.rule}.json", f"nash_{args.rule}_from_planner.json"):
    path = HERE / "out" / fname
    if path.exists():
        run = json.loads(path.read_text())
        for i, n in enumerate(names):
            banks[i].append({k: np.array(v) for k, v in run["schedules"][n].items()})


def net(sch):
    # net position of a schedule: + = sells, - = buys. this is all the market sees
    return sch["sell_kw"] - sch["buy_kw"]


def dedupe(bank):
    # drop schedules with the same net position, only q matters for the market
    # (if both pure equilibria gave the same schedule, keep it once)
    out = []
    for s in bank:
        if not any(np.allclose(net(s), net(o), atol=1e-6) for o in out):
            out.append(s)
    return out


banks = [dedupe(b) for b in banks]
sigma = [np.ones(len(b)) / len(b) for b in banks]  # sigma[n] = probabilities on the bank of n, start uniform
if args.resume:
    # pick up a previous run where it stopped (same banks, same probabilities)
    prev = json.loads((EXT / "out" / f"mixed_{args.rule}.json").read_text())
    banks = [[{k: np.array(v) for k, v in s.items()} for s in prev["banks"][n]] for n in names]
    sigma = [np.array(prev["sigma"][n]) for n in names]


def others(i, sigma, limit):
    # what the 9 OTHER households can do when they draw at random from their banks
    # returns, for each possible draw: its probability, and the supply S and demand D of the others in every session
    # if there are few combinations (<= limit) we list them all with their exact probability,
    # otherwise we draw `limit` combinations at random (each then has probability 1/limit)
    idx = [m for m in range(N) if m != i]  # the other households
    supp = [np.flatnonzero(sigma[m] > 1e-9) for m in idx]  # schedules they actually play (probability > 0)
    count = int(np.prod([len(s) for s in supp]))  # number of possible combinations of the others
    if count <= limit:
        grids = [g.ravel() for g in np.meshgrid(*supp, indexing="ij")]  # every combination
        probs = np.prod([sigma[m][g] for m, g in zip(idx, grids)], axis=0)  # probability of each one (product)
    else:
        grids = [rng.choice(len(sigma[m]), size=limit, p=sigma[m] / sigma[m].sum()) for m in idx]  # random draws
        probs = np.full(limit, 1.0 / limit)
    S = np.zeros((len(probs), T))  # supply of the others, draws x sessions
    D = np.zeros((len(probs), T))  # demand of the others
    for m, g in zip(idx, grids):
        Q = np.array([net(s) for s in banks[m]])[g]  # net positions of household m in each draw
        S += np.clip(Q, 0, None)  # positive part = selling
        D += np.clip(-Q, 0, None)  # negative part = buying
    return probs / probs.sum(), S, D


def expected_value(qi, probs, S, D):
    # expected revenue (minus the bill) of a household playing qi, when the others are drawn from (probs, S, D)
    # for each draw: add the household to the aggregates, compute the prices with the rule, compute its revenue
    # then average over the draws with their probabilities
    s_, d_ = np.clip(qi, 0, None), np.clip(-qi, 0, None)
    r, c, _ = session_prices(S + s_, D + d_, data.low, data.high, args.rule)
    return float(probs @ ((r * s_ - c * d_).sum(1) * dt))


def solve_bank_game(sigma):
    # fictitious play on the banks (Brown 1951)
    # at each iteration, every household looks at which schedule of its bank pays it most on average
    # against the others' current probabilities, and moves a bit of probability towards it
    # all households update at the same time, so they adapt to each other
    for it in range(1, args.fp_iters + 1):
        new = []
        for i in range(N):
            if len(banks[i]) == 1:  # only one schedule: nothing to choose, probability 1
                new.append(np.ones(1))
                continue
            probs, S, D = others(i, sigma, args.fp_samples)
            u = np.array([expected_value(net(s), probs, S, D) for s in banks[i]])  # mean revenue of each schedule
            br = np.zeros(len(u))
            br[np.argmax(u)] = 1.0  # "all on the best schedule" (e_k* in the paper)
            a = 1.0 / (it + 1)  # step gets smaller over time
            new.append((1 - a) * sigma[i] + a * br)  # mix old probabilities with "all on the best"
        sigma = new  # everyone updates at once
        if all(len(b) == 1 for b in banks):  # nobody has a choice: pure, stop
            break
    return sigma


def bank_regret(sigma):
    # how much each household could gain by switching to its best schedule in its bank
    # (only a check inside the banks, the real certificate is the best response over everything below)
    reg = []
    for i in range(N):
        probs, S, D = others(i, sigma, args.max_exact)
        u = np.array([expected_value(net(s), probs, S, D) for s in banks[i]])
        reg.append(float(u.max() - sigma[i] @ u))  # best schedule minus current mix
    return reg


def best_response(i, sigma):
    # best schedule over EVERYTHING (not only the bank) against the mixture of the others
    # same as the pure best response, but each session's revenue curve is the average over the others' draws
    probs, S, D = others(i, sigma, args.max_exact)
    m = new_model()
    hv = add_household(m, data, names[i])  # all physical constraints of the household
    qv = m.addVars(T, lb=-X, ub=X, name="net")  # net position, + sells, - buys
    for t in range(T):
        m.addConstr(qv[t] == hv["sell"][t] - hv["buy"][t])
    m.ModelSense = GRB.MAXIMIZE
    base = np.linspace(-X, X, args.points)  # 201 positions between -5 and 5 kW
    for t in range(T):
        kinks = np.unique(np.clip(D[:, t] - S[:, t], -X, X))[:50]  # balance points of the likely draws (formula changes there)
        xs = np.unique(np.concatenate([base, [0.0], kinks]))  # points of the broken line
        s_, d_ = np.clip(xs, 0, None), np.clip(-xs, 0, None)
        Sx = S[:, t][:, None] + s_[None, :]  # supply for every draw x every position of the household
        Dx = D[:, t][:, None] + d_[None, :]  # demand, same
        lo = np.full_like(Sx, data.low[t])
        hi = np.full_like(Sx, data.high[t])
        r, c, _ = session_prices(Sx, Dx, lo, hi, args.rule)  # prices for every draw and every position
        ys = probs @ ((r * s_[None, :] - c * d_[None, :]) * dt)  # expected revenue at each point (average over draws)
        m.setPWLObj(qv[t], xs.tolist(), ys.tolist())  # gurobi joins the points by straight segments
    m.optimize()
    sch = schedule(hv, T)  # best schedule found
    return sch, expected_value(net(sch), probs, S, D)  # schedule found and its exact expected revenue


# main loop of the double oracle
t0 = time.time()
for outer in range(1, args.outer + 1):
    sigma = solve_bank_game(sigma)  # 1) best probabilities inside the current banks
    added = 0
    gains = []
    for i in range(N):  # 2) for each household, look for a better schedule outside its bank
        probs, S, D = others(i, sigma, args.max_exact)
        current = float(sigma[i] @ np.array([expected_value(net(s), probs, S, D) for s in banks[i]]))  # its mean revenue now
        sch, val = best_response(i, sigma)  # best schedule over everything
        gains.append(val - current)  # what it would gain by switching
        if val - current > args.tol and not any(np.allclose(net(sch), net(o), atol=1e-6) for o in banks[i]):
            banks[i].append(sch)  # 3) worth it and new: add it to the bank
            sigma[i] = np.append(sigma[i] * 0.9, 0.1)  # give the new schedule a little weight
            added += 1
    print(f"round {outer:2}: {added} schedule(s) added, largest gain {max(gains):.5f} USD, "
          f"bank sizes {[len(b) for b in banks]}, {time.time() - t0:.0f} s", flush=True)
    if max(gains) <= args.tol:  # nobody can do better outside its bank -> equilibrium
        break

# solve the bank game once more, so the new schedules don't keep the 0.1 weight they got when added
sigma = solve_bank_game(sigma)
sigma = [np.where(s < 1e-3, 0.0, s) / np.where(s < 1e-3, 0.0, s).sum() for s in sigma]  # drop dust probabilities

# final certificate: best response over everything against the final mixture, exact if possible
# epsilon = largest expected gain any household could still get by deviating
epsilon = 0.0
eps_n = {}
for i in range(N):
    probs, S, D = others(i, sigma, args.max_exact)
    current = float(sigma[i] @ np.array([expected_value(net(s), probs, S, D) for s in banks[i]]))
    _, val = best_response(i, sigma)
    eps_n[names[i]] = max(0.0, val - current)  # expected gain from deviating
epsilon = max(eps_n.values())

# draws of the whole community from the mixture, for the distribution figures
# each draw: every household picks one schedule of its bank with its probabilities
draws = 2000  # community draws for the figures
picks = np.array([[rng.choice(len(sigma[i]), p=sigma[i] / sigma[i].sum()) for i in range(N)] for _ in range(draws)])
bills = np.zeros((draws, N))
for j in range(draws):
    q = np.array([net(banks[i][picks[j, i]]) for i in range(N)])  # positions of the 10 households in this draw
    s_, d_ = np.clip(q, 0, None), np.clip(-q, 0, None)
    r, c, _ = session_prices(s_.sum(0), d_.sum(0), data.low, data.high, args.rule)  # prices of this draw
    bills[j] = (d_ * c - s_ * r).sum(1) * dt  # bill of each household in this draw

solo = json.loads((HERE / "out" / "solo.json").read_text())  # grid-alone bills, to compare
print(f"\nmixed nash under {args.rule}: no household can gain more than {epsilon:.5f} USD in expectation "
      f"by deviating (bank regret {max(bank_regret(sigma)):.5f})")
print(f"expected community bill {bills.sum(1).mean():.2f} USD, 5-95% over draws "
      f"{np.quantile(bills.sum(1), 0.05):.2f} to {np.quantile(bills.sum(1), 0.95):.2f}")
print(f"{'household':12} {'solo':>8} {'E bill':>8} {'gain':>8}  probabilities")
for i, n in enumerate(names):
    s0 = solo["bills"][n]["solo"]
    p = ", ".join(f"{x:.2f}" for x in sigma[i])
    print(f"{n:12} {s0:8.2f} {bills[:, i].mean():8.2f} {s0 - bills[:, i].mean():8.2f}  [{p}]")

# save everything: probabilities, banks and draws (read by plots_mixed.py)
out = {"rule": args.rule, "epsilon_usd": epsilon, "epsilon_by_household": eps_n,
       "sigma": {n: sigma[i].tolist() for i, n in enumerate(names)},
       "banks": {n: [{k: np.asarray(v).round(6).tolist() for k, v in s.items()} for s in banks[i]]
                 for i, n in enumerate(names)},
       "draws": picks.tolist(), "draw_bills": bills.round(6).tolist()}
path = EXT / "out" / f"mixed_{args.rule}.json"
with open(path, "w") as f:
    json.dump(out, f)
print(f"wrote {path}")