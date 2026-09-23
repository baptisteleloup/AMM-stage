// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {IGridTariff} from "./interfaces/IGridTariff.sol";

// Supplies the market contract with the tariff band (lambda_low, lambda_high) of every
// fifteen-minute session. The mode is chosen once, at deployment.
contract GridTariff is IGridTariff {

    // Schedule: a stable regulated tariff (e.g. peak / off-peak), transcribed by the admin.
    // Feed: prices that change every day (day-ahead), posted by reporters who vote on them.
    enum Mode {
        Schedule,
        Feed
    }

    uint256 constant SLOT = 900;   // length of a session: 900 s = 15 min
    uint256 constant DAY = 86400;  // length of a day: 96 sessions of 900 s

    // Feed mode: how many past days getPrices searches when the requested day has no
    // finalised prices and the latest finalised day lies in the future.
    uint32 constant MAX_LOOKBACK = 31;

    // Mode chosen at deployment
    Mode public immutable mode;

    // The only address allowed to change the tariff in Schedule mode (the grid role), nobody can replace it after deployment.
    address public immutable admin;

    // A complete tariff for Schedule mode.
    struct Schedule {
        UD60x18 feedIn;         // lambda_low: feed-in rate, the same all day
        UD60x18 retailOffPeak;  // lambda_high outside the peak windows
        UD60x18 retailPeak;     // lambda_high inside the peak windows
        uint32[] winStart;      // start of each peak window, in seconds after midnight
        uint32[] winEnd;        // end of each peak window (same index as winStart)
    }

    // Tariff in force. Set at deployment, then replaced by `pending` once that one has
    // taken effect and a newer tariff is announced (see setSchedule).
    Schedule current;

    // Tariff announced by the admin, which applies from pendingFromDay onward.
    Schedule pending;

    // Day number (timestamp / 86400) from which `pending` applies instead of `current`.
    uint32 public pendingFromDay;

    // True once a tariff has been announced at least once.
    bool public hasPending;

    // Reporters allowed to post prices in Feed mode. 
    mapping(address => bool) public isReporter;

    // Number of identical submissions needed to finalise the prices of a day.
    uint256 public immutable quorum;

    // reported[day][reporter]: has this reporter already submitted for this day?
    // Stops a reporter from voting twice.
    mapping(uint32 => mapping(address => bool)) reported;

    // votes[day][hash]: how many reporters submitted exactly these vectors for that day.
    mapping(uint32 => mapping(bytes32 => uint256)) votes;

    // stored[day][hash]: are the vectors of this candidate already in storage?
    // Avoids writing 2 x 96 values again for every vote on the same candidate.
    mapping(uint32 => mapping(bytes32 => bool)) stored;

    // lowVec[day][hash]: the 96 lambda_low values of the candidate with this hash.
    mapping(uint32 => mapping(bytes32 => UD60x18[96])) lowVec;

    // highVec[day][hash]: the 96 lambda_high values of the same candidate.
    mapping(uint32 => mapping(bytes32 => UD60x18[96])) highVec;

    // activeHash[day]: the candidate that reached the quorum, i.e. the official prices
    // of that day. Zero as long as no candidate has the quorum.
    mapping(uint32 => bytes32) public activeHash;

    // Highest day number that reached the quorum. May lie in the future, since
    // reporters can post ahead. Used by getPrices as a fallback (see below).
    uint32 public lastFinalizedDay;

    // Emitted when the admin announces a new tariff, with the day it will apply from.
    event ScheduleUpdated(uint32 fromDay);
    // Emitted on every vote: who submitted what, for which day.
    event PricesSubmitted(uint32 indexed day, address indexed reporter, bytes32 hash);
    // Emitted when a candidate reaches the quorum: the public record of the chosen prices.
    event PricesFinalized(uint32 indexed day, bytes32 hash);

    // Restricts a function to the admin address.
    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    // Deployment: sets the mode, the admin, the initial tariff, the reporters and the quorum.
    // In Feed mode the quorum must lie between 1 and the number of reporters.
    // In Schedule mode reporters and quorum are unused.
    constructor(Mode _mode, address _admin, Schedule memory initial, address[] memory reporters, uint256 _quorum) {
        mode = _mode;
        admin = _admin;
        _storeSchedule(current, initial);

        require(_mode == Mode.Schedule || (_quorum > 0 && _quorum <= reporters.length), "bad quorum");
        quorum = _quorum;
        for (uint256 i = 0; i < reporters.length; i++) {
            isReporter[reporters[i]] = true;
        }
    }

    // Schedule mode only. The admin announces a new tariff. It applies from the next
    // day, not immediately, and an event announces it, so members can check it first.
    function setSchedule(Schedule calldata s) external onlyAdmin {
        require(mode == Mode.Schedule, "not schedule mode");
        uint32 today = uint32(block.timestamp / DAY);
        // If the previously announced tariff is already in force, it becomes `current`
        // before being overwritten. Otherwise the rest of today would fall back to the
        // older `current`. A tariff announced but not yet in force is simply replaced.
        if (hasPending && today >= pendingFromDay) {
            _storeSchedule(current, pending);
        }
        _storeSchedule(pending, s);
        pendingFromDay = today + 1;
        hasPending = true;
        emit ScheduleUpdated(pendingFromDay);
    }

    // Feed mode only. A reporter submits the 96 price pairs of a day.
    // Each reporter votes once per day, and only for today or a later day.
    function submitDailyPrices(uint32 day, UD60x18[96] calldata low, UD60x18[96] calldata high) external {
        require(mode == Mode.Feed, "not feed mode");
        require(isReporter[msg.sender], "not reporter");
        require(day >= uint32(block.timestamp / DAY), "day in the past");
        require(!reported[day][msg.sender], "already reported");
        reported[day][msg.sender] = true;

        // Every session must satisfy lambda_low <= lambda_high, otherwise everything is rejected.
        for (uint256 i = 0; i < 96; i++) {
            require(low[i].unwrap() <= high[i].unwrap(), "low > high");
        }

        // The hash of the two vectors identifies the candidate. The vectors are stored
        // the first time the candidate is seen, then one vote is counted for it.
        bytes32 h = keccak256(abi.encode(low, high));
        if (!stored[day][h]) {
            lowVec[day][h] = low;
            highVec[day][h] = high;
            stored[day][h] = true;
        }
        votes[day][h] += 1;
        emit PricesSubmitted(day, msg.sender, h);

        // The first candidate to reach exactly the quorum becomes the prices of the day.
        if (votes[day][h] == quorum) {
            activeHash[day] = h;
            if (day > lastFinalizedDay) lastFinalizedDay = day;
            emit PricesFinalized(day, h);
        }
    }

    // Called by the market contract at every session opening.
    // Returns (lambda_low, lambda_high) for the given time.
    function getPrices(uint256 timestamp) public view returns (UD60x18 lambdaLow, UD60x18 lambdaHigh) {
        if (mode == Mode.Schedule) {
            // Schedule mode: take the tariff in force that day, then check whether the
            // time falls inside a peak window.
            Schedule storage s = _scheduleAt(uint32(timestamp / DAY));
            uint256 secOfDay = timestamp % DAY;
            UD60x18 high = s.retailOffPeak;
            for (uint256 i = 0; i < s.winStart.length; i++) {
                if (secOfDay >= s.winStart[i] && secOfDay < s.winEnd[i]) {
                    high = s.retailPeak;
                    break;
                }
            }
            return (s.feedIn, high);
        }

        // Feed mode: take the finalised prices of the day. If there are none, fall back
        // to the most recent finalised day that is not later than the requested one,
        // rather than stopping the market. A future day is never used as a fallback.
        uint32 day = uint32(timestamp / DAY);
        bytes32 h = activeHash[day];
        if (h == bytes32(0)) {
            if (lastFinalizedDay <= day) {
                // Common case: the latest finalised day is in the past.
                day = lastFinalizedDay;
                h = activeHash[day];
            } else {
                // Some later day is finalised but not this one: search backwards.
                for (uint32 k = 1; k <= MAX_LOOKBACK && k <= day; k++) {
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
        uint256 slot = (timestamp % DAY) / SLOT;   // session index within the day, 0 to 95
        return (lowVec[day][h][slot], highVec[day][h][slot]);
    }

    // True if, in Feed mode, the requested day has no finalised prices, that is if
    // getPrices is serving fallback prices.
    function isStale(uint256 timestamp) external view returns (bool) {
        return mode == Mode.Feed && activeHash[uint32(timestamp / DAY)] == bytes32(0);
    }

    // Picks the tariff in force on a given day: `pending` once it has taken effect,
    // `current` otherwise.
    function _scheduleAt(uint32 day) internal view returns (Schedule storage) {
        if (hasPending && day >= pendingFromDay) return pending;
        return current;
    }

    // Copies a tariff into storage after checking it: as many window starts as ends,
    // feed-in <= off-peak <= peak, and every window inside the day.
    function _storeSchedule(Schedule storage dst, Schedule memory src) internal {
        require(src.winStart.length == src.winEnd.length, "windows mismatch");
        require(src.feedIn.unwrap() <= src.retailOffPeak.unwrap(), "feedIn > offPeak");
        require(src.retailOffPeak.unwrap() <= src.retailPeak.unwrap(), "offPeak > peak");
        dst.feedIn = src.feedIn;
        dst.retailOffPeak = src.retailOffPeak;
        dst.retailPeak = src.retailPeak;
        delete dst.winStart;
        delete dst.winEnd;
        for (uint256 i = 0; i < src.winStart.length; i++) {
            require(src.winStart[i] < src.winEnd[i] && src.winEnd[i] <= DAY, "bad window");
            dst.winStart.push(src.winStart[i]);
            dst.winEnd.push(src.winEnd[i]);
        }
    }
}
