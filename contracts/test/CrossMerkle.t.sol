// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { Test } from "forge-std/Test.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { MerkleHelper } from "./utils/MerkleHelper.sol";

/// Cross-check against py/merkle.py (vector.json), 5 leaves = odd carry-up path.
contract CrossMerkleTest is Test {
    bytes32 constant PYROOT = 0x28e11616d1d1cccd94692ced6e0e9cc2d7014cb81914be22e2f9ad6671e147ae;
    bytes32 constant SALT = bytes32(uint256(42));

    function _leaves() internal pure returns (bytes32[] memory l) {
        int256[5] memory n = [int256(100e18), -55e18, int256(0), 7e17, -3e18];
        l = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            l[i] = MerkleHelper.leaf(address(uint160(16 + i)), n[i], SALT);
        }
    }

    function test_rootMatchesPython() public pure {
        assertEq(MerkleHelper.root(_leaves()), PYROOT);
    }

    function test_pythonProofVerifies() public pure {
        // proof for index 1, as emitted by py/merkle.py
        bytes32[] memory p = new bytes32[](3);
        p[0] = 0xf8a77c7b544e1b21ffd8b5e0fa4e781c0c4675d6b697bdcededa27b0cbcbd14f;
        p[1] = 0x280c5125c1f8dfe75e905e5bf05e45bf95f7201e6016c2baaf7b448988cb8520;
        p[2] = 0xc4f575806f08c78c59297079d4d5f4770fd9abcee2c892efbfbb5571c5565d53;
        assertTrue(MerkleProof.verify(p, PYROOT, _leaves()[1]));

        // proof for index 4 (carried node: depth 1)
        bytes32[] memory p4 = new bytes32[](1);
        p4[0] = 0x34265c34f5633bae569341b9d7ebb47468476f8b92744c5f43197aaac3ea956d;
        assertTrue(MerkleProof.verify(p4, PYROOT, _leaves()[4]));
    }
}
