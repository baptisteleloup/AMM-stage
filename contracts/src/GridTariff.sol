// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

// Grid tariff band (lambda_low, lambda_high) of every fifteen-minute session, read by MarketV4 at
// each session opening. Schedule mode: a regulated peak / off-peak tariff set by the admin.
// Feed mode: day-ahead prices posted by reporters and adopted once a quorum agrees on them.

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {IGridTariff} from "./interfaces/IGridTariff.sol";

contract GridTariff is IGridTariff {
    enum Mode {
        Schedule, // stable tariff, transcribed by the admin
        Feed // daily prices, voted by reporters
    }

    uint256 constant SLOT = 900; // session length, s
    uint256 constant DAY = 86400; // day length, s (96 sessions)
    uint32 constant MAX_LOOKBACK = 31; // feed mode: days searched back for fallback prices

    Mode public immutable mode; // fixed at deployment
    address public immutable admin; // grid role, sole author of schedules, cannot be replaced

    // A complete tariff for Schedule mode.
    struct Schedule {
        UD60x18 feedIn; // lambda_low, the same all day
        UD60x18 retailOffPeak; // lambda_high outside the peak windows
        UD60x18 retailPeak; // lambda_high inside the peak windows
        uint32[] winStart; // start of each peak window, seconds after midnight
        uint32[] winEnd; // end of each peak window, same index as winStart
    }

    Schedule current; // tariff in force until `pending` takes effect
    Schedule pending; // tariff announced by the admin, in force from pendingFromDay
    uint32 public pendingFromDay; // day number (timestamp / 86400) from which `pending` applies
    bool public hasPending; // a tariff has been announced at least once

    mapping(address => bool) public isReporter; // feed mode: who may post prices
    uint256 public immutable quorum; // identical submissions needed to adopt a day's prices

    mapping(uint32 => mapping(address => bool)) reported; // [day][reporter] one vote per reporter and day
    mapping(uint32 => mapping(bytes32 => uint256)) votes; // [day][hash] votes for this candidate
    mapping(uint32 => mapping(bytes32 => bool)) stored; // [day][hash] vectors already stored, written once
    mapping(uint32 => mapping(bytes32 => UD60x18[96])) lowVec; // [day][hash] the 96 lambda_low of the candidate
    mapping(uint32 => mapping(bytes32 => UD60x18[96])) highVec; // [day][hash] the 96 lambda_high
    mapping(uint32 => bytes32) public activeHash; // [day] candidate that reached the quorum, 0 if none
    uint32 public lastFinalizedDay; // highest day with adopted prices, may lie in the future

    event ScheduleUpdated(uint32 fromDay); // new tariff announced, with the day it applies from
    event PricesSubmitted(uint32 indexed day, address indexed reporter, bytes32 hash); // one vote
    event PricesFinalized(uint32 indexed day, bytes32 hash); // public record of the adopted prices

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    // Sets the mode, admin, initial tariff, reporters and quorum. Reporters and quorum are unused in Schedule mode.
    constructor(Mode _mode, address _admin, Schedule memory initial, address[] memory reporters, uint256 _quorum) {
        mode = _mode;
        admin = _admin;
        _storeSchedule(current, initial);

        // feed: 1 <= quorum <= reporters
        require(_mode == Mode.Schedule || (_quorum > 0 && _quorum <= reporters.length), "bad quorum");
        quorum = _quorum;
        for (uint256 i = 0; i < reporters.length; i++) {
            isReporter[reporters[i]] = true;
        }
    }

    // Schedule mode: the admin announces a new tariff, in force from the next day so members can check it first.
    function setSchedule(Schedule calldata s) external onlyAdmin {
        require(mode == Mode.Schedule, "not schedule mode");
        uint32 today = uint32(block.timestamp / DAY);
        if (hasPending && today >= pendingFromDay) {
            _storeSchedule(current, pending); // the announced tariff is in force: keep it as current before replacing
        }
        _storeSchedule(pending, s); // a tariff not yet in force is simply replaced
        pendingFromDay = today + 1;
        hasPending = true;
        emit ScheduleUpdated(pendingFromDay);
    }

    // Feed mode: a reporter submits the 96 price pairs of today or a later day, once per day.
    function submitDailyPrices(uint32 day, UD60x18[96] calldata low, UD60x18[96] calldata high) external {
        require(mode == Mode.Feed, "not feed mode");
        require(isReporter[msg.sender], "not reporter");
        require(day >= uint32(block.timestamp / DAY), "day in the past");
        require(!reported[day][msg.sender], "already reported");
        reported[day][msg.sender] = true;

        for (uint256 i = 0; i < 96; i++) {
            require(low[i].unwrap() <= high[i].unwrap(), "low > high"); // every session must be a valid band
        }

        bytes32 h = keccak256(abi.encode(low, high)); // identifies the candidate
        if (!stored[day][h]) {
            lowVec[day][h] = low; // stored on its first vote only
            highVec[day][h] = high;
            stored[day][h] = true;
        }
        votes[day][h] += 1;
        emit PricesSubmitted(day, msg.sender, h);

        if (votes[day][h] == quorum) { // the first candidate to reach the quorum wins
            activeHash[day] = h;
            if (day > lastFinalizedDay) lastFinalizedDay = day;
            emit PricesFinalized(day, h);
        }
    }

    // Band of the session containing `timestamp`. Called by MarketV4.openSession.
    function getPrices(uint256 timestamp) public view returns (UD60x18 lambdaLow, UD60x18 lambdaHigh) {
        if (mode == Mode.Schedule) {
            Schedule storage s = _scheduleAt(uint32(timestamp / DAY)); // tariff in force that day
            uint256 secOfDay = timestamp % DAY;
            UD60x18 high = s.retailOffPeak;
            for (uint256 i = 0; i < s.winStart.length; i++) {
                if (secOfDay >= s.winStart[i] && secOfDay < s.winEnd[i]) { // inside a peak window
                    high = s.retailPeak;
                    break;
                }
            }
            return (s.feedIn, high);
        }

        // Feed mode: adopted prices of the day, else those of the latest earlier adopted day,
        // so the market keeps running. A future day is never used.
        uint32 day = uint32(timestamp / DAY);
        bytes32 h = activeHash[day];
        if (h == bytes32(0)) {
            if (lastFinalizedDay <= day) {
                day = lastFinalizedDay; // usual case: the latest adopted day is in the past
                h = activeHash[day];
            } else {
                for (uint32 k = 1; k <= MAX_LOOKBACK && k <= day; k++) { // a later day is adopted: search backwards
                    bytes32 past = activeHash[day - k];
                    if (past != bytes32(0)) {
                        day = day - k;
                        h = past;
                        break;
                    }
                }
            }
        }
        require(h != bytes32(0), "no feed");
        uint256 slot = (timestamp % DAY) / SLOT; // session index, 0 to 95
        return (lowVec[day][h][slot], highVec[day][h][slot]);
    }

    // True in feed mode when the day has no adopted prices, i.e. getPrices serves fallback prices.
    function isStale(uint256 timestamp) external view returns (bool) {
        return mode == Mode.Feed && activeHash[uint32(timestamp / DAY)] == bytes32(0);
    }

    // Tariff in force on a day: `pending` once it has taken effect, `current` otherwise.
    function _scheduleAt(uint32 day) internal view returns (Schedule storage) {
        if (hasPending && day >= pendingFromDay) return pending;
        return current;
    }

    // Checks a tariff and copies it into storage.
    function _storeSchedule(Schedule storage dst, Schedule memory src) internal {
        require(src.winStart.length == src.winEnd.length, "windows mismatch");
        require(src.feedIn.unwrap() <= src.retailOffPeak.unwrap(), "feedIn > offPeak"); // feed-in <= off-peak <= peak
        require(src.retailOffPeak.unwrap() <= src.retailPeak.unwrap(), "offPeak > peak");
        dst.feedIn = src.feedIn;
        dst.retailOffPeak = src.retailOffPeak;
        dst.retailPeak = src.retailPeak;
        delete dst.winStart; // drop the previous windows
        delete dst.winEnd;
        for (uint256 i = 0; i < src.winStart.length; i++) {
            require(src.winStart[i] < src.winEnd[i] && src.winEnd[i] <= DAY, "bad window"); // non-empty, inside the day
            dst.winStart.push(src.winStart[i]);
            dst.winEnd.push(src.winEnd[i]);
        }
    }
}
