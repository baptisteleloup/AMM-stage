// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { Pricing } from "./Pricing.sol";
import { IGridTariff } from "./IGridTariff.sol";

/// @title Market — sessions on commitments, permissionless settlement, daily netting
/// @notice Individual netputs stay off-chain: openSession publishes aggregates + a Merkle root.
///         settle() fixes prices (callable by anyone). Money moves once a day via
///         closeDay -> challenge window -> finalizeDay, on internal EEUR balances.

contract Market {

    uint256 constant SLOT = 900;    // 15 min
    uint256 constant DAY  = 86400;  // 96 slots
    uint256 constant DUST = 1e9;    // rounding tolerance on challenges

    struct Session {
        bool    opened;
        bool    settled;
        bytes32 netputRoot;   // Merkle root of leaves (prosumer, netput, salt)
        UD60x18 s;            // aggregate supply  (kWh)
        UD60x18 d;            // aggregate demand  (kWh)
        UD60x18 r;
        UD60x18 c;
        UD60x18 cTotal;
        UD60x18 rTotal;
    }

    struct DayBatch {
        bool      closed;
        bool      finalized;
        bool      cancelled;
        uint64    closedAt;
        bytes32   dayRoot;
        int256    net;        // sum of amounts = grid leg actually transferred
        address[] accounts;
        int256[]  amounts;    // net day payment, signed (EEUR 1e18)
    }

    mapping(uint64 => Session)  public sessions;    // sessionId = timestamp / 900
    mapping(uint32 => DayBatch) batches;            // day = timestamp / 86400
    mapping(uint32 => int256)   public dayNet;      // sum of (rTotal - cTotal), = grid leg
    mapping(uint32 => uint16)   public openedCount;
    mapping(uint32 => uint16)   public settledCount;
    mapping(uint32 => mapping(address => int256)) public batchAmountOf;
    mapping(uint32 => mapping(address => bool))   public inBatch;

    mapping(address => uint256) public balanceOf;      // internal EEUR ledger
    mapping(address => uint256) public pendingDebit;   // locked while a batch awaits finalization
    mapping(address => uint256) public floorOf;        // solvency floor (worst-case day * lambda_high)

    IERC20      public immutable token;
    IGridTariff public immutable tariff;
    address     public immutable grid;
    address     public immutable operator;      // metering only: openSession + closeDay
    uint64      public immutable challengeWindow;

    event SessionOpened(uint64 indexed sessionId, bytes32 netputRoot, UD60x18 s, UD60x18 d);
    event Settled(uint64 indexed sessionId, UD60x18 r, UD60x18 c, UD60x18 cTotal, UD60x18 rTotal);
    event Deposited(address indexed prosumer, uint256 amount);
    event Withdrawn(address indexed prosumer, uint256 amount);
    event DayClosed(uint32 indexed day, bytes32 dayRoot, uint256 accounts);
    event DayFinalized(uint32 indexed day, int256 gridLeg);
    event DayCancelled(uint32 indexed day, address indexed challenger);

    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }

    constructor(
        IERC20 _token,
        IGridTariff _tariff,
        address _grid,
        address _operator,
        uint64 _challengeWindow
    ) {
        token           = _token;
        tariff          = _tariff;
        grid            = _grid;
        operator        = _operator;
        challengeWindow = _challengeWindow;
    }

    // ---- balances ----

    function deposit(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        balanceOf[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(
            balanceOf[msg.sender] >= amount + pendingDebit[msg.sender] + floorOf[msg.sender],
            "locked or below floor"
        );
        balanceOf[msg.sender] -= amount;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// Replaces per-order collateral: withdrawals cannot go below the prosumer's worst case.
    function setFloor(address prosumer, uint256 floor) external onlyOperator {
        floorOf[prosumer] = floor;
    }

    // ---- session lifecycle ----

    function currentSessionId() public view returns (uint64) {
        return uint64(block.timestamp / SLOT);
    }

    /// One tx per session: aggregates + commitment. No individual netput on-chain.
    function openSession(uint64 sessionId, bytes32 netputRoot, UD60x18 s, UD60x18 d)
        external onlyOperator
    {
        uint64 cur = currentSessionId();
        require(sessionId == cur || sessionId + 1 == cur, "not current session"); // 1 slot grace
        Session storage S = sessions[sessionId];
        require(!S.opened, "already opened");
        S.opened     = true;
        S.netputRoot = netputRoot;
        S.s          = s;
        S.d          = d;
        openedCount[uint32(sessionId / 96)] += 1;
        emit SessionOpened(sessionId, netputRoot, s, d);
    }

    /// Permissionless: keepers race, first call wins, duplicates revert. Moves no money.
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

    // ---- daily netting ----

    /// Operator posts the per-prosumer day amounts. The contract cannot check each line
    /// (it has no netputs) but enforces budget balance: sum(amounts) == dayNet.
    function closeDay(
        uint32 day,
        bytes32 dayRoot,
        address[] calldata accounts,
        int256[] calldata amounts
    ) external onlyOperator {
        require(block.timestamp >= (uint256(day) + 1) * DAY, "day not over");
        require(accounts.length == amounts.length, "length mismatch");
        DayBatch storage B = batches[day];
        require(!B.closed, "already closed");
        require(settledCount[day] == openedCount[day], "unsettled sessions");

        int256 sum;
        for (uint256 i = 0; i < accounts.length; i++) {
            address a = accounts[i];
            require(!inBatch[day][a], "duplicate account");
            inBatch[day][a] = true;
            batchAmountOf[day][a] = amounts[i];
            sum += amounts[i];
            if (amounts[i] < 0) {
                uint256 debit = uint256(-amounts[i]);
                require(balanceOf[a] >= pendingDebit[a] + debit, "insufficient balance");
                pendingDebit[a] += debit;   // locked until finalize/cancel
            }
        }
        // pro-rata shares are floored off-chain: allow rounding dust, nothing more
        int256 gap = sum - dayNet[day];
        if (gap < 0) gap = -gap;
        require(uint256(gap) <= DUST * (accounts.length + 1), "budget balance violated");

        B.closed   = true;
        B.closedAt = uint64(block.timestamp);
        B.net      = sum;
        B.dayRoot  = dayRoot;
        B.accounts = accounts;
        B.amounts  = amounts;
        emit DayClosed(day, dayRoot, accounts.length);
    }

    /// Permissionless, after the challenge window. Applies balances and the grid leg.
    function finalizeDay(uint32 day) external {
        DayBatch storage B = batches[day];
        require(B.closed, "not closed");
        require(!B.finalized, "already finalized");
        require(!B.cancelled, "cancelled");
        require(block.timestamp >= B.closedAt + challengeWindow, "challenge window open");

        for (uint256 i = 0; i < B.accounts.length; i++) {
            address a = B.accounts[i];
            int256 amt = B.amounts[i];
            if (amt >= 0) {
                balanceOf[a] += uint256(amt);
            } else {
                balanceOf[a]    -= uint256(-amt);
                pendingDebit[a] -= uint256(-amt);
            }
        }

        // residual = net grid leg (Case II: grid pays feed-in, Case III: grid collects)
        int256 leg = B.net;
        if (leg > 0) {
            require(token.transferFrom(grid, address(this), uint256(leg)), "grid transfer failed");
        } else if (leg < 0) {
            require(token.transfer(grid, uint256(-leg)), "grid transfer failed");
        }

        B.finalized = true;
        emit DayFinalized(day, leg);
    }

    /// A prosumer reveals their leaves for every opened session of the day.
    /// If the recomputed total differs from the batch entry, the day is cancelled.
    function challenge(
        uint32 day,
        uint64[] calldata sessionIds,
        int256[] calldata netputs,
        bytes32[] calldata salts,
        bytes32[][] calldata proofs
    ) external {
        DayBatch storage B = batches[day];
        require(B.closed && !B.finalized && !B.cancelled, "no open batch");
        require(block.timestamp < B.closedAt + challengeWindow, "window over");
        require(sessionIds.length == openedCount[day], "must cover all sessions");
        require(netputs.length == sessionIds.length && salts.length == sessionIds.length
            && proofs.length == sessionIds.length, "length mismatch");

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

        int256 claimed = batchAmountOf[day][msg.sender]; // 0 if omitted from the batch
        int256 diff = truth - claimed;
        if (diff < 0) diff = -diff;
        require(uint256(diff) > DUST, "batch correct");

        for (uint256 i = 0; i < B.accounts.length; i++) {
            int256 amt = B.amounts[i];
            if (amt < 0) pendingDebit[B.accounts[i]] -= uint256(-amt);
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
        returns (bool closed, bool finalized, bool cancelled, uint64 closedAt, bytes32 dayRoot)
    {
        DayBatch storage B = batches[day];
        return (B.closed, B.finalized, B.cancelled, B.closedAt, B.dayRoot);
    }

    function decompose(int256 netput) public pure returns (uint256 supply, uint256 demand) {
        if (netput > 0)      supply = uint256(netput);
        else if (netput < 0) demand = uint256(-netput);
    }
}
