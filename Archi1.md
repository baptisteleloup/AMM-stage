# AMM for Energy Sharing — Smart Contract Implementation

On-chain implementation of the automated market maker (AMM) for local energy sharing described in Fabi et al., *Automated Market Making for Energy Sharing* (arXiv:2512.24432). The market mechanism runs as Solidity smart contracts on a private Hyperledger Besu (QBFT) network; an off-chain Python orchestrator relays metered net positions to the contracts and triggers settlement each session.

Internship at Télécom Paris / CREST, supervised by Michele Fabi.

---

## Overview

Prosumers (producers/consumers of energy) exchange electricity within a local community. Each session, the metering operator submits every prosumer's observed net position to the market. The market aggregates supply and demand, computes clearing prices, settles payments in an internal token, and resets for the next session. Grid prices act as bounds and follow a day/night tariff schedule.

The mechanism is fully on-chain and verifiable by every node; only the metering relay is off-chain.

---

## Top-level layout

```
1 - AMM/
├── contracts/     Foundry project: contracts, tests, and the off-chain Python scripts
└── reference/     Copy of the paper authors' code and data (Fabi et al.), kept for reproducibility
```

---

## contracts/

The Foundry project holding the smart contracts, their tests, and the Python orchestration scripts that drive them on the Besu network.

### Solidity contracts (`contracts/src/`)

- **`Market.sol`** — Core contract. Collects orders, aggregates supply/demand, asks `Pricing` for clearing prices, settles payments and resets the session.
  - `submitOrder(prosumer, netput)` — operator-only; records an order and locks worst-case collateral for buyers.
  - `settle()` — clears the session: computes prices, pays sellers and charges buyers, refunds excess collateral.
  - `_resetSession()` — clears orders and collateral for the next session.
  - `setGridPrices(low, high)` — re-anchors the feed-in / retail bounds (used for the hourly tariff schedule).

- **`Pricing.sol`** — Pure, stateless library holding the pricing mathematics. 
  - `prices(supply, demand, lambdaLow, lambdaHigh)` — linear pricing rule; returns reward rate r (sellers) and cost rate c (buyers).
  - `totals(...)` — reward/cost totals including grid legs.

- **`EnergyEuro.sol`** — ERC-20 settlement token (EEUR). Minting is mocked for the pilot (a collateral-backed version is future work). Moved on behalf of the market through a payment-backend interface, so the monetary layer is decoupled from the mechanism.

- **`IPaymentBackend.sol` / `TokenBackend.sol`** — Payment abstraction. `Market` moves funds through this interface; `TokenBackend` implements it over `EnergyEuro`. Swapping the backend does not touch `Market` or `Pricing`.

### Tests (`contracts/test/`)

Foundry tests covering the mechanism across the three regimes (surplus, deficit, balance), money conservation, and a full session on real Nice equilibrium data.

### Off-chain orchestration (`contracts/*.py`)

- **`besu_common.py`** — Shared module for talking to the Besu network. Handles the three Besu specifics: PoA middleware (to read QBFT blocks), explicit transaction signing (Besu does not unlock accounts), and legacy transactions. Also provides batched sending (`send_batch`) for fast sessions. Read by all other scripts.

- **`deploy_besu.py`** — Deploys the contracts (EnergyEuro, TokenBackend, Market) to the Besu network and writes their addresses to `deployed_besu.json`.

- **`setup_besu.py`** — One-time setup: funds the grid, operator and prosumers with ETH (gas) and mints EEUR. Does not sign prosumer approvals (prosumers approve themselves).

- **`simulate_approvals_besu.py`** — Test scaffold. `--generate N` creates `prosumers_nice.json` (deterministic test addresses); no argument simulates the approvals each prosumer would sign from their own wallet. Not production code — in production, each prosumer approves the backend themselves.

- **`orchestrator_besu.py`** — Plays market sessions. Reads net positions, re-anchors grid prices at hourly tariff transitions (peak 8h-12h and 13h-20h, off-peak otherwise), submits orders in batch (operator), and settles.
  - `--t <step>` — play a single session at a given time step.
  - `--run` — replay the day (one session per time step, fixed target delay between sessions).
  - `lire_netputs()` — reads the session's net positions from `netputs_nice.json`. In production this is the metering bridge (see Open questions).

- **`check_state_besu.py`** — Prints on-chain state (EEUR balances, collateral, market total) before/after a session to verify money conservation.

- **`demo.sh`** — End-to-end demo: starts the network, (optionally deploys + sets up with `--full`), plays the day, prints state before/after.

### Data (`contracts/*.json`)

- **`netputs_nice.json`** — Net positions per time step, indexed `{ "t": {prosumer: netput}, ... }`. Extracted from the paper's Nice equilibrium data.
- **`prosumers_nice.json`** — Mapping `{ prosumer_id: address }` for the test participants.
- **`deployed_besu.json`** — Deployed contract and account addresses (generated by `deploy_besu.py`; local, not versioned).

### Configuration

- **`foundry.toml`** — Foundry project configuration.
- **`lib/`** — Git submodules: `forge-std`, `openzeppelin-contracts`, `prb-math` (fixed-point math).

---

## reference/

A copy of the paper authors' code and data (Fabi et al., arXiv:2512.24432). Contains the Nice and Paris datasets, including `NiceData/mpe_simulation_results_Nice.pkl` — the pre-computed Mean-Field equilibrium (net positions per agent and time step) used as the source for `netputs_nice.json`. The script `extract_nice_json.py` (in this folder) reads the pickle and produces the indexed JSON. This directory is reference material from the paper, kept for reproducibility; it is not part of the implementation.

---

## Design choices

- **Metering** — the metering operator submits observed net positions. The market mechanism (pricing, settlement) stays decentralized and verifiable; the operator is the single, irreducible trust point at the physical-world boundary.
- **Prosumers** — prosumers are sovereign: they hold their own keys and approve the payment backend themselves. The system never holds prosumer keys.
- **Mocked currency** — EEUR minting is mocked for the pilot to isolate the market mechanism. A collateral-backed version (prosumers deposit an asset to mint their own EEUR) is documented as future work; thanks to the payment-backend decoupling, it would not change the mechanism.
- **Hourly grid tariffs** — grid bounds follow the paper's French tariff schedule (retail 21.46 peak / 16.96 off-peak c€/kWh, feed-in 8.86 constant), re-anchored at tariff transitions.

---

## Open questions (prosumer lifecycle)

These are the boundaries with the physical and institutional world, deliberately mocked pending design decisions. The mechanism, settlement, network and deployment all work.

1. **Registration** — how a new prosumer becomes a recognized participant: who validates local-community membership and adds their address to the metering/orchestrator scope.
2. **Funding** — how a registered prosumer obtains EEUR: mocked mint, or self-funded collateral deposit.
3. **Metering bridge** — how a prosumer's net positions reach each session (`lire_netputs`): who builds the meter -> optimization -> netput bridge, and what the real source is.

One lifecycle: register (1), fund (2), and each session the meter feeds orders (3).
