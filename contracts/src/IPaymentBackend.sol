// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

/// @notice Abstraction du backend monétaire. Le settlement en dépend,
///         sans connaître l'implémentation (token, registre interne, stablecoin...).
interface IPaymentBackend {
    /// @dev transfère `amount` de `from` vers `to`. Doit revert si échec.
    function pay(address from, address to, uint256 amount) external;

    /// @dev expose le token utilisé, pour qu'un contrat détenteur de fonds
    ///      (le Market) puisse s'auto-approuver.
    function tokenAddress() external view returns (address);
}