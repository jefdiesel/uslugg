# Hybrid A+C Plan: callHook for non-pool USLUG

Status: design locked, implementation pending.
Owner: jef. Last design discussion: 2026-05-01.

## Problem

The 404+v4 design has two truths in conflict:

1. **404 magic**: every whole-USLUG balance crossing in `_move` auto-mints/burns NFTs, regardless of how the crossing happened.
2. **v4 hook magic**: `currentSeed` only mutates when `afterSwap` fires on the locked pool.

Result: USLUG acquired outside the locked pool (aggregator routes, p2p sends, faucet drips, airdrops) produces sluggs with stale seeds — same art as the previous mint. The "art is swap-driven" pitch becomes a fiction. Plus the unipeg UX issue: users overbuy to guarantee a whole NFT, paying extra gas/slippage.

## Decision

Hybrid A+C with whole-token round-trip claim.

**Path A — buy via locked pool (no UX change)**
- User calls `USluggSwap.buy(...)` (or aggregator routes through the locked pool).
- `afterSwap` fires on the locked pool → seed rolls → transient `swapFiredThisTx` flag set.
- `poolManager.take` sends USLUG to user; `_move` runs in the same tx, sees the flag set, auto-mints fresh-seed sluggs.
- One-click experience preserved.

**Path C — `callHook` for non-pool USLUG**
- User holds USLUG from elsewhere (no auto-mint happened because flag wasn't set).
- They call `USlugg404.callHook(count, maxSlippageBps)`.
- Function pulls `count * tokensPerSlugg` USLUG from caller.
- Sells via the locked pool (afterSwap fires → seed rolls #1).
- Buys back with the ETH yield (afterSwap fires → seed rolls #2).
- Slippage check (default 1%, user-overridable up to a hard 5% ceiling).
- Returns the slightly-less USLUG to caller.
- Mints `count` sluggs with the post-second-swap seed.
- Real economic cost: ~0.2% pool fees + slippage + gas. Cannot be cheap-grinded.

## Naming

- `callHook` — new function for materializing sluggs from owed USLUG.
- `wrap()` / `unwrap()` — rename existing `claim()` / `unclaim()` to avoid collision (those wrap a slugg into the standalone ERC-721 for OpenSea).

## Contract changes

### USluggHook.sol

- Add transient bool flag (EIP-1153) for "swap fired on locked pool this tx":
  ```solidity
  // pragma solidity ^0.8.24 supports `transient` keyword via tload/tstore in 0.8.26+
  // Using assembly for portability:
  function _setSwapFired() private {
      assembly { tstore(0, 1) }
  }
  function swapFiredThisTx() external view returns (bool flag) {
      assembly { flag := tload(0) }
  }
  ```
- In `afterSwap`, when the lockedPoolHash matches, call `_setSwapFired()` after the existing seed mutation.
- Non-locked pool calls still short-circuit — no flag set, no seed mutation.

### ISeedSource.sol

- Extend interface:
  ```solidity
  interface ISeedSource {
      function currentSeed() external view returns (bytes32);
      function swapCount() external view returns (uint64);
      function swapFiredThisTx() external view returns (bool);
  }
  ```

### MockSeedSource.sol (testnet)

- Implement `swapFiredThisTx()` returning true (no enforcement on testnet without real hook).

### USlugg404.sol

- Constructor: `skipSluggs[address(this)] = true` so the contract can hold transit USLUG without minting NFTs to itself.
- Add storage: `address public swapRouter;` and `bool internal _routerSet;`.
- Add `setSwapRouter(address router)` external onlyOwner, one-shot:
  ```solidity
  function setSwapRouter(address router) external onlyOwner {
      require(!_routerSet, "router already set");
      require(router != address(0), "router=0");
      _routerSet = true;
      swapRouter = router;
      skipSluggs[router] = true;       // router is transit
      // Set max approval so callHook can sell USLUG via the router
      allowance[address(this)][router] = type(uint256).max;
      emit Approval(address(this), router, type(uint256).max);
  }
  ```
- Modify `_move`:
  - **Receive branch**: only auto-mint if `seed.swapFiredThisTx() == true`. If false, just move balance, no NFT mint.
  - **Send branch**: make burn lossy. If `_inventory[from].length < lose`, burn what's there and let the rest "disappear" (just an owed-counter decrement; total NFTs goes down by what we had).
- Add `callHook(uint256 count, uint256 maxSlippageBps) external nonReentrant`:
  ```
  preconditions:
    - count > 0
    - maxSlippageBps <= 500 (5% hard ceiling)
    - balanceOf[msg.sender] >= count * tokensPerSlugg
    - swapRouter != address(0)
  
  steps:
    1. Pull `count * tokensPerSlugg` USLUG from msg.sender into address(this) via direct balance manipulation
       (avoid _move pitfalls; emit Transfer for indexers).
    2. Cache ETH balance: ethBefore = address(this).balance.
    3. Call swapRouter.sell(amount, minEthOut=1, deadline) → triggers afterSwap on locked pool.
    4. Compute ethGot = address(this).balance - ethBefore.
    5. Call swapRouter.buy{value: ethGot}(usluggOut=expected, maxEthIn=ethGot, deadline)
       where expected = (count * tokensPerSlugg) * (10000 - maxSlippageBps) / 10000.
       This triggers afterSwap on locked pool again.
    6. Compute usluggBack = balance change at this address.
    7. Slippage check: usluggBack >= count * tokensPerSlugg * (10000 - maxSlippageBps) / 10000.
    8. Send usluggBack to msg.sender via direct balance manipulation.
    9. Read seed.currentSeed() (now post-second-swap).
   10. Mint `count` sluggs to msg.sender with this seed.
   11. Emit a CallHookCompleted event for indexers.
  
  invariants:
    - nonReentrant (defense-in-depth; both swaps re-enter through PoolManager)
    - all-or-nothing: any leg failing reverts everything; user's USLUG returns
    - no balance sweep: ethGot uses delta from cached ethBefore, not address(this).balance
    - no inventory pollution: skipSluggs[address(this)] = true, no auto-mints to self
  ```
- Rename existing `claim()` → `wrap()`, `unclaim()` → `unwrap()`. Keep semantics identical. Update callers (USluggClaimed reference, tests, site).

### DeployUslugg.s.sol

- Order of operations:
  1. Mine hook salt (existing)
  2. Deploy hook, runtime, renderer, token, USluggClaimed (existing)
  3. Lock the hook's pool key (existing fix)
  4. **NEW**: deploy USluggSwap with the canonical PoolKey
  5. **NEW**: token.setSwapRouter(USluggSwap address)
  6. Propose hook ownership handoff (existing)

## Tests

### Forge unit tests
- Path A: buy via USluggSwap mints sluggs in the same tx with fresh seed.
- Direct ERC-20 transfer doesn't auto-mint (no flag set).
- Faucet drip doesn't auto-mint.
- callHook works: caller pays ~0.2% USLUG, gets `count` sluggs with new seed.
- callHook reverts on slippage exceeded.
- callHook reverts if swapRouter not set.
- callHook reverts if balance insufficient.
- callHook reverts if maxSlippageBps > 500 (hard cap).
- Honeypot scenarios: any swap leg failure → entire callHook reverts → user's USLUG restored.
- setSwapRouter only-owner, one-shot.
- Sell with insufficient inventory: balance moves, no underflow.
- Path A under stress: many buys in succession all get fresh seeds (different per swap).

### Echidna invariants (updated)
- New: `inventory.length <= balance / tokensPerSlugg` (was equality). The "owed" gap is non-negative.
- New: `callHook(count) increases inventory by exactly count` (when it succeeds).
- New: `callHook never increases user's USLUG balance` (always net-negative due to fees).
- Existing: no token creation, nextSluggId monotonic, escrow balance whole units.

### Halmos symbolic
- Existing 10 proofs remain valid.
- Add: callHook(count, slippage) with symbolic count, slippage — verify slippage cap enforcement.

## Security model

| Attack | Mitigation |
|---|---|
| Reentrancy via swap callback | nonReentrant on callHook |
| Honeypot: USLUG taken, swap reverts | All-or-nothing tx semantics |
| Sandwich on round-trip | Slippage cap (1% default, 5% max) |
| Pre-existing dust swept | Balance deltas (ethBefore/ethAfter), not absolutes |
| Cheap seed grinding | Real ~0.2% cost per round-trip; not free |
| Token-direct ETH exploit | receive() permissive but ethGot tracked via delta; dust doesn't leak |
| Router hijack | setSwapRouter is one-shot; immutable after set |
| Locked pool empty | Swap reverts → callHook reverts cleanly; no stuck funds |

## Migration

Mainnet hasn't shipped. Sepolia has — current testnet deploy will be replaced with the new design. No live state to migrate.

## Out of scope (deferred)

- Multi-pool routing (e.g., USLUG/USDC alongside USLUG/WETH). Single locked pool for now.
- Auto-claim cron. Users manually call callHook.
- Subsidized first-claim. Each user pays their own round-trip.

## Decisions confirmed
- (1) Sell-without-claiming: fine, owed counter just goes down (lossy burn).
- (2) Slippage default: 1%, hard cap 5%.
- (3) Function name: `callHook`.
- (4) Round-trip direction: sell-first, USLUG → ETH → USLUG.
- (5) Pool: original launch pool. Liquidity is locked-LP guaranteed once launched.
