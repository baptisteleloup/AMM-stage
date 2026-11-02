// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

// Tests of the demo settlement token EnergyEuro: metadata, owner-only minting, transfers.
// Run from contracts/: forge test --match-path test/EnergyEuro.t.sol

import {Test} from "forge-std/Test.sol";
import {EnergyEuro} from "../src/EnergyEuro.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract EnergyEuroTest is Test {
    EnergyEuro token;
    address owner = address(this); // the test contract deploys the token, so it owns it
    address alice = address(0xA11CE);
    address mallory = address(0xBAD); // not the owner

    function setUp() public {
        token = new EnergyEuro();
    }

    // Name, symbol and 18 decimals match what MarketV4's unit conversion assumes; no initial supply.
    function test_metadata() public view {
        assertEq(token.name(), "Energy Euro");
        assertEq(token.symbol(), "EEUR");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
    }

    // The owner funds members and the grid account by minting.
    function test_ownerCanMint() public {
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    // Nobody else can create tokens.
    function test_nonOwnerCannotMint() public {
        vm.prank(mallory);
        vm.expectRevert();
        token.mint(mallory, 1_000_000e18);
    }

    // Minted tokens behave as a plain ERC-20, so members can deposit them into the market.
    function test_mintedTokensAreTransferable() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.transfer(mallory, 30e18);
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(mallory), 30e18);
    }
}
