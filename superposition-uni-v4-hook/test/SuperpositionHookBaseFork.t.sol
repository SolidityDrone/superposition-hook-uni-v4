// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {SuperpositionHook} from "../src/SuperpositionHook.sol";
import {BucketShares} from "../src/BucketShares.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {TestSwapRouter} from "./helpers/TestSwapRouter.sol";

/// @notice Base mainnet fork suite (reference market). Any ERC-4626 vault pair works; here the
///         sides are Aave's ERC-4626 wrappers, and one test mixes Aave with a Morpho vault.
contract SuperpositionHookBaseForkTest is Test {
    IPoolManager internal constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Aave ERC-4626 wrappers ("Wrapped Aave Base ...").
    IERC4626 internal constant VAULT_WETH = IERC4626(0xe298b938631f750DD409fB18227C4a23dCdaab9b);
    IERC4626 internal constant VAULT_USDC = IERC4626(0xC768c589647798a6EE01A91FdE98EF2ed046DBD6);
    // Morpho MetaMorpho vault, for the mixed-vaults test.
    IERC4626 internal constant MORPHO_USDC = IERC4626(0xBEEFE94c8aD530842bfE7d8B397938fFc1cb83b2);

    IAggregatorV3 internal constant ETH_USD =
        IAggregatorV3(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
    IAggregatorV3 internal constant USDC_USD =
        IAggregatorV3(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B);

    SuperpositionHook internal hook;
    uint160 internal sqrtPriceX96;
    int24 internal currentTick;

    address internal lp = address(0xB0B);

    function setUp() public virtual {
        vm.createSelectFork("base");
        hook = _deployHook(VAULT_WETH, VAULT_USDC);

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

    function _deployHook(IERC4626 vault0, IERC4626 vault1) internal returns (SuperpositionHook h) {
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory args = abi.encode(PM, vault0, vault1, uint24(500), int24(10), address(this));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(SuperpositionHook).creationCode, args);
        h = new SuperpositionHook{salt: salt}(PM, vault0, vault1, 500, 10, address(this));
        assertEq(address(h), predicted);
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

    function _required(uint128 liquidity, int24 lower, int24 upper)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtP = sqrtPriceX96;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        if (sqrtP <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (sqrtP < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtP, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }

    function _depositDefault(uint256 amount0Desired, uint256 amount1Desired)
        internal
        returns (uint256 shares, uint128 liq, uint256 exp0, uint256 exp1, int24 lower, int24 upper)
    {
        int24 base = _floor(currentTick, 10);
        lower = base - 600;
        upper = base + 600;
        uint256 eff0 = amount0Desired > 1000 ? amount0Desired - 1000 : 0;
        uint256 eff1 = amount1Desired > 1000 ? amount1Desired - 1000 : 0;
        liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            eff0,
            eff1
        );
        (uint256 r0, uint256 r1) = _required(liq, lower, upper);
        exp0 = r0 == 0 ? 0 : r0 + 1000;
        exp1 = r1 == 0 ? 0 : r1 + 1000;
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

    function _withdrawParams(uint256 shares)
        internal
        view
        returns (SuperpositionHook.WithdrawParams memory)
    {
        int24 base = _floor(currentTick, 10);
        return SuperpositionHook.WithdrawParams({
            tickLower: base - 600,
            tickUpper: base + 600,
            owner: lp,
            shareAmount: shares,
            recipient: lp
        });
    }

    function test_initial_views() public view {
        (uint256 a0, uint256 a1) = hook.currentBalance();
        assertEq(a0, 0);
        assertEq(a1, 0);
        (uint256 c0, uint256 c1) = hook.totalClaim();
        assertEq(c0, 0);
        assertEq(c1, 0);
        assertEq(hook.getBuckets().length, 0);
    }

    function test_fork_deposit_two_sided() public {
        (uint256 shares,,,, int24 lower, int24 upper) = _depositDefault(1e18, 3000e6);

        assertGt(shares, 0);
        assertEq(hook.sharesOf(lp, lower, upper), shares);
        assertEq(hook.getBuckets().length, 1);

        (uint256 a0, uint256 a1) = hook.currentBalance();
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertGt(VAULT_WETH.balanceOf(address(hook)), 0);
        assertGt(VAULT_USDC.balanceOf(address(hook)), 0);
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0);
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0);
    }

    function test_fork_withdraw_returns_principal() public {
        (uint256 shares,, uint256 exp0, uint256 exp1,,) = _depositDefault(1e18, 3000e6);

        uint256 wBefore = IERC20(WETH).balanceOf(lp);
        uint256 uBefore = IERC20(USDC).balanceOf(lp);
        vm.prank(lp);
        (uint256 wOut, uint256 uOut) = hook.withdraw(_withdrawParams(shares));

        assertEq(IERC20(WETH).balanceOf(lp) - wBefore, wOut);
        assertEq(IERC20(USDC).balanceOf(lp) - uBefore, uOut);
        assertApproxEqAbs(wOut, exp0, 10);
        assertApproxEqAbs(uOut, exp1, 10);
        (uint256 c0, uint256 c1) = hook.totalClaim();
        assertApproxEqAbs(c0, 0, 10);
        assertApproxEqAbs(c1, 0, 10);
    }

    function test_fork_withdraw_half() public {
        (uint256 shares,,,,,) = _depositDefault(1e18, 3000e6);

        SuperpositionHook.Bucket[] memory bs = hook.getBuckets();
        uint256 c0 = bs[0].c0;
        uint256 c1 = bs[0].c1;
        uint256 s = bs[0].shares;
        uint256 half = shares / 2;
        vm.prank(lp);
        (uint256 wOut, uint256 uOut) = hook.withdraw(_withdrawParams(half));

        assertApproxEqAbs(wOut, c0 * half / s, 2);
        assertApproxEqAbs(uOut, c1 * half / s, 2);
        int24 base = _floor(currentTick, 10);
        assertEq(hook.sharesOf(lp, base - 600, base + 600), shares - half);
    }

    function test_fork_swap_jit_cycle() public {
        _depositDefault(1e18, 3000e6);
        TestSwapRouter router = new TestSwapRouter(PM);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.stopPrank();

        (uint160 sqrtBefore, int24 tickBefore,,) = StateLibrary.getSlot0(PM, hook.poolId());
        vm.prank(lp);
        router.swap(_poolKey(), true, -0.01e18, TickMath.MIN_SQRT_PRICE + 1, lp);

        (uint160 sqrtAfter, int24 tickAfter,,) = StateLibrary.getSlot0(PM, hook.poolId());
        assertLt(sqrtAfter, sqrtBefore);
        assertLt(tickAfter, tickBefore);
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0);
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0);
        assertGt(VAULT_WETH.balanceOf(address(hook)), 0);
        assertFalse(hook.jitActive());
    }

    function test_fork_one_sided_usdc_limit_order() public {
        int24 base = _floor(currentTick, 10);
        int24 tickUpper = base - 10;
        int24 tickLower = tickUpper - 600;
        vm.prank(lp);
        uint256 shares = hook.deposit(
            SuperpositionHook.DepositParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: 0,
                amount1Desired: 3000e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp
            })
        );

        assertGt(shares, 0);
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0);
        assertEq(VAULT_WETH.balanceOf(address(hook)), 0);
        assertGt(VAULT_USDC.balanceOf(address(hook)), 0);
        (uint256 v0, uint256 v1) = hook.virtualBalance();
        assertEq(v0, 0);
        assertGt(v1, 0);
    }

    function test_fork_limit_order_fills_on_cross() public {
        int24 base = _floor(currentTick, 10);
        int24 tickUpper = base - 10;
        int24 tickLower = tickUpper - 600;
        vm.prank(lp);
        hook.deposit(
            SuperpositionHook.DepositParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: 0,
                amount1Desired: 3000e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp
            })
        );

        TestSwapRouter router = new TestSwapRouter(PM);
        vm.prank(lp);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.prank(lp);
        router.swap(_poolKey(), true, -0.5e18, TickMath.MIN_SQRT_PRICE + 1, lp);

        assertGt(VAULT_WETH.balanceOf(address(hook)), 0);
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0);
    }

    function test_fork_yield_accrual_and_atomic_exit_fairness() public {
        int24 base = _floor(currentTick, 10);
        int24 lower = base - 600;
        int24 upper = base + 600;
        _depositDefault(1e18, 3000e6);

        // Simulate yield: extra underlying lands in the hook, which `_syncYield` distributes.
        deal(WETH, address(hook), IERC20(WETH).balanceOf(address(hook)) + 0.5e18);
        deal(USDC, address(hook), IERC20(USDC).balanceOf(address(hook)) + 1500e6);
        hook.syncYield();

        uint256 valueBefore = hook.bucketValue(lower, upper);
        vm.startPrank(lp);
        uint256 aliceShares = hook.deposit(
            SuperpositionHook.DepositParams({
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: 1e18,
                amount1Desired: 3000e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp
            })
        );
        hook.withdraw(_withdrawParams(aliceShares));
        vm.stopPrank();

        uint256 valueAfter = hook.bucketValue(lower, upper);
        assertApproxEqRel(valueAfter, valueBefore, 0.001e18);
    }

    function test_fork_deposit_survives_vault_failure() public {
        vm.mockCallRevert(address(VAULT_WETH), IERC4626.deposit.selector, bytes("vault failed"));
        vm.mockCallRevert(address(VAULT_USDC), IERC4626.deposit.selector, bytes("vault failed"));

        (uint256 shares,,,,,) = _depositDefault(1e18, 3000e6);
        assertGt(shares, 0);
        assertEq(VAULT_WETH.balanceOf(address(hook)), 0);
        assertGt(IERC20(WETH).balanceOf(address(hook)), 0);
        (uint256 c0, uint256 c1) = hook.totalClaim();
        assertGt(c0 + c1, 0);
    }

    function test_fork_partial_vault_deposit_stays_correct() public {
        _depositDefault(1e18, 3000e6);

        // Only the USDC vault rejects deposits from now on (simulated cap).
        vm.mockCallRevert(address(VAULT_USDC), IERC4626.deposit.selector, bytes("cap"));

        TestSwapRouter router = new TestSwapRouter(PM);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.prank(lp);
        router.swap(_poolKey(), true, -0.01e18, TickMath.MIN_SQRT_PRICE + 1, lp);

        assertGt(VAULT_WETH.balanceOf(address(hook)), 0);
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0);
        assertGt(IERC20(USDC).balanceOf(address(hook)), 0);
        assertFalse(hook.jitActive());
    }

    function test_fork_withdraw_after_swap() public {
        (uint256 shares,,,,,) = _depositDefault(1e18, 3000e6);
        TestSwapRouter router = new TestSwapRouter(PM);
        vm.prank(lp);
        IERC20(WETH).approve(address(router), type(uint256).max);
        vm.prank(lp);
        router.swap(_poolKey(), true, -0.01e18, TickMath.MIN_SQRT_PRICE + 1, lp);

        vm.prank(lp);
        (uint256 wOut, uint256 uOut) = hook.withdraw(_withdrawParams(shares));
        assertGt(wOut + uOut, 0);
        int24 base = _floor(currentTick, 10);
        assertEq(hook.sharesOf(lp, base - 600, base + 600), 0);
    }

    function test_fork_multi_lp_full_exit() public {
        int24 base = _floor(currentTick, 10);
        int24 lower = base - 600;
        int24 upper = base + 600;

        address lp2 = address(0xA11CE);
        deal(WETH, lp2, 100e18);
        deal(USDC, lp2, 1_000_000e6);
        vm.startPrank(lp2);
        IERC20(WETH).approve(address(hook), type(uint256).max);
        IERC20(USDC).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        (uint256 s1,,,,,) = _depositDefault(1e18, 3000e6);
        vm.prank(lp2);
        uint256 s2 = hook.deposit(
            SuperpositionHook.DepositParams({
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: 0.5e18,
                amount1Desired: 1500e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp2
            })
        );
        assertGt(s1, 0);
        assertGt(s2, 0);

        vm.prank(lp);
        hook.withdraw(_withdrawParams(s1));
        vm.prank(lp2);
        hook.withdraw(
            SuperpositionHook.WithdrawParams({
                tickLower: lower, tickUpper: upper, owner: lp2, shareAmount: s2, recipient: lp2
            })
        );

        (uint256 c0, uint256 c1) = hook.totalClaim();
        assertApproxEqAbs(c0, 0, 10);
        assertApproxEqAbs(c1, 0, 10);
        SuperpositionHook.Bucket[] memory bs2 = hook.getBuckets();
        assertFalse(bs2[0].active);
    }

    function test_fork_delegate_withdraw() public {
        (uint256 shares,,,,,) = _depositDefault(1e18, 3000e6);
        int24 base = _floor(currentTick, 10);
        address operator = address(0xDE1E6A7E);

        BucketShares token = hook.shareToken();
        vm.prank(lp);
        token.setApprovalForAll(operator, true);

        uint256 wBefore = IERC20(WETH).balanceOf(operator);
        vm.prank(operator);
        (uint256 wOut, uint256 uOut) = hook.withdraw(
            SuperpositionHook.WithdrawParams({
                tickLower: base - 600,
                tickUpper: base + 600,
                owner: lp,
                shareAmount: shares / 2,
                recipient: operator
            })
        );

        assertGt(wOut + uOut, 0);
        assertEq(IERC20(WETH).balanceOf(operator) - wBefore, wOut);
        assertEq(hook.sharesOf(lp, base - 600, base + 600), shares - shares / 2);
    }

    /// @notice Same hook, one Aave-backed side and one Morpho-backed side.
    function test_fork_mixed_vaults_aave_morpho() public {
        SuperpositionHook mixed = _deployHook(VAULT_WETH, MORPHO_USDC);
        mixed.initializePool(sqrtPriceX96);

        vm.startPrank(lp);
        IERC20(WETH).approve(address(mixed), type(uint256).max);
        IERC20(USDC).approve(address(mixed), type(uint256).max);
        int24 base = _floor(currentTick, 10);
        uint256 shares = mixed.deposit(
            SuperpositionHook.DepositParams({
                tickLower: base - 600,
                tickUpper: base + 600,
                amount0Desired: 1e18,
                amount1Desired: 3000e6,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp
            })
        );
        vm.stopPrank();

        assertGt(shares, 0);
        assertGt(VAULT_WETH.balanceOf(address(mixed)), 0);
        assertGt(MORPHO_USDC.balanceOf(address(mixed)), 0);

        vm.prank(lp);
        (uint256 wOut, uint256 uOut) = mixed.withdraw(
            SuperpositionHook.WithdrawParams({
                tickLower: base - 600,
                tickUpper: base + 600,
                owner: lp,
                shareAmount: shares,
                recipient: lp
            })
        );
        assertGt(wOut + uOut, 0);
    }

    function test_non_manager_hook_calls_revert() public {
        PoolKey memory key = _poolKey();
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600, liquidityDelta: 0, salt: 0
        });

        vm.expectRevert(SuperpositionHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(0xBAD), key, params, "");
        vm.expectRevert(SuperpositionHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(0xBAD), key, params, "");
        vm.expectRevert(SuperpositionHook.NotPoolManager.selector);
        hook.beforeSwap(address(0xBAD), key, IPoolManager.SwapParams(false, 0, 0), "");
    }

    function test_direct_lp_modify_reverts() public {
        DirectLpAttacker attacker = new DirectLpAttacker(PM);
        vm.expectRevert();
        attacker.attack(_poolKey());
    }
}

/// @notice Tries to LP the pool directly, bypassing the vault; must be rejected.
contract DirectLpAttacker {
    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function attack(PoolKey calldata key) external {
        manager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        PoolKey memory key = abi.decode(data, (PoolKey));
        manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: 1e15, salt: 0
            }),
            ""
        );
        return "";
    }
}
