// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {SuperpositionHook} from "../src/SuperpositionHook.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {BaseSepoliaAddresses} from "./BaseSepoliaAddresses.sol";

/// @title DeployHook
/// @notice Deploys `SuperpositionHook` to **Base Sepolia (TESTNET)** through the deterministic
///         CREATE2 proxy and initializes the ETH/USDC pool.
/// @dev TESTNET ONLY. The script reverts unless the chain id is Base Sepolia (84532).
///
///      forge script script/DeployHook.s.sol --rpc-url base_sepolia --broadcast --private-key <KEY>
contract DeployHook is Script {
    function run() external returns (SuperpositionHook hook) {
        require(
            block.chainid == BaseSepoliaAddresses.CHAIN_ID, "DeployHook: not Base Sepolia testnet"
        );

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        address owner = msg.sender;
        bytes memory args = _constructorArgs(owner);
        // The deterministic proxy is the CREATE2 deployer, so mine against it.
        (address predicted, bytes32 salt) = HookMiner.find(
            BaseSepoliaAddresses.CREATE2_DEPLOYER, flags, type(SuperpositionHook).creationCode, args
        );

        bytes memory initCode = abi.encodePacked(type(SuperpositionHook).creationCode, args);
        uint160 sqrtPriceX96 = _sqrtPriceFromFeeds();

        vm.startBroadcast();
        (bool ok,) = BaseSepoliaAddresses.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok, "create2 deployment failed");
        hook = SuperpositionHook(predicted);
        hook.initializePool(sqrtPriceX96);
        vm.stopBroadcast();

        require(address(hook).code.length > 0, "no code");
        console2.log("SuperpositionHook deployed to Base Sepolia (TESTNET)", address(hook));
        console2.log("pool initialized at sqrtPriceX96", uint256(sqrtPriceX96));
        console2.logBytes32(salt);
    }

    function _constructorArgs(address owner) internal pure returns (bytes memory) {
        return abi.encode(
            IPoolManager(BaseSepoliaAddresses.POOL_MANAGER),
            BaseSepoliaAddresses.AAVE_POOL,
            BaseSepoliaAddresses.WETH,
            BaseSepoliaAddresses.USDC,
            BaseSepoliaAddresses.AWETH,
            BaseSepoliaAddresses.AUSDC,
            IAggregatorV3(BaseSepoliaAddresses.ETH_USD_FEED),
            IAggregatorV3(BaseSepoliaAddresses.USDC_USD_FEED),
            owner
        );
    }

    /// @dev WETH is token0 and USDC token1, so price = ethUsd / (usdcUsd * 1e12).
    function _sqrtPriceFromFeeds() internal view returns (uint160) {
        (, int256 ethPrice,,,) = IAggregatorV3(BaseSepoliaAddresses.ETH_USD_FEED).latestRoundData();
        (, int256 usdcPrice,,,) =
            IAggregatorV3(BaseSepoliaAddresses.USDC_USD_FEED).latestRoundData();
        uint256 priceX192 =
            Math.mulDiv(uint256(ethPrice), uint256(1) << 192, uint256(usdcPrice) * 1e12);
        return uint160(Math.sqrt(priceX192));
    }
}
