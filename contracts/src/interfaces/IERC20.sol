// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// The three token calls MarketV4 needs from its settlement token.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool); // payouts
    function transferFrom(address from, address to, uint256 amount) external returns (bool); // deposits, grid pull
    function balanceOf(address who) external view returns (uint256);
}
