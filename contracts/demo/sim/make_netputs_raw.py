# Turns the recorded profiles into netputs: per member and session, PV output minus consumption,
# as recorded (no battery, no shifting), split into whole Wh sold or bought. Reads --profiles
# (agents.json and the parquet files), writes --out and <out>_manifest.json. Run from contracts/:
#   python3 demo/sim/make_netputs_raw.py --profiles demo/data/profiles --out demo/data/netputs_raw.json --force
import argparse
import json
import os
from datetime import datetime, timezone

import pandas as pd

SESSIONS = 96  # fifteen-minute sessions per day
HOURS_PER_SESSION = 24.0 / SESSIONS  # the profiles give average power in kW over each session


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profiles", default="demo/data/profiles")
    ap.add_argument("--out", default="demo/data/netputs_raw.json")
    ap.add_argument("--days", type=int, default=None,
                    help="number of days to keep; default: all but the last, as with the solver")
    ap.add_argument("--force", action="store_true", help="allow writing over an existing file")
    args = ap.parse_args()

    if os.path.exists(args.out) and not args.force:
        raise SystemExit(f"{args.out} already exists; pass --force to overwrite it")

    with open(os.path.join(args.profiles, "agents.json")) as f:
        meta = json.load(f)
    names = [a["name"] for a in meta["agents"]]
    days = meta["days"]
    keep = args.days if args.days is not None else max(1, len(days) - 1)  # the last profile day is dropped by default
    sim_days = days[:keep]  # days written to the netputs

    profiles = {}
    # community totals, for the energy balance check below
    totals = {"sold": 0, "bought": 0, "generation_kwh": 0.0, "consumption_kwh": 0.0}
    for n in names:
        s = pd.read_parquet(os.path.join(args.profiles, f"{n}.parquet"))
        per_day = {}
        for di, day in enumerate(sim_days):
            rows_of_day = s[s.index.strftime("%Y-%m-%d") == day]  # the 96 sessions of that day
            if len(rows_of_day) != SESSIONS:
                raise SystemExit(f"{n} has {len(rows_of_day)} rows on {day}, expected {SESSIONS}")
            gen = rows_of_day["omega_kw"].values  # PV output, kW
            # base plus flexible load as recorded, kW
            con = (rows_of_day["alpha_base_kw"] + rows_of_day["flex_kw"]).values
            rows = []
            for t in range(SESSIONS):
                wh = (gen[t] - con[t]) * HOURS_PER_SESSION * 1000  # net energy of the session, Wh
                sell = int(round(wh)) if wh > 0 else 0  # a member is on one side only
                buy = int(round(-wh)) if wh < 0 else 0
                rows.append([sell, buy])
                totals["sold"] += sell
                totals["bought"] += buy
            totals["generation_kwh"] += float(gen.sum()) * HOURS_PER_SESSION
            totals["consumption_kwh"] += float(con.sum()) * HOURS_PER_SESSION
            per_day[str(di)] = rows  # keyed by day index, as the operator expects
        profiles[n] = per_day

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump({"sessions": SESSIONS, "unit": "Wh", "baseDay": 0,  # format read by the operator (NETPUTS_JSON)
                   "days": len(sim_days), "profiles": profiles}, f)

    manifest = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "method": "net position = photovoltaic output minus base and flexible consumption, "
                  "as recorded, with no battery, no load shifting and no optimisation",
        "profiles": os.path.abspath(args.profiles),
        "agents": names,
        "days": sim_days,
    }
    with open(os.path.splitext(args.out)[0] + "_manifest.json", "w") as f:
        json.dump(manifest, f, indent=1)

    # Without storage, net purchases must equal the physical deficit exactly.
    deficit = totals["consumption_kwh"] - totals["generation_kwh"]
    net = (totals["bought"] - totals["sold"]) / 1000
    print(f"wrote {args.out}: {len(names)} dwellings x {len(sim_days)} day(s) ({', '.join(sim_days)})")
    print(f"offered {totals['sold'] / 1000:.1f} kWh, demanded {totals['bought'] / 1000:.1f} kWh")
    print(f"energy balance: deficit {deficit:.1f} kWh, net purchases {net:.1f} kWh "
          f"(difference {net - deficit:+.2f} kWh, rounding only)")


if __name__ == "__main__":
    main()
