# uSlugg Hardening Notes

Post-mortem audit of uSlugg vs. lessons from the live uPEG protocol.
Each row is a vulnerability found in uPEG and uSlugg's status against it.

## What we already do better than uPEG

| uPEG vulnerability | uSlugg status | How |
|---|---|---|
| **Renounced ownership trap** — uPEG's hook + token owner are 0x0, so all bugs are unfixable forever | ✅ MITIGATED | USluggHook has 2-step `transferOwnership` + `acceptOwnership`; USlugg404 owner is immutable (deploy from multisig). Both are reachable identities, can be coordinated. |
| **Any v4 pool triggers mint** — uPEG hardcodes `pool == PoolManager singleton`, so attackers can spin up a competing pool with a different hook and still trigger uPEG mints | ✅ MITIGATED | `USluggHook.lockedPoolHash` pins the legitimate pool. Other pools' afterSwap short-circuits — no seed mutation, no fee. |
| **LP-withdraw seed-stale clone bug** — uPEG mints fire on any `from == PoolManager` transfer (incl. `removeLiquidity`), but `_randomizeSeed` only runs in `afterSwap`. Two LP withdraws back-to-back inherit the same seed → identical unicorns. We measured 6.59% collision rate in the live collection. | ✅ MITIGATED | Receive-side auto-mint in `_move` is gated on `seed.swapFiredThisTx()` (EIP-1153 transient). Non-swap transfers never auto-mint. Holders use `callHook` to materialize NFTs with a fresh seed via round-trip through the locked pool. |
| **Holder list off-by-one** — uPEG's `_removeHolder` deletes `_holderList[_holderListNumbers[owner]]` (1-indexed) but inserts at `_holderList[_holdersCount]` (0-indexed). Sparse holes, broken enumeration. | ✅ MITIGATED | uSlugg uses per-address `_inventory[]` arrays with swap-with-last + pop. Standard pattern, no off-by-one. |
| **Hook fee unbounded** — uPEG's `feeBps` is settable but the owner is renounced, so it's stuck at its initial value forever | ✅ MITIGATED | `feeBps` is owner-controlled and hard-capped at 100 bps (1%). Multisig can adjust within the cap. |
| **Atomic batch rarity extraction** — uPEG attacker buys 100 unicorns in one tx, transfers the rare ones via `transferUpeg(specific_id, recipient)`, sells the rest. Live attacker drained pool from 17% → 6.47% in days. | ⚠️ HARDER | uSlugg disables ERC-721 `transferFrom`/`safeTransferFrom`. To extract a specific Slugg from a batch, the attacker must `wrap()` it (which costs `wrapFeeWei` ETH) before selling. The wrap fee taxes the attack. Combined with the ~0.4% pool round-trip cost via `callHook`, the per-rare extraction cost is meaningfully higher than uPEG's ~0% cost. |
| **prevrandao seed grinding** — public users can't predict prevrandao, but builders can. uPEG seed mixes prevrandao directly. | ⚠️ INHERENT | Same risk applies to uSlugg. Mitigations: callHook costs ~0.4% (so cheap-grinding rare via callHook is taxed); seed only churns on locked-pool swaps (so attacker can't grind via random pools). For a true MEV-resistant seed we'd need Chainlink VRF or commit-reveal — neither acceptable for swap-driven UX. Accepting the residual risk. |

## What this commit fixes

| Issue | Severity | Fix |
|---|---|---|
| **Backdoor: `setSeedSource` is mutable post-deploy** | HIGH | Make it one-shot — set in constructor or first `setSeedSource` call; subsequent calls revert. Owner cannot point seed at a controlled source after launch. |
| **Backdoor: `setRenderer` is mutable post-deploy** | MEDIUM | Same one-shot treatment. Renderer can't be swapped to malicious SVGs after launch. |
| **Backdoor: `setClaimedNft` is mutable post-deploy** | HIGH | Same. Claimed NFT contract can't be swapped to break wrap/unwrap or steal wrapped NFTs. |

## Remaining residual risks (documented, not patched)

| Risk | Reason not patched |
|---|---|
| **`setSkip` can flip an address back to non-skip** | Legitimate use cases: retiring a deprecated faucet, helper, or router. Owner discretion; document in operational runbook. |
| **`setTreasury` is mutable** | By design: governance can rotate the treasury wallet. |
| **`setWrapFee` / `setUnwrapFee` mutable** | Economic parameters; governance tuning expected. Hard cap not enforced — multisig must self-police. |
| **Owner is a single immutable address on USlugg404** | If you want multisig control, deploy from a multisig wallet. Adding `transferOwnership` would expand the attack surface for marginal flexibility. |
| **prevrandao predictability for builders** | See above — accepted given the swap-driven UX requirement. |
| **LP `add_liquidity` from a holder with NFTs causes lossy LIFO burn** | Mirrors the "selling burns NFTs" semantic. LP positions in uSlugg are launched-and-locked, so end users shouldn't be touching liquidity. |

## Operational notes

- **Deploy from a multisig wallet** (Safe, etc.) so USlugg404's `owner` is the multisig's address.
- **After deploy**, in this exact order:
  1. `token.setSeedSource(hook)`
  2. `token.setRenderer(rendererAddr)`
  3. `token.setClaimedNft(claimedAddr)`
  4. `token.setSwapRouter(swapAddr)` (already one-shot)
  5. `token.setSkip(poolMgr, true)` (PM exempt from minting NFTs to itself when receiving USLUG during sell-leg settles)
  6. `hook.lockPool(canonicalPoolKey)`
  7. `hook.transferOwnership(multisigOrOpsAddress)` then `acceptOwnership` from that address.
- **After step 7**, the only remaining levers are: hook fee adjustment within 1% cap, treasury rotation, wrap fee tuning, skip toggling. All require multisig signature.

## Test additions

- `test_setSeedSourceIsOneShot` — second call reverts with `SeedSourceAlreadySet`
- `test_setRendererIsOneShot` — same pattern
- `test_setClaimedNftIsOneShot` — same pattern
