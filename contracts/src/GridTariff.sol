// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import {IGridTariff} from "./interfaces/IGridTariff.sol";

contract GridTariff is IGridTariff {
   
    enum Mode {
        Schedule,
        Feed
    }

    uint256 constant SLOT = 900; // 15 minutes = 900 seconds
    uint256 constant DAY = 86400; // 96 slots, 86400 = 900 x 96

    Mode public immutable mode;
    address public immutable admin; // grid role, admin of the tariffs

    //French mode
    struct Schedule {
        UD60x18 feedIn; // lambda_low, constant across the day
        UD60x18 retailOffPeak; // lambda_high outside peak windows
        UD60x18 retailPeak; // lambda_high inside peak windows
        uint32[] winStart; // peak windows, seconds of day
        uint32[] winEnd;
    }

    Schedule current;
    Schedule pending;
    uint32 public pendingFromDay; 
    bool public hasPending;

    mapping(address => bool) public isReporter;
    uint256 public immutable quorum;

    mapping(uint32 => mapping(address => bool)) reported; 
    mapping(uint32 => mapping(bytes32 => uint256)) votes;
    mapping(uint32 => mapping(bytes32 => bool)) stored;
    mapping(uint32 => mapping(bytes32 => UD60x18[96])) lowVec;
    mapping(uint32 => mapping(bytes32 => UD60x18[96])) highVec;
    mapping(uint32 => bytes32) public activeHash; 
    uint32 public lastFinalizedDay; 

    event ScheduleUpdated(uint32 fromDay);
    event PricesSubmitted(uint32 indexed day, address indexed reporter, bytes32 hash);
    event PricesFinalized(uint32 indexed day, bytes32 hash);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

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


    function setSchedule(Schedule calldata s) external onlyAdmin {
        require(mode == Mode.Schedule, "not schedule mode");
        _storeSchedule(pending, s);
        pendingFromDay = uint32(block.timestamp / DAY) + 1;
        hasPending = true;
        emit ScheduleUpdated(pendingFromDay);
    }


    function submitDailyPrices(uint32 day, UD60x18[96] calldata low, UD60x18[96] calldata high) external {
        require(mode == Mode.Feed, "not feed mode");
        require(isReporter[msg.sender], "not reporter");
        require(day >= uint32(block.timestamp / DAY), "day in the past");
        require(!reported[day][msg.sender], "already reported");
        reported[day][msg.sender] = true;

        for (uint256 i = 0; i < 96; i++) {
            require(low[i].unwrap() <= high[i].unwrap(), "low > high");
        }

        bytes32 h = keccak256(abi.encode(low, high));
        if (!stored[day][h]) {
            lowVec[day][h] = low;
            highVec[day][h] = high;
            stored[day][h] = true;
        }
        votes[day][h] += 1;
        emit PricesSubmitted(day, msg.sender, h);

        if (votes[day][h] == quorum) {
            activeHash[day] = h;
            if (day > lastFinalizedDay) lastFinalizedDay = day;
            emit PricesFinalized(day, h);
        }
    }

    function getPrices(uint256 timestamp) public view returns (UD60x18 lambdaLow, UD60x18 lambdaHigh) {
        if (mode == Mode.Schedule) {
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

        uint32 day = uint32(timestamp / DAY);
        bytes32 h = activeHash[day];
        if (h == bytes32(0)) {
            day = lastFinalizedDay;
            h = activeHash[day];
        }
        require(h != bytes32(0), "no feed");
        uint256 slot = (timestamp % DAY) / SLOT;
        return (lowVec[day][h][slot], highVec[day][h][slot]);
    }

    function isStale(uint256 timestamp) external view returns (bool) {
        return mode == Mode.Feed && activeHash[uint32(timestamp / DAY)] == bytes32(0);
    }

    function _scheduleAt(uint32 day) internal view returns (Schedule storage) {
        if (hasPending && day >= pendingFromDay) return pending;
        return current;
    }

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
