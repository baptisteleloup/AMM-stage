// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {MarketV4} from "../src/MarketV4.sol";
import {GridTariff} from "../src/GridTariff.sol";
import {EnergyEuro} from "../src/EnergyEuro.sol";
import {IHonkVerifier} from "../src/interfaces/IVerifier.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";


contract MockHonkVerifier is IHonkVerifier {
    bool public result = true;

    function set(bool r) external {
        result = r;
    }

    function verify(bytes calldata, bytes32[] calldata) external view returns (bool) {
        return result;
    }
}

contract MarketV4Test is Test {
    uint256 constant DAY = 86400;
    uint256 constant SLOT = 900;
    uint256 constant SESSIONS = 96;
    uint256 constant BATCH = 8;
    uint256 constant UNIT = 1e6; 

    MarketV4 market;
    GridTariff tariff;
    EnergyEuro eeur;
    MockHonkVerifier dayVerifier;
    MockHonkVerifier revealVerifier;

    address operator = makeAddr("operator");
    address grid = makeAddr("grid");
    address floorAdmin = makeAddr("floorAdmin");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address reserve = makeAddr("reserve");

    bytes32 constant EMPTY_NETPUT_HASH = keccak256("EMPTY_NETPUT_HASH_PLACEHOLDER");
    bytes32 constant ZERO_BAL_COMMIT = keccak256("ZERO_BAL_COMMIT_PLACEHOLDER");

    uint256 dayId; 

    function _schedule() internal view virtual returns (GridTariff.Schedule memory) {
        return GridTariff.Schedule({
            feedIn: ud(8.86e18),
            retailOffPeak: ud(16.96e18),
            retailPeak: ud(21.46e18),
            winStart: new uint32[](0),
            winEnd: new uint32[](0)
        });
    }

    function _expectedDustIsZero() internal view virtual returns (bool) {
        return true;
    }

    function setUp() public {
        vm.warp(20_000 * DAY);
        dayId = block.timestamp / DAY;

        eeur = new EnergyEuro(); 
        dayVerifier = new MockHonkVerifier();
        revealVerifier = new MockHonkVerifier();

        GridTariff.Schedule memory sched = _schedule();

        tariff = new GridTariff(GridTariff.Mode.Schedule, admin, sched, new address[](0), 0);

        market = new MarketV4(
            IERC20(address(eeur)),
            dayVerifier,
            revealVerifier,
            tariff,
            operator,
            grid,
            floorAdmin,
            reserve,
            EMPTY_NETPUT_HASH,
            ZERO_BAL_COMMIT
        );

        vm.prank(alice);
        market.register(bytes.concat(hex"02", bytes32("alice_pk")));
        vm.prank(bob);
        market.register(bytes.concat(hex"02", bytes32("bob_pk")));
        deal(address(eeur), alice, 100 ether);
        deal(address(eeur), bob, 100 ether);
        deal(address(eeur), grid, 1000 ether);

        vm.prank(alice);
        eeur.approve(address(market), type(uint256).max);
        vm.prank(bob);
        eeur.approve(address(market), type(uint256).max);
        vm.prank(grid);
        eeur.approve(address(market), type(uint256).max);

        _coSetFloor(1, bytes32("floor_commit_1"));
        _coSetFloor(2, bytes32("floor_commit_2"));

        vm.prank(alice);
        market.deposit(1 ether); 
        vm.prank(bob);
        market.deposit(1 ether);
    }

    function _openSession(uint256 t, uint32 s, uint32 d) internal {
        vm.warp(dayId * DAY + t * SLOT + 1);
        vm.prank(operator);
        market.openSession(dayId, t, s, d);
    }

    function _honestDay()
        internal
        returns (bytes32[] memory newCommits, uint32[96] memory pS, uint32[96] memory pD, uint256 pOut, uint256 pIn)
    {
        _openSession(10, 100, 100);
        _openSession(50, 0, 200);

        (,, uint32 r10, uint32 c10,,,) = market.sessions(dayId, 10);
        (,,, uint32 c50,,,) = market.sessions(dayId, 50);

        pS[10] = 100;
        pD[10] = 100;
        pD[50] = 200;
        pOut = uint256(r10) * 100;
        pIn = uint256(c10) * 100 + uint256(c50) * 200;

        newCommits = new bytes32[](BATCH);
        newCommits[0] = keccak256("alice_new_commit");
        newCommits[1] = keccak256("bob_new_commit");
        for (uint256 i = 2; i < BATCH; i++) {
            newCommits[i] = ZERO_BAL_COMMIT;
        }

        vm.warp((dayId + 1) * DAY + 1);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("alice_netputs");
        hashes[1] = keccak256("bob_netputs");
        vm.prank(operator);
        market.postNetputHashes(dayId, hashes);
    }

    function _noWithdrawals() internal pure returns (uint256[] memory w) {
        w = new uint256[](BATCH);
    }

    function _submitHonestChunk() internal returns (uint256 pOut, uint256 pIn) {
        (bytes32[] memory nc, uint32[96] memory pS, uint32[96] memory pD, uint256 o, uint256 i) = _honestDay();
        market.submitChunk(
            dayId, 0, MarketV4.ChunkSubmission(nc, _noWithdrawals(), pS, pD, o, i), "proof"
        );
        return (o, i);
    }

    function _warpPastDeadline() internal {
        (,,,, uint256 deadline,) = market.dayCloses(dayId);
        if (block.timestamp <= deadline) {
            vm.warp(deadline + 1);
        }
    }

    function _coSetFloor(uint256 slot, bytes32 commit_) internal {
        vm.prank(operator);
        market.proposeFloor(slot, commit_);
        vm.prank(floorAdmin);
        market.confirmFloor(slot, commit_);
    }

    function test_FullHonestDay_Finalizes() public {
        _submitHonestChunk();
        _warpPastDeadline();
        market.finalizeDay(dayId);

        (MarketV4.DayState st,, uint256 accOut, uint256 accIn,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Finalized));
        assertGt(accIn, accOut); 
        assertGt(eeur.balanceOf(grid), 1000 ether);
        assertEq(market.balCommitOf(1), keccak256("alice_new_commit"));
        assertEq(market.balCommitOf(2), keccak256("bob_new_commit"));
        assertEq(market.pendingDeposit(1), 0); 
        assertEq(market.dustPot(), (accIn - accOut) - (eeur.balanceOf(grid) - 1000 ether) / UNIT);
    }

    function test_OpenSession_WrongClock_Reverts() public {
        vm.warp(dayId * DAY + 10 * SLOT + 1);
        vm.prank(operator);
        vm.expectRevert(bytes("clock"));
        market.openSession(dayId, 11, 1, 1); 
    }

    function test_SubmitChunk_InvalidProof_Reverts() public {
        (bytes32[] memory nc, uint32[96] memory pS, uint32[96] memory pD, uint256 o, uint256 i) = _honestDay();
        dayVerifier.set(false);
        vm.expectRevert(bytes("invalid proof"));
        market.submitChunk(
            dayId, 0, MarketV4.ChunkSubmission(nc, _noWithdrawals(), pS, pD, o, i), "proof"
        );
    }


    function test_Attack_InflatedS_CannotFinalize() public {
        _openSession(10, 100, 100);
        _openSession(50, 500, 200); 
        uint32[96] memory pS;
        uint32[96] memory pD;
        pS[10] = 100; 
        pD[10] = 100;
        pD[50] = 200;
        (,, uint32 r10, uint32 c10,,,) = market.sessions(dayId, 10);
        (,,, uint32 c50,,,) = market.sessions(dayId, 50);
        uint256 pOut = uint256(r10) * 100;
        uint256 pIn = uint256(c10) * 100 + uint256(c50) * 200;

        vm.warp((dayId + 1) * DAY + 1);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("a");
        hashes[1] = keccak256("b");
        vm.prank(operator);
        market.postNetputHashes(dayId, hashes);

        bytes32[] memory nc = new bytes32[](BATCH);
        for (uint256 i = 0; i < BATCH; i++) {
            nc[i] = ZERO_BAL_COMMIT;
        }
        market.submitChunk(
            dayId, 0, MarketV4.ChunkSubmission(nc, _noWithdrawals(), pS, pD, pOut, pIn), "proof"
        );

        _warpPastDeadline();
        vm.expectRevert(bytes("s/d mismatch"));
        market.finalizeDay(dayId); 
    }

    function test_Conservation_Mismatch_Reverts() public {
        (bytes32[] memory nc, uint32[96] memory pS, uint32[96] memory pD, uint256 o, uint256 i) = _honestDay();
        market.submitChunk(
            dayId, 0, MarketV4.ChunkSubmission(nc, _noWithdrawals(), pS, pD, o + 1, i), "proof"
        );
        _warpPastDeadline();
        vm.expectRevert(bytes("conservation out"));
        market.finalizeDay(dayId);
    }


    function test_Cancel_MissingProofs_AfterDeadline() public {
        _honestDay(); 
        _warpPastDeadline();
        market.cancelDay(dayId, 0, "no proof");
        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Cancelled));
    }

    function test_Reveal_Pending_BlocksFinalize_ThenOperatorAnswers() public {
        _submitHonestChunk();
        vm.prank(alice);
        market.requestData(dayId);

        _warpPastDeadline();
        vm.expectRevert(bytes("reveal pending"));
        market.finalizeDay(dayId);

        vm.prank(operator);
        market.postEncryptedData(dayId, 1, hex"deadbeef");
        market.finalizeDay(dayId); 
    }

    function test_Reveal_Timeout_AllowsCancel() public {
        _submitHonestChunk();
        vm.prank(alice);
        market.requestData(dayId);
        vm.warp(block.timestamp + market.REVEAL_WINDOW() + 1);
        _warpPastDeadline();
        vm.prank(alice);
        market.cancelDay(dayId, 1, "operator withheld data"); 
        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Cancelled));
    }

    function test_ClearReveal_VerifiesAgainstStagedCommit() public {
        _submitHonestChunk();
        vm.prank(alice);
        market.requestData(dayId);
        vm.prank(operator);
        market.postEncryptedData(dayId, 1, hex"deadbeef");
        vm.prank(alice);
        market.requestClearReveal(dayId);
        market.clearReveal(dayId, 1, 123_456, "proof"); 
        _warpPastDeadline();
        market.finalizeDay(dayId);
    }

    function test_Dispute_BlocksFinalize() public {
        _submitHonestChunk();
        vm.prank(alice);
        market.disputeDay(dayId);
        _warpPastDeadline();
        vm.expectRevert(bytes("disputed"));
        market.finalizeDay(dayId);
        market.cancelDay(dayId, 0, "disputed");
    }

    function test_Withdrawal_PaidAtFinalize() public {
        vm.prank(alice);
        market.requestWithdraw(100_000 * UNIT);
        uint256 before = eeur.balanceOf(alice);

        (bytes32[] memory nc, uint32[96] memory pS, uint32[96] memory pD, uint256 o, uint256 i) = _honestDay();
        uint256[] memory paid = _noWithdrawals();
        paid[0] = 100_000; 
        market.submitChunk(dayId, 0, MarketV4.ChunkSubmission(nc, paid, pS, pD, o, i), "proof");
        _warpPastDeadline();
        market.finalizeDay(dayId);
        assertEq(eeur.balanceOf(alice), before + 100_000 * UNIT);
        assertEq(market.pendingWithdrawal(1), 0);
    }

    function test_Deposit_RejectsSubPeurDust() public {
        vm.prank(alice);
        vm.expectRevert(bytes("amount not a whole pEUR"));
        market.deposit(1); 
    }

    function test_DepositAfterFreeze_StaysQueued() public {
        _submitHonestChunk(); 
        assertEq(market.snapDeposit(dayId, 1), 1 ether / UNIT);

        vm.prank(alice);
        market.deposit(0.5 ether); 
        assertEq(market.pendingDeposit(1), 1.5 ether / UNIT);

        _warpPastDeadline();
        market.finalizeDay(dayId);

        assertEq(market.pendingDeposit(1), 0.5 ether / UNIT);
    }

    function test_WithdrawAfterFreeze_NotPaidToday_StaysQueued() public {
        _submitHonestChunk();
        assertEq(market.snapWithdrawal(dayId, 1), 0);

        vm.prank(alice);
        market.requestWithdraw(0.1 ether);
        uint256 before = eeur.balanceOf(alice);

        _warpPastDeadline();
        market.finalizeDay(dayId);

        assertEq(eeur.balanceOf(alice), before); 
        assertEq(market.pendingWithdrawal(1), 0.1 ether / UNIT); 
    }

    function test_CancelledDay_ConsumesNothing() public {
        _honestDay(); 
        assertEq(market.snapDeposit(dayId, 1), 1 ether / UNIT);
        _warpPastDeadline();
        market.cancelDay(dayId, 0, "no proof");
        assertEq(market.pendingDeposit(1), 1 ether / UNIT);
    }

    function test_RegisterMidClose_DoesNotChangeChunkCount() public {
        _honestDay();
        uint256 k0 = market.chunkCountFor(dayId);
        for (uint256 i = 0; i < 20; i++) {
            address late = makeAddr(string(abi.encodePacked("late", i)));
            vm.prank(late);
            market.register(bytes.concat(hex"02", bytes32("late_pk")));
        }
        assertGt(market.chunkCount(), k0); 
        assertEq(market.chunkCountFor(dayId), k0); 
    }

    function test_Dust_MatchesExpectation() public {
        _submitHonestChunk();
        _warpPastDeadline();
        market.finalizeDay(dayId);

        if (_expectedDustIsZero()) {
            assertEq(market.dustPot(), 0);
        } else {
            assertGt(market.dustPot(), 0);
        }
    }

    function test_SweepDust_PermissionlessToFixedReserve() public {
        _submitHonestChunk();
        _warpPastDeadline();
        market.finalizeDay(dayId);
        uint256 pot = market.dustPot();

        address anyone = makeAddr("passer_by");
        if (pot == 0) {
            vm.prank(anyone);
            vm.expectRevert(bytes("no dust"));
            market.sweepDust();
            return;
        }

        vm.prank(anyone);
        market.sweepDust();

        assertEq(market.dustPot(), 0);
        assertEq(eeur.balanceOf(reserve), pot * UNIT); 
    }

    function test_SweepDust_NothingToSweep_Reverts() public {
        vm.expectRevert(bytes("no dust"));
        market.sweepDust();
    }

    function test_ProposeFloor_OnlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not operator"));
        market.proposeFloor(1, bytes32("x"));
    }

    function test_CoSignature_HappyPath() public {
        vm.prank(operator);
        market.proposeFloor(1, bytes32("newfloor"));
        assertEq(market.floorCommitOf(1), bytes32("floor_commit_1")); 
        vm.prank(floorAdmin);
        market.confirmFloor(1, bytes32("newfloor"));
        assertEq(market.floorCommitOf(1), bytes32("newfloor")); 
        assertEq(market.pendingFloorCommit(1), bytes32(0)); 
    }

    function test_CoSignature_OperatorAloneCannotConfirm() public {
        vm.prank(operator);
        market.proposeFloor(1, bytes32("evil"));
        vm.prank(operator); 
        vm.expectRevert(bytes("not floor admin"));
        market.confirmFloor(1, bytes32("evil"));
        assertEq(market.floorCommitOf(1), bytes32("floor_commit_1")); 
    }

    function test_CoSignature_AdminCannotConfirmUnproposed() public {
        vm.prank(floorAdmin);
        vm.expectRevert(bytes("no matching proposal"));
        market.confirmFloor(1, bytes32("fabricated"));
    }

    function test_CoSignature_ConfirmMustMatchProposal() public {
        vm.prank(operator);
        market.proposeFloor(1, bytes32("A"));
        vm.prank(floorAdmin);
        vm.expectRevert(bytes("no matching proposal"));
        market.confirmFloor(1, bytes32("B")); 
    }

    function test_OpenRevealCount_TracksBothStages() public {
        _submitHonestChunk();
        assertEq(market.openRevealCount(dayId), 0);

        vm.prank(alice);
        market.requestData(dayId);
        assertEq(market.openRevealCount(dayId), 1);

        vm.prank(bob);
        market.requestData(dayId);
        assertEq(market.openRevealCount(dayId), 2);

        vm.prank(operator);
        market.postEncryptedData(dayId, 1, hex"aa");
        vm.prank(operator);
        market.postEncryptedData(dayId, 2, hex"bb");
        assertEq(market.openRevealCount(dayId), 0);

        vm.prank(alice);
        market.requestClearReveal(dayId); 
        assertEq(market.openRevealCount(dayId), 1);

        market.clearReveal(dayId, 1, 1, "proof");
        assertEq(market.openRevealCount(dayId), 0);

        _warpPastDeadline();
        market.finalizeDay(dayId); 
    }

    function test_Cancel_WrongSlot_NoGround() public {
        _submitHonestChunk();
        vm.prank(alice);
        market.requestData(dayId);
        vm.prank(operator);
        market.postEncryptedData(dayId, 1, hex"aa"); 

        vm.warp(block.timestamp + market.REVEAL_WINDOW() + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("no ground"));
        market.cancelDay(dayId, 1, "bogus claim");
    }

    function test_OpenSession_NotOperator_Reverts() public {
        vm.warp(dayId * DAY + 10 * SLOT + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("not operator"));
        market.openSession(dayId, 10, 100, 100);
    }

    function test_FinalizeDay_IsPermissionless() public {
        _submitHonestChunk();
        _warpPastDeadline();
        address randomKeeper = makeAddr("keeper_org_3");
        vm.prank(randomKeeper);
        market.finalizeDay(dayId); 
        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Finalized));
    }

    function test_GreedyWithdrawal_IsClamped_DayStillCloses() public {
        vm.prank(alice);
        market.requestWithdraw(50 ether); 
        assertEq(market.pendingWithdrawal(1), 50 ether / UNIT);

        (bytes32[] memory nc, uint32[96] memory pS, uint32[96] memory pD, uint256 o, uint256 i) = _honestDay();
        uint256[] memory paid = _noWithdrawals();
        paid[0] = 0.5 ether / UNIT; 
        uint256 before = eeur.balanceOf(alice);
        market.submitChunk(dayId, 0, MarketV4.ChunkSubmission(nc, paid, pS, pD, o, i), "proof");

        _warpPastDeadline();
        market.finalizeDay(dayId); 

        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Finalized));
        assertEq(eeur.balanceOf(alice), before + 0.5 ether); 
        assertEq(market.pendingWithdrawal(1), 49.5 ether / UNIT); 
    }
}

contract MarketV4PathologicalTariffTest is MarketV4Test {
    function _schedule() internal view override returns (GridTariff.Schedule memory) {
        return GridTariff.Schedule({
            feedIn: ud(8.86e18 + 1),
            retailOffPeak: ud(16.96e18 + 1),
            retailPeak: ud(21.46e18 + 1),
            winStart: new uint32[](0),
            winEnd: new uint32[](0)
        });
    }

    function _expectedDustIsZero() internal view override returns (bool) {
        return false;
    }
}
