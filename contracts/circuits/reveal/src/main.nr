
use nodash::poseidon2;

fn main(
    commitment: pub Field,
    bal: pub Field,        
    blind: Field,          
) {
    bal.assert_max_bit_size::<64>();
    assert(poseidon2([bal, blind]) == commitment);
}
