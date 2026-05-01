# PEPI Reference (Pepe Inscriptions / ERC20i)

Reference for uPork's renderer + mint mechanics. Not a copy. Pulled from the verified mainnet source 2026-05-01.

## Addresses + sources

- **Token contract**: [`0x3103cD1602d5fa8f4b9283F9D5a7fa2290795d51`](https://etherscan.io/token/0x3103cD1602d5fa8f4b9283F9D5a7fa2290795d51)
- **Total supply**: 13,370 PEPI (9 decimals)
- **Solidity**: 0.8.33, optimization=1, EVM=osaka
- **Source verified on Etherscan**: yes
- **GitHub**: https://github.com/ERC-20i/Pepi
  - `token/Pepi.sol` — main token + `HasItemsWithRoe` mixin
  - `Generator.sol` — SVG renderer + trait storage
  - `lib/` — Ownable + base ERC20
  - `marketplace/` — OTC item marketplace
- **Site**: https://pepe-erc20i.vip

## What surprised us

1. **PEPI does NOT use a Uniswap v4 hook.** It uses the regular ERC-20 `_transfer` override. The Uniswap pool address is registered as an "item source" via `setItemSource(address, bool)`. Any transfer FROM a source mints items to the recipient. This works on v2, v3, v4 — they happen to use v4 currently, but the mechanic is hook-agnostic.
2. **Item values are 1, 2, 4, 6, 8** (not sequential 1-5). Constants `_VALUE_LVL_1..5` map to values 1, 2, 4, 6, 8.
3. **Greedy mint loop with quirks**: when buying N tokens in one swap, the contract iterates from value 8 down to 1, filling as many items of each value as fit. Caps at 1000 new items per transfer. Special rule: only ONE of value-1 or value-2 per incoming transfer (`if (n != 0) break` for low values).
4. **"Roe"** = fractional balance not bound to an item. Each holder has at most one roe, separately seeded, level 0 in the renderer.
5. **LIFO with exact-value tier exception**: when transferring partial, items are popped from the end of the owner's master list. BUT if the transfer amount exactly equals `V * tokenUnit` for V in {1,2,4,6,8} AND the holder owns an item of that value, the LAST item of that value gets transferred (preserving order within other tiers).
6. **Value-1 transfers between non-sources are special**: a 1-token transfer burns the source's item and creates roe at the destination instead of moving the item. Punishes "shaving 1 token off" — you lose the item entirely.

## Pertinent for uPork: this is NOT what we need

PEPI's `_transfer`-override approach requires controlling the token contract. uPork rides on existing $PORK — we can't modify PORK's transfer. We need a v4 hook (which PEPI doesn't actually have, despite the marketing). uPork = the v4-hook version of this idea.

So we'll inherit PEPI's:
- ✅ Renderer pattern (layered SVG with on-chain rect data per category × level)
- ✅ Trait taxonomy (categories, level counts)
- ✅ Color palette (skin colors, backgrounds)
- ✅ Seed-driven deterministic art
- ❌ Their `_transfer` mint mechanic (can't, PORK is theirs not ours)
- ❌ Their lifecycle stages (we said no — adult only)
- ❌ Their value-1/2/4/6/8 staircase (we use probability tiers driven by swap size)

## Generator architecture (their `Generator.sol`)

`Generator` is `Ownable`. Stores layered rectangle data per trait category, indexed by level (0-5) and file-id.

Storage:
```solidity
uint constant levelsCount = 6;        // 0=roe (dust), 1-5 for items
uint8 constant pixelsCount = 32;      // 32x32 art grid

mapping(uint => mapping(uint => Rect[])) bodies;            // colorless (uses skin_colors)
mapping(uint => mapping(uint => RectColored[])) cloths;
mapping(uint => mapping(uint => RectColored[])) eyes;
mapping(uint => mapping(uint => RectColored[])) mouths;
mapping(uint => mapping(uint => RectColored[])) accessories;
mapping(uint => mapping(uint => RectColored[])) hats;
mapping(uint => mapping(uint => RectColored[])) ears;

uint8[6] bodyLevelCounts;       // how many body files per level
uint8[6] clothLevelCounts;
uint8[6] eyesLevelCounts;
uint8[6] mouthLevelCounts;
uint8[6] accessoryLevelCounts;
uint8[6] hatLevelCounts;
uint8[6] earsLevelCounts;

string[] backgroundColors;       // 7 vibrant: #c37100, #db4161, #9aeb00, ...
string[] dustBackgroundColors;   // 7 muted: #b0a090, #9a8f82, ...
string[] skin_colors;            // ~36 entries, heavily weighted to GREENS (Pepe), then browns/yellows/blues/reds/oranges/pinks as rares
```

Each `Rect` is `(x, y, width, height)` for colorless layers (body uses random skin color), each `RectColored` adds `color` (uint24).

Setter functions: `setBodies`, `setCloths`, `setEyes`, `setMouths`, `setAccessories`, `setHats`, `setEars`. Owner-only. Take batch of `FileData[]` or `FileDataColored[]` — each entry sets all rects for one (level, file) combination. Replaces existing if file already set.

### Render flow

```solidity
function getItemData(SeedData calldata) external view returns (ItemData memory)
```

Builds an `ItemData` from a `SeedData` deterministically:

```solidity
struct SeedData {
    uint8 lvl;     // 0 (roe) or 1-5 (item)
    uint value;    // 1/2/4/6/8 for items, raw amount for roe
    uint seed1;    // PRNG stream A (block.timestamp/sender/nonce/block.number)
    uint seed2;    // PRNG stream B (sender + extraSeed via keccak)
}

struct ItemData {
    uint lvl;
    string background;
    uint body;        // 0 = none
    string bodyColor;
    uint cloth;       // 0 = none, else file id
    uint eyes;
    uint mouth;
    uint accessory;
    uint hat;
    uint ears;
}
```

Two PRNG streams used to pick: background, body file, body color, then per category (cloth/eyes/mouth/accessory/hat/ears) — each picks an integer 0..levelCount[lvl]-1, where 0 means "none" (skip layer).

There's also a level-1 "limits" block that suppresses certain combos:
```solidity
if (data.lvl == 1) {
    if (data.mouth == 9 && data.accessory >= 7 && data.accessory <= 9) data.accessory = 0;
    if (data.eyes == 5 && data.accessory >= 10 && data.accessory <= 13) data.accessory = 0;
}
```
Hand-tuned style coherence at the lowest tier.

### SVG composition

`RectLib.toSvg` emits `<rect x='..' y='..' width='..' height='..' fill='..'/>`. Layers stack in render order. Final SVG is a 32×32 viewBox containing all the visible-layer rects. Inlined as data URI in `tokenURI` (we'd need to look at their tokenURI builder to confirm — wasn't in the file we pulled).

## Trait taxonomy (counts per level)

We need to count actual files per level by reading their `setBodies`/`setCloths`/... call data on-chain. Skipped here — would require pulling the deployment txes' calldata. Pattern is clear though:

- 7 trait categories
- Each has 0..N variants per level (level 0 = dust/roe, levels 1-5 for items)
- Level 5 (most rare) = most variants
- Setters are batch-callable so they did it in chunks at deploy

Their Generator's `setX` admin functions are owner-only — once they renounce ownership (or transfer to multisig), the trait set freezes. Worth checking their Etherscan for whether ownership has been renounced.

## Mint mechanics (what they do that we ARE NOT copying)

```solidity
function _mintItemsFromIncoming(address account, uint incoming) internal {
    if (incoming == 0 || _isItemSource(account)) return;
    uint remains = incoming;
    uint before = _itemCounts[account];
    for (uint v = 5; v >= 1; --v) {
        uint val = (v==5?8 : v==4?6 : v==3?4 : v==2?2 : 1);
        if (remains < val) continue;
        uint n = _itemCounts[account] - before;
        if (n >= 1000) break;            // 1000 new items per transfer cap
        uint count = remains / val;
        if (val <= 2) {                   // values 1 and 2 special
            if (n != 0) break;            // only as the FIRST mint, blocks if higher tier already minted
            if (val == 1 && count > 1) count = 1;
        } else {
            uint cap = 1000 - n;
            if (count > cap) count = cap;
        }
        for (uint i = 0; i < count; ++i) _mintItem(account, val);
        remains -= count * val;
    }
}
```

So if you buy 13 tokens in one tx: greedy → 1× lvl-5 (value 8), 1× lvl-3 (value 4), 1× lvl-1 (value 1) ... wait, after 8 + 4 = 12, remains = 1, val=2 doesn't fit, val=1 → count=1 mints. So you get 3 items: a lvl-5, a lvl-3, a lvl-1. Cumulative inventory growth by integer-buy size.

uPork's design is different: probability-tier roll per buy, baked at mint time, no greedy pyramid.

## What we steal for uPork

1. **Trait categories**: 7 layers (body, eyes, mouth, ears, hat, clothing, glasses) — we already aligned on this.
2. **32×32 pixel SVG composition** — reuse approach, originalize art assets (recolor green → pink, redraw any details).
3. **`Rect` / `RectColored` storage layout** in the renderer contract — solid pattern, gas-reasonable, owner-settable in batches.
4. **Two-stream PRNG** (`seed1` and `seed2`) for trait selection — reduces correlation between trait picks.
5. **`ItemData` / `SeedData` struct shape** — clean separation between the input seed and the resolved trait choices.
6. **Background palette pattern** — 7-ish vibrant for items, muted for low tiers (we'd map to common-tier alt palette).
7. **Skin color weight bias** — heavy weighting toward primary brand color (their green, our pink), with rare alt-color hits for variety.
8. **Hand-tuned style limits** — level-1 has explicit combo suppressors. We can do the same for tier-specific exclusions.

## What we don't take

- The `_transfer` override mechanic (need a v4 hook instead — see PLAN-uPork.md)
- Lifecycle stages / value tiers 1/2/4/6/8 (we use probability bands instead)
- The greedy multi-item mint per transfer (we do one mint per buy)
- The "roe" fractional concept (uPork doesn't track fractional anything — buys mint, sells don't)
- Their OTC marketplace contract (uPork ships standard ERC-721 → OpenSea/Blur)

## Open questions to resolve

1. Are PEPI's renderer setters renounced? (Check Etherscan for ownership state.)
2. Total trait variant count per category × level — pull from their deploy txes if we want exact pool sizes for our brief.
3. Do they store full SVG paths or just rects? (Looks like rects only — pixel-art friendly.)

These are deferable. We have enough to write the uPork renderer architecture from this reference + our own art.
