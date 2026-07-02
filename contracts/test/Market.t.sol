// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test } from "forge-std/Test.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { Market } from "../src/Market.sol";
import { EnergyEuro } from "../src/EnergyEuro.sol";
import { TokenBackend } from "../src/TokenBackend.sol";

contract MarketTest is Test {
    Market market;
    EnergyEuro token;
    TokenBackend backend;

    UD60x18 constant LAMBDA_LOW  = UD60x18.wrap(8.86e18);
    UD60x18 constant LAMBDA_HIGH = UD60x18.wrap(21.46e18);
    uint256 constant TOL = 1e12; // 1e-6 en UD60x18

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address carol = address(0xCA201);
    address grid  = address(0x6819D);

    function setUp() public {
        // 1-3 : déploiement dans l'ordre des dépendances
        token   = new EnergyEuro();
        backend = new TokenBackend(token);
        market  = new Market(LAMBDA_LOW, LAMBDA_HIGH, backend, grid);

        // 4 : financer (le grid + les prosumers qui pourraient être acheteurs)
        token.mint(grid,  1_000_000e18);
        token.mint(alice, 1_000_000e18);
        token.mint(bob,   1_000_000e18);
        token.mint(carol, 1_000_000e18);

        // 5 : approvals : c'est TokenBackend qui a la fonction de paiement et qui prélève donc on doit lui donner l'autorisation
        vm.prank(grid);  token.approve(address(backend), type(uint256).max);
        vm.prank(alice); token.approve(address(backend), type(uint256).max);
        vm.prank(bob);   token.approve(address(backend), type(uint256).max);
        vm.prank(carol); token.approve(address(backend), type(uint256).max);
    }

    // ---------- ÉTAPE 1 : collecte (5 units) ----------

    /// 1. Soumission simple : netput stocké, prosumer ajouté.
    function test_submitOrder_storesNetput() public {
        vm.prank(alice);
        market.submitOrder(150e18);

        (int256 netput, bool exists) = market.orderOf(alice);
        assertEq(netput, 150e18);
        assertTrue(exists);
        assertEq(market.prosumerCount(), 1);
    }

    /// 2. Resoumission : écrase sans doublon.
    function test_resubmit_overwritesWithoutDuplicate() public {
        vm.prank(alice);
        market.submitOrder(150e18);
        vm.prank(alice);
        market.submitOrder(-80e18);

        (int256 netput,) = market.orderOf(alice);
        assertEq(netput, -80e18);
        assertEq(market.prosumerCount(), 1);
    }

    /// 3. Plusieurs prosumers distincts s'accumulent.
    function test_multipleProsumers_accumulate() public {
        vm.prank(alice);
        market.submitOrder(150e18);
        vm.prank(bob);
        market.submitOrder(-100e18);

        assertEq(market.prosumerCount(), 2);
        assertEq(market.prosumers(0), alice);
        assertEq(market.prosumers(1), bob);
    }

    /// 4. Décomposition signé -> (offre, demande), 3 cas.
    function test_decompose_allCases() public view {
        (uint256 s1, uint256 d1) = market.decompose(150e18);
        assertEq(s1, 150e18); assertEq(d1, 0);

        (uint256 s2, uint256 d2) = market.decompose(-80e18);
        assertEq(s2, 0); assertEq(d2, 80e18);

        (uint256 s3, uint256 d3) = market.decompose(0);
        assertEq(s3, 0); assertEq(d3, 0);
    }

    /// 5. netput = 0 est une soumission valide (présent, pas absent).
    function test_zeroNetput_isValidSubmission() public {
        vm.prank(alice);
        market.submitOrder(0);

        (, bool exists) = market.orderOf(alice);
        assertTrue(exists);
        assertEq(market.prosumerCount(), 1);
    }

    /// Fuzz étape 1 : resoumissions par la même adresse => jamais de doublon.
    function testFuzz_noDuplicateOnResubmit(int256 n1, int256 n2, int256 n3) public {
        vm.prank(alice); market.submitOrder(n1);
        vm.prank(alice); market.submitOrder(n2);
        vm.prank(alice); market.submitOrder(n3);

        assertEq(market.prosumerCount(), 1);
        (int256 netput,) = market.orderOf(alice);
        assertEq(netput, n3);
    }

    // ---------- ÉTAPE 2 : agrégation ----------

    /// Un seul vendeur : s = netput, d = 0.
    function test_aggregate_singleSeller() public {
        vm.prank(alice); market.submitOrder(150e18);
        (UD60x18 s, UD60x18 d) = market.aggregate();
        assertEq(s.unwrap(), 150e18);
        assertEq(d.unwrap(), 0);
    }

    /// Un seul acheteur : s = 0, d = |netput|.
    function test_aggregate_singleBuyer() public {
        vm.prank(bob); market.submitOrder(-100e18);
        (UD60x18 s, UD60x18 d) = market.aggregate();
        assertEq(s.unwrap(), 0);
        assertEq(d.unwrap(), 100e18);
    }

    /// Mixte : les offres et demandes s'agrègent séparément.
    function test_aggregate_mixed() public {
        vm.prank(alice); market.submitOrder(150e18);
        vm.prank(bob);   market.submitOrder(-100e18);
        (UD60x18 s, UD60x18 d) = market.aggregate();
        assertEq(s.unwrap(), 150e18);
        assertEq(d.unwrap(), 100e18);
    }

    /// Resoumission reflétée dans l'agrégat (Alice passe vendeuse -> acheteuse).
    function test_aggregate_reflectsResubmission() public {
        vm.prank(alice); market.submitOrder(150e18);
        vm.prank(alice); market.submitOrder(-80e18);
        (UD60x18 s, UD60x18 d) = market.aggregate();
        assertEq(s.unwrap(), 0);        // plus aucune offre
        assertEq(d.unwrap(), 80e18);    // valeur mise à jour, pas 150
    }

    /// Câblage complet : submit -> aggregate -> pricer reproduit le golden surplus.
    /// s=150, d=100 => r≈13.06, c≈15.16.
    function test_clearingPrices_reproducesGoldenSurplus() public {
        vm.prank(alice); market.submitOrder(150e18);
        vm.prank(bob);   market.submitOrder(-100e18);

        (UD60x18 r, UD60x18 c) = market.clearingPrices();
        assertApproxEqAbs(r.unwrap(), 13.06e18, TOL);
        assertApproxEqAbs(c.unwrap(), 15.16e18, TOL);
    }

    /// Fuzz agrégation : sur des netputs quelconques, aggregate somme correctement.
    function testFuzz_aggregate_sumsCorrectly(int256 n1, int256 n2, int256 n3) public {
        n1 = bound(n1, int256(-1e24), int256(1e24));
        n2 = bound(n2, int256(-1e24), int256(1e24));
        n3 = bound(n3, int256(-1e24), int256(1e24));

        vm.prank(alice); market.submitOrder(n1);
        vm.prank(bob);   market.submitOrder(n2);
        vm.prank(carol); market.submitOrder(n3);

        // somme attendue, calculée indépendamment dans le test
        uint256 expS;
        uint256 expD;
        int256[3] memory ns = [n1, n2, n3];
        for (uint256 i = 0; i < 3; i++) {
            if (ns[i] > 0)      expS += uint256(ns[i]);
            else if (ns[i] < 0) expD += uint256(-ns[i]);
        }

        (UD60x18 s, UD60x18 d) = market.aggregate();
        assertEq(s.unwrap(), expS);
        assertEq(d.unwrap(), expD);
    }

    /// Fuzz intégration IR : quels que soient les λ (avec λ_low <= λ_high) et les
    /// ordres, les prix de clearing restent dans [λ_low, λ_high].
    function testFuzz_clearingPrices_respectsIR(
        uint256 lowRaw, uint256 highRaw, int256 n1, int256 n2
    ) public {
        UD60x18 low  = ud(bound(lowRaw,  1e18, 50e18));
        UD60x18 high = ud(bound(highRaw, low.unwrap(), 100e18)); // garantit low <= high
        n1 = bound(n1, int256(-1e24), int256(1e24));
        n2 = bound(n2, int256(-1e24), int256(1e24));

        Market m = new Market(low, high, backend, grid);
        vm.prank(alice); m.submitOrder(n1);
        vm.prank(bob);   m.submitOrder(n2);

        (UD60x18 r, UD60x18 c) = m.clearingPrices();
        assertGe(r.unwrap(), low.unwrap());
        assertLe(r.unwrap(), high.unwrap());
        assertGe(c.unwrap(), low.unwrap());
        assertLe(c.unwrap(), high.unwrap());
    }


    /// Étape 3 — câblage des totaux, cas surplus (alice +150, bob -100 => s=150, d=100).
    function test_settlementTotals_surplus() public {
        vm.prank(alice); market.submitOrder(150e18);
        vm.prank(bob);   market.submitOrder(-100e18);

        (UD60x18 cT, UD60x18 rT) = market.settlementTotals();
        assertApproxEqAbs(cT.unwrap(), 1516e18, TOL);
        assertApproxEqAbs(rT.unwrap(), 1959e18, TOL); // 1516 + 443
    }

    /// Étape 3 — câblage, cas déficit (alice +100, bob -150 => s=100, d=150).
    function test_settlementTotals_deficit() public {
        vm.prank(alice); market.submitOrder(100e18);    
        vm.prank(bob);   market.submitOrder(-150e18);

        (UD60x18 cT, UD60x18 rT) = market.settlementTotals();
        assertApproxEqAbs(rT.unwrap(), 1516e18, TOL);
        assertApproxEqAbs(cT.unwrap(), 2589e18, TOL); // 1516 + 1073
    }

    /// Étape 3 — câblage, cas équilibré.
    function test_settlementTotals_balanced() public {
        vm.prank(alice); market.submitOrder(100e18);
        vm.prank(bob);   market.submitOrder(-100e18);

        (UD60x18 cT, UD60x18 rT) = market.settlementTotals();
        assertApproxEqAbs(cT.unwrap(), 1516e18, TOL);
        assertApproxEqAbs(rT.unwrap(), 1516e18, TOL);
        assertEq(cT.unwrap(), rT.unwrap());
    }

    // ---------- ÉTAPE 4 : settlement (l'argent bouge) ----------

    /// conservation. La somme des soldes ne change pas.
    function test_settle_conservesMoney() public {
        vm.prank(alice); market.submitOrder(150e18);  // vendeuse
        vm.prank(bob);   market.submitOrder(-100e18); // acheteur

        uint256 before_ = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(grid);
        market.settle();
        uint256 after_ = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(grid);

        assertEq(before_, after_); 
    }

    /// Le vendeur touche R_total (surplus, Alice seule vendeuse).
    function test_settle_sellerPaid() public {
        vm.prank(alice); market.submitOrder(150e18);
        vm.prank(bob);   market.submitOrder(-100e18);

        uint256 before_ = token.balanceOf(alice);
        market.settle();
        // R_total surplus = 1516 + 443 = 1959 ; Alice seule vendeuse => tout
        assertApproxEqAbs(token.balanceOf(alice) - before_, 1959e18, TOL);
    }

    /// L'acheteur paie C_total (surplus, Bob seul acheteur).
    function test_settle_buyerCharged() public {
        vm.prank(alice); market.submitOrder(150e18);
        vm.prank(bob);   market.submitOrder(-100e18);

        uint256 before_ = token.balanceOf(bob);
        market.settle();
        // C_total surplus = 1516 ; Bob seul acheteur => tout
        assertApproxEqAbs(before_ - token.balanceOf(bob), 1516e18, TOL);
    }

    /// Fuzz conservation : sur des ordres quelconques, l'argent est conservé.
    function testFuzz_settle_conserves(int256 n1, int256 n2, int256 n3) public {
        n1 = bound(n1, int256(-1000e18), int256(1000e18));
        n2 = bound(n2, int256(-1000e18), int256(1000e18));
        n3 = bound(n3, int256(-1000e18), int256(1000e18));

        vm.prank(alice); market.submitOrder(n1);
        vm.prank(bob);   market.submitOrder(n2);
        vm.prank(carol); market.submitOrder(n3);

        uint256 before_ = token.balanceOf(alice) + token.balanceOf(bob)
                        + token.balanceOf(carol) + token.balanceOf(grid);
        market.settle();
        uint256 after_ = token.balanceOf(alice) + token.balanceOf(bob)
                       + token.balanceOf(carol) + token.balanceOf(grid);

        assertEq(before_, after_); // conservation, quels que soient les ordres
    }

}