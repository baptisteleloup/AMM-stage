// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pricing } from "./Pricing.sol";
import { IPaymentBackend } from "./IPaymentBackend.sol";

/// @title Market — orders collection, aggregation, and settlement
/// @notice Metering submits the confirmed orders and then triggers settlement.
///         Buyers post worst-case collateral, which is refunded at settlement for solvency management.

contract Market {

    struct Order {
        int256 netput;  
        bool exists;
    }

    mapping(address => Order)   public orderOf;
    mapping(address => uint256) public collateralOf;   // blocked EEUR 
    address[] public prosumers;

    UD60x18 public lambdaLow;    // feed-in (grid buys)
    UD60x18 public lambdaHigh;   // retail  (grid sells)

    IPaymentBackend public immutable backend;
    address public immutable grid;         // grid 
    address public immutable operator;     // metering (orchestrator)

    event OrderSubmitted(address indexed prosumer, int256 netput);
    event CollateralLocked(address indexed prosumer, uint256 amount);
    event Settled(UD60x18 cTotal, UD60x18 rTotal);

    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }

    constructor(
        UD60x18 _lambdaLow,
        UD60x18 _lambdaHigh,
        IPaymentBackend _backend,
        address _grid,
        address _operator
    ) {
        require(_lambdaLow.unwrap() <= _lambdaHigh.unwrap(), "lambdaLow > lambdaHigh");
        lambdaLow  = _lambdaLow;
        lambdaHigh = _lambdaHigh;
        backend    = _backend;
        grid       = _grid;
        operator   = _operator;

        IERC20(_backend.tokenAddress()).approve(address(_backend), type(uint256).max);
    }

    /// Updates the grid prices before a session (re-anchoring)
    function setGridPrices(UD60x18 _low, UD60x18 _high) external onlyOperator {
        require(_low.unwrap() <= _high.unwrap(), "low > high");
        lambdaLow = _low;
        lambdaHigh = _high;
    }

    /// Submits a prosumer's confirmed order. Locks their collateral if they make a purchase.
    /// The prosumer must have approved the backend beforehand.
    function submitOrder(address prosumer, int256 netput) external onlyOperator {
        if (!orderOf[prosumer].exists) {
            prosumers.push(prosumer);
        }

        // Resubmission: Return the old collateral before re-locking it
        uint256 old = collateralOf[prosumer];
        if (old > 0) {
            collateralOf[prosumer] = 0;
            backend.pay(address(this), prosumer, old);
        }

        orderOf[prosumer] = Order({ netput: netput, exists: true });

        // Buyer collateral = demand * retail price (maximum possible cost)
        (, uint256 dn) = decompose(netput);
        if (dn > 0) {
            uint256 required = ud(dn).mul(lambdaHigh).unwrap();
            backend.pay(prosumer, address(this), required);
            collateralOf[prosumer] = required;
            emit CollateralLocked(prosumer, required);
        }


        //wannings system

        emit OrderSubmitted(prosumer, netput);
    }

    /// Distribute costs and revenues, reimburse collateral, reset.
    function settle() external onlyOperator {
        (UD60x18 s, UD60x18 d) = aggregate();
        (UD60x18 cTotalUD, UD60x18 rTotalUD) = Pricing.totals(s, d, lambdaLow, lambdaHigh);

        uint256 cTotal = cTotalUD.unwrap();
        uint256 rTotal = rTotalUD.unwrap();
        uint256 sAgg   = s.unwrap();
        uint256 dAgg   = d.unwrap();

        for (uint256 i = 0; i < prosumers.length; i++) {
            address p = prosumers[i];
            (uint256 sn, uint256 dn) = decompose(orderOf[p].netput);

            if (sn > 0) {
                uint256 share = rTotal * sn / sAgg;
                backend.pay(grid, p, share);
            } else if (dn > 0) {
                uint256 cost   = cTotal * dn / dAgg;
                uint256 locked = collateralOf[p];
                if (cost > locked) cost = locked;   // rounding safety
                collateralOf[p] = 0;
                backend.pay(address(this), grid, cost);
                if (locked > cost) {
                    backend.pay(address(this), p, locked - cost);
                }
            }
        }

        emit Settled(cTotalUD, rTotalUD);
        _resetSession();
    }

    //Problem to privacy (encrypt electricity consumption) 

    /// Empty orders
    function _resetSession() internal {
        for (uint256 i = 0; i < prosumers.length; i++) {
            delete orderOf[prosumers[i]];
            delete collateralOf[prosumers[i]];
        }
        delete prosumers;
    }

    /// Aggregates offer and demand
    function aggregate() public view returns (UD60x18 s, UD60x18 d) {
        uint256 totalS;
        uint256 totalD;
        for (uint256 i = 0; i < prosumers.length; i++) {
            (uint256 sn, uint256 dn) = decompose(orderOf[prosumers[i]].netput);
            totalS += sn;
            totalD += dn;
        }
        s = ud(totalS);
        d = ud(totalD);
    }

    /// Clearing prices (r, c)
    function clearingPrices() external view returns (UD60x18 r, UD60x18 c) {
        (UD60x18 s, UD60x18 d) = aggregate();
        (r, c) = Pricing.prices(s, d, lambdaLow, lambdaHigh);
    }

    /// Settlement totals
    function settlementTotals() external view returns (UD60x18 cTotal, UD60x18 rTotal) {
        (UD60x18 s, UD60x18 d) = aggregate();
        (cTotal, rTotal) = Pricing.totals(s, d, lambdaLow, lambdaHigh);
    }

    /// decomposes a signed netput into non-negative (supply, demand) components.
    function decompose(int256 netput) public pure returns (uint256 supply, uint256 demand) {
        if (netput > 0)      supply = uint256(netput);
        else if (netput < 0) demand = uint256(-netput);
    }

    function prosumerCount() external view returns (uint256) {
        return prosumers.length;
    }
}


//AMM with a recovery mode, assume that the community is connected to the grid. 
//Fast regime, receovery regime
//Recovery regime, the community is disconnected from the grid and supply/demand has to be matched internally. Auction, deal with negative prices. 
//Protocol : Thundrella https://eprint.iacr.org/2017/913.pdf





