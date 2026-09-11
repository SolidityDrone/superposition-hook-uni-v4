// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {SuperpositionHook} from "../src/SuperpositionHook.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {TestSwapRouter} from "./helpers/TestSwapRouter.sol";

/// @notice Base Sepolia (chain id 84532) fork suite — the testnet deployment target.
/// @dev Aave's Base Sepolia USDC is its own test market asset (`0xba50…`), not Circle USDC.
contract BaseSepoliaForkTest is Test {
    IPoolManager internal constant PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address internal constant AAVE = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address internal constant AWETH = 0x73a5bB60b0B0fc35710DDc0ea9c407031E31Bdbb;
    address internal constant AUSDC = 0x10F1A9D11CDf50041f3f8cB7191CBE2f31750ACC;
    IAggregatorV3 internal constant ETH_USD =
        IAggregatorV3(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1);
    IAggregatorV3 internal constant USDC_USD =
        IAggregatorV3(0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165);

    SuperpositionHook internal hook;
    uint160 internal sqrtPriceX96;
    int24 internal currentTick;

    address internal lp = address(0xB0B);

    function setUp() public {
        vm.createSelectFork("base_sepolia");

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory args =
            abi.encode(PM, AAVE, WETH, USDC, AWETH, AUSDC, uint24(500), int24(10), address(this));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(SuperpositionHook).creationCode, args);
        hook = new SuperpositionHook{salt: salt}(
            PM, AAVE, WETH, USDC, AWETH, AUSDC, 500, 10, address(this)
        );
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
        uint256 priceX192 =
            Math.mulDiv(uint256(ethPrice), uint256(1) << 192, uint256(usdcPrice) * 1e12);
        return uint160(Math.sqrt(priceX192));
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
    }

    function _deposit(int24 lower, int24 upper, uint256 a0, uint256 a1)
        internal
        returns (uint256 shares)
    {
        vm.prank(lp);
        shares = hook.deposit(
            SuperpositionHook.DepositParams({
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp
            })
        );
    }

    function test_sepolia_deploy_and_deposit() public {
        int24 base = _floor(currentTick, 10);
        uint256 shares = _deposit(base - 600, base + 600, 1e18, 3_000e6);

        assertGt(shares, 0);
        assertEq(hook.sharesOf(lp, base - 600, base + 600), shares);
        assertGt(IERC20(AWETH).balanceOf(address(hook)), 0);
        assertGt(IERC20(AUSDC).balanceOf(address(hook)), 0);
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0);
        (uint256 c0, uint256 c1) = hook.totalClaim();
        assertGt(c0 + c1, 0);
    }

    function test_sepolia_jit_swap() public {
        int24 base = _floor(currentTick, 10);
        _deposit(base - 600, base + 600, 1e18, 3_000e6);

        TestSwapRouter router = new TestSwapRouter(PM);
        vm.prank(lp);
        IERC20(WETH).approve(address(router), type(uint256).max);

        (uint160 sqrtBefore,,,) = StateLibrary.getSlot0(PM, hook.poolId());
        vm.prank(lp);
        router.swap(_poolKey(), true, -0.01e18, TickMath.MIN_SQRT_PRICE + 1, lp);
        (uint160 sqrtAfter,,,) = StateLibrary.getSlot0(PM, hook.poolId());

        assertLt(sqrtAfter, sqrtBefore);
        assertFalse(hook.jitActive());
        assertGt(IERC20(AWETH).balanceOf(address(hook)), 0);
    }

    function test_sepolia_withdraw() public {
        int24 base = _floor(currentTick, 10);
        uint256 shares = _deposit(base - 600, base + 600, 1e18, 3_000e6);

        uint256 wBefore = IERC20(WETH).balanceOf(lp);
        vm.prank(lp);
        (uint256 wOut, uint256 uOut) = hook.withdraw(
            SuperpositionHook.WithdrawParams({
                tickLower: base - 600, tickUpper: base + 600, shareAmount: shares, recipient: lp
            })
        );

        assertGt(wOut, 0);
        assertEq(IERC20(WETH).balanceOf(lp) - wBefore, wOut);
        assertGt(uOut, 0);
        assertEq(hook.sharesOf(lp, base - 600, base + 600), 0);
    }

    function test_sepolia_usdc_only_limit_order() public {
        int24 base = _floor(currentTick, 10);
        int24 tickUpper = base - 10;
        int24 tickLower = tickUpper - 600;
        uint256 shares = _deposit(tickLower, tickUpper, 0, 3_000e6);

        assertGt(shares, 0);
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0);
        assertGt(IERC20(AUSDC).balanceOf(address(hook)), 0);
        (uint256 vw,) = hook.virtualBalance();
        assertEq(vw, 0);
    }
}
