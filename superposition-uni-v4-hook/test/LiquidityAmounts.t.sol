// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";

contract LiquidityAmountsTest is Test {
    uint160 internal constant SPOT = 1 << 96; // price == 1

    function _ticks() internal pure returns (uint160 lower, uint160 upper) {
        lower = TickMath.getSqrtPriceAtTick(-60);
        upper = TickMath.getSqrtPriceAtTick(60);
    }

    function test_in_range_round_trip() public pure {
        (uint160 lower, uint160 upper) = _ticks();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(SPOT, lower, upper, 1e18, 1e18);
        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(SPOT, lower, upper, liquidity);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertLe(amount0, 1e18);
        assertLe(amount1, 1e18);
    }

    function test_below_range_is_token0_only() public pure {
        (uint160 lower, uint160 upper) = _ticks();
        uint160 spot = TickMath.getSqrtPriceAtTick(-120); // below lower
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(spot, lower, upper, 1e18, 0);
        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(spot, lower, upper, liquidity);
        assertGt(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_above_range_is_token1_only() public pure {
        (uint160 lower, uint160 upper) = _ticks();
        uint160 spot = TickMath.getSqrtPriceAtTick(120); // above upper
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(spot, lower, upper, 0, 1e18);
        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(spot, lower, upper, liquidity);
        assertEq(amount0, 0);
        assertGt(amount1, 0);
    }
}
