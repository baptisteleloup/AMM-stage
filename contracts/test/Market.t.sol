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
    uint256 constant TOL = 1e12;

    address operator = address(0x09E5A70);  
    address grid     = address(0x6819D);
    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);
    address carol    = address(0xCA201);

    function setUp() public {
        token   = new EnergyEuro();
        backend = new TokenBackend(token);
        market  = new Market(LAMBDA_LOW, LAMBDA_HIGH, backend, grid, operator);

        token.mint(grid,  1_000_000e18);
        token.mint(alice, 1_000_000e18);
        token.mint(bob,   1_000_000e18);
        token.mint(carol, 1_000_000e18);

        vm.prank(grid);  token.approve(address(backend), type(uint256).max);
        vm.prank(alice); token.approve(address(backend), type(uint256).max);
        vm.prank(bob);   token.approve(address(backend), type(uint256).max);
        vm.prank(carol); token.approve(address(backend), type(uint256).max);
    }

    function _submit(address who, int256 netput) internal {
        vm.prank(operator);
        market.submitOrder(who, netput);
    }

    function test_submit_storesNetput() public {
        _submit(alice, 150e18);
        (int256 n, bool ex) = market.orderOf(alice);
        assertEq(n, 150e18);
        assertTrue(ex);
        assertEq(market.prosumerCount(), 1);
    }

    function test_onlyOperatorCanSubmit() public {
        vm.prank(alice);            
        vm.expectRevert();
        market.submitOrder(alice, 150e18);
    }

    function test_resubmit_noDuplicate() public {
        _submit(alice, 150e18);
        _submit(alice, 80e18);     
        (int256 n,) = market.orderOf(alice);
        assertEq(n, 80e18);
        assertEq(market.prosumerCount(), 1);
    }

    function test_zeroNetput_isValid() public {
        _submit(alice, 0);
        (, bool ex) = market.orderOf(alice);
        assertTrue(ex);
        assertEq(market.prosumerCount(), 1);
    }

    function test_decompose_allCases() public view {
        (uint256 s1, uint256 d1) = market.decompose(150e18);
        assertEq(s1, 150e18); assertEq(d1, 0);
        (uint256 s2, uint256 d2) = market.decompose(-80e18);
        assertEq(s2, 0); assertEq(d2, 80e18);
        (uint256 s3, uint256 d3) = market.decompose(0);
        assertEq(s3, 0); assertEq(d3, 0);
    }

    function test_aggregate_mixed() public {
        _submit(alice, 150e18);
        _submit(bob, -100e18);
        (UD60x18 s, UD60x18 d) = market.aggregate();
        assertEq(s.unwrap(), 150e18);
        assertEq(d.unwrap(), 100e18);
    }

    function test_clearingPrices_goldenSurplus() public {
        _submit(alice, 150e18);
        _submit(bob, -100e18);
        (UD60x18 r, UD60x18 c) = market.clearingPrices();
        assertApproxEqAbs(r.unwrap(), 13.06e18, TOL);
        assertApproxEqAbs(c.unwrap(), 15.16e18, TOL);
    }

    function test_settlementTotals_surplus() public {
        _submit(alice, 150e18);
        _submit(bob, -100e18);
        (UD60x18 cT, UD60x18 rT) = market.settlementTotals();
        assertApproxEqAbs(cT.unwrap(), 1516e18, TOL);
        assertApproxEqAbs(rT.unwrap(), 1959e18, TOL);
    }

    function test_collateral_buyerLocked() public {
        uint256 before_ = token.balanceOf(bob);
        _submit(bob, -100e18);
        // 100 * 21.46 = 2146
        assertEq(market.collateralOf(bob), 2146e18);
        assertEq(before_ - token.balanceOf(bob), 2146e18);
        assertEq(token.balanceOf(address(market)), 2146e18);
    }

    function test_collateral_sellerNone() public {
        uint256 before_ = token.balanceOf(alice);
        _submit(alice, 150e18);
        assertEq(market.collateralOf(alice), 0);
        assertEq(token.balanceOf(alice), before_);
    }

    function test_collateral_resubmitBuyerToBuyer() public {
        _submit(bob, -100e18);              
        _submit(bob, -50e18);               
        assertEq(market.collateralOf(bob), 1073e18);
        assertEq(token.balanceOf(address(market)), 1073e18);
    }

    function test_collateral_resubmitBuyerToSeller() public {
        uint256 before_ = token.balanceOf(bob);
        _submit(bob, -100e18);              
        _submit(bob, 80e18);               
        assertEq(market.collateralOf(bob), 0);
        assertEq(token.balanceOf(bob), before_); 
    }

    function test_settle_conservesMoney() public {
        uint256 before_ = _totalBalances();
        _submit(alice, 150e18);
        _submit(bob, -100e18);
        vm.prank(operator); market.settle();
        assertEq(_totalBalances(), before_);
    }

    function test_settle_sellerPaid() public {
        _submit(alice, 150e18);
        _submit(bob, -100e18);
        uint256 before_ = token.balanceOf(alice);
        vm.prank(operator); market.settle();
        assertApproxEqAbs(token.balanceOf(alice) - before_, 1959e18, TOL);
    }

    function test_settle_buyerNetCostAndRefund() public {
        _submit(alice, 150e18);
        uint256 before_ = token.balanceOf(bob);
        _submit(bob, -100e18);              
        vm.prank(operator); market.settle();
        assertApproxEqAbs(before_ - token.balanceOf(bob), 1516e18, TOL);
        assertEq(market.collateralOf(bob), 0);
    }

    function test_settle_resetsSession() public {
        _submit(alice, 150e18);
        _submit(bob, -100e18);
        vm.prank(operator); market.settle();
        assertEq(market.prosumerCount(), 0);
        (, bool ex) = market.orderOf(alice);
        assertFalse(ex);
        assertEq(token.balanceOf(address(market)), 0); 
    }

    function test_onlyOperatorCanSettle() public {
        _submit(alice, 150e18);
        _submit(bob, -100e18);
        vm.prank(alice);
        vm.expectRevert();
        market.settle();
    }

    function test_onlyOperatorCanSetGridPrices() public {
        vm.prank(alice);
        vm.expectRevert();
        market.setGridPrices(LAMBDA_LOW, LAMBDA_HIGH);
    }

    function testFuzz_settle_conserves(int256 n1, int256 n2, int256 n3) public {
        n1 = bound(n1, int256(-1000e18), int256(1000e18));
        n2 = bound(n2, int256(-1000e18), int256(1000e18));
        n3 = bound(n3, int256(-1000e18), int256(1000e18));

        uint256 before_ = _totalBalances();
        _submit(alice, n1);
        _submit(bob, n2);
        _submit(carol, n3);
        vm.prank(operator); market.settle();
        assertEq(_totalBalances(), before_);
    }

    function testFuzz_clearingPrices_respectIR(int256 n1, int256 n2) public {
        n1 = bound(n1, int256(-1000e18), int256(1000e18));
        n2 = bound(n2, int256(-1000e18), int256(1000e18));
        _submit(alice, n1);
        _submit(bob, n2);
        (UD60x18 r, UD60x18 c) = market.clearingPrices();
        assertGe(r.unwrap(), LAMBDA_LOW.unwrap());
        assertLe(c.unwrap(), LAMBDA_HIGH.unwrap());
        assertLe(r.unwrap(), c.unwrap()); // no-arbitrage
    }


    function _totalBalances() internal view returns (uint256) {
        return token.balanceOf(alice) + token.balanceOf(bob)
             + token.balanceOf(carol) + token.balanceOf(grid)
             + token.balanceOf(address(market));
    }
}