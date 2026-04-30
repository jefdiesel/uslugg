# uSlugg

Animated, fully on-chain generative art that mints from Uniswap v4 swaps.

> **Live testnet**: [uslugg.vercel.app](https://uslugg.vercel.app) (Sepolia)

## What it is

uSlugg is a 10,000-piece generative art collection where each piece is an animated **smear pattern** — 1, 2, or 3 panels of textures (noise, checkerboard, stripes, etc.) that drift and decay across a Canvas2D loop forever. The seed is on-chain, the JS animation runtime is bytecode-stored, and your wallet renders the piece live via the `animation_url` field in the token URI.

**Why it's interesting:**

- Every parameter that drives the art (panel count, split ratios, colors, patterns, smear directions, decay rates) is derived deterministically from a single `bytes32` seed
- Pieces mint as a side effect of swapping uSlugg ↔ ETH on a Uniswap v4 pool — the swap-driven hook produces the seed, the 404 token mints/burns NFTs as the ERC-20 balance crosses integer thresholds
- Selling uSlugg burns your NFT; the next buyer of those tokens gets a freshly minted one with a brand new seed (so a token that has cycled three owners has been three different sluggs)

## Architecture

```
ON-CHAIN (Solidity)
├─ USluggHook         v4 afterSwap hook → re-rolls currentSeed every swap, skims 0.1% fee
├─ USlugg404          ERC-20 + ERC-721 hybrid (3 decimals, 1.000 = 1 NFT)
├─ USluggClaimed      Standalone ERC-721 wrapper (so claimed pieces trade on OpenSea/Blur)
├─ USluggSwap         Single-pool buy/sell router for the uSlugg/WETH v4 pool
├─ USluggLPLocker     Permanent LP custody — feeRecipient immutable, no rug path
├─ USluggRenderer     tokenURI builder that returns animation_url (HTML data URI)
├─ USluggRuntime      Bytecode-stored Canvas2D smear runtime (~10KB JS, read by Renderer)
└─ USluggBeta         Public-mint ERC-721 used for the renderer-only testnet beta

OFF-CHAIN (frontend)
└─ site/index.html    Vanilla JS testnet page · wallet connect · mint · live viewer
```

## Art rules (what makes a slugg)

Each token's `bytes32` seed decodes to:

| Layer | Distribution |
| --- | --- |
| **Panel count** | 1-panel ~0.1% · 2-panel ~93.7% · 3-panel ~6.25% |
| **Compound rare ("monolith")** | ~0.006% — forces 1-panel + heavy decay + giant cells + slow speed |
| **Mirror mode (2-panel)** | ~6.25% — panel 1 is panel 0 with reversed direction |
| **Themed palette** | ~25% — colors picked from curated tuples (cyber, sunset, noir, pastel, ocean, acid) |
| **Unified palette** | ~0.78% — panels share a color |
| **Split ratio** | 94% in 10–90% range · 6% rare ultra-thin (1–9% / 91–99%) |
| **Patterns** | noise · random-blocks · checkerboard · stripes · dashes · dots · diagonal-stripes (panels never share pattern) |
| **Cell size** | 5 weighted tiers: ultra-fine 2-3px (12.5%) · fine 4-7px (25%) · medium 8-16px (31%) · chunky 17-40px (19%) · giant 41-80px (12.5%) |
| **Highlight color** | Third color used in 2-3% of pixels in noise/dots/random-blocks for visual depth |
| **Animation** | Trail intensity 0.50–0.97 · decay 0.5–18% per frame · 5% rare heavy-decay tier · direction changes randomly every 1–4s |

Every panel is internally high-contrast (BG channel ~88% forced to opposite half of FG channel). Multi-panel pieces enforce that panel colors are at least 4 Manhattan-distance apart so they don't visually merge.

## Tokenomics

- **Total supply**: 10,000 USLUG (3 decimals → 10,000.000 max)
- **Mint threshold**: 1.000 USLUG = 1 NFT (anything fractional below 1.000 is just ERC-20 with no NFT)
- **Treasury allocation**: 0% premint
- **LP**: All 10k locked at launch via `USluggLPLocker` across a $1 → $1,107 single-sided BCC-style launch curve
- **Revenue**:
  - Pool 0.3% fee → LP fee recipient
  - Hook 0.1% fee → hook owner (multisig)
  - Claim 0.001111 ETH (~$3.50)
  - Unclaim 0.0069 ETH (~$22)

## Live testnet (Sepolia)

| Contract | Address |
| --- | --- |
| USluggBeta (public mint, plain ERC-721) | `0xef27007372797Fceb6a5Af85a77b83dD644f2A32` |
| USluggRenderer (latest) | dynamic — page reads from token |
| USluggRuntime (latest) | dynamic — page reads from renderer |

The current testnet is the **renderer beta** only (no v4 pool, no LP, no swap-driven mint yet). Anyone with Sepolia ETH can mint directly via [uslugg.vercel.app](https://uslugg.vercel.app).

## Local dev

```bash
# Install deps
git clone git@github.com:jefdiesel/uslugg.git
cd uslugg
forge install foundry-rs/forge-std --no-git
forge install Uniswap/v4-core --no-git
forge install Uniswap/v4-periphery --no-git

# Build
forge build

# Run tests (e2e 404 + claim flow + renderer dump)
forge test

# Generate sample mints + a single-piece refresh viewer
mkdir -p samples
forge test --match-test test_mint_and_dump
open samples/one.html        # interactive single-piece viewer
open samples/index.html      # 4-piece grid

# Deploy renderer-only beta to Sepolia
cp .env.example .env  # fill ALCHEMY_KEY + DEPLOY_PRIVATE_KEY
source .env
forge script script/DeployBeta.s.sol --rpc-url "https://eth-sepolia.g.alchemy.com/v2/$ALCHEMY_KEY" --private-key "$DEPLOY_PRIVATE_KEY" --broadcast

# Deploy full v4 stack (mainnet-shaped)
HOOK_OWNER=0xYourMultisig forge script script/DeployUslugg.s.sol --rpc-url $RPC --private-key $PK --broadcast --verify

# Update the renderer (e.g. after iterating on art rules)
TOKEN=0x... forge script script/UpdateRuntime.s.sol --rpc-url $RPC --private-key $PK --broadcast
```

## Repo layout

```
src/                # Solidity contracts
script/             # Foundry deploy + redeploy scripts
test/               # Foundry tests (POC.t.sol = renderer; USlugg404.t.sol = e2e 404)
site/               # Vercel-hosted frontend
  ├─ index.html     # main testnet page
  ├─ one.html       # single-piece refresh viewer
  ├─ api/rpc.js     # Alchemy proxy (key in Vercel env, never exposed to browser)
  └─ vercel.json    # cleanUrls + no-store cache headers
samples/            # gitignored — `forge test` dumps live tokenURI samples here
.env.example        # config template
```

## Status

- [x] Renderer + animation runtime working
- [x] Public-mint testnet live on Sepolia
- [x] Full v4 stack ported (404 + hook + locker + swap + claim) — compiles, tested locally
- [ ] v4 pool deployed to Sepolia
- [ ] Swap-driven mint flow live on testnet
- [ ] Mainnet deploy

## License

MIT.
