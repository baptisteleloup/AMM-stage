// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test } from "forge-std/Test.sol";
import { EnergyEuro } from "../src/EnergyEuro.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract EnergyEuroTest is Test {
    EnergyEuro token;
    address owner = address(this); // le contrat de test déploie => il est owner
    address alice = address(0xA11CE);
    address mallory = address(0xBAD);

    function setUp() public {
        token = new EnergyEuro();
    }

    /// Métadonnées standard correctement initialisées.
    function test_metadata() public view {
        assertEq(token.name(), "Energy Euro");
        assertEq(token.symbol(), "EEUR");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0); // rien émis au départ
    }

    /// L'owner peut mint : le solde et le supply augmentent.
    function test_ownerCanMint() public {
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    /// Un non-owner NE PEUT PAS mint : l'appel revert.
    function test_nonOwnerCannotMint() public {
        vm.prank(mallory);
        vm.expectRevert();
        token.mint(mallory, 1_000_000e18);
    }

    /// Le mint alimente bien un transfert standard (sanity check d'intégration).
    function test_mintedTokensAreTransferable() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.transfer(mallory, 30e18);
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(mallory), 30e18);
    }
}