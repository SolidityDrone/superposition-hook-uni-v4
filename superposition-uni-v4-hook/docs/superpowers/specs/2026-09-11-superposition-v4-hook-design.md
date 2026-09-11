# Superposition v4 Hook — Design

- **Date:** 2026-09-11
- **Status:** Approved for planning
- **Network target:** Base mainnet (fork-tested), Base addresses used throughout
- **Branch:** `superposition-hook`

## 1. Goal

Build a Uniswap v4 concentrated-liquidity hook that keeps **100% of pooled capital working in Aave v3** between swaps, while presenting a normal CL pool to swappers.

Users deposit into the hook. The hook mints **internal vault shares** (ERC-4626-style accounting, no real ERC20 required) that represent a proportional claim on the vault. Yield earned by the Aave aTokens raises the value of those shares. A user who joins and exits within the same block must receive back only the value they put in, so they cannot skim yield accrued by earlier depositors.

## 2. Non-goals

- No external yield-accounting oracle or off-chain proof system. Yield is measured directly by the on-chain aToken balances.
- No ERC20 share token. Shares are internal accounting only.
- No adapter layer in this phase. The hook is built and fork-validated first; an adapter is a later deliverable.
- No multi-pool factory. A single hook instance serves one `PoolKey` (WETH/USDC for this phase), parameterized by currency pair and oracle feeds.

## 3. Background: Uniswap v4 primitives used

- A single `PoolManager` singleton holds pool state. `modifyLiquidity` updates `pool.liquidity`, the tick bitmap and `sqrtPriceX96`, and returns a `BalanceDelta` owed by the caller.
- `BalanceDelta` values must net to zero across all accounts before the lock is released (`nonZeroDeltaCount == 0`).
- Hooks run inside the active lock and may call `modifyLiquidity`, `sync`, `settle`, `take`, and `mint`.
- `beforeSwap` runs before swap math, so liquidity added there is visible to the swap. `afterSwap` runs after the price has moved.
- A hook registered with the add/remove-liquidity permissions can reject liquidity operations from any sender except itself.

## 4. Architecture

Single contract, `SuperpositionHook`, which is both the v4 hook and the vault.

### 4.1 Data model

```solidity
struct Range {
    int24 lower;
    int24 upper;
    uint128 liquidity;   // aggregate CL liquidity for this exact range
    bool active;
}

// immutable / config
PoolKey internal poolKey;
PoolId  internal poolId;
AggregatorV3Interface internal ethUsdFeed;   // Chainlink ETH/USD, 8 decimals
AggregatorV3Interface internal usdcUsdFeed;  // Chainlink USDC/USD, 8 decimals
address internal immutable aavePool;
address internal immutable aWETH;
address internal immutable aUSDC;

// vault state
uint256 internal totalShares;
mapping(address => uint256) internal shares;
Range[] internal ranges;                       // enumerated active buckets
mapping(bytes32 => uint256) internal rangeId;  // keccak(lower,upper) => index+1
bool internal jitActive;                       // reentrancy guard for the JIT window
```

Constants: `MINIMUM_SHARES = 1e3`; `VIRTUAL_SHARES = 1e3`; `VIRTUAL_ASSETS = 1e3`; `WAD = 1e18`.

### 4.2 Valuation

`totalAssets()` returns the USD value (1e18 scale) of the vault's real holdings:

```
ethUnderlying  = aWETH.balanceOf(hook) + idle WETH
usdcUnderlying = aUSDC.balanceOf(hook) + idle USDC
totalAssets    = ethUnderlying  * ethUsdPrice  / 1e8          // WETH has 18 decimals
               + usdcUnderlying * usdcUsdPrice * 1e12 / 1e8   // USDC has 6 decimals
```

Chainlink feeds are used instead of the v4 spot price so share minting cannot be manipulated by sandwiching the pool. Stale rounds (`updatedAt == 0` or older than a configured heartbeat) revert.

### 4.3 Share math (ERC-4626 equivalent)

```
convertToShares(assets)  = assets * (totalShares + VIRTUAL_SHARES) / (totalAssets() + VIRTUAL_ASSETS)
convertToAssets(shares)  = shares * (totalAssets() + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)
```

- **First deposit** mints `1:1` plus `MINIMUM_SHARES`, which are permanently locked (minted to `address(0)` / dead address) to remove the empty-vault inflation attack surface.
- The virtual offsets bound the donation/inflation attack for all later deposits.

### 4.4 Deposit flow

`deposit(DepositParams params)`:

1. Revert if `jitActive` (mid-swap).
2. Read `sqrtPriceX96` and check the pool is initialized.
3. `liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, amount0Desired, amount1Desired)`.
4. `(amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, liquidity)` — this yields `amount0 == 0` for a range fully above spot and `amount1 == 0` for a range fully below spot, enabling true one-sided limit orders.
5. Enforce `amount0 >= amount0Min && amount1 >= amount1Min` (slippage). Revert on zero liquidity.
6. Pull exactly `(amount0, amount1)` from the user.
7. Add/merge `liquidity` into the bucket keyed by `(tickLower, tickUpper)`; register the bucket in `ranges` if new.
8. Supply the pulled tokens to Aave inside `try/catch`. If the supply reverts, the tokens stay in the hook as idle balance (still counted in `totalAssets`).
9. Mint shares from the **deposited value** using the share math above.
10. Emit `Deposited`.

Because the vault's holdings always equal the sum of every bucket's composition at the current price (§4.6), pulling exactly the range-required amounts keeps the vault fully backed by its aggregate virtual position.

### 4.5 Withdraw flow

`withdraw(uint256 shareAmount, address recipient)`:

1. Revert if `jitActive`; revert on zero shares.
2. `f = shareAmount / totalShares`.
3. For each active bucket: reduce `liquidity` by `f`; mark inactive when it reaches zero.
4. For each underlying: read the **idle** balance first, then `aavePool.withdraw(asset, f * aTokenBalance, recipient)`, then transfer the pro-rata idle slice to the recipient.
5. Burn shares; emit `Withdrawn`.

Exit returns a pro-rata slice of real assets (`aWETH`, `aUSDC`, idle) and needs no oracle. Yield accrued since a deposit is therefore only ever captured by pre-existing shares.

### 4.6 JIT swap lifecycle

Between swaps the pool holds **zero real liquidity**; capital sits in Aave.

`beforeSwap`:
1. Revert if no active liquidity; set `jitActive = true`.
2. Withdraw all aWETH/aUSDC from Aave to the hook.
3. For every active bucket: `poolManager.modifyLiquidity(key, {lower, upper, +L, salt: 0}, "")`, then settle the returned negative delta for each currency via `sync` → transfer → `settle`.
4. Return `(beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0)`.

Swap executes against real CL liquidity added in step 3.

`afterSwap`:
1. For every active bucket: `modifyLiquidity(..., -L ...)`.
2. `poolManager.take(currency, hook, amount)` the positive delta for each currency.
3. Supply all underlying held by the hook back to Aave inside `try/catch`.
4. `jitActive = false`; return the selector.

All hook deltas are zeroed inside the lock, satisfying the v4 invariant.

### 4.7 Access control

- `beforeAddLiquidity` / `beforeRemoveLiquidity` revert unless `sender == address(this)`, so users cannot add or remove pool liquidity directly; all entry is through the vault.
- `beforeSwap`/`afterSwap`/add/remove callbacks are gated to `PoolManager`.
- Pool is initialized once by the deployer; `initialize` is one-shot.

### 4.8 Views

- `currentBalance()` → `(wethUnderlying, usdcUnderlying)` real holdings.
- `virtualBalance()` → `(wethRequired, usdcRequired)` the aggregate bucket composition at the current price.
- `totalAssets()` → USD 1e18.
- `sharePrice()` → assets per 1e18 shares.
- `convertToShares` / `convertToAssets` / `previewDeposit` / `previewWithdraw`.
- `balanceOf(address)` shares; `totalSupply()`.
- `getRanges()` → the active bucket list.

## 5. Error handling

- **Aave supply failure (deposit):** `try aavePool.supply(...) catch {}`. Tokens remain idle; `totalAssets` includes idle balances so shares are still correctly priced.
- **Aave supply failure (post-swap):** same; the hook carries idle tokens into the next cycle.
- **Aave withdrawal failure:** propagates the Aave revert. Partial-liquidity edge cases revert rather than silently underpay.
- **Zero liquidity / uninitialized pool / zero shares:** explicit custom errors.
- **Reentrancy:** `jitActive` blocks deposit/withdraw during the swap callbacks.

## 6. Testing strategy

Foundry, Base mainnet fork pinned to a recent block; `mainnet.base.org` public RPC (archive not required for recent state).

Real contracts, no mocks, for the integration suite:

| Contract | Address |
|---|---|
| v4 `PoolManager` | `0x498581fF718922c3f8e6A244956aF099B2652b2B` |
| Aave v3 `Pool` | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| aUSDC | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |
| WETH | `0x4200000000000000000000000000000000000006` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Chainlink ETH/USD | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| Chainlink USDC/USD | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` |

Pool parameters: WETH as `currency0`, USDC as `currency1`, fee `500`, tickSpacing `10`.

A minimal in-repo `TestSwapRouter` performs the `unlock`/`swap`/`settle`/`take` cycle so the hook's JIT path is exercised without pulling in the full periphery.

Test cases:

1. **Two-sided deposit** — WETH+USDC at a range around spot; assert shares minted, aToken balances hold 100% of capital, idle balance is zero.
2. **Yield accrual + fair exit** — simulate Aave yield (advance Aave's reserve index / seed idle underlying), then assert share price rose and a later depositor who joins and exits atomically receives only their principal.
3. **One-sided out-of-range limit order** — deposit USDC only at a tick range above spot; assert no WETH is pulled, the bucket is registered, `virtualBalance` shows USDC only, and a swap that pushes price into the range converts part of the USDC into WETH.
4. **Full JIT swap cycle** — deposit, swap in both directions, assert price moves, capital returns to Aave after each swap, and hook deltas net to zero.
5. **Try/catch** — force the Aave supply leg to fail and assert deposit still succeeds with idle tokens and correct share pricing.
6. **Access control** — direct `modifyLiquidity` by a non-hook address reverts; deposit/withdraw during a swap reverts.
7. **Invariants (fuzz)** — for randomized deposit/withdraw/swap sequences: `totalSupply == sum(balances)`, `totalAssets >= sum of share claims` (solvency), one-sided deposits never pull the zero side.

## 7. Repository layout

```
foundry.toml
src/
  SuperpositionHook.sol
  interfaces/
    IAavePool.sol
    IAggregatorV3.sol
  libraries/
    ShareMath.sol
test/
  SuperpositionHookBaseFork.t.sol
  helpers/TestSwapRouter.sol
script/
  DeployHook.s.sol
  BaseAddresses.sol
docs/
  superpowers/specs/2026-09-11-superposition-v4-hook-design.md
README.md
```

Dependencies (git submodules): `Uniswap/v4-core`, `Uniswap/v4-periphery` (for `LiquidityAmounts`/`TickMath`), `foundry-rs/forge-std`, `OpenZeppelin/openzeppelin-contracts` (Math/FullMath/ReentrancyGuard/IERC20/SafeERC20).

## 8. Security considerations

- Share pricing uses Chainlink, not the maniputable v4 spot price; stale/zero rounds revert.
- Empty-vault inflation attack mitigated by locked minimum shares + virtual offsets.
- `jitActive` guard prevents reentrant deposits/withdrawals during the swap window.
- Withdrawals pay out a pro-rata slice of actual on-chain balances, so the vault cannot become insolvent through accounting drift.
- Rounding is always in the vault's favor on deposit minting and in the user's favor is avoided on withdrawal by flooring payouts.
- Aave withdrawal is bounded by available pool liquidity; large withdrawals may need smaller steps (documented limitation, not hidden).

## 9. Future work (out of scope now)

- Adapter exposing the hook's shares to external protocols/aggregators.
- Multi-pair deployment via factory and an oracle registry.
- TWAP fallback for feeds and configurable heartbeats.
- Withdrawal batching for Aave liquidity-constrained reserves.
