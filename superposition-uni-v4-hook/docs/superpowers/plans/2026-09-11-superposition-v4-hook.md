# Superposition v4 Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and fork-test a Uniswap v4 concentrated-liquidity hook whose capital sits 100% in Aave v3 between swaps, with ERC-4626-style internal shares so yield is shared fairly.

**Architecture:** One contract `SuperpositionHook` is both the v4 hook and the vault. Deposits ship tokens straight to Aave and record aggregate CL liquidity per tick range. `beforeSwap` JIT-withdraws from Aave and materializes every range as real v4 liquidity; `afterSwap` removes it and re-supplies everything to Aave. Shares are minted against a Chainlink-valued `totalAssets()` and redeemed pro-rata per token (no oracle needed on exit).

**Tech Stack:** Solidity 0.8.26, Foundry (forge 1.5.0), Uniswap v4-core v4.0.0, OpenZeppelin v5.1.0, Base mainnet fork (`mainnet.base.org`).

## Global Constraints

- Solidity `0.8.26`, `evm_version = "cancun"`.
- Network: Base mainnet fork only. Real contracts, no mocks except the forced-failure test.
- Never add an off-chain prover, and never reference any prior project.
- WETH = `currency0`, USDC = `currency1`, fee = `500`, tickSpacing = `10`.
- All hook actions are gated: only the PoolManager may call callbacks; only the hook may add/remove pool liquidity.
- `totalAssets()` uses Chainlink ETH/USD + USDC/USD (8 decimals); aToken `balanceOf` on Base is already index-accrued.
- Every task ends with `forge build`/`forge test` green and a commit.

---

### Task 1: Scaffold the Foundry project

**Files:**
- Create: `foundry.toml`, `.gitignore`, `remappings.txt`, `README.md`
- Already present: `lib/forge-std`, `lib/v4-core@v4.0.0`, `lib/openzeppelin-contracts@v5.1.0`

**Steps**

- [ ] Write `foundry.toml` (root = repo subdir, solc 0.8.26, cancun, optimizer on, `[rpc_endpoints] base`).
- [ ] Write `remappings.txt`:
  ```
  @uniswap/v4-core/=lib/v4-core/
  @openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
  forge-std/=lib/forge-std/src/
  ```
- [ ] Write `.gitignore`: `out/`, `cache/`, `broadcast/`, `.env`, `node_modules/`.
- [ ] Write `README.md` describing the hook (no external project references).
- [ ] `forge build` → compiles (empty project is fine).
- [ ] Commit: `chore: scaffold foundry project and dependencies`.

---

### Task 2: Token math libraries (TDD)

**Files:**
- Create: `src/libraries/LiquidityAmounts.sol` (vendored Uniswap MIT, imports v4-core `FullMath`/`FixedPoint96`)
- Create: `src/libraries/ShareMath.sol`
- Test: `test/LiquidityAmounts.t.sol`, `test/ShareMath.t.sol`

**Interfaces**
- `LiquidityAmounts.getLiquidityForAmounts(uint160 sqrtX96, uint160 sqrtAX96, uint160 sqrtBX96, uint256 amount0, uint256 amount1) returns (uint128)`
- `LiquidityAmounts.getAmountsForLiquidity(uint160 sqrtX96, uint160 sqrtAX96, uint160 sqrtBX96, uint128 liquidity) returns (uint256 amount0, uint256 amount1)`
- `ShareMath.toShares(uint256 assets, uint256 totalAssetsBefore, uint256 totalShares) returns (uint256)`
- `ShareMath.toAssets(uint256 shares, uint256 totalAssets, uint256 totalSupply) returns (uint256)`

- [ ] Write `test/LiquidityAmounts.t.sol`: for spot inside `[lower, upper]`, `getLiquidityForAmounts` then `getAmountsForLiquidity` round-trips within rounding; for spot **below** range, `amount1 == 0`; for spot **above**, `amount0 == 0`. Run → FAIL (library missing).
- [ ] Implement `LiquidityAmounts.sol`; run → PASS.
- [ ] Write `test/ShareMath.t.sol`: first deposit 1:1; second deposit into a doubled-asset vault mints half the shares; withdrawal of all shares returns all assets; virtual-offset keeps `toShares(0) == 0`. Run → FAIL.
- [ ] Implement `ShareMath.sol` with `VIRTUAL_SHARES = 1e3`, `VIRTUAL_ASSETS = 1e3` using OZ `Math.mulDiv`. Run → PASS.
- [ ] Commit: `feat: add liquidity and share math libraries`.

---

### Task 3: Hook skeleton, config, and views

**Files:**
- Create: `src/interfaces/IAavePool.sol`, `src/interfaces/IAggregatorV3.sol`
- Create: `src/SuperpositionHook.sol`
- Test: `test/SuperpositionHookBaseFork.t.sol` (setUp only for now)

**Interfaces (exact)**
- Inherit `IHooks`; implement all callbacks.
- Constructor: `(IPoolManager manager, address aavePool, address weth, address usdc, address aWeth, address aUsdc, IAggregatorV3 ethUsd, IAggregatorV3 usdcUsd)`.
- `function initializePool(uint160 sqrtPriceX96) external onlyOwner`.
- `function currentBalance() external view returns (uint256 wethAmt, uint256 usdcAmt)`.
- `function virtualBalance() external view returns (uint256 wethAmt, uint256 usdcAmt)`.
- `function totalAssets() public view returns (uint256)`.
- `function convertToShares(uint256 assets) public view returns (uint256)`.
- `function convertToAssets(uint256 s) public view returns (uint256)`.
- `function sharePrice() external view returns (uint256)`.
- `function balanceOf(address) external view returns (uint256)`; `totalSupply()`.

**Setup details**
- Build `PoolKey` in the constructor with `hooks: IHooks(address(this))`.
- Deploy via `HookMiner.find(address(this), flags, type(SuperpositionHook).creationCode, abi.encode(args))` then `new SuperpositionHook{salt: salt}(...)`.
- Desired `flags = BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG` (bits 11, 9, 7, 6). Masked to 14 bits.
- `initializePool` calls `poolManager.initialize(poolKey, price)`.

- [ ] Write `HookMiner` at `test/utils/HookMiner.sol` (CREATE2 brute force, expected ~16k iterations).
- [ ] Write setUp: fork Base, deploy hook via miner, init pool at a price derived from the live Chainlink feeds, `deal` WETH/USDC to a test LP.
- [ ] Write test: `currentBalance()` is `(0,0)` before deposits; `sharePrice()` is `1e18`; `totalAssets()` is `0`.
- [ ] Implement `SuperpositionHook.sol` skeleton + views; run → PASS.
- [ ] Commit: `feat: add hook skeleton, pool init, and balance views`.

---

### Task 4: Deposit and range tracking (TDD)

**Files:**
- Modify: `src/SuperpositionHook.sol`
- Test: `test/SuperpositionHookBaseFork.t.sol`

**Interfaces**
- `struct DepositParams { int24 tickLower; int24 tickUpper; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; address recipient; }`
- `function deposit(DepositParams calldata p) external returns (uint256 sharesMinted)`
- Events: `Deposited(address indexed recipient, int24 lower, int24 upper, uint128 liquidity, uint256 amount0, uint256 amount1, uint256 shares)`.
- Errors: `JitActive()`, `NoLiquidity()`, `Slippage()`, `InvalidRange()`, `PoolNotInitialized()`.
- Getter: `function getRanges() external view returns (Range[] memory)`.

**Logic**
1. Revert `JitActive`.
2. `(sqrtP,,,) = poolManager.getSlot0(poolId)`; revert `PoolNotInitialized` if 0.
3. `L = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0Desired, amount1Desired)`.
4. `(a0,a1) = LiquidityAmounts.getAmountsForLiquidity(...)`; require `L > 0`, `a0 >= amount0Min`, `a1 >= amount1Min`.
5. `preTotal = totalAssets()` (before pulling).
6. `transferFrom` a0 WETH and a1 USDC.
7. `_addRange(lower, upper, L)`.
8. `_supply(weth, a0)`, `_supply(usdc, a1)` (try/catch, tokens idle on failure).
9. `value = _value(a0, a1)`; first deposit seeds `MINIMUM_SHARES = 1e3` to `address(0)`; `shares = ShareMath.toShares(value, preTotal, totalShares)`.
10. `_mint(recipient, shares)`, emit.

- [ ] Write test `test_fork_deposit_two_sided`: deposit 1 WETH / 2600 USDC around spot; assert `currentBalance() == (1e18, 2600e6)`, idle balances 0, aWETH/aUSDC balances > 0, shares > 0, `getRanges().length == 1`. Run → FAIL.
- [ ] Implement deposit + `_supply` + `_addRange` + internal mint. Run → PASS.
- [ ] Commit: `feat: add two-sided deposits backed by Aave`.

---

### Task 5: Withdraw and proportional range reduction (TDD)

**Files:**
- Modify: `src/SuperpositionHook.sol`
- Test: `test/SuperpositionHookBaseFork.t.sol`

**Interfaces**
- `function withdraw(uint256 shareAmount, address recipient) external returns (uint256 wethOut, uint256 usdcOut)`.
- Event: `Withdrawn(address indexed owner, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1)`.

**Logic**
1. Revert `JitActive`, zero shares, or `shareAmount > balanceOf[msg.sender]`.
2. Read idle and aToken balances; `f = shareAmount / totalShares`.
3. Reduce every active range's `liquidity` by `f` (mark inactive at zero).
4. `withdraw` the `f` share of each aToken from Aave to recipient; transfer the `f` share of idle.
5. `_burn(msg.sender, shareAmount)`; emit.

- [ ] Write test `test_fork_withdraw_returns_principal`: deposit, then withdraw all; assert WETH/USDC returned within 1 wei of deposit, shares 0, ranges inactive, `totalAssets() == 0`.
- [ ] Write test `test_fork_withdraw_half`: withdraw half; assert balances and remaining range liquidity both halve.
- [ ] Implement; run → PASS.
- [ ] Commit: `feat: add pro-rata withdrawals and range reduction`.

---

### Task 6: JIT liquidity on swaps (TDD)

**Files:**
- Create: `test/helpers/TestSwapRouter.sol`
- Modify: `src/SuperpositionHook.sol`
- Test: `test/SuperpositionHookBaseFork.t.sol`

**`TestSwapRouter`** implements `unlockCallback`: decode `(PoolKey, bool zeroForOne, int256 amountSpecified, uint160 limit, address payer)`, call `poolManager.swap`, `sync`+`transferFrom`+`settle` the negative delta, `take` the positive delta to `payer`.

**Hook logic**
- `beforeSwap`: revert `NoLiquidity` if no active range; set `jitActive`; withdraw all aWETH/aUSDC; for each active range `modifyLiquidity(+L)` accumulating `need0/need1`; `sync`+`transfer`+`settle` each owed currency; return `(selector, ZERO_DELTA, 0)`.
- `afterSwap`: for each active range `modifyLiquidity(-L)` accumulating positive deltas; `take` each; `_supply` all WETH/USDC back to Aave; clear `jitActive`; return `(selector, 0)`.
- `beforeAddLiquidity`/`beforeRemoveLiquidity`: `require(sender == address(this))`.

- [ ] Write `test_fork_swap_jit_cycle`: deposit 1 WETH / 2600 USDC; swap 0.1 WETH → USDC via router; assert spot price moved down, idle hook balance 0 after, aToken balances > 0, and a reverse swap moves price back. Run → FAIL.
- [ ] Implement JIT paths. Run → PASS.
- [ ] Commit: `feat: JIT-add v4 liquidity around swaps and re-deposit to Aave`.

---

### Task 7: One-sided out-of-range limit order (TDD)

**Files:**
- Test: `test/SuperpositionHookBaseFork.t.sol`

- [ ] Write `test_fork_one_sided_usdc_limit_order`: pick `tickLower` > current tick aligned to spacing; call deposit with `amount0Desired = 0`, `amount1Desired = 3000e6`; assert WETH pulled == 0, USDC pulled > 0, `virtualBalance().wethAmt == 0`, `virtualBalance().usdcAmt > 0`, shares > 0.
- [ ] Write `test_fork_limit_order_fills_on_cross`: deposit USDC-only above spot; perform a large WETH→USDC swap that pushes price into the range; assert the vault's WETH `currentBalance()` increased and USDC decreased (limit order filled).
- [ ] Both should pass with existing logic; fix range/tick alignment and `MIN_TICK + spacing` clamping as needed.
- [ ] Commit: `test: prove one-sided out-of-range limit orders`.

---

### Task 8: Yield fairness and try/catch

**Files:**
- Create: `test/helpers/AaveBorrower.sol`
- Modify: `test/SuperpositionHookBaseFork.t.sol`

- [ ] Write `test_fork_share_price_rises_with_aave_yield`: deposit; create USDC utilization with `AaveBorrower` (supply WETH collateral, borrow USDC); `vm.warp(365 days)`; poke Aave; assert `sharePrice() > 1e18` and `aUSDC.balanceOf(hook)` grew.
- [ ] Write `test_fork_atomic_join_exit_earns_no_yield`: after yield, new LP deposits and immediately withdraws in the same block; assert returned WETH/USDC within rounding of deposited and existing holder's `convertToAssets` unchanged.
- [ ] Write `test_fork_deposit_survives_aave_failure`: `vm.mockCallRevert(aavePool, abi.encodeWithSelector(supply.selector,...))`; deposit; assert it succeeds, tokens are idle, `totalAssets()` includes them, shares minted.
- [ ] Commit: `test: prove yield fairness and Aave failure fallback`.

---

### Task 9: Access control, reentrancy, invariants

**Files:**
- Test: `test/SuperpositionHookBaseFork.t.sol`, `test/Invariants.t.sol`

- [ ] `test_direct_modify_liquidity_reverts`: external `poolManager.modifyLiquidity` on the pool reverts (hook rejects sender).
- [ ] `test_deposit_during_swap_reverts`: malicious router calls `hook.deposit` inside `unlockCallback` during a swap; expect `JitActive`.
- [ ] `testFuzz_solvency`: randomized deposit/withdraw sequences keep `totalAssets() >= sum(balanceOf * sharePrice)` (floor) and `currentBalance() == aToken + idle`.
- [ ] Commit: `test: access control, reentrancy, and solvency invariants`.

---

### Task 10: Deploy script, README, final verification

**Files:**
- Create: `script/BaseAddresses.sol`, `script/DeployHook.s.sol`
- Modify: `README.md`

- [ ] `BaseAddresses.sol` holds the verified Base addresses (PoolManager, Aave Pool, WETH, USDC, aTokens, Chainlink feeds).
- [ ] `DeployHook.s.sol` mines the salt, deploys the hook, initializes the pool, logs addresses.
- [ ] `README.md`: what it is, architecture, the share model, how to run fork tests, addresses.
- [ ] Run `forge fmt`, `forge build`, `forge test -vv`; all green.
- [ ] Commit: `chore: add deployment script and project README`.

---

## Self-Review

- **Spec coverage:** deposits/withdrawals (4,5), virtual+current views (3), 100% Aave (4,6), 4626 shares (2,4,8), one-sided limit orders (7), try/catch (8), views (3), Base fork ETH/USDC (all), commits per task. Adapter explicitly out of scope.
- **Type consistency:** `Range` fields (`lower`,`upper`,`liquidity`,`active`), `PoolKey` WETH-first, `DepositParams` field names, `JitActive`/`NoLiquidity` errors used consistently.
- **Open risk:** `deal` for USDC on Base fork may need `vm.store` fallback; resolved during Task 3.
