import argparse
import json
import os
import re
import subprocess

import pandas as pd

RELEASE = "2024/resstock_amy2018_release_2"
META_URL = ("https://oedi-data-lake.s3.amazonaws.com/nrel-pds-building-stock/"
            "end-use-load-profiles-for-us-building-stock/{release}/metadata_and_annual_results/"
            "by_state/state={state}/parquet/{state}_baseline_metadata_and_annual_results.parquet")


def fetch(state, release, cache):
    os.makedirs(cache, exist_ok=True)
    dest = os.path.join(cache, f"{state}_metadata.parquet")
    if os.path.exists(dest):
        print(f"using cached {dest}")
        return dest
    url = META_URL.format(state=state, release=release)
    print(f"downloading state metadata (this is a few hundred MB)\n  {url}")
    r = subprocess.run(["curl", "-fL", "--progress-bar", "-o", dest, url])
    if r.returncode != 0:
        os.path.exists(dest) and os.remove(dest)
        raise SystemExit(
            "download failed. The release path moves between publications — open\n"
            "https://data.openei.org/submissions/4520 , find the current\n"
            "metadata_and_annual_results path, and pass it with --release")
    return dest


def find_col(df, patterns, required=True, label=""):
    for p in patterns:
        for c in df.columns:
            if re.search(p, c, re.I):
                return c
    if required:
        raise SystemExit(f"could not find a column for {label}. Columns available:\n"
                         + "\n".join(sorted(df.columns)[:80]))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", default="MA")
    ap.add_argument("--with-pv", type=int, default=5)
    ap.add_argument("--without-pv", type=int, default=5)
    ap.add_argument("--release", default=RELEASE)
    ap.add_argument("--cache", default="demo/data/raw")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default="selection.json")
    ap.add_argument("--any-county", action="store_true",
                    help="draw from the whole state instead of a single county")
    args = ap.parse_args()

    path = fetch(args.state, args.release, args.cache)
    df = pd.read_parquet(path)
    print(f"{len(df)} dwellings in {args.state}")

    pv_col = find_col(df, [r"in\.pv_system_size", r"in\.has_pv", r"pv_system_size"],
                      label="PV system size")
    type_col = find_col(df, [r"in\.geometry_building_type_recs", r"in\.building_type"],
                        required=False)
    elec_col = find_col(df, [r"out\.electricity\.total\.energy_consumption",
                             r"out\.electricity\.net\.energy_consumption"],
                        required=False)

    print(f"PV column: {pv_col}")

    has_pv = df[pv_col].astype(str).str.lower().isin(["none", "nan", "0", "0.0", "false", ""])
    with_pv = df[~has_pv].copy()
    without_pv = df[has_pv].copy()
    print(f"{len(with_pv)} with PV, {len(without_pv)} without")

    if type_col:
        sf = without_pv[type_col].astype(str).str.contains("Single-Family", case=False, na=False)
        if sf.sum() >= args.without_pv:
            without_pv = without_pv[sf]
            print(f"restricted the no-PV group to single-family for comparability "
                  f"({len(without_pv)} left)")


    county_col = find_col(df, [r"in\.county_and_puma", r"in\.county"], required=False)
    chosen_county = None
    if county_col and not args.any_county:
        counts = with_pv.groupby(county_col).size()
        no_counts = without_pv.groupby(county_col).size()
        feasible = [c for c in counts.index
                    if counts[c] >= args.with_pv and no_counts.get(c, 0) >= args.without_pv]
        if feasible:
            chosen_county = max(feasible, key=lambda c: counts[c])
            with_pv = with_pv[with_pv[county_col] == chosen_county]
            without_pv = without_pv[without_pv[county_col] == chosen_county]
            print(f"all {args.with_pv + args.without_pv} dwellings drawn from one county: "
                  f"{chosen_county}")
        else:
            print("no single county can supply the whole panel; drawing from the "
                  "whole state. The members will not share a feeder — say so in "
                  "the paper, or ask for fewer dwellings.")

    if len(with_pv) < args.with_pv:
        raise SystemExit(f"only {len(with_pv)} dwellings with PV available")

    with_pv = with_pv.sort_values(pv_col)
    idx = [int(round(i * (len(with_pv) - 1) / max(1, args.with_pv - 1)))
           for i in range(args.with_pv)]
    sel_pv = with_pv.iloc[idx]
    sel_no = without_pv.sample(args.without_pv, random_state=args.seed)

    id_col = "bldg_id" if "bldg_id" in df.columns else df.index.name or df.columns[0]

    def ids(frame):
        return [str(v) for v in (frame[id_col] if id_col in frame.columns else frame.index)]

    pv_ids, no_ids = ids(sel_pv), ids(sel_no)

    print()
    print("with PV:")
    for i, row in zip(pv_ids, sel_pv.itertuples()):
        size = getattr(row, pv_col.replace(".", "_"), "?") if hasattr(row, pv_col.replace(".", "_")) else sel_pv.loc[:, pv_col].loc[row.Index]
        print(f"  {i:>10}   {pv_col.split('.')[-1]} = {size}")
    print("without PV:")
    for i in no_ids:
        print(f"  {i:>10}")

    all_ids = pv_ids + no_ids
    print()
    print("paste this:")
    print(f"  --ids {','.join(all_ids)} --state {args.state}")

    with open(args.out, "w") as f:
        json.dump({
            "state": args.state,
            "release": args.release,
            "pv_column": pv_col,
            "with_pv_ids": pv_ids,
            "without_pv_ids": no_ids,
            "selection_rule": "PV group spread evenly across the system-size "
                              "distribution; no-PV group drawn at random with a "
                              "fixed seed, restricted to single-family where possible",
            "seed": args.seed,
            "county": str(chosen_county) if chosen_county is not None else None,
            "geography_note": "all members drawn from one county so that the "
                              "community plausibly shares a distribution feeder "
                              "and a wholesale pricing zone",
            "note": "This is a composition choice, not a representative sample. "
                    "PV penetration in the ResStock baseline follows the real US "
                    "stock, so a mixed community must be selected deliberately.",
        }, f, indent=1)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
