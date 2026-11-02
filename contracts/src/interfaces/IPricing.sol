// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

// Session rates (r, c) for the aggregates (s, d) under the band (lambdaLow, lambdaHigh), in
// 18-decimal fixed point. Implemented by Pricing, called by MarketV4.openSession.

import {UD60x18} from "@prb/math/src/UD60x18.sol";

interface IPricing {
    function prices(UD60x18 s, UD60x18 d, UD60x18 lambdaLow, UD60x18 lambdaHigh)
        external
        view
        returns (UD60x18 r, UD60x18 c);
}
