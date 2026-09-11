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
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ShareMath} from "./libraries/ShareMath.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title SuperpositionHook
/// @notice A Uniswap v4 concentrated-liquidity hook that keeps 100% of pooled capital earning
///         yield in Aave v3 and represents LP ownership with internal ERC-4626 style shares.
/// @dev The pool's liquidity is virtual: between swaps all tokens sit in Aave as aWETH/aUSDC.
///      `beforeSwap` withdraws them and materializes the recorded tick ranges as real v4
///      liquidity; `afterSwap` removes the ranges, takes the proceeds (principal + fees), and
///      supplies everything back to Aave. Because the Aave position is closed and reopened
///      inside a single swap transaction, the reserve's utilization is effectively unchanged.
contract SuperpositionHook is IHooks, Ownable {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Thrown when a hook callback is invoked by anyone but the PoolManager.
    error NotPoolManager();
    /// @notice Thrown when an unused IHooks callback is invoked.
    error HookNotImplemented();
    /// @notice Thrown when a third party tries to add or remove pool liquidity directly.
    error OnlyHook();
    /// @notice Thrown when depositing or withdrawing while a JIT swap is in flight.
    error JitActive();
    /// @notice Thrown when a range produces zero liquidity, or a swap runs with no liquidity.
    error NoLiquidity();
    /// @notice Thrown when the amounts required by the range exceed the caller's limits/budget.
    error Slippage();
    /// @notice Thrown when tick bounds are inverted or not aligned to the pool tick spacing.
    error InvalidRange();
    /// @notice Thrown when the pool has not been initialized yet.
    error PoolNotInitialized();
    /// @notice Thrown when `initializePool` is called twice.
    error AlreadyInitialized();
    /// @notice Thrown when a deposit or withdrawal would mint or burn zero shares.
    error ZeroShares();
    /// @notice Thrown when the caller does not hold enough shares to redeem.
    error InsufficientShares();
    /// @notice Thrown when a Chainlink round is missing or non-positive.
    error StalePrice();

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @dev One whole share, in 1e18 fixed point.
    uint256 internal constant WAD = 1e18;
    /// @dev Chainlink USD feeds return 8 decimals.
    uint256 internal constant FEED_SCALE = 1e8;
    /// @dev Extra wei pulled per token to absorb Aave's per-supply index rounding (see deposit).
    uint256 internal constant DEPOSIT_BUFFER = 1000;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Aggregate liquidity placed in one tick range across all depositors.
    /// @param lower Lower tick bound of the range.
    /// @param upper Upper tick bound of the range.
    /// @param liquidity Total v4 liquidity for this exact range.
    /// @param active Whether the range still holds liquidity (cleared when it reaches zero).
    struct Range {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        bool active;
    }

    /// @notice Arguments for `deposit`.
    /// @param tickLower Lower tick bound of the position.
    /// @param tickUpper Upper tick bound of the position.
    /// @param amount0Desired Max WETH (currency0) the caller is willing to spend, including buffer.
    /// @param amount1Desired Max USDC (currency1) the caller is willing to spend, including buffer.
    /// @param amount0Min Slippage floor on the WETH actually required by the range.
    /// @param amount1Min Slippage floor on the USDC actually required by the range.
    /// @param recipient Address that receives the minted shares.
    struct DepositParams {
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
    }

    // ---------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------

    /// @notice The v4 singleton that owns all pool state.
    IPoolManager public immutable poolManager;
    /// @notice The Aave v3 pool used for yield.
    address public immutable aavePool;
    /// @notice Wrapped ETH (currency0).
    IERC20 public immutable weth;
    /// @notice USD Coin (currency1).
    IERC20 public immutable usdc;
    /// @notice Aave interest-bearing WETH, held by the vault.
    IERC20 public immutable aWeth;
    /// @notice Aave interest-bearing USDC, held by the vault.
    IERC20 public immutable aUsdc;
    /// @notice Chainlink ETH/USD feed, used to value WETH in USD.
    IAggregatorV3 public immutable ethUsdFeed;
    /// @notice Chainlink USDC/USD feed, used to value USDC in USD.
    IAggregatorV3 public immutable usdcUsdFeed;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Pool key of the single pool this hook serves.
    PoolKey public poolKey;
    /// @notice Pool id derived from `poolKey`.
    PoolId public poolId;
    /// @notice True once `initializePool` has run.
    bool public initialized;

    /// @notice True while `beforeSwap`..`afterSwap` are executing. Blocks deposit/withdraw.
    bool public jitActive;

    /// @notice Total internal shares outstanding.
    uint256 public totalShares;
    /// @notice Internal share balance per account.
    mapping(address => uint256) public balanceOf;

    /// @dev Enumerated ranges; inactive entries are skipped during JIT.
    Range[] internal ranges;
    /// @dev keccak(lower, upper) => 1-based index into `ranges` (0 means "not present").
    mapping(bytes32 => uint256) internal rangeIndex;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted on a successful deposit.
    /// @param recipient Receiver of the newly minted shares.
    /// @param lower Lower tick of the deposited range.
    /// @param upper Upper tick of the deposited range.
    /// @param liquidity Liquidity added for this range.
    /// @param amount0 WETH actually pulled from the caller.
    /// @param amount1 USDC actually pulled from the caller.
    /// @param shares Shares minted to `recipient`.
    event Deposited(
        address indexed recipient,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );

    /// @notice Emitted on a successful withdrawal.
    /// @param owner Account whose shares were burned.
    /// @param recipient Account that received the underlying.
    /// @param shares Shares burned.
    /// @param amount0 WETH paid out (aToken withdrawal + idle).
    /// @param amount1 USDC paid out (aToken withdrawal + idle).
    event Withdrawn(
        address indexed owner,
        address indexed recipient,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    /// @dev Restricts a hook callback to the v4 PoolManager.
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Blocks vault entry points during the JIT window.
    modifier notJit() {
        if (jitActive) revert JitActive();
        _;
    }

    /// @notice Deploys the hook for a single WETH/USDC pool.
    /// @dev `initialOwner` is explicit because CREATE2 deployment via the deterministic proxy makes
    ///      `msg.sender` the proxy, not the deployer.
    /// @param _poolManager The v4 PoolManager singleton.
    /// @param _aavePool The Aave v3 pool.
    /// @param _weth WETH address (must sort before USDC).
    /// @param _usdc USDC address.
    /// @param _aWeth Aave interest-bearing WETH.
    /// @param _aUsdc Aave interest-bearing USDC.
    /// @param _ethUsdFeed Chainlink ETH/USD feed.
    /// @param _usdcUsdFeed Chainlink USDC/USD feed.
    /// @param initialOwner Owner allowed to initialize the pool.
    constructor(
        IPoolManager _poolManager,
        address _aavePool,
        address _weth,
        address _usdc,
        address _aWeth,
        address _aUsdc,
        IAggregatorV3 _ethUsdFeed,
        IAggregatorV3 _usdcUsdFeed,
        address initialOwner
    ) Ownable(initialOwner) {
        // v4 requires currency0 < currency1 by address.
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

    /// @notice Initializes the ETH/USDC pool at the given starting price.
    /// @dev One-shot. The hook address must already encode the enabled permission bits or the
    ///      PoolManager will reject this call.
    /// @param sqrtPriceX96 Initial pool price as a sqrt price in Q96.
    function initializePool(uint160 sqrtPriceX96) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        poolManager.initialize(poolKey, sqrtPriceX96);
        initialized = true;
    }

    /// @notice Adds liquidity to a tick range, supplies it to Aave, and mints shares.
    /// @dev Only the tokens actually required by the range at the current price are pulled, which
    ///      makes one-sided out-of-range deposits (limit orders) natural: a range below spot needs
    ///      only USDC, a range above spot needs only WETH.
    ///
    ///      Amounts are rounded up exactly like the PoolManager does, plus a small `DEPOSIT_BUFFER`.
    ///      Aave's liquidity index truncates `balanceOf` by up to one wei per supply, and because
    ///      the hook re-supplies every swap, the buffer keeps the vault able to re-materialize the
    ///      range. The buffer is reserved inside `amountDesired`, so the pull never exceeds it.
    /// @param p Deposit parameters (range, max amounts, slippage floors, recipient).
    /// @return sharesMinted Shares minted to `p.recipient`.
    function deposit(DepositParams calldata p) external notJit returns (uint256 sharesMinted) {
        if (!initialized) revert PoolNotInitialized();
        if (p.tickLower >= p.tickUpper) revert InvalidRange();
        // v4 only accepts positions on tick-spacing boundaries.
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
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, eff0, eff1);
        if (liquidity == 0) revert NoLiquidity();

        // Amounts the PoolManager will actually require for that liquidity at the current price.
        (uint256 amount0, uint256 amount1) =
            _requiredAmounts(sqrtP, sqrtLower, sqrtUpper, liquidity);
        if (amount0 < p.amount0Min || amount1 < p.amount1Min) revert Slippage();

        // Aave's liquidity index rounds balances down by a few wei; keep a tiny buffer so the
        // vault can always re-materialize the exact range the PoolManager asks for.
        uint256 pull0 = amount0 == 0 ? 0 : amount0 + DEPOSIT_BUFFER;
        uint256 pull1 = amount1 == 0 ? 0 : amount1 + DEPOSIT_BUFFER;
        if (pull0 > p.amount0Desired || pull1 > p.amount1Desired) revert Slippage();

        // Snapshot the share price *before* the deposit so the new shares are priced correctly.
        uint256 preTotal = totalAssets();

        if (pull0 > 0) weth.safeTransferFrom(msg.sender, address(this), pull0);
        if (pull1 > 0) usdc.safeTransferFrom(msg.sender, address(this), pull1);

        // Record the position first, then deploy the capital. `_supply` never reverts.
        _addRange(p.tickLower, p.tickUpper, liquidity);
        _supply(weth, pull0);
        _supply(usdc, pull1);

        uint256 value = _value(pull0, pull1);
        sharesMinted = ShareMath.toShares(value, preTotal, totalShares);
        if (sharesMinted == 0) revert ZeroShares();
        _mint(p.recipient, sharesMinted);

        emit Deposited(p.recipient, p.tickLower, p.tickUpper, liquidity, pull0, pull1, sharesMinted);
    }

    /// @notice Burns shares and pays out the caller's pro-rata slice of the vault's real holdings.
    /// @dev No oracle is needed on exit: the payout is `shareAmount / totalSupply` of each aToken
    ///      balance plus the same fraction of any idle balance. Yield accrued since a share was
    ///      minted is therefore captured only by that share.
    /// @param shareAmount Shares to burn.
    /// @param recipient Address that receives the WETH and USDC.
    /// @return wethOut WETH paid out (Aave withdrawal plus idle slice).
    /// @return usdcOut USDC paid out (Aave withdrawal plus idle slice).
    function withdraw(uint256 shareAmount, address recipient)
        external
        notJit
        returns (uint256 wethOut, uint256 usdcOut)
    {
        if (shareAmount == 0) revert ZeroShares();
        if (balanceOf[msg.sender] < shareAmount) revert InsufficientShares();

        uint256 supply = totalShares;
        // Keep the virtual ranges proportional to the remaining shares.
        _reduceRanges(shareAmount, supply);

        uint256 aWethBal = aWeth.balanceOf(address(this));
        uint256 aUsdcBal = aUsdc.balanceOf(address(this));
        uint256 wethIdle = weth.balanceOf(address(this));
        uint256 usdcIdle = usdc.balanceOf(address(this));

        // floor() rounding always favours the vault, never the exiting user.
        uint256 aWethOut = Math.mulDiv(aWethBal, shareAmount, supply);
        uint256 aUsdcOut = Math.mulDiv(aUsdcBal, shareAmount, supply);
        uint256 wethIdleOut = Math.mulDiv(wethIdle, shareAmount, supply);
        uint256 usdcIdleOut = Math.mulDiv(usdcIdle, shareAmount, supply);

        // Pull the Aave slice directly to the recipient; send the idle slice from the hook.
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

    /// @notice Real holdings of the vault: idle balance plus aToken balances.
    /// @dev On Aave v3.2 the aToken `balanceOf` is already index-accrued, so it is the underlying
    ///      amount and grows with yield.
    /// @return wethAmt WETH held (idle + aWETH).
    /// @return usdcAmt USDC held (idle + aUSDC).
    function currentBalance() public view returns (uint256 wethAmt, uint256 usdcAmt) {
        wethAmt = weth.balanceOf(address(this)) + aWeth.balanceOf(address(this));
        usdcAmt = usdc.balanceOf(address(this)) + aUsdc.balanceOf(address(this));
    }

    /// @notice The token composition the vault would have if every range were materialized now.
    /// @dev Useful to compare against `currentBalance`; the two match between swaps up to the
    ///      deposit buffer and accrued yield.
    /// @return wethAmt WETH required by all active ranges at the current price.
    /// @return usdcAmt USDC required by all active ranges at the current price.
    function virtualBalance() public view returns (uint256 wethAmt, uint256 usdcAmt) {
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtP == 0) return (0, 0);
        uint256 len = ranges.length;
        for (uint256 i = 0; i < len; i++) {
            Range memory r = ranges[i];
            if (!r.active || r.liquidity == 0) continue;
            (uint256 a0, uint256 a1) = _requiredAmounts(
                sqrtP,
                TickMath.getSqrtPriceAtTick(r.lower),
                TickMath.getSqrtPriceAtTick(r.upper),
                r.liquidity
            );
            wethAmt += a0;
            usdcAmt += a1;
        }
    }

    /// @notice USD value (1e18) of the vault's real holdings, using Chainlink feeds.
    /// @return The vault's total assets in USD with 18 decimals.
    function totalAssets() public view returns (uint256) {
        (uint256 w, uint256 u) = currentBalance();
        return _value(w, u);
    }

    /// @notice Shares that `assets` (USD, 1e18) would mint right now.
    /// @param assets USD value to convert.
    /// @return Shares minted for `assets`.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return ShareMath.toShares(assets, totalAssets(), totalShares);
    }

    /// @notice USD value (1e18) of `shares` right now.
    /// @param shares Share amount to convert.
    /// @return USD value of `shares`.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return ShareMath.toAssets(shares, totalAssets(), totalShares);
    }

    /// @notice USD value (1e18) of one whole share. Rises with Aave yield.
    /// @return Assets per 1e18 shares.
    function sharePrice() external view returns (uint256) {
        return ShareMath.toAssets(WAD, totalAssets(), totalShares);
    }

    /// @notice Total internal shares outstanding.
    /// @return Total share supply.
    function totalSupply() external view returns (uint256) {
        return totalShares;
    }

    /// @notice All ranges ever registered, including inactive ones.
    /// @return The range array.
    function getRanges() external view returns (Range[] memory) {
        return ranges;
    }

    //////////////////////////////////////////////////////////////////
    // H O O K S
    //////////////////////////////////////////////////////////////////

    /// @dev Unused: not enabled in the hook permission bits.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @dev Unused: the pool key is built in the constructor.
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @notice Rejects liquidity additions that do not come from the hook itself.
    /// @dev Applied to the hook's own JIT `modifyLiquidity(+L)` calls, which have `sender == hook`.
    /// @return The callback selector.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        if (sender != address(this)) revert OnlyHook();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Not enabled; the hook takes no hook delta when adding liquidity.
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

    /// @notice Rejects liquidity removals that do not come from the hook itself.
    /// @return The callback selector.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        if (sender != address(this)) revert OnlyHook();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev Not enabled; the hook takes no hook delta when removing liquidity.
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

    /// @notice JIT step 1: fund the pool and materialize every active range before the swap.
    /// @dev Withdraws all aTokens to underlying, then adds each range as a real v4 position and
    ///      settles what those positions owe the PoolManager (`sync` -> transfer -> `settle`).
    ///      Sets `jitActive` for the duration of the swap.
    /// @return The callback selector.
    /// @return A zero before-swap delta (the hook does not alter the swap amounts).
    /// @return A zero LP fee override.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (_activeLiquidity() == 0) revert NoLiquidity();

        // Everything the vault holds (idle + withdrawn aTokens) is now available to back the swap.
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
            // Negative amounts are owed to the PoolManager; accumulate and settle once per token.
            need0 += int256(delta.amount0());
            need1 += int256(delta.amount1());
        }
        _settleOwed(key, need0, need1);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice JIT step 2: remove every range and re-supply the proceeds to Aave.
    /// @dev Removing the ranges credits the hook a positive delta which is `take`n out. Crucially
    ///      all PoolManager deltas are settled *before* the Aave supply leg, so a caught supply
    ///      failure leaves idle tokens and never an unsettled delta when the lock closes.
    /// @return The callback selector.
    /// @return A zero hook delta.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
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
            // Positive amounts are owed to the hook (principal returned plus swap fees).
            take0 += int256(delta.amount0());
            take1 += int256(delta.amount1());
        }
        if (take0 > 0) poolManager.take(key.currency0, address(this), uint256(take0));
        if (take1 > 0) poolManager.take(key.currency1, address(this), uint256(take1));

        // Re-deploy everything; unbalanced leftovers simply stay idle until the next cycle.
        _supply(weth, weth.balanceOf(address(this)));
        _supply(usdc, usdc.balanceOf(address(this)));

        jitActive = false;
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Unused: donations are not enabled.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @dev Unused: donations are not enabled.
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    //////////////////////////////////////////////////////////////////
    // I N T E R N A L
    //////////////////////////////////////////////////////////////////

    /// @dev USD value (1e18) of `wethAmt` and `usdcAmt` at the Chainlink prices.
    function _value(uint256 wethAmt, uint256 usdcAmt) internal view returns (uint256) {
        if (wethAmt == 0 && usdcAmt == 0) return 0;
        uint256 ethPrice = _price(ethUsdFeed);
        uint256 usdcPrice = _price(usdcUsdFeed);
        // WETH has 18 decimals: value = amount * price / 1e8 -> 18 decimals.
        uint256 value0 = Math.mulDiv(wethAmt, ethPrice, FEED_SCALE);
        // USDC has 6 decimals: scale the price by 1e12 so the result is 18 decimals too.
        uint256 value1 = Math.mulDiv(usdcAmt, usdcPrice * 1e12, FEED_SCALE);
        return value0 + value1;
    }

    /// @dev Reads a Chainlink round and rejects missing or non-positive answers.
    function _price(IAggregatorV3 feed) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0) revert StalePrice();
        return uint256(answer);
    }

    /// @dev Token amounts a range needs at `sqrtP`, rounded UP exactly like the PoolManager does.
    function _requiredAmounts(
        uint160 sqrtP,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtP <= sqrtLower) {
            // Range is entirely above the current price: only token0 is required.
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (sqrtP < sqrtUpper) {
            // Price is inside the range: both sides are required.
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtP, liquidity, true);
        } else {
            // Range is entirely below the current price: only token1 is required.
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }

    /// @dev Mints internal shares.
    function _mint(address to, uint256 amount) internal {
        totalShares += amount;
        balanceOf[to] += amount;
    }

    /// @dev Burns internal shares. Callers must have checked the balance.
    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalShares -= amount;
    }

    /// @dev Adds `liquidity` to the bucket for `(lower, upper)`, registering it on first use.
    function _addRange(int24 lower, int24 upper, uint128 liquidity) internal {
        bytes32 key = keccak256(abi.encodePacked(lower, upper));
        uint256 idx = rangeIndex[key];
        if (idx == 0) {
            ranges.push(Range({lower: lower, upper: upper, liquidity: liquidity, active: true}));
            rangeIndex[key] = ranges.length; // index is stored 1-based so 0 means "missing"
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
            // Drop the dangling allowance; the tokens remain in the hook and count in totalAssets.
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

    /// @dev Sum of liquidity across active ranges; used to reject swaps with no depth.
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
            IERC20(Currency.unwrap(key.currency0))
                .safeTransfer(address(poolManager), uint256(-need0));
            poolManager.settle();
        }
        if (need1 < 0) {
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1))
                .safeTransfer(address(poolManager), uint256(-need1));
            poolManager.settle();
        }
    }
}
