# Private Energy-Sharing Market — V4 (Noir / UltraHonk)

A local energy community trades surplus production between members at prices computed on-chain, better than the grid tariff for both sides. Individual consumption data never touches the chain: amounts and balances live behind Poseidon2 commitments, and the daily settlement is **proven correct with zero-knowledge proofs** — conservation, solvency, and fidelity to each member's committed consumption — instead of being trusted or recomputed in public.

**Stack**: Solidity on a permissioned [Besu](https://besu.hyperledger.org/) network (QBFT, free gas) · circuits in [Noir](https://noir-lang.org/) · proving/verification with UltraHonk ([Barretenberg](https://github.com/AztecProtocol/aztec-packages)) — universal SRS, **no per-circuit trusted setup**.

→ Full design: `[Archi4.md](./Archi4.md)`

---



## Version history

This repository is the fourth iteration of the same market. The thread running through them: **every piece of data you hide destroys a verification that used to be free, and must be bought back — first with a recourse, then with cryptography.**


| Version | What it did                                                                                                                                                                                                                                                                                     | What it paid                                                                                                                                                                    |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **V1**  | Everything in cleartext on-chain; the contract computed the whole settlement (prices, pro-rata, collateral) from posted netputs — wrong settlement impossible by re-execution.                                                                                                                  | Zero privacy: individual load curves public at 15-min resolution (a presence sensor).                                                                                           |
| **V2**  | Netputs move off-chain (aggregates + Merkle root only), clock-driven sessions, permissionless settle, daily netting.                                                                                                                                                                            | The contract can no longer check individual amounts → a Merkle **challenge** lets the victim contest, at the cost of revealing their own data. Amounts & balances still public. |
| **V3**  | Amounts and balances hidden behind commitments; one Groth16 proof per day (conservation + solvency). Challenge retained for fidelity.                                                                                                                                                           | Per-circuit trusted-setup ceremony (toxic waste), N frozen by the circuit, 44 KB of on-chain Poseidon.                                                                          |
| **V4**  | Fidelity moves **into the circuit** (the challenge dies), UltraHonk removes the ceremony, chunking unfreezes N, two-stage reveal-or-cancel guarantees data availability, privacy side-channels closed (private participation, committed floors, seeded netput hashes), floor changes co-signed. | The residual, named: the prover sees the witness; meter fidelity stays off-chain (bonded dispute).                                                                              |




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
├── js_scripts/               # scenario + proof generation (noir_js / bb.js)
├── test/
│   ├── MarketV4.t.sol        # 91 mock tests (verifiers stubbed)
│   └── MarketV4.ffi.t.sol    # full real cycle: TS proves, Solidity verifies (vm.ffi)

```



## Build & test

```bash
# 1. Solidity, mock suite (fast — verifiers stubbed)
forge test --no-match-contract FFI

# 2. Full cycle with real proofs (needs node deps + nargo + bb)
cd js_scripts && npm install && cd ..
forge test                      # includes the FFI test: TS generates, chain verifies
```



### Rebuilding the circuits / verifier

Any circuit change requires recompiling and regenerating the verifier — **no ceremony**:

```bash
cd circuits/day_chunk
nargo compile                                   # -> target/day_chunk.json
bb write_vk -b target/day_chunk.json -o target --oracle_hash keccak
bb write_solidity_verifier -k target/vk -o ../../src/DayChunkVerifier.sol
```

Then sanity-check the two constants at the top of the generated file: `LOG_N = 17`, `NUMBER_OF_PUBLIC_INPUTS = 466`. If either moved, more than you intended changed. The `poseidon_helper` circuit must be recompiled too whenever the hash format changes (`nargo compile` in its folder) — the TS scripts execute it.

### Padding constants

`EMPTY_NETPUT_HASH` and `ZERO_BAL_COMMIT` are printed by the circuit itself and injected at deployment:

```bash
cd circuits/day_chunk && nargo test --show-output   # print_contract_constants
```

They come *from* the circuit, so they match Poseidon2 by construction — never recompute them with another implementation.

## Pinned versions & known traps

- **bb.js**: pinned nightly; the prover **must** use the `verifierTarget: "evm"` flavor (keccak transcript + ZK). The
`keccak: true` option generates a *non-ZK* proof of the wrong size →`ProofLengthWrongWithLogN` on-chain.
- The generated verifier **reverts** with custom errors (`SumcheckFailed`, `PublicInputsLengthWrong`, …) — it never returns
`false`. The most common failure, `SumcheckFailed`, means one public input differs between prover and contract.
- Verifiers are ~23.7 KB each — close to EIP-170; the genesis `contractSizeLimit` is the guardrail on the consortium chain.
- The `MarketV4` constructor takes **10 arguments** (token, two verifiers, tariff, operator, grid, floorAdmin, reserve, two padding constants) — keep deployment scripts in sync.



## Status

- Contracts + circuits: **complete and green** — 91 mock tests + the full FFI cycle (real UltraHonk proofs verified on-chain).
- Not yet built: the **prosumer client** (recompute the netput hash, decrypt reveal blobs, margin alerts — the recourses only protect members who verify), keeper-daemon migration, deployment scripts for the consortium network.
- Open design questions (dispute adjudication & bond, cancelled-day re-close, `requestData` griefing, `FLOOR_CAP`): see the end of
`[Archi4.md](./Archi4.md)`.

