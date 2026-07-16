// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { Market } from "../src/Market.sol";
import { EnergyEuro } from "../src/EnergyEuro.sol";
import { GridTariff } from "../src/GridTariff.sol";
import { NiceData } from "../src/NiceData.sol";
import { MerkleHelper } from "./utils/MerkleHelper.sol";

/// @notice Simulation of optimized paper reel netputs (Nice, t=48, 50 agents), full lifecycle.
contract SimulationNiceTest is Test {
    Market market;
    EnergyEuro token;
    GridTariff tariff;

    UD60x18 constant LAMBDA_LOW  = UD60x18.wrap(8.86e18);
    UD60x18 constant OFF_PEAK    = UD60x18.wrap(16.96e18);
    UD60x18 constant PEAK        = UD60x18.wrap(21.46e18);
    UD60x18 constant RHO_OFF     = UD60x18.wrap(12.91e18); // (8.86 + 16.96) / 2, t=48 = 12h
    uint256 constant TOL = 1e13;
    uint64  constant WINDOW = 24 hours;

    address operator = address(0x09E5A70);
    address grid     = address(0x6819D);
    address keeper   = address(0xCAFE);

    uint256 constant N = 50;
    address[N] prosumers;
    int256[N] netputs;
    bytes32 constant SALT = bytes32(uint256(7));

    uint256 constant DAY0 = 20_000 * 86400;
    uint32  day0;
    uint64  sid; // t=48 -> 12h00, off-peak window (12h-13h)

    function setUp() public {
        vm.warp(DAY0);
        day0 = uint32(DAY0 / 86400);
        sid  = uint64(DAY0 / 900) + 48;

        GridTariff.Schedule memory s;
        s.feedIn = LAMBDA_LOW; s.retailOffPeak = OFF_PEAK; s.retailPeak = PEAK;
        s.winStart = new uint32[](2); s.winEnd = new uint32[](2);
        s.winStart[0] = 8 * 3600;  s.winEnd[0] = 12 * 3600;
        s.winStart[1] = 13 * 3600; s.winEnd[1] = 20 * 3600;
        tariff = new GridTariff(GridTariff.Mode.Schedule, grid, s, new address[](0), 0);

        token  = new EnergyEuro();
        market = new Market(token, tariff, grid, operator, WINDOW);

        netputs = NiceData.netputs();

        token.mint(grid, 1_000_000e18);
        vm.prank(grid); token.approve(address(market), type(uint256).max);

        for (uint256 i = 0; i < N; i++) {
            prosumers[i] = address(uint160(0x1000 + i));
            token.mint(prosumers[i], 1_000_000e18);
            vm.startPrank(prosumers[i]);
            token.approve(address(market), type(uint256).max);
            market.deposit(100_000e18);
            vm.stopPrank();
        }
    }

    function test_simulationNice_t48_50agents() public {
        uint256 totalBefore = _totalTracked();

        // ---- operator side: tree + aggregates, one tx ----
        bytes32[] memory leaves = new bytes32[](N);
        uint256 ts; uint256 td;
        for (uint256 i = 0; i < N; i++) {
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
        (UD60x18 r, UD60x18 c) = market.clearingPrices(sid);

        console.log("=== Nice t=48, 50 agents ===");
        console.log("offre agregee  (kW x1e-3):", ts / 1e15);
        console.log("demande agregee(kW x1e-3):", td / 1e15);
        console.log("r vendeurs    (EUR x1e-4):", r.unwrap() / 1e14);
        console.log("c acheteurs   (EUR x1e-4):", c.unwrap() / 1e14);

        // ---- netting ----
        address[] memory accts = new address[](N);
        int256[]  memory amts  = new int256[](N);
        for (uint256 i = 0; i < N; i++) {
            accts[i] = prosumers[i];
            if (netputs[i] > 0)      amts[i] = int256(ud(uint256(netputs[i])).mul(r).unwrap());
            else if (netputs[i] < 0) amts[i] = -int256(ud(uint256(-netputs[i])).mul(c).unwrap());
        }
        vm.warp((uint256(day0) + 1) * 86400);
        vm.prank(operator);
        market.closeDay(day0, bytes32(uint256(0xDA)), accts, amts);

        // a prosumer verifies their own line during the window (proof against the root)
        (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs) =
            _challengeArgs(leaves, 0);
        vm.prank(prosumers[0]);
        vm.expectRevert(bytes("batch correct")); // honest batch: challenge rejected
        market.challenge(day0, sids, nps, salts, proofs);

        vm.warp(block.timestamp + WINDOW);
        vm.prank(keeper);
        market.finalizeDay(day0);

        // ---- verifications ----

        assertEq(_totalTracked(), totalBefore, "conservation failed");

        uint256 ledger;
        for (uint256 i = 0; i < N; i++) {
            ledger += market.balanceOf(prosumers[i]);
            assertEq(market.pendingDebit(prosumers[i]), 0, "debit not released");
        }
        assertEq(token.balanceOf(address(market)), ledger, "ledger not backed");

        assertApproxEqAbs(c.unwrap(), RHO_OFF.unwrap(), TOL, "c != rho");
        assertLt(r.unwrap(), RHO_OFF.unwrap());            // surplus at midday
        assertGe(r.unwrap(), LAMBDA_LOW.unwrap());
        assertLe(r.unwrap(), c.unwrap());                  // no-arbitrage
    }

    function _challengeArgs(bytes32[] memory leaves, uint256 who)
        internal view
        returns (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs)
    {
        sids  = new uint64[](1);  sids[0]  = sid;
        nps   = new int256[](1);  nps[0]   = netputs[who];
        salts = new bytes32[](1); salts[0] = SALT;
        proofs = new bytes32[][](1);
        proofs[0] = MerkleHelper.proof(leaves, who);
    }

    function _totalTracked() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < N; i++) sum += token.balanceOf(prosumers[i]);
        sum += token.balanceOf(grid);
        sum += token.balanceOf(address(market));
    }
}
