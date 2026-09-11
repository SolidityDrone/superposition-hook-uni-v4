// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BaseSepoliaAddresses
/// @notice Verified **Base Sepolia TESTNET** (chain id 84532) addresses.
/// @dev TESTNET ONLY — this is not Base mainnet. The deployment script enforces the chain id.
library BaseSepoliaAddresses {
    /// @notice Base Sepolia chain id.
    uint256 internal constant CHAIN_ID = 84532;

    /// @dev Uniswap v4 PoolManager on Base Sepolia.
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    /// @dev Aave v3 Pool on Base Sepolia (BGD Labs address book).
    address internal constant AAVE_POOL = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;

    /// @dev Wrapped ETH. Sorts before the USDC below, so it is currency0.
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    /// @dev Aave's Base Sepolia USDC **test asset** — NOT the Circle USDC (`0x036CbD…`).
    ///      The pool is created with this token so the vault can actually supply it to Aave.
    address internal constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;

    /// @dev Aave interest-bearing WETH on Base Sepolia.
    address internal constant AWETH = 0x73a5bB60b0B0fc35710DDc0ea9c407031E31Bdbb;

    /// @dev Aave interest-bearing USDC on Base Sepolia.
    address internal constant AUSDC = 0x10F1A9D11CDf50041f3f8cB7191CBE2f31750ACC;

    /// @dev Chainlink ETH/USD on Base Sepolia (8 decimals).
    address internal constant ETH_USD_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;

    /// @dev Chainlink USDC/USD on Base Sepolia (8 decimals).
    address internal constant USDC_USD_FEED = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;

    /// @dev Arachnid deterministic deployment proxy (present on Base Sepolia).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev ETH/USDC pool fee (0.05%).
    uint24 internal constant FEE = 500;

    /// @dev ETH/USDC pool tick spacing.
    int24 internal constant TICK_SPACING = 10;
}
