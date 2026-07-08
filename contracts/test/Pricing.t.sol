// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test } from "forge-std/Test.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { Pricing } from "../src/Pricing.sol";

contract PricingTest is Test {
    UD60x18 constant LAMBDA_LOW  = UD60x18.wrap(8.86e18);   
    UD60x18 constant LAMBDA_HIGH = UD60x18.wrap(21.46e18);  

    uint256 constant TOL = 1e12;

    function test_balanced() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(100e18), ud(100e18), LAMBDA_LOW, LAMBDA_HIGH);
        assertApproxEqAbs(r.unwrap(), 15.16e18, TOL);
        assertApproxEqAbs(c.unwrap(), 15.16e18, TOL);
    }

    function test_surplus() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(150e18), ud(100e18), LAMBDA_LOW, LAMBDA_HIGH);
        assertApproxEqAbs(r.unwrap(), 13.06e18, TOL);
        assertApproxEqAbs(c.unwrap(), 15.16e18, TOL);
    }

    function test_deficit() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(100e18), ud(150e18), LAMBDA_LOW, LAMBDA_HIGH);
        assertApproxEqAbs(r.unwrap(), 15.16e18, TOL);
        assertApproxEqAbs(c.unwrap(), 17.26e18, TOL);
    }

    function testFuzz_noArbitrage(uint256 sRaw, uint256 dRaw) public {
        UD60x18 s = ud(bound(sRaw, 1e18, 1_000_000e18)); 
        UD60x18 d = ud(bound(dRaw, 1e18, 1_000_000e18));

        (UD60x18 r, UD60x18 c) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);

        assertLe(r.unwrap(), c.unwrap());
    }

    function testFuzz_individualRationality(uint256 sRaw, uint256 dRaw) public {
        UD60x18 s = ud(bound(sRaw, 1e18, 1_000_000e18));
        UD60x18 d = ud(bound(dRaw, 1e18, 1_000_000e18));

        (UD60x18 r, UD60x18 c) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);

        assertGe(r.unwrap(), LAMBDA_LOW.unwrap());   // r >= λ_low
        assertLe(r.unwrap(), LAMBDA_HIGH.unwrap());  // r <= λ_high
        assertGe(c.unwrap(), LAMBDA_LOW.unwrap());   // c >= λ_low
        assertLe(c.unwrap(), LAMBDA_HIGH.unwrap());  // c <= λ_high
    }

    function testFuzz_homogeneity(uint256 sRaw, uint256 dRaw, uint256 alphaRaw) public {
        UD60x18 s = ud(bound(sRaw, 1e18, 1_000e18));
        UD60x18 d = ud(bound(dRaw, 1e18, 1_000e18));
        UD60x18 alpha = ud(bound(alphaRaw, 1e18, 1_000e18)); 

        (UD60x18 r1, UD60x18 c1) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);

        (UD60x18 r2, UD60x18 c2) =
            Pricing.prices(s.mul(alpha), d.mul(alpha), LAMBDA_LOW, LAMBDA_HIGH);

        assertApproxEqAbs(r1.unwrap(), r2.unwrap(), TOL);
        assertApproxEqAbs(c1.unwrap(), c2.unwrap(), TOL);
}

    function testFuzz_responsiveness_supply(uint256 sRaw, uint256 dRaw, uint256 bumpRaw) public {
        UD60x18 s    = ud(bound(sRaw,    1e18, 1_000e18));
        UD60x18 d    = ud(bound(dRaw,    1e18, 1_000e18));
        UD60x18 bump = ud(bound(bumpRaw, 1e18, 1_000e18));

        (UD60x18 r1, UD60x18 c1) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);
        (UD60x18 r2, UD60x18 c2) = Pricing.prices(s.add(bump), d, LAMBDA_LOW, LAMBDA_HIGH);

        assertLe(c2.unwrap(), c1.unwrap()); // ∂c/∂s ≤ 0
        assertLe(r2.unwrap(), r1.unwrap()); // ∂r/∂s ≤ 0
    }

    function testFuzz_responsiveness_demand(uint256 sRaw, uint256 dRaw, uint256 bumpRaw) public {
        UD60x18 s    = ud(bound(sRaw,    1e18, 1_000e18));
        UD60x18 d    = ud(bound(dRaw,    1e18, 1_000e18));
        UD60x18 bump = ud(bound(bumpRaw, 1e18, 1_000e18));

        (UD60x18 r1, UD60x18 c1) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);
        (UD60x18 r2, UD60x18 c2) = Pricing.prices(s, d.add(bump), LAMBDA_LOW, LAMBDA_HIGH);

        assertGe(c2.unwrap(), c1.unwrap()); // ∂c/∂d ≥ 0
        assertGe(r2.unwrap(), r1.unwrap()); // ∂r/∂d ≥ 0
    }

    function test_explore_zeroDemand() public {
    (UD60x18 r, UD60x18 c) =
        Pricing.prices(ud(100e18), ud(0), LAMBDA_LOW, LAMBDA_HIGH);

    emit log_named_uint("r", r.unwrap());
    emit log_named_uint("c", c.unwrap());
    }

    function test_edge_zeroDemand() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(100e18), ud(0), LAMBDA_LOW, LAMBDA_HIGH);

        assertEq(r.unwrap(), LAMBDA_LOW.unwrap());   // r == λ_low == 8.86 (feed-in)
        assertEq(c.unwrap(), LAMBDA_HIGH.unwrap());  // c == λ_high == 21.46 
    }

    function test_edge_zeroSupply() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(0), ud(100e18), LAMBDA_LOW, LAMBDA_HIGH);

        assertEq(c.unwrap(), LAMBDA_HIGH.unwrap());  // c == λ_high == 21.46 (retail)
        assertEq(r.unwrap(), LAMBDA_LOW.unwrap());   // r == λ_low == 8.86
    }

    function test_explore_emptyMarket() public {
    (UD60x18 r, UD60x18 c) =
        Pricing.prices(ud(0), ud(0), LAMBDA_LOW, LAMBDA_HIGH);

    emit log_named_uint("r", r.unwrap());
    emit log_named_uint("c", c.unwrap());
    }

    function test_edge_emptyMarket() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(0), ud(0), LAMBDA_LOW, LAMBDA_HIGH);

        assertEq(r.unwrap(), LAMBDA_LOW.unwrap());   // r == λ_low == 8.86
        assertEq(c.unwrap(), LAMBDA_HIGH.unwrap());  // c == λ_high == 21.46 
    }

    function testFuzz_edge_zeroSpread(uint256 sRaw, uint256 dRaw, uint256 lambdaRaw) public {
        UD60x18 s      = ud(bound(sRaw, 1e18, 1_000_000e18));
        UD60x18 d      = ud(bound(dRaw, 1e18, 1_000_000e18));
        UD60x18 lambda = ud(bound(lambdaRaw, 1e18, 100e18));

        
        (UD60x18 r, UD60x18 c) = Pricing.prices(s, d, lambda, lambda);

        assertEq(r.unwrap(), lambda.unwrap());
        assertEq(c.unwrap(), lambda.unwrap());
    }

    function testFuzz_edge_extremeRatio(uint256 sRaw) public {
        UD60x18 s = ud(bound(sRaw, 1_000_000e18, 1_000_000_000e18));
        UD60x18 d = ud(1e18);                                        

        (UD60x18 r, UD60x18 c) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);

        assertGe(r.unwrap(), LAMBDA_LOW.unwrap());   // r >= λ_low
        assertLe(r.unwrap(), LAMBDA_HIGH.unwrap());  // r <= λ_high
        assertGe(c.unwrap(), LAMBDA_LOW.unwrap());   // c >= λ_low
        assertLe(c.unwrap(), LAMBDA_HIGH.unwrap());  // c <= λ_high

        assertEq(c.unwrap(), 15.16e18);
    }


    function test_totals_balanced() public {
        (UD60x18 cT, UD60x18 rT) = Pricing.totals(ud(100e18), ud(100e18), LAMBDA_LOW, LAMBDA_HIGH);
        // ρ = 15.16, ΔE = 100 => M = 1516
        assertApproxEqAbs(cT.unwrap(), 1516e18, TOL);
        assertApproxEqAbs(rT.unwrap(), 1516e18, TOL);
        assertEq(cT.unwrap(), rT.unwrap()); // parfaitement équilibré
    }

    function test_totals_surplus() public {
        (UD60x18 cT, UD60x18 rT) = Pricing.totals(ud(150e18), ud(100e18), LAMBDA_LOW, LAMBDA_HIGH);
        assertApproxEqAbs(cT.unwrap(), 1516e18, TOL);          
        assertApproxEqAbs(rT.unwrap(), 1516e18 + 443e18, TOL); 
    }

    function test_totals_deficit() public {
        (UD60x18 cT, UD60x18 rT) = Pricing.totals(ud(100e18), ud(150e18), LAMBDA_LOW, LAMBDA_HIGH);
        assertApproxEqAbs(rT.unwrap(), 1516e18, TOL);           
        assertApproxEqAbs(cT.unwrap(), 1516e18 + 1073e18, TOL); 
    }


    function testFuzz_budgetBalance(uint256 sRaw, uint256 dRaw) public {
        UD60x18 s = ud(bound(sRaw, 1e18, 1_000_000e18));
        UD60x18 d = ud(bound(dRaw, 1e18, 1_000_000e18));

        (UD60x18 cT, UD60x18 rT) = Pricing.totals(s, d, LAMBDA_LOW, LAMBDA_HIGH);

        if (s.unwrap() > d.unwrap()) {
            uint256 gridLeg = LAMBDA_LOW.unwrap() * (s.unwrap() - d.unwrap()) / 1e18;
            assertApproxEqAbs(rT.unwrap() - cT.unwrap(), gridLeg, TOL);
        } else if (d.unwrap() > s.unwrap()) {
            uint256 gridLeg = LAMBDA_HIGH.unwrap() * (d.unwrap() - s.unwrap()) / 1e18;
            assertApproxEqAbs(cT.unwrap() - rT.unwrap(), gridLeg, TOL);
        } else {
            assertEq(cT.unwrap(), rT.unwrap());
        }
    }

}



