# Uniswap v4 Developer Feedback — Superposition

## Who's writing this

I've built a few v4 hooks before this one, mostly smaller experiments around custom curves and
dynamic fees, so I came into this hackathon already fairly comfortable with the callback model and
the hook-address permission bits. This was the first time I tried to make a hook that manages real
external yield positions on every swap, and honestly it was the most fun I've had with v4 so far.

Project: **Superposition** — a concentrated-liquidity hook that keeps 100% of pooled capital in
ERC-4626 lending vaults between swaps and unwinds them just-in-time for the duration of a swap.

Repo: [github.com/SolidityDrone/superposition-hook-uni-v4](https://github.com/SolidityDrone/superposition-hook-uni-v4) · Deployment target: Base Sepolia (testnet).

## What went well

**The singleton + flash accounting model is genuinely a joy for this.** Because `PoolManager` only
tracks deltas and everything is settled inside the lock, I could redeem both vaults, add real
liquidity, swap, remove it, `take` the proceeds, and re-deposit — all in one transaction with no
intermediate token dust. The `sync`/`settle`/`take` flow in
`src/SuperpositionHook.sol:576` (`beforeSwap`) and `src/SuperpositionHook.sol:619` (`afterSwap`) is
what makes the whole "capital never sits idle" idea possible. On v3 this hook would not exist.

**Permission bits are clean.** Mining the address for exactly `BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG |
BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG`
(`script/DeployHook.s.sol:29`) keeps the surface small, and the `beforeAddLiquidity` /
`beforeRemoveLiquidity` gates (`src/SuperpositionHook.sol:503`, `:527`) gave me an easy way to make
the hook the only LP. The `HookMiner` copy in `src/libraries/HookMiner.sol:25` works and mirrors the
official one, so no complaints there.

**`modifyLiquidity` deltas made per-bucket attribution straightforward.** I store the add delta in
`beforeSwap` and apply the removal delta in `afterSwap`, so PnL and fees land only on the range that
was crossed. That was much less painful than I expected.

## Friction / things I'd love to see improved

1. **Testing hooks against real state is still the sharpest edge.** I ended up building a minimal
   swap router (`test/helpers/TestSwapRouter.sol`) and forking Base mainnet/Sepolia to test against
   real `PoolManager` and real ERC-4626 vaults. It works, but a first-party "fork a live pool and
   drive callbacks" recipe in the docs would save people a day. Most of my past hook work hit this
   same wall.

2. **Failure modes around external calls.** My hook deposits into third-party vaults inside
   `afterSwap` (`src/SuperpositionHook.sol:734`). Vaults can be paused or capped, so I had to be very
   careful that a failed deposit never leaves an unsettled `PoolManager` delta. I settled all deltas
   before touching the vaults and wrapped the deposit in `try/catch`. More examples of "external call
   fails mid-callback" in the docs/example repo would help a lot.

3. **Rounding.** ERC-4626 share math rounds against you, so I keep a small `DEPOSIT_BUFFER` and clamp
   withdrawals to the real vault position. Not a v4 problem at all, but it's the kind of thing a
   hook example that combines v4 with ERC-4626 could show once and save everyone the debugging.

4. **Documentation is good but scattered.** `v4-core`, `v4-periphery`, and the docs site each had a
   piece of what I needed. A single canonical "here's the lifecycle of one swap, with every callback
   and every delta" page would be a great addition.

## Where the integration lives (for review)

- Hook callbacks: `src/SuperpositionHook.sol:556` (`beforeSwap`), `:604` (`afterSwap`)
- LP gating / permissions: `src/SuperpositionHook.sol:503`, `:527`; flags in `script/DeployHook.s.sol:29`
- PoolManager liquidity calls: `src/SuperpositionHook.sol:576`, `:619`
- ERC-4626 custody: `_deposit` `src/SuperpositionHook.sol:734`, `_redeemAll` `:745`, `_payout` `:758`
- Share token (ERC-1155, one id per range): `src/BucketShares.sol:11`
- CREATE2 salt search: `src/libraries/HookMiner.sol:25`
- Fork tests against live Uniswap v4 + real vaults: `test/BaseSepoliaFork.t.sol`,
  `test/SuperpositionHookBaseFork.t.sol`

## Overall

v4 is the first AMM framework where an idea like this felt like a feature of the design rather than
a fight with it. Hooks + the singleton + flash accounting are a real step up from v3 from a builder's
point of view, and I'd happily ship more on this. Main ask: more end-to-end examples around external
calls, failure handling, and fork testing. Thanks for putting v4 out there.

— built for the Uniswap track
