// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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
import {BucketShares} from "./BucketShares.sol";

/// @title SuperpositionHook
/// @notice A Uniswap v4 concentrated-liquidity hook that keeps 100% of pooled capital in an
///         external **ERC-4626 lending vault** (per side) between swaps and tracks ownership per
///         tick range.
/// @dev The hook is protocol-agnostic: it only talks ERC-4626. Pass any two vaults whose `asset()`
///      are the pool currencies — e.g. a Morpho MetaMorpho vault, an Euler v2 EVault, a Spark
///      Savings vault, an Aave ERC-4626 wrapper, or a Yearn vault, in any combination. There is no
///      protocol-specific branch or function here.
///
///      Pool liquidity is virtual: between swaps the capital sits in the vaults. `beforeSwap`
///      redeems them and materializes every range as real v4 liquidity; `afterSwap` removes the
///      ranges, takes proceeds and fees, and deposits everything back. Ownership is per bucket
///      `(tickLower, tickUpper)`, so an out-of-range one-sided deposit is a genuine limit order.
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
    /// @notice Thrown when the caller does not hold enough shares of the bucket.
    error InsufficientShares();
    /// @notice Thrown when referencing a range that has never been deposited into.
    error NoBucket();
    /// @notice Thrown when the caller is neither the share owner nor an approved operator.
    error NotAuthorized();

    /// @dev Extra wei pulled per token to absorb vault share/asset rounding (see deposit).
    uint256 internal constant DEPOSIT_BUFFER = 1000;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Aggregate state of one tick range.
    struct Bucket {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 shares;
        uint256 c0;
        uint256 c1;
        bool active;
    }

    /// @notice Arguments for `deposit`.
    /// @param tickLower Lower tick bound of the position.
    /// @param tickUpper Upper tick bound of the position.
    /// @param amount0Desired Max token0 the caller is willing to spend (buffer included).
    /// @param amount1Desired Max token1 the caller is willing to spend (buffer included).
    /// @param amount0Min Slippage floor on the token0 actually required.
    /// @param amount1Min Slippage floor on the token1 actually required.
    /// @param recipient Receiver of the minted bucket shares.
    struct DepositParams {
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
    }

    /// @notice Arguments for `withdraw`.
    /// @param tickLower Lower tick bound of the bucket.
    /// @param tickUpper Upper tick bound of the bucket.
    /// @param owner Holder whose bucket shares are burned.
    /// @param shareAmount Bucket shares to burn.
    /// @param recipient Receiver of the underlying.
    struct WithdrawParams {
        int24 tickLower;
        int24 tickUpper;
        address owner;
        uint256 shareAmount;
        address recipient;
    }

    // ---------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------

    /// @notice The v4 singleton that owns all pool state.
    IPoolManager public immutable poolManager;
    /// @notice ERC-4626 vault holding token0 (bank for currency0).
    IERC4626 public immutable vault0;
    /// @notice ERC-4626 vault holding token1 (bank for currency1).
    IERC4626 public immutable vault1;
    /// @notice Underlying token of `vault0` and currency0 of the pool.
    IERC20 public immutable token0;
    /// @notice Underlying token of `vault1` and currency1 of the pool.
    IERC20 public immutable token1;
    /// @notice ERC-1155 share token; one id per bucket.
    BucketShares public immutable shareToken;

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

    /// @dev Enumerated buckets; inactive entries are skipped during JIT.
    Bucket[] internal buckets;
    /// @dev keccak(lower, upper) => 1-based index into `buckets` (0 means "not present").
    mapping(bytes32 => uint256) internal bucketIndex;
    /// @dev Per bucket JIT add delta captured in `beforeSwap` and applied in `afterSwap`.
    mapping(bytes32 => int256) internal jitAdd0;
    mapping(bytes32 => int256) internal jitAdd1;

    /// @notice Cached sum of every bucket's token0 claim.
    uint256 public totalC0;
    /// @notice Cached sum of every bucket's token1 claim.
    uint256 public totalC1;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted on a successful deposit.
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
    event Withdrawn(
        address indexed owner,
        address indexed recipient,
        int24 lower,
        int24 upper,
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

    /// @notice Deploys the hook for a single pool backed by two ERC-4626 lending vaults.
    /// @dev The pool currencies are taken from `vault0.asset()` / `vault1.asset()`, which must be
    ///      sorted ascending (v4 requires `currency0 < currency1`). `initialOwner` is explicit
    ///      because CREATE2 deployment via the deterministic proxy makes `msg.sender` the proxy.
    /// @param _poolManager The v4 PoolManager singleton.
    /// @param _vault0 ERC-4626 vault whose asset is currency0.
    /// @param _vault1 ERC-4626 vault whose asset is currency1.
    /// @param _fee Pool LP fee.
    /// @param _tickSpacing Pool tick spacing.
    /// @param initialOwner Owner allowed to initialize the pool.
    constructor(
        IPoolManager _poolManager,
        IERC4626 _vault0,
        IERC4626 _vault1,
        uint24 _fee,
        int24 _tickSpacing,
        address initialOwner
    ) Ownable(initialOwner) {
        address a0 = _vault0.asset();
        address a1 = _vault1.asset();
        require(a0 < a1, "assets out of order");

        poolManager = _poolManager;
        vault0 = _vault0;
        vault1 = _vault1;
        token0 = IERC20(a0);
        token1 = IERC20(a1);

        // The hook owns the share token so it is the only minter/burner.
        shareToken = new BucketShares("", address(this));

        poolKey = PoolKey({
            currency0: Currency.wrap(a0),
            currency1: Currency.wrap(a1),
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: IHooks(address(this))
        });
        poolId = poolKey.toId();
    }

    //////////////////////////////////////////////////////////////////
    // P U B L I C   A D M I N
    //////////////////////////////////////////////////////////////////

    /// @notice Initializes the pool at the given starting price.
    /// @dev One-shot. The hook address must already encode the enabled permission bits.
    /// @param sqrtPriceX96 Initial pool price as a sqrt price in Q96.
    function initializePool(uint160 sqrtPriceX96) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        poolManager.initialize(poolKey, sqrtPriceX96);
        initialized = true;
    }

    /// @notice Adds liquidity to a tick range and deposits it into the lending vaults.
    /// @dev Only the tokens the range actually requires are pulled, so a range fully below spot
    ///      needs only token1 and a range fully above spot needs only token0: a real limit order.
    ///
    ///      Shares are minted at the current **pool price**:
    ///      `shares = valueIn * bucket.shares / valueBefore`. Because the deposit is priced the same
    ///      way as the bucket, an atomic deposit -> withdraw returns exactly the principal and does
    ///      not dilute existing yield.
    /// @param p Deposit parameters.
    /// @return sharesMinted Bucket shares minted to `p.recipient`.
    function deposit(DepositParams calldata p) external notJit returns (uint256 sharesMinted) {
        if (!initialized) revert PoolNotInitialized();
        if (p.tickLower >= p.tickUpper) revert InvalidRange();
        if (p.tickLower % poolKey.tickSpacing != 0 || p.tickUpper % poolKey.tickSpacing != 0) {
            revert InvalidRange();
        }

        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtP == 0) revert PoolNotInitialized();

        // Bring every bucket's claim up to date before pricing this deposit.
        _syncYield();

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(p.tickUpper);

        // Reserve the rounding buffer inside the user's budget.
        uint256 eff0 = p.amount0Desired > DEPOSIT_BUFFER ? p.amount0Desired - DEPOSIT_BUFFER : 0;
        uint256 eff1 = p.amount1Desired > DEPOSIT_BUFFER ? p.amount1Desired - DEPOSIT_BUFFER : 0;
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, eff0, eff1);
        if (liquidity == 0) revert NoLiquidity();

        (uint256 amount0, uint256 amount1) =
            _requiredAmounts(sqrtP, sqrtLower, sqrtUpper, liquidity);
        if (amount0 < p.amount0Min || amount1 < p.amount1Min) revert Slippage();

        // Vault share/asset rounding can leave the position a few wei short; keep a buffer so the
        // range can always be re-materialized exactly.
        uint256 pull0 = amount0 == 0 ? 0 : amount0 + DEPOSIT_BUFFER;
        uint256 pull1 = amount1 == 0 ? 0 : amount1 + DEPOSIT_BUFFER;
        if (pull0 > p.amount0Desired || pull1 > p.amount1Desired) revert Slippage();

        bytes32 key = _bucketKey(p.tickLower, p.tickUpper);
        uint256 idx = bucketIndex[key];
        uint256 valueIn = _valueAtPrice(pull0, pull1, sqrtP);
        if (valueIn == 0) revert ZeroShares();

        if (idx == 0) {
            sharesMinted = valueIn;
            buckets.push(
                Bucket({
                    lower: p.tickLower,
                    upper: p.tickUpper,
                    liquidity: liquidity,
                    shares: sharesMinted,
                    c0: pull0,
                    c1: pull1,
                    active: true
                })
            );
            bucketIndex[key] = buckets.length;
        } else {
            Bucket storage b = buckets[idx - 1];
            uint256 valueBefore = _valueAtPrice(b.c0, b.c1, sqrtP);
            sharesMinted = valueBefore == 0 ? valueIn : Math.mulDiv(valueIn, b.shares, valueBefore);
            b.c0 += pull0;
            b.c1 += pull1;
            b.liquidity += liquidity;
            b.shares += sharesMinted;
            b.active = true;
        }
        if (sharesMinted == 0) revert ZeroShares();

        shareToken.mint(p.recipient, uint256(key), sharesMinted);
        totalC0 += pull0;
        totalC1 += pull1;

        if (pull0 > 0) token0.safeTransferFrom(msg.sender, address(this), pull0);
        if (pull1 > 0) token1.safeTransferFrom(msg.sender, address(this), pull1);
        _deposit(token0, vault0, pull0);
        _deposit(token1, vault1, pull1);

        emit Deposited(p.recipient, p.tickLower, p.tickUpper, liquidity, pull0, pull1, sharesMinted);
    }

    /// @notice Burns bucket shares and pays out the bucket's pro-rata token claim.
    /// @dev If the bucket is one-sided (range out of the money), the payout is one-sided: the owner
    ///      of a resting token1 bid receives token1, or token0 once the price crossed.
    /// @param p Withdraw parameters.
    /// @return amount0 token0 paid out.
    /// @return amount1 token1 paid out.
    function withdraw(WithdrawParams calldata p)
        external
        notJit
        returns (uint256 amount0, uint256 amount1)
    {
        if (p.shareAmount == 0) revert ZeroShares();
        bytes32 key = _bucketKey(p.tickLower, p.tickUpper);
        uint256 idx = bucketIndex[key];
        if (idx == 0) revert NoBucket();
        if (msg.sender != p.owner && !shareToken.isApprovedForAll(p.owner, msg.sender)) {
            revert NotAuthorized();
        }
        if (shareToken.balanceOf(p.owner, uint256(key)) < p.shareAmount) {
            revert InsufficientShares();
        }

        _syncYield();

        Bucket storage b = buckets[idx - 1];
        uint256 total = b.shares;
        amount0 = Math.mulDiv(b.c0, p.shareAmount, total);
        amount1 = Math.mulDiv(b.c1, p.shareAmount, total);
        uint128 dl = uint128(Math.mulDiv(b.liquidity, p.shareAmount, total));

        b.c0 -= amount0;
        b.c1 -= amount1;
        b.liquidity -= dl;
        b.shares = total - p.shareAmount;
        shareToken.burn(p.owner, uint256(key), p.shareAmount);
        totalC0 -= amount0;
        totalC1 -= amount1;
        if (b.liquidity == 0) b.active = false;

        // Vault rounding can leave the bucket claim a few wei above the real position; pay out at
        // most what is actually held.
        amount0 = _payout(token0, vault0, amount0, p.recipient);
        amount1 = _payout(token1, vault1, amount1, p.recipient);

        emit Withdrawn(
            p.owner, p.recipient, p.tickLower, p.tickUpper, p.shareAmount, amount0, amount1
        );
    }

    /// @notice Realizes accrued vault yield into the buckets. Idempotent and safe to call anytime
    ///         off the JIT window; also lets an integrator refresh claims before quoting.
    function syncYield() external notJit {
        _syncYield();
    }

    //////////////////////////////////////////////////////////////////
    // V I E W S
    //////////////////////////////////////////////////////////////////

    /// @notice Real holdings of the vault: idle balance plus each lending vault position.
    /// @return amount0 token0 held (idle + vault0 position).
    /// @return amount1 token1 held (idle + vault1 position).
    function currentBalance() public view returns (uint256 amount0, uint256 amount1) {
        amount0 = token0.balanceOf(address(this))
            + vault0.convertToAssets(vault0.balanceOf(address(this)));
        amount1 = token1.balanceOf(address(this))
            + vault1.convertToAssets(vault1.balanceOf(address(this)));
    }

    /// @notice The token composition the vault would have if every range were materialized now.
    /// @return amount0 token0 required by all active buckets at the current price.
    /// @return amount1 token1 required by all active buckets at the current price.
    function virtualBalance() public view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtP == 0) return (0, 0);
        uint256 len = buckets.length;
        for (uint256 i = 0; i < len; i++) {
            Bucket memory b = buckets[i];
            if (!b.active || b.liquidity == 0) continue;
            (uint256 a0, uint256 a1) = _requiredAmounts(
                sqrtP,
                TickMath.getSqrtPriceAtTick(b.lower),
                TickMath.getSqrtPriceAtTick(b.upper),
                b.liquidity
            );
            amount0 += a0;
            amount1 += a1;
        }
    }

    /// @notice Cached sum of all buckets' token claims (underlying).
    /// @return The vault's total token0 and token1 claims.
    function totalClaim() external view returns (uint256, uint256) {
        return (totalC0, totalC1);
    }

    /// @notice Bucket shares owned by `user` in `(lower, upper)`.
    /// @param user Account to query.
    /// @param lower Lower tick bound.
    /// @param upper Upper tick bound.
    /// @return The user's bucket shares.
    function sharesOf(address user, int24 lower, int24 upper) external view returns (uint256) {
        return shareToken.balanceOf(user, uint256(_bucketKey(lower, upper)));
    }

    /// @notice Total shares of the bucket `(lower, upper)`.
    /// @param lower Lower tick bound.
    /// @param upper Upper tick bound.
    /// @return The bucket share supply.
    function totalSharesOf(int24 lower, int24 upper) external view returns (uint256) {
        uint256 idx = bucketIndex[_bucketKey(lower, upper)];
        return idx == 0 ? 0 : buckets[idx - 1].shares;
    }

    /// @notice Value of a bucket in token1 terms at the current pool price.
    /// @param lower Lower tick bound.
    /// @param upper Upper tick bound.
    /// @return The bucket claim value.
    function bucketValue(int24 lower, int24 upper) external view returns (uint256) {
        uint256 idx = bucketIndex[_bucketKey(lower, upper)];
        if (idx == 0) return 0;
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtP == 0) return 0;
        Bucket storage b = buckets[idx - 1];
        return _valueAtPrice(b.c0, b.c1, sqrtP);
    }

    /// @notice All buckets ever registered, including inactive ones.
    /// @return The bucket array.
    function getBuckets() external view returns (Bucket[] memory) {
        return buckets;
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

    /// @notice JIT step 1: sync yield, redeem the vaults and materialize every active bucket.
    /// @dev Redeems all lending vault shares to underlying, distributes yield across buckets, then
    ///      adds each bucket as a real v4 position and settles what those positions owe the
    ///      PoolManager. The per-bucket add delta is stored for `afterSwap`.
    /// @return The callback selector.
    /// @return A zero before-swap delta.
    /// @return A zero LP fee override.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (_activeLiquidity() == 0) revert NoLiquidity();

        jitActive = true;
        _redeemAll();

        // Now the hook holds all underlying: distribute the yield accrued since the last cycle.
        _syncYield();

        int256 need0;
        int256 need1;
        uint256 len = buckets.length;
        for (uint256 i = 0; i < len; i++) {
            Bucket storage b = buckets[i];
            if (!b.active || b.liquidity == 0) continue;
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: b.lower,
                    tickUpper: b.upper,
                    liquidityDelta: int256(uint256(b.liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            bytes32 k = _bucketKey(b.lower, b.upper);
            jitAdd0[k] = int256(delta.amount0());
            jitAdd1[k] = int256(delta.amount1());
            need0 += int256(delta.amount0());
            need1 += int256(delta.amount1());
        }
        _settleOwed(key, need0, need1);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice JIT step 2: remove every bucket, attribute PnL and fees, and re-deposit to the vaults.
    /// @dev Removing a bucket credits the hook a positive delta which is `take`n out. The bucket's
    ///      claim moves by the net of its add and remove deltas, so swap principal change and fees
    ///      land on the bucket that produced them. All PoolManager deltas are settled before the
    ///      vault deposit leg, so a caught deposit failure never leaves an unsettled delta.
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
        int256 net0;
        int256 net1;
        uint256 len = buckets.length;
        for (uint256 i = 0; i < len; i++) {
            Bucket storage b = buckets[i];
            if (!b.active || b.liquidity == 0) continue;
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: b.lower,
                    tickUpper: b.upper,
                    liquidityDelta: -int256(uint256(b.liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            bytes32 k = _bucketKey(b.lower, b.upper);
            int256 d0 = int256(delta.amount0()) + jitAdd0[k];
            int256 d1 = int256(delta.amount1()) + jitAdd1[k];
            b.c0 = uint256(int256(b.c0) + d0);
            b.c1 = uint256(int256(b.c1) + d1);
            net0 += d0;
            net1 += d1;
            take0 += int256(delta.amount0());
            take1 += int256(delta.amount1());
        }
        if (take0 > 0) poolManager.take(key.currency0, address(this), uint256(take0));
        if (take1 > 0) poolManager.take(key.currency1, address(this), uint256(take1));

        totalC0 = uint256(int256(totalC0) + net0);
        totalC1 = uint256(int256(totalC1) + net1);

        // Re-deploy everything; any leftover simply stays idle until the next cycle.
        _deposit(token0, vault0, token0.balanceOf(address(this)));
        _deposit(token1, vault1, token1.balanceOf(address(this)));

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

    /// @dev keccak of the tick bounds.
    function _bucketKey(int24 lower, int24 upper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(lower, upper));
    }

    /// @dev Bucket claim value in token1 terms at `sqrtP`: `value = c1 + c0 * price`.
    function _valueAtPrice(uint256 x0, uint256 x1, uint160 sqrtP) internal pure returns (uint256) {
        if (x0 == 0) return x1;
        uint256 pX96 = Math.mulDiv(sqrtP, sqrtP, 1 << 96); // raw token1 per token0, scaled by 2^96
        return x1 + Math.mulDiv(x0, pX96, 1 << 96);
    }

    /// @dev Distributes accrued vault yield across buckets, per token, pro-rata to their claims.
    ///      Yield is uniform per token, so no per-bucket history is needed; the cached totals are
    ///      then raised to the real balances (never lowered, to avoid underflow on withdrawal).
    function _syncYield() internal {
        (uint256 r0, uint256 r1) = currentBalance();
        uint256 t0 = totalC0;
        uint256 t1 = totalC1;
        uint256 len = buckets.length;

        if (r0 > t0 && t0 > 0) {
            uint256 yield0 = r0 - t0;
            for (uint256 i = 0; i < len; i++) {
                Bucket storage b = buckets[i];
                if (b.c0 == 0) continue;
                b.c0 += Math.mulDiv(yield0, b.c0, t0);
            }
            totalC0 = r0;
        }
        if (r1 > t1 && t1 > 0) {
            uint256 yield1 = r1 - t1;
            for (uint256 i = 0; i < len; i++) {
                Bucket storage b = buckets[i];
                if (b.c1 == 0) continue;
                b.c1 += Math.mulDiv(yield1, b.c1, t1);
            }
            totalC1 = r1;
        }
    }

    /// @dev Token amounts a range needs at `sqrtP`, rounded UP exactly like the PoolManager does.
    function _requiredAmounts(
        uint160 sqrtP,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtP <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (sqrtP < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtP, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }

    /// @dev Deposits `amount` into the ERC-4626 `vault`. On failure tokens stay idle in the hook.
    function _deposit(IERC20 token, IERC4626 vault, uint256 amount) internal {
        if (amount == 0) return;
        token.forceApprove(address(vault), amount);
        try vault.deposit(amount, address(this)) {}
        catch {
            // Drop the dangling allowance; the tokens remain in the hook and count in balances.
            token.forceApprove(address(vault), 0);
        }
    }

    /// @dev Redeems the entire position of `vault` back to underlying held by the hook.
    function _redeemAll(IERC4626 vault) internal {
        uint256 shares = vault.balanceOf(address(this));
        if (shares > 0) vault.redeem(shares, address(this), address(this));
    }

    /// @dev Redeems both lending vaults to idle underlying (JIT funding step).
    function _redeemAll() internal {
        _redeemAll(vault0);
        _redeemAll(vault1);
    }

    /// @dev Pays up to `amount` of `token` to `to`, using idle balance first then the vault, and
    ///      returns the amount actually paid (clamped to the real position).
    function _payout(IERC20 token, IERC4626 vault, uint256 amount, address to)
        internal
        returns (uint256 paid)
    {
        if (amount == 0) return 0;
        uint256 idle = token.balanceOf(address(this));
        if (idle >= amount) {
            token.safeTransfer(to, amount);
            return amount;
        }
        if (idle > 0) token.safeTransfer(to, idle);

        uint256 remaining = amount - idle;
        uint256 position = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 fromVault = remaining > position ? position : remaining;
        if (fromVault > 0) vault.withdraw(fromVault, to, address(this));
        paid = idle + fromVault;
    }

    /// @dev Sum of liquidity across active buckets; used to reject swaps with no depth.
    function _activeLiquidity() internal view returns (uint256 total) {
        uint256 len = buckets.length;
        for (uint256 i = 0; i < len; i++) {
            if (buckets[i].active) total += buckets[i].liquidity;
        }
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
