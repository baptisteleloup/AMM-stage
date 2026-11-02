// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {MarketV4} from "../src/MarketV4.sol";
import {GridTariff} from "../src/GridTariff.sol";
import {Pricing, PricingLib} from "../src/Pricing.sol";
import {EnergyEuro} from "../src/EnergyEuro.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IHonkVerifier} from "../src/interfaces/IVerifier.sol";

// End-to-end test of MarketV4 with the real generated verifiers and real UltraHonk proofs, built
// through vm.ffi by js_scripts/generateProof_daychunk.ts and generateProof_reveal.ts (scenario.ts).
// Slow, needs npx tsx and the compiled circuits. Run from contracts/:
// forge test --match-path "test/*.ffi.t.sol"
contract MarketV4FFITest is Test {
    uint256 constant DAY = 86400;
    uint256 constant SLOT = 900; // session length, s
    uint256 constant BATCH = 8;
    uint256 constant UNIT = 1e6; // token wei per internal unit (MarketV4.WEI_PER_UNIT)

    uint256 constant T1 = 10; // session where alice sells 100 Wh to bob (as in scenario.ts)
    uint256 constant T2 = 50; // session where bob buys 200 Wh alone, from the grid
    uint256 constant FLOOR = 31e12; // members' floor in internal units (31 EEUR), as in scenario.ts
    uint256 constant DEPOSIT_D0_WEI = 50 ether; // each member's deposit, applied by day 0

    MarketV4 market;
    GridTariff tariff;
    Pricing pricing;

    // Pricing rule of the community. The provers take the recorded rates as arguments.
    function _rule() internal pure virtual returns (PricingLib.Rule) {
        return PricingLib.Rule.MidMarket;
    }
    EnergyEuro eeur;

    address operator = makeAddr("operator");
    address grid = makeAddr("grid");
    address floorAdmin = makeAddr("floorAdmin");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice"); // slot 1
    address bob = makeAddr("bob"); // slot 2
    address reserve = makeAddr("reserve");

    uint256 day0; // deposits only, no trade
    uint256 day1; // alice sells, bob buys

    // Deploys the market with the real verifiers and the prover's constants, registers alice and bob,
    // co-signs their floors and queues a 50 EEUR deposit each.
    function setUp() public {
        vm.warp(20_000 * DAY);
        day0 = block.timestamp / DAY;
        day1 = day0 + 1;

        (bytes32 emptyHash, bytes32 zeroCommit, bytes32 floorC1, bytes32 floorC2) = _ffiConstants(); // must match the circuit's hashes

        eeur = new EnergyEuro();
        GridTariff.Schedule memory sched = GridTariff.Schedule({
            feedIn: ud(8.86e18),
            retailOffPeak: ud(16.96e18),
            retailPeak: ud(21.46e18),
            winStart: new uint32[](0),
            winEnd: new uint32[](0)
        }); // flat band, no peak windows
        tariff = new GridTariff(GridTariff.Mode.Schedule, admin, sched, new address[](0), 0);

        pricing = new Pricing(_rule());
        market = new MarketV4(
            IERC20(address(eeur)),
            IHonkVerifier(deployCode("DayChunkVerifier.sol:HonkVerifier")),
            IHonkVerifier(deployCode("RevealVerifier.sol:HonkVerifier")),
            tariff,
            pricing,
            operator,
            grid,
            floorAdmin,
            reserve,
            emptyHash,
            zeroCommit
        );

        vm.prank(alice);
        market.register(bytes.concat(hex"02", bytes32("alice_pk")));
        vm.prank(bob);
        market.register(bytes.concat(hex"02", bytes32("bob_pk")));
        vm.prank(operator);
        market.proposeFloor(1, floorC1);
        vm.prank(floorAdmin);
        market.confirmFloor(1, floorC1);
        vm.prank(operator);
        market.proposeFloor(2, floorC2);
        vm.prank(floorAdmin);
        market.confirmFloor(2, floorC2);

        deal(address(eeur), alice, 100 ether);
        deal(address(eeur), bob, 100 ether);
        deal(address(eeur), grid, 1000 ether);
        vm.prank(alice);
        eeur.approve(address(market), type(uint256).max);
        vm.prank(bob);
        eeur.approve(address(market), type(uint256).max);
        vm.prank(grid);
        eeur.approve(address(market), type(uint256).max);

        vm.prank(alice);
        market.deposit(DEPOSIT_D0_WEI);
        vm.prank(bob);
        market.deposit(DEPOSIT_D0_WEI);
    }


    // Two full days with real proofs: day 0 applies the deposits, day 1 trades, rejects a wrong total,
    // answers both recourse stages with a real reveal proof, then settles and pays the grid.
    function test_FFI_TwoDayLifecycle_RealProofs() public {
        vm.warp(day1 * DAY + 1); // just after day 0's midnight
        (
            bytes memory proof0,
            bytes32[] memory hashes0,
            bytes32[] memory commits0,
            uint256 out0,
            uint256 in0
        ) = _ffiDay(0, 0, 0, 0, 0); // day 0 has no session, so no rates
        assertEq(out0, 0);
        assertEq(in0, 0);

        vm.prank(operator);
        market.postNetputHashes(day0, hashes0);
        market.submitChunk(
            day0,
            0,
            MarketV4.ChunkSubmission(commits0, _zeros(), _emptyS(), _emptyS(), 0, 0),
            proof0
        );

        vm.warp(day1 * DAY + T1 * SLOT + 1);
        vm.prank(operator);
        market.openSession(day1, T1, 100, 100); // trading goes on while day 0 is closing

        vm.warp(day1 * DAY + market.PROOF_WINDOW() + 1);
        market.finalizeDay(day0); // the deposits are now in the balance commitments
        assertEq(market.balCommitOf(1), commits0[0]);
        assertEq(market.balCommitOf(2), commits0[1]);

        vm.warp(day1 * DAY + T2 * SLOT + 1);
        vm.prank(operator);
        market.openSession(day1, T2, 0, 200);
        (,, uint32 r10, uint32 c10,,,) = market.sessions(day1, T1); // recorded rates, passed to the provers
        (,, uint32 r50, uint32 c50,,,) = market.sessions(day1, T2);

        vm.warp((day1 + 1) * DAY + 1);
        (
            bytes memory proof1,
            bytes32[] memory hashes1,
            bytes32[] memory commits1,
            uint256 out1,
            uint256 in1
        ) = _ffiDay(1, r10, c10, r50, c50);
        assertEq(out1, uint256(r10) * 100); // alice's sale
        assertEq(in1, uint256(c10) * 100 + uint256(c50) * 200); // bob's purchases

        vm.prank(operator);
        market.postNetputHashes(day1, hashes1);

        uint32[96] memory pS; // the batch holds both members, so its partial sums are the session totals
        uint32[96] memory pD;
        pS[T1] = 100;
        pD[T1] = 100;
        pD[T2] = 200;

        // a claimed total off by one unit makes the real verifier reject the proof
        vm.expectRevert(abi.encodeWithSignature("SumcheckFailed()"));
        market.submitChunk(
            day1, 0, MarketV4.ChunkSubmission(commits1, _zeros(), pS, pD, out1, in1 + 1), proof1
        );

        market.submitChunk(
            day1, 0, MarketV4.ChunkSubmission(commits1, _zeros(), pS, pD, out1, in1), proof1
        );

        vm.prank(alice);
        market.requestData(day1);
        vm.prank(operator);
        market.postEncryptedData(day1, 1, hex"aabb"); // stage 1 blob is not checked on-chain
        vm.prank(alice);
        market.requestClearReveal(day1);

        (bytes memory revealProof, uint256 aliceBal) = _ffiReveal(1, r10, c10, r50, c50);
        assertEq(aliceBal, 50e12 + uint256(r10) * 100); // deposit plus day 1 sale
        market.clearReveal(day1, 1, uint64(aliceBal), revealProof); // verified against the staged commitment

        uint256 gridBefore = eeur.balanceOf(grid);
        vm.warp((day1 + 1) * DAY + market.PROOF_WINDOW() + 1);
        market.finalizeDay(day1);

        assertEq(market.balCommitOf(1), commits1[0]);
        assertEq(market.balCommitOf(2), commits1[1]);

        (,,,,, uint32 lambdaHi50,) = market.sessions(day1, T2);
        assertEq(eeur.balanceOf(grid), gridBefore + uint256(lambdaHi50) * 200 * UNIT); // bob's T2 shortfall at retail
    }

    // The padding and zero-balance constants given to the contract are the prover's, so padding lanes verify.
    function test_FFI_ConstantsMatchProver() public {
        (bytes32 emptyHash, bytes32 zeroCommit,,) = _ffiConstants();
        assertEq(market.EMPTY_NETPUT_HASH(), emptyHash);
        assertEq(market.ZERO_BAL_COMMIT(), zeroCommit);
    }
    
    // Padding hash, zero-balance commitment and the two floor commitments, from the prover.
    function _ffiConstants() internal returns (bytes32, bytes32, bytes32, bytes32) {
        string[] memory cmd = new string[](4);
        cmd[0] = "npx";
        cmd[1] = "tsx";
        cmd[2] = "js_scripts/generateProof_daychunk.ts";
        cmd[3] = "constants";
        return abi.decode(vm.ffi(cmd), (bytes32, bytes32, bytes32, bytes32));
    }

    // Real day_chunk proof of day 0 or 1, with its position commitments, new balances and totals.
    function _ffiDay(uint256 day, uint32 r10, uint32 c10, uint32 r50, uint32 c50)
        internal
        returns (bytes memory, bytes32[] memory, bytes32[] memory, uint256, uint256)
    {
        string[] memory cmd = new string[](day == 0 ? 4 : 8);
        cmd[0] = "npx";
        cmd[1] = "tsx";
        cmd[2] = "js_scripts/generateProof_daychunk.ts";
        cmd[3] = vm.toString(day);
        if (day == 1) { // day 1 needs the recorded rates of T1 and T2
            cmd[4] = vm.toString(uint256(r10));
            cmd[5] = vm.toString(uint256(c10));
            cmd[6] = vm.toString(uint256(r50));
            cmd[7] = vm.toString(uint256(c50));
        }
        return abi.decode(vm.ffi(cmd), (bytes, bytes32[], bytes32[], uint256, uint256));
    }

    // Real reveal proof that a member's day 1 balance opens its commitment, with that balance.
    function _ffiReveal(uint256 slot, uint32 r10, uint32 c10, uint32 r50, uint32 c50)
        internal
        returns (bytes memory, uint256)
    {
        string[] memory cmd = new string[](8);
        cmd[0] = "npx";
        cmd[1] = "tsx";
        cmd[2] = "js_scripts/generateProof_reveal.ts";
        cmd[3] = vm.toString(slot);
        cmd[4] = vm.toString(uint256(r10));
        cmd[5] = vm.toString(uint256(c10));
        cmd[6] = vm.toString(uint256(r50));
        cmd[7] = vm.toString(uint256(c50));
        return abi.decode(vm.ffi(cmd), (bytes, uint256));
    }

    // No withdrawal in any lane.
    function _zeros() internal pure returns (uint256[] memory z) {
        z = new uint256[](BATCH);
    }

    // All-zero partial sums, for day 0 which has no session.
    function _emptyS() internal pure returns (uint32[96] memory s) {}
}
