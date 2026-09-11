# Superposition v4 Hook

A Uniswap v4 concentrated-liquidity hook that keeps **100% of pooled capital earning yield in
Aave v3** between swaps, while presenting a normal CL pool to swappers.

```
deposit ──▶ vault shares ──▶ Aave aWETH / aUSDC        (capital at work, always)
                                   │
swap ──▶ beforeSwap: withdraw ──▶ add ranges as real v4 liquidity ──▶ swap
         afterSwap:  remove ranges ──▶ take ──▶ supply everything back to Aave
```

The pool's liquidity is effectively **virtual**: it is materialized only for the duration of a
swap transaction, then unwound. Because the Aave position is closed and reopened inside the same
transaction, its supply rate and utilization are unaffected.

## Features

- **ERC-4626 style shares.** Users deposit into the hook and receive internal shares (no ERC20
  needed). Withdrawals return a pro-rata slice of the vault's real `aWETH`/`aUSDC` balances, so
  accrued yield belongs only to the shares that were present while it accrued. An atomic
  join → exit earns nothing.
- **Real concentrated liquidity.** Any tick range is supported. `beforeSwap` adds every active
  range to the v4 pool, `afterSwap` removes it, so ticks, fees and price impact behave exactly
  like a normal v4 CL pool.
- **One-sided limit orders.** A range fully below spot needs only USDC; a range fully above spot
  needs only WETH. Deposits can supply a single side.
- **Aave-hardened.** The supply leg is wrapped in `try/catch`; if Aave rejects the deposit the
  tokens stay idle in the vault and are still counted in `totalAssets`.
- **Chainlink-priced shares.** Shares are minted against a Chainlink USD valuation of the vault's
  two assets, so minting cannot be manipulated through the pool.

## Contracts

| File | Purpose |
|---|---|
| `src/SuperpositionHook.sol` | The hook and vault: deposits, withdrawals, JIT liquidity, share accounting |
| `src/libraries/LiquidityAmounts.sol` | Range liquidity ⇄ token amount math |
| `src/libraries/ShareMath.sol` | ERC-4626 style share conversion with virtual offsets |
| `src/libraries/HookMiner.sol` | CREATE2 salt search for the v4 permission bits |
| `src/interfaces/IAavePool.sol` | Aave v3 pool subset |
| `src/interfaces/IAggregatorV3.sol` | Chainlink feed subset |

## Share model

`totalAssets()` is the USD value of `aWETH + idle WETH` and `aUSDC + idle USDC` at Chainlink
prices. A deposit mints:

```
shares = valueIn * (totalSupply + 1e3) / (totalAssetsBefore + 1e3)
```

A withdrawal burns shares and pays `shares / totalSupply` of **each** real balance (aTokens plus
idle), so no oracle is needed on exit. Aave v3.2 already index-accrues `aToken.balanceOf`, so the
aToken balance is the underlying amount and yield needs no extra accounting.

## Views

- `currentBalance()` — real WETH/USDC holdings (aTokens + idle)
- `virtualBalance()` — the per-range composition at the current price
- `totalAssets()`, `sharePrice()`, `convertToShares()`, `convertToAssets()`
- `balanceOf(address)`, `totalSupply()`, `getRanges()`

## Build and test

```bash
forge build
forge test
```

Fork tests run against Base mainnet (`https://mainnet.base.org`) with real Uniswap v4, real Aave
v3 and real Chainlink feeds — no mocks except the forced Aave-failure case.

Test coverage: two-sided deposits, pro-rata withdrawals, full JIT swap cycle, USDC-only limit
orders and their fill on cross, share-price fairness (atomic join/exit earns no yield), Aave
failure fallback, hook access control, and multi-LP full exit.

## Deploy

```bash
forge script script/DeployHook.s.sol --rpc-url base --broadcast
```

Deployment goes through the deterministic CREATE2 proxy so the hook address encodes the required
v4 permission bits.

## Base addresses

| Contract | Address |
|---|---|
| v4 `PoolManager` | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Aave v3 `Pool` | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| WETH / aWETH | `0x4200…0006` / `0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7` |
| USDC / aUSDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` / `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |
| Chainlink ETH/USD | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| Chainlink USDC/USD | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` |

Pool parameters: WETH `currency0`, USDC `currency1`, fee `500`, tickSpacing `10`.

## Limitations

- Valuation is ETH/USDC-specific (two Chainlink feeds) in this revision.
- Aave withdrawal is bounded by pool liquidity; very large withdrawals may need batching.
- The vault is a single pool; a multi-pair factory and an external adapter are future work.
