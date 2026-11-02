// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {UD60x18} from "@prb/math/src/UD60x18.sol";

// What the market needs from the pricing contract: the two session rates for the
// aggregates (s, d) under the band (lambdaLow, lambdaHigh), in 18-decimal fixed point.
interface IPricing {
    function prices(UD60x18 s, UD60x18 d, UD60x18 lambdaLow, UD60x18 lambdaHigh)
        external
        view
        returns (UD60x18 r, UD60x18 c);
}
