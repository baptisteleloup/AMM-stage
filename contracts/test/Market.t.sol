// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test } from "forge-std/Test.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { Market } from "../src/Market.sol";
import { EnergyEuro } from "../src/EnergyEuro.sol";
import { GridTariff } from "../src/GridTariff.sol";
import { MerkleHelper } from "./utils/MerkleHelper.sol";

contract MarketTest is Test {
    Market market;
    EnergyEuro token;
    GridTariff tariff;

    UD60x18 constant FEED_IN  = UD60x18.wrap(8.86e18);
    UD60x18 constant OFF_PEAK = UD60x18.wrap(16.96e18);
    UD60x18 constant PEAK     = UD60x18.wrap(21.46e18);
    uint64  constant WINDOW   = 24 hours;

    address operator = address(0x09E5A70);
    address grid     = address(0x6819D);
    address keeper   = address(0xCAFE);   // any address: settlement is permissionless
    address mallory  = address(0xBAD);

    address[4] prosumers = [address(0x51), address(0x52), address(0xB1), address(0xB2)];
    bytes32 constant SALT = bytes32(uint256(42));

    uint256 constant DAY0 = 20_000 * 86400;
    uint32  day0;

    function setUp() public {
        vm.warp(DAY0);
        day0 = uint32(DAY0 / 86400);

        GridTariff.Schedule memory s;
        s.feedIn = FEED_IN; s.retailOffPeak = OFF_PEAK; s.retailPeak = PEAK;
        s.winStart = new uint32[](2); s.winEnd = new uint32[](2);
        s.winStart[0] = 8 * 3600;  s.winEnd[0] = 12 * 3600;
        s.winStart[1] = 13 * 3600; s.winEnd[1] = 20 * 3600;
        tariff = new GridTariff(GridTariff.Mode.Schedule, grid, s, new address[](0), 0);

        token  = new EnergyEuro();
        market = new Market(token, tariff, grid, operator, WINDOW);

        token.mint(grid, 1_000_000e18);
        vm.prank(grid); token.approve(address(market), type(uint256).max);

        for (uint256 i = 0; i < 4; i++) {
            token.mint(prosumers[i], 100_000e18);
            vm.startPrank(prosumers[i]);
            token.approve(address(market), type(uint256).max);
            market.deposit(50_000e18);
            vm.stopPrank();
        }
    }

    // ---- helpers ----

    function _leaves(int256[4] memory netputs) internal view returns (bytes32[] memory l) {
        l = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) l[i] = MerkleHelper.leaf(prosumers[i], netputs[i], SALT);
    }

    function _aggregates(int256[4] memory netputs) internal pure returns (UD60x18 s, UD60x18 d) {
        uint256 ts; uint256 td;
        for (uint256 i = 0; i < 4; i++) {
            if (netputs[i] > 0) ts += uint256(netputs[i]);
            else td += uint256(-netputs[i]);
        }
        return (ud(ts), ud(td));
    }

    /// open at sid, settle at sid+1 (by `keeper`), return session prices
    function _openAndSettle(uint64 sid, int256[4] memory netputs)
        internal returns (UD60x18 r, UD60x18 c)
    {
        (UD60x18 s, UD60x18 d) = _aggregates(netputs);
        vm.warp(uint256(sid) * 900);
        vm.prank(operator);
        market.openSession(sid, MerkleHelper.root(_leaves(netputs)), s, d);

        vm.warp((uint256(sid) + 1) * 900);
        vm.prank(keeper);
        market.settle(sid);
        return market.clearingPrices(sid);
    }

    function _amount(int256 netput, UD60x18 r, UD60x18 c) internal pure returns (int256) {
        if (netput > 0) return int256(ud(uint256(netput)).mul(r).unwrap());
        if (netput < 0) return -int256(ud(uint256(-netput)).mul(c).unwrap());
        return 0;
    }

    function _totalTracked() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < 4; i++) sum += token.balanceOf(prosumers[i]);
        sum += token.balanceOf(grid);
        sum += token.balanceOf(address(market));
    }

    // ---- balances ----

    function test_depositWithdraw() public {
        vm.prank(prosumers[0]);
        market.withdraw(10_000e18);
        assertEq(market.balanceOf(prosumers[0]), 40_000e18);
        assertEq(token.balanceOf(prosumers[0]), 60_000e18);
    }

    function test_withdrawRespectsFloor() public {
        vm.prank(operator);
        market.setFloor(prosumers[0], 45_000e18);
        vm.prank(prosumers[0]);
        vm.expectRevert();
        market.withdraw(10_000e18); // 50k - 10k < floor
    }

    // ---- sessions ----

    function test_openSession_onlyOperator() public {
        uint64 sid = market.currentSessionId();
        vm.prank(mallory);
        vm.expectRevert();
        market.openSession(sid, bytes32(0), ud(0), ud(0));
    }

    function test_openSession_rejectsWrongSlot() public {
        uint64 sid = market.currentSessionId();
        vm.prank(operator);
        vm.expectRevert(); // future session
        market.openSession(sid + 4, bytes32(0), ud(0), ud(0));
    }

    function test_settle_isPermissionless() public {
        int256[4] memory netputs = [int256(100e18), int256(50e18), int256(-80e18), int256(-40e18)];
        uint64 sid = uint64((DAY0 + 9 * 3600) / 900); // peak
        (UD60x18 r, UD60x18 c) = _openAndSettle(sid, netputs); // settled by `keeper`, not operator

        // surplus (150 > 120): c anchors at rho_peak, r below
        UD60x18 rho = FEED_IN.add(PEAK).div(ud(2e18));
        assertEq(c.unwrap(), rho.unwrap());
        assertLt(r.unwrap(), rho.unwrap());
        assertLe(r.unwrap(), c.unwrap());
    }

    function test_settle_usesTariffWindow() public {
        int256[4] memory netputs = [int256(100e18), int256(0), int256(-100e18), int256(0)];
        uint64 peakSid = uint64((DAY0 + 9 * 3600) / 900);
        uint64 offSid  = uint64((DAY0 + 22 * 3600) / 900);
        (, UD60x18 cPeak) = _openAndSettle(peakSid, netputs);
        (, UD60x18 cOff)  = _openAndSettle(offSid, netputs);

        // balanced market: c = rho of the window -> re-anchoring is on-chain now
        assertEq(cPeak.unwrap(), FEED_IN.add(PEAK).div(ud(2e18)).unwrap());
        assertEq(cOff.unwrap(),  FEED_IN.add(OFF_PEAK).div(ud(2e18)).unwrap());
    }

    function test_settle_revertsBeforeSessionEnd() public {
        uint64 sid = market.currentSessionId();
        vm.prank(operator);
        market.openSession(sid, bytes32(uint256(1)), ud(1e18), ud(1e18));
        vm.expectRevert();
        market.settle(sid);
    }

    function test_settle_revertsTwice() public {
        int256[4] memory netputs = [int256(100e18), int256(0), int256(-100e18), int256(0)];
        uint64 sid = uint64((DAY0 + 9 * 3600) / 900);
        _openAndSettle(sid, netputs);
        vm.expectRevert();
        market.settle(sid);
    }

    // ---- daily netting ----

    function _runOneDay()
        internal
        returns (int256[4] memory amounts, int256[4] memory netputs1, int256[4] memory netputs2, uint64 sid1, uint64 sid2)
    {
        netputs1 = [int256(100e18), int256(50e18), int256(-80e18), int256(-40e18)];  // surplus
        netputs2 = [int256(30e18),  int256(20e18), int256(-90e18), int256(-60e18)];  // deficit
        sid1 = uint64((DAY0 + 9 * 3600) / 900);
        sid2 = uint64((DAY0 + 15 * 3600) / 900);
        (UD60x18 r1, UD60x18 c1) = _openAndSettle(sid1, netputs1);
        (UD60x18 r2, UD60x18 c2) = _openAndSettle(sid2, netputs2);

        for (uint256 i = 0; i < 4; i++) {
            amounts[i] = _amount(netputs1[i], r1, c1) + _amount(netputs2[i], r2, c2);
        }
    }

    function _closeDay0(int256[4] memory amounts) internal {
        address[] memory accts = new address[](4);
        int256[]  memory amts  = new int256[](4);
        for (uint256 i = 0; i < 4; i++) { accts[i] = prosumers[i]; amts[i] = amounts[i]; }
        vm.warp((uint256(day0) + 1) * 86400);
        vm.prank(operator);
        market.closeDay(day0, bytes32(uint256(0xDA)), accts, amts);
    }

    function test_fullDay_happyPath() public {
        uint256 totalBefore = _totalTracked();
        (int256[4] memory amounts,,,,) = _runOneDay();

        uint256[4] memory before_;
        for (uint256 i = 0; i < 4; i++) before_[i] = market.balanceOf(prosumers[i]);

        _closeDay0(amounts);

        vm.warp(block.timestamp + WINDOW);
        vm.prank(keeper);                     // finalization is permissionless too
        market.finalizeDay(day0);

        for (uint256 i = 0; i < 4; i++) {
            int256 expected = int256(before_[i]) + amounts[i];
            assertEq(int256(market.balanceOf(prosumers[i])), expected, "balance mismatch");
            assertEq(market.pendingDebit(prosumers[i]), 0, "debit not released");
        }
        assertEq(_totalTracked(), totalBefore, "conservation violee");

        // pool tokens == sum of internal balances (ledger backed 1:1)
        uint256 ledger;
        for (uint256 i = 0; i < 4; i++) ledger += market.balanceOf(prosumers[i]);
        assertEq(token.balanceOf(address(market)), ledger, "ledger not backed");
    }

    function test_closeDay_rejectsBadSum() public {
        (int256[4] memory amounts,,,,) = _runOneDay();
        amounts[0] += 1e18; // operator tries to print 1 EEUR
        address[] memory accts = new address[](4);
        int256[]  memory amts  = new int256[](4);
        for (uint256 i = 0; i < 4; i++) { accts[i] = prosumers[i]; amts[i] = amounts[i]; }
        vm.warp((uint256(day0) + 1) * 86400);
        vm.prank(operator);
        vm.expectRevert(bytes("budget balance violated"));
        market.closeDay(day0, bytes32(0), accts, amts);
    }

    function test_closeDay_rejectsUnsettledSessions() public {
        int256[4] memory netputs = [int256(100e18), int256(0), int256(-100e18), int256(0)];
        uint64 sid = uint64((DAY0 + 9 * 3600) / 900);
        (UD60x18 s, UD60x18 d) = _aggregates(netputs);
        vm.warp(uint256(sid) * 900);
        vm.prank(operator);
        market.openSession(sid, MerkleHelper.root(_leaves(netputs)), s, d); // never settled

        vm.warp((uint256(day0) + 1) * 86400);
        vm.prank(operator);
        vm.expectRevert(bytes("unsettled sessions"));
        market.closeDay(day0, bytes32(0), new address[](0), new int256[](0));
    }

    function test_pendingDebitLocksWithdraw() public {
        (int256[4] memory amounts,,,,) = _runOneDay();
        _closeDay0(amounts);

        // prosumers[2] is a net buyer: debit locked during the window
        assertGt(market.pendingDebit(prosumers[2]), 0);
        vm.prank(prosumers[2]);
        vm.expectRevert();
        market.withdraw(50_000e18);

        vm.warp(block.timestamp + WINDOW);
        market.finalizeDay(day0);
        vm.prank(prosumers[2]);
        market.withdraw(1_000e18); // released after finalization
    }

    function test_finalize_revertsDuringWindow() public {
        (int256[4] memory amounts,,,,) = _runOneDay();
        _closeDay0(amounts);
        vm.expectRevert(bytes("challenge window open"));
        market.finalizeDay(day0);
    }

    // ---- challenge ----

    function _challengeArgs(int256[4] memory netputs1, int256[4] memory netputs2, uint64 sid1, uint64 sid2, uint256 who)
        internal view
        returns (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs)
    {
        sids  = new uint64[](2);  sids[0] = sid1;        sids[1] = sid2;
        nps   = new int256[](2);  nps[0]  = netputs1[who]; nps[1] = netputs2[who];
        salts = new bytes32[](2); salts[0] = SALT;       salts[1] = SALT;
        proofs = new bytes32[][](2);
        proofs[0] = MerkleHelper.proof(_leaves(netputs1), who);
        proofs[1] = MerkleHelper.proof(_leaves(netputs2), who);
    }

    function test_challenge_cancelsDishonestBatch() public {
        (int256[4] memory amounts, int256[4] memory n1, int256[4] memory n2, uint64 sid1, uint64 sid2) = _runOneDay();

        // operator moves 3 EEUR from prosumers[0] to prosumers[1]: sum unchanged, passes closeDay
        amounts[0] -= 3e18;
        amounts[1] += 3e18;
        _closeDay0(amounts);

        (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs) =
            _challengeArgs(n1, n2, sid1, sid2, 0);
        vm.prank(prosumers[0]);
        market.challenge(day0, sids, nps, salts, proofs);

        (,, bool cancelled,,) = market.dayBatch(day0);
        assertTrue(cancelled);
        for (uint256 i = 0; i < 4; i++) assertEq(market.pendingDebit(prosumers[i]), 0);

        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(bytes("cancelled"));
        market.finalizeDay(day0); // no money ever moves on a cancelled day
    }

    function test_challenge_rejectsHonestBatch() public {
        (int256[4] memory amounts, int256[4] memory n1, int256[4] memory n2, uint64 sid1, uint64 sid2) = _runOneDay();
        _closeDay0(amounts);

        (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs) =
            _challengeArgs(n1, n2, sid1, sid2, 0);
        vm.prank(prosumers[0]);
        vm.expectRevert(bytes("batch correct"));
        market.challenge(day0, sids, nps, salts, proofs); // no griefing on honest operator
    }

    function test_challenge_rejectsForgedLeaf() public {
        (int256[4] memory amounts, int256[4] memory n1, int256[4] memory n2, uint64 sid1, uint64 sid2) = _runOneDay();
        _closeDay0(amounts);

        (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs) =
            _challengeArgs(n1, n2, sid1, sid2, 0);
        nps[0] = 500e18; // claims a netput not in the tree
        vm.prank(prosumers[0]);
        vm.expectRevert(bytes("bad proof"));
        market.challenge(day0, sids, nps, salts, proofs);
    }

    function test_challenge_detectsOmittedProsumer() public {
        (int256[4] memory amounts, int256[4] memory n1, int256[4] memory n2, uint64 sid1, uint64 sid2) = _runOneDay();

        // operator drops prosumers[0] (a net seller) and keeps their revenue at the grid leg
        address[] memory accts = new address[](3);
        int256[]  memory amts  = new int256[](3);
        for (uint256 i = 1; i < 4; i++) { accts[i - 1] = prosumers[i]; amts[i - 1] = amounts[i]; }
        vm.warp((uint256(day0) + 1) * 86400);
        vm.prank(operator);
        vm.expectRevert(bytes("budget balance violated")); // caught even before any challenge
        market.closeDay(day0, bytes32(0), accts, amts);

        // if the operator also fakes the sum by inflating someone else, the challenge catches it
        amts[0] = amounts[1] + amounts[0]; // give prosumers[0]'s revenue to prosumers[1]
        vm.prank(operator);
        market.closeDay(day0, bytes32(0), accts, amts);

        (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs) =
            _challengeArgs(n1, n2, sid1, sid2, 0);
        vm.prank(prosumers[0]); // omitted -> claimed = 0 != truth
        market.challenge(day0, sids, nps, salts, proofs);
        (,, bool cancelled,,) = market.dayBatch(day0);
        assertTrue(cancelled);
    }
}
