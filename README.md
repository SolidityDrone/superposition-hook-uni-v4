# superposition-hook-uni-v4

A Uniswap v4 concentrated-liquidity hook whose capital sits 100% in Aave v3 between swaps, with
ERC-4626 style internal shares for fair yield accounting.

The implementation, design spec and fork tests live in [`superposition-uni-v4-hook/`](./superposition-uni-v4-hook).

- `superposition-uni-v4-hook/src/SuperpositionHook.sol` — hook + vault
- `superposition-uni-v4-hook/docs/superpowers/specs/2026-09-11-superposition-v4-hook-design.md` — design
- `superposition-uni-v4-hook/README.md` — build, test and architecture notes

```bash
cd superposition-uni-v4-hook
forge test
```
