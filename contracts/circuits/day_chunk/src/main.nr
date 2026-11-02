// Batch circuit: one proof settles one day for BATCH members. It checks their committed positions,
// recomputes their payments at the on-chain prices, updates their balance commitments and caps
// withdrawals. Build with `nargo compile` here; the operator (prove.ts) reads target/day_chunk.json.

use nodash::poseidon2;

global SESSIONS: u32 = 96; // fifteen-minute sessions in a day
global BATCH: u32 = 8;     // members per proof, the fixed width of the circuit

// Commitment to a balance or a floor. The random blinding stops anyone from trying all small values.
fn commit_balance(bal: Field, blind: Field) -> Field {
    poseidon2([bal, blind])
}

// Commitment to a member's 96 positions, the hash chain of the paper. Seeded with the slot and a
// random seed (an idle day is not guessable), then chained so no position can change or move.
fn hash_netputs(slot: Field, nblind: Field, sell: [Field; SESSIONS], buy: [Field; SESSIONS]) -> Field {
    let mut acc: Field = poseidon2([slot, nblind]);
    for t in 0..SESSIONS {
        acc = poseidon2([acc, sell[t], buy[t]]);
    }
    acc
}

// Public inputs (450 fields) are built by MarketV4 from its storage. Private inputs are the operator's.
fn main(
    price_r: pub [Field; SESSIONS],       // seller rate of each session, as recorded on chain (1e-9 currency per kWh)
    price_c: pub [Field; SESSIONS],       // buyer rate of each session, as recorded on chain
    slots: pub [Field; BATCH],            // slot number of each lane, 0 for a padding lane
    netput_hashes: pub [Field; BATCH],    // position commitments posted at midnight
    old_commits: pub [Field; BATCH],      // balance commitments currently in storage
    new_commits: pub [Field; BATCH],      // new balance commitments claimed by the prover
    deposits: pub [Field; BATCH],         // deposits frozen at midnight, applied today (1e-12 currency)
    withdrawals: pub [Field; BATCH],      // withdrawal REQUESTS frozen at midnight
    withdrawals_paid: pub [Field; BATCH], // what is actually paid, min(request, available), claimed by the prover
    floor_commits: pub [Field; BATCH],    // floor commitments frozen at midnight (the floor stays private)
    partial_s: pub [Field; SESSIONS],     // the batch's share of the supply aggregate, per session
    partial_d: pub [Field; SESSIONS],     // the batch's share of the demand aggregate, per session
    partial_paid_out: pub Field,          // total paid to the batch's sellers over the day
    partial_paid_in: pub Field,           // total paid by the batch's buyers over the day
    sell: [[Field; SESSIONS]; BATCH],     // energy offered by each member in each session (Wh)
    buy: [[Field; SESSIONS]; BATCH],      // energy demanded by each member in each session (Wh)
    old_bals: [Field; BATCH],             // opening balances in the clear
    old_blinds: [Field; BATCH],           // blinding factors of the opening balance commitments
    new_blinds: [Field; BATCH],           // blinding factors of the new balance commitments
    floors: [Field; BATCH],               // floors in the clear
    floor_blinds: [Field; BATCH],         // blinding factors of the floor commitments
    netput_blinds: [Field; BATCH],        // seeds of the position commitments (one per member and day)
) {
    // Running sums over the lanes: aggregates per session and money totals.
    let mut acc_s: [Field; SESSIONS] = [0; SESSIONS];
    let mut acc_d: [Field; SESSIONS] = [0; SESSIONS];
    let mut acc_out: Field = 0;
    let mut acc_in: Field = 0;

    for n in 0..BATCH {
        // Slot 0 marks a padding lane, used when the batch is not full.
        let is_padding = slots[n] == 0;

        // Balance and floor must fit in 64 bits, the width of the contract's balances.
        old_bals[n].assert_max_bit_size::<64>();
        floors[n].assert_max_bit_size::<64>();
        // Statement 1: the private opening balance opens the commitment in storage...
        assert(commit_balance(old_bals[n], old_blinds[n]) == old_commits[n]);

        // ...and the private floor opens the floor commitment frozen at midnight.
        assert(commit_balance(floors[n], floor_blinds[n]) == floor_commits[n]);

        // Statement 6: participation bit. A member takes part in the day only if its
        // opening balance is at least its floor. A padding lane never takes part.
        let participating: Field = if is_padding {
            0
        } else if (old_bals[n] as u64) >= (floors[n] as u64) {
            1
        } else {
            0
        };

        // Money received and paid by this member over the day.
        let mut paid_out_n: Field = 0;
        let mut paid_in_n: Field = 0;

        for t in 0..SESSIONS {
            // Energies fit in 32 bits, the width of the contract's aggregates.
            sell[n][t].assert_max_bit_size::<32>();
            buy[n][t].assert_max_bit_size::<32>();
            // A member is on one side of the market at most in a session.
            assert(sell[n][t] * buy[n][t] == 0);
            // A member below its floor has only zero positions.
            assert(sell[n][t] * (1 - participating) == 0);
            assert(buy[n][t] * (1 - participating) == 0);
            // A padding lane has only zero positions (also implied by participating = 0).
            if is_padding {
                assert(sell[n][t] == 0);
                assert(buy[n][t] == 0);
            }

            // Statement 2: add this member's positions to the batch's partial aggregates.
            acc_s[t] = acc_s[t] + sell[n][t];
            acc_d[t] = acc_d[t] + buy[n][t];

            // Statement 3: amounts recomputed from the recorded prices. Price (1e-9 per kWh)
            // times energy (Wh) is an exact integer in units of 1e-12 of the currency.
            paid_out_n = paid_out_n + price_r[t] * sell[n][t];
            paid_in_n = paid_in_n + price_c[t] * buy[n][t];
        }

        // Statement 1 again: the positions used above are exactly those committed at midnight.
        let h = hash_netputs(slots[n], netput_blinds[n], sell[n], buy[n]);
        assert(h == netput_hashes[n]);

        // A padding lane carries no money and a zero seed, so its commitment is the
        // constant EMPTY_NETPUT_HASH the contract supplies.
        if is_padding {
            assert(deposits[n] == 0);
            assert(withdrawals[n] == 0);
            assert(netput_blinds[n] == 0);
        }

        // Statement 4: balance after trades and deposit. The 64-bit check enforces non-negativity,
        // since a negative value wraps to a field element of more than 250 bits.
        let after_trade = old_bals[n] + paid_out_n + deposits[n] - paid_in_n;
        after_trade.assert_max_bit_size::<64>();

        // Withdrawal capping: paid = min(request, available).
        withdrawals[n].assert_max_bit_size::<64>();
        let avail = after_trade as u64;
        let req = withdrawals[n] as u64;
        let paid = if req < avail { req } else { avail };
        assert(paid as Field == withdrawals_paid[n]);

        // New balance, non-negative by construction, checked to 64 bits like the old one.
        let new_bal = after_trade - (paid as Field);
        new_bal.assert_max_bit_size::<64>();

        // The new balance opens the new commitment the contract will store at settlement.
        assert(commit_balance(new_bal, new_blinds[n]) == new_commits[n]);

        acc_out = acc_out + paid_out_n;
        acc_in = acc_in + paid_in_n;
    }

    // Statements 2 and 5: lane sums equal the declared partial aggregates and totals.
    // MarketV4 then checks that the batches add up to the aggregates posted during the day.
    for t in 0..SESSIONS {
        assert(acc_s[t] == partial_s[t]);
        assert(acc_d[t] == partial_d[t]);
    }
    assert(acc_out == partial_paid_out);
    assert(acc_in == partial_paid_in);
}

// `nargo test --show-output` prints the two padding constants given to MarketV4 at deployment:
// EMPTY_NETPUT_HASH (96 zero positions, slot 0, seed 0) and ZERO_BAL_COMMIT (balance 0, blinding 0).
#[test]
fn print_contract_constants() {
    let zeros: [Field; SESSIONS] = [0; SESSIONS];
    let empty_hash = hash_netputs(0, 0, zeros, zeros);
    let zero_commit = commit_balance(0, 0);
    println(empty_hash);
    println(zero_commit);
}
