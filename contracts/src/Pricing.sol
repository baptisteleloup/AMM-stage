// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

// The three pricing rules of Fabi et al. (mid-market rate, supply-demand ratio, hyperbolic) as
// pure functions of the session aggregates (s, d) and the band (lo, hi), in 18-decimal cents per kWh.
// Every rule gives lo <= r <= c <= hi and balances the budget d*c - s*r = hi*(d-s)^+ - lo*(s-d)^+.
// MarketV4 calls Pricing.prices at each session opening and rounds r down and c up.

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {IPricing} from "./interfaces/IPricing.sol";

library PricingLib {
    enum Rule {
        MidMarket, // internal price at the midpoint of the band
        SupplyDemandRatio, // seller price falls with s/d, buyer price from budget balance
        Hyperbolic // constant-product trading function fitted to the band
    }

    UD60x18 private constant ONE = UD60x18.wrap(1e18);

    // Dispatches to the rule. Shared edge cases first.
    function prices(Rule rule, UD60x18 s, UD60x18 d, UD60x18 lambdaLow, UD60x18 lambdaHigh)
        internal
        pure
        returns (UD60x18 r, UD60x18 c)
    {
        require(lambdaLow.lte(lambdaHigh), "band");
        // one side empty: it trades with the grid
        if (s.unwrap() == 0 || d.unwrap() == 0) return (lambdaLow, lambdaHigh);
        if (lambdaLow.unwrap() == lambdaHigh.unwrap()) return (lambdaLow, lambdaHigh); // flat band, nothing to share

        if (rule == Rule.MidMarket) return _midMarket(s, d, lambdaLow, lambdaHigh);
        if (rule == Rule.SupplyDemandRatio) return _supplyDemandRatio(s, d, lambdaLow, lambdaHigh);
        return _hyperbolic(s, d, lambdaLow, lambdaHigh);
    }

    // Mid-market rate, rule (1) of the paper.
    function _midMarket(UD60x18 s, UD60x18 d, UD60x18 lo, UD60x18 hi)
        private
        pure
        returns (UD60x18 r, UD60x18 c)
    {
        UD60x18 rho = lo.add(hi).div(ud(2e18)); // midpoint of the band
        UD60x18 u = _oneMinusOrZero(d.div(s)); // share of supply sold to the grid
        UD60x18 v = _oneMinusOrZero(s.div(d)); // share of demand bought from the grid
        r = rho.sub(rho.sub(lo).mul(u)); // pulled down towards lo by the surplus
        c = rho.add(hi.sub(rho).mul(v)); // pulled up towards hi by the shortfall
    }

    // Supply-demand ratio, rule (3) of the paper.
    function _supplyDemandRatio(UD60x18 s, UD60x18 d, UD60x18 lo, UD60x18 hi)
        private
        pure
        returns (UD60x18 r, UD60x18 c)
    {
        if (s.gte(d)) return (lo, lo); // excess supply: both at the feed-in rate
        UD60x18 y = s.div(d); // supply-demand ratio, below 1 here
        UD60x18 D = hi.sub(lo).mul(y).add(lo);
        r = hi.mul(lo).div(D); // r = hi*lo / ((hi - lo) y + lo)
        c = y.mul(r).add(ONE.sub(y).mul(hi)); // c = y r + (1 - y) hi, budget balance
    }

    // Hyperbolic rule, rule (2) of the paper, with a = sqrt(lo), b = sqrt(hi), chi = ab / (b - a).
    function _hyperbolic(UD60x18 s, UD60x18 d, UD60x18 lo, UD60x18 hi)
        private
        pure
        returns (UD60x18 r, UD60x18 c)
    {
        if (lo.unwrap() == 0) {
            // limit lo -> 0: r = 0, c = (1 - y)^+ hi
            return s.gte(d) ? (ud(0), ud(0)) : (ud(0), ONE.sub(s.div(d)).mul(hi));
        }
        UD60x18 a = lo.sqrt();
        UD60x18 b = hi.sqrt();
        UD60x18 ab = a.mul(b);
        if (s.lte(d)) {
            UD60x18 y = s.div(d);
            return (ab, y.mul(ab).add(ONE.sub(y).mul(hi))); // excess demand: r = ab, c = y ab + (1 - y) hi
        }
        UD60x18 u = ONE.sub(d.div(s)); // share of supply sold to the grid
        UD60x18 k = a.div(b.sub(a)); // chi / b
        UD60x18 chi = ab.div(b.sub(a));
        UD60x18 z = chi.div(u.add(k)); // falls from b at balance to a
        c = a.mul(z);
        r = chi.mul(z.sub(a)).add(u.mul(lo));
    }

    // (1 - x)^+
    function _oneMinusOrZero(UD60x18 x) private pure returns (UD60x18) {
        return x.lt(ONE) ? ONE.sub(x) : ud(0);
    }
}

// One per community. The rule is immutable, so the split of the gain cannot change once running.
contract Pricing is IPricing {
    PricingLib.Rule public immutable rule; // 0 MMR, 1 SDR, 2 hyperbolic

    constructor(PricingLib.Rule _rule) {
        rule = _rule;
    }

    // Called by MarketV4.openSession.
    function prices(UD60x18 s, UD60x18 d, UD60x18 lambdaLow, UD60x18 lambdaHigh)
        external
        view
        returns (UD60x18 r, UD60x18 c)
    {
        return PricingLib.prices(rule, s, d, lambdaLow, lambdaHigh);
    }
}
