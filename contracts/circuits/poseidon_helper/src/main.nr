
use nodash::poseidon2;

global SESSIONS: u32 = 96;

fn main(
    slot: Field,
    nblind: Field, 
    sell: [Field; SESSIONS],
    buy: [Field; SESSIONS],
    bal: Field,
    blind: Field,
) -> pub [Field; 2] {
    let mut acc: Field = poseidon2([slot, nblind]);
    for t in 0..SESSIONS {
        acc = poseidon2([acc, sell[t], buy[t]]);
    }
    
    [acc, poseidon2([bal, blind])]
}
