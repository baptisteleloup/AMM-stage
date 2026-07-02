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

    /// Axiome 3 — No-Arbitrage : r <= c pour tout (s, d)
    function testFuzz_noArbitrage(uint256 sRaw, uint256 dRaw) public {
        UD60x18 s = ud(bound(sRaw, 1e18, 1_000_000e18)); // de 1 à 1e6 kWh
        UD60x18 d = ud(bound(dRaw, 1e18, 1_000_000e18));

        (UD60x18 r, UD60x18 c) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);

        assertLe(r.unwrap(), c.unwrap());
    }

    /// Axiome 5 — Individual Rationality : λ_low <= r, c <= λ_high pour tout (s, d)
    /// (couvre aussi l'Axiome 6 Monotonicité, car λ_low = 8.86 > 0)
    function testFuzz_individualRationality(uint256 sRaw, uint256 dRaw) public {
        UD60x18 s = ud(bound(sRaw, 1e18, 1_000_000e18));
        UD60x18 d = ud(bound(dRaw, 1e18, 1_000_000e18));

        (UD60x18 r, UD60x18 c) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);

        // r et c restent dans l'intervalle grid [λ_low, λ_high]
        assertGe(r.unwrap(), LAMBDA_LOW.unwrap());   // r >= λ_low
        assertLe(r.unwrap(), LAMBDA_HIGH.unwrap());  // r <= λ_high
        assertGe(c.unwrap(), LAMBDA_LOW.unwrap());   // c >= λ_low
        assertLe(c.unwrap(), LAMBDA_HIGH.unwrap());  // c <= λ_high
    }

    /// Axiome 8 — Homogénéité : prices(αs, αd) == prices(s, d) pour tout α > 0
    function testFuzz_homogeneity(uint256 sRaw, uint256 dRaw, uint256 alphaRaw) public {
        UD60x18 s = ud(bound(sRaw, 1e18, 1_000e18));
        UD60x18 d = ud(bound(dRaw, 1e18, 1_000e18));
        UD60x18 alpha = ud(bound(alphaRaw, 1e18, 1_000e18)); // α de 1 à 1000

        // Appel 1 : échelle de base
        (UD60x18 r1, UD60x18 c1) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);

        // Appel 2 : tout mis à l'échelle par α
        (UD60x18 r2, UD60x18 c2) =
            Pricing.prices(s.mul(alpha), d.mul(alpha), LAMBDA_LOW, LAMBDA_HIGH);

        // Les deux doivent coïncider (à la tolérance d'arrondi près)
        assertApproxEqAbs(r1.unwrap(), r2.unwrap(), TOL);
        assertApproxEqAbs(c1.unwrap(), c2.unwrap(), TOL);
}

    /// Axiome 7 — Responsiveness à l'offre : plus d'offre => ni c ni r n'augmentent.
    /// Couvre ∂c/∂s ≤ 0 et ∂r/∂s ≤ 0.
    function testFuzz_responsiveness_supply(uint256 sRaw, uint256 dRaw, uint256 bumpRaw) public {
        UD60x18 s    = ud(bound(sRaw,    1e18, 1_000e18));
        UD60x18 d    = ud(bound(dRaw,    1e18, 1_000e18));
        UD60x18 bump = ud(bound(bumpRaw, 1e18, 1_000e18));

        (UD60x18 r1, UD60x18 c1) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);
        (UD60x18 r2, UD60x18 c2) = Pricing.prices(s.add(bump), d, LAMBDA_LOW, LAMBDA_HIGH);

        assertLe(c2.unwrap(), c1.unwrap()); // ∂c/∂s ≤ 0
        assertLe(r2.unwrap(), r1.unwrap()); // ∂r/∂s ≤ 0
    }

    /// Axiome 7 — Responsiveness à la demande : plus de demande => ni c ni r ne baissent.
    /// Couvre ∂c/∂d ≥ 0 et ∂r/∂d ≥ 0.
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

    /// Cas limite — demande nulle (d = 0, surplus pur).
    /// Décision de design : pas de revert. Les vendeurs écoulent tout
    /// au grid, donc r = λ_low. c = λ_high
    function test_edge_zeroDemand() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(100e18), ud(0), LAMBDA_LOW, LAMBDA_HIGH);

        assertEq(r.unwrap(), LAMBDA_LOW.unwrap());   // r == λ_low == 8.86 (feed-in)
        assertEq(c.unwrap(), LAMBDA_HIGH.unwrap());  // c == λ_high == 21.46 (fantôme, non facturé)
    }

    /// Cas limite — offre nulle (s = 0, déficit pur).
    /// Miroir de test_edge_zeroDemand. Décision de design : pas de revert.
    /// Les acheteurs importent tout au grid, donc c = λ_high. r = λ_low
    function test_edge_zeroSupply() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(0), ud(100e18), LAMBDA_LOW, LAMBDA_HIGH);

        assertEq(c.unwrap(), LAMBDA_HIGH.unwrap());  // c == λ_high == 21.46 (retail)
        assertEq(r.unwrap(), LAMBDA_LOW.unwrap());   // r == λ_low == 8.86 (fantôme, non payé)
    }

    function test_explore_emptyMarket() public {
    (UD60x18 r, UD60x18 c) =
        Pricing.prices(ud(0), ud(0), LAMBDA_LOW, LAMBDA_HIGH);

    emit log_named_uint("r", r.unwrap());
    emit log_named_uint("c", c.unwrap());
    }

    /// Cas limite — marché vide (s = 0 ET d = 0).
    /// Comportement ACTUEL figé (Option A) : pas de revert, renvoie les bornes grid.
    /// Les DEUX prix sont fantômes (ni vendeur ni acheteur pour les honorer).
    /// TODO: valider avec Michele — faut-il plutôt revert sur un marché vide ?
    function test_edge_emptyMarket() public {
        (UD60x18 r, UD60x18 c) =
            Pricing.prices(ud(0), ud(0), LAMBDA_LOW, LAMBDA_HIGH);

        assertEq(r.unwrap(), LAMBDA_LOW.unwrap());   // r == λ_low == 8.86
        assertEq(c.unwrap(), LAMBDA_HIGH.unwrap());  // c == λ_high == 21.46 
    }

    /// Cas limite — spread grid nul (λ_low == λ_high).
    /// quel que soit (s,d), r = c = λ.
    function testFuzz_edge_zeroSpread(uint256 sRaw, uint256 dRaw, uint256 lambdaRaw) public {
        UD60x18 s      = ud(bound(sRaw, 1e18, 1_000_000e18));
        UD60x18 d      = ud(bound(dRaw, 1e18, 1_000_000e18));
        UD60x18 lambda = ud(bound(lambdaRaw, 1e18, 100e18)); // un prix grid quelconque

        // les deux bornes égales
        (UD60x18 r, UD60x18 c) = Pricing.prices(s, d, lambda, lambda);

        // r = c = λ, exactement 
        assertEq(r.unwrap(), lambda.unwrap());
        assertEq(c.unwrap(), lambda.unwrap());
    }

    /// Cas limite — ratio extrême (s >>> d). Test de robustesse arithmétique.
    /// Vérifie : pas d'overflow/revert, et les prix restent bornés dans [λ_low, λ_high]
    function testFuzz_edge_extremeRatio(uint256 sRaw) public {
        UD60x18 s = ud(bound(sRaw, 1_000_000e18, 1_000_000_000e18)); // offre énorme : 1e6 à 1e9 kWh
        UD60x18 d = ud(1e18);                                        // demande minuscule : 1 kWh

        (UD60x18 r, UD60x18 c) = Pricing.prices(s, d, LAMBDA_LOW, LAMBDA_HIGH);

        // robustesse : les prix restent dans l'intervalle grid, pas d'explosion
        assertGe(r.unwrap(), LAMBDA_LOW.unwrap());   // r >= λ_low
        assertLe(r.unwrap(), LAMBDA_HIGH.unwrap());  // r <= λ_high
        assertGe(c.unwrap(), LAMBDA_LOW.unwrap());   // c >= λ_low
        assertLe(c.unwrap(), LAMBDA_HIGH.unwrap());  // c <= λ_high

        // comportement attendu à ratio extrême : c reste à ρ = 15.16
        assertEq(c.unwrap(), 15.16e18);
    }


    /// Totaux — cas équilibré : Ctotal = Rtotal = ρ·s (pas de jambe grid).
    function test_totals_balanced() public {
        (UD60x18 cT, UD60x18 rT) = Pricing.totals(ud(100e18), ud(100e18), LAMBDA_LOW, LAMBDA_HIGH);
        // ρ = 15.16, ΔE = 100 => M = 1516
        assertApproxEqAbs(cT.unwrap(), 1516e18, TOL);
        assertApproxEqAbs(rT.unwrap(), 1516e18, TOL);
        assertEq(cT.unwrap(), rT.unwrap()); // parfaitement équilibré
    }

    /// Totaux — surplus : Rtotal > Ctotal, l'écart = λ_low·(s−d).
    function test_totals_surplus() public {
        (UD60x18 cT, UD60x18 rT) = Pricing.totals(ud(150e18), ud(100e18), LAMBDA_LOW, LAMBDA_HIGH);
        // ΔE = 100, M = 15.16·100 = 1516 ; jambe grid = 8.86·50 = 443
        assertApproxEqAbs(cT.unwrap(), 1516e18, TOL);          // acheteurs paient M
        assertApproxEqAbs(rT.unwrap(), 1516e18 + 443e18, TOL); // vendeurs : M + revente surplus
    }

    /// Totaux — déficit : Ctotal > Rtotal, l'écart = λ_high·(d−s).
    function test_totals_deficit() public {
        (UD60x18 cT, UD60x18 rT) = Pricing.totals(ud(100e18), ud(150e18), LAMBDA_LOW, LAMBDA_HIGH);
        // ΔE = 100, M = 1516 ; jambe grid = 21.46·50 = 1073
        assertApproxEqAbs(rT.unwrap(), 1516e18, TOL);           // vendeurs touchent M
        assertApproxEqAbs(cT.unwrap(), 1516e18 + 1073e18, TOL); // acheteurs : M + import déficit
    }

    /// INVARIANT budget-balance complet : Rtotal − Ctotal = jambe grid, pour tout (s,d).
    function testFuzz_budgetBalance(uint256 sRaw, uint256 dRaw) public {
        UD60x18 s = ud(bound(sRaw, 1e18, 1_000_000e18));
        UD60x18 d = ud(bound(dRaw, 1e18, 1_000_000e18));

        (UD60x18 cT, UD60x18 rT) = Pricing.totals(s, d, LAMBDA_LOW, LAMBDA_HIGH);

        // jambe grid attendue : +λ_low·(s−d) si surplus, −λ_high·(d−s) si déficit
        if (s.unwrap() > d.unwrap()) {
            uint256 gridLeg = LAMBDA_LOW.unwrap() * (s.unwrap() - d.unwrap()) / 1e18;
            assertApproxEqAbs(rT.unwrap() - cT.unwrap(), gridLeg, TOL);
        } else if (d.unwrap() > s.unwrap()) {
            uint256 gridLeg = LAMBDA_HIGH.unwrap() * (d.unwrap() - s.unwrap()) / 1e18;
            assertApproxEqAbs(cT.unwrap() - rT.unwrap(), gridLeg, TOL);
        } else {
            assertEq(cT.unwrap(), rT.unwrap()); // équilibre : pas d'écart
        }
    }

}



