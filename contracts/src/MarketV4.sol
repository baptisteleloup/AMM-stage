// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IHonkVerifier} from "./interfaces/IVerifier.sol";
import {IGridTariff} from "./interfaces/IGridTariff.sol";
import {Pricing} from "./Pricing.sol";

// Core contract of the settlement layer. It records the session aggregates and prices,
// freezes each day at midnight, verifies the batch proofs, runs the recourse window,
// and settles or cancels the day. It never sees an individual position, only
// aggregates, commitments and proofs.
contract MarketV4 {
    // Number of fifteen-minute sessions in a day.
    uint256 public constant SESSIONS = 96;

    // Number of members proven together in one batch proof (the circuit's fixed width).
    uint256 public constant BATCH = 8;

    // Length of a session in seconds.
    uint256 public constant SESSION_SECONDS = 900; 

    // Divides an 18-decimal price into the stored 32-bit price. Prices from the tariff are
    // in cents per kWh with 18 decimals, so one stored unit is 1e-7 cent = 1e-9 of the
    // currency per kWh.
    uint256 public constant PRICE_SCALE = 1e11;

    // Token base units (18 decimals) per internal unit of account (1e-12 of the currency).
    uint256 public constant WEI_PER_UNIT = 1e6;

    // Time after midnight during which proofs are submitted and recourse can be filed.
    // Settlement is possible only once it has elapsed.
    uint256 public constant PROOF_WINDOW = 12 hours; 

    // Time the operator has to answer each step of a data request.
    uint256 public constant REVEAL_WINDOW = 4 hours; 

    // If settlement still has not happened this long after the deadline, anyone may cancel
    // the day. Keeps PROOF_WINDOW + grace under a day, so each day is resolved before the
    // next one needs to close.
    uint256 public constant SETTLEMENT_GRACE = 6 hours;

    // Largest value a stored 32-bit price can take.
    uint256 public constant MAX_UNIT = type(uint32).max; 

    // Number of days without any settled day after which members may leave with their
    // funds on their own (see escape). Two weeks, far beyond any normal delay.
    uint256 public constant ESCAPE_DELAY_DAYS = 14;

    // Commitment to 96 zero positions under slot 0 and seed 0, used for padding lanes.
    // Computed by the circuit's own hash function and injected at deployment.
    bytes32 public immutable EMPTY_NETPUT_HASH;

    // Commitment to a zero balance under blinding factor 0. Starting balance commitment of
    // every new member, and the balance and floor commitment of padding lanes.
    bytes32 public immutable ZERO_BAL_COMMIT;

    // Day of deployment. The escape hatch opens only ESCAPE_DELAY_DAYS after it, so a
    // community that has not settled its first day yet cannot be emptied at start-up.
    uint256 public immutable deployDay;

    // Settlement token. All deposits, withdrawals and grid payments move in it.
    IERC20 public immutable eeur;

    // Verifier generated from the batch circuit.
    IHonkVerifier public immutable dayVerifier;

    // Verifier generated from the reveal circuit (opens one balance commitment).
    IHonkVerifier public immutable revealVerifier;

    // Tariff contract read at every session opening for (lambda_low, lambda_high).
    IGridTariff public immutable tariff;

    // The only address that may open sessions, post commitments, answer data requests
    // and propose floors.
    address public immutable operator; 

    // Account that receives the community's net imports and pays for its net exports.
    address public immutable grid; 

    // Second signature needed to set a member's floor.
    address public immutable floorAdmin;

    // Destination of the rounding residual (see sweepDust).
    address public immutable reserve;

    // Number of registered members. Slots are numbered 1 to prosumerCount.
    uint256 public prosumerCount;

    // slotOf[wallet]: slot number of a member, 0 if not registered.
    mapping(address => uint256) public slotOf;

    // ownerOf[slot]: wallet that receives the member's withdrawals.
    mapping(uint256 => address) public ownerOf;

    // encryptionKeyOf[slot]: public key the operator encrypts data requests to.
    mapping(uint256 => bytes) public encryptionKeyOf;

    // balCommitOf[slot]: commitment to the member's balance after the last settled day.
    mapping(uint256 => bytes32) public balCommitOf; 

    // floorCommitOf[slot]: commitment to the member's floor currently in force.
    mapping(uint256 => bytes32) public floorCommitOf;

    // pendingDeposit[slot]: deposits received but not yet applied by a settlement,
    // in internal units.
    mapping(uint256 => uint256) public pendingDeposit; 

    // pendingWithdrawal[slot]: withdrawals requested but not yet paid, in internal units.
    mapping(uint256 => uint256) public pendingWithdrawal;

    // snapDeposit[day][slot]: pendingDeposit frozen at that day's midnight. This is the
    // deposit the day's proof applies; later deposits wait for the next day.
    mapping(uint256 => mapping(uint256 => uint256)) public snapDeposit; 

    // snapWithdrawal[day][slot]: pendingWithdrawal frozen at midnight, the request the proof caps.
    mapping(uint256 => mapping(uint256 => uint256)) public snapWithdrawal;

    // snapFloorCommit[day][slot]: floor commitment frozen at midnight, the one the proof compares
    // the balance with.
    mapping(uint256 => mapping(uint256 => bytes32)) public snapFloorCommit; 

    // What the chain records for one session. Prices are stored rounded (see _priceUp
    // and _priceDown).
    struct Session {
        uint32 s; // aggregate offered in the session, Wh
        uint32 d; // aggregate demanded, Wh
        uint32 priceR; // seller rate r, rounded down
        uint32 priceC; // buyer rate c, rounded up
        uint32 lambdaLo; // feed-in bound, rounded up
        uint32 lambdaHi; // retail bound, rounded down
        bool opened; // false for a session the operator never opened (counts as zero)
    }

    // sessions[day][t]: the record of session t of that day.
    mapping(uint256 => mapping(uint256 => Session)) public sessions;

    // Life of a day. Pending: trading or not yet closed. Closing: frozen at midnight, proofs
    // and recourse under way. Finalized: settled. Cancelled: nothing moved.
    enum DayState {
        Pending,
        Closing,
        Finalized,
        Cancelled
    }

    // Everything the contract tracks while a day is closing.
    struct DayClose {
        DayState state; // where the day stands
        uint256 chunksVerified; // number of batches proven so far
        uint256 accPaidOut; // sum of the batches' totals paid to sellers
        uint256 accPaidIn; // sum of the batches' totals paid by buyers
        uint256 disputeDeadline; // end of the proof and recourse window
        uint256 prosumerCountAt; // member count frozen at midnight, fixes the number of batches
    }

    // dayCloses[day]: closing state of that day.
    mapping(uint256 => DayClose) public dayCloses;

    // chunkDone[day][k]: has batch k of that day been proven?
    mapping(uint256 => mapping(uint256 => bool)) public chunkDone;

    // accS[day][t] and accD[day][t]: running sums of the partial aggregates declared by the
    // verified batches, compared at settlement with the aggregates posted during the day.
    mapping(uint256 => uint32[SESSIONS]) internal accS;
    mapping(uint256 => uint32[SESSIONS]) internal accD;

    // stagedCommit[day][slot]: new balance commitment proven by the batch, applied only at settlement.
    mapping(uint256 => mapping(uint256 => bytes32)) public stagedCommit;

    // stagedWithdrawalPaid[day][slot]: withdrawal the proof allows, paid only at settlement.
    mapping(uint256 => mapping(uint256 => uint256)) public stagedWithdrawalPaid;

    // netputHashOf[day][slot]: commitment to the member's 96 positions of that day, posted at midnight.
    mapping(uint256 => mapping(uint256 => bytes32)) public netputHashOf;

    // netputHashesPosted[day]: has that day been frozen?
    mapping(uint256 => bool) public netputHashesPosted;

    // State of one member's data request for one day. Stage 1: encrypted data.
    // Stage 2: balance opened in the clear.
    struct RevealRequest {
        uint64 stage1Deadline; // operator's deadline for stage 1, 0 if never requested
        uint64 stage2Deadline; // operator's deadline for stage 2, 0 if never requested
        bool stage1Done; // encrypted data published
        bool stage2Done; // balance opened in the clear
    }

    // reveals[day][slot]: that member's request for that day.
    mapping(uint256 => mapping(uint256 => RevealRequest)) public reveals; 

    // openRevealCount[day]: requests not yet answered. Settlement waits while it is above zero.
    mapping(uint256 => uint256) public openRevealCount;

    // Most recent day frozen at midnight. Days must close in increasing order.
    uint256 public lastClosedDay;

    // Rounding residual accumulated over settled days, waiting to be swept to the reserve.
    uint256 public dustPot;

    event SessionOpened(uint256 indexed dayId, uint256 t, uint32 s, uint32 d, uint32 r, uint32 c);
    event NetputHashesPosted(uint256 indexed dayId);
    event ChunkVerified(uint256 indexed dayId, uint256 k);
    event DayFinalized(uint256 indexed dayId, uint256 paidOut, uint256 paidIn);
    event DayCancelled(uint256 indexed dayId, string reason);
    event DataRequested(uint256 indexed dayId, uint256 slot, uint8 stage);
    event EncryptedDataPosted(uint256 indexed dayId, uint256 slot, bytes blob);
    event BalanceRevealed(uint256 indexed dayId, uint256 slot, uint64 bal);
    event DustAccrued(uint256 indexed dayId, uint256 amount);
    event DustSwept(uint256 amount);
    event FloorProposed(uint256 indexed slot, bytes32 floorCommit);
    event FloorSet(uint256 indexed slot);
    // Emitted when a member leaves through the escape hatch, with the amount paid out.
    event Escaped(uint256 indexed slot, uint256 amount);

    constructor(
        IERC20 _eeur,
        IHonkVerifier _day,
        IHonkVerifier _reveal,
        IGridTariff _tariff,
        address _operator,
        address _grid,
        address _floorAdmin,
        address _reserve,
        bytes32 _emptyNetputHash,
        bytes32 _zeroBalCommit
    ) {
        eeur = _eeur;
        dayVerifier = _day;
        revealVerifier = _reveal;
        tariff = _tariff;
        operator = _operator;
        grid = _grid;
        floorAdmin = _floorAdmin;
        reserve = _reserve;
        EMPTY_NETPUT_HASH = _emptyNetputHash;
        ZERO_BAL_COMMIT = _zeroBalCommit;
        deployDay = block.timestamp / 1 days;
    }

    // Restricts a function to the operator address.
    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }


    // Anyone can register, once per wallet, with a secp256k1 public key (compressed or not).
    // The new member starts with a zero balance commitment and a zero floor commitment.
    function register(bytes calldata encryptionKey) external {
        require(slotOf[msg.sender] == 0, "registered");
        require(
            (encryptionKey.length == 33 && (encryptionKey[0] == 0x02 || encryptionKey[0] == 0x03))
                || (encryptionKey.length == 65 && encryptionKey[0] == 0x04),
            "bad pubkey"
        );
        uint256 slot = ++prosumerCount;
        slotOf[msg.sender] = slot;
        ownerOf[slot] = msg.sender;
        encryptionKeyOf[slot] = encryptionKey;
        balCommitOf[slot] = ZERO_BAL_COMMIT;
        floorCommitOf[slot] = ZERO_BAL_COMMIT;
    }

    
    // pendingFloorCommit[slot]: floor commitment proposed by the operator, awaiting confirmation.
    mapping(uint256 => bytes32) public pendingFloorCommit; 

    // First signature on a floor: the operator proposes a commitment to the member's floor.
    function proposeFloor(uint256 slot, bytes32 floorCommit) external onlyOperator {
        require(slot != 0 && slot <= prosumerCount, "slot");
        pendingFloorCommit[slot] = floorCommit;
        emit FloorProposed(slot, floorCommit);
    }

    // Second signature: the floor administrator confirms the same commitment, which takes effect.
    function confirmFloor(uint256 slot, bytes32 floorCommit) external {
        require(msg.sender == floorAdmin, "not floor admin");
        require(pendingFloorCommit[slot] == floorCommit && floorCommit != bytes32(0), "no matching proposal");
        floorCommitOf[slot] = floorCommit;
        delete pendingFloorCommit[slot];
        emit FloorSet(slot);
    }

    // A member deposits tokens. They wait in pendingDeposit until a day's midnight freeze
    // includes them and that day settles. Amounts must be whole internal units.
    function deposit(uint256 amount) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(amount % WEI_PER_UNIT == 0, "amount not a whole pEUR");
        require(eeur.transferFrom(msg.sender, address(this), amount), "transfer");
        pendingDeposit[slot] += amount / WEI_PER_UNIT;
    }

    // A member asks for a withdrawal. It is paid at a later settlement, capped by the proof at
    // the balance available; the rest stays queued.
    function requestWithdraw(uint256 amount) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(amount % WEI_PER_UNIT == 0, "amount not a whole pEUR");
        pendingWithdrawal[slot] += amount / WEI_PER_UNIT;
    }

    // Day number of the current block, from the consensus timestamp.
    function currentDayId() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    // Session index (0 to 95) of the current block.
    function currentSessionIdx() public view returns (uint256) {
        return (block.timestamp % 1 days) / SESSION_SECONDS;
    }

    // The operator posts the aggregates (s, d) of the current session, in Wh. The contract reads
    // the band from the tariff, computes (r, c) with the pricing library, rounds them and
    // records everything. Only the session in progress can be opened.
    function openSession(uint256 dayId, uint256 t, uint32 s, uint32 d) external onlyOperator {
        require(t < SESSIONS, "t");
        require(!sessions[dayId][t].opened, "opened");
        require(dayId == currentDayId() && t == currentSessionIdx(), "clock");
        (UD60x18 lo, UD60x18 hi) = tariff.getPrices(block.timestamp);

        (UD60x18 rUd, UD60x18 cUd) = Pricing.prices(ud(uint256(s) * 1e18), ud(uint256(d) * 1e18), lo, hi);
 
        sessions[dayId][t] = Session(s, d, _priceDown(rUd), _priceUp(cUd), _priceUp(lo), _priceDown(hi), true);
        (uint32 r, uint32 c) = (sessions[dayId][t].priceR, sessions[dayId][t].priceC);
        emit SessionOpened(dayId, t, s, d, r, c);
    }

    // Number of batches for the current member count.
    function chunkCount() public view returns (uint256) {
        return (prosumerCount + BATCH - 1) / BATCH;
    }

    // Number of batches for a given day, from the member count frozen at its midnight.
    function chunkCountFor(uint256 dayId) public view returns (uint256) {
        return (dayCloses[dayId].prosumerCountAt + BATCH - 1) / BATCH;
    }

    // Midnight freeze. The operator posts one position commitment per member. In the same
    // transaction the contract freezes the member count, deposits, withdrawal requests and
    // floors, and opens the proof window. Days must close in order, one at a time.
    function postNetputHashes(uint256 dayId, bytes32[] calldata hashes) external onlyOperator {
        require(dayId < currentDayId(), "day not over");
        require(!netputHashesPosted[dayId], "posted");
        require(dayId > lastClosedDay, "out of order");
        require(lastClosedDay == 0 || dayCloses[lastClosedDay].state != DayState.Closing, "previous day still closing");
        require(hashes.length == prosumerCount, "len");
    
        for (uint256 i = 0; i < hashes.length; i++) {
            uint256 slot = i + 1;
            netputHashOf[dayId][slot] = hashes[i];
            snapDeposit[dayId][slot] = pendingDeposit[slot];
            snapWithdrawal[dayId][slot] = pendingWithdrawal[slot];
            snapFloorCommit[dayId][slot] = floorCommitOf[slot];
        }
        netputHashesPosted[dayId] = true;
        lastClosedDay = dayId;
        dayCloses[dayId].prosumerCountAt = prosumerCount;
        dayCloses[dayId].state = DayState.Closing;
        dayCloses[dayId].disputeDeadline = (dayId + 1) * 1 days + PROOF_WINDOW;
        emit NetputHashesPosted(dayId);
    }

    // What the prover sends with a batch proof: the outputs it claims.
    struct ChunkSubmission {
        bytes32[] newCommits; // new balance commitment of each lane
        uint256[] withdrawalsPaid; // withdrawal the proof allows for each lane
        uint32[SESSIONS] partialS; // the batch's share of s in every session
        uint32[SESSIONS] partialD; // the batch's share of d in every session
        uint256 partialPaidOut; // total the batch's sellers receive
        uint256 partialPaidIn; // total the batch's buyers pay
    }

    // Verifies the proof of batch k. The contract builds the public inputs itself from its
    // storage and the claimed outputs. If the proof holds, the batch's partial aggregates and
    // totals are added to the running sums, and its new commitments and payouts are staged.
    function submitChunk(uint256 dayId, uint256 k, ChunkSubmission calldata sub, bytes calldata proof) external {
        DayClose storage dc = dayCloses[dayId];
        require(dc.state == DayState.Closing, "state");
        require(k < chunkCountFor(dayId) && !chunkDone[dayId][k], "chunk");
        require(sub.newCommits.length == BATCH && sub.withdrawalsPaid.length == BATCH, "len");

        bytes32[] memory pub_ = _buildPublicInputs(dayId, k, sub);
        require(dayVerifier.verify(proof, pub_), "invalid proof");

        uint32[SESSIONS] storage aS = accS[dayId];
        uint32[SESSIONS] storage aD = accD[dayId];
        for (uint256 t = 0; t < SESSIONS; t++) {
            aS[t] += sub.partialS[t];
            aD[t] += sub.partialD[t];
        }
        dc.accPaidOut += sub.partialPaidOut;
        dc.accPaidIn += sub.partialPaidIn;

        for (uint256 i = 0; i < BATCH; i++) {
            uint256 slot = k * BATCH + i + 1;
            if (slot <= dc.prosumerCountAt) {
                stagedCommit[dayId][slot] = sub.newCommits[i];
                stagedWithdrawalPaid[dayId][slot] = sub.withdrawalsPaid[i];
            }
        }
        chunkDone[dayId][k] = true;
        dc.chunksVerified += 1;
        emit ChunkVerified(dayId, k);
    }

    // Settlement, callable by anyone once every batch is proven, the deadline has passed and no
    // request is pending. Checks the reconciliation, books the residual, applies the staged
    // commitments, consumes the frozen queues, pays withdrawals and settles the grid leg.
    function finalizeDay(uint256 dayId) external {
        DayClose storage dc = dayCloses[dayId];
        require(dc.state == DayState.Closing, "state");
        require(dc.chunksVerified == chunkCountFor(dayId), "chunks");
        require(block.timestamp >= dc.disputeDeadline, "dispute window");
        _requireNoPendingReveals(dayId);

        uint32[SESSIONS] storage aS = accS[dayId];
        uint32[SESSIONS] storage aD = accD[dayId];
        uint256 expectedOut;
        uint256 expectedIn;
     
        uint256 gridPay;
        uint256 gridRecv;
        for (uint256 t = 0; t < SESSIONS; t++) {
            Session storage ss = sessions[dayId][t];
            uint32 s_ = ss.opened ? ss.s : 0;
            uint32 d_ = ss.opened ? ss.d : 0;
            require(aS[t] == s_ && aD[t] == d_, "s/d mismatch");
            expectedOut += uint256(ss.priceR) * s_;
            expectedIn += uint256(ss.priceC) * d_;
            if (d_ > s_) {
                gridPay += uint256(ss.lambdaHi) * (d_ - s_);
            } else if (s_ > d_) {
                gridRecv += uint256(ss.lambdaLo) * (s_ - d_);
            }
        }

        require(dc.accPaidOut == expectedOut, "conservation out");
        require(dc.accPaidIn == expectedIn, "conservation in");

        uint256 dust = (dc.accPaidIn + gridRecv) - (dc.accPaidOut + gridPay);
        dustPot += dust;
        emit DustAccrued(dayId, dust);

        for (uint256 slot = 1; slot <= dc.prosumerCountAt; slot++) {
            balCommitOf[slot] = stagedCommit[dayId][slot];
            
            uint256 dep = snapDeposit[dayId][slot];
            if (dep > 0) pendingDeposit[slot] -= dep;

            uint256 wPaid = stagedWithdrawalPaid[dayId][slot];
            if (wPaid > 0) {
                pendingWithdrawal[slot] -= wPaid;
                require(eeur.transfer(ownerOf[slot], wPaid * WEI_PER_UNIT), "withdraw");
            }
        }
        _settleGridLeg(gridPay, gridRecv);

        dc.state = DayState.Finalized;
        emit DayFinalized(dayId, dc.accPaidOut, dc.accPaidIn);
    }

    // Cancellation, callable by anyone but only on verifiable grounds: proofs missing after the
    // deadline, a request left unanswered past its deadline (revealSlot names it), or settlement
    // still not done after the grace period with no request pending. Nothing moves.
    function cancelDay(uint256 dayId, uint256 revealSlot, string calldata reason) public {
        DayClose storage dc = dayCloses[dayId];
        require(dc.state == DayState.Closing, "state");
        bool timeout = block.timestamp > dc.disputeDeadline && dc.chunksVerified < chunkCountFor(dayId);
        bool revealTimeout = revealSlot != 0 && _revealTimedOut(dayId, revealSlot);
        bool stuck = block.timestamp > dc.disputeDeadline + SETTLEMENT_GRACE && openRevealCount[dayId] == 0;
        require(timeout || revealTimeout || stuck, "no ground");
        dc.state = DayState.Cancelled;
        emit DayCancelled(dayId, reason);
    }

    // Recourse, stage 1. A member asks the operator to publish its data for a closing day,
    // encrypted to its key. Settlement is blocked until the operator answers.
    function requestData(uint256 dayId) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(dayCloses[dayId].state == DayState.Closing, "state");
        // Only members frozen into that day can object to it. A wallet registered after
        // midnight has nothing to ask for, and could otherwise block settlement.
        require(slot <= dayCloses[dayId].prosumerCountAt, "not a member that day");
        require(block.timestamp < dayCloses[dayId].disputeDeadline, "objection window closed");
        RevealRequest storage r = reveals[dayId][slot];
        require(r.stage1Deadline == 0, "requested");
        r.stage1Deadline = uint64(block.timestamp + REVEAL_WINDOW);
        openRevealCount[dayId] += 1;
        emit DataRequested(dayId, slot, 1);
    }

    // The operator answers stage 1. The blob is not checked, it is only recorded in an event.
    function postEncryptedData(uint256 dayId, uint256 slot, bytes calldata blob) external onlyOperator {
        RevealRequest storage r = reveals[dayId][slot];
        require(r.stage1Deadline != 0 && !r.stage1Done, "no request");
        r.stage1Done = true;
        openRevealCount[dayId] -= 1;
        emit EncryptedDataPosted(dayId, slot, blob);
    }

    // Recourse, stage 2. After stage 1, a member asks for its balance to be opened in the clear.
    function requestClearReveal(uint256 dayId) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(dayCloses[dayId].state == DayState.Closing, "state");
        require(block.timestamp < dayCloses[dayId].disputeDeadline + REVEAL_WINDOW, "objection window closed");
        RevealRequest storage r = reveals[dayId][slot];
        require(r.stage1Done && r.stage2Deadline == 0, "stage1 first");
        r.stage2Deadline = uint64(block.timestamp + REVEAL_WINDOW);
        openRevealCount[dayId] += 1;
        emit DataRequested(dayId, slot, 2);
    }

    // Stage 2 answer: a reveal proof that the stated balance opens the member's commitment.
    // Uses the staged commitment if the member's batch is already proven, the settled one otherwise.
    function clearReveal(uint256 dayId, uint256 slot, uint64 bal, bytes calldata proof) external {
        RevealRequest storage r = reveals[dayId][slot];
        require(r.stage2Deadline != 0 && !r.stage2Done, "no request");
        bytes32 c = stagedCommit[dayId][slot] != bytes32(0) ? stagedCommit[dayId][slot] : balCommitOf[slot];
        bytes32[] memory pub_ = new bytes32[](2);
        pub_[0] = c;
        pub_[1] = bytes32(uint256(bal));
        require(revealVerifier.verify(proof, pub_), "invalid reveal");
        r.stage2Done = true;
        openRevealCount[dayId] -= 1;
        emit BalanceRevealed(dayId, slot, bal);
    }

    // True when members may leave on their own: no day has been settled for
    // ESCAPE_DELAY_DAYS days, no day is currently closing, and the contract is older
    // than that delay. It means the operator has stopped settling, so balances would
    // otherwise stay locked in the contract.
    function escapeAvailable() public view returns (bool) {
        uint256 today = currentDayId();
        if (today < deployDay + ESCAPE_DELAY_DAYS) return false;
        if (lastClosedDay != 0 && dayCloses[lastClosedDay].state == DayState.Closing) return false;
        for (uint256 i = 0; i < ESCAPE_DELAY_DAYS; i++) {
            if (dayCloses[today - i].state == DayState.Finalized) return false;
        }
        return true;
    }

    // Escape hatch. Once escapeAvailable() holds, a member proves its settled balance with
    // the reveal circuit, using the blinding factor from its own day-close packet, and is
    // paid that balance plus any deposit not yet applied. Its balance commitment is reset
    // to zero and its queues are emptied, so nothing can be claimed twice. No operator
    // action is needed. A day still closing must be settled or cancelled first.
    function escape(uint64 bal, bytes calldata proof) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(escapeAvailable(), "operator active");
        bytes32[] memory pub_ = new bytes32[](2);
        pub_[0] = balCommitOf[slot];
        pub_[1] = bytes32(uint256(bal));
        require(revealVerifier.verify(proof, pub_), "invalid reveal");

        uint256 amount = uint256(bal) + pendingDeposit[slot];
        balCommitOf[slot] = ZERO_BAL_COMMIT;
        pendingDeposit[slot] = 0;
        pendingWithdrawal[slot] = 0;
        if (amount > 0) {
            require(eeur.transfer(ownerOf[slot], amount * WEI_PER_UNIT), "escape");
        }
        emit Escaped(slot, amount);
    }

    // Sends the accumulated rounding residual to the reserve. Callable by anyone.
    function sweepDust() external {
        uint256 d = dustPot;
        require(d > 0, "no dust");
        dustPot = 0;
        require(eeur.transfer(reserve, d * WEI_PER_UNIT), "sweep");
        emit DustSwept(d);
    }

    // Assembles the 450 public inputs of a batch proof, in the order the circuit expects:
    // 96 seller rates, 96 buyer rates, then eight values per lane for slots, position
    // commitments, old and new balance commitments, deposits, withdrawal requests, withdrawals
    // paid and floor commitments, then the 2 x 96 partial aggregates and the two totals.
    // Lanes beyond the frozen member count are padding and get the neutral constants.
    function _buildPublicInputs(uint256 dayId, uint256 k, ChunkSubmission calldata sub)
        internal
        view
        returns (bytes32[] memory pub_)
    {
        uint256 n = SESSIONS * 4 + BATCH * 8 + 2; 
        pub_ = new bytes32[](n);
        uint256 nAt = dayCloses[dayId].prosumerCountAt; 
        uint256 i = 0;
        for (uint256 t = 0; t < SESSIONS; t++) {
            pub_[i++] = bytes32(uint256(sessions[dayId][t].priceR));
        }
        for (uint256 t = 0; t < SESSIONS; t++) {
            pub_[i++] = bytes32(uint256(sessions[dayId][t].priceC));
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = bytes32(slot <= nAt ? slot : 0);
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = slot <= nAt ? netputHashOf[dayId][slot] : EMPTY_NETPUT_HASH;
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = slot <= nAt ? balCommitOf[slot] : ZERO_BAL_COMMIT;
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = slot <= nAt ? sub.newCommits[j] : ZERO_BAL_COMMIT;
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = bytes32(slot <= nAt ? snapDeposit[dayId][slot] : 0); 
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = bytes32(slot <= nAt ? snapWithdrawal[dayId][slot] : 0); 
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
            pub_[i++] = bytes32(slot <= nAt ? sub.withdrawalsPaid[j] : 0); 
        }
        for (uint256 j = 0; j < BATCH; j++) {
            uint256 slot = k * BATCH + j + 1;
          
            pub_[i++] = slot <= nAt ? snapFloorCommit[dayId][slot] : ZERO_BAL_COMMIT;
        }
        for (uint256 t = 0; t < SESSIONS; t++) {
            pub_[i++] = bytes32(uint256(sub.partialS[t]));
        }
        for (uint256 t = 0; t < SESSIONS; t++) {
            pub_[i++] = bytes32(uint256(sub.partialD[t]));
        }
        pub_[i++] = bytes32(sub.partialPaidOut);
        pub_[i++] = bytes32(sub.partialPaidIn);
    }

    // Pays the grid for the day's net imports and pulls from it the value of net exports.
    // The grid account must have approved the contract for the pull.
    function _settleGridLeg(uint256 gridPay, uint256 gridRecv) internal {
        if (gridPay > 0) {
            require(eeur.transfer(grid, gridPay * WEI_PER_UNIT), "grid pay");
        }
        if (gridRecv > 0) {
            require(eeur.transferFrom(grid, address(this), gridRecv * WEI_PER_UNIT), "grid fund");
        }
    }

    // Settlement waits while any data request of the day is open.
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

    // Rounds an 18-decimal price down to the stored 32-bit grain. Used for the seller rate and
    // the retail bound, so that the market never pays out more than it collects.
    function _priceDown(UD60x18 p) internal pure returns (uint32) {
        uint256 v = UD60x18.unwrap(p) / PRICE_SCALE;
        require(v <= MAX_UNIT, "price overflow uint32");
        return uint32(v);
    }

    // Rounds up to the stored grain. Used for the buyer rate and the feed-in bound.
    function _priceUp(UD60x18 p) internal pure returns (uint32) {
        uint256 raw = UD60x18.unwrap(p);
        uint256 v = (raw + PRICE_SCALE - 1) / PRICE_SCALE;
        require(v <= MAX_UNIT, "price overflow uint32");
        return uint32(v);
    }
}
