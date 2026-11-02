// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

// Tests of Pricing.sol: properties every rule must satisfy (band, no arbitrage, budget balance,
// homogeneity, monotonicity, edge cases), run once per rule, plus reference values per rule.
// Run from contracts/: forge test --match-path test/Pricing.t.sol

import {Test} from "forge-std/Test.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {Pricing, PricingLib} from "../src/Pricing.sol";

// Invariants every rule must satisfy, run under each of the three rules, plus
// reference values per rule computed at 40-digit precision from the paper's formulas.
abstract contract PricingRuleTest is Test {
    UD60x18 constant LAMBDA_LOW = UD60x18.wrap(8.86e18); // feed-in, cents per kWh
    UD60x18 constant LAMBDA_HIGH = UD60x18.wrap(21.46e18); // retail
    uint256 constant TOL = 1e12; // 1e-6 cent per kWh, ten times the market grain, far above fixed-point error

    Pricing pricing;

    function _rule() internal pure virtual returns (PricingLib.Rule);

    function setUp() public {
        pricing = new Pricing(_rule());
    }

    // (r, c) for aggregates (s, d) in the test band.
    function _p(uint256 s, uint256 d) internal view returns (UD60x18 r, UD60x18 c) {
        return pricing.prices(ud(s), ud(d), LAMBDA_LOW, LAMBDA_HIGH);
    }

    // The rule is fixed at deployment.
    function test_ruleIsImmutable() public view {
        assertEq(uint256(pricing.rule()), uint256(_rule()));
    }

    // r <= c: nobody gains by selling and buying back in the same session.
    function testFuzz_noArbitrage(uint256 sRaw, uint256 dRaw) public view {
        (UD60x18 r, UD60x18 c) = _p(bound(sRaw, 1e18, 1_000_000e18), bound(dRaw, 1e18, 1_000_000e18));
        assertLe(r.unwrap(), c.unwrap() + TOL);
    }

    // Both prices stay in the grid band, so trading locally is never worse than trading with the grid.
    function testFuzz_individualRationality(uint256 sRaw, uint256 dRaw) public view {
        (UD60x18 r, UD60x18 c) = _p(bound(sRaw, 1e18, 1_000_000e18), bound(dRaw, 1e18, 1_000_000e18));
        assertGe(r.unwrap() + TOL, LAMBDA_LOW.unwrap());
        assertLe(r.unwrap(), LAMBDA_HIGH.unwrap() + TOL);
        assertGe(c.unwrap() + TOL, LAMBDA_LOW.unwrap());
        assertLe(c.unwrap(), LAMBDA_HIGH.unwrap() + TOL);
    }

    // d c - s r must equal the grid leg hi (d-s)^+ - lo (s-d)^+ for every rule.
    function testFuzz_budgetBalance(uint256 sRaw, uint256 dRaw) public view {
        uint256 s = bound(sRaw, 1e18, 1_000_000e18);
        uint256 d = bound(dRaw, 1e18, 1_000_000e18);
        (UD60x18 r, UD60x18 c) = _p(s, d);
        int256 paidIn = int256(d * c.unwrap() / 1e18); // buyers pay d c
        int256 paidOut = int256(s * r.unwrap() / 1e18); // sellers receive s r
        int256 gridLeg = s > d
            ? -int256(LAMBDA_LOW.unwrap() * (s - d) / 1e18) // surplus sold to the grid at feed-in
            : int256(LAMBDA_HIGH.unwrap() * (d - s) / 1e18); // shortfall bought from the grid at retail
        uint256 tol = TOL * (s + d) / 1e18 + TOL; // price tolerance scaled by the volumes
        assertApproxEqAbs(paidIn - paidOut, gridLeg, tol);
    }

    // Scaling s and d by the same factor leaves prices unchanged: only the ratio matters.
    function testFuzz_homogeneity(uint256 sRaw, uint256 dRaw, uint256 alphaRaw) public view {
        uint256 s = bound(sRaw, 1e18, 1_000e18);
        uint256 d = bound(dRaw, 1e18, 1_000e18);
        uint256 alpha = bound(alphaRaw, 1e18, 1_000e18);
        (UD60x18 r1, UD60x18 c1) = _p(s, d);
        (UD60x18 r2, UD60x18 c2) = _p(s * alpha / 1e18, d * alpha / 1e18);
        assertApproxEqAbs(r1.unwrap(), r2.unwrap(), TOL);
        assertApproxEqAbs(c1.unwrap(), c2.unwrap(), TOL);
    }

    // More supply never raises either price.
    function testFuzz_responsiveness_supply(uint256 sRaw, uint256 dRaw, uint256 bumpRaw) public view {
        uint256 s = bound(sRaw, 1e18, 1_000e18);
        uint256 d = bound(dRaw, 1e18, 1_000e18);
        uint256 bump = bound(bumpRaw, 1e18, 1_000e18);
        (UD60x18 r1, UD60x18 c1) = _p(s, d);
        (UD60x18 r2, UD60x18 c2) = _p(s + bump, d);
        assertLe(c2.unwrap(), c1.unwrap() + TOL);
        assertLe(r2.unwrap(), r1.unwrap() + TOL);
    }

    // More demand never lowers either price.
    function testFuzz_responsiveness_demand(uint256 sRaw, uint256 dRaw, uint256 bumpRaw) public view {
        uint256 s = bound(sRaw, 1e18, 1_000e18);
        uint256 d = bound(dRaw, 1e18, 1_000e18);
        uint256 bump = bound(bumpRaw, 1e18, 1_000e18);
        (UD60x18 r1, UD60x18 c1) = _p(s, d);
        (UD60x18 r2, UD60x18 c2) = _p(s, d + bump);
        assertGe(c2.unwrap() + TOL, c1.unwrap());
        assertGe(r2.unwrap() + TOL, r1.unwrap());
    }

    // No buyers: sellers trade with the grid at the band.
    function test_edge_zeroDemand() public view {
        (UD60x18 r, UD60x18 c) = _p(100e18, 0);
        assertEq(r.unwrap(), LAMBDA_LOW.unwrap());
        assertEq(c.unwrap(), LAMBDA_HIGH.unwrap());
    }

    // No sellers: buyers trade with the grid at the band.
    function test_edge_zeroSupply() public view {
        (UD60x18 r, UD60x18 c) = _p(0, 100e18);
        assertEq(r.unwrap(), LAMBDA_LOW.unwrap());
        assertEq(c.unwrap(), LAMBDA_HIGH.unwrap());
    }

    // Empty session: the band, no division by zero.
    function test_edge_emptyMarket() public view {
        (UD60x18 r, UD60x18 c) = _p(0, 0);
        assertEq(r.unwrap(), LAMBDA_LOW.unwrap());
        assertEq(c.unwrap(), LAMBDA_HIGH.unwrap());
    }

    // A flat band leaves nothing to share: both prices equal the grid price.
    function testFuzz_edge_zeroSpread(uint256 sRaw, uint256 dRaw, uint256 lambdaRaw) public view {
        UD60x18 lambda = ud(bound(lambdaRaw, 1e18, 100e18));
        (UD60x18 r, UD60x18 c) =
            pricing.prices(ud(bound(sRaw, 1e18, 1_000_000e18)), ud(bound(dRaw, 1e18, 1_000_000e18)), lambda, lambda);
        assertEq(r.unwrap(), lambda.unwrap());
        assertEq(c.unwrap(), lambda.unwrap());
    }

    // Supply up to 1e9 times demand still gives prices inside the band.
    function testFuzz_edge_extremeRatio(uint256 sRaw) public view {
        (UD60x18 r, UD60x18 c) = _p(bound(sRaw, 1_000_000e18, 1_000_000_000e18), 1e18);
        assertGe(r.unwrap() + TOL, LAMBDA_LOW.unwrap());
        assertLe(c.unwrap(), LAMBDA_HIGH.unwrap() + TOL);
    }

    // A zero feed-in tariff is valid and must not break the rules' arithmetic.
    function test_zeroFeedIn_doesNotRevert() public view {
        (UD60x18 r, UD60x18 c) = pricing.prices(ud(150e18), ud(100e18), ud(0), LAMBDA_HIGH); // surplus
        assertLe(r.unwrap(), c.unwrap() + TOL);
        (r, c) = pricing.prices(ud(100e18), ud(150e18), ud(0), LAMBDA_HIGH); // shortfall
        assertLe(c.unwrap(), LAMBDA_HIGH.unwrap());
    }

    // lambda_low > lambda_high is rejected.
    function test_invertedBand_reverts() public {
        vm.expectRevert(bytes("band"));
        pricing.prices(ud(100e18), ud(100e18), LAMBDA_HIGH, LAMBDA_LOW);
    }
}

contract PricingMidMarketTest is PricingRuleTest {
    function _rule() internal pure override returns (PricingLib.Rule) { return PricingLib.Rule.MidMarket; }

    // Reference prices at (s, d) = (100, 100), (150, 100) and (100, 150).
    function test_reference() public view {
        (UD60x18 r, UD60x18 c) = _p(100e18, 100e18);
        assertApproxEqAbs(r.unwrap(), 15.16e18, TOL); // midpoint of the band
        assertApproxEqAbs(c.unwrap(), 15.16e18, TOL);
        (r, c) = _p(150e18, 100e18);
        assertApproxEqAbs(r.unwrap(), 13.06e18, TOL);
        assertApproxEqAbs(c.unwrap(), 15.16e18, TOL);
        (r, c) = _p(100e18, 150e18);
        assertApproxEqAbs(r.unwrap(), 15.16e18, TOL);
        assertApproxEqAbs(c.unwrap(), 17.26e18, TOL);
    }
}

contract PricingSupplyDemandRatioTest is PricingRuleTest {
    function _rule() internal pure override returns (PricingLib.Rule) { return PricingLib.Rule.SupplyDemandRatio; }

    // Reference prices at (s, d) = (100, 100), (150, 100) and (100, 150).
    function test_reference() public view {
        (UD60x18 r, UD60x18 c) = _p(100e18, 100e18);
        assertApproxEqAbs(r.unwrap(), 8.86e18, TOL); // s >= d: everything at feed-in
        assertApproxEqAbs(c.unwrap(), 8.86e18, TOL);
        (r, c) = _p(150e18, 100e18);
        assertApproxEqAbs(r.unwrap(), 8.86e18, TOL);
        assertApproxEqAbs(c.unwrap(), 8.86e18, TOL);
        (r, c) = _p(100e18, 150e18);
        assertApproxEqAbs(r.unwrap(), 11.015967555041e18, TOL);
        assertApproxEqAbs(c.unwrap(), 14.497311703360e18, TOL);
    }
}

contract PricingHyperbolicTest is PricingRuleTest {
    function _rule() internal pure override returns (PricingLib.Rule) { return PricingLib.Rule.Hyperbolic; }

    // Reference prices at (s, d) = (100, 100), (150, 100) and (100, 150).
    function test_reference() public view {
        (UD60x18 r, UD60x18 c) = _p(100e18, 100e18);
        assertApproxEqAbs(r.unwrap(), 13.788966603774e18, TOL); // geometric mean of the band
        assertApproxEqAbs(c.unwrap(), 13.788966603774e18, TOL);
        (r, c) = _p(150e18, 100e18);
        assertApproxEqAbs(r.unwrap(), 10.707966841041e18, TOL);
        assertApproxEqAbs(c.unwrap(), 11.631950261562e18, TOL);
        (r, c) = _p(100e18, 150e18);
        assertApproxEqAbs(r.unwrap(), 13.788966603774e18, TOL);
        assertApproxEqAbs(c.unwrap(), 16.345977735849e18, TOL);
    }

    // As supply grows without bound, both prices approach the feed-in rate.
    function test_limit_largeSupply() public view {
        (UD60x18 r, UD60x18 c) = _p(1_000_000e18, 1e18);
        assertApproxEqAbs(r.unwrap(), LAMBDA_LOW.unwrap(), 1e15);
        assertApproxEqAbs(c.unwrap(), LAMBDA_LOW.unwrap(), 1e15);
    }
}
