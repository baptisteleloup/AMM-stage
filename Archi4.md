# Architecture — Private Energy-Sharing Market (Noir / UltraHonk)

A local energy community trades surplus production between members at prices computed on-chain, better than the grid tariff for both sides. Individual consumption data never touches the chain: per-member amounts and balances are hidden behind commitments, and the daily settlement is proven correct with zero-knowledge proofs instead of being trusted or recomputed in public.

The stack: Solidity contracts on a permissioned Besu network (QBFT, free gas), circuits written in [Noir](https://noir-lang.org/), proofs generated and verified with UltraHonk ([Barretenberg](https://github.com/AztecProtocol/aztec-packages)) — no trusted setup, no per-circuit ceremony.

---



## Roles


| Role         | Held by                                                 | Powers                                                                                                                                                                              |
| ------------ | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `operator`   | the metering relay                                      | posts session aggregates, commits netputs, generates the daily proofs, answers data requests. **No discretion**: cannot set prices, settle, redistribute, censor, or withhold data. |
| `grid`       | the energy supplier (counterparty)                      | pays for the community's net surplus, is paid for its net deficit, at its own tariffs.                                                                                              |
| `floorAdmin` | the connection-data authority (DSO / community body)    | co-signs floor changes. Distinct from `grid` by design: the interested counterparty never decides who participates.                                                                 |
| `reserve`    | fixed address                                           | receives rounding dust.                                                                                                                                                             |
| keepers      | one daemon (a background process) per consortium member | call the permissionless functions (`finalizeDay`, `cancelDay`). Redundant: any one alive suffices.                                                                                  |
| prosumers    | the members                                             | deposit, trade, withdraw — and hold recourses (below) that can block or cancel a settlement.                                                                                        |




## The unit system

Everything internal is integer arithmetic — conservation is *exact*, no floating point anywhere:

- energy in **Wh** (`u32`), prices in **pEUR/Wh** (`u32`,
pico-euro = 10⁻¹² €), balances in **pEUR** (`u64`, max ≈ €18 M);
- one conversion at the edge: `PRICE_SCALE = 1e11` turns the fixed-point
tariff (UD60x18, cents/kWh) into integer pEUR/Wh
(10¹⁸ ÷ 10¹⁰ cent→pEUR × 10³ kWh→Wh); `WEI_PER_UNIT = 1e6` bridges
pEUR to the 18-decimals payment token;
- prices are rounded so the dust is **≥ 0 by construction** (seller
price down, buyer price up): the residual goes to `reserve`, never to
a participant.



## A day in the system

**During the day — 96 sessions of 15 minutes.** The session index ispure clock arithmetic (`timestamp / 900`): nobody opens or schedules a market round, it exists by consensus time. For each round the operator posts only two aggregates — total supply `s` and demand `d` — and the contract computes and stores the internal prices `(r, c)` from the grid
tariffs (`GridTariff`) and the pricing curve (`Pricing`). No money moves. Individual amounts are neither posted nor computable.

**At midnight — commit and freeze.** `postNetputHashes` publishes one **netput commitment per prosumer** (a Poseidon2 hash chain over their 96 `(sell, buy)` pairs, seeded with a private per-day blind) and, in the same transaction, **freezes a snapshot** of everything the settlement will use: the member count N, pending deposits, pending withdrawal requests, and the floor commitments. Proofs are generated against this frozen snapshot — state that keeps moving afterwards (a late deposit, a new registration) simply waits for the next day's snapshot.

**The proofs — one per chunk of 8.** The circuit has a fixed shape (`BATCH = 8` prosumers), so the community is settled in `K = ⌈N/8⌉`chunks, the last one padded with neutral slots. N is unbounded and frozen per day. Each chunk proof establishes, over private witnesses (the netputs, the cleartext balances, the blinds):

1. the private netputs hash to the published commitments;
2. their per-session sums match the chunk's announced partial
  aggregates — and the contract requires the K partials to add up to
   the `(s, d)` posted in session: **lying about aggregates makes the
   proof impossible**;
3. every member's daily amount is exactly
  `Σ (r·sell − c·buy)` at the stored prices — **fidelity is proven,
   not policed**;
4. every balance transition is correct and every new balance is ≥ 0
  (64-bit range check = solvency; a negative balance has no
   witness);
5. the chunk's money totals are conserved;
6. each floor opens against its frozen commitment, and participation
  is derived privately (`balance ≥ floor`) — never published.

Verified chunks are **staged**, not applied.

**The window — recourses before any money moves.** Between the freeze and the deadline, any prosumer can:

- `requestData` — force the operator to post their receipts and
balance opening on-chain, encrypted to their key (calldata = permanent
proof of delivery). An open request **blocks finalization**.
- `requestClearReveal` **→** `clearReveal` — escalate if the blob is
garbage: the operator must prove, with a dedicated `reveal` circuit,
that the on-chain balance commitment opens to the value announced in
the clear. The commitment's binding makes lying impossible here.
- `disputeDay` — contest the one thing no proof can cover: whether
the committed netputs match the physical meter. Bonded (anti-abuse);
adjudication is off-chain, with the DSO's allocated load curves as
the natural authoritative anchor.
- `cancelDay` — on verified grounds only (missing proofs at the
deadline, an unanswered data request, an unresolved dispute), anyone
cancels the day.

**After the deadline — permissionless settlement.** `finalizeDay` (callable by anyone) checks that all chunks are proven, no reveal is pending, no dispute is open; cross-checks aggregates and conservation; then applies everything at once: balance commitments advance, frozen deposits/withdrawals are consumed by subtraction, clamped withdrawals (`paid = min(request, available)` — proven in-circuit) are paid out in tokens, the grid leg settles the community's net position, dust accrues. **This is the only moment money moves.**

**If anything fails — clean cancellation.** A cancelled day changes one enum and nothing else: commitments do not advance, no funds move, frozen queues survive for the next day. The community simply traded at grid tariff that day. The failure mode of the whole system is a temporary return to the status quo — never a wrong or partial settlement. *The contract settles correctly, or it does not settle.*

## Privacy model

**Hidden by construction**: individual netputs (never on-chain; the hash chain is seeded with a private blind, so even an idle day — all zeros — is not guessable), amounts (recomputed in-circuit, never posted), balances and floors (Poseidon2 commitments), participation / exclusion (derived privately in-circuit).

**Public and accepted**: session aggregates and prices (the market itself — k-anonymity depends on community size), deposit and withdrawal amounts (real ERC20 transfers, member-timed; a clamped withdrawal additionally reveals the balance hit zero), the slot ↔ address directory (pseudonymous), metadata of exercising a recourse.

**Structural**: proof generation requires the witness — whoever runs the proving daemon sees the community's curves. In the realistic deployment this is the party that already legally sees them (the DSO's metering), so the system adds **no new observer** relative to the status quo; closing even that (TEE around the daemon, per-member proving, collaborative SNARKs) is future work.

**Operational requirement**: all blinds (balance, floor, hash seed) must be fresh every day, drawn from a CSPRNG, and archived — reused blinds leak equality ("balance unchanged"); lost blinds mean the operator can no longer prove.

## Floor governance

The floor (minimum provision, derived from subscribed power) is the admission lever, and admission depends on an off-chain fact — so it is an oracle, constrained rather than eliminated:

- the floor value is **committed** (cleartext would betray subscribed
power); the circuit opens it privately against the frozen snapshot;
- changes require **two distinct roles**: `proposeFloor` (operator) then
`confirmFloor` (`floorAdmin`, the connection-data authority). The
operator alone can exclude nobody;
- the target is notified (`FloorProposed`/`FloorSet` events) and holds
the opening — they can publish it and prove abuse (binding);
- optional hardening: an in-circuit `FLOOR_CAP`
(`assert(floor ≤ CAP)`) making anyone with `balance ≥ CAP`
mathematically unexcludable — one line, to bundle with the next
verifier regeneration.



## Verifier facts

- UltraHonk, universal SRS: recompiling a circuit requires only
`nargo compile` + regenerating the Solidity verifier (the verification
key is hardcoded in the generated contract) + redeploying it. No
ceremony, ever.
- Current `day_chunk` verifier: `LOG_N = 17` (2¹⁷ rows),
`NUMBER_OF_PUBLIC_INPUTS = 466` (450 application inputs + 16 bb
pairing points). Re-check both constants after every regeneration.
- ~23.7 KB per verifier — mind EIP-170 / the genesis
`contractSizeLimit`.
- Prover pinned to a bb.js nightly with the `verifierTarget: "evm"`
flavor (keccak transcript + ZK); the padding constants
(`EMPTY_NETPUT_HASH`, `ZERO_BAL_COMMIT`) are printed by
`nargo test print_contract_constants` and injected at deployment —
they come *from* the circuit, so they match by construction.
- Failed verification **reverts** with custom errors
(`SumcheckFailed`, …), it never returns `false`; a failed chunk
submission is atomic and retryable until the deadline.



## Known limits and open questions

- **Meter fidelity is the irreducible residual**: no proof can check
committed netputs against the physical world. The bonded dispute +
the DSO anchor frame it; a signing meter would close it.
- **A cancelled day is not re-settled** — resuming next day from the
previous balances works as-is; recovering the lost day's internal
trades is an open design choice (bounded re-close vs status quo).
- `requestData` **is free and unconditional** — a griefing path
(request → operator outage → collective cancellation) exists; options:
a symmetric bond, rate-limiting, or acceptance (permissioned
membership, zero attacker gain).
- **Dispute bond** amount and refund/forfeiture rules are governance
placeholders.
- **The prosumer client** (recompute the hash, decrypt blobs, margin
alerts, exercise recourses) is the largest missing component — the
recourses only protect members who actually verify.
- Keeper daemons and deployment scripts must track the current
interfaces (the constructor takes 10 arguments, including
`floorAdmin`).

