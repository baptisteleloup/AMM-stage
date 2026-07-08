// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";

/// @title  Pricing — linear curve
/// @dev    Pure library, without status. Entirely in UD60x18 (18 decimal places).
///         Unit: Use the same unit as the oracle (c€/kWh).


library Pricing {

    /// @notice Intern price ρ = (λ_low + λ_high) / 2 
    function mid(UD60x18 lambdaLow, UD60x18 lambdaHigh) internal pure returns (UD60x18)
    {
        return lambdaLow.add(lambdaHigh).div(ud(2e18));
    }

    /// @notice Marginal prices (r, c) based on supply and demand aggregates.
    /// @param  s          aggregate supply (kWh)
    /// @param  d          aggregate demand (kWh)
    /// @param  lambdaLow  feed-in tarif 
    /// @param  lambdaHigh retail price 
    function prices(
        UD60x18 s,
        UD60x18 d,
        UD60x18 lambdaLow,
        UD60x18 lambdaHigh
    ) internal pure returns (UD60x18 r, UD60x18 c) {
        UD60x18 rho = mid(lambdaLow, lambdaHigh);

        UD60x18 ratioSD = _ratioOrZero(s, d); // y   = s/d
        UD60x18 ratioDS = _ratioOrZero(d, s); // 1/y = d/s

        // c = ρ + (λ̄ − ρ)·(1 − y)⁺
        c = rho.add( lambdaHigh.sub(rho).mul(_oneMinusOrZero(ratioSD)) );

        // r = ρ − (ρ − λ)·(1 − 1/y)⁺
        r = rho.sub( rho.sub(lambdaLow).mul(_oneMinusOrZero(ratioDS)) );
    }

    /// @notice ΔE = min(s, d).
    function matched(UD60x18 s, UD60x18 d) internal pure returns (UD60x18) {
        return s.lt(d) ? s : d;
    }

    /// @notice pool value : M = ρ · ΔE 
    function poolValue(UD60x18 rho, UD60x18 deltaE) internal pure returns (UD60x18) {
        return rho.mul(deltaE);
    }

    /// @notice total buyer cost (Ctotal) and total seller revenue (Rtotal)
    function totals(
        UD60x18 s,
        UD60x18 d,
        UD60x18 lambdaLow,
        UD60x18 lambdaHigh
    ) internal pure returns (UD60x18 cTotal, UD60x18 rTotal) {
        UD60x18 rho = mid(lambdaLow, lambdaHigh);
        UD60x18 deltaE = matched(s, d);
        UD60x18 M = poolValue(rho, deltaE); 

        if (d.lt(s)) {
            // Case II surplus
            cTotal = M;
            rTotal = M.add(lambdaLow.mul(s.sub(d)));
        } else if (s.lt(d)) {
            // Case III deficit 
            rTotal = M;
            cTotal = M.add(lambdaHigh.mul(d.sub(s)));
        } else {
            // Case I balanced
            cTotal = M;
            rTotal = M;
        }
    }

    /// @dev a/b, or 0 si b == 0 
    function _ratioOrZero(UD60x18 a, UD60x18 b)
        private pure returns (UD60x18)
    {
        return b.unwrap() == 0 ? ud(0) : a.div(b);
    }

    /// @dev (1 − x)⁺ = max(1 − x, 0)
    function _oneMinusOrZero(UD60x18 x)
        private pure returns (UD60x18)
    {
        UD60x18 one = ud(1e18);
        return x.lt(one) ? one.sub(x) : ud(0);
    }
}