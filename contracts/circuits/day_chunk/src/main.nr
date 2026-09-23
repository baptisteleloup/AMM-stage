use nodash::poseidon2;

// Batch circuit. One proof covers BATCH members for one whole day. 

global SESSIONS: u32 = 96; // fifteen-minute sessions in a day
global BATCH: u32 = 8;     // members per proof, the fixed width of the circuit

// Commitment to a balance or a floor: Poseidon2 hash of the value and a random blinding
// factor. The blinding factor prevents guessing small values by trying them all.
fn commit_balance(bal: Field, blind: Field) -> Field {
    poseidon2([bal, blind])
}

// Commitment to a member's day of positions, equation (2) of the paper. The chain starts
// from the slot number and a random seed, so that a day of inactivity is not guessable,
// then hashes the 96 (sell, buy) pairs one after the other, so that no position can be
// changed or moved to another session without changing the result.
fn hash_netputs(slot: Field, nblind: Field, sell: [Field; SESSIONS], buy: [Field; SESSIONS]) -> Field {
    let mut acc: Field = poseidon2([slot, nblind]);
    for t in 0..SESSIONS {
        acc = poseidon2([acc, sell[t], buy[t]]);
    }
    acc
}

// Public inputs are assembled by the market contract from its own storage, never by the
// prover (450 field elements in total). Private inputs are known to the operator only.
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
    floor_commits: pub [Field; BATCH],    // floor commitments frozen at midnight; the floor itself
                                          // stays private because it would reveal subscribed power
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
        // Slot 0 marks a padding lane, filled by the contract when the batch is not full.
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
            // A padding lane has only zero positions (already implied by participating = 0).
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

        // Statement 4: balance after the day's trades and deposit. The range check is what
        // enforces non-negativity: a negative value wraps around to a number of more than
        // 250 bits in the prime field and cannot pass.
        let after_trade = old_bals[n] + paid_out_n + deposits[n] - paid_in_n;
        after_trade.assert_max_bit_size::<64>();

        // Withdrawal capping: pay the request, or everything available if the request is larger.
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

    // Statements 2 and 5: the sums over the lanes equal the partial aggregates and totals
    // the prover declared. The contract later checks that the batches add up to the
    // aggregates posted during the day.
    for t in 0..SESSIONS {
        assert(acc_s[t] == partial_s[t]);
        assert(acc_d[t] == partial_d[t]);
    }
    assert(acc_out == partial_paid_out);
    assert(acc_in == partial_paid_in);
}

// Prints the two constants the contract needs for padding lanes: the commitment to 96
// zero positions under slot 0 and seed 0, and the commitment to a zero balance under
// blinding factor 0. They are injected into the market contract at deployment.
#[test]
fn print_contract_constants() {
    let zeros: [Field; SESSIONS] = [0; SESSIONS];
    let empty_hash = hash_netputs(0, 0, zeros, zeros);
    let zero_commit = commit_balance(0, 0);
    println(empty_hash);
    println(zero_commit);
}
