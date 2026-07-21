// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Interface des verifiers generes par Barretenberg :
///   bb write_vk -b target/day_chunk.json -o target/vk
///   bb write_solidity_verifier -k target/vk -o DayChunkVerifier.sol
/// (noms de sous-commandes a verifier contre `bb --help` de ta version)
interface IHonkVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}
