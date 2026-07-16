// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

/// @notice Builds the same trees as the operator client (sorted pairs, OZ-compatible).
///         Odd node at a level is carried up without hashing.
library MerkleHelper {

    function leaf(address prosumer, int256 netput, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(prosumer, netput, salt))));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "no leaves");
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _nextLevel(level);
        }
        return level[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory) {
        require(index < leaves.length, "bad index");
        bytes32[] memory path = new bytes32[](_depth(leaves.length));
        uint256 n;
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 sib = index % 2 == 0 ? index + 1 : index - 1;
            if (sib < level.length) {
                path[n++] = level[sib];
            }
            index /= 2;
            level = _nextLevel(level);
        }
        // trim to actual length (carried nodes skip a sibling)
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = path[i];
        return out;
    }

    function _nextLevel(bytes32[] memory level) private pure returns (bytes32[] memory) {
        uint256 len = (level.length + 1) / 2;
        bytes32[] memory next = new bytes32[](len);
        for (uint256 i = 0; i < level.length / 2; i++) {
            next[i] = _hashPair(level[2 * i], level[2 * i + 1]);
        }
        if (level.length % 2 == 1) next[len - 1] = level[level.length - 1];
        return next;
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _depth(uint256 n) private pure returns (uint256 d) {
        while (n > 1) { n = (n + 1) / 2; d++; }
    }
}
