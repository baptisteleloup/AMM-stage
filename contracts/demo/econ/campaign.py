# Runs equilibrium.py many times: multiple starts, stability test and fine-grid check (several hours).
# Needs out/solo.json, out/planner.json and out/nash_<rule>*.json; writes out/ms, out/stab and out/cert,
# skipping runs already done, so it can be stopped and restarted. The log of the paper's run is out/campaign.log.
# Run from contracts/: python demo/econ/campaign.py [--step multistart|stability|certify|all] [--rules ...]
import argparse
import subprocess
import sys
import time

from common import HERE

ap = argparse.ArgumentParser()
ap.add_argument("--step", choices=("multistart", "stability", "certify", "all"), default="all")
ap.add_argument("--rules", nargs="+", default=["mmr", "sdr", "hyperbolic"])
ap.add_argument("--n-mix", type=int, default=12)  # random mixes of solo and planner starts, per rule
ap.add_argument("--n-shuffle", type=int, default=3)  # random household orders from each of solo and planner
ap.add_argument("--stab-k", type=int, nargs="+", default=[1, 3])  # how many households we kick off
ap.add_argument("--stab-seeds", type=int, default=5)  # how many kicks for each k
ap.add_argument("--cert-points", type=int, default=2001)  # finer broken line for the check
args = ap.parse_args()

OUT = HERE / "out"  # results folder
EQ = str(HERE / "equilibrium.py")  # script run for every tag


def run(tag, extra):
    # one call of equilibrium.py, skipped if its output already exists
    if (OUT / f"{tag}.json").exists():
        print(f"skip {tag} (already done)", flush=True)
        return
    t0 = time.time()
    cmd = [sys.executable, EQ, "--tag", tag] + extra  # same Python, output out/<tag>.json
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"FAILED {tag}\n{res.stderr[-2000:]}", flush=True)
        return
    # summary lines of the run
    last = [line for line in res.stdout.splitlines() if line.startswith(("nash under", "community bill", "certificate"))]
    print(f"done {tag} in {time.time() - t0:.0f} s | " + " | ".join(last), flush=True)


def multistart(rule):
    # starts from solo, planner, random mixes of the two, and shuffled orders
    run(f"ms/{rule}_solo", ["--rule", rule, "--init", "solo"])
    run(f"ms/{rule}_planner", ["--rule", rule, "--init", "planner"])
    for s in range(args.n_mix):
        p = (0.25, 0.5, 0.75)[s % 3]  # share of households starting from the planner
        run(f"ms/{rule}_mix{s}", ["--rule", rule, "--init", "mix", "--mix-p", str(p), "--seed", str(s), "--shuffle"])
    for s in range(args.n_shuffle):
        run(f"ms/{rule}_solo_shuffle{s}", ["--rule", rule, "--init", "solo", "--seed", str(100 + s), "--shuffle"])
        run(f"ms/{rule}_planner_shuffle{s}", ["--rule", rule, "--init", "planner", "--seed", str(200 + s), "--shuffle"])


def stability(rule):
    # kick k households of the paper's equilibrium back to solo and let the others react
    base = OUT / f"nash_{rule}.json"  # the equilibrium of the paper (start from grid-alone schedules)
    if not base.exists():
        print(f"no {base.name}, run equilibrium.py --rule {rule} first", flush=True)
        return
    for k in args.stab_k:
        for s in range(args.stab_seeds):
            run(f"stab/{rule}_k{k}_s{s}", ["--rule", rule, "--init", "file", "--from", str(base),
                                          "--perturb", str(k), "--seed", str(s)])


def certify(rule):
    # no passes, only the final check, with a much finer broken line
    for name in (f"nash_{rule}", f"nash_{rule}_from_planner"):
        f = OUT / f"{name}.json"
        if f.exists():
            run(f"cert/{name}_{args.cert_points}", ["--rule", rule, "--init", "file", "--from", str(f),
                                                     "--max-passes", "0", "--points", str(args.cert_points)])


for rule in args.rules:
    if args.step in ("certify", "all"):
        certify(rule)
    if args.step in ("multistart", "all"):
        multistart(rule)
    if args.step in ("stability", "all"):
        stability(rule)
print("campaign finished, now run summarize.py")
