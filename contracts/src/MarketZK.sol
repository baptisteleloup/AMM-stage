// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { PoseidonT3 } from "./PoseidonT3.sol";
import { Pricing } from "./Pricing.sol";
import { IGridTariff } from "./IGridTariff.sol";

interface IDayBatchVerifier {
    function verifyProof(
        uint[2] calldata a, uint[2][2] calldata b, uint[2] calldata c,
        uint[9] calldata pubSignals
    ) external view returns (bool);
}

/// @title MarketZK — EXPERIMENTAL. Netting amounts and balances are Poseidon
///        commitments; a single Groth16 proof per day replaces the clear-text
///        budget-balance check AND the solvency checks (newBal >= 0 in-circuit).
///        Sessions/settle identical to Market. N account slots fixed by the
///        compiled circuit (here 2). Deposits/withdrawals are public deltas
///        folded into the day's proof. Netput Merkle commitments and the
///        optimistic challenge remain: the proof makes amounts sum-correct
///        and hidden, the challenge keeps them honest.
contract MarketZK {

    uint256 constant SLOT  = 900;
    uint256 constant DAY   = 86400;
    uint256 constant DUST  = 1e9;
    uint256 constant N     = 2;                    // compiled circuit size
    uint256 constant SHIFT = 1 << 127;             // sign shift used in-circuit
    // Poseidon(0, 0): initial balance commitment (balance 0 is public anyway)
    uint256 constant GENESIS_C =
        14744269619966411208579211824598458697587494354926760081771325075741142829156;

    struct Session {
        bool    opened;
        bool    settled;
        bytes32 netputRoot;
        UD60x18 s;  UD60x18 d;
        UD60x18 r;  UD60x18 c;
        UD60x18 cTotal;  UD60x18 rTotal;
    }

    struct DayBatch {
        bool     closed;
        bool     finalized;
        bool     cancelled;
        uint64   closedAt;
        bytes32  dayRoot;
        int256   net;            // clear batch sum (from sumShifted): grid leg
        uint256[N] amtC;         // hidden per-slot amounts (commitments)
        uint256[N] newC;         // staged balance commitments
        int256[N]  deltas;       // public deltas consumed by this batch
        uint256[N] withdraws;    // token payouts executed at finalize
    }

    mapping(uint64 => Session)  public sessions;
    mapping(uint32 => DayBatch) batches;
    mapping(uint32 => int256)   public dayNet;
    mapping(uint32 => uint16)   public openedCount;
    mapping(uint32 => uint16)   public settledCount;

    address[N] public accountOf;                    // slot -> prosumer
    mapping(address => uint256) public slotOf;      // prosumer -> slot + 1 (0 = none)
    uint256[N] public balC;                         // hidden balances (commitments)
    int256[N]  public pendingDelta;                 // public: deposits - withdrawals
    uint256[N] public queuedWithdraw;               // tokens owed at next finalize
    bool public bootstrapped;

    IERC20            public immutable token;
    IGridTariff       public immutable tariff;
    IDayBatchVerifier public immutable verifier;
    address           public immutable grid;
    address           public immutable operator;
    uint64            public immutable challengeWindow;

    event SessionOpened(uint64 indexed sessionId, bytes32 netputRoot, UD60x18 s, UD60x18 d);
    event Settled(uint64 indexed sessionId, UD60x18 r, UD60x18 c, UD60x18 cTotal, UD60x18 rTotal);
    event Deposited(address indexed prosumer, uint256 amount);
    event WithdrawQueued(address indexed prosumer, uint256 amount);
    event DayClosed(uint32 indexed day, bytes32 dayRoot, int256 net);
    event DayFinalized(uint32 indexed day, int256 gridLeg);
    event DayCancelled(uint32 indexed day, address indexed challenger);

    modifier onlyOperator() { require(msg.sender == operator, "not operator"); _; }

    constructor(
        IERC20 _token, IGridTariff _tariff, IDayBatchVerifier _verifier,
        address _grid, address _operator, uint64 _challengeWindow
    ) {
        token = _token; tariff = _tariff; verifier = _verifier;
        grid = _grid; operator = _operator; challengeWindow = _challengeWindow;
    }

    // ---- accounts ----

    function register(address prosumer, uint256 slot) external onlyOperator {
        require(slot < N && accountOf[slot] == address(0), "slot taken");
        require(slotOf[prosumer] == 0, "already registered");
        accountOf[slot] = prosumer;
        slotOf[prosumer] = slot + 1;
        balC[slot] = GENESIS_C;   // committed balance 0 (publicly known at genesis)
    }

    /// One-shot migration hook from the clear-balance system: operator posts
    /// the initial commitments, each prosumer verifies their opening off-chain.
    function bootstrapBalances(uint256[N] calldata c) external onlyOperator {
        require(!bootstrapped, "done");
        bootstrapped = true;
        balC = c;
    }

    // ---- money in / out: public deltas, folded into the day's proof ----

    function deposit(uint256 amount) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(amount < SHIFT, "too large");
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        pendingDelta[slot - 1] += int256(amount);
        emit Deposited(msg.sender, amount);
    }

    /// No opening reveal, no clear balance check: the withdrawal is a public
    /// negative delta and the CIRCUIT enforces newBal >= 0 — an over-withdrawal
    /// makes the day unprovable, so the operator must drop it (re-queue) first.
    function requestWithdraw(uint256 amount) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(amount < SHIFT, "too large");
        pendingDelta[slot - 1] -= int256(amount);
        queuedWithdraw[slot - 1] += amount;
        emit WithdrawQueued(msg.sender, amount);
    }

    // ---- sessions: identical to Market ----

    function currentSessionId() public view returns (uint64) {
        return uint64(block.timestamp / SLOT);
    }

    function openSession(uint64 sessionId, bytes32 netputRoot, UD60x18 s, UD60x18 d)
        external onlyOperator
    {
        uint64 cur = currentSessionId();
        require(sessionId == cur || sessionId + 1 == cur, "not current session");
        Session storage S = sessions[sessionId];
        require(!S.opened, "already opened");
        S.opened = true;
        S.netputRoot = netputRoot;
        S.s = s;
        S.d = d;
        openedCount[uint32(sessionId / 96)] += 1;
        emit SessionOpened(sessionId, netputRoot, s, d);
    }

    function settle(uint64 sessionId) external {
        require(block.timestamp >= (uint256(sessionId) + 1) * SLOT, "session not closed");
        Session storage S = sessions[sessionId];
        require(S.opened, "not opened");
        require(!S.settled, "already settled");
        (UD60x18 lo, UD60x18 hi) = tariff.getPrices(uint256(sessionId) * SLOT);
        (S.cTotal, S.rTotal) = Pricing.totals(S.s, S.d, lo, hi);
        (S.r, S.c)           = Pricing.prices(S.s, S.d, lo, hi);
        S.settled = true;
        dayNet[uint32(sessionId / 96)] +=
            int256(S.rTotal.unwrap()) - int256(S.cTotal.unwrap());
        settledCount[uint32(sessionId / 96)] += 1;
        emit Settled(sessionId, S.r, S.c, S.cTotal, S.rTotal);
    }

    // ---- ZK netting ----

    /// Publics assembled BY THE CONTRACT from its own state (old balances,
    /// pending deltas): the proof is bound to the chain, not to operator claims.
    function closeDayZK(
        uint32 day,
        bytes32 dayRoot,
        uint256[N] calldata amtC,
        uint256[N] calldata newC,
        uint256 sumShifted,
        uint[2] calldata pA, uint[2][2] calldata pB, uint[2] calldata pC
    ) external onlyOperator {
        require(block.timestamp >= (uint256(day) + 1) * DAY, "day not over");
        DayBatch storage B = batches[day];
        require(!B.closed, "already closed");
        require(settledCount[day] == openedCount[day], "unsettled sessions");

        uint[9] memory pub;
        pub[0] = sumShifted;
        for (uint256 i = 0; i < N; i++) {
            pub[1 + i]      = balC[i];                                  // oldC from state
            pub[3 + i]      = amtC[i];
            pub[5 + i]      = newC[i];
            pub[7 + i]      = uint256(pendingDelta[i] + int256(SHIFT)); // delta from state
        }
        require(verifier.verifyProof(pA, pB, pC, pub), "invalid proof");

        int256 sum = int256(sumShifted) - int256(N * SHIFT);
        int256 gap = sum - dayNet[day];
        if (gap < 0) gap = -gap;
        require(uint256(gap) <= DUST * (N + 1), "budget balance violated");

        B.closed   = true;
        B.closedAt = uint64(block.timestamp);
        B.dayRoot  = dayRoot;
        B.net      = sum;
        B.amtC     = amtC;
        B.newC     = newC;
        for (uint256 i = 0; i < N; i++) {
            B.deltas[i]    = pendingDelta[i];   // snapshot what the proof consumed
            B.withdraws[i] = queuedWithdraw[i];
            pendingDelta[i]   = 0;              // new deposits/withdrawals go to next day
            queuedWithdraw[i] = 0;
        }
        emit DayClosed(day, dayRoot, sum);
    }

    function finalizeDay(uint32 day) external {
        DayBatch storage B = batches[day];
        require(B.closed, "not closed");
        require(!B.finalized, "already finalized");
        require(!B.cancelled, "cancelled");
        require(block.timestamp >= B.closedAt + challengeWindow, "challenge window open");

        balC = B.newC;   // hidden balances advance: updated blind, proven correct

        for (uint256 i = 0; i < N; i++) {
            if (B.withdraws[i] > 0) {
                require(token.transfer(accountOf[i], B.withdraws[i]), "payout failed");
            }
        }
        int256 leg = B.net;
        if (leg > 0)      require(token.transferFrom(grid, address(this), uint256(leg)), "grid transfer failed");
        else if (leg < 0) require(token.transfer(grid, uint256(-leg)), "grid transfer failed");

        B.finalized = true;
        emit DayFinalized(day, leg);
    }

    /// Same optimistic game as Market, on hidden amounts: the challenger reveals
    /// their netput leaves (truth) AND the opening (amtShifted, r) of their
    /// amount commitment (claimed). Poseidon binding replaces the clear compare.
    function challenge(
        uint32 day,
        uint64[] calldata sessionIds,
        int256[] calldata netputs,
        bytes32[] calldata salts,
        bytes32[][] calldata proofs,
        uint256 amtShifted,
        uint256 amtR
    ) external {
        DayBatch storage B = batches[day];
        require(B.closed && !B.finalized && !B.cancelled, "no open batch");
        require(block.timestamp < B.closedAt + challengeWindow, "window over");
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(sessionIds.length == openedCount[day], "must cover all sessions");
        require(netputs.length == sessionIds.length && salts.length == sessionIds.length
            && proofs.length == sessionIds.length, "length mismatch");

        // the claimed amount: opening of the committed value, bound by Poseidon
        require(PoseidonT3.hash([amtShifted, amtR]) == B.amtC[slot - 1], "bad opening");
        int256 claimed = int256(amtShifted) - int256(SHIFT);

        int256 truth;
        uint64 prev;
        for (uint256 i = 0; i < sessionIds.length; i++) {
            uint64 sid = sessionIds[i];
            require(uint32(sid / 96) == day, "wrong day");
            require(i == 0 || sid > prev, "ids not increasing");
            prev = sid;
            Session storage S = sessions[sid];
            require(S.opened, "session not opened");
            bytes32 leaf = keccak256(bytes.concat(
                keccak256(abi.encode(msg.sender, netputs[i], salts[i]))
            ));
            require(MerkleProof.verify(proofs[i], S.netputRoot, leaf), "bad proof");
            (uint256 sn, uint256 dn) = decompose(netputs[i]);
            truth += int256(ud(sn).mul(S.r).unwrap()) - int256(ud(dn).mul(S.c).unwrap());
        }

        int256 diff = truth - claimed;
        if (diff < 0) diff = -diff;
        require(uint256(diff) > DUST, "batch correct");

        // cancelled day: staged commitments dropped, consumed deltas restored
        for (uint256 i = 0; i < N; i++) {
            pendingDelta[i]   += B.deltas[i];
            queuedWithdraw[i] += B.withdraws[i];
        }
        B.cancelled = true;
        emit DayCancelled(day, msg.sender);
    }

    // ---- views / helpers ----

    function clearingPrices(uint64 sessionId) external view returns (UD60x18 r, UD60x18 c) {
        Session storage S = sessions[sessionId];
        require(S.settled, "not settled");
        return (S.r, S.c);
    }

    function dayBatch(uint32 day)
        external view
        returns (bool closed, bool finalized, bool cancelled, uint64 closedAt, bytes32 dayRoot, int256 net)
    {
        DayBatch storage B = batches[day];
        return (B.closed, B.finalized, B.cancelled, B.closedAt, B.dayRoot, B.net);
    }

    function amtCommitment(uint32 day, uint256 slot) external view returns (uint256) {
        return batches[day].amtC[slot];
    }

    function decompose(int256 netput) public pure returns (uint256 supply, uint256 demand) {
        if (netput > 0)      supply = uint256(netput);
        else if (netput < 0) demand = uint256(-netput);
    }
}
