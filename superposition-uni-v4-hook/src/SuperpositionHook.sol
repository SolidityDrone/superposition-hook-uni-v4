// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {ShareMath} from "./libraries/ShareMath.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title SuperpositionHook
/// @notice Uniswap v4 concentrated-liquidity hook that holds 100% of capital in Aave v3
///         between swaps and issues ERC-4626 style internal shares.
contract SuperpositionHook is IHooks, Ownable {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    error NotPoolManager();
    error HookNotImplemented();
    error OnlyHook();
    error JitActive();
    error NoLiquidity();
    error Slippage();
    error InvalidRange();
    error PoolNotInitialized();
    error AlreadyInitialized();
    error ZeroShares();
    error InsufficientShares();
    error StalePrice();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant FEED_SCALE = 1e8;
    uint256 internal constant DEPOSIT_BUFFER = 5;

    struct Range {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        bool active;
    }

    struct DepositParams {
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
    }

    IPoolManager public immutable poolManager;
    address public immutable aavePool;
    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    IERC20 public immutable aWeth;
    IERC20 public immutable aUsdc;
    IAggregatorV3 public immutable ethUsdFeed;
    IAggregatorV3 public immutable usdcUsdFeed;

    PoolKey public poolKey;
    PoolId public poolId;
    bool public initialized;

    bool public jitActive;

    uint256 public totalShares;
    mapping(address => uint256) public balanceOf;

    Range[] internal ranges;
    mapping(bytes32 => uint256) internal rangeIndex;

    event Deposited(
        address indexed recipient,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );
    event Withdrawn(address indexed owner, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier notJit() {
        if (jitActive) revert JitActive();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _aavePool,
        address _weth,
        address _usdc,
        address _aWeth,
        address _aUsdc,
        IAggregatorV3 _ethUsdFeed,
        IAggregatorV3 _usdcUsdFeed
    ) Ownable(msg.sender) {
        require(_weth < _usdc, "currencies out of order");
        poolManager = _poolManager;
        aavePool = _aavePool;
        weth = IERC20(_weth);
        usdc = IERC20(_usdc);
        aWeth = IERC20(_aWeth);
        aUsdc = IERC20(_aUsdc);
        ethUsdFeed = _ethUsdFeed;
        usdcUsdFeed = _usdcUsdFeed;

        poolKey = PoolKey({
            currency0: Currency.wrap(_weth),
            currency1: Currency.wrap(_usdc),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(this))
        });
        poolId = poolKey.toId();
    }

    //////////////////////////////////////////////////////////////////
    // P U B L I C   A D M I N
    //////////////////////////////////////////////////////////////////

    function initializePool(uint160 sqrtPriceX96) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        poolManager.initialize(poolKey, sqrtPriceX96);
        initialized = true;
    }

    /// @notice Add liquidity to a tick range. Tokens are supplied to Aave and shares are minted.
    function deposit(DepositParams calldata p) external notJit returns (uint256 sharesMinted) {
        if (!initialized) revert PoolNotInitialized();
        if (p.tickLower >= p.tickUpper) revert InvalidRange();
        if (p.tickLower % poolKey.tickSpacing != 0 || p.tickUpper % poolKey.tickSpacing != 0) {
            revert InvalidRange();
        }

        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtP == 0) revert PoolNotInitialized();

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(p.tickUpper);

        // Reserve the rounding buffer from the user's budget so the pulled amount never exceeds
        // `amountDesired`.
        uint256 eff0 = p.amount0Desired > DEPOSIT_BUFFER ? p.amount0Desired - DEPOSIT_BUFFER : 0;
        uint256 eff1 = p.amount1Desired > DEPOSIT_BUFFER ? p.amount1Desired - DEPOSIT_BUFFER : 0;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, eff0, eff1);
        if (liquidity == 0) revert NoLiquidity();

        (uint256 amount0, uint256 amount1) = _requiredAmounts(sqrtP, sqrtLower, sqrtUpper, liquidity);
        if (amount0 < p.amount0Min || amount1 < p.amount1Min) revert Slippage();

        // Aave's liquidity index rounds balances down by a few wei; keep a tiny buffer so the
        // vault can always re-materialize the exact range the PoolManager asks for.
        uint256 pull0 = amount0 == 0 ? 0 : amount0 + DEPOSIT_BUFFER;
        uint256 pull1 = amount1 == 0 ? 0 : amount1 + DEPOSIT_BUFFER;
        if (pull0 > p.amount0Desired || pull1 > p.amount1Desired) revert Slippage();

        uint256 preTotal = totalAssets();

        if (pull0 > 0) weth.safeTransferFrom(msg.sender, address(this), pull0);
        if (pull1 > 0) usdc.safeTransferFrom(msg.sender, address(this), pull1);

        _addRange(p.tickLower, p.tickUpper, liquidity);
        _supply(weth, pull0);
        _supply(usdc, pull1);

        uint256 value = _value(pull0, pull1);
        sharesMinted = ShareMath.toShares(value, preTotal, totalShares);
        if (sharesMinted == 0) revert ZeroShares();
        _mint(p.recipient, sharesMinted);

        emit Deposited(p.recipient, p.tickLower, p.tickUpper, liquidity, pull0, pull1, sharesMinted);
    }

    /// @notice Burn shares and receive a pro-rata slice of the vault's real holdings.
    function withdraw(uint256 shareAmount, address recipient)
        external
        notJit
        returns (uint256 wethOut, uint256 usdcOut)
    {
        if (shareAmount == 0) revert ZeroShares();
        if (balanceOf[msg.sender] < shareAmount) revert InsufficientShares();

        uint256 supply = totalShares;
        _reduceRanges(shareAmount, supply);

        uint256 aWethBal = aWeth.balanceOf(address(this));
        uint256 aUsdcBal = aUsdc.balanceOf(address(this));
        uint256 wethIdle = weth.balanceOf(address(this));
        uint256 usdcIdle = usdc.balanceOf(address(this));

        uint256 aWethOut = Math.mulDiv(aWethBal, shareAmount, supply);
        uint256 aUsdcOut = Math.mulDiv(aUsdcBal, shareAmount, supply);
        uint256 wethIdleOut = Math.mulDiv(wethIdle, shareAmount, supply);
        uint256 usdcIdleOut = Math.mulDiv(usdcIdle, shareAmount, supply);

        if (aWethOut > 0) IAavePool(aavePool).withdraw(address(weth), aWethOut, recipient);
        if (aUsdcOut > 0) IAavePool(aavePool).withdraw(address(usdc), aUsdcOut, recipient);
        if (wethIdleOut > 0) weth.safeTransfer(recipient, wethIdleOut);
        if (usdcIdleOut > 0) usdc.safeTransfer(recipient, usdcIdleOut);

        wethOut = aWethOut + wethIdleOut;
        usdcOut = aUsdcOut + usdcIdleOut;

        _burn(msg.sender, shareAmount);
        emit Withdrawn(msg.sender, recipient, shareAmount, wethOut, usdcOut);
    }

    //////////////////////////////////////////////////////////////////
    // V I E W S
    //////////////////////////////////////////////////////////////////

    /// @notice Real holdings: idle balance plus aToken balances (index-accrued on Aave v3.2+).
    function currentBalance() public view returns (uint256 wethAmt, uint256 usdcAmt) {
        wethAmt = weth.balanceOf(address(this)) + aWeth.balanceOf(address(this));
        usdcAmt = usdc.balanceOf(address(this)) + aUsdc.balanceOf(address(this));
    }

    /// @notice Composition the vault would have if every range were materialized at the current price.
    function virtualBalance() public view returns (uint256 wethAmt, uint256 usdcAmt) {
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtP == 0) return (0, 0);
        uint256 len = ranges.length;
        for (uint256 i = 0; i < len; i++) {
            Range memory r = ranges[i];
            if (!r.active || r.liquidity == 0) continue;
            (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtP, TickMath.getSqrtPriceAtTick(r.lower), TickMath.getSqrtPriceAtTick(r.upper), r.liquidity
            );
            wethAmt += a0;
            usdcAmt += a1;
        }
    }

    /// @notice USD value (1e18) of the vault's real holdings.
    function totalAssets() public view returns (uint256) {
        (uint256 w, uint256 u) = currentBalance();
        return _value(w, u);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return ShareMath.toShares(assets, totalAssets(), totalShares);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return ShareMath.toAssets(shares, totalAssets(), totalShares);
    }

    function sharePrice() external view returns (uint256) {
        return ShareMath.toAssets(WAD, totalAssets(), totalShares);
    }

    function totalSupply() external view returns (uint256) {
        return totalShares;
    }

    function getRanges() external view returns (Range[] memory) {
        return ranges;
    }

    //////////////////////////////////////////////////////////////////
    // H O O K S
    //////////////////////////////////////////////////////////////////

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (sender != address(this)) revert OnlyHook();
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view returns (bytes4) {
        if (sender != address(this)) revert OnlyHook();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_activeLiquidity() == 0) revert NoLiquidity();

        jitActive = true;
        _withdrawAllFromAave();

        int256 need0;
        int256 need1;
        uint256 len = ranges.length;
        for (uint256 i = 0; i < len; i++) {
            Range memory r = ranges[i];
            if (!r.active || r.liquidity == 0) continue;
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: r.lower,
                    tickUpper: r.upper,
                    liquidityDelta: int256(uint256(r.liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            need0 += int256(delta.amount0());
            need1 += int256(delta.amount1());
        }
        _settleOwed(key, need0, need1);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        int256 take0;
        int256 take1;
        uint256 len = ranges.length;
        for (uint256 i = 0; i < len; i++) {
            Range memory r = ranges[i];
            if (!r.active || r.liquidity == 0) continue;
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: r.lower,
                    tickUpper: r.upper,
                    liquidityDelta: -int256(uint256(r.liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            take0 += int256(delta.amount0());
            take1 += int256(delta.amount1());
        }
        if (take0 > 0) poolManager.take(key.currency0, address(this), uint256(take0));
        if (take1 > 0) poolManager.take(key.currency1, address(this), uint256(take1));

        _supply(weth, weth.balanceOf(address(this)));
        _supply(usdc, usdc.balanceOf(address(this)));

        jitActive = false;
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    //////////////////////////////////////////////////////////////////
    // I N T E R N A L
    //////////////////////////////////////////////////////////////////

    function _value(uint256 wethAmt, uint256 usdcAmt) internal view returns (uint256) {
        if (wethAmt == 0 && usdcAmt == 0) return 0;
        uint256 ethPrice = _price(ethUsdFeed);
        uint256 usdcPrice = _price(usdcUsdFeed);
        uint256 value0 = Math.mulDiv(wethAmt, ethPrice, FEED_SCALE);
        uint256 value1 = Math.mulDiv(usdcAmt, usdcPrice * 1e12, FEED_SCALE);
        return value0 + value1;
    }

    function _price(IAggregatorV3 feed) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0) revert StalePrice();
        return uint256(answer);
    }

    /// @dev Token amounts a range needs at `sqrtP`, rounded UP exactly like the PoolManager does.
    function _requiredAmounts(uint160 sqrtP, uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtP <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (sqrtP < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtP, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }

    function _mint(address to, uint256 amount) internal {
        totalShares += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalShares -= amount;
    }

    function _addRange(int24 lower, int24 upper, uint128 liquidity) internal {
        bytes32 key = keccak256(abi.encodePacked(lower, upper));
        uint256 idx = rangeIndex[key];
        if (idx == 0) {
            ranges.push(Range({lower: lower, upper: upper, liquidity: liquidity, active: true}));
            rangeIndex[key] = ranges.length; // 1-based
        } else {
            Range storage r = ranges[idx - 1];
            r.liquidity += liquidity;
            r.active = true;
        }
    }

    /// @dev Supplies `amount` to Aave. On failure (paused/frozen reserve) tokens stay idle.
    function _supply(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        token.forceApprove(aavePool, amount);
        try IAavePool(aavePool).supply(address(token), amount, address(this), 0) {}
        catch {
            token.forceApprove(aavePool, 0);
        }
    }

    /// @dev Shrinks every active range proportionally to the shares being redeemed.
    function _reduceRanges(uint256 shareAmount, uint256 supply) internal {
        uint256 len = ranges.length;
        for (uint256 i = 0; i < len; i++) {
            Range storage r = ranges[i];
            if (!r.active || r.liquidity == 0) continue;
            uint128 dec = uint128(Math.mulDiv(r.liquidity, shareAmount, supply));
            if (dec >= r.liquidity) {
                r.liquidity = 0;
                r.active = false;
            } else {
                r.liquidity -= dec;
            }
        }
    }

    function _activeLiquidity() internal view returns (uint256 total) {
        uint256 len = ranges.length;
        for (uint256 i = 0; i < len; i++) {
            if (ranges[i].active) total += ranges[i].liquidity;
        }
    }

    /// @dev JIT: pull the entire yield position back into underlying so it can back the swap.
    function _withdrawAllFromAave() internal {
        uint256 aW = aWeth.balanceOf(address(this));
        uint256 aU = aUsdc.balanceOf(address(this));
        if (aW > 0) IAavePool(aavePool).withdraw(address(weth), aW, address(this));
        if (aU > 0) IAavePool(aavePool).withdraw(address(usdc), aU, address(this));
    }

    /// @dev Pays the PoolManager whatever the just-added liquidity owes it.
    function _settleOwed(PoolKey memory key, int256 need0, int256 need1) internal {
        if (need0 < 0) {
            poolManager.sync(key.currency0);
            IERC20(Currency.unwrap(key.currency0)).safeTransfer(address(poolManager), uint256(-need0));
            poolManager.settle();
        }
        if (need1 < 0) {
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(poolManager), uint256(-need1));
            poolManager.settle();
        }
    }
}
