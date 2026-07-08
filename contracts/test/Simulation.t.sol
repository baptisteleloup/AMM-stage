// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { Market } from "../src/Market.sol";
import { EnergyEuro } from "../src/EnergyEuro.sol";
import { TokenBackend } from "../src/TokenBackend.sol";

contract SimulationTest is Test {
    Market market;
    EnergyEuro token;
    TokenBackend backend;

    UD60x18 constant LAMBDA_LOW  = UD60x18.wrap(8.86e18);
    UD60x18 constant LAMBDA_HIGH = UD60x18.wrap(21.46e18);
    UD60x18 constant RHO         = UD60x18.wrap(15.16e18); // (8.86 + 21.46) / 2
    uint256 constant TOL = 1e12;

    address operator = address(0x09E5A70);
    address grid     = address(0x6819D);

    address[8] prosumers = [
        address(0x51), address(0x52), address(0x53), address(0x54), // sellers
        address(0xB1), address(0xB2), address(0xB3), address(0xB4)  // buyers
    ];

    function setUp() public {
        token   = new EnergyEuro();
        backend = new TokenBackend(token);
        market  = new Market(LAMBDA_LOW, LAMBDA_HIGH, backend, grid, operator);

        token.mint(grid, 100_000_000e18);
        vm.prank(grid); token.approve(address(backend), type(uint256).max);
        for (uint256 i = 0; i < 8; i++) {
            token.mint(prosumers[i], 100_000_000e18);
            vm.prank(prosumers[i]);
            token.approve(address(backend), type(uint256).max);
        }
    }


     function _runSession(int256[8] memory netputs)
        internal
        returns (UD60x18 r, UD60x18 c, uint256[8] memory startBal, uint256 totalBefore)
    {
        for (uint256 i = 0; i < 8; i++) startBal[i] = token.balanceOf(prosumers[i]);
        totalBefore = _totalTracked();

        for (uint256 i = 0; i < 8; i++) {
            vm.prank(operator);
            market.submitOrder(prosumers[i], netputs[i]);
        }

        (r, c) = market.clearingPrices();

        vm.prank(operator);
        market.settle();
    }

    function _checkInvariants(uint256 totalBefore) internal view {
        assertEq(_totalTracked(), totalBefore, "conservation violee");
        assertEq(token.balanceOf(address(market)), 0, "collateral coince");
        assertEq(market.prosumerCount(), 0, "session non reset");
        for (uint256 i = 0; i < 8; i++) {
            assertEq(market.collateralOf(prosumers[i]), 0, "collateral non rendu");
        }
    }

    function test_surplus() public {
        int256[8] memory netputs = [
            int256(200e18), int256(150e18), int256(100e18), int256(50e18),
            int256(-120e18), int256(-100e18), int256(-80e18), int256(-50e18)
        ];
        (UD60x18 r, UD60x18 c,, uint256 totalBefore) = _runSession(netputs);

        console.log("=== SURPLUS (supply 500 > demand 350) ===");
        _logPrices(r, c);
        _checkInvariants(totalBefore);

        assertApproxEqAbs(c.unwrap(), RHO.unwrap(), TOL);
        assertLt(r.unwrap(), RHO.unwrap());
        assertLe(r.unwrap(), c.unwrap()); // no-arbitrage
    }

    function test_deficit() public {
        int256[8] memory netputs = [
            int256(120e18), int256(100e18), int256(80e18), int256(50e18),
            int256(-200e18), int256(-150e18), int256(-100e18), int256(-50e18)
        ];
        (UD60x18 r, UD60x18 c,, uint256 totalBefore) = _runSession(netputs);

        console.log("=== DEFICIT (supply 350 < demand 500) ===");
        _logPrices(r, c);
        _checkInvariants(totalBefore);

        assertApproxEqAbs(r.unwrap(), RHO.unwrap(), TOL);
        assertGt(c.unwrap(), RHO.unwrap());
        assertLe(r.unwrap(), c.unwrap());
    }

    function test_balanced() public {
        int256[8] memory netputs = [
            int256(150e18), int256(120e18), int256(80e18), int256(50e18),
            int256(-150e18), int256(-120e18), int256(-80e18), int256(-50e18)
        ];
        (UD60x18 r, UD60x18 c,, uint256 totalBefore) = _runSession(netputs);

        console.log("=== BALANCED (supply 400 = demand 400) ===");
        _logPrices(r, c);
        _checkInvariants(totalBefore);

        assertApproxEqAbs(r.unwrap(), RHO.unwrap(), TOL);
        assertApproxEqAbs(c.unwrap(), RHO.unwrap(), TOL);
    }

    
    function _logPrices(UD60x18 r, UD60x18 c) internal pure {
        console.log("r (vendeurs) x1e-4:", r.unwrap() / 1e14);
        console.log("c (acheteurs) x1e-4:", c.unwrap() / 1e14);
    }

    function _totalTracked() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < 8; i++) sum += token.balanceOf(prosumers[i]);
        sum += token.balanceOf(grid);
        sum += token.balanceOf(address(market));
    }
}