// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Settlement contract of the local market. Records each session's aggregates and prices,
// freezes the day at midnight, verifies the batch proofs, runs the recourse window, then
// settles or cancels the day. It only sees aggregates, commitments and proofs, never an
// individual position. Driven by the operator daemon (js_scripts/operator/).

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IHonkVerifier} from "./interfaces/IVerifier.sol";
import {IGridTariff} from "./interfaces/IGridTariff.sol";
import {IPricing} from "./interfaces/IPricing.sol";

contract MarketV4 {
    uint256 public constant SESSIONS = 96; // fifteen-minute sessions per day
    uint256 public constant BATCH = 8; // members per batch proof, fixed by the circuit
    uint256 public constant SESSION_SECONDS = 900; // length of a session

    // 18-decimal price / PRICE_SCALE = stored 32-bit price. Tariff prices are in cents per kWh,
    // so one stored unit is 1e-7 cent per kWh, and one unit times one Wh is 1e-12 of the currency.
    uint256 public constant PRICE_SCALE = 1e11;
    uint256 public constant WEI_PER_UNIT = 1e6; // token base units (18 decimals) per internal unit (1e-12)

    uint256 public constant PROOF_WINDOW = 12 hours; // after midnight: proofs and recourse, no settlement yet
    uint256 public constant REVEAL_WINDOW = 4 hours; // operator's time to answer each recourse stage
    uint256 public constant SETTLEMENT_GRACE = 6 hours; // after the deadline, anyone may cancel a stuck day
    uint256 public constant MAX_UNIT = type(uint32).max; // largest stored price
    uint256 public constant ESCAPE_DELAY_DAYS = 14; // days without settlement before members can leave alone

    bytes32 public immutable EMPTY_NETPUT_HASH; // commitment to 96 zero positions (slot 0, seed 0), for padding lanes
    bytes32 public immutable ZERO_BAL_COMMIT; // commitment to a zero balance (blinding 0), start of every member
    uint256 public immutable deployDay; // day of deployment, the escape hatch cannot open before deployDay + 14

    IERC20 public immutable eeur; // settlement token: deposits, withdrawals and grid payments
    IHonkVerifier public immutable dayVerifier; // verifier of the day_chunk circuit
    IHonkVerifier public immutable revealVerifier; // verifier of the reveal circuit (opens a balance commitment)
    IGridTariff public immutable tariff; // gives (lambda_low, lambda_high) at each session opening
    IPricing public immutable pricing; // turns (s, d) and the band into (r, c), rule fixed at deployment

    address public immutable operator; // opens sessions, posts commitments, answers recourse, proposes floors
    address public immutable grid; // paid for net imports, pays for net exports
    address public immutable floorAdmin; // second signature on a member's floor
    address public immutable reserve; // receives the rounding residual (sweepDust)

    uint256 public prosumerCount; // members registered, slots run from 1 to prosumerCount

    mapping(address => uint256) public slotOf; // wallet => slot, 0 if not registered
    mapping(uint256 => address) public ownerOf; // slot => wallet paid on withdrawal
    mapping(uint256 => bytes) public encryptionKeyOf; // slot => public key for encrypted recourse data
    mapping(uint256 => bytes32) public balCommitOf; // slot => balance commitment after the last settled day
    mapping(uint256 => bytes32) public floorCommitOf; // slot => floor commitment in force
    mapping(uint256 => uint256) public pendingDeposit; // slot => deposits not yet applied, internal units
    mapping(uint256 => uint256) public pendingWithdrawal; // slot => withdrawals requested, not yet paid

    // Queues frozen at a day's midnight: the values that day's proof uses. Later changes wait for the next day.
    mapping(uint256 => mapping(uint256 => uint256)) public snapDeposit; // [day][slot] deposit applied by the proof
    mapping(uint256 => mapping(uint256 => uint256)) public snapWithdrawal; // [day][slot] request the proof caps
    // [day][slot] floor the balance is checked against
    mapping(uint256 => mapping(uint256 => bytes32)) public snapFloorCommit;

    // What the chain stores for one session. Prices rounded in the market's favour (_priceUp, _priceDown).
    struct Session {
        uint32 s; // aggregate offered in the session, Wh
        uint32 d; // aggregate demanded, Wh
        uint32 priceR; // seller rate r, rounded down
        uint32 priceC; // buyer rate c, rounded up
        uint32 lambdaLo; // feed-in bound, rounded up
        uint32 lambdaHi; // retail bound, rounded down
        bool opened; // false for a session the operator never opened (counts as zero)
    }

    mapping(uint256 => mapping(uint256 => Session)) public sessions; // [day][t] record of session t

    // Pending: trading or not yet frozen. Closing: frozen, proofs and recourse under way.
    // Finalized: settled. Cancelled: nothing moved.
    enum DayState {
        Pending,
        Closing,
        Finalized,
        Cancelled
    }

    // Closing state of one day.
    struct DayClose {
        DayState state; // where the day stands
        uint256 chunksVerified; // batches proven so far
        uint256 accPaidOut; // sum of the batches' totals paid to sellers
        uint256 accPaidIn; // sum of the batches' totals paid by buyers
        uint256 disputeDeadline; // end of the proof and recourse window
        uint256 prosumerCountAt; // member count frozen at midnight, fixes the number of batches
    }

    mapping(uint256 => DayClose) public dayCloses; // [day] closing state
    mapping(uint256 => mapping(uint256 => bool)) public chunkDone; // [day][k] batch k proven

    // [day][t] running sums of the batches' partial aggregates, checked at settlement against the posted (s, d).
    mapping(uint256 => uint32[SESSIONS]) internal accS;
    mapping(uint256 => uint32[SESSIONS]) internal accD;

    // [day][slot] proven new balance, applied at settlement
    mapping(uint256 => mapping(uint256 => bytes32)) public stagedCommit;
    // [day][slot] proven payout, paid at settlement
    mapping(uint256 => mapping(uint256 => uint256)) public stagedWithdrawalPaid;
    mapping(uint256 => mapping(uint256 => bytes32)) public netputHashOf; // [day][slot] commitment to the 96 positions
    mapping(uint256 => bool) public netputHashesPosted; // [day] frozen at midnight

    // One member's recourse for one day. Stage 1: encrypted data. Stage 2: balance opened in the clear.
    struct RevealRequest {
        uint64 stage1Deadline; // operator's deadline for stage 1, 0 if never requested
        uint64 stage2Deadline; // operator's deadline for stage 2, 0 if never requested
        bool stage1Done; // encrypted data published
        bool stage2Done; // balance opened in the clear
    }

    mapping(uint256 => mapping(uint256 => RevealRequest)) public reveals; // [day][slot] recourse state
    mapping(uint256 => uint256) public openRevealCount; // [day] unanswered requests, settlement waits for 0

    uint256 public lastClosedDay; // last day frozen, days close in increasing order
    uint256 public dustPot; // rounding residual of settled days, waiting for sweepDust

    event SessionOpened(uint256 indexed dayId, uint256 t, uint32 s, uint32 d, uint32 r, uint32 c);
    event NetputHashesPosted(uint256 indexed dayId);
    event ChunkVerified(uint256 indexed dayId, uint256 k);
    event DayFinalized(uint256 indexed dayId, uint256 paidOut, uint256 paidIn);
    event DayCancelled(uint256 indexed dayId, string reason);
    event DataRequested(uint256 indexed dayId, uint256 slot, uint8 stage);
    // recourse data, read off-chain by the member
    event EncryptedDataPosted(uint256 indexed dayId, uint256 slot, bytes blob);
    event BalanceRevealed(uint256 indexed dayId, uint256 slot, uint64 bal);
    event DustAccrued(uint256 indexed dayId, uint256 amount);
    event DustSwept(uint256 amount);
    event FloorProposed(uint256 indexed slot, bytes32 floorCommit);
    event FloorSet(uint256 indexed slot);
    event Escaped(uint256 indexed slot, uint256 amount); // member left through the escape hatch

    constructor(
        IERC20 _eeur,
        IHonkVerifier _day,
        IHonkVerifier _reveal,
        IGridTariff _tariff,
        IPricing _pricing,
        address _operator,
        address _grid,
        address _floorAdmin,
        address _reserve,
        bytes32 _emptyNetputHash, // computed off-chain with the circuit's hash
        bytes32 _zeroBalCommit // idem
    ) {
        eeur = _eeur;
        dayVerifier = _day;
        revealVerifier = _reveal;
        tariff = _tariff;
        pricing = _pricing;
        operator = _operator;
        grid = _grid;
        floorAdmin = _floorAdmin;
        reserve = _reserve;
        EMPTY_NETPUT_HASH = _emptyNetputHash;
        ZERO_BAL_COMMIT = _zeroBalCommit;
        deployDay = block.timestamp / 1 days;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }

    // Anyone registers once per wallet, with a secp256k1 key for encrypted recourse data.
    function register(bytes calldata encryptionKey) external {
        require(slotOf[msg.sender] == 0, "registered"); // one slot per wallet
        require(
            (encryptionKey.length == 33 && (encryptionKey[0] == 0x02 || encryptionKey[0] == 0x03)) // compressed key
                || (encryptionKey.length == 65 && encryptionKey[0] == 0x04), // uncompressed key
            "bad pubkey"
        );
        uint256 slot = ++prosumerCount; // next free slot
        slotOf[msg.sender] = slot;
        ownerOf[slot] = msg.sender;
        encryptionKeyOf[slot] = encryptionKey;
        balCommitOf[slot] = ZERO_BAL_COMMIT; // starts with a zero balance
        floorCommitOf[slot] = ZERO_BAL_COMMIT; // and a zero floor
    }

    // [slot] floor proposed by the operator, awaiting confirmation
    mapping(uint256 => bytes32) public pendingFloorCommit;

    // Floor, first signature: the operator proposes a commitment to the member's floor.
    function proposeFloor(uint256 slot, bytes32 floorCommit) external onlyOperator {
        require(slot != 0 && slot <= prosumerCount, "slot"); // registered slot only
        pendingFloorCommit[slot] = floorCommit;
        emit FloorProposed(slot, floorCommit);
    }

    // Floor, second signature: the floor admin confirms the same commitment, which takes effect.
    function confirmFloor(uint256 slot, bytes32 floorCommit) external {
        require(msg.sender == floorAdmin, "not floor admin");
        require(pendingFloorCommit[slot] == floorCommit && floorCommit != bytes32(0), "no matching proposal");
        floorCommitOf[slot] = floorCommit; // checked by the proofs from the next midnight on
        delete pendingFloorCommit[slot];
        emit FloorSet(slot);
    }

    // Deposit in tokens, applied by the first day frozen after it once that day settles.
    function deposit(uint256 amount) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(amount % WEI_PER_UNIT == 0, "amount not a whole pEUR"); // whole internal units only
        require(eeur.transferFrom(msg.sender, address(this), amount), "transfer"); // tokens held by the market
        pendingDeposit[slot] += amount / WEI_PER_UNIT; // queued in internal units
    }

    // Withdrawal request, paid at a later settlement up to what the proof allows. The rest stays queued.
    function requestWithdraw(uint256 amount) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(amount % WEI_PER_UNIT == 0, "amount not a whole pEUR");
        pendingWithdrawal[slot] += amount / WEI_PER_UNIT; // queued in internal units
    }

    // Day number of the current block.
    function currentDayId() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    // Session index (0 to 95) of the current block.
    function currentSessionIdx() public view returns (uint256) {
        return (block.timestamp % 1 days) / SESSION_SECONDS;
    }

    // The operator posts (s, d) of the session in progress, in Wh. The contract reads the band,
    // computes (r, c), rounds them and stores the session.
    function openSession(uint256 dayId, uint256 t, uint32 s, uint32 d) external onlyOperator {
        require(t < SESSIONS, "t");
        require(!sessions[dayId][t].opened, "opened"); // each session opens once
        require(dayId == currentDayId() && t == currentSessionIdx(), "clock"); // only the current session
        (UD60x18 lo, UD60x18 hi) = tariff.getPrices(block.timestamp); // grid band of this session
        // rule's rates
        (UD60x18 rUd, UD60x18 cUd) = pricing.prices(ud(uint256(s) * 1e18), ud(uint256(d) * 1e18), lo, hi);
        // rounded so the market never pays out more than it collects
        sessions[dayId][t] = Session(s, d, _priceDown(rUd), _priceUp(cUd), _priceUp(lo), _priceDown(hi), true);
        (uint32 r, uint32 c) = (sessions[dayId][t].priceR, sessions[dayId][t].priceC);
        emit SessionOpened(dayId, t, s, d, r, c);
    }

    // Number of batches for the current member count.
    function chunkCount() public view returns (uint256) {
        return (prosumerCount + BATCH - 1) / BATCH; // ceil(n / 8)
    }

    // Number of batches of a day, from the member count frozen at its midnight.
    function chunkCountFor(uint256 dayId) public view returns (uint256) {
        return (dayCloses[dayId].prosumerCountAt + BATCH - 1) / BATCH;
    }

    // Midnight freeze: one position commitment per member, and in the same transaction the member
    // count, deposits, withdrawal requests and floors are frozen and the proof window opens.
    function postNetputHashes(uint256 dayId, bytes32[] calldata hashes) external onlyOperator {
        require(dayId < currentDayId(), "day not over");
        require(!netputHashesPosted[dayId], "posted");
        require(dayId > lastClosedDay, "out of order"); // days close in increasing order
        // one day at a time
        require(lastClosedDay == 0 || dayCloses[lastClosedDay].state != DayState.Closing, "previous day still closing");
        require(hashes.length == prosumerCount, "len"); // one commitment per member
        for (uint256 i = 0; i < hashes.length; i++) {
            uint256 slot = i + 1;
            netputHashOf[dayId][slot] = hashes[i];
            snapDeposit[dayId][slot] = pendingDeposit[slot]; // freeze the queues the proof uses
            snapWithdrawal[dayId][slot] = pendingWithdrawal[slot];
            snapFloorCommit[dayId][slot] = floorCommitOf[slot];
        }
        netputHashesPosted[dayId] = true;
        lastClosedDay = dayId;
        dayCloses[dayId].prosumerCountAt = prosumerCount; // fixes the number of batches
        dayCloses[dayId].state = DayState.Closing;
        dayCloses[dayId].disputeDeadline = (dayId + 1) * 1 days + PROOF_WINDOW; // noon of the next day
        emit NetputHashesPosted(dayId);
    }

    // Outputs claimed by the prover for one batch.
    struct ChunkSubmission {
        bytes32[] newCommits; // new balance commitment of each lane
        uint256[] withdrawalsPaid; // withdrawal the proof allows for each lane
        uint32[SESSIONS] partialS; // the batch's share of s in every session
        uint32[SESSIONS] partialD; // the batch's share of d in every session
        uint256 partialPaidOut; // total the batch's sellers receive
        uint256 partialPaidIn; // total the batch's buyers pay
    }

    // Verifies the proof of batch k against public inputs rebuilt from storage, then adds its partial
    // aggregates and totals to the running sums and stages its new commitments and payouts.
    function submitChunk(uint256 dayId, uint256 k, ChunkSubmission calldata sub, bytes calldata proof) external {
        DayClose storage dc = dayCloses[dayId];
        require(dc.state == DayState.Closing, "state");
        require(k < chunkCountFor(dayId) && !chunkDone[dayId][k], "chunk"); // valid batch, proven once
        require(sub.newCommits.length == BATCH && sub.withdrawalsPaid.length == BATCH, "len");

        bytes32[] memory pub_ = _buildPublicInputs(dayId, k, sub); // inputs come from the chain, not the prover
        require(dayVerifier.verify(proof, pub_), "invalid proof");

        uint32[SESSIONS] storage aS = accS[dayId];
        uint32[SESSIONS] storage aD = accD[dayId];
        for (uint256 t = 0; t < SESSIONS; t++) {
            aS[t] += sub.partialS[t]; // add the batch's share of each session
            aD[t] += sub.partialD[t];
        }
        dc.accPaidOut += sub.partialPaidOut;
        dc.accPaidIn += sub.partialPaidIn;

        for (uint256 i = 0; i < BATCH; i++) {
            uint256 slot = k * BATCH + i + 1; // lane i of batch k
            if (slot <= dc.prosumerCountAt) { // padding lanes are ignored
                stagedCommit[dayId][slot] = sub.newCommits[i];
                stagedWithdrawalPaid[dayId][slot] = sub.withdrawalsPaid[i];
            }
        }
        chunkDone[dayId][k] = true;
        dc.chunksVerified += 1;
        emit ChunkVerified(dayId, k);
    }

    // Settlement, by anyone once every batch is proven, the deadline has passed and no request is open.
    function finalizeDay(uint256 dayId) external {
        DayClose storage dc = dayCloses[dayId];
        require(dc.state == DayState.Closing, "state");
        require(dc.chunksVerified == chunkCountFor(dayId), "chunks"); // every batch proven
        require(block.timestamp >= dc.disputeDeadline, "dispute window"); // recourse window over
        _requireNoPendingReveals(dayId);

        uint32[SESSIONS] storage aS = accS[dayId];
        uint32[SESSIONS] storage aD = accD[dayId];
        uint256 expectedOut; // what sellers must receive at the posted rates
        uint256 expectedIn; // what buyers must pay
        uint256 gridPay; // value of net imports, paid to the grid
        uint256 gridRecv; // value of net exports, paid by the grid
        for (uint256 t = 0; t < SESSIONS; t++) {
            Session storage ss = sessions[dayId][t];
            uint32 s_ = ss.opened ? ss.s : 0; // a session never opened counts as empty
            uint32 d_ = ss.opened ? ss.d : 0;
            require(aS[t] == s_ && aD[t] == d_, "s/d mismatch"); // proofs add up to the posted aggregates
            expectedOut += uint256(ss.priceR) * s_;
            expectedIn += uint256(ss.priceC) * d_;
            if (d_ > s_) {
                gridPay += uint256(ss.lambdaHi) * (d_ - s_); // shortfall bought at retail
            } else if (s_ > d_) {
                gridRecv += uint256(ss.lambdaLo) * (s_ - d_); // surplus sold at feed-in
            }
        }

        require(dc.accPaidOut == expectedOut, "conservation out"); // proven totals match the rates
        require(dc.accPaidIn == expectedIn, "conservation in");

        uint256 dust = (dc.accPaidIn + gridRecv) - (dc.accPaidOut + gridPay); // rounding residual, never negative
        dustPot += dust;
        emit DustAccrued(dayId, dust);

        for (uint256 slot = 1; slot <= dc.prosumerCountAt; slot++) {
            balCommitOf[slot] = stagedCommit[dayId][slot]; // proven balance becomes the settled one
            uint256 dep = snapDeposit[dayId][slot];
            if (dep > 0) pendingDeposit[slot] -= dep; // deposit applied, later ones stay queued
            uint256 wPaid = stagedWithdrawalPaid[dayId][slot];
            if (wPaid > 0) {
                pendingWithdrawal[slot] -= wPaid; // the unpaid part stays queued
                require(eeur.transfer(ownerOf[slot], wPaid * WEI_PER_UNIT), "withdraw");
            }
        }
        _settleGridLeg(gridPay, gridRecv);

        dc.state = DayState.Finalized;
        emit DayFinalized(dayId, dc.accPaidOut, dc.accPaidIn);
    }

    // Cancellation, by anyone, on verifiable grounds only. Nothing moves and balances stay as they were.
    function cancelDay(uint256 dayId, uint256 revealSlot, string calldata reason) public {
        DayClose storage dc = dayCloses[dayId];
        require(dc.state == DayState.Closing, "state");
        // proofs missing
        bool timeout = block.timestamp > dc.disputeDeadline && dc.chunksVerified < chunkCountFor(dayId);
        bool revealTimeout = revealSlot != 0 && _revealTimedOut(dayId, revealSlot); // recourse left unanswered
        // nobody settled
        bool stuck = block.timestamp > dc.disputeDeadline + SETTLEMENT_GRACE && openRevealCount[dayId] == 0;
        require(timeout || revealTimeout || stuck, "no ground");
        dc.state = DayState.Cancelled;
        emit DayCancelled(dayId, reason);
    }

    // Recourse, stage 1: a member asks for its data of a closing day, encrypted to its key.
    function requestData(uint256 dayId) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(dayCloses[dayId].state == DayState.Closing, "state");
        // late registrants cannot block the day
        require(slot <= dayCloses[dayId].prosumerCountAt, "not a member that day");
        require(block.timestamp < dayCloses[dayId].disputeDeadline, "objection window closed");
        RevealRequest storage r = reveals[dayId][slot];
        require(r.stage1Deadline == 0, "requested"); // once per day
        r.stage1Deadline = uint64(block.timestamp + REVEAL_WINDOW);
        openRevealCount[dayId] += 1; // blocks settlement until answered
        emit DataRequested(dayId, slot, 1);
    }

    // Stage 1 answer by the operator. The blob is not checked on-chain, only published.
    function postEncryptedData(uint256 dayId, uint256 slot, bytes calldata blob) external onlyOperator {
        RevealRequest storage r = reveals[dayId][slot];
        require(r.stage1Deadline != 0 && !r.stage1Done, "no request");
        r.stage1Done = true;
        openRevealCount[dayId] -= 1;
        emit EncryptedDataPosted(dayId, slot, blob);
    }

    // Recourse, stage 2: after stage 1, the member asks for its balance to be opened in the clear.
    function requestClearReveal(uint256 dayId) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(dayCloses[dayId].state == DayState.Closing, "state");
        require(block.timestamp < dayCloses[dayId].disputeDeadline + REVEAL_WINDOW, "objection window closed");
        RevealRequest storage r = reveals[dayId][slot];
        require(r.stage1Done && r.stage2Deadline == 0, "stage1 first");
        r.stage2Deadline = uint64(block.timestamp + REVEAL_WINDOW);
        openRevealCount[dayId] += 1; // blocks settlement until answered
        emit DataRequested(dayId, slot, 2);
    }

    // Stage 2 answer: a reveal proof that bal opens the member's commitment.
    function clearReveal(uint256 dayId, uint256 slot, uint64 bal, bytes calldata proof) external {
        RevealRequest storage r = reveals[dayId][slot];
        require(r.stage2Deadline != 0 && !r.stage2Done, "no request");
        // new balance if its batch is proven, else the settled one
        bytes32 c = stagedCommit[dayId][slot] != bytes32(0) ? stagedCommit[dayId][slot] : balCommitOf[slot];
        bytes32[] memory pub_ = new bytes32[](2);
        pub_[0] = c;
        pub_[1] = bytes32(uint256(bal));
        require(revealVerifier.verify(proof, pub_), "invalid reveal");
        r.stage2Done = true;
        openRevealCount[dayId] -= 1;
        emit BalanceRevealed(dayId, slot, bal);
    }

    // True when the operator has stopped settling: no day settled in the last 14 days,
    // none closing, and the contract is at least 14 days old.
    function escapeAvailable() public view returns (bool) {
        uint256 today = currentDayId();
        if (today < deployDay + ESCAPE_DELAY_DAYS) return false; // too young
        // a day must resolve first
        if (lastClosedDay != 0 && dayCloses[lastClosedDay].state == DayState.Closing) return false;
        for (uint256 i = 0; i < ESCAPE_DELAY_DAYS; i++) {
            if (dayCloses[today - i].state == DayState.Finalized) return false; // operator still active
        }
        return true;
    }

    // Escape hatch: the member proves its settled balance with the reveal circuit and is paid it,
    // plus any deposit not yet applied. No operator action needed.
    function escape(uint64 bal, bytes calldata proof) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(escapeAvailable(), "operator active");
        bytes32[] memory pub_ = new bytes32[](2);
        pub_[0] = balCommitOf[slot]; // settled balance, blinding from the member's last day-close packet
        pub_[1] = bytes32(uint256(bal));
        require(revealVerifier.verify(proof, pub_), "invalid reveal");

        uint256 amount = uint256(bal) + pendingDeposit[slot];
        balCommitOf[slot] = ZERO_BAL_COMMIT; // reset, so nothing can be claimed twice
        pendingDeposit[slot] = 0;
        pendingWithdrawal[slot] = 0;
        if (amount > 0) {
            require(eeur.transfer(ownerOf[slot], amount * WEI_PER_UNIT), "escape");
        }
        emit Escaped(slot, amount);
    }

    // Sends the accumulated rounding residual to the reserve. Anyone may call it.
    function sweepDust() external {
        uint256 d = dustPot;
        require(d > 0, "no dust");
        dustPot = 0;
        require(eeur.transfer(reserve, d * WEI_PER_UNIT), "sweep");
        emit DustSwept(d);
    }

    // The 450 public inputs of a batch proof, in the circuit's order. Lanes beyond the frozen
    // member count are padding and get the neutral constants.
    function _buildPublicInputs(uint256 dayId, uint256 k, ChunkSubmission calldata sub)
        internal
        view
        returns (bytes32[] memory pub_)
    {
        uint256 n = SESSIONS * 4 + BATCH * 8 + 2; // 4 x 96 per-session values, 8 x 8 per-lane values, 2 totals
        pub_ = new bytes32[](n);
        uint256 nAt = dayCloses[dayId].prosumerCountAt; // lanes above this slot are padding
        uint256 i = 0;
        for (uint256 t = 0; t < SESSIONS; t++) {
            pub_[i++] = bytes32(uint256(sessions[dayId][t].priceR)); // seller rates
        }
        for (uint256 t = 0; t < SESSIONS; t++) {
            pub_[i++] = bytes32(uint256(sessions[dayId][t].priceC)); // buyer rates
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = bytes32(slot <= nAt ? slot : 0); // slot numbers
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = slot <= nAt ? netputHashOf[dayId][slot] : EMPTY_NETPUT_HASH; // position commitments
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = slot <= nAt ? balCommitOf[slot] : ZERO_BAL_COMMIT; // old balances
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = slot <= nAt ? sub.newCommits[j] : ZERO_BAL_COMMIT; // new balances
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = bytes32(slot <= nAt ? snapDeposit[dayId][slot] : 0); // frozen deposits
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = bytes32(slot <= nAt ? snapWithdrawal[dayId][slot] : 0); // frozen withdrawal requests
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = bytes32(slot <= nAt ? sub.withdrawalsPaid[j] : 0); // withdrawals paid
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = slot <= nAt ? snapFloorCommit[dayId][slot] : ZERO_BAL_COMMIT; // frozen floors
        }
        for (uint256 t = 0; t < SESSIONS; t++) {
            pub_[i++] = bytes32(uint256(sub.partialS[t])); // batch's share of s
        }
        for (uint256 t = 0; t < SESSIONS; t++) {
            pub_[i++] = bytes32(uint256(sub.partialD[t])); // batch's share of d
        }
        pub_[i++] = bytes32(sub.partialPaidOut);
        pub_[i++] = bytes32(sub.partialPaidIn);
    }

    // Grid leg of the day: pay net imports, pull the value of net exports (grid must have approved the market).
    function _settleGridLeg(uint256 gridPay, uint256 gridRecv) internal {
        if (gridPay > 0) {
            require(eeur.transfer(grid, gridPay * WEI_PER_UNIT), "grid pay");
        }
        if (gridRecv > 0) {
            require(eeur.transferFrom(grid, address(this), gridRecv * WEI_PER_UNIT), "grid fund");
        }
    }

    // Settlement waits while any recourse request of the day is open.
    function _requireNoPendingReveals(uint256 dayId) internal view {
        require(openRevealCount[dayId] == 0, "reveal pending");
    }

    // True if a request of this member for this day passed its deadline unanswered.
    function _revealTimedOut(uint256 dayId, uint256 slot) internal view returns (bool) {
        RevealRequest storage r = reveals[dayId][slot];
        if (r.stage1Deadline != 0 && !r.stage1Done && block.timestamp > r.stage1Deadline) return true;
        if (r.stage2Deadline != 0 && !r.stage2Done && block.timestamp > r.stage2Deadline) return true;
        return false;
    }

    // Rounds down to the stored grain. Used for the seller rate and the retail bound.
    function _priceDown(UD60x18 p) internal pure returns (uint32) {
        uint256 v = UD60x18.unwrap(p) / PRICE_SCALE;
        require(v <= MAX_UNIT, "price overflow uint32");
        return uint32(v);
    }

    // Rounds up to the stored grain. Used for the buyer rate and the feed-in bound.
    function _priceUp(UD60x18 p) internal pure returns (uint32) {
        uint256 raw = UD60x18.unwrap(p);
        uint256 v = (raw + PRICE_SCALE - 1) / PRICE_SCALE; // ceiling division
        require(v <= MAX_UNIT, "price overflow uint32");
        return uint32(v);
    }
}
