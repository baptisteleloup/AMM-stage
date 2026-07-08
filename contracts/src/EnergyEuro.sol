// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title  EnergyEuro — Network currency
/// @notice Pilot mock : the owner (contract deployer) mints the EEUR
contract EnergyEuro is ERC20, Ownable {

    constructor() ERC20("Energy Euro", "EEUR") Ownable(msg.sender) {}

    /// @notice Émet `amount` tokens vers `to`. Réservé à l'owner.
    /// @dev amount en échelle 1e18
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}