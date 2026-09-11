// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title BaseSepoliaAddresses
/// @notice Verified **Base Sepolia TESTNET** (chain id 84532) addresses.
/// @dev TESTNET ONLY. The pool is backed by two ERC-4626 lending vaults; here they are Aave's
///      ERC-4626 wrappers, but any ERC-4626 vault pair works (Morpho, Euler v2, Spark, ...).
library BaseSepoliaAddresses {
    /// @notice Base Sepolia chain id.
    uint256 internal constant CHAIN_ID = 84532;

    /// @dev Uniswap v4 PoolManager on Base Sepolia.
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    /// @dev ERC-4626 lending vault for currency0; its `asset()` is WETH below.
    address internal constant VAULT0 = 0xde7820fFb73059608928cb9e29F6EB1369Ad1342; // Wrapped Aave WETH
    /// @dev ERC-4626 lending vault for currency1; its `asset()` is the USDC below.
    address internal constant VAULT1 = 0xf430cb6E2b85f99222fBFA6dFEa18Ff60FA6B32a; // Wrapped Aave USDC

    /// @dev Wrapped ETH; asset of VAULT0. Sorts before USDC, so it is currency0.
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    /// @dev Aave's Base Sepolia USDC **test asset** (not Circle USDC); asset of VAULT1.
    address internal constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;

    /// @dev Chainlink ETH/USD on Base Sepolia (used only to pick the initial pool price).
    address internal constant ETH_USD_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    /// @dev Chainlink USDC/USD on Base Sepolia (used only to pick the initial pool price).
    address internal constant USDC_USD_FEED = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;

    /// @dev Arachnid deterministic deployment proxy (present on Base Sepolia).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Pool fee (0.05%).
    uint24 internal constant FEE = 500;

    /// @dev Pool tick spacing.
    int24 internal constant TICK_SPACING = 10;
}
