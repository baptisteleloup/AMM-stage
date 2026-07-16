// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { Market } from "../src/Market.sol";
import { EnergyEuro } from "../src/EnergyEuro.sol";
import { GridTariff } from "../src/GridTariff.sol";
import { MerkleHelper } from "./utils/MerkleHelper.sol";

contract SimulationTest is Test {
    Market market;
    EnergyEuro token;
    GridTariff tariff;

    UD60x18 constant LAMBDA_LOW  = UD60x18.wrap(8.86e18);
    UD60x18 constant OFF_PEAK    = UD60x18.wrap(16.96e18);
    UD60x18 constant LAMBDA_HIGH = UD60x18.wrap(21.46e18);
    UD60x18 constant RHO         = UD60x18.wrap(15.16e18); // (8.86 + 21.46) / 2, peak
    uint256 constant TOL = 1e12;
    uint64  constant WINDOW = 24 hours;

    address operator = address(0x09E5A70);
    address grid     = address(0x6819D);
    address keeper   = address(0xCAFE);

    address[8] prosumers = [
        address(0x51), address(0x52), address(0x53), address(0x54), // sellers
        address(0xB1), address(0xB2), address(0xB3), address(0xB4)  // buyers
    ];
    bytes32 constant SALT = bytes32(uint256(7));

    uint256 constant DAY0 = 20_000 * 86400;
    uint32  day0;
    uint64  sid; // one peak session per test

    function setUp() public {
        vm.warp(DAY0);
        day0 = uint32(DAY0 / 86400);
        sid  = uint64((DAY0 + 9 * 3600) / 900); // 9h: peak window

        GridTariff.Schedule memory s;
        s.feedIn = LAMBDA_LOW; s.retailOffPeak = OFF_PEAK; s.retailPeak = LAMBDA_HIGH;
        s.winStart = new uint32[](2); s.winEnd = new uint32[](2);
        s.winStart[0] = 8 * 3600;  s.winEnd[0] = 12 * 3600;
        s.winStart[1] = 13 * 3600; s.winEnd[1] = 20 * 3600;
        tariff = new GridTariff(GridTariff.Mode.Schedule, grid, s, new address[](0), 0);

        token  = new EnergyEuro();
        market = new Market(token, tariff, grid, operator, WINDOW);

        token.mint(grid, 100_000_000e18);
        vm.prank(grid); token.approve(address(market), type(uint256).max);
        for (uint256 i = 0; i < 8; i++) {
            token.mint(prosumers[i], 100_000_000e18);
            vm.startPrank(prosumers[i]);
            token.approve(address(market), type(uint256).max);
            market.deposit(1_000_000e18);
            vm.stopPrank();
        }
    }

    function _runDay(int256[8] memory netputs)
        internal
        returns (UD60x18 r, UD60x18 c, uint256 totalBefore)
    {
        totalBefore = _totalTracked();

        bytes32[] memory leaves = new bytes32[](8);
        uint256 ts; uint256 td;
        for (uint256 i = 0; i < 8; i++) {
            leaves[i] = MerkleHelper.leaf(prosumers[i], netputs[i], SALT);
            if (netputs[i] > 0) ts += uint256(netputs[i]);
            else td += uint256(-netputs[i]);
        }

        vm.warp(uint256(sid) * 900);
        vm.prank(operator);
        market.openSession(sid, MerkleHelper.root(leaves), ud(ts), ud(td));

        vm.warp((uint256(sid) + 1) * 900);
        vm.prank(keeper);
        market.settle(sid);
        (r, c) = market.clearingPrices(sid);

        // operator computes the day amounts off-chain (same fixed-point math)
        address[] memory accts = new address[](8);
        int256[]  memory amts  = new int256[](8);
        for (uint256 i = 0; i < 8; i++) {
            accts[i] = prosumers[i];
            if (netputs[i] > 0)      amts[i] = int256(ud(uint256(netputs[i])).mul(r).unwrap());
            else if (netputs[i] < 0) amts[i] = -int256(ud(uint256(-netputs[i])).mul(c).unwrap());
        }
        vm.warp((uint256(day0) + 1) * 86400);
        vm.prank(operator);
        market.closeDay(day0, bytes32(uint256(0xDA)), accts, amts);

        vm.warp(block.timestamp + WINDOW);
        vm.prank(keeper);
        market.finalizeDay(day0);
    }

    function _checkInvariants(uint256 totalBefore) internal view {
        assertEq(_totalTracked(), totalBefore, "conservation violee");

        uint256 ledger;
        for (uint256 i = 0; i < 8; i++) {
            ledger += market.balanceOf(prosumers[i]);
            assertEq(market.pendingDebit(prosumers[i]), 0, "debit non libere");
        }
        assertEq(token.balanceOf(address(market)), ledger, "ledger non adosse");

        (, bool finalized,,,) = market.dayBatch(day0);
        assertTrue(finalized, "jour non finalise");
    }

    function test_surplus() public {
        int256[8] memory netputs = [
            int256(200e18), int256(150e18), int256(100e18), int256(50e18),
            int256(-120e18), int256(-100e18), int256(-80e18), int256(-50e18)
        ];
        (UD60x18 r, UD60x18 c, uint256 totalBefore) = _runDay(netputs);

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
        (UD60x18 r, UD60x18 c, uint256 totalBefore) = _runDay(netputs);

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
        (UD60x18 r, UD60x18 c, uint256 totalBefore) = _runDay(netputs);

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
