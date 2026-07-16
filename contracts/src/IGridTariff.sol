// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { UD60x18 } from "@prb/math/src/UD60x18.sol";

/// @title IGridTariff — grid prices for the session containing `timestamp`
interface IGridTariff {
    function getPrices(uint256 timestamp)
        external view returns (UD60x18 lambdaLow, UD60x18 lambdaHigh);
}
