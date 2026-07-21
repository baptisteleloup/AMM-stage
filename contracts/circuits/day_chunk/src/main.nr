use nodash::poseidon2;

global SESSIONS: u32 = 96; 
global BATCH: u32 = 8;    

fn commit_balance(bal: Field, blind: Field) -> Field {
    poseidon2([bal, blind])
}

fn hash_netputs(slot: Field, nblind: Field, sell: [Field; SESSIONS], buy: [Field; SESSIONS]) -> Field {
    let mut acc: Field = poseidon2([slot, nblind]);
    for t in 0..SESSIONS {
        acc = poseidon2([acc, sell[t], buy[t]]);
    }
    acc
}

fn main(
    price_r: pub [Field; SESSIONS],       // sell prices stored on-chain (pEUR/unit)
    price_c: pub [Field; SESSIONS],       // buy prices stored on-chain
    slots: pub [Field; BATCH],            // slot ids of this chunk (0 = padding)
    netput_hashes: pub [Field; BATCH],    // per-prosumer published commitments
    old_commits: pub [Field; BATCH],      // balance commitments in storage
    new_commits: pub [Field; BATCH],      // proposed new commitments
    deposits: pub [Field; BATCH],         // public deposits for the day (pEUR)
    withdrawals: pub [Field; BATCH],      // withdrawal REQUESTS frozen for the day (pEUR)
    withdrawals_paid: pub [Field; BATCH], // what is actually paid = min(request, available)
    floor_commits: pub [Field; BATCH],    // [D9 + RGPD] commit(floor, blind), from storage,
                                          // frozen at postNetputHashes. Replaces the
                                          // former public `floors` (leaked subscribed power).
    partial_s: pub [Field; SESSIONS],     // chunk's partial supply sums
    partial_d: pub [Field; SESSIONS],     // chunk's partial demand sums
    partial_paid_out: pub Field,          // Sum of amounts paid to sellers (batch)
    partial_paid_in: pub Field,           // Sum of amounts paid by buyers (batch)
    sell: [[Field; SESSIONS]; BATCH],     // energy sold per session (Wh-quarter)
    buy: [[Field; SESSIONS]; BATCH],      // energy bought per session
    old_bals: [Field; BATCH],             // cleartext balances (pEUR)
    old_blinds: [Field; BATCH],           // blinding factors of old commitments
    new_blinds: [Field; BATCH],           // blinding factors of new commitments
    floors: [Field; BATCH],               // [RGPD] cleartext floors -- PRIVATE now
    floor_blinds: [Field; BATCH],         // blinding factors of floor_commits
    netput_blinds: [Field; BATCH],        // [RGPD 2] per-(slot, day) seed blinds
) {
    let mut acc_s: [Field; SESSIONS] = [0; SESSIONS];
    let mut acc_d: [Field; SESSIONS] = [0; SESSIONS];
    let mut acc_out: Field = 0;
    let mut acc_in: Field = 0;

    for n in 0..BATCH {
        let is_padding = slots[n] == 0;

        old_bals[n].assert_max_bit_size::<64>();
        floors[n].assert_max_bit_size::<64>();
        assert(commit_balance(old_bals[n], old_blinds[n]) == old_commits[n]);

        assert(commit_balance(floors[n], floor_blinds[n]) == floor_commits[n]);

        let participating: Field = if is_padding {
            0
        } else if (old_bals[n] as u64) >= (floors[n] as u64) {
            1
        } else {
            0
        };

        let mut paid_out_n: Field = 0; 
        let mut paid_in_n: Field = 0; 

        for t in 0..SESSIONS {
            sell[n][t].assert_max_bit_size::<32>();
            buy[n][t].assert_max_bit_size::<32>();
            assert(sell[n][t] * buy[n][t] == 0);
            assert(sell[n][t] * (1 - participating) == 0);
            assert(buy[n][t] * (1 - participating) == 0);
            if is_padding {
                assert(sell[n][t] == 0);
                assert(buy[n][t] == 0);
            }

        
            acc_s[t] = acc_s[t] + sell[n][t];
            acc_d[t] = acc_d[t] + buy[n][t];

        
            paid_out_n = paid_out_n + price_r[t] * sell[n][t];
            paid_in_n = paid_in_n + price_c[t] * buy[n][t];
        }

        let h = hash_netputs(slots[n], netput_blinds[n], sell[n], buy[n]);
        assert(h == netput_hashes[n]);

        if is_padding {
            assert(deposits[n] == 0);
            assert(withdrawals[n] == 0);
            assert(netput_blinds[n] == 0);
        }

        let after_trade = old_bals[n] + paid_out_n + deposits[n] - paid_in_n;
        after_trade.assert_max_bit_size::<64>();

        withdrawals[n].assert_max_bit_size::<64>();
        let avail = after_trade as u64;
        let req = withdrawals[n] as u64;
        let paid = if req < avail { req } else { avail };
        assert(paid as Field == withdrawals_paid[n]);

        let new_bal = after_trade - (paid as Field);
        new_bal.assert_max_bit_size::<64>();

        assert(commit_balance(new_bal, new_blinds[n]) == new_commits[n]);

        acc_out = acc_out + paid_out_n;
        acc_in = acc_in + paid_in_n;
    }

    for t in 0..SESSIONS {
        assert(acc_s[t] == partial_s[t]);
        assert(acc_d[t] == partial_d[t]);
    }
    assert(acc_out == partial_paid_out);
    assert(acc_in == partial_paid_in);
}

#[test]
fn print_contract_constants() {
    let zeros: [Field; SESSIONS] = [0; SESSIONS];
    let empty_hash = hash_netputs(0, 0, zeros, zeros);
    let zero_commit = commit_balance(0, 0);
    println(empty_hash);
    println(zero_commit);
}
