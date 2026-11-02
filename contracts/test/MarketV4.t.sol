// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Mock suite of MarketV4: sessions, midnight freeze, batch submission, settlement, recourse,
// cancellation, deposits and withdrawals, floors, dust and escape hatch. Proofs are replaced by
// MockHonkVerifier. Reruns under the three pricing rules and an off-grain tariff.
// Run from contracts/: forge test --match-path test/MarketV4.t.sol

import {Test} from "forge-std/Test.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {MarketV4} from "../src/MarketV4.sol";
import {GridTariff} from "../src/GridTariff.sol";
import {Pricing, PricingLib} from "../src/Pricing.sol";
import {EnergyEuro} from "../src/EnergyEuro.sol";
import {IHonkVerifier} from "../src/interfaces/IVerifier.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";


// Stand-in for the generated verifiers: returns whatever the test sets, true by default.
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
    uint256 constant SLOT = 900; // session length, s
    uint256 constant SESSIONS = 96;
    uint256 constant BATCH = 8; // members per batch proof
    uint256 constant UNIT = 1e6; // token wei per internal unit (MarketV4.WEI_PER_UNIT)

    MarketV4 market;
    GridTariff tariff;
    Pricing pricing;

    // Pricing rule the community runs under. Subclasses rerun the whole suite under the
    // other rules, since every test derives its expected amounts from the recorded prices.
    function _rule() internal pure virtual returns (PricingLib.Rule) {
        return PricingLib.Rule.MidMarket;
    }
    EnergyEuro eeur;
    MockHonkVerifier dayVerifier; // stands for the day_chunk verifier
    MockHonkVerifier revealVerifier; // stands for the reveal verifier

    address operator = makeAddr("operator");
    address grid = makeAddr("grid");
    address floorAdmin = makeAddr("floorAdmin");
    address admin = makeAddr("admin"); // tariff admin
    address alice = makeAddr("alice"); // slot 1
    address bob = makeAddr("bob"); // slot 2
    address reserve = makeAddr("reserve"); // receives swept dust

    // Arbitrary constants: the mock verifier never checks them against the circuit's hashes.
    bytes32 constant EMPTY_NETPUT_HASH = keccak256("EMPTY_NETPUT_HASH_PLACEHOLDER");
    bytes32 constant ZERO_BAL_COMMIT = keccak256("ZERO_BAL_COMMIT_PLACEHOLDER");

    uint256 dayId; // the day under test, also the deployment day

    // Flat tariff band (no peak windows), cents per kWh. Overridden by the off-grain subclass.
    function _schedule() internal view virtual returns (GridTariff.Schedule memory) {
        return GridTariff.Schedule({
            feedIn: ud(8.86e18),
            retailOffPeak: ud(16.96e18),
            retailPeak: ud(21.46e18),
            winStart: new uint32[](0),
            winEnd: new uint32[](0)
        });
    }

    // Whether settling the honest day leaves no rounding residual under this rule and band.
    function _expectedDustIsZero() internal view virtual returns (bool) {
        return true;
    }

    // Deploys the market, registers alice and bob, funds everyone, sets floors and queues a 1 EEUR deposit each.
    function setUp() public {
        vm.warp(20_000 * DAY);
        dayId = block.timestamp / DAY;

        eeur = new EnergyEuro(); // owned by the test contract
        dayVerifier = new MockHonkVerifier();
        revealVerifier = new MockHonkVerifier();

        GridTariff.Schedule memory sched = _schedule();

        tariff = new GridTariff(GridTariff.Mode.Schedule, admin, sched, new address[](0), 0);

        pricing = new Pricing(_rule());
        market = new MarketV4(
            IERC20(address(eeur)),
            dayVerifier,
            revealVerifier,
            tariff,
            pricing,
            operator,
            grid,
            floorAdmin,
            reserve,
            EMPTY_NETPUT_HASH,
            ZERO_BAL_COMMIT
        );

        vm.prank(alice);
        market.register(bytes.concat(hex"02", bytes32("alice_pk"))); // 33-byte compressed key format
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
        eeur.approve(address(market), type(uint256).max); // the market pulls the grid's payment for exports

        _coSetFloor(1, bytes32("floor_commit_1"));
        _coSetFloor(2, bytes32("floor_commit_2"));

        vm.prank(alice);
        market.deposit(1 ether); // queued, applied by the first settled day
        vm.prank(bob);
        market.deposit(1 ether);
    }

    // Warps into session t of dayId and has the operator post its aggregates.
    function _openSession(uint256 t, uint32 s, uint32 d) internal {
        vm.warp(dayId * DAY + t * SLOT + 1);
        vm.prank(operator);
        market.openSession(dayId, t, s, d);
    }

    // Trades a day (alice sells 100 Wh to bob in session 10, bob buys 200 Wh alone in session 50),
    // freezes it at midnight and returns the batch outputs an honest prover would claim.
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
        pOut = uint256(r10) * 100; // alice's sale at the recorded seller rate
        pIn = uint256(c10) * 100 + uint256(c50) * 200; // bob's purchases at the recorded buyer rates

        newCommits = new bytes32[](BATCH);
        newCommits[0] = keccak256("alice_new_commit");
        newCommits[1] = keccak256("bob_new_commit");
        for (uint256 i = 2; i < BATCH; i++) {
            newCommits[i] = ZERO_BAL_COMMIT; // padding lanes
        }

        vm.warp((dayId + 1) * DAY + 1); // just after midnight
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("alice_netputs");
        hashes[1] = keccak256("bob_netputs");
        vm.prank(operator);
        market.postNetputHashes(dayId, hashes); // midnight freeze
    }

    function _noWithdrawals() internal pure returns (uint256[] memory w) {
        w = new uint256[](BATCH);
    }

    // Trades and freezes the honest day, then submits its single batch.
    function _submitHonestChunk() internal returns (uint256 pOut, uint256 pIn) {
        (bytes32[] memory nc, uint32[96] memory pS, uint32[96] memory pD, uint256 o, uint256 i) = _honestDay();
        market.submitChunk(
            dayId, 0, MarketV4.ChunkSubmission(nc, _noWithdrawals(), pS, pD, o, i), "proof"
        );
        return (o, i);
    }

    // Moves past the end of the proof and recourse window of dayId.
    function _warpPastDeadline() internal {
        (,,,, uint256 deadline,) = market.dayCloses(dayId);
        if (block.timestamp <= deadline) {
            vm.warp(deadline + 1);
        }
    }

    // Sets a floor with both signatures: operator proposes, floor admin confirms.
    function _coSetFloor(uint256 slot, bytes32 commit_) internal {
        vm.prank(operator);
        market.proposeFloor(slot, commit_);
        vm.prank(floorAdmin);
        market.confirmFloor(slot, commit_);
    }

    // An honest day settles: new balances in force, deposits applied, grid paid, residual in the dust pot.
    function test_FullHonestDay_Finalizes() public {
        _submitHonestChunk();
        _warpPastDeadline();
        market.finalizeDay(dayId);

        (MarketV4.DayState st,, uint256 accOut, uint256 accIn,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Finalized));
        assertGt(accIn, accOut); // net import day: buyers pay more than sellers receive
        assertGt(eeur.balanceOf(grid), 1000 ether);
        assertEq(market.balCommitOf(1), keccak256("alice_new_commit"));
        assertEq(market.balCommitOf(2), keccak256("bob_new_commit"));
        assertEq(market.pendingDeposit(1), 0); // the queued deposit was applied
        assertEq(market.dustPot(), (accIn - accOut) - (eeur.balanceOf(grid) - 1000 ether) / UNIT);
    }

    // The operator can only open the session in progress, never a past or future one.
    function test_OpenSession_WrongClock_Reverts() public {
        vm.warp(dayId * DAY + 10 * SLOT + 1);
        vm.prank(operator);
        vm.expectRevert(bytes("clock"));
        market.openSession(dayId, 11, 1, 1); // clock is in session 10
    }

    // A batch whose proof does not verify is rejected.
    function test_SubmitChunk_InvalidProof_Reverts() public {
        (bytes32[] memory nc, uint32[96] memory pS, uint32[96] memory pD, uint256 o, uint256 i) = _honestDay();
        dayVerifier.set(false);
        vm.expectRevert(bytes("invalid proof"));
        market.submitChunk(
            dayId, 0, MarketV4.ChunkSubmission(nc, _noWithdrawals(), pS, pD, o, i), "proof"
        );
    }


    // An operator who posts a supply the members did not offer cannot settle: proven partial sums must match.
    function test_Attack_InflatedS_CannotFinalize() public {
        _openSession(10, 100, 100);
        _openSession(50, 500, 200); // posted s = 500, but no member offered anything
        uint32[96] memory pS;
        uint32[96] memory pD;
        pS[10] = 100; // the proofs only account for what members really offered
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
        market.finalizeDay(dayId); // session 50: proven s = 0, posted s = 500
    }

    // Proven payout totals must equal what the recorded rates imply.
    function test_Conservation_Mismatch_Reverts() public {
        (bytes32[] memory nc, uint32[96] memory pS, uint32[96] memory pD, uint256 o, uint256 i) = _honestDay();
        market.submitChunk(
            dayId, 0, MarketV4.ChunkSubmission(nc, _noWithdrawals(), pS, pD, o + 1, i), "proof"
        );
        _warpPastDeadline();
        vm.expectRevert(bytes("conservation out"));
        market.finalizeDay(dayId);
    }


    // Batches still missing at the deadline let anyone cancel the day.
    function test_Cancel_MissingProofs_AfterDeadline() public {
        _honestDay(); // frozen, no batch submitted
        _warpPastDeadline();
        market.cancelDay(dayId, 0, "no proof");
        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Cancelled));
    }

    // An open recourse request blocks settlement until the operator answers it.
    function test_Reveal_Pending_BlocksFinalize_ThenOperatorAnswers() public {
        _submitHonestChunk();
        vm.prank(alice);
        market.requestData(dayId);

        _warpPastDeadline();
        vm.expectRevert(bytes("reveal pending"));
        market.finalizeDay(dayId);

        vm.prank(operator);
        market.postEncryptedData(dayId, 1, hex"deadbeef");
        market.finalizeDay(dayId); // request answered, settlement goes through
    }

    // An unanswered request past its window is a ground to cancel the day.
    function test_Reveal_Timeout_AllowsCancel() public {
        _submitHonestChunk();
        vm.prank(alice);
        market.requestData(dayId);
        vm.warp(block.timestamp + market.REVEAL_WINDOW() + 1);
        _warpPastDeadline();
        vm.prank(alice);
        market.cancelDay(dayId, 1, "operator withheld data"); // ground: slot 1's request timed out
        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Cancelled));
    }

    // Both recourse stages answered: the clear reveal closes the request and the day settles.
    function test_ClearReveal_VerifiesAgainstStagedCommit() public {
        _submitHonestChunk();
        vm.prank(alice);
        market.requestData(dayId);
        vm.prank(operator);
        market.postEncryptedData(dayId, 1, hex"deadbeef");
        vm.prank(alice);
        market.requestClearReveal(dayId);
        market.clearReveal(dayId, 1, 123_456, "proof"); // checked against alice's staged commitment
        _warpPastDeadline();
        market.finalizeDay(dayId);
    }

    // A frozen and proven day with a surplus, so settlement must pull the grid's payment.
    function _dayWhereGridOwes() internal returns (uint256 pOut, uint256 pIn) {
        _openSession(10, 200, 100); // more sold than bought: the grid buys the surplus

        (,, uint32 r10, uint32 c10,,,) = market.sessions(dayId, 10);
        uint32[96] memory pS;
        uint32[96] memory pD;
        pS[10] = 200;
        pD[10] = 100;
        pOut = uint256(r10) * 200;
        pIn = uint256(c10) * 100;

        bytes32[] memory nc = new bytes32[](BATCH);
        nc[0] = keccak256("alice_new_commit");
        nc[1] = keccak256("bob_new_commit");
        for (uint256 i = 2; i < BATCH; i++) nc[i] = ZERO_BAL_COMMIT;

        vm.warp((dayId + 1) * DAY + 1);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("alice_netputs");
        hashes[1] = keccak256("bob_netputs");
        vm.prank(operator);
        market.postNetputHashes(dayId, hashes);

        market.submitChunk(dayId, 0, MarketV4.ChunkSubmission(nc, _noWithdrawals(), pS, pD, pOut, pIn), "proof");
    }

    // A grid that does not pay blocks settlement, but the day cannot be cancelled before the grace period.
    function test_Stuck_GridShortfall_CannotCancelBeforeGrace() public {
        _dayWhereGridOwes();
        vm.prank(grid);
        eeur.approve(address(market), 0); // the grid stops paying
        _warpPastDeadline();

        vm.expectRevert(); // the token reverts first, with its own error
        market.finalizeDay(dayId);

        // proofs are complete, so the ordinary timeout ground does not apply yet
        vm.expectRevert(bytes("no ground"));
        market.cancelDay(dayId, 0, "stuck");
    }

    // After the grace period a stuck day can be cancelled, and nothing it would have consumed is lost.
    function test_Stuck_GridShortfall_CancelAfterGrace() public {
        _dayWhereGridOwes();
        vm.prank(grid);
        eeur.approve(address(market), 0);
        (,,,, uint256 deadline,) = market.dayCloses(dayId);
        vm.warp(deadline + market.SETTLEMENT_GRACE() + 1);

        vm.expectRevert(); // the token reverts first, with its own error
        market.finalizeDay(dayId);

        market.cancelDay(dayId, 0, "settlement impossible");
        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Cancelled));
        // nothing was consumed: the deposit is still queued for a later day
        assertEq(market.pendingDeposit(1), 1 ether / UNIT);
    }

    // A failed settlement can be retried: once the grid pays again within the grace period, the day settles.
    function test_Stuck_GridShortfall_RecoversIfFundedInTime() public {
        _dayWhereGridOwes();
        vm.prank(grid);
        eeur.approve(address(market), 0);
        _warpPastDeadline();
        vm.expectRevert(); // the token reverts first, with its own error
        market.finalizeDay(dayId);

        // the grid fixes its approval before the grace runs out
        vm.prank(grid);
        eeur.approve(address(market), type(uint256).max);
        market.finalizeDay(dayId);
        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Finalized));
    }

    // Timing constants keep every outcome (settlement, grace cancel, both recourse stages) within the next day.
    function test_GraceKeepsSettlementWithinTheDay() public view {
        assertLt(market.PROOF_WINDOW() + market.SETTLEMENT_GRACE(), 1 days);
        assertLt(market.PROOF_WINDOW() + 2 * market.REVEAL_WINDOW(), 1 days);
    }

    // Stage 1 recourse closes with the proof window.
    function test_Request_AfterDeadline_Reverts() public {
        _submitHonestChunk();
        _warpPastDeadline();
        vm.prank(alice);
        vm.expectRevert(bytes("objection window closed"));
        market.requestData(dayId);
    }

    // Recourse is only possible on a day that is closing.
    function test_Request_OnFutureDay_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("state"));
        market.requestData(dayId + 3);
    }

    // Stage 2 stays open one reveal window past the deadline, so an answered stage 1 can still be escalated.
    function test_ClearRequest_ShortlyAfterDeadline_StillAllowed() public {
        _submitHonestChunk();
        vm.prank(alice);
        market.requestData(dayId);
        vm.prank(operator);
        market.postEncryptedData(dayId, 1, hex"aa");
        _warpPastDeadline(); // stage 1 was answered; the prosumer may still escalate
        vm.prank(alice);
        market.requestClearReveal(dayId);
        assertEq(market.openRevealCount(dayId), 1);
    }

    // The "stuck" ground needs no open request; with one open, only its own timeout is a ground.
    function test_Stuck_NotWhileARevealIsOpen() public {
        _dayWhereGridOwes();
        vm.prank(alice);
        market.requestData(dayId);
        (,,,, uint256 deadline,) = market.dayCloses(dayId);
        vm.warp(deadline + market.SETTLEMENT_GRACE() + 1);
        vm.expectRevert(bytes("no ground"));
        market.cancelDay(dayId, 0, "stuck");
        market.cancelDay(dayId, 1, "operator withheld data"); // alice's request timed out
    }

    // Days are frozen in increasing order.
    function test_CloseDays_MustBeInOrder() public {
        _honestDay(); // dayId closed
        bytes32[] memory hashes = new bytes32[](2);
        vm.prank(operator);
        vm.expectRevert(bytes("out of order"));
        market.postNetputHashes(dayId - 1, hashes);
    }

    // Only one day closes at a time: the next freeze waits for the previous day to settle or cancel.
    function test_CloseNextDay_WhilePreviousStillClosing_Reverts() public {
        _submitHonestChunk(); // dayId proven but not settled
        vm.warp((dayId + 2) * DAY + 1);
        bytes32[] memory hashes = new bytes32[](2);
        vm.prank(operator);
        vm.expectRevert(bytes("previous day still closing"));
        market.postNetputHashes(dayId + 1, hashes);
    }

    // Once the previous day is settled, the next one can be frozen.
    function test_CloseNextDay_AfterPreviousSettled_Works() public {
        _submitHonestChunk();
        _warpPastDeadline();
        market.finalizeDay(dayId);
        vm.warp((dayId + 2) * DAY + 1);
        bytes32[] memory hashes = new bytes32[](2);
        vm.prank(operator);
        market.postNetputHashes(dayId + 1, hashes);
        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId + 1);
        assertEq(uint8(st), uint8(MarketV4.DayState.Closing));
    }

    // A withdrawal requested before the freeze is paid in tokens at settlement.
    function test_Withdrawal_PaidAtFinalize() public {
        vm.prank(alice);
        market.requestWithdraw(100_000 * UNIT);
        uint256 before = eeur.balanceOf(alice);

        (bytes32[] memory nc, uint32[96] memory pS, uint32[96] memory pD, uint256 o, uint256 i) = _honestDay();
        uint256[] memory paid = _noWithdrawals();
        paid[0] = 100_000; // proven payout for alice, internal units
        market.submitChunk(dayId, 0, MarketV4.ChunkSubmission(nc, paid, pS, pD, o, i), "proof");
        _warpPastDeadline();
        market.finalizeDay(dayId);
        assertEq(eeur.balanceOf(alice), before + 100_000 * UNIT);
        assertEq(market.pendingWithdrawal(1), 0);
    }

    // Deposits must be whole internal units, so no token wei is stranded by the conversion.
    function test_Deposit_RejectsSubPeurDust() public {
        vm.prank(alice);
        vm.expectRevert(bytes("amount not a whole pEUR"));
        market.deposit(1); // 1 wei
    }

    // A deposit made after midnight is not in that day's proof and stays queued for the next day.
    function test_DepositAfterFreeze_StaysQueued() public {
        _submitHonestChunk(); // freezes alice's 1 EEUR deposit
        assertEq(market.snapDeposit(dayId, 1), 1 ether / UNIT);

        vm.prank(alice);
        market.deposit(0.5 ether); // after the freeze
        assertEq(market.pendingDeposit(1), 1.5 ether / UNIT);

        _warpPastDeadline();
        market.finalizeDay(dayId);

        assertEq(market.pendingDeposit(1), 0.5 ether / UNIT);
    }

    // A withdrawal requested after midnight is not paid that day and stays queued.
    function test_WithdrawAfterFreeze_NotPaidToday_StaysQueued() public {
        _submitHonestChunk();
        assertEq(market.snapWithdrawal(dayId, 1), 0);

        vm.prank(alice);
        market.requestWithdraw(0.1 ether);
        uint256 before = eeur.balanceOf(alice);

        _warpPastDeadline();
        market.finalizeDay(dayId);

        assertEq(eeur.balanceOf(alice), before); // nothing paid
        assertEq(market.pendingWithdrawal(1), 0.1 ether / UNIT); // still queued
    }

    // A cancelled day applies none of the frozen deposits.
    function test_CancelledDay_ConsumesNothing() public {
        _honestDay(); // frozen, no batch submitted
        assertEq(market.snapDeposit(dayId, 1), 1 ether / UNIT);
        _warpPastDeadline();
        market.cancelDay(dayId, 0, "no proof");
        assertEq(market.pendingDeposit(1), 1 ether / UNIT);
    }

    // Registrations during a close do not change the number of batches that day must prove.
    function test_RegisterMidClose_DoesNotChangeChunkCount() public {
        _honestDay();
        uint256 k0 = market.chunkCountFor(dayId);
        for (uint256 i = 0; i < 20; i++) {
            address late = makeAddr(string(abi.encodePacked("late", i)));
            vm.prank(late);
            market.register(bytes.concat(hex"02", bytes32("late_pk")));
        }
        assertGt(market.chunkCount(), k0); // 22 members now need more batches
        assertEq(market.chunkCountFor(dayId), k0); // but the frozen day keeps its count
    }

    // The rounding residual is zero when the rule's prices fall on the stored grain, positive otherwise.
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

    // Anyone may sweep the dust, and it can only go to the fixed reserve.
    function test_SweepDust_PermissionlessToFixedReserve() public {
        _submitHonestChunk();
        _warpPastDeadline();
        market.finalizeDay(dayId);
        uint256 pot = market.dustPot();

        address anyone = makeAddr("passer_by");
        if (pot == 0) { // rules with no residual: nothing to sweep
            vm.prank(anyone);
            vm.expectRevert(bytes("no dust"));
            market.sweepDust();
            return;
        }

        vm.prank(anyone);
        market.sweepDust();

        assertEq(market.dustPot(), 0);
        assertEq(eeur.balanceOf(reserve), pot * UNIT); // internal units converted back to token wei
    }

    // Sweeping an empty pot reverts.
    function test_SweepDust_NothingToSweep_Reverts() public {
        vm.expectRevert(bytes("no dust"));
        market.sweepDust();
    }

    // Only the operator can propose a floor.
    function test_ProposeFloor_OnlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not operator"));
        market.proposeFloor(1, bytes32("x"));
    }

    // A floor takes effect only once the floor admin confirms the operator's proposal.
    function test_CoSignature_HappyPath() public {
        vm.prank(operator);
        market.proposeFloor(1, bytes32("newfloor"));
        assertEq(market.floorCommitOf(1), bytes32("floor_commit_1")); // proposal alone changes nothing
        vm.prank(floorAdmin);
        market.confirmFloor(1, bytes32("newfloor"));
        assertEq(market.floorCommitOf(1), bytes32("newfloor")); // in force after confirmation
        assertEq(market.pendingFloorCommit(1), bytes32(0)); // proposal consumed
    }

    // The operator cannot sign both halves and set a floor alone.
    function test_CoSignature_OperatorAloneCannotConfirm() public {
        vm.prank(operator);
        market.proposeFloor(1, bytes32("evil"));
        vm.prank(operator); // operator tries the second signature
        vm.expectRevert(bytes("not floor admin"));
        market.confirmFloor(1, bytes32("evil"));
        assertEq(market.floorCommitOf(1), bytes32("floor_commit_1")); // unchanged
    }

    // The floor admin cannot set a floor the operator never proposed.
    function test_CoSignature_AdminCannotConfirmUnproposed() public {
        vm.prank(floorAdmin);
        vm.expectRevert(bytes("no matching proposal"));
        market.confirmFloor(1, bytes32("fabricated"));
    }

    // The confirmation must name exactly the proposed commitment.
    function test_CoSignature_ConfirmMustMatchProposal() public {
        vm.prank(operator);
        market.proposeFloor(1, bytes32("A"));
        vm.prank(floorAdmin);
        vm.expectRevert(bytes("no matching proposal"));
        market.confirmFloor(1, bytes32("B")); // differs from the proposal
    }

    // The open request counter rises and falls with both recourse stages, and settlement needs it at zero.
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
        market.requestClearReveal(dayId); // stage 2 reopens one request
        assertEq(market.openRevealCount(dayId), 1);

        market.clearReveal(dayId, 1, 1, "proof");
        assertEq(market.openRevealCount(dayId), 0);

        _warpPastDeadline();
        market.finalizeDay(dayId); // all requests answered
    }

    // An answered request is not a ground to cancel, even after its window.
    function test_Cancel_WrongSlot_NoGround() public {
        _submitHonestChunk();
        vm.prank(alice);
        market.requestData(dayId);
        vm.prank(operator);
        market.postEncryptedData(dayId, 1, hex"aa"); // answered in time

        vm.warp(block.timestamp + market.REVEAL_WINDOW() + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("no ground"));
        market.cancelDay(dayId, 1, "bogus claim");
    }

    // Only the operator posts session aggregates.
    function test_OpenSession_NotOperator_Reverts() public {
        vm.warp(dayId * DAY + 10 * SLOT + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("not operator"));
        market.openSession(dayId, 10, 100, 100);
    }

    // Settlement does not depend on the operator: any account can trigger it.
    function test_FinalizeDay_IsPermissionless() public {
        _submitHonestChunk();
        _warpPastDeadline();
        address randomKeeper = makeAddr("keeper_org_3");
        vm.prank(randomKeeper);
        market.finalizeDay(dayId); // no role required
        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Finalized));
    }

    // A request larger than the balance is paid only up to what the proof allows; the day still settles.
    function test_GreedyWithdrawal_IsClamped_DayStillCloses() public {
        vm.prank(alice);
        market.requestWithdraw(50 ether); // far above her 1 EEUR deposit
        assertEq(market.pendingWithdrawal(1), 50 ether / UNIT);

        (bytes32[] memory nc, uint32[96] memory pS, uint32[96] memory pD, uint256 o, uint256 i) = _honestDay();
        uint256[] memory paid = _noWithdrawals();
        paid[0] = 0.5 ether / UNIT; // the proof caps the payout
        uint256 before = eeur.balanceOf(alice);
        market.submitChunk(dayId, 0, MarketV4.ChunkSubmission(nc, paid, pS, pD, o, i), "proof");

        _warpPastDeadline();
        market.finalizeDay(dayId); // the oversized request does not block settlement

        (MarketV4.DayState st,,,,,) = market.dayCloses(dayId);
        assertEq(uint8(st), uint8(MarketV4.DayState.Finalized));
        assertEq(eeur.balanceOf(alice), before + 0.5 ether); // paid what was proven
        assertEq(market.pendingWithdrawal(1), 49.5 ether / UNIT); // the rest stays queued
    }
}

// Reruns the suite with every tariff bound 1 wei off the stored price grain, so rounding always
// leaves a residual. Also holds the late-registration and escape hatch tests.
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

    // A member who registered after midnight cannot open recourse on that day and block it.
    function test_Request_NotAMemberThatDay_Reverts() public {
        _honestDay();
        address carol = makeAddr("carol");
        vm.prank(carol);
        market.register(bytes.concat(hex"02", bytes32("carol_pk"))); // slot 3, after the freeze
        vm.prank(carol);
        vm.expectRevert(bytes("not a member that day"));
        market.requestData(dayId);
    }

    // The escape hatch is closed while the contract is younger than the escape delay.
    function test_Escape_NotRightAfterDeployment() public {
        vm.prank(alice);
        vm.expectRevert(bytes("operator active"));
        market.escape(0, "proof");
    }

    // After the delay with no settlement, a member leaves with its balance plus its unapplied deposit.
    function test_Escape_AfterInactivity_ReturnsBalanceAndQueuedDeposit() public {
        vm.warp((dayId + market.ESCAPE_DELAY_DAYS() + 1) * DAY + 1);
        uint256 before = eeur.balanceOf(alice);
        vm.prank(alice);
        market.escape(0, "proof"); // settled balance 0, queued deposit 1 EEUR
        assertEq(eeur.balanceOf(alice), before + 1 ether);
        assertEq(market.pendingDeposit(1), 0);
        assertEq(market.balCommitOf(1), ZERO_BAL_COMMIT); // reset, nothing left to claim
    }

    // The escape pays the balance proven against the last settled commitment.
    function test_Escape_PaysTheProvenBalance() public {
        _submitHonestChunk();
        _warpPastDeadline();
        market.finalizeDay(dayId);
        vm.warp((dayId + market.ESCAPE_DELAY_DAYS() + 2) * DAY + 1); // the settled day is out of the 14-day lookback
        uint256 before = eeur.balanceOf(alice);
        vm.prank(alice);
        market.escape(700_000, "proof");
        assertEq(eeur.balanceOf(alice), before + 700_000 * UNIT);
    }

    // A settlement within the last 14 days means the operator is active: no escape.
    function test_Escape_BlockedByARecentSettlement() public {
        _submitHonestChunk();
        _warpPastDeadline();
        market.finalizeDay(dayId);
        vm.warp((dayId + 5) * DAY + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("operator active"));
        market.escape(0, "proof");
    }

    // A day still closing must resolve first; once it is cancelled, the escape opens.
    function test_Escape_BlockedWhileADayIsClosing_ThenAllowedOnceCancelled() public {
        _honestDay();
        vm.warp((dayId + market.ESCAPE_DELAY_DAYS() + 1) * DAY + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("operator active"));
        market.escape(0, "proof");
        market.cancelDay(dayId, 0, "no proof");
        vm.prank(alice);
        market.escape(0, "proof");
    }

    // The escape requires a valid reveal proof of the claimed balance.
    function test_Escape_InvalidProof_Reverts() public {
        vm.warp((dayId + market.ESCAPE_DELAY_DAYS() + 1) * DAY + 1);
        revealVerifier.set(false);
        vm.prank(alice);
        vm.expectRevert(bytes("invalid reveal"));
        market.escape(0, "proof");
    }
}

// Reruns the suite under the supply-demand ratio rule.
contract MarketV4SupplyDemandRatioTest is MarketV4Test {
    function _rule() internal pure override returns (PricingLib.Rule) {
        return PricingLib.Rule.SupplyDemandRatio;
    }
}

// Reruns the suite under the hyperbolic rule.
contract MarketV4HyperbolicTest is MarketV4Test {
    function _rule() internal pure override returns (PricingLib.Rule) {
        return PricingLib.Rule.Hyperbolic;
    }

    // The geometric mean of the test band is irrational, so the recorded prices are
    // rounded and a positive residual is expected, unlike under the other two rules.
    function _expectedDustIsZero() internal view override returns (bool) {
        return false;
    }
}
