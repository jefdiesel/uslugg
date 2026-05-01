# uPork Design Doc

Status: design locked, implementation pending uSlugg redesign merge.
Owner: jef. Designed: 2026-05-01.

## Concept

uPork is a "shadow-404" NFT collection riding on existing $PORK token. PORK doesn't change; uPork attaches a v4 hook to a PORK/WETH pool we deploy. Every swap on that pool mints a "Pork" — a pink-frog inscription — to the swapper. Tier rolled probabilistically, weighted by swap size. Bigger swap = better odds at high tiers, never guaranteed.

uPork is a **separate project from uSlugg**, a parallel deployment of the same architectural pattern. PORK is the underlying ERC-20 (already exists, jef holds some). uPork = pink-frog cousin of PEPI, but with rarity gambling instead of fixed levels and per-swap mint instead of balance-tier reveal.

## Economic model

**Pool fee tier: 1% (PoolKey fee = 10000)**
**Hook fee: 0.5% (50 bps), capped at 1% by hook contract**
**Total user cost per swap: 1.5%**

Strategically: not competing with v3/aggregators on price. Premium "mint pool" — opt in to gamble for art, swap elsewhere if you want cheap PORK trades. Users pay 1.5% as the implicit mint cost.

Revenue per 1B PORK swap:
- Hook fee: 5M PORK (hook-contract balance, owner-withdrawable)
- LP fee: 10M PORK (LP positions → locker → feeRecipient = treasury)
- Total: 15M PORK per 1B PORK swap

Per $1M cumulative trade volume: ~$15k project revenue (at any reasonable PORK price).

## Mint mechanics

**One mint per BUY only.** Buys (WETH-in / PORK-out) on the locked pool mint exactly one Pork to the recipient. Sells (PORK-in / WETH-out) pay the 1.5% fee normally but DO NOT mint anything. This aligns NFT supply with PORK accumulation — dumpers don't get rewarded with art.

Detection: in `afterSwap`, check the delta sign on the PORK currency. If `delta.PORK > 0` (recipient received PORK), it's a buy → mint. If `< 0`, it's a sell → skip mint, fees still apply. Hook stores a flag at deploy for which currency in the locked PoolKey is PORK to avoid ambiguity from address-ordering.

Multiple Porks per address from natural buying activity.

**Tier is rolled probabilistically at mint time, locked permanently.** Roll uses `keccak256(currentSeed, mintId, recipient)` mixed with the swap size to derive both a probability bucket and a per-tier seed.

### Minimum swap threshold

**1B PORK minimum to trigger a mint.** Below 1B, the swap proceeds normally (still pays the 1.5% fee) but no Pork mints. Filters out spam, makes 1B (~$300 at current prices) the entry ticket.

### Probability distribution (default, tunable)

| Swap size (PORK) | Common | Uncommon | Rare | Legendary |
|---|---|---|---|---|
| < 1B | NO MINT (fees still paid) | | | |
| 1B–10B | 80% | 18% | 2% | 0% |
| 10B–100B | 60% | 30% | 9% | 1% |
| 100B–1T | 30% | 40% | 25% | 5% |
| 1T–10T | 5% | 25% | 50% | 20% |
| 10T+ | 5% | 5% | 30% | **60%** |

A 1T–10T swap has 20% legendary chance. The 10T+ "mega whale" tier (essentially anyone dropping ~$35k+ in one swap at current PORK prices) has 60% legendary — basically wins the gamble. Rare in practice, but the tier exists so if someone goes for it they get the prize.

### Economic rationale for the distribution

The 1.5% total fee on a 1T+ swap = ~$4,500 at current prices. With 20% legendary odds, expected fee cost per legendary = $22,500. That's the implicit floor for legendary secondary prices — the cost the original minter sunk in fees to get one. High fees + long-tail rarity = real economic backing for collector value.

### Splitting is allowed (lean-in)

10×100B BUYS = 10 Porks, each rolled independently from the 10B-100B band. Probabilistically dominant on getting at-least-one legendary (40% vs 20% from one 1T buy), but produces 10 NFTs of varied tiers. Different playstyle from one-big-buy (1 NFT, prestige flex). Both styles pay the same 1.5% in fees and contribute equal revenue.

### Wash trading is not amplified (sells don't mint)

Wash = buy then sell. Buy mints + pays 1.5%; sell pays 1.5% but no mint. Net: 1 Pork for 3% effective cost vs. 1.5% from a straight buy. Wash is strictly more expensive per Pork. Sellers subsidize buyers' mints by paying fees without getting reward. Discourages spam-minting via wash without explicitly blocking sells.

## Visual / trait system

**All Porks share the same base body**: an adult pink frog. No progression stages, no juvenile forms — every Pork is fully grown from day one. Rarity comes entirely from accessory layers stacked on top of the adult base.

Layers, ordered from base outward:

1. **Adult pink frog body** — same for every Pork (always present)
2. **Eyes** — 1 of N eye styles
3. **Mouth** — 1 of N mouth styles
4. **Ears** — 1 of N ear shapes
5. **Hat** — 1 of N hat styles
6. **Clothing** — 1 of N clothing/shirt styles
7. **Glasses / face accessory** — 1 of N styles
8. **Background** — 1 of N (rare modifier)

### Tier → layer mapping (launch set)

| Tier | Layers shown |
|---|---|
| Common | body + eyes + mouth |
| Uncommon | body + eyes + mouth + ears |
| Rare | body + eyes + mouth + ears + hat |
| Legendary | body + eyes + mouth + ears + hat + clothing + glasses |

Within each tier, sub-traits (which eye style, which hat) are selected deterministically from the per-mint seed. Higher tiers have access to rarer sub-trait pools (gold hat, gem-encrusted glasses, etc.).

Background as ultra-rare modifier: ~1% chance at any tier. A Legendary-with-Background is ~0.2% of all mints.

### Future expansion

The trait system is extensible by design. Owner can add new trait categories or new sub-trait variants in later drops without breaking existing Porks. Examples:
- New hat styles released in a "winter drop"
- New trait category like "weapon" or "pet" added later
- Seasonal backgrounds (limited-time mint windows)

Existing Porks freeze with the trait set they were minted under (tier locked → sub-traits locked). New mints after an expansion can roll into the new trait pools.

### Art format and source

Static SVG, on-chain. 32×32 pixel grid composed of layered SVG primitives. No animation (different from uSlugg's animated runtime). All traits stored as bytecode in a renderer/runtime contract pair.

PEPI's open-source art is fair game as starting reference — PORK is a Pepe fork, PEPI is a Pepe fork, both are downstream of the same memetic source. We can study PEPI's sprite sheets and adapt them (recolor green → pink, add original PORK-specific accessories). Original cleanup pass gives us our own visual identity within the Pepe-derivative tradition.

## Tradeable

uPork NFTs are standalone ERC-721. Tradeable on OpenSea, Blur, etc. EIP-2981 royalty (5-10%, recipient = treasury or split). Tier locked at mint, never changes — selling a Legendary doesn't reset for buyer.

This means:
- ✅ Active swappers fill out their collection over time
- ✅ Whales mint trophies via big swaps
- ✅ Royalty stream from secondary
- ✅ Marketplace listings drive discoverability
- ✅ "Complete the set" collector psychology (some go for one of each tier; some go for legendaries; some flip)

## Contract architecture (no 404 hybrid needed)

PORK already exists as a regular ERC-20. uPork doesn't wrap or modify PORK — just observes swaps on its own pool.

Contracts:

- **uPorkHook.sol** — v4 afterSwap hook on the locked PORK/WETH pool. On every swap, mints one Pork via the uPorkNFT contract. Holds accumulated hook fees in its own balance, withdrawable by owner. Same `lockedPoolHash` pattern as USluggHook to prevent attacker-pool seed manipulation.
- **uPorkNFT.sol** — Standalone ERC-721. Mint gated to uPorkHook only. Stores per-token tier + seed. tokenURI delegates to renderer.
- **uPorkRenderer.sol** — Builds tokenURI from tier + seed. Composes the SVG layer stack.
- **uPorkRuntime.sol** — Bytecode-stored SVG primitives library. Read by renderer. ~5–15 KB depending on trait variety.
- **uPorkLocker.sol** — Permanent LP custody, immutable feeRecipient. (Same pattern as USluggLPLocker.)
- **uPorkRouter.sol** — Optional: thin swap helper for the locked pool, similar to USluggSwap. Not strictly needed if the custom UI calls Universal Router directly.

NO 404 hybrid contract. PORK is the token; uPorkNFT is the collection. Decoupled. Much simpler than uSlugg.

## Routing strategy

**Custom UI (porksluggs.xyz or similar)** is the primary route. UI hardcodes the pool address, swaps go through it directly. Aggregator routing is a bonus, not a dependency.

UI surface:
- Connect wallet
- "Buy N PORK to roll a Pork" — exact-output buy of N PORK via uPorkRouter
- Mint preview — show probability bands ("at this size you have X% legendary chance")
- Wallet view — show all Porks owned, by tier
- Sell back to pool — shows expected payout, also rolls a Pork (every swap mints)

## Supply / cap

**No hard cap on Pork count.** Every swap mints. The collection grows organically with PORK trade volume on the pool.

This differs from uSlugg's 10k cap. Justification: PORK has billions of supply, the activity-based model produces NFTs proportional to economic engagement. Hard caps don't fit. Rarity comes from probability, not scarcity-by-fiat.

If desired, a soft "season cap" — Porks minted before block N have a "Genesis" trait flag that later mints don't get. Adds OG status without limiting future mints. Optional.

## Decisions confirmed (2026-05-01)

1. **NFT model**: per-BUY mint, tier locked at mint, probabilistically weighted by swap size.
2. **Sells don't mint**: only buys (WETH→PORK) trigger NFT mints. Sells pay full fees but receive no NFT.
3. **Minimum swap to mint**: 1B PORK. Sub-1B swaps allowed, just don't mint.
4. **Splitting**: allowed and intended ("lean in"). Pays same fees in aggregate.
5. **Pool fee**: 1% (PoolKey fee = 10000, tickSpacing = 200).
6. **Hook fee**: 0.5% (50 bps) at deploy. Owner-tunable up to 1% cap.
7. **Transferable**: yes. Royalty-bearing. Tier locked permanently at mint.
8. **Probability distribution**: kept whale-friendly (70% high-tier at 1T+). High fees create the price floor for high-tier mints — economic backing baked in.
9. **No 404 hybrid**. PORK is its own ERC-20; uPork is just a hook + NFT contract.
10. **Naming**: `u` prefix convention. uPork. Future projects: uX.
11. **No lifecycle/progression stages**. All Porks are adult on mint. Variation only via accessory layers.
12. **PEPI art is fair game** for reference and adaptation. Both projects descend from Pepe; we'll recolor and originalize.
13. **Trait system is extensible**. Future expansion drops can add new categories or sub-traits without breaking existing mints.
14. **Royalties**: 100% to jef.
15. **Chain**: Mainnet.

## Out of scope (deferred)

- Cumulative-volume tier-up model (considered, dropped in favor of per-swap probabilistic).
- Soulbound (rejected — kills royalty market).
- Lifecycle stages (rejected — additive layers used instead).
- Animated art (different product; that's uSlugg).
- Multi-pool routing.
- Subsidized mints / first-mint-free.

## Implementation plan

Phase 0: uSlugg redesign (callHook hybrid) merges first. uSlugg is the template.

Phase 1: Fork uSlugg contracts → uPork. Strip the 404 hybrid. Keep hook + NFT + renderer + locker. Apply PORK-specific:
- PoolKey for PORK/WETH at fee=10000
- Probability rolls in afterSwap based on swap size
- Pink-frog SVG layers in renderer
- Default hook fee = 50 bps

Phase 2: Custom UI. Hardcode the pool. Preview probabilities. Wallet view. Sell-back.

Phase 3: Liquidity seed. jef's existing PORK + ETH = initial LP, locked in the locker. Single-sided PORK across an aggressive tick range works (BCC-style launch curve translated for PORK price).

Phase 4: Marketing — "swap PORK at uPork.xyz, gamble for the art." PORK community discovery.

## Cost estimate

Mainnet (gas only, jef provides PORK + ETH for LP):
- Hook + NFT + renderer + runtime + locker deploy: ~$200 gas
- Pool initialize: ~$5 gas
- LP seed: ~$30–100 gas
- Total infra: ~$300

L2 (Base/Arb/Unichain): divide by ~50, roughly $6–10.

Time: ~1 week of work after uSlugg merges (since the contracts are mostly fork-and-tweak).

## Open questions for later

- Genesis trait cutoff block?
- Royalty split between jef and PORK community treasury?
- Should LP fee recipient be a PORK community multisig or jef's own?
- Trait art commissioning (who draws the pink frog assets)?
- L2 vs mainnet first launch?
