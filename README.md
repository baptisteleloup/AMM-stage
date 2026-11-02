# Private local energy market: contracts, proofs and experiments

This repository holds the code that accompanies the manuscript. It
implements an automated market maker for local electricity exchange: EVM contracts on a
Hyperledger Besu network, Noir circuits proven with UltraHonk, an operator daemon that runs the
market and proves each day, and a prosumer client that checks its own settlement. It also holds
every experiment of the manuscript: the fixed-profile demo on NREL ResStock households and ISO New
England prices, the on-chain cost measurements, the four-validator Besu network (faults and clock
skew), and the strategic study (Nash equilibria computed with Gurobi).

## Repository layout

```
README.md
contracts/   contracts, circuits, operator, client, demo, experiments (Foundry project root)
network/     four-validator Besu network and its fault and clock-skew experiments
archive/     code and outputs no longer used by the manuscript (kept, not maintained)
```

Inside `contracts/`:

| Path | Content |
|---|---|
| `src/` | `MarketV4.sol` (sessions, midnight freeze, batch verification, recourse, settlement), `Pricing.sol` (MMR, SDR and hyperbolic rules), `GridTariff.sol` (tariff band, schedule and feed modes), `EnergyEuro.sol` (demo settlement token; its name is historical, the experiments use USD prices), generated verifiers |
| `test/` | Foundry tests: mock suite and FFI suite with real proofs |
| `circuits/` | `day_chunk` (one day for a batch of 8 members), `reveal` (opens a balance commitment), `poseidon_helper` (off-circuit hashes) |
| `js_scripts/operator/` | operator daemon (configured only through environment variables) |
| `js_scripts/client/` | prosumer client, CLI and local web UI |
| `js_scripts/demo/` | demo orchestrator, deployment, price and floor posting, chain measurements |
| `js_scripts/besu/` | watchers and reports of the Besu experiments |
| `demo/` | `run.sh`, data (`data/`), simulation scripts (`sim/`), strategic study (`econ/`), results |

## Requirements

| Tool | Version used | Needed for |
|---|---|---|
| Foundry (`forge`, `anvil`) | forge 1.7.1 | contracts, tests, local chain of the demo |
| Node.js and `npx tsx` | Node 24 | operator, client, demo, measurements |
| nargo | 1.0.0-beta.19 | compiling the circuits |
| bb (Barretenberg) | 4.0.0-nightly.20260120 | FFI tests (`bb.js` of the same version is used by the scripts) |
| Python, with `uv` | Python 3.13 | data preparation, reports, strategic study |
| Gurobi and a licence | Gurobi 13.0 | strategic study (`demo/econ/`), `demo/sim/check_grid_cap.py` |
| Docker with Compose | | Besu network (`network/`) |
| `curl` | | ResStock downloads |

Setup, from the repository root:

```
git submodule update --init --recursive        # forge-std, openzeppelin-contracts, prb-math
npm install                                    # TypeScript dependencies (package.json at the root)
uv venv contracts/.venv --python 3.13
uv pip install --python contracts/.venv/bin/python pandas pyarrow openpyxl tqdm numpy matplotlib gurobipy
source contracts/.venv/bin/activate
cd contracts
for c in day_chunk reveal poseidon_helper; do (cd circuits/$c && nargo compile); done
```

The compiled circuits (`circuits/*/target/`) are not committed. They are read by the operator,
the proof scripts and the FFI tests.

Every command below runs from `contracts/`, except the scripts of `network/`, which run from
`network/`.

## Quick checks

```
cd contracts
forge build && forge test --no-match-path "test/*.ffi.t.sol"
npx tsc --noEmit -p ../tsconfig.json
python -m py_compile demo/sim/*.py demo/econ/*.py demo/econ/extensions/*.py
python demo/econ/summarize.py
```

`summarize.py` only reads the committed results in `demo/econ/out/` and prints the tables of the
strategic study. The test suite with real proofs needs the compiled circuits and `bb`:
`forge test --match-path "test/*.ffi.t.sol"`.

## Reproducing the manuscript

### 1. Data (1 to 4 July 2018, ten households in Massachusetts)

The outputs of this step are committed in `demo/data/`, so it can be skipped. The raw downloads
go to `demo/data/raw/` (about 125 MB, not committed).

```
python3 demo/sim/pick_buildings.py --state MA --with-pv 5 --without-pv 5 --cache demo/data/raw --out demo/data/selection.json
python3 demo/sim/build_profiles.py --state MA --days 2018-07-01:2018-07-05 --cache demo/data/raw --out demo/data/profiles \
    --ids "$(python3 -c "import json; s = json.load(open('demo/data/selection.json')); print(','.join(s['with_pv_ids'] + s['without_pv_ids']))")"
python3 demo/sim/fetch_prices.py --days 2018-07-01:2018-07-05 --zone WCMA --delivery-adder 0.12 --out demo/data/prices.json
python3 demo/sim/make_netputs_raw.py --profiles demo/data/profiles --out demo/data/netputs_raw.json --force
```

| Script | Produces |
|---|---|
| `pick_buildings.py` | `selection.json`: the ResStock building ids (5 with PV, 5 without) |
| `build_profiles.py` | `profiles/`: `prosumer-<i>.parquet`, `agents.json`, `cycles.json`, `manifest.json` |
| `fetch_prices.py` | `prices.json` and `prices_manifest.json`: tariff band from ISO-NE day-ahead prices |
| `make_netputs_raw.py` | `netputs_raw.json` and its manifest: recorded net positions per session |

The ISO New England workbook `2018_smd_hourly.xlsx` sits behind a captcha and must be downloaded
by hand from the Zonal Information page
(https://www.iso-ne.com/isoexpress/web/reports/pricing/-/tree/zone-info). `fetch_prices.py` looks
for it in `demo/data/raw/`, then in `~/Downloads/`, or takes it with `--local <path>`. The
five-day range is intended: the netputs keep all days but the last, which gives the four days of
the manuscript.

### 2. Fixed-profile demo, once per pricing rule

```
PRICING_RULE=<mmr|sdr|hyperbolic> NETPUTS=demo/data/netputs_raw.json DEPOSIT_EUR=200 SKIP_DATA=1 bash demo/run.sh
```

`run.sh` starts anvil, deploys the community, posts the prices and floors, starts the operator
and the clients, then drives the clock session by session; each day is frozen, proven and
settled on chain. It runs until stopped. Leave it running until the four days are settled (shown
by the live view), then, in a second terminal and while the chain is still up:

```
MEASURE_OUT=demo/measure_chain_<rule>.json npx tsx js_scripts/demo/measure_chain.ts
```

This writes the gas, calldata, proof sizes and proving times of the run
(`demo/measure_chain_{mmr,sdr,hyperbolic}.json`, the table of on-chain costs). Stop `run.sh` with
Ctrl-C afterwards. The run state goes to `demo/state/` (not committed). Without `SKIP_DATA=1`,
`run.sh` runs step 1 first.

### 3. Fixed-profile reports and figures

These read `demo/data/netputs_raw.json` and `demo/data/prices.json` and do not need the chain.

```
python3 demo/sim/report_results.py --rule <rule> --figdir demo/figures_raw_<rule>
python3 demo/sim/plot_prices_rules.py --netputs demo/data/netputs_raw.json
```

| Output | Content |
|---|---|
| `demo/results_raw_<rule>.pdf` | full report of the run under one rule (not committed) |
| `demo/figures_raw_<rule>/fig_*.pdf` | figures of the fixed-profile results (sessions, prices, gains, decomposition, cash, individual gains) |
| `demo/figures_raw_<rule>/table_days.tex`, `table_households.tex` | tables of the fixed-profile results, per day and per household |
| `demo/figures_raw/fig_prices_rules.pdf` | session prices of the three rules on the most active day |

Two optional checks of the data: `demo/sim/check_grid_cap.py` (smallest grid connection per
household, Gurobi) and `demo/sim/end_use_breakdown.py` (daily kWh per ResStock end use).

### 4. Besu network (from `network/`)

```
bash reset.sh       # restarts the four validators from block zero (docker compose up -d) and waits for blocks
bash faults.sh      # stops and restarts validators: 4, 3, 2, 3, 4 up
docker build -f Dockerfile.faketime -t besu-faketime:26.8.1 .
bash skew.sh        # restarts node-4 with its clock shifted by +2 s, -3 s, -8 s, -30 s
```

| Output (`network/besu_results/`) | Content |
|---|---|
| `faults.json`, `events.jsonl` | blocks per phase, longest gap, fork check |
| `skew.json`, `skew_events.jsonl` | share of blocks of the skewed validator, block intervals, timestamp lag |

The raw watcher logs (`watch.jsonl`, `skew_watch.jsonl`, about 150 MB each) are not committed.
Time to finality, from `contracts/` with the network up (results committed in
`contracts/besu_results/`):

```
RPC_URLS=http://127.0.0.1:8545,http://127.0.0.1:8546 N=200 BURST=10 OUT=besu_results/finality_burst.json npx tsx js_scripts/besu/finality.ts
```

The demo itself can run on this network with `CHAIN=besu` in front of `bash demo/run.sh`.

### 5. Strategic study (Gurobi)

All results are committed in `demo/econ/out/`.

```
python demo/econ/solo.py                                  # out/solo.json: each household alone against the grid
python demo/econ/planner.py                               # out/planner.json: social planner
python demo/econ/equilibrium.py --rule <rule>             # out/nash_<rule>.json: Nash equilibrium from the solo start
python demo/econ/equilibrium.py --rule <rule> --init planner   # out/nash_<rule>_from_planner.json
python demo/econ/campaign.py                              # out/ms, out/stab, out/cert (several hours)
python demo/econ/summarize.py                             # tables: multiple starts, stability, fine-grid check
python demo/econ/check_potential.py --rule <rule> demo/econ/out/nash_<rule>_from_planner.json   # witnesses reported in the manuscript
python demo/econ/plots.py                                 # figures/fig_eq_*.pdf
python demo/econ/plot_grid_overlay.py                     # figures/fig_eq_grid_overlay_mmr.pdf
```

`campaign.py` runs `equilibrium.py` many times (multiple starts, stability test, check on a
2 001-point grid); it skips runs already done, so it can be stopped and restarted. The log of the
manuscript's run is `demo/econ/out/campaign.log`. `check_potential.py` without file arguments
searches all committed profiles and stops at the first witness it finds, which need not be the one
reported in the manuscript. `plots.py` and `plot_grid_overlay.py` take `--rule` (default `mmr`)
for the profile figures.

## Reference figures

Use them to check a reproduction.

- Fixed profiles, 1 to 4 July 2018: 366.0 kWh exchanged inside the community, a gain of
  43.92 USD, against a grid-only bill of 144.01 USD.
- Chain, ten households: about 19.0 million gas per day; a batch proof takes about 2.4 s.
- Strategic study: households optimising alone 100.22 USD, social planner 68.03 USD, Nash
  equilibria 72.88 (MMR), 72.96 (SDR) and 73.33 USD (hyperbolic), with a certificate
  epsilon of 0.00008, 0.00100 and 0.00504 USD on the 2 001-point grid.
- No exact potential: the restricted-game cross derivatives differ, -0.000841 and +0.000841
  (MMR), 0.241910 and 0.251382 (SDR), 0.095092 and 0.105220 USD/kWh² (hyperbolic).

## Extension outside the manuscript

`demo/econ/extensions/` computes mixed-strategy Nash equilibria of the ten-household game. It is
not part of the manuscript and is kept for reference.

```
python demo/econ/extensions/mixed.py --rule <rule>        # extensions/out/mixed_<rule>.json
python demo/econ/extensions/plots_mixed.py                # extensions/figures/fig_mixed_*.pdf
```

## External data

- NREL ResStock, release `resstock_amy2018_release_2` (AMY 2018 weather), from the OEDI data lake
  (https://data.openei.org/submissions/4520).
- ISO New England, SMD hourly data 2018 (day-ahead zonal LMP, zone WCMA).
