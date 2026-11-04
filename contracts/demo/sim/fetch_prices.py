# Builds the tariff band from ISO New England day-ahead prices: low = zonal LMP, high = LMP plus
# a flat delivery adder, held flat over the four sessions of each hour. Reads the SMD hourly workbook
# (downloaded by hand, captcha), writes --out and prices_manifest.json next to it. Run from contracts/:
#   python3 demo/sim/fetch_prices.py --days 2018-07-01:2018-07-05 --zone WCMA --out demo/data/prices.json
import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

import pandas as pd

SESSIONS = 96  # fifteen-minute sessions per day
ZONES = ["NEMA", "SEMA", "WCMA", "CT", "RI", "NH", "VT", "ME", ".H.INTERNAL_HUB"]  # load zones of the workbook

ZONE_INFO_PAGE = "https://www.iso-ne.com/isoexpress/web/reports/pricing/-/tree/zone-info"


# How to fetch the workbook by hand, printed when it is missing.
def manual_instructions(year, cache):
    return (
        f"\nThe {year} hourly workbook has to be downloaded by hand, once.\n"
        f"ISO New England puts a captcha on these files, so no script can fetch\n"
        f"them. It takes about two minutes:\n\n"
        f"  1. open {ZONE_INFO_PAGE}\n"
        f"  2. in the Zonal Information table, find the row for {year}\n"
        f"     (the file is named {year}_smd_hourly.xlsx)\n"
        f"  3. tick it, solve the captcha, download\n"
        f"  4. move it into {cache}/ , or pass it directly:\n\n"
        f"       python3 fetch_prices.py --days ... --local ~/Downloads/{year}_smd_hourly.xlsx\n\n"
        f"Once it sits in {cache}/ every later run finds it there on its own.\n")


# Hash of the workbook, recorded in the manifest.
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# Workbook path: --local, else the cache, else ~/Downloads (copied into the cache).
def find_workbook(year, cache, local):
    if local:
        if not os.path.exists(local):
            raise SystemExit(f"{local} does not exist" + manual_instructions(year, cache))
        return local
    os.makedirs(cache, exist_ok=True)
    for name in (f"{year}_smd_hourly.xlsx", f"{year}_smd_hourly.xls",
                 f"smd_hourly_{year}.xlsx"):
        cached = os.path.join(cache, name)
        if os.path.exists(cached):
            print(f"using {cached}")
            return cached
    for guess in (os.path.expanduser(f"~/Downloads/{year}_smd_hourly.xlsx"),
                  f"./{year}_smd_hourly.xlsx"):
        if os.path.exists(guess):
            dest = os.path.join(cache, os.path.basename(guess))
            print(f"found {guess}, copying into {cache}/")
            with open(guess, "rb") as a, open(dest, "wb") as b:
                b.write(a.read())
            return dest
    raise SystemExit(manual_instructions(year, cache))


# Hourly day-ahead LMP of one zone over the run, as (date, start_hour, lmp).
def read_zone(path, zone, day_from, day_to):
    book = pd.ExcelFile(path)
    names = {s.upper().strip(): s for s in book.sheet_names}
    key = zone.upper().replace(".H.INTERNAL_HUB", "ISO NE CA")  # the hub sits on the system sheet
    sheet = None
    for cand in (key, key.replace(" ", "_"), zone.upper()):
        if cand in names:
            sheet = names[cand]
            break
    if sheet is None:
        raise SystemExit(f"no sheet for zone {zone}. Sheets in the workbook:\n  "
                         + "\n  ".join(book.sheet_names))
    print(f"reading sheet {sheet}")
    df = book.parse(sheet)

    def norm(c):  # column names vary between years
        return "".join(ch for ch in str(c).lower() if ch.isalnum())

    date_col = next((c for c in df.columns if norm(c) in ("date", "day", "localday")), None)
    hour_col = next((c for c in df.columns
                     if norm(c) in ("hrend", "hourend", "hourending", "he", "hr", "hour")), None)
    if hour_col is None:
        hour_col = next((c for c in df.columns
                         if norm(c).startswith("hr") or norm(c).startswith("hour")), None)
    lmp_col = next((c for c in df.columns if norm(c) in ("dalmp", "damlp")), None)
    if lmp_col is None:
        lmp_col = next((c for c in df.columns
                        if "da" in norm(c) and "lmp" in norm(c) and "rt" not in norm(c)), None)
    if date_col is None or hour_col is None or lmp_col is None:
        raise SystemExit("could not identify the date / hour / day-ahead LMP columns.\n"
                         "Columns present:\n  " + "\n  ".join(str(c) for c in df.columns))
    print(f"columns: date={date_col}  hour={hour_col}  day-ahead LMP={lmp_col}")

    df = df[[date_col, hour_col, lmp_col]].copy()
    df.columns = ["date", "hour", "lmp"]
    df["date"] = pd.to_datetime(df["date"], errors="coerce")
    df["hour"] = pd.to_numeric(df["hour"], errors="coerce")
    df["lmp"] = pd.to_numeric(df["lmp"], errors="coerce")
    df = df.dropna()

    df["start_hour"] = (df["hour"] - 1).astype(int)  # hour ending -> hour starting
    df = df[(df["start_hour"] >= 0) & (df["start_hour"] <= 23)]

    lo = pd.Timestamp(day_from)
    hi = pd.Timestamp(day_to) + pd.Timedelta(days=1)
    df = df[(df["date"] >= lo) & (df["date"] < hi)]
    if len(df) == 0:
        raise SystemExit(f"no rows for {day_from}..{day_to} in this workbook")
    return df


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", required=True, help="YYYY-MM-DD:YYYY-MM-DD, inclusive")
    ap.add_argument("--zone", default="WCMA", choices=ZONES)
    ap.add_argument("--local", help="an already-downloaded SMD hourly workbook")
    ap.add_argument("--cache", default="demo/data/raw")
    ap.add_argument("--out", default="prices.json")
    ap.add_argument("--delivery-adder", type=float, default=0.12,
                    help="currency per kWh added on top of the wholesale price to "
                         "get what a household actually pays: distribution, "
                         "transmission and taxes")
    ap.add_argument("--dst-shift-hours", type=int, default=1,
                    help="hours to shift ISO-NE's clock onto ResStock's standard "
                         "time; 1 in summer, 0 in winter")
    args = ap.parse_args()

    day_from, day_to = args.days.split(":")
    year = pd.Timestamp(day_from).year

    path = find_workbook(year, args.cache, args.local)
    url = None

    df = read_zone(path, args.zone, day_from, day_to)

    rows = {}
    for _, r in df.iterrows():
        h = int(r["start_hour"]) - args.dst_shift_hours  # prevailing time -> ResStock's standard time
        d = r["date"]
        if h < 0:  # shifted into the previous day
            h += 24
            d = d - pd.Timedelta(days=1)
        rows[(d.date().isoformat(), h)] = float(r["lmp"]) / 1000.0  # $/MWh -> per kWh

    days = []
    cur = pd.Timestamp(day_from)
    end = pd.Timestamp(day_to)
    while cur <= end:
        days.append(cur.date().isoformat())
        cur += pd.Timedelta(days=1)

    out_days = {}
    stats = []
    for day in days:
        missing = [h for h in range(24) if (day, h) not in rows]
        if missing:
            print(f"  {day}: {len(missing)} hour(s) missing, filled from the "
                  f"nearest available hour")
        low, high = [], []
        last = None
        for h in range(24):
            v = rows.get((day, h))
            if v is None:
                v = last if last is not None else 0.03  # missing hour: repeat the previous one
            last = v
            for _ in range(4):  # same price in the four sessions of the hour
                low.append(round(v, 6))  # feed-in = wholesale
                high.append(round(v + args.delivery_adder, 6))  # retail = wholesale + delivery adder
        out_days[day] = {"low": low, "high": high}
        stats.append((day, min(low), max(low), sum(low) / len(low)))

    payload = {  # format read by post_prices.ts and the reports
        "sessions": SESSIONS,
        "unit": "currency per kWh",
        "zone": args.zone,
        "delivery_adder": args.delivery_adder,
        "days": days,
        "prices": out_days,
    }
    with open(args.out, "w") as f:
        json.dump(payload, f)

    manifest = {  # provenance of the tariff band
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": {
            "name": f"ISO New England SMD hourly data, {year}",
            "zone": args.zone,
            "landing_page": ZONE_INFO_PAGE,
            "file": os.path.basename(path),
            "sha256": sha256(path),
        },
        "parameters": {
            "days": args.days,
            "delivery_adder_usd_per_kwh": args.delivery_adder,
            "dst_shift_hours": args.dst_shift_hours,
        },
        "transformations": [
            "hour-ending labels converted to interval-start hours",
            f"clock shifted back {args.dst_shift_hours} h from Eastern Prevailing Time to Eastern Standard Time, as in ResStock",
            "USD/MWh converted to USD/kWh",
            "each hourly day-ahead price held flat over its four quarter hours",
            "feed-in rate = day-ahead LMP; retail rate = LMP + delivery adder",
        ],
        "daily_wholesale_summary_usd_per_kwh": [
            {"day": d, "min": round(a, 4), "max": round(b, 4), "mean": round(c, 4)}
            for d, a, b, c in stats
        ],
    }
    manifest_path = os.path.join(os.path.dirname(os.path.abspath(args.out)), "prices_manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=1)

    print()
    print(f"wrote {args.out}: {len(days)} day(s), zone {args.zone}")
    for d, a, b, c in stats:
        print(f"  {d}  wholesale {a:.4f} .. {b:.4f}, mean {c:.4f}   "
              f"household pays {c + args.delivery_adder:.4f}")
    spread = args.delivery_adder
    print()
    print(f"the spread a local trade splits is the delivery adder: {spread:.4f}/kWh")


if __name__ == "__main__":
    main()
