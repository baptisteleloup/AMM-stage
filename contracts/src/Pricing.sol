// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";

library Pricing {
    function mid(UD60x18 lambdaLow, UD60x18 lambdaHigh) internal pure returns (UD60x18) {
        return lambdaLow.add(lambdaHigh).div(ud(2e18));
    }

    function prices(UD60x18 s, UD60x18 d, UD60x18 lambdaLow, UD60x18 lambdaHigh)
        internal
        pure
        returns (UD60x18 r, UD60x18 c)
    {
        UD60x18 rho = mid(lambdaLow, lambdaHigh);

        UD60x18 ratioSD = _ratioOrZero(s, d); 
        UD60x18 ratioDS = _ratioOrZero(d, s);

        c = rho.add(lambdaHigh.sub(rho).mul(_oneMinusOrZero(ratioSD)));
        r = rho.sub(rho.sub(lambdaLow).mul(_oneMinusOrZero(ratioDS)));
    }

    function matched(UD60x18 s, UD60x18 d) internal pure returns (UD60x18) {
        return s.lt(d) ? s : d;
    }

    function poolValue(UD60x18 rho, UD60x18 deltaE) internal pure returns (UD60x18) {
        return rho.mul(deltaE);
    }

    function totals(UD60x18 s, UD60x18 d, UD60x18 lambdaLow, UD60x18 lambdaHigh)
        internal
        pure
        returns (UD60x18 cTotal, UD60x18 rTotal)
    {
        UD60x18 rho = mid(lambdaLow, lambdaHigh);
        UD60x18 deltaE = matched(s, d);
        UD60x18 M = poolValue(rho, deltaE);

        if (d.lt(s)) {
            cTotal = M;
            rTotal = M.add(lambdaLow.mul(s.sub(d)));
        } else if (s.lt(d)) {
            rTotal = M;
            cTotal = M.add(lambdaHigh.mul(d.sub(s)));
        } else {
            cTotal = M;
            rTotal = M;
        }
    }

    function _ratioOrZero(UD60x18 a, UD60x18 b) private pure returns (UD60x18) {
        return b.unwrap() == 0 ? ud(0) : a.div(b);
    }

    function _oneMinusOrZero(UD60x18 x) private pure returns (UD60x18) {
        UD60x18 one = ud(1e18);
        return x.lt(one) ? one.sub(x) : ud(0);
    }
}
