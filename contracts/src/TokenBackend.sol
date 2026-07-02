// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPaymentBackend } from "./IPaymentBackend.sol";

/// @notice Backend de paiement adossé à un ERC-20 (EnergyEuro).
contract TokenBackend is IPaymentBackend {
    IERC20 public immutable token;

    constructor(IERC20 _token) {
        token = _token;
    }

    /// @dev utilise transferFrom : `from` doit avoir approve() ce contrat.
    function pay(address from, address to, uint256 amount) external {
        require(token.transferFrom(from, to, amount), "transfer failed");
    }
}