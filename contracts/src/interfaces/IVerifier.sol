// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Barretenberg verifier interface
///   bb write_vk -b target/day_chunk.json -o target/vk
///   bb write_solidity_verifier -k target/vk -o DayChunkVerifier.sol
interface IHonkVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}
