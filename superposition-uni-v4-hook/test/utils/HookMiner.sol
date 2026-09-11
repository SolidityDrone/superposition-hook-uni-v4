// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Finds a CREATE2 salt such that the deployed hook address encodes the required permission bits.
library HookMiner {
    uint160 internal constant FLAG_MASK = (1 << 14) - 1;
    uint256 internal constant MAX_ITERATIONS = 200_000;

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        flags = flags & FLAG_MASK;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            salt = bytes32(i);
            address candidate =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, initCodeHash)))));
            if (uint160(candidate) & FLAG_MASK == flags) {
                return (candidate, salt);
            }
        }
        revert("HookMiner: no salt found");
    }
}
