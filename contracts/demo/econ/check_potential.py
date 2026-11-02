# Looks for a witness that the game under a rule has no exact potential, on saved profiles.
# Reads the given json profiles (default: every json under out/), writes nothing.
# Run from contracts/: python demo/econ/check_potential.py [--rule mmr|sdr|hyperbolic] [profile.json ...]
#
# Idea (Monderer and Shapley 1996, Theorem 4.5): restrict two households n and m to one number each,
# the energy theta they shift through their battery from session t to t2. This smooth restricted game
# has a potential only if d2 P_n / dtheta_n dtheta_m == d2 P_m / dtheta_n dtheta_m, so one pair where the
# two cross derivatives differ shows that the full game has none.
import argparse
import json

import numpy as np

from common import HERE, SETTINGS, Data, session_prices

ap = argparse.ArgumentParser()
ap.add_argument("--rule", choices=("mmr", "sdr", "hyperbolic"), default="mmr")  # the game we test
ap.add_argument("paths", nargs="*")  # profiles to test
args = ap.parse_args()
RULE = args.rule
EPS = 1e-4  # step of the finite differences (kWh)
MARGIN = 1e-3  # positions and aggregates must stay this far from any kink (kWh)
THR = 1e-6  # smallest difference of cross derivatives we count (USD/kWh^2)

data = Data()
dt, T = data.dt, data.T
K, B, X = SETTINGS["battery_kw"], SETTINGS["battery_kwh"], SETTINGS["grid_kw"]  # limits used to check slack


def bill(x, S_o, D_o, t):
    # bills of the households of x (net positions in kWh) in session(s) t,
    # the other households' aggregates being S_o, D_o
    S = S_o + np.clip(x, 0, None).sum(0)  # supply with these households
    D = D_o + np.clip(-x, 0, None).sum(0)  # demand with these households
    r, c, _ = session_prices(S, D, data.low[t], data.high[t], RULE)
    return -(np.clip(x, 0, None) * r - np.clip(-x, 0, None) * c)


def cross(xn, xm, S_o, D_o, t):
    # d2 bill / dx_n dx_m for n's bill and for m's bill, by finite differences, every session at once
    def b(dn, dm):
        return bill(np.array([xn + dn, xm + dm]), S_o, D_o, t)

    f = (b(EPS, EPS) - b(EPS, 0) - b(0, EPS) + b(0, 0)) / EPS**2  # mixed second difference
    return f[0], f[1]  # cross derivative of n's bill, of m's bill


def can_shift(sch, t, t2, sign):
    # can this household raise its net position by a little at t (sign=+1) or lower it (sign=-1),
    # and do the opposite at t2, through its battery, with every constraint slack?
    sell, buy = sch["sell_kw"] * dt, sch["buy_kw"] * dt
    k, soc = sch["batt_kw"], sch["soc_kwh"]
    for tau, s in ((t, sign), (t2, -sign)):
        if s > 0:  # net position up: sell more (or buy less), battery gives the energy
            if k[tau] <= -K + 1e-6 or (sell[tau] > 0 and sell[tau] >= X * dt - MARGIN):
                return False
        else:  # net position down: buy more (or sell less), battery takes the energy
            if k[tau] >= K - 1e-6 or (buy[tau] > 0 and buy[tau] >= X * dt - MARGIN):
                return False
    lo, hi = min(t, t2), max(t, t2)
    # the stored energy moves between the two sessions: down if the household first gives energy
    first = sign if t < t2 else -sign
    seg = soc[lo:hi]
    return bool(np.all(seg > 1e-6)) if first > 0 else bool(np.all(seg < B - 1e-6))


def search(path):
    # first witness found in one saved profile, or None
    run = json.loads(open(path).read())
    if "schedules" not in run or "soc_kwh" not in next(iter(run["schedules"].values())):
        return None  # not a profile of schedules (e.g. a summary file)
    names = list(run["schedules"])
    sch = {n: {k: np.array(v) for k, v in run["schedules"][n].items()} for n in names}
    q = np.array([(sch[n]["sell_kw"] - sch[n]["buy_kw"]) * dt for n in names])  # kWh
    S, D = np.clip(q, 0, None).sum(0), np.clip(-q, 0, None).sum(0)
    t_all = np.arange(T)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            xn, xm = q[i], q[j]
            S_o = S - np.clip(xn, 0, None) - np.clip(xm, 0, None)
            D_o = D - np.clip(-xn, 0, None) - np.clip(-xm, 0, None)
            cn, cm = cross(xn, xm, S_o, D_o, t_all)
            # sessions away from every kink
            smooth = (np.abs(xn) > MARGIN) & (np.abs(xm) > MARGIN) & (np.abs(S - D) > MARGIN)
            gap = np.where(smooth, cn - cm, np.nan)  # asymmetry of each session
            for t in np.flatnonzero(smooth & (np.abs(gap) > THR)):
                for t2 in np.flatnonzero(smooth):
                    if t2 == t or abs(gap[t] + gap[t2]) <= THR:
                        continue  # the two sessions must not cancel each other
                    for sn in (1, -1):
                        if not can_shift(sch[names[i]], t, t2, sn):
                            continue
                        for sm in (1, -1):
                            if can_shift(sch[names[j]], t, t2, sm):
                                return names, i, j, t, t2, sn, sm, cn, cm, q, S, D
    return None


paths = args.paths or [str(p) for p in sorted((HERE / "out").rglob("*.json"))]
print(f"testing the game under the {RULE} rule")
for path in paths:
    w = search(path)
    if w is None:
        print(f"{path}: no witness")
        continue
    names, i, j, t, t2, sn, sm, cn, cm, q, S, D = w
    tot_n = sn * sm * (cn[t] + cn[t2])  # cross derivative of n's bill in the restricted game
    tot_m = sn * sm * (cm[t] + cm[t2])
    print(f"{path}: WITNESS (any feasible profile works, whatever rule produced it)")
    for tau in (t, t2):
        side = "excess demand" if S[tau] < D[tau] else "excess supply"
        print(f"  session {tau} ({side}, supply {S[tau]:.3f} kWh, demand {D[tau]:.3f} kWh): "
              f"{names[i]} net {q[i, tau]:+.3f} kWh, {names[j]} net {q[j, tau]:+.3f} kWh, "
              f"cross derivatives {cn[tau]:+.6f} (n) and {cm[tau]:+.6f} (m)")
    for who, s_ in ((names[i], sn), (names[j], sm)):
        up, down = (t, t2) if s_ > 0 else (t2, t)
        print(f"  {who} can raise its net position at session {up} and lower it at session {down} "
              f"through its battery, with every constraint slack")
    print(f"  restricted game: d2P_n/dtheta_n dtheta_m = {tot_n:+.6f}, d2P_m/dtheta_n dtheta_m = {tot_m:+.6f} USD/kWh^2")
    break  # one witness is enough
