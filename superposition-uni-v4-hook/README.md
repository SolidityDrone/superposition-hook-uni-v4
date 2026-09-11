# Superposition v4 Hook

A Uniswap v4 concentrated-liquidity hook that keeps **100% of pooled capital in Aave v3**
between swaps while presenting a normal CL pool to swappers.

- Users deposit into the hook and receive internal **ERC-4626-style shares** (no ERC20).
- Capital is supplied to Aave and held as aTokens; yield raises the share price.
- Around every swap the hook JIT-withdraws from Aave, materializes the pool's tick ranges
  as real v4 liquidity, executes, then removes and re-supplies everything.
- Supports true one-sided, out-of-range deposits (limit orders).

See `docs/superpowers/specs/2026-09-11-superposition-v4-hook-design.md` for the design.

## Build

```bash
forge build
forge test
```

Fork tests run against Base mainnet (`https://mainnet.base.org`).
