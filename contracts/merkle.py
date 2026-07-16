"""Merkle trees for netput commitments. Mirrors test/utils/MerkleHelper.sol:
double-hashed leaves, sorted pairs, odd node carried up. OZ MerkleProof compatible."""

from eth_abi import encode
from eth_utils import keccak


def leaf(prosumer: str, netput: int, salt: bytes) -> bytes:
    # keccak256(bytes.concat(keccak256(abi.encode(prosumer, netput, salt))))
    return keccak(keccak(encode(["address", "int256", "bytes32"], [prosumer, netput, salt])))


def amount_leaf(prosumer: str, amount: int) -> bytes:
    # leaves of the dayRoot (informational, not verified on-chain)
    return keccak(keccak(encode(["address", "int256"], [prosumer, amount])))


def _hash_pair(a: bytes, b: bytes) -> bytes:
    return keccak(a + b) if a < b else keccak(b + a)


def _next_level(level: list[bytes]) -> list[bytes]:
    nxt = [_hash_pair(level[2 * i], level[2 * i + 1]) for i in range(len(level) // 2)]
    if len(level) % 2 == 1:
        nxt.append(level[-1])
    return nxt


def root(leaves: list[bytes]) -> bytes:
    assert leaves, "no leaves"
    level = list(leaves)
    while len(level) > 1:
        level = _next_level(level)
    return level[0]


def proof(leaves: list[bytes], index: int) -> list[bytes]:
    assert 0 <= index < len(leaves)
    path = []
    level = list(leaves)
    while len(level) > 1:
        sib = index + 1 if index % 2 == 0 else index - 1
        if sib < len(level):
            path.append(level[sib])
        index //= 2
        level = _next_level(level)
    return path
