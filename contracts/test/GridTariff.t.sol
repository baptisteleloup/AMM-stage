// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test } from "forge-std/Test.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { GridTariff } from "../src/GridTariff.sol";

contract GridTariffTest is Test {
    GridTariff schedule;
    GridTariff feed;

    UD60x18 constant FEED_IN  = UD60x18.wrap(8.86e18);
    UD60x18 constant OFF_PEAK = UD60x18.wrap(16.96e18);
    UD60x18 constant PEAK     = UD60x18.wrap(21.46e18);

    address admin   = address(0xAD);
    address mallory = address(0xBAD);
    address[] reporters;

    uint256 constant DAY0 = 20_000 * 86400; // an arbitrary day boundary

    function _frenchSchedule() internal pure returns (GridTariff.Schedule memory s) {
        s.feedIn        = FEED_IN;
        s.retailOffPeak = OFF_PEAK;
        s.retailPeak    = PEAK;
        s.winStart = new uint32[](2);
        s.winEnd   = new uint32[](2);
        s.winStart[0] = 8 * 3600;  s.winEnd[0] = 12 * 3600; // 8h-12h
        s.winStart[1] = 13 * 3600; s.winEnd[1] = 20 * 3600; // 13h-20h
    }

    function setUp() public {
        vm.warp(DAY0);

        schedule = new GridTariff(
            GridTariff.Mode.Schedule, admin, _frenchSchedule(), new address[](0), 0
        );

        reporters.push(address(0xF1));
        reporters.push(address(0xF2));
        reporters.push(address(0xF3));
        feed = new GridTariff(
            GridTariff.Mode.Feed, admin, _frenchSchedule(), reporters, 2 // 2-of-3
        );
    }

    // ---- schedule mode ----

    function test_schedule_peakWindows() public view {
        (, UD60x18 h1) = schedule.getPrices(DAY0 + 9 * 3600);   // 9h  -> peak
        (, UD60x18 h2) = schedule.getPrices(DAY0 + 12 * 3600);  // 12h -> off-peak (lunch)
        (, UD60x18 h3) = schedule.getPrices(DAY0 + 15 * 3600);  // 15h -> peak
        (, UD60x18 h4) = schedule.getPrices(DAY0 + 22 * 3600);  // 22h -> off-peak
        assertEq(h1.unwrap(), PEAK.unwrap());
        assertEq(h2.unwrap(), OFF_PEAK.unwrap());
        assertEq(h3.unwrap(), PEAK.unwrap());
        assertEq(h4.unwrap(), OFF_PEAK.unwrap());
    }

    function test_schedule_boundaries() public view {
        (, UD60x18 before8) = schedule.getPrices(DAY0 + 8 * 3600 - 1);
        (, UD60x18 at8)     = schedule.getPrices(DAY0 + 8 * 3600);
        (, UD60x18 at20)    = schedule.getPrices(DAY0 + 20 * 3600);
        assertEq(before8.unwrap(), OFF_PEAK.unwrap());
        assertEq(at8.unwrap(), PEAK.unwrap());
        assertEq(at20.unwrap(), OFF_PEAK.unwrap()); // winEnd exclusive
    }

    function testFuzz_schedule_feedInConstant(uint256 secOfDay) public view {
        secOfDay = bound(secOfDay, 0, 86399);
        (UD60x18 lo,) = schedule.getPrices(DAY0 + secOfDay);
        assertEq(lo.unwrap(), FEED_IN.unwrap());
    }

    function test_schedule_revisionNextDay() public {
        GridTariff.Schedule memory s = _frenchSchedule();
        s.retailPeak = UD60x18.wrap(25e18);
        vm.prank(admin);
        schedule.setSchedule(s);

        (, UD60x18 today_) = schedule.getPrices(DAY0 + 9 * 3600);
        (, UD60x18 tomorrow_) = schedule.getPrices(DAY0 + 86400 + 9 * 3600);
        assertEq(today_.unwrap(), PEAK.unwrap());     // unchanged until day boundary
        assertEq(tomorrow_.unwrap(), 25e18);
    }

    function test_schedule_nonAdminCannotRevise() public {
        vm.prank(mallory);
        vm.expectRevert();
        schedule.setSchedule(_frenchSchedule());
    }

    // ---- feed mode ----

    function _vector(uint256 base) internal pure
        returns (UD60x18[96] memory lo, UD60x18[96] memory hi)
    {
        for (uint256 i = 0; i < 96; i++) {
            lo[i] = ud(base);
            hi[i] = ud(base * 2);
        }
    }

    function test_feed_quorumFinalizes() public {
        uint32 day = uint32(DAY0 / 86400) + 1;
        (UD60x18[96] memory lo, UD60x18[96] memory hi) = _vector(10e18);

        vm.prank(reporters[0]);
        feed.submitDailyPrices(day, lo, hi);
        assertEq(feed.activeHash(day), bytes32(0)); // 1 of 2: not yet

        vm.prank(reporters[1]);
        feed.submitDailyPrices(day, lo, hi);
        assertTrue(feed.activeHash(day) != bytes32(0));

        (UD60x18 l, UD60x18 h) = feed.getPrices(uint256(day) * 86400 + 7 * 900);
        assertEq(l.unwrap(), 10e18);
        assertEq(h.unwrap(), 20e18);
    }

    function test_feed_dissentBlocksQuorum() public {
        uint32 day = uint32(DAY0 / 86400) + 1;
        (UD60x18[96] memory lo1, UD60x18[96] memory hi1) = _vector(10e18);
        (UD60x18[96] memory lo2, UD60x18[96] memory hi2) = _vector(11e18); // dishonest value

        vm.prank(reporters[0]);
        feed.submitDailyPrices(day, lo1, hi1);
        vm.prank(reporters[1]);
        feed.submitDailyPrices(day, lo2, hi2);
        assertEq(feed.activeHash(day), bytes32(0)); // 1 + 1, no hash at quorum

        vm.prank(reporters[2]);
        feed.submitDailyPrices(day, lo1, hi1);      // honest majority
        assertTrue(feed.activeHash(day) != bytes32(0));
        (UD60x18 l,) = feed.getPrices(uint256(day) * 86400);
        assertEq(l.unwrap(), 10e18);
    }

    function test_feed_fallbackToLastFinalized() public {
        uint32 day = uint32(DAY0 / 86400) + 1;
        (UD60x18[96] memory lo, UD60x18[96] memory hi) = _vector(10e18);
        vm.prank(reporters[0]); feed.submitDailyPrices(day, lo, hi);
        vm.prank(reporters[1]); feed.submitDailyPrices(day, lo, hi);

        // day+1 never reaches quorum -> serve day's vector, flagged stale
        uint256 ts = (uint256(day) + 1) * 86400 + 5 * 900;
        (UD60x18 l,) = feed.getPrices(ts);
        assertEq(l.unwrap(), 10e18);
        assertTrue(feed.isStale(ts));
        assertFalse(feed.isStale(uint256(day) * 86400));
    }

    function test_feed_onlyReporters() public {
        (UD60x18[96] memory lo, UD60x18[96] memory hi) = _vector(10e18);
        vm.prank(mallory);
        vm.expectRevert();
        feed.submitDailyPrices(uint32(DAY0 / 86400) + 1, lo, hi);
    }

    function test_feed_oneSubmissionPerReporter() public {
        uint32 day = uint32(DAY0 / 86400) + 1;
        (UD60x18[96] memory lo, UD60x18[96] memory hi) = _vector(10e18);
        vm.prank(reporters[0]);
        feed.submitDailyPrices(day, lo, hi);
        vm.prank(reporters[0]);
        vm.expectRevert(); // cannot self-quorum
        feed.submitDailyPrices(day, lo, hi);
    }
}
