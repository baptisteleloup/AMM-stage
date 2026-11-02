// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {IPricing} from "./interfaces/IPricing.sol";

// The three pricing rules of Fabi et al., as pure functions of the session
// aggregates (s, d) and of the tariff band (lambdaLow, lambdaHigh). Prices and
// bounds are 18-decimal fixed-point numbers in the tariff's unit (cents per kWh).
//
// Every rule returns a seller rate r and a buyer rate c with r <= c, both inside
// the band, and satisfying the budget identity d*c - s*r = hi*(d-s)^+ - lo*(s-d)^+.
// The market then rounds r down and c up to its 32-bit grain, which is where the
// direction of rounding is enforced; the fixed-point error here is ten orders of
// magnitude below that grain.
library PricingLib {
    enum Rule {
        MidMarket,          // internal price at the midpoint of the band
        SupplyDemandRatio,  // seller price falls with s/d, buyer price by budget balance
        Hyperbolic          // constant-product trading function adapted to the band
    }

    UD60x18 private constant ONE = UD60x18.wrap(1e18);

    function prices(Rule rule, UD60x18 s, UD60x18 d, UD60x18 lambdaLow, UD60x18 lambdaHigh)
        internal
        pure
        returns (UD60x18 r, UD60x18 c)
    {
        require(lambdaLow.lte(lambdaHigh), "band");
        // An empty side has nothing to price: the side that is present trades with the
        // grid, and the absent side's price is immaterial. Every rule agrees on this.
        if (s.unwrap() == 0 || d.unwrap() == 0) return (lambdaLow, lambdaHigh);
        if (lambdaLow.unwrap() == lambdaHigh.unwrap()) return (lambdaLow, lambdaHigh);

        if (rule == Rule.MidMarket) return _midMarket(s, d, lambdaLow, lambdaHigh);
        if (rule == Rule.SupplyDemandRatio) return _supplyDemandRatio(s, d, lambdaLow, lambdaHigh);
        return _hyperbolic(s, d, lambdaLow, lambdaHigh);
    }

    // Rule (1) of the paper. u = (1 - d/s)^+ is the share of supply sold to the grid,
    // v = (1 - s/d)^+ the share of demand bought from it.
    function _midMarket(UD60x18 s, UD60x18 d, UD60x18 lo, UD60x18 hi)
        private
        pure
        returns (UD60x18 r, UD60x18 c)
    {
        UD60x18 rho = lo.add(hi).div(ud(2e18));
        UD60x18 u = _oneMinusOrZero(d.div(s));
        UD60x18 v = _oneMinusOrZero(s.div(d));
        r = rho.sub(rho.sub(lo).mul(u));
        c = rho.add(hi.sub(rho).mul(v));
    }

    // Rule (3) of the paper. In excess supply both prices sit at the feed-in rate.
    // In excess demand, with D = (hi - lo) y + lo, r = hi*lo/D and c = y r + (1-y) hi.
    function _supplyDemandRatio(UD60x18 s, UD60x18 d, UD60x18 lo, UD60x18 hi)
        private
        pure
        returns (UD60x18 r, UD60x18 c)
    {
        if (s.gte(d)) return (lo, lo);
        UD60x18 y = s.div(d);
        UD60x18 D = hi.sub(lo).mul(y).add(lo);
        r = hi.mul(lo).div(D);
        c = y.mul(r).add(ONE.sub(y).mul(hi));
    }

    // Rule (2) of the paper, written with a = sqrt(lo), b = sqrt(hi), chi = ab/(b-a).
    // In excess demand r is the geometric mean ab and c = y ab + (1-y) hi.
    // In excess supply, with u = 1 - 1/y and z = chi / (u + chi/b):
    //   c = a z   and   r = chi (z - a) + u lo.
    // When lo = 0 the rule degenerates to r = 0, c = (1-y)^+ hi, which is its limit.
    function _hyperbolic(UD60x18 s, UD60x18 d, UD60x18 lo, UD60x18 hi)
        private
        pure
        returns (UD60x18 r, UD60x18 c)
    {
        if (lo.unwrap() == 0) {
            return s.gte(d) ? (ud(0), ud(0)) : (ud(0), ONE.sub(s.div(d)).mul(hi));
        }
        UD60x18 a = lo.sqrt();
        UD60x18 b = hi.sqrt();
        UD60x18 ab = a.mul(b);
        if (s.lte(d)) {
            UD60x18 y = s.div(d);
            return (ab, y.mul(ab).add(ONE.sub(y).mul(hi)));
        }
        UD60x18 u = ONE.sub(d.div(s));            // share of supply sold to the grid
        UD60x18 k = a.div(b.sub(a));              // chi / b
        UD60x18 chi = ab.div(b.sub(a));
        UD60x18 z = chi.div(u.add(k));            // falls from b at balance to a
        c = a.mul(z);
        r = chi.mul(z.sub(a)).add(u.mul(lo));
    }

    function _oneMinusOrZero(UD60x18 x) private pure returns (UD60x18) {
        return x.lt(ONE) ? ONE.sub(x) : ud(0);
    }
}

// Deployed once per community. The rule is fixed at deployment and cannot change,
// so that nobody can alter how the gain is split once the community is running.
contract Pricing is IPricing {
    PricingLib.Rule public immutable rule;

    constructor(PricingLib.Rule _rule) {
        rule = _rule;
    }

    function prices(UD60x18 s, UD60x18 d, UD60x18 lambdaLow, UD60x18 lambdaHigh)
        external
        view
        returns (UD60x18 r, UD60x18 c)
    {
        return PricingLib.prices(rule, s, d, lambdaLow, lambdaHigh);
    }
}
