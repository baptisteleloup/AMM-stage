// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

// Grid band of the session containing a timestamp, in 18-decimal cents per kWh.
// Implemented by GridTariff, called by MarketV4.openSession.

import {UD60x18} from "@prb/math/src/UD60x18.sol";

interface IGridTariff {
    function getPrices(uint256 timestamp) external view returns (UD60x18 lambdaLow, UD60x18 lambdaHigh);
}
