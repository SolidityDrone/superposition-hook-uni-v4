// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {ShareMath} from "./libraries/ShareMath.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title SuperpositionHook
/// @notice Uniswap v4 concentrated-liquidity hook that holds 100% of capital in Aave v3
///         between swaps and issues ERC-4626 style internal shares.
contract SuperpositionHook is IHooks, Ownable {
    using PoolIdLibrary for PoolKey;

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

    uint256 internal constant MINIMUM_SHARES = 1e3;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant FEED_SCALE = 1e8;

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

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
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

    function _mint(address to, uint256 amount) internal {
        totalShares += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalShares -= amount;
    }
}
