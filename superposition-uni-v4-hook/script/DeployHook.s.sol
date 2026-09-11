// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {SuperpositionHook} from "../src/SuperpositionHook.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {BaseAddresses} from "./BaseAddresses.sol";

/// @notice Deploys the hook through the deterministic CREATE2 proxy and initializes the pool.
/// @dev Run with: forge script script/DeployHook.s.sol --rpc-url base --broadcast
contract DeployHook is Script {
    function run() external returns (SuperpositionHook hook) {
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        address owner = msg.sender;
        bytes memory args = _constructorArgs(owner);
        // The deterministic proxy is the CREATE2 deployer.
        (address predicted, bytes32 salt) = HookMiner.find(
            BaseAddresses.CREATE2_DEPLOYER, flags, type(SuperpositionHook).creationCode, args
        );

        bytes memory initCode = abi.encodePacked(type(SuperpositionHook).creationCode, args);
        uint160 sqrtPriceX96 = _sqrtPriceFromFeeds();

        vm.startBroadcast();
        (bool ok,) = BaseAddresses.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok, "create2 deployment failed");
        hook = SuperpositionHook(predicted);
        hook.initializePool(sqrtPriceX96);
        vm.stopBroadcast();

        require(address(hook).code.length > 0, "no code");
        console2.log("SuperpositionHook deployed at", address(hook));
        console2.log("pool initialized at sqrtPriceX96", uint256(sqrtPriceX96));
        console2.logBytes32(salt);
    }

    function _constructorArgs(address owner) internal pure returns (bytes memory) {
        return abi.encode(
            IPoolManager(BaseAddresses.POOL_MANAGER),
            BaseAddresses.AAVE_POOL,
            BaseAddresses.WETH,
            BaseAddresses.USDC,
            BaseAddresses.AWETH,
            BaseAddresses.AUSDC,
            IAggregatorV3(BaseAddresses.ETH_USD_FEED),
            IAggregatorV3(BaseAddresses.USDC_USD_FEED),
            owner
        );
    }

    /// @dev WETH is token0 and USDC token1, so price = ethUsd / (usdcUsd * 1e12).
    function _sqrtPriceFromFeeds() internal view returns (uint160) {
        (, int256 ethPrice,,,) = IAggregatorV3(BaseAddresses.ETH_USD_FEED).latestRoundData();
        (, int256 usdcPrice,,,) = IAggregatorV3(BaseAddresses.USDC_USD_FEED).latestRoundData();
        uint256 priceX192 =
            Math.mulDiv(uint256(ethPrice), uint256(1) << 192, uint256(usdcPrice) * 1e12);
        return uint160(Math.sqrt(priceX192));
    }
}
