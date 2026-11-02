// Reveal circuit: proves that a public balance opens a balance commitment, without the blinding.
// Used by MarketV4.clearReveal (recourse, stage 2) and MarketV4.escape.
// Build with `nargo compile` here; the operator and generateProof_reveal.ts read target/reveal.json.

use nodash::poseidon2;

fn main(
    commitment: pub Field, // balance commitment stored on chain
    bal: pub Field, // balance claimed in the clear
    blind: Field, // blinding factor, known to the operator and the member
) {
    bal.assert_max_bit_size::<64>(); // fits the contract's uint64 balance
    assert(poseidon2([bal, blind]) == commitment); // bal opens the commitment
}
