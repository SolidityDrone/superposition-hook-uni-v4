// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Minimal v4 swap router for tests: unlock -> swap -> settle/take.
contract TestSwapRouter {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;

    struct CallbackData {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        address payer;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 limit, address payer)
        external
        returns (BalanceDelta delta)
    {
        bytes memory result = manager.unlock(abi.encode(CallbackData(key, zeroForOne, amountSpecified, limit, payer)));
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        CallbackData memory data = abi.decode(raw, (CallbackData));

        BalanceDelta delta = manager.swap(
            data.key,
            IPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: data.amountSpecified,
                sqrtPriceLimitX96: data.sqrtPriceLimitX96
            }),
            ""
        );

        if (delta.amount0() < 0) {
            manager.sync(data.key.currency0);
            IERC20(Currency.unwrap(data.key.currency0)).safeTransferFrom(
                data.payer, address(manager), uint256(uint128(-delta.amount0()))
            );
            manager.settle();
        }
        if (delta.amount1() < 0) {
            manager.sync(data.key.currency1);
            IERC20(Currency.unwrap(data.key.currency1)).safeTransferFrom(
                data.payer, address(manager), uint256(uint128(-delta.amount1()))
            );
            manager.settle();
        }
        if (delta.amount0() > 0) {
            manager.take(data.key.currency0, data.payer, uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(data.key.currency1, data.payer, uint256(uint128(delta.amount1())));
        }

        return abi.encode(delta);
    }
}
