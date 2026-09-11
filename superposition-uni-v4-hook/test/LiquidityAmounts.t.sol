// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Exercises the canonical Uniswap v4 periphery liquidity math in the two directions
///         the hook relies on: liquidity from amounts, and amounts from liquidity.
contract LiquidityAmountsTest is Test {
    uint160 internal constant SPOT = 1 << 96; // price == 1

    function _ticks() internal pure returns (uint160 lower, uint160 upper) {
        lower = TickMath.getSqrtPriceAtTick(-60);
        upper = TickMath.getSqrtPriceAtTick(60);
    }

    function test_in_range_round_trip() public pure {
        (uint160 lower, uint160 upper) = _ticks();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(SPOT, lower, upper, 1e18, 1e18);
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(SPOT, upper, liquidity, true);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(lower, SPOT, liquidity, true);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertLe(amount0, 1e18);
        assertLe(amount1, 1e18);
    }

    function test_below_range_needs_only_token0() public pure {
        (uint160 lower, uint160 upper) = _ticks();
        uint160 spot = TickMath.getSqrtPriceAtTick(-120); // below the range
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(spot, lower, upper, 1e18, 0);
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(lower, upper, liquidity, true);
        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertLe(amount0, 1e18);
    }

    function test_above_range_needs_only_token1() public pure {
        (uint160 lower, uint160 upper) = _ticks();
        uint160 spot = TickMath.getSqrtPriceAtTick(120); // above the range
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(spot, lower, upper, 0, 1e18);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(lower, upper, liquidity, true);
        assertGt(liquidity, 0);
        assertGt(amount1, 0);
        assertLe(amount1, 1e18);
    }
}
