// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title  EnergyEuro — monnaie du réseau (euro tokenisé), mintable par l'owner.
/// @notice ERC-20 standard représentant l'euro sur le réseau AMM énergie.
///         Pour le pilote : l'owner (déployeur) émet les tokens et les distribue.
contract EnergyEuro is ERC20, Ownable {

    constructor() ERC20("Energy Euro", "EEUR") Ownable(msg.sender) {}

    /// @notice Émet `amount` tokens vers `to`. Réservé à l'owner.
    /// @dev amount en échelle 1e18
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}