// Off-circuit hashing helper: executed (never proven) to get the same Poseidon2 commitments as
// day_chunk, i.e. the position commitment of a member's day and a balance commitment.
// Build with `nargo compile` here; js_scripts/scenario.ts reads target/poseidon_helper.json.

use nodash::poseidon2;

global SESSIONS: u32 = 96; // fifteen-minute sessions in a day

fn main(
    slot: Field, // member's slot number
    nblind: Field, // seed of the position commitment
    sell: [Field; SESSIONS], // Wh offered per session
    buy: [Field; SESSIONS], // Wh demanded per session
    bal: Field, // balance to commit
    blind: Field, // its blinding factor
) -> pub [Field; 2] {
    let mut acc: Field = poseidon2([slot, nblind]); // same chain as day_chunk's hash_netputs
    for t in 0..SESSIONS {
        acc = poseidon2([acc, sell[t], buy[t]]);
    }
    [acc, poseidon2([bal, blind])] // position commitment, balance commitment
}
