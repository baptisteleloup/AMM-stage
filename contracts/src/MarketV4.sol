// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IHonkVerifier} from "./interfaces/IVerifier.sol";
import {IGridTariff} from "./interfaces/IGridTariff.sol";
import {Pricing} from "./Pricing.sol";

contract MarketV4 {
    uint256 public constant SESSIONS = 96;
    uint256 public constant BATCH = 8;
    uint256 public constant SESSION_SECONDS = 900; 
    uint256 public constant PRICE_SCALE = 1e11;
    uint256 public constant WEI_PER_UNIT = 1e6;
    uint256 public constant PROOF_WINDOW = 12 hours; 
    uint256 public constant REVEAL_WINDOW = 4 hours; 
    uint256 public constant SETTLEMENT_GRACE = 6 hours;
    uint256 public constant MAX_UNIT = type(uint32).max; 

    bytes32 public immutable EMPTY_NETPUT_HASH;
    bytes32 public immutable ZERO_BAL_COMMIT;

    IERC20 public immutable eeur;
    IHonkVerifier public immutable dayVerifier;
    IHonkVerifier public immutable revealVerifier;
    IGridTariff public immutable tariff;
    address public immutable operator; 
    address public immutable grid; 
    address public immutable floorAdmin;
    address public immutable reserve;

    uint256 public prosumerCount;
    mapping(address => uint256) public slotOf;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bytes) public encryptionKeyOf;
    mapping(uint256 => bytes32) public balCommitOf; 
    mapping(uint256 => bytes32) public floorCommitOf;
    mapping(uint256 => uint256) public pendingDeposit; 
    mapping(uint256 => uint256) public pendingWithdrawal;
    mapping(uint256 => mapping(uint256 => uint256)) public snapDeposit; 
    mapping(uint256 => mapping(uint256 => uint256)) public snapWithdrawal;
    mapping(uint256 => mapping(uint256 => bytes32)) public snapFloorCommit; 

    struct Session {
        uint32 s; 
        uint32 d; 
        uint32 priceR; 
        uint32 priceC; 
        uint32 lambdaLo; 
        uint32 lambdaHi; 
        bool opened;
    }
    mapping(uint256 => mapping(uint256 => Session)) public sessions;

    enum DayState {
        Pending,
        Closing,
        Finalized,
        Cancelled
    }

    struct DayClose {
        DayState state;
        uint256 chunksVerified;
        uint256 accPaidOut; 
        uint256 accPaidIn; 
        uint256 disputeDeadline;
        uint256 prosumerCountAt;
    }
    mapping(uint256 => DayClose) public dayCloses;
    mapping(uint256 => mapping(uint256 => bool)) public chunkDone;
    mapping(uint256 => uint32[SESSIONS]) internal accS;
    mapping(uint256 => uint32[SESSIONS]) internal accD;
    mapping(uint256 => mapping(uint256 => bytes32)) public stagedCommit;
    mapping(uint256 => mapping(uint256 => uint256)) public stagedWithdrawalPaid;
    mapping(uint256 => mapping(uint256 => bytes32)) public netputHashOf;
    mapping(uint256 => bool) public netputHashesPosted;

    struct RevealRequest {
        uint64 stage1Deadline; 
        uint64 stage2Deadline; 
        bool stage1Done;
        bool stage2Done;
    }
    mapping(uint256 => mapping(uint256 => RevealRequest)) public reveals; 
    mapping(uint256 => uint256) public openRevealCount;
    uint256 public lastClosedDay;
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
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }


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

    
    mapping(uint256 => bytes32) public pendingFloorCommit; 

    function proposeFloor(uint256 slot, bytes32 floorCommit) external onlyOperator {
        require(slot != 0 && slot <= prosumerCount, "slot");
        pendingFloorCommit[slot] = floorCommit;
        emit FloorProposed(slot, floorCommit);
    }

    function confirmFloor(uint256 slot, bytes32 floorCommit) external {
        require(msg.sender == floorAdmin, "not floor admin");
        require(pendingFloorCommit[slot] == floorCommit && floorCommit != bytes32(0), "no matching proposal");
        floorCommitOf[slot] = floorCommit;
        delete pendingFloorCommit[slot];
        emit FloorSet(slot);
    }

    function deposit(uint256 amount) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(amount % WEI_PER_UNIT == 0, "amount not a whole pEUR");
        require(eeur.transferFrom(msg.sender, address(this), amount), "transfer");
        pendingDeposit[slot] += amount / WEI_PER_UNIT;
    }

    function requestWithdraw(uint256 amount) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(amount % WEI_PER_UNIT == 0, "amount not a whole pEUR");
        pendingWithdrawal[slot] += amount / WEI_PER_UNIT;
    }

    function currentDayId() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function currentSessionIdx() public view returns (uint256) {
        return (block.timestamp % 1 days) / SESSION_SECONDS;
    }

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

    function chunkCount() public view returns (uint256) {
        return (prosumerCount + BATCH - 1) / BATCH;
    }

    function chunkCountFor(uint256 dayId) public view returns (uint256) {
        return (dayCloses[dayId].prosumerCountAt + BATCH - 1) / BATCH;
    }

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

    struct ChunkSubmission {
        bytes32[] newCommits;
        uint256[] withdrawalsPaid; 
        uint32[SESSIONS] partialS;
        uint32[SESSIONS] partialD;
        uint256 partialPaidOut;
        uint256 partialPaidIn;
    }

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

    function requestData(uint256 dayId) external {
        uint256 slot = slotOf[msg.sender];
        require(slot != 0, "not registered");
        require(dayCloses[dayId].state == DayState.Closing, "state");
        require(block.timestamp < dayCloses[dayId].disputeDeadline, "objection window closed");
        RevealRequest storage r = reveals[dayId][slot];
        require(r.stage1Deadline == 0, "requested");
        r.stage1Deadline = uint64(block.timestamp + REVEAL_WINDOW);
        openRevealCount[dayId] += 1;
        emit DataRequested(dayId, slot, 1);
    }

    function postEncryptedData(uint256 dayId, uint256 slot, bytes calldata blob) external onlyOperator {
        RevealRequest storage r = reveals[dayId][slot];
        require(r.stage1Deadline != 0 && !r.stage1Done, "no request");
        r.stage1Done = true;
        openRevealCount[dayId] -= 1;
        emit EncryptedDataPosted(dayId, slot, blob);
    }

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

    function sweepDust() external {
        uint256 d = dustPot;
        require(d > 0, "no dust");
        dustPot = 0;
        require(eeur.transfer(reserve, d * WEI_PER_UNIT), "sweep");
        emit DustSwept(d);
    }

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

    function _settleGridLeg(uint256 gridPay, uint256 gridRecv) internal {
        if (gridPay > 0) {
            require(eeur.transfer(grid, gridPay * WEI_PER_UNIT), "grid pay");
        }
        if (gridRecv > 0) {
            require(eeur.transferFrom(grid, address(this), gridRecv * WEI_PER_UNIT), "grid fund");
        }
    }

    function _requireNoPendingReveals(uint256 dayId) internal view {
        require(openRevealCount[dayId] == 0, "reveal pending");
    }

    function _revealTimedOut(uint256 dayId, uint256 slot) internal view returns (bool) {
        RevealRequest storage r = reveals[dayId][slot];
        if (r.stage1Deadline != 0 && !r.stage1Done && block.timestamp > r.stage1Deadline) return true;
        if (r.stage2Deadline != 0 && !r.stage2Done && block.timestamp > r.stage2Deadline) return true;
        return false;
    }

    function _priceDown(UD60x18 p) internal pure returns (uint32) {
        uint256 v = UD60x18.unwrap(p) / PRICE_SCALE;
        require(v <= MAX_UNIT, "price overflow uint32");
        return uint32(v);
    }

    function _priceUp(UD60x18 p) internal pure returns (uint32) {
        uint256 raw = UD60x18.unwrap(p);
        uint256 v = (raw + PRICE_SCALE - 1) / PRICE_SCALE;
        require(v <= MAX_UNIT, "price overflow uint32");
        return uint32(v);
    }
}
