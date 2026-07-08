// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

/// @notice Monetary Backend.
interface IPaymentBackend {
    /// @dev transfer `amount` from `from` to `to`. Revert if fail.
    function pay(address from, address to, uint256 amount) external;

    /// @dev exposes the token used
    function tokenAddress() external view returns (address);
}