// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test } from "forge-std/Test.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { Pricing } from "../src/Pricing.sol";

contract PricingTest is Test {
    // Prix grid du papier (c€/kWh), en UD60x18
    UD60x18 constant LAMBDA_LOW  = UD60x18.wrap(8.86e18);   // feed-in λ
    UD60x18 constant LAMBDA_HIGH = UD60x18.wrap(21.46e18);  // retail λ̄

    // Tolérance : 1e-6 
    uint256 constant TOL = 1e12; // 1e-6 * 1e18

    /// Cas I — équilibré (s = d) : r = c = ρ = 15.16
    function test_balanced() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(100e18), ud(100e18), LAMBDA_LOW, LAMBDA_HIGH);
        assertApproxEqAbs(r.unwrap(), 15.16e18, TOL);
        assertApproxEqAbs(c.unwrap(), 15.16e18, TOL);
    }

    /// Cas II — surplus (s > d) : r = 13.06, c = 15.16
    function test_surplus() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(150e18), ud(100e18), LAMBDA_LOW, LAMBDA_HIGH);
        assertApproxEqAbs(r.unwrap(), 13.06e18, TOL);
        assertApproxEqAbs(c.unwrap(), 15.16e18, TOL);
    }

    /// Cas III — déficit (d > s) : r = 15.16, c = 17.26
    function test_deficit() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(100e18), ud(150e18), LAMBDA_LOW, LAMBDA_HIGH);
        assertApproxEqAbs(r.unwrap(), 15.16e18, TOL);
        assertApproxEqAbs(c.unwrap(), 17.26e18, TOL);
    }
}