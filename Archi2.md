# AMM for Energy Sharing — Smart Contract Implementation

On-chain implementation of the automated market maker (AMM) for local energy sharing described in Fabi et al., *Automated Market Making for Energy Sharing* (arXiv:2512.24432). The market mechanism runs as Solidity smart contracts on a private Hyperledger Besu (QBFT) network. Sessions are indexed on wall-clock time, settlement is permissionless (driven by redundant keeper daemons), and individual net positions never appear on-chain: each session publishes only aggregates plus a Merkle commitment, with payments netted once a day under an optimistic challenge window.

Internship at Télécom Paris / CREST, supervised by Michele Fabi.

---

## Overview

Prosumers (producers/consumers of energy) exchange electricity within a local community. Each 15-minute session, the metering operator publishes the community's aggregate supply and demand together with a Merkle root committing to the individual net positions — one transaction, no individual data. Anyone may then settle the session: the contract reads the grid tariff for that slot from `GridTariff` (computed on-chain, no oracle needed for scheduled tariffs) and fixes the clearing prices. Money moves once a day: the operator posts a netting batch (per-prosumer net amounts over the day's sessions), which the contract checks for budget balance; after a challenge window during which any prosumer can dispute their line by revealing their committed leaves, anyone finalizes the day against internal EEUR balances.

Pricing, settlement timing, tariffs and payments are on-chain and verifiable by every node; only the metering relay is off-chain, and it is accountable: it is bound by its own session commitments and every prosumer can audit — and cancel — a dishonest batch.

---

## Top-level layout

```
1 - AMM/
├── contracts/     Foundry project: contracts, tests, and the off-chain Python scripts
└── reference/     Copy of the paper authors' code and data (Fabi et al.), kept for reproducibility
```

---

## contracts/

The Foundry project holding the smart contracts, their tests, and the Python scripts that drive them on the Besu network.

### Solidity contracts (`contracts/src/`)

- **`Market.sol`** — Core contract. Timestamped sessions (`sessionId = timestamp / 900`), aggregate-only order flow, internal EEUR ledger, daily netting with optimistic verification.
  - `openSession(sessionId, netputRoot, s, d)` — operator-only; one tx per session: aggregates plus the Merkle root of `(prosumer, netput, salt)` leaves. No individual netput on-chain.
  - `settle(sessionId)` — **permissionless**; after the slot closes, reads the tariff from `GridTariff`, fixes `(r, c, cTotal, rTotal)`. O(1), moves no money.
  - `deposit(amount)` / `withdraw(amount)` — internal EEUR balances, decoupled from market activity. `setFloor` replaces per-order collateral: withdrawals cannot go below a prosumer's worst-case daily cost.
  - `closeDay(day, dayRoot, accounts, amounts)` — operator-only; posts the per-prosumer net amounts for the day. The contract enforces budget balance (sum of amounts = sum of `rTotal − cTotal` over the day, up to rounding dust) and locks debits as `pendingDebit`.
  - `challenge(day, sessionIds, netputs, salts, proofs)` — any prosumer, during the window; reveals their leaves for every opened session, the contract recomputes their true amount from the stored prices and cancels the day on mismatch.
  - `finalizeDay(day)` — **permissionless**, after the window; applies balance deltas and transfers the net grid leg.

- **`GridTariff.sol` / `IGridTariff.sol`** — Grid price bounds behind one interface, `getPrices(timestamp)`. Two modes:
  - *Schedule* — the French regulated tariff: `lambda_high` is a pure function of `block.timestamp` (peak windows 8h–12h and 13h–20h). Re-anchoring happens on-chain; no transaction is ever needed intra-day. Regulatory revisions go through `setSchedule` (grid role, effective from the next day boundary).
  - *Feed* — dynamic-price regimes (day-ahead spot): authorized reporters each post the next day's 96-slot vector once; the vector activates when M of N reporters agree on the same hash, with graceful fallback to the last finalized day.

- **`Pricing.sol`** — unchanged. Pure, stateless library holding the pricing mathematics (linear rule, `prices` and `totals`).

- **`EnergyEuro.sol`** — unchanged. ERC-20 settlement token (EEUR), mocked minting for the pilot. `Market` now holds deposits directly and nets on an internal ledger, so ERC-20 transfers only occur at deposit, withdrawal, and the daily grid leg.

### Tests (`contracts/test/`)

Foundry tests (31, all passing) covering: the tariff schedule and its window boundaries, feed quorum/dissent/fallback, session lifecycle and permissions, permissionless settlement across tariff windows, budget-balance enforcement, the full day happy path with conservation and ledger-backing invariants, the challenge game (dishonest batch cancelled, honest batch ungriefable, forged leaves rejected, omitted prosumers detected), plus the three regime simulations (surplus, deficit, balance) and a full lifecycle on real Nice equilibrium data. `test/utils/MerkleHelper.sol` builds OZ-compatible trees in tests; `CrossMerkle.t.sol` pins the Python/Solidity Merkle compatibility (same roots, Python proofs verified by OZ `MerkleProof`).

### Off-chain scripts (`contracts/*.py`)

- **`besu_common.py`** — unchanged. Shared module for talking to the Besu network (PoA middleware, explicit signing, legacy transactions, batched sending).

- **`merkle.py`** — Merkle trees for the netput commitments. Mirrors `MerkleHelper.sol` exactly (double-hashed leaves, sorted pairs, odd node carried up); cross-validated by `CrossMerkle.t.sol`.

- **`metering_operator.py`** — the reduced operator (replaces `orchestrator_besu.py`). Per slot: reads net positions (Nice replay, data step = `sid % 96`), builds the Merkle tree over all prosumers, submits `openSession`, writes leaves + proofs to `leaves/<day>/<sid>.json` (the off-chain distribution channel). End of day: recomputes each prosumer's net amount from the on-chain prices with the same floor arithmetic as the contract, posts `closeDay`.
  - `--slot <sid>` — open one session; `--close-day <day>` — post the netting batch; `--run` — live loop.

- **`keeper_daemon.py`** — one instance per validator organization; stateless and idempotent, N copies run in parallel and races are harmless. Settles closed sessions, finalizes days past the challenge window, and (Feed mode) fetches the ENTSO-E day-ahead vector after publication and submits it.

- **`deploy_besu.py` / `setup_besu.py` / `simulate_approvals_besu.py` / `check_state_besu.py` / `demo.sh`** — deployment and scaffolding; to be updated for the new constructors (`GridTariff` first, then `Market(token, tariff, grid, operator, challengeWindow)`), the `deposit` step in setup, and the keeper in the demo.

### Data (`contracts/*.json`, `contracts/leaves/`)

- **`netputs_nice.json`** — Net positions per time step, indexed `{ "t": {prosumer: netput}, ... }`. Extracted from the paper's Nice equilibrium data.
- **`prosumers_nice.json`** — Mapping `{ prosumer_id: address }` for the test participants.
- **`deployed_besu.json`** — Deployed contract and account addresses (now includes `GridTariff`).
- **`leaves/<day>/<sid>.json`** — per-session leaves, salts and Merkle proofs written by the operator for distribution to prosumers (local, not versioned).

### Configuration

- **`foundry.toml`** — Foundry project configuration.
- **`lib/`** — Git submodules: `forge-std`, `openzeppelin-contracts` (now also used for `MerkleProof`), `prb-math` (fixed-point math).

---

## reference/

A copy of the paper authors' code and data (Fabi et al., arXiv:2512.24432). Contains the Nice and Paris datasets, including `NiceData/mpe_simulation_results_Nice.pkl` — the pre-computed Mean-Field equilibrium used as the source for `netputs_nice.json`, produced by `extract_nice_json.py`. Reference material, not part of the implementation.

---

## Design choices

- **Privacy by aggregation** — the mechanism's Anonymity axiom means pricing only needs aggregates; the implementation takes it literally. Individual 15-minute profiles (the behavioral data) stay off-chain under a commitment; the residual public leak is one net € amount per prosumer per day, at `closeDay`. Verifiability is individual: each prosumer holds their leaves and can audit their own line.
- **Everything deterministic is on-chain** — the tariff calendar is computed from `block.timestamp`; only genuinely external data (day-ahead spot, when applicable) enters via the M-of-N feed, once a day.
- **No load-bearing process** — any time-triggered transition (`settle`, `finalizeDay`, the feed) is permissionless and idempotent; redundant keepers, one per validator organization, are the availability mechanism. On a private network with free gas there is no free-rider problem to price, so no keeper reward is needed.
- **Accountable metering** — the operator remains the single trust point at the physical-world boundary, but it is now constrained: it cannot create or destroy money (budget-balance check), it is bound by its own session commitments, fraud is blocked before money moves (challenge window), and pricing/timing are out of its hands entirely.
- **Prosumers** — sovereign as before: they hold their own keys, deposit and withdraw at will; the system never holds prosumer keys.
- **Mocked currency** — EEUR minting is mocked for the pilot; a collateral-backed version remains future work.

---

## What changed since Archi1

**Motivating critiques.** (1) Privacy: the block explorer exposed who consumes what and when — `orderOf` was public, `OrderSubmitted`/`CollateralLocked` events carried individual netputs, and per-session ERC-20 transfers revealed quantities through public prices. (2) Centralization: a single cron orchestrator held pricing (`setGridPrices`), sequencing (`submitOrder`) and settlement (`settle`), so the market died with its server.

**Contract changes.**

| | Archi1 | Archi2 |
|---|---|---|
| Order flow | 50 × `submitOrder(prosumer, netput)` in cleartext | 1 × `openSession(root, s, d)`: aggregates + commitment |
| Grid prices | `setGridPrices` by the operator, per tariff window | `GridTariff`: computed on-chain (Schedule) or M-of-N daily feed |
| Settlement | `settle()` operator-only, O(N), moves money | `settle(sid)` permissionless, O(1), fixes prices only |
| Payments | per-session ERC-20 transfers | internal ledger, daily netting, deposits/withdrawals on demand |
| Collateral | locked per order (`CollateralLocked` leaked demand) | withdrawal floor + `pendingDebit` lock during the window |
| Operator misreporting | undetectable, money moved immediately | budget-balance check, challenge window, day cancellation |
| Timing | operator's cron | wall-clock sessions + redundant keeper daemons |

**Removed.** `IPaymentBackend.sol` / `TokenBackend.sol` (and their tests): the backend indirection existed to decouple money movements from the mechanism; the internal ledger now plays that role, and `Market` talks to the ERC-20 directly (transfers only at deposit/withdraw/grid leg). `orchestrator_besu.py` is replaced by `metering_operator.py` + `keeper_daemon.py`.

**Added.** `GridTariff.sol`, `IGridTariff.sol`, rewritten `Market.sol`; `merkle.py`, `metering_operator.py`, `keeper_daemon.py`; `MerkleHelper.sol`, `CrossMerkle.t.sol`, rewritten test suite.

**Behavioral notes.** Sessions are wall-clock indexed, so the 15-second accelerated replay of Archi1 no longer applies as-is: the live loop maps the dataset onto real slots (`sid % 96`); an accelerated demo requires redeploying with a smaller `SLOT` and scaling the schedule windows by the same factor. The Nice `t=48` session now clears at the off-peak mid-price (12.91 c€/kWh) rather than 15.16, because 12h falls in the off-peak lunch window — the re-anchoring is on-chain and automatic. The grid account must `approve` the Market (it pays the feed-in leg on net-surplus days).

**Known residuals** (documented, deliberate): daily net amounts are public in `closeDay` calldata (the 15-minute profile is not); the operator sees all individual data (it reads the meters — see Open questions 4); challenges require the operator to have distributed leaves (a prosumer omitted from the trees cannot prove it — mitigated by signed meter readings, future work).

---

## Open questions (prosumer lifecycle)

1. **Registration** — how a new prosumer becomes a recognized participant: who validates local-community membership and adds their address to the metering scope.
2. **Funding** — how a registered prosumer obtains EEUR: mocked mint, or self-funded collateral deposit; plus the sizing of the withdrawal floor (worst-case daily consumption × retail price).
3. **Metering bridge** — how net positions reach the operator each session, and what the real meter → optimization → netput source is.
4. **Trustworthy metering** — the operator can still misstate the physical reality itself; meter-signed readings would make even that contestable on-chain (DePIN frontier, explicitly assumed away in the paper).
5. **Leaf distribution & auto-verification** — replacing `leaves/*.json` with a real transport, and the prosumer client that recomputes its line each day and challenges automatically.
6. **Keeper keys** — one signing key per validator organization (the daemon currently reuses the operator key as a placeholder).

One lifecycle: register (1), fund (2), each session the meter feeds the operator (3, 4), each day the prosumer client verifies (5).
