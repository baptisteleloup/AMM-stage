// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test } from "forge-std/Test.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { MarketZK, IDayBatchVerifier } from "../src/MarketZK.sol";
import { EnergyEuro } from "../src/EnergyEuro.sol";
import { GridTariff } from "../src/GridTariff.sol";
import { PoseidonT3 } from "../src/PoseidonT3.sol";
import { Groth16Verifier } from "../src/DayBatchVerifier.sol";
import { ZKFixture } from "./utils/ZKFixture.sol";
import { MerkleHelper } from "./utils/MerkleHelper.sol";

contract MarketZKTest is Test {
    MarketZK market;
    EnergyEuro token;
    GridTariff tariff;
    IDayBatchVerifier verifier;

    UD60x18 constant FEED_IN  = UD60x18.wrap(8.86e18);
    UD60x18 constant OFF_PEAK = UD60x18.wrap(16.96e18);
    UD60x18 constant PEAK     = UD60x18.wrap(21.46e18);
    uint64  constant WINDOW = 24 hours;
    bytes32 constant SALT = bytes32(uint256(7));

    address operator = address(0x09E5A70);
    address grid     = address(0x6819D);
    address keeper   = address(0xCAFE);

    // must mirror zk/prove_day.js
    address[2] prosumers = [address(0x51), address(0xB1)];
    int256[2]  netputs   = [int256(100e18), int256(-100e18)];

    uint256 constant DAY0 = 20_000 * 86400;
    uint32  day0;
    uint64  sid;

    function setUp() public {
        vm.warp(DAY0);
        day0 = uint32(DAY0 / 86400);
        sid  = uint64((DAY0 + 9 * 3600) / 900); // peak: rho = 15.16

        GridTariff.Schedule memory s;
        s.feedIn = FEED_IN; s.retailOffPeak = OFF_PEAK; s.retailPeak = PEAK;
        s.winStart = new uint32[](2); s.winEnd = new uint32[](2);
        s.winStart[0] = 8 * 3600;  s.winEnd[0] = 12 * 3600;
        s.winStart[1] = 13 * 3600; s.winEnd[1] = 20 * 3600;
        tariff = new GridTariff(GridTariff.Mode.Schedule, grid, s, new address[](0), 0);

        token    = new EnergyEuro();
        verifier = IDayBatchVerifier(address(new Groth16Verifier()));
        market   = new MarketZK(token, tariff, verifier, grid, operator, WINDOW);

        // pool funded to cover hidden balances (bootstrap = migration hook)
        token.mint(address(market), 2 * 5000e18);
        token.mint(grid, 1_000_000e18);
        vm.prank(grid); token.approve(address(market), type(uint256).max);

        vm.startPrank(operator);
        for (uint256 i = 0; i < 2; i++) market.register(prosumers[i], i);
        market.bootstrapBalances(ZKFixture.oldC());
        vm.stopPrank();
    }

    function _leaves() internal view returns (bytes32[] memory l) {
        l = new bytes32[](2);
        for (uint256 i = 0; i < 2; i++) l[i] = MerkleHelper.leaf(prosumers[i], netputs[i], SALT);
    }

    function _runSession() internal {
        // balanced session: s = d = 150 -> r = c = rho exactly
        vm.warp(uint256(sid) * 900);
        vm.prank(operator);
        market.openSession(sid, MerkleHelper.root(_leaves()), ud(100e18), ud(100e18));
        vm.warp((uint256(sid) + 1) * 900);
        vm.prank(keeper);
        market.settle(sid);
    }

    function _closeHonest() internal {
        vm.warp((uint256(day0) + 1) * 86400);
        vm.prank(operator);
        market.closeDayZK(day0, bytes32(uint256(0xDA)), ZKFixture.honestAmtC(),
            ZKFixture.honestNewC(), ZKFixture.honestSum(),
            ZKFixture.honestA(), ZKFixture.honestB(), ZKFixture.honestC());
    }

    // ---- the pipeline ----

    function test_poseidonSolidity_matchesCircomlibjs() public pure {
        // vectors from circomlibjs (the operator side)
        assertEq(PoseidonT3.hash([uint256(0), uint256(0)]),
            14744269619966411208579211824598458697587494354926760081771325075741142829156);
        assertEq(PoseidonT3.hash([uint256(1), uint256(2)]),
            7853200120776062878684798364095072458815029376092732009249414926327459813530);
    }

    function test_realProofAccepted_amountsHidden() public {
        _runSession();
        _closeHonest();
        (bool closed,,,,, int256 net) = market.dayBatch(day0);
        assertTrue(closed);
        assertEq(net, 0); // balanced day, proven blind: no clear amount anywhere
    }

    function test_tamperedCommitmentRejected() public {
        _runSession();
        uint256[2] memory amtC = ZKFixture.honestAmtC();
        amtC[0] ^= 1; // one bit
        vm.warp((uint256(day0) + 1) * 86400);
        vm.prank(operator);
        vm.expectRevert(bytes("invalid proof"));
        market.closeDayZK(day0, bytes32(0), amtC, ZKFixture.honestNewC(),
            ZKFixture.honestSum(), ZKFixture.honestA(), ZKFixture.honestB(), ZKFixture.honestC());
    }

    function test_proofBoundToChainState() public {
        _runSession();
        // a deposit changes pendingDelta -> contract-built publics change -> proof dies
        token.mint(prosumers[0], 10e18);
        vm.startPrank(prosumers[0]);
        token.approve(address(market), 10e18);
        market.deposit(10e18);
        vm.stopPrank();
        vm.warp((uint256(day0) + 1) * 86400);
        vm.prank(operator);
        vm.expectRevert(bytes("invalid proof"));
        market.closeDayZK(day0, bytes32(0), ZKFixture.honestAmtC(), ZKFixture.honestNewC(),
            ZKFixture.honestSum(), ZKFixture.honestA(), ZKFixture.honestB(), ZKFixture.honestC());
    }

    function test_fullDay_finalizeAdvancesHiddenBalances() public {
        _runSession();
        _closeHonest();
        vm.warp(block.timestamp + WINDOW);
        vm.prank(keeper);
        market.finalizeDay(day0);
        uint256[2] memory expected = ZKFixture.honestNewC();
        for (uint256 i = 0; i < 2; i++) assertEq(market.balC(i), expected[i]);
    }

    // ---- the optimistic game on hidden amounts ----

    function _challengeArgs() internal view
        returns (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs)
    {
        sids  = new uint64[](1);  sids[0]  = sid;
        nps   = new int256[](1);  nps[0]   = netputs[0];
        salts = new bytes32[](1); salts[0] = SALT;
        proofs = new bytes32[][](1);
        proofs[0] = MerkleHelper.proof(_leaves(), 0);
    }

    function test_challenge_honestBatchUngriefable() public {
        _runSession();
        _closeHonest();
        (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs) = _challengeArgs();
        (uint256 amtS, uint256 amtR) = ZKFixture.honestOpen0();
        vm.prank(prosumers[0]);
        vm.expectRevert(bytes("batch correct"));
        market.challenge(day0, sids, nps, salts, proofs, amtS, amtR);
    }

    function test_challenge_catchesHiddenRedistribution() public {
        _runSession();
        // dishonest batch: valid proof (sum unchanged), amounts silently moved
        vm.warp((uint256(day0) + 1) * 86400);
        vm.prank(operator);
        market.closeDayZK(day0, bytes32(0), ZKFixture.badAmtC(), ZKFixture.badNewC(),
            ZKFixture.badSum(), ZKFixture.badA(), ZKFixture.badB(), ZKFixture.badC());

        (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs) = _challengeArgs();
        (uint256 amtS, uint256 amtR) = ZKFixture.badOpen0();
        vm.prank(prosumers[0]);
        market.challenge(day0, sids, nps, salts, proofs, amtS, amtR);
        (,, bool cancelled,,,) = market.dayBatch(day0);
        assertTrue(cancelled);

        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(bytes("cancelled"));
        market.finalizeDay(day0);
    }

    function test_challenge_forgedOpeningRejected() public {
        _runSession();
        _closeHonest();
        (uint64[] memory sids, int256[] memory nps, bytes32[] memory salts, bytes32[][] memory proofs) = _challengeArgs();
        (uint256 amtS, uint256 amtR) = ZKFixture.honestOpen0();
        vm.prank(prosumers[0]);
        vm.expectRevert(bytes("bad opening"));
        market.challenge(day0, sids, nps, salts, proofs, amtS + 1, amtR);
    }
}
