// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SuperpositionHook} from "../src/SuperpositionHook.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract SuperpositionHookBaseForkTest is Test {
    IPoolManager internal constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address internal constant AAVE = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AWETH = 0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7;
    address internal constant AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    IAggregatorV3 internal constant ETH_USD = IAggregatorV3(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
    IAggregatorV3 internal constant USDC_USD = IAggregatorV3(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B);

    SuperpositionHook internal hook;
    uint160 internal sqrtPriceX96;
    int24 internal currentTick;

    address internal lp = address(0xB0B);

    function setUp() public virtual {
        vm.createSelectFork("base");

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory args = abi.encode(PM, AAVE, WETH, USDC, AWETH, AUSDC, ETH_USD, USDC_USD);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(SuperpositionHook).creationCode, args);
        hook = new SuperpositionHook{salt: salt}(PM, AAVE, WETH, USDC, AWETH, AUSDC, ETH_USD, USDC_USD);
        assertEq(address(hook), predicted);

        sqrtPriceX96 = _sqrtPriceFromFeeds();
        currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        hook.initializePool(sqrtPriceX96);

        deal(WETH, lp, 1_000e18);
        deal(USDC, lp, 5_000_000e6);
        vm.prank(lp);
        IERC20(WETH).approve(address(hook), type(uint256).max);
        vm.prank(lp);
        IERC20(USDC).approve(address(hook), type(uint256).max);
    }

    function _sqrtPriceFromFeeds() internal view returns (uint160) {
        (, int256 ethPrice,,,) = ETH_USD.latestRoundData();
        (, int256 usdcPrice,,,) = USDC_USD.latestRoundData();
        // raw price token1/token0 = (ethPrice/1e8 * 1e6) / (usdcPrice/1e8 * 1e18)
        //                        = ethPrice / (usdcPrice * 1e12)
        // sqrtPriceX96 = sqrt(price * 2^192)
        uint256 priceX192 = Math.mulDiv(uint256(ethPrice), uint256(1) << 192, uint256(usdcPrice) * 1e12);
        return uint160(Math.sqrt(priceX192));
    }

    function test_initial_views() public view {
        (uint256 w, uint256 u) = hook.currentBalance();
        assertEq(w, 0);
        assertEq(u, 0);
        assertEq(hook.totalAssets(), 0);
        assertEq(hook.sharePrice(), 1e18);
        assertEq(hook.getRanges().length, 0);
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function test_fork_deposit_two_sided() public {
        int24 base = _floor(currentTick, 10);
        int24 lower = base - 600;
        int24 upper = base + 600;
        uint256 amount0Desired = 1e18;
        uint256 amount1Desired = 3000e6;

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            amount0Desired,
            amount1Desired
        );
        (uint256 exp0, uint256 exp1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liq
        );

        vm.prank(lp);
        uint256 shares = hook.deposit(
            SuperpositionHook.DepositParams({
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp
            })
        );

        assertGt(shares, 0);
        assertEq(hook.balanceOf(lp), shares);
        assertEq(hook.getRanges().length, 1);

        (uint256 w, uint256 u) = hook.currentBalance();
        assertApproxEqAbs(w, exp0, 1);
        assertApproxEqAbs(u, exp1, 1);
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0);
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0);
        assertGt(IERC20(AWETH).balanceOf(address(hook)), 0);
        assertGt(IERC20(AUSDC).balanceOf(address(hook)), 0);
        assertGt(hook.totalAssets(), 0);
    }

    function _depositDefault(uint256 amount0Desired, uint256 amount1Desired)
        internal
        returns (uint256 shares, uint128 liq, uint256 exp0, uint256 exp1, int24 lower, int24 upper)
    {
        int24 base = _floor(currentTick, 10);
        lower = base - 600;
        upper = base + 600;
        liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            amount0Desired,
            amount1Desired
        );
        (exp0, exp1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liq
        );
        vm.prank(lp);
        shares = hook.deposit(
            SuperpositionHook.DepositParams({
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp
            })
        );
    }

    function test_fork_withdraw_returns_principal() public {
        (uint256 shares,, uint256 exp0, uint256 exp1,,) = _depositDefault(1e18, 3000e6);

        uint256 wBefore = IERC20(WETH).balanceOf(lp);
        uint256 uBefore = IERC20(USDC).balanceOf(lp);
        vm.prank(lp);
        (uint256 wOut, uint256 uOut) = hook.withdraw(shares, lp);

        assertEq(IERC20(WETH).balanceOf(lp) - wBefore, wOut);
        assertEq(IERC20(USDC).balanceOf(lp) - uBefore, uOut);
        assertApproxEqAbs(wOut, exp0, 2);
        assertApproxEqAbs(uOut, exp1, 2);
        assertEq(hook.balanceOf(lp), 0);
        assertEq(hook.totalSupply(), 0);
        assertApproxEqAbs(hook.totalAssets(), 0, 2);
    }

    function test_fork_withdraw_half() public {
        (uint256 shares, uint128 liq, uint256 exp0, uint256 exp1,,) = _depositDefault(1e18, 3000e6);

        uint256 half = shares / 2;
        vm.prank(lp);
        (uint256 wOut, uint256 uOut) = hook.withdraw(half, lp);

        assertApproxEqAbs(wOut, exp0 / 2, 2);
        assertApproxEqAbs(uOut, exp1 / 2, 2);
        assertEq(hook.balanceOf(lp), shares - half);
        SuperpositionHook.Range[] memory rs = hook.getRanges();
        assertApproxEqAbs(uint256(rs[0].liquidity), uint256(liq) / 2, uint256(liq) / 1000);
    }
}
