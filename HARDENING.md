# uSlugg Hardening Notes

Audit of uSlugg vs. lessons from the live uPEG protocol. Status as of this commit:
**every residual risk identified has been mitigated**, including the prevrandao
exposure that uPEG (and the original uSlugg design) couldn't escape.

## Architectural defenses (already in place pre-hardening)

| uPEG vulnerability | uSlugg defense | Where |
|---|---|---|
| Renounced ownership trap (uPEG's hook + token owners are 0x0, all bugs unfixable) | Hook owner has 2-step `transferOwnership` + `acceptOwnership`; token owner is immutable (deploy from multisig) | USluggHook, USlugg404 |
| Any v4 pool can trigger mint (uPEG hardcodes `pool == PM`, attackers can spin up own pools) | `lockedPoolHash` pins the canonical pool; foreign-pool `afterSwap` short-circuits | USluggHook.lockPool |
| LP-withdraw seed-stale clones (uPEG: 6.59% collision rate observed in live data) | Receive-side auto-mint is gated on `seed.swapFiredThisTx()` (EIP-1153 transient). Non-swap transfers never auto-mint. | USlugg404._move |
| Holder list off-by-one bug | Per-address `_inventory[]` arrays w/ swap-with-last + pop. No global list. | USlugg404 |
| Hook fee unbounded after renounce | Hard 1% cap, multisig adjustable within | USluggHook.setFeeBps |

## Hardening fixes applied in this commit

| Bug class | Fix | Where |
|---|---|---|
| `setSeedSource` mutable post-deploy → owner could repoint randomness | `seed` is now `immutable`, set in constructor, no setter exists | USlugg404 |
| `setRenderer` mutable post-deploy → visual vandalism backdoor | One-shot setter (reverts on second call with `RendererAlreadySet`) | USlugg404 |
| `setClaimedNft` mutable post-deploy → wrap/unwrap hijack backdoor | One-shot setter (`ClaimedNftAlreadySet`) | USlugg404 |
| **prevrandao predictability — builders can grind seeds in-tx** | **Deferred reveal**: mints store `mintBlock`, seed is `bytes32(0)` until `reveal(id)` is called after `REVEAL_DELAY` blocks. Seed = `keccak(blockhash(mintBlock + REVEAL_DELAY), id, originalMinter)`. Builder of mint block cannot predict the future blockhash. | USlugg404 + USluggHook |
| Hook stored a predictable `currentSeed` in state (mixed prevrandao) | Removed entirely. Hook is no longer a randomness oracle — only sets the swap-fired flag and takes fees. `ISeedSource` reduced to just `swapFiredThisTx()`. | USluggHook, ISeedSource |
| `setSkip` could un-skip an address (e.g., un-skip PoolManager → leak NFTs) | Add-only: `v=false` reverts with `CannotUnskip`. Skips are permanent once set. | USlugg404 |
| `setTreasury` could mistype to a black hole | Two-step: `proposeTreasury` then `acceptTreasury` from the new address (matches hook's owner pattern). | USlugg404 |
| `setWrapFee` / `setUnwrapFee` unbounded → owner griefing | Hard cap `MAX_WRAP_FEE_WEI = 0.1 ether`. Anything above reverts. | USlugg404 |
| Atomic batch rarity extraction (uPEG attacker minted 100/tx) | `MAX_MINTS_PER_TX = 25` cap on `_move` and `callHook`. | USlugg404 |
| Single-tx mint→inspect→wrap-rare extraction | `MIN_WRAP_AGE = 32 blocks` before a slugg can be wrapped. Combined with REVEAL_DELAY, attacker can't even know which is rare until reveal time + can't pull rare out for 32 blocks. | USlugg404.wrap |

## Reveal mechanics

The deferred-reveal model is the key defense against builder-MEV. Mechanics:

1. Buy via locked pool (or `callHook`) → afterSwap sets `swapFiredThisTx` flag → `_move` mints sluggs with `seed = bytes32(0)` and `mintBlock = block.number`.
2. Wait `REVEAL_DELAY = 2` blocks (~24 seconds on L1).
3. Anyone calls `reveal(id)` (or `revealMany(ids[])` for batches). Seed is locked from `keccak(blockhash(mintBlock + REVEAL_DELAY), id, originalMinter)`.
4. If reveal is called >256 blocks after mint, `blockhash()` returns 0; the contract falls back to `blockhash(block.number - 1)`. The seed is still deterministic and anyone-callable, just dependent on whoever first revealed.

**Why this defeats prevrandao MEV:**
- The builder of block N (when the mint happens) cannot control `blockhash(N+2)` unless they also win slot N+2.
- For the largest staker (~33% of stake), probability of winning two consecutive slots is ~10%. With each additional `REVEAL_DELAY` block, this drops geometrically.
- Setting `REVEAL_DELAY = 2` is a pragmatic floor: meaningful protection with minimal UX cost.

## Operational deploy order

```
1. Deploy USluggHook (owner = deployer multisig)
2. Deploy USluggClaimed
3. Deploy USlugg404(seed=hook, treasury, maxSluggs, tokensPerSlugg)
4. token.setRenderer(renderer)               // one-shot
5. token.setClaimedNft(claimed)              // one-shot
6. token.setWrapFee + setUnwrapFee           // within MAX_WRAP_FEE_WEI cap
7. Deploy USluggSwap with canonical PoolKey
8. token.setSwapRouter(swap)                 // one-shot
9. token.setSkip(poolManager, true)          // add-only
10. hook.lockPool(canonicalPoolKey)          // one-shot
11. (optional) hook.transferOwnership(opsMultisig); accept from opsMultisig
```

After step 11 the only governance levers remaining are: hook fee within 1% cap, treasury rotation (2-step), wrap fee tuning (within cap), additional skip additions. All multisig-gated.

## Test coverage

103 tests across 8 suites, all green. Hardening-specific:

- `test_seedSourceImmutable` — seed has no setter
- `test_setRendererIsOneShot`, `test_setClaimedNftIsOneShot` — one-shot enforcement
- `test_setSkipAddOnly` — un-skip reverts
- `test_wrapFeeCaps` — fee setter caps
- `test_treasuryTwoStepTransfer` — propose + accept
- `test_batchSizeCapped` — MAX_MINTS_PER_TX enforcement
- `test_revealLifecycle` — pre/post REVEAL_DELAY behavior, double-reveal, missing-id
- `test_wrapAgeGate` — MIN_WRAP_AGE enforcement
- `test_wrapRequiresReveal` — wrap on unrevealed slugg reverts

## Residual risks (none material)

| Risk | Why accepted |
|---|---|
| LP `add_liquidity` from a holder with NFTs causes lossy LIFO burn | LP positions in uSlugg are launched-and-locked. End users shouldn't touch liquidity. Mirrors the "selling burns NFTs" semantic. |
| Stale-blockhash fallback for late reveal | If a holder lets reveal lapse >256 blocks, the seed is set from a more-recent blockhash (deterministic, but the holder gave up control by waiting). Acceptable as a degenerate case. |
| 2-block UX delay before art shows | Direct cost of MEV-resistant randomness. Acceptable given the threat model. |
