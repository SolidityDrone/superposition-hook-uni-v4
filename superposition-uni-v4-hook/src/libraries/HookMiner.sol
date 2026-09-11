// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Mirrors Uniswap's v4 HookMiner: finds a CREATE2 salt so the deployed hook
///         address encodes the required permission bits in its low 14 bits.
/// @dev Uniswap v4 decides which callbacks to call from the hook address bits, and
///      `PoolManager.initialize` reverts unless they match (`Hooks.isValidHookAddress`).
library HookMiner {
    // Mask for the bottom 14 bits of the address.
    uint160 internal constant FLAG_MASK = Hooks.ALL_HOOK_MASK;

    // Bounded search to avoid an unbounded loop.
    uint256 internal constant MAX_ITERATIONS = 160_444;

    /// @param deployer The address that will deploy the hook. In tests this is the test
    ///        contract; in scripts it is the CREATE2 deployer proxy.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal view returns (address hookAddress, bytes32 salt) {
        flags = flags & FLAG_MASK;
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);

        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            address candidate = computeAddress(deployer, i, initCode);
            if (uint160(candidate) & FLAG_MASK == flags && candidate.code.length == 0) {
                return (candidate, bytes32(i));
            }
        }
        revert("HookMiner: no salt found");
    }

    function computeAddress(address deployer, uint256 salt, bytes memory initCode)
        internal
        pure
        returns (address candidate)
    {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, keccak256(initCode))))
            )
        );
    }
}
