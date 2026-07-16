# AMM for Energy Sharing — Smart Contract Implementation (V3)

On-chain implementation of the automated market maker (AMM) for local energy sharing described in Fabi et al., *Automated Market Making for Energy Sharing* (arXiv:2512.24432). The market mechanism runs as Solidity smart contracts on a private Hyperledger Besu (QBFT) network. Sessions are indexed on wall-clock time, settlement is permissionless (driven by redundant keeper daemons), and neither individual net positions nor individual money amounts ever appear on-chain: each session publishes only aggregates plus a Merkle commitment, and the daily netting publishes only Poseidon commitments plus a single Groth16 proof that the hidden amounts are conservative and solvent.

Internship at Télécom Paris / CREST, supervised by Michele Fabi.

---

## Overview

Prosumers (producers/consumers of energy) exchange electricity within a local community. Each 15-minute session, the metering operator publishes the community's aggregate supply and demand together with a Merkle root committing to the individual net positions — one transaction, no individual data. Anyone may then settle the session: the contract reads the grid tariff for that slot from `GridTariff` (computed on-chain, no oracle needed for scheduled tariffs) and fixes the clearing prices.

Money moves once a day. The operator computes each prosumer's net amount from the on-chain prices, commits to it, and posts a netting batch consisting of commitments only, together with one zero-knowledge proof establishing that the hidden amounts open those commitments, sum to the community's real net position against the grid, and leave no balance negative. Internal balances are themselves commitments: the contract advances them blind. After a challenge window — during which any prosumer can dispute their line by opening their amount commitment and revealing their committed leaves — anyone finalizes the day.

Pricing, settlement timing, tariffs and payments are on-chain and verifiable by every node; only the metering relay is off-chain, and it is accountable: it is bound by its own session commitments, it cannot create or destroy money, it cannot make anyone insolvent, and every prosumer can audit — and cancel — a dishonest batch.

The proof and the commitments are complementary, not redundant: the proof establishes conservation and solvency over values nobody sees; the Merkle roots and the challenge establish fidelity to the metered net positions. A valid proof can still carry a constant-sum redistribution — that is precisely what the challenge catches.

---

## Top-level layout

```
1 - AMM/
├── contracts/     Foundry project: contracts, circuit, tests, and the off-chain scripts
└── reference/     Copy of the paper authors' code and data (Fabi et al.), kept for reproducibility
```

---

## contracts/

### Solidity contracts (`contracts/src/`)

- **`MarketZK.sol`** — Core contract. Timestamped sessions (`sessionId = timestamp / 900`), aggregate-only order flow, committed internal balances, daily netting verified by a Groth16 proof under an optimistic challenge window. Accounts live in numbered slots (`register`, `slotOf`/`accountOf`) because the circuit is positional.
  - `openSession(sessionId, netputRoot, s, d)` — operator-only; one tx per session: aggregates plus the Merkle root of `(prosumer, netput, salt)` leaves. Unchanged from V2.
  - `settle(sessionId)` — **permissionless**; after the slot closes, reads the tariff from `GridTariff`, fixes `(r, c, cTotal, rTotal)` and accumulates `rTotal − cTotal` into `dayNet`. O(1), moves no money. Unchanged from V2.
  - `register(prosumer, slot)` / `bootstrapBalances(commitments)` — operator-only; assign circuit slots. A fresh slot starts at `GENESIS_C = Poseidon(0, 0)` (an initial zero balance is public anyway, so no blinding is needed); `bootstrapBalances` is the one-shot migration hook for inherited balances, each prosumer verifying its own opening off-chain.
  - `deposit(amount)` / `requestWithdraw(amount)` — money in and out. Both are **public signed deltas** (`pendingDelta`) absorbed by that evening's proof rather than immediate balance moves; withdrawals are paid at the next `finalizeDay`. Their solvency is enforced in-circuit, so no floor and no `pendingDebit` lock are needed.
  - `closeDayZK(day, dayRoot, amtC, newC, sumShifted, proof)` — operator-only; posts the day's amount and new-balance commitments plus the proof. The contract assembles the public inputs **from its own state** (current `balC`, current `pendingDelta`), so a proof is only valid against the present chain state: no replay, no proving against an imagined state. It then checks budget balance on the hidden amounts: `|sumShifted − N·2^127 − dayNet| ≤ DUST·(N+1)`.
  - `challenge(day, sessionIds, netputs, salts, proofs, amtShifted, amtR)` — any prosumer, during the window; opens their own amount commitment (`PoseidonT3.hash([amtShifted, amtR]) == amtC[slot]`, binding), reveals their leaves for every opened session, and the contract recomputes their true amount from the stored prices and cancels the day on mismatch. Consumed deltas and queued withdrawals are restored on cancellation.
  - `finalizeDay(day)` — **permissionless**, after the window; advances the committed balances blind (`balC = newC`), pays queued withdrawals, and transfers the net grid leg.

- **`DayBatchVerifier.sol`** — **generated** by `snarkjs` from the circuit and the ceremony; never edited by hand. Holds the verification key as constants and exposes `verifyProof(a, b, c, pubSignals)`. Public-signal order is fixed by the circuit: `[sumShifted, oldC[N], amtC[N], newC[N], delta[N]]`, i.e. `1 + 4N` signals (`uint[9]` for the compiled N=2 instance). Regenerating the circuit or the proving key means regenerating this file and redeploying the market — `verifier` is `immutable` by design: the circuit is a rule of the game, not a parameter.

- **`PoseidonT3.sol`** — vendored (`poseidon-solidity`). SNARK-friendly hash over the BN254 field, used at exactly one place on-chain: verifying a commitment opening in `challenge`. Its bytecode exceeds EIP-170, hence `code_size_limit` in `foundry.toml` and `contractSizeLimit` in the Besu genesis.

- **`GridTariff.sol` / `IGridTariff.sol`** — unchanged from V2. Grid price bounds behind one interface, `getPrices(timestamp)`. Two modes:
  - *Schedule* — the French regulated tariff: `lambda_high` is a pure function of `block.timestamp` (peak windows 8h–12h and 13h–20h). Re-anchoring happens on-chain; no transaction is ever needed intra-day. Regulatory revisions go through `setSchedule` (grid role, effective from the next day boundary).
  - *Feed* — dynamic-price regimes (day-ahead spot): authorized reporters each post the next day's 96-slot vector once; the vector activates when M of N reporters agree on the same hash, with graceful fallback to the last finalized day.

- **`Pricing.sol`** — unchanged. Pure, stateless library holding the pricing mathematics (linear rule, `prices` and `totals`).

- **`EnergyEuro.sol`** — unchanged. ERC-20 settlement token (EEUR), mocked minting for the pilot. ERC-20 transfers only occur at deposit, withdrawal payout, and the daily grid leg.

### Zero-knowledge circuit and proving (`contracts/zk/`)

- **`daybatch.circom`** — `template DayBatch(N)`. Per slot: three Poseidon openings (old balance, amount, new balance) against the public commitments; `Num2Bits(128)` on the shifted amount; the transition `newBal = oldBal + amt + delta − 2·2^127`; `Num2Bits(128)` on the new balance — **this is where solvency lives**: a negative balance wraps in the field and does not fit 128 bits, so no witness exists and the day is unprovable. Signed values travel shifted by `SHIFT = 2^127` (finite fields have no sign); the output `sumShifted` is the sum the contract checks against `dayNet`. Compiled test instance: `DayBatch(2)`, 1,952 non-linear constraints. Production: `DayBatch(50)`, ≈45k constraints, phase-1 ceremony at power 16.

- **`prove_day.js`** — operator-side prover and test-fixture generator. Builds the circuit input (public commitments, private openings, fresh blinding per commitment), runs `snarkjs.groth16.fullProve`, exports Solidity calldata. Emits two proofs over the same old balances: an honest batch, and a dishonest one where 200 units are moved between slots at constant sum — the latter proves valid and is caught by the challenge (`MarketZK.t.sol`).

- **`README-zk.md`** — build pipeline, ceremony commands, and the caveats reproduced under *Conditions for production* below.

- Build artifacts (`*.ptau`, `*.zkey`, `build/`, `node_modules/`) are regenerable and not versioned; `DayBatchVerifier.sol` and `ZKFixture.sol` are generated but **are** versioned, since the tests and the deployment depend on them.

### Tests (`contracts/test/`)

Foundry tests (20, all passing): `GridTariff.t.sol` (10) — schedule windows and boundaries, fuzzed feed-in constancy, next-day revisions, feed quorum/dissent/fallback/permissions; `MarketZK.t.sol` (8) — circomlibjs ↔ `PoseidonT3` cross-validation on fixed vectors, a real Groth16 proof accepted on-chain with amounts hidden, tampered public rejected, proof bound to chain state (an interleaved deposit invalidates it), hidden balances advanced at finalize, honest batch ungriefable, hidden constant-sum redistribution caught by the challenge, forged opening rejected; `CrossMerkle.t.sol` (2) — Python/Solidity Merkle compatibility (same roots, Python proofs verified by OZ `MerkleProof`). `test/utils/MerkleHelper.sol` builds OZ-compatible trees; `test/utils/ZKFixture.sol` holds the generated proofs, so the suite runs without circom or Node.

Tests exercise a real proof end to end, not a mock verifier.

### Off-chain scripts (`contracts/*.py`)

- **`besu_common.py`** — unchanged. Shared module for talking to the Besu network (PoA middleware, explicit signing, legacy transactions, batched sending). `deployed_besu.json` now also carries `GridTariff`, `MarketZK`, `DayBatchVerifier` and `PoseidonT3`.

- **`merkle.py`** — unchanged. Merkle trees for the netput commitments, mirroring `MerkleHelper.sol` exactly (double-hashed leaves, sorted pairs, odd node carried up); cross-validated by `CrossMerkle.t.sol`.

- **`metering_operator.py`** — the reduced operator. Per slot (unchanged): reads net positions (Nice replay, data step = `sid % 96`), builds the Merkle tree over all prosumers, submits `openSession`, writes leaves + proofs to `leaves/<day>/<sid>.json`. End of day (to be updated for V3): recomputes each prosumer's net amount from the on-chain prices with the same floor arithmetic as the contract, builds the circuit input, invokes the prover, posts `closeDayZK`, and distributes the openings alongside the leaves.
  - **New persistent state, critical**: the operator must keep each slot's balance opening `(balance, r)` across days — the chain holds only commitments, so losing this file means no future proof can be produced and the market halts with funds locked. This is the availability cost of confidentiality and has no V2 equivalent.
  - Deposits or withdrawals landing between reading `pendingDelta` and inclusion invalidate the proof (by design — state binding); the operator re-reads, re-proves and resubmits.

- **`keeper_daemon.py`** — unchanged in structure; one instance per validator organization, stateless and idempotent, N copies run in parallel and races are harmless. Settles closed sessions, finalizes days past the challenge window, and (Feed mode) fetches the ENTSO-E day-ahead vector after publication and submits it. `dayBatch(day)` now returns six fields (`net` added) — unpacking updated accordingly.

- **`deploy_besu.py` / `setup_besu.py` / `simulate_approvals_besu.py` / `check_state_besu.py` / `demo.sh`** — deployment and scaffolding; to be updated for the V3 constructors (`GridTariff`, then `PoseidonT3` and `DayBatchVerifier`, then `MarketZK(token, tariff, verifier, grid, operator, challengeWindow)` with library linking), the `register` / `bootstrapBalances` step, and the fact that `check_state_besu.py` can no longer read balances — it can only verify that the token held by the contract matches the sum of deposits minus payouts.

### Data (`contracts/*.json`, `contracts/leaves/`)

- **`netputs_nice.json`** — Net positions per time step, indexed `{ "t": {prosumer: netput}, ... }`. Extracted from the paper's Nice equilibrium data.
- **`prosumers_nice.json`** — Mapping `{ prosumer_id: address }` for the test participants; now also fixes the slot assignment.
- **`deployed_besu.json`** — Deployed contract and account addresses.
- **`leaves/<day>/<sid>.json`** — per-session leaves, salts and Merkle proofs written by the operator for distribution to prosumers (local, not versioned). V3 adds the daily commitment openings to the same channel.

### Configuration

- **`foundry.toml`** — Foundry project configuration. V3 requires `code_size_limit = 100000` (PoseidonT3 exceeds EIP-170), and `via_ir = true` with `optimizer = true` (the generated verifier does not compile otherwise).
- **`lib/`** — Git submodules: `forge-std`, `openzeppelin-contracts`, `prb-math`. `zk/package.json` pins `snarkjs`, `circomlib`, `circomlibjs`, `poseidon-solidity`; the `circom` compiler is a standalone binary.

---

## reference/

A copy of the paper authors' code and data (Fabi et al., arXiv:2512.24432). Contains the Nice and Paris datasets, including `NiceData/mpe_simulation_results_Nice.pkl` — the pre-computed Mean-Field equilibrium used as the source for `netputs_nice.json`, produced by `extract_nice_json.py`. Reference material, not part of the implementation.

---

## Design choices

- **Privacy by aggregation, then by commitment** — the mechanism's Anonymity axiom means pricing only needs aggregates, so individual 15-minute profiles stay off-chain under a Merkle commitment (V2). V3 removes the residual: daily net amounts and internal balances become Poseidon commitments, and the contract verifies the accounting on values it never sees. A full market day publishes roots, aggregates, prices, commitments, one community-level sum, and the voluntary deposit/withdrawal deltas — no netput, no individual amount, no balance.
- **A contract cannot keep a secret** — calldata is public and permanent, storage is readable by any node, and execution is replicated. Hiding a value therefore means either keeping it off-chain (the netputs) or making it verifiable without being visible (the amounts). There is no simpler intermediate rung; this is why V3 goes straight to proofs.
- **Two proofs of two different things** — Groth16 gives conservation and solvency over hidden values; Merkle plus the challenge give fidelity to the metered net positions. Neither subsumes the other, and dropping either one breaks a different property.
- **Solvency as impossibility, not detection** — the in-circuit range constraint on each new balance makes an insolvent day unprovable rather than rejectable, which removes the withdrawal floor and the `pendingDebit` freeze entirely.
- **Everything deterministic is on-chain** — the tariff calendar is computed from `block.timestamp`; only genuinely external data (day-ahead spot, when applicable) enters via the M-of-N feed, once a day.
- **No load-bearing process** — any time-triggered transition (`settle`, `finalizeDay`, the feed) is permissionless and idempotent; redundant keepers, one per validator organization, are the availability mechanism. On a private network with free gas there is no free-rider problem to price, so no keeper reward is needed.
- **Accountable metering** — the operator remains the single trust point at the physical-world boundary, but it is constrained: it cannot set prices, halt the market, create or destroy money, make anyone insolvent, rewrite its own commitments, or misstate an amount without the victim being able to prove it and cancel the day.
- **Confidentiality shifts data availability onto the participants** — the chain no longer holds the values, so the operator must retain the balance openings and each prosumer their receipts. This is a genuine operational regression against V2 and is stated, not hidden.
- **Prosumers** — sovereign as before: they hold their own keys, deposit and withdraw at will; the system never holds prosumer keys.
- **Mocked currency** — EEUR minting is mocked for the pilot; a collateral-backed version remains future work.

---

## What changed since Archi2

**Motivating critique.** Archi2 removed the 15-minute behavioral profile from the chain but still published one net € amount per prosumer per day in `closeDay` calldata. That residual is enough to infer multi-day absence and relative consumption levels for anyone able to link an address to a household — and, independently of any attacker model, publishing a per-household daily figure to every consortium node is a data-minimization problem under GDPR: the mechanism's accounting only needs the sum. Noise-based mitigations were evaluated and rejected: any unbiased noise averages out over repeated observation, so no calibration hides a prolonged absence while keeping payments exact, and noised-but-re-inferable pseudonymous data does not meet the anonymization standard. The only design that removes the leak is one where the amounts are not published at all — which requires the contract to verify accounting it cannot read.

**Contract changes.**

| | Archi2 | Archi3 |
|---|---|---|
| Daily net amounts | public in `closeDay` calldata | Poseidon commitments only |
| Internal balances | public mapping | commitments, advanced blind at finalize |
| Budget balance | `require(sum(amounts) ≈ dayNet)` | in-circuit sum; `require(sumShifted − N·2^127 ≈ dayNet)` |
| Solvency | balance checks, withdrawal floor, `pendingDebit` freeze | in-circuit range on the new balance: an insolvent day is unprovable |
| Deposits / withdrawals | immediate ledger moves | public signed deltas folded into the day's proof; payouts at finalize |
| Challenge | compare a public number | open a commitment (Poseidon binding), then the same recomputation |
| Accounts | any address, added at will | numbered slots fixed by the compiled circuit |
| Sessions, tariffs, pricing, keepers, netput Merkle | — | unchanged |

**Added.** `MarketZK.sol`, `DayBatchVerifier.sol` (generated), `PoseidonT3.sol` (vendored); `zk/daybatch.circom`, `zk/prove_day.js`, `zk/README-zk.md`; `test/MarketZK.t.sol`, `test/utils/ZKFixture.sol` (generated); `foundry.toml` now sets `code_size_limit`, `via_ir` and `optimizer`.

**Removed.** `Market.sol` and its tests (`Market.t.sol`, `Simulation.t.sol`, `SimulationNice.t.sol`) — superseded by `MarketZK.sol`. The V2 branch remains available for comparison. `setFloor` and `pendingDebit` are gone, subsumed by the in-circuit solvency constraint.

**Behavioral notes.** Session-level behavior, tariff re-anchoring and keeper dynamics are identical to Archi2; the Nice `t=48` session still clears at the off-peak mid-price (12.91 c€/kWh). Deployment gains two steps (library linking for `PoseidonT3`, deploying the verifier before the market) and a slot assignment step. `closeDayZK` measures ≈0.7M gas at N=2 in tests, dominated by the Groth16 verification, which grows by one scalar multiplication per public signal (≈6k gas), i.e. roughly linearly in N: budget ≈1.4M at N=50. Free gas on the private network makes this a throughput question, not a cost one. Proof generation takes seconds at these sizes and happens once a day.

**Known residuals** (documented, deliberate): the operator still sees all individual data — it reads the meters, and no cryptography addresses a lie at the source (see Open questions 4); deposits and withdrawals remain public, at times chosen by the user and therefore decorrelated from consumption; the community's daily net position against the grid is public by necessity, since it settles as an ERC-20 transfer; a prosumer whose opening the operator withholds cannot challenge (reveal-or-cancel, listed below).

---

## Conditions for production

V3's design is complete and the pipeline runs end to end, but three items must be closed before the system handles real money. They are properties of the current build, not of the architecture.

1. **Multi-party ceremony.** Groth16 requires a trusted setup per circuit; whoever holds the setup randomness can forge proofs — here, silently create money, with forged proofs indistinguishable from honest ones. The current ceremony has a single contributor and is a development artifact. Production requires an MPC ceremony in which each consortium organization contributes, security holding if one participant is honest — the same governance ritual as the validator set. Phase 1 can inherit a public perpetual powers-of-tau.
2. **Circuit review.** Under-constrained circuits are the primary vulnerability class in ZK systems, and a missing constraint fails silently rather than loudly. Required: line-by-line constraint review, static analysis (`circomspect`), and adversarial tests beyond those included.
3. **Batch size.** The compiled instance is `DayBatch(2)`. Production needs `DayBatch(50)` — or, preferably, batch chunking: keeping the circuit as a fixed-size building block and posting several proofs per day, with the contract summing across chunks. Chunking removes the community-size ceiling structurally and is the recommended path; over-provisioning empty slots is the cheap interim (empty slots are indistinguishable from inactive members, since fresh blinding is drawn each evening regardless).

Also outstanding: reveal-or-cancel, so that an operator withholding an opening loses the day (≈30 lines); the withdrawal floor as an in-circuit constraint if the policy is retained; a deterministic policy for dequeuing an over-withdrawal that would otherwise block the day's proof; and the operator's persistent opening state with a backup and restore procedure. A universal-setup system (PLONK) would remove condition 1's per-circuit repetition at the cost of a heavier verification (~400–500k gas) — a favorable trade on a free-gas chain if the circuit is expected to keep changing.

---

## Open questions (prosumer lifecycle)

1. **Registration** — how a new prosumer becomes a recognized participant: who validates local-community membership, adds their address to the metering scope, and assigns a circuit slot.
2. **Funding** — how a registered prosumer obtains EEUR: mocked mint, or self-funded collateral deposit.
3. **Metering bridge** — how net positions reach the operator each session, and what the real meter → optimization → netput source is.
4. **Trustworthy metering** — the operator can still misstate the physical reality itself. Merkle commitments make the lie non-repudiable rather than impossible: the false declaration is signed and timestamped, and the aggregate lies are constrained by the grid's own meter at the point of common coupling, which must match the daily grid leg. The residual is a constant-sum lie on individual netputs, detectable only against the prosumer's own meter. Meter-signed readings would make even that contestable on-chain (DePIN frontier, explicitly assumed away in the paper).
5. **Opening and leaf distribution & auto-verification** — replacing `leaves/*.json` with a real transport, and the prosumer client that recomputes its line each day, checks its opening against the posted commitment, and challenges automatically. In V3 this client is no longer optional convenience: it is the only way the amounts are ever checked.
6. **Keeper keys** — one signing key per validator organization (the daemon currently reuses the operator key as a placeholder).

One lifecycle: register and get a slot (1), fund (2), each session the meter feeds the operator (3, 4), each day the prosumer client verifies its opening and its leaves (5).
