// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { Market } from "../src/Market.sol";
import { EnergyEuro } from "../src/EnergyEuro.sol";
import { TokenBackend } from "../src/TokenBackend.sol";
import { NiceData } from "../src/NiceData.sol";

/// @notice Simulation of optimized paper reel netputs (Nice, t=48, 50 agents).
contract SimulationNiceTest is Test {
    Market market;
    EnergyEuro token;
    TokenBackend backend;

    UD60x18 constant LAMBDA_LOW  = UD60x18.wrap(8.86e18);
    UD60x18 constant LAMBDA_HIGH = UD60x18.wrap(21.46e18);
    UD60x18 constant RHO         = UD60x18.wrap(15.16e18);
    uint256 constant TOL = 1e13;

    address operator = address(0x09E5A70);
    address grid     = address(0x6819D);

    uint256 constant N = 50;
    address[N] prosumers;
    int256[N] netputs;

    function setUp() public {
        token   = new EnergyEuro();
        backend = new TokenBackend(token);
        market  = new Market(LAMBDA_LOW, LAMBDA_HIGH, backend, grid, operator);

        netputs = NiceData.netputs();

        token.mint(grid, 1_000_000e18);
        vm.prank(grid); token.approve(address(backend), type(uint256).max);

        for (uint256 i = 0; i < N; i++) {
            prosumers[i] = address(uint160(0x1000 + i));
            token.mint(prosumers[i], 1_000_000e18);
            vm.prank(prosumers[i]);
            token.approve(address(backend), type(uint256).max);
        }
    }

    function test_simulationNice_t48_50agents() public {
        uint256 totalBefore = _totalTracked();

        for (uint256 i = 0; i < N; i++) {
            vm.prank(operator);
            market.submitOrder(prosumers[i], netputs[i]);
        }

        (UD60x18 s, UD60x18 d) = market.aggregate();
        (UD60x18 r, UD60x18 c) = market.clearingPrices();

        console.log("=== Nice t=48, 50 agents ===");
        console.log("offre agregee  (kW x1e-3):", s.unwrap() / 1e15);
        console.log("demande agregee(kW x1e-3):", d.unwrap() / 1e15);
        console.log("r vendeurs    (EUR x1e-4):", r.unwrap() / 1e14);
        console.log("c acheteurs   (EUR x1e-4):", c.unwrap() / 1e14);

        vm.prank(operator);
        market.settle();

        // ---- verifications ----

        assertEq(_totalTracked(), totalBefore, "conservation failed");
        assertEq(token.balanceOf(address(market)), 0, "collateral not refunded");
        assertEq(market.prosumerCount(), 0, "session not reset");
        assertApproxEqAbs(c.unwrap(), RHO.unwrap(), TOL, "c != rho");
        assertLt(r.unwrap(), RHO.unwrap());
        assertGe(r.unwrap(), LAMBDA_LOW.unwrap());  
        assertLe(r.unwrap(), c.unwrap());           // no-arbitrage

    }

    function _totalTracked() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < N; i++) sum += token.balanceOf(prosumers[i]);
        sum += token.balanceOf(grid);
        sum += token.balanceOf(address(market));
    }
}
