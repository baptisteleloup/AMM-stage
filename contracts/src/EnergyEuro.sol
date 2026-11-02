// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

// Demo settlement token (EEUR, 18 decimals). The deployer owns it and mints balances for the
// members and the grid account. A real deployment would use an existing stablecoin instead.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract EnergyEuro is ERC20, Ownable {
    constructor() ERC20("Energy Euro", "EEUR") Ownable(msg.sender) {}

    // Owner only: creates tokens for a member or the grid account.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
