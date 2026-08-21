# Private Energy-Sharing Market — V4 (Noir / UltraHonk)

A local energy community trades surplus production between members at prices computed on-chain, better than the grid tariff for both sides. Individual consumption data never touches the chain: amounts and balances live behind Poseidon2 commitments, and the daily settlement is **proven correct with zero-knowledge proofs** (conservation, solvency, and fidelity to each member's committed consumption) instead of being trusted or recomputed in public.

**Stack**: Solidity on a permissioned [Besu](https://besu.hyperledger.org/) network (QBFT, free gas) · circuits in [Noir](https://noir-lang.org/) · proving/verification with UltraHonk ([Barretenberg](https://github.com/AztecProtocol/aztec-packages)), **no per-circuit trusted setup**.

→ Full design: Archi4.md

---



## Version history

This repository is the fourth iteration of the same market. The thread running through them: **every piece of data you hide destroys a verification that used to be free, and must be bought back.**


| Version | What it did                                                                                                                                                                                                                                                                                     | What it paid                                                                                                                                                                    |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **V1**  | Everything in cleartext on-chain; the contract computed the whole settlement (prices, pro-rata, collateral) from posted netputs. A wrong settlement was impossible by re-execution.                                                                                                             | Zero privacy: individual load curves public at 15-min resolution (a presence sensor).                                                                                           |
| **V2**  | Netputs move off-chain (aggregates + Merkle root only), clock-driven sessions, permissionless settle, daily netting.                                                                                                                                                                            | The contract can no longer check individual amounts → a Merkle **challenge** lets the victim contest, at the cost of revealing their own data. Amounts & balances still public. |
| **V3**  | Amounts and balances hidden behind commitments; one Groth16 proof per day (conservation + solvency). Challenge retained for fidelity.                                                                                                                                                           | Per-circuit trusted-setup ceremony (toxic waste), N frozen by the circuit, 44 KB of on-chain Poseidon.                                                                          |
| **V4**  | Fidelity moves **into the circuit** (the challenge dies), UltraHonk removes the ceremony, chunking unfreezes N, two-stage reveal-or-cancel guarantees data availability, privacy side-channels closed (private participation, committed floors, seeded netput hashes), floor changes co-signed. | The residual, named: the prover sees the witness; meter fidelity stays off-chain, adjudicated externally.                                                                       |




## Repository layout

```
contracts/
├── src/
│   ├── MarketV4.sol          # the market: sessions, freeze, chunks, settlement, recourses
│   ├── GridTariff.sol        # tariff clock  
│   ├── Pricing.sol           # the paper's pricing curve (UD60x18)
│   ├── EnergyEuro.sol        # payment token (EEUR, 1:1 €)
│   ├── DayChunkVerifier.sol  # GENERATED UltraHonk verifier (day_chunk circuit)
│   └── RevealVerifier.sol    # GENERATED UltraHonk verifier (reveal circuit)
├── circuits/
│   ├── day_chunk/            # the daily proof: C1–C6 over BATCH = 8 prosumers
│   ├── reveal/               # opens a balance commitment in the clear (recourse stage 2)
│   └── poseidon_helper/      # executed (not proven) by scripts: THE Poseidon2 reference
├── js_scripts/
│   ├── operator/             # the operator daemon: sessions, close, proofs, receipts, reveals
│   ├── client/               # the prosumer client: verify, keeper, recourses, web UI
│   ├── demo/                 # demo-only
│   ├── scenario.ts           # shared crypto primitives + the FFI test's two-prosumer scenario
│   └── generateProof_*.ts    # invoked by the FFI test 
├── demo/
│   ├── sim/                  # ResStock -> profiles -> the paper's solver -> netputs
│   ├── run.sh                # the whole demo, from building selection to a live view
│   ├── data/                 # inputs: profiles, prices, netputs (raw/ is a download cache)
│   └── state/                # one run's output: deployment, receipts, databases, log
├── test/
│   ├── MarketV4.t.sol        # mock suite (verifiers stubbed)
│   └── MarketV4.ffi.t.sol    # full real cycle: TS proves, Solidity verifies (vm.ffi)

```



## Build & test

```bash
# 1. Solidity, mock suite (fast)
forge test --no-match-contract FFI

# 2. Full cycle with real proofs (needs node deps + nargo + bb)
cd js_scripts && npm install && cd ..
forge test                      # includes the FFI test: TS generates, chain verifies

# 3. The market running end to end, on real building and price data
./demo/run.sh                   # SKIP_DATA=1 to reuse profiles and prices already built
```



### Rebuilding the circuits / verifier

Any circuit change requires recompiling and regenerating the verifier:

```bash
cd circuits/day_chunk
nargo compile                                   # -> target/day_chunk.json
bb write_vk -b target/day_chunk.json -o target --oracle_hash keccak
bb write_solidity_verifier -k target/vk -o ../../src/DayChunkVerifier.sol
```

### Padding constants

`EMPTY_NETPUT_HASH` and `ZERO_BAL_COMMIT` are printed by the circuit itself and injected at deployment:

```bash
cd circuits/day_chunk && nargo test --show-output   # print_contract_constants
```

They come *from* the circuit, so they match Poseidon2 by construction: never recompute them with another implementation.

## Pinned versions & known traps

- **bb.js**: pinned nightly; the prover **must** use the `verifierTarget: "evm"` flavor (keccak transcript + ZK). The
`keccak: true` option generates a *non-ZK* proof of the wrong size →`ProofLengthWrongWithLogN` on-chain.
- The generated verifier **reverts** with custom errors (`SumcheckFailed`, `PublicInputsLengthWrong`, …). It never returns `false`. The most common failure, `SumcheckFailed`, means one public input differs between prover and contract.
- Verifiers are ~23.7 KB each  (close to EIP-170); the genesis `contractSizeLimit` is the guardrail on the consortium chain.
- The `MarketV4` constructor takes **10 arguments** (token, two verifiers, tariff, operator, grid, floorAdmin, reserve, two padding constants).

## The demo

`./demo/run.sh` runs the whole market on measured building data and real wholesale
prices, on a local chain. The point is not that it runs, but what it runs on: the
gains from sharing depend entirely on members *not* producing and consuming at the
same moment, so a demo built on identical synthetic profiles would measure nothing.

**Dwellings.** [ResStock](https://www.nrel.gov/buildings/resstock.html), from NREL's
[End-Use Load Profiles for the U.S. Building Stock](https://www.nrel.gov/buildings/end-use-load-profiles.html)
project. ResStock characterises the U.S. housing stock as conditional probability
distributions drawn from a dozen public and private sources (census, RECS, AHS,
utility data), samples representative dwellings from that parameter space by
deterministic quota sampling, builds an OpenStudio model for each one, and simulates
it in EnergyPlus at a sub-hourly timestep. The published profiles were calibrated
against measured utility and submetered data over a three-year validation effort.
Roughly 550,000 residential models cover the country, about one per few hundred
existing dwellings.

Two consequences matter here. Each dwelling has its own envelope, equipment,
occupancy schedule and PV capacity, so two neighbours peak at different moments,
which is exactly the diversity a sharing market monetises. And the output is broken
down by end use, which is what lets `build_profiles.py` separate the flexible part
of demand (space conditioning, water heating, whose thermal mass allows shifting)
from the inflexible part, rather than declaring a flat percentage flexible.

Release: `2024/resstock_amy2018_release_2`, upgrade 0 (baseline stock, no retrofit).
`amy2018` means *actual meteorological year 2018*, the weather as it was actually
observed, not a typical year. Data portal: [OEDI submission 4520](https://data.openei.org/submissions/4520).
`pick_buildings.py` reads the state metadata file to select dwellings in one county,
with and without PV; `build_profiles.py` downloads one timeseries parquet per
selected dwelling and turns it into the three series the solver needs (gross
production, inflexible demand, daily flexible energy), writing a `manifest.json`
that records the source URLs, checksums and every transformation applied.

**Prices.** ISO New England
[SMD Hourly Data](https://www.iso-ne.com/isoexpress/web/reports/load-and-demand/-/tree/zone-info),
one annual workbook with a tab per load zone, hourly day-ahead locational marginal
prices alongside system load. The demo uses WCMA (Western/Central Massachusetts) to
match the dwellings. `fetch_prices.py` holds each hourly price flat across its four
quarter-hours and adds a delivery adder to approximate a retail tariff.

Same year and same region for both sources, so load and price move together: the
heatwave that drives air conditioning also drives the wholesale price. The workbook
sits behind a captcha, so it is cached in `demo/data/raw/` and downloaded once.

**Netputs.** `make_netputs.py` imports `solve_horizon` from the paper's own
repository rather than reimplementing it, and runs it at 96 steps a day. One
departure from the paper is deliberate: it treats the other members' aggregates as a
fixed point solved by damped best response, instead of taking them as exogenous. At
a community of a few dozen, each member visibly moves the aggregate that sets the
price, so the price-taking assumption of the mean-field setting does not hold.

## Status

- Contracts + circuits: **complete and green**.The mock suite plus the full FFI cycle (real UltraHonk proofs verified on-chain).
- **Operator daemon**: running. Proof generation lives in a separate worker process, so a reveal request no longer stalls the session loop; it settles or cancels its own days rather than waiting for a keeper.
- **Prosumer client**: running, with a web UI. Recomputes the netput hash, verifies each day against its own receipts, decrypts reveal blobs, raises margin alerts, and runs a keeper. The first rung of recourse (`requestData` → decrypt) is automated; the rungs above it are deliberately manual. A public reveal is irreversible, and a cancellation costs the whole community its day.
- **Demo**: ten ResStock dwellings from one Massachusetts county, ISO New England day-ahead prices, the paper's solver at 96 steps a day. Runs on a local chain.

