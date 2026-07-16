pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/bitify.circom";

// One day's netting batch, verified in zero knowledge.
// For each account slot n (fixed N at compile, pad with zero-amount slots):
//   - amtC[n]  commits the day's net amount (shifted by 2^127 to encode sign)
//   - oldC[n]  commits the balance before the day, newC[n] after
//   - delta[n] is the PUBLIC deposit/withdraw net of the day (shifted)
// Constraints: openings match, amount in (-2^127, 2^127), new balance in [0, 2^128)
// (solvency lives HERE: an insolvent account makes the proof impossible),
// and sum of shifted amounts equals the public sumShifted.
template DayBatch(N) {
    var SHIFT = 170141183460469231731687303715884105728; // 2^127

    // public
    signal input oldC[N];
    signal input amtC[N];
    signal input newC[N];
    signal input delta[N];      // shifted: real delta + 2^63
    signal output sumShifted;   // sum of shifted amounts

    // private
    signal input oldBal[N];
    signal input oldR[N];
    signal input amt[N];        // shifted: real amount + 2^63
    signal input amtR[N];
    signal input newR[N];

    component openOld[N];
    component openAmt[N];
    component openNew[N];
    component rangeAmt[N];
    component rangeNew[N];
    signal newBal[N];

    var acc = 0;
    for (var n = 0; n < N; n++) {
        // openings
        openOld[n] = Poseidon(2);
        openOld[n].inputs[0] <== oldBal[n];
        openOld[n].inputs[1] <== oldR[n];
        openOld[n].out === oldC[n];

        openAmt[n] = Poseidon(2);
        openAmt[n].inputs[0] <== amt[n];
        openAmt[n].inputs[1] <== amtR[n];
        openAmt[n].out === amtC[n];

        // amount range: shifted value fits in 64 bits
        rangeAmt[n] = Num2Bits(128);
        rangeAmt[n].in <== amt[n];

        // balance transition (delta is shifted too, so subtract 2*SHIFT)
        newBal[n] <== oldBal[n] + amt[n] + delta[n] - 2 * SHIFT;

        // solvency + bound: new balance in [0, 2^64). A negative balance
        // wraps in the field and cannot fit 64 bits: no proof exists.
        rangeNew[n] = Num2Bits(128);
        rangeNew[n].in <== newBal[n];

        openNew[n] = Poseidon(2);
        openNew[n].inputs[0] <== newBal[n];
        openNew[n].inputs[1] <== newR[n];
        openNew[n].out === newC[n];

        acc += amt[n];
    }
    sumShifted <== acc;
}

component main { public [oldC, amtC, newC, delta] } = DayBatch(2);
