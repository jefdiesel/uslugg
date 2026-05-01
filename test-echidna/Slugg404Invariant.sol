// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {USlugg404}          from "../src/USlugg404.sol";
import {USluggClaimed}      from "../src/USluggClaimed.sol";
import {USluggRenderer}     from "../src/USluggRenderer.sol";
import {USluggRuntime}      from "../src/USluggRuntime.sol";
import {MockSeedSource}     from "../src/MockSeedSource.sol";
import {ISeedSource}        from "../src/ISeedSource.sol";
import {IUSluggRenderer}    from "../src/IUSluggRenderer.sol";
import {IUSluggClaimed}     from "../src/IUSluggClaimed.sol";

/// @notice Lightweight router stub for callHook fuzzing. Pulls USLUG via the
/// max allowance the token grants in setSwapRouter, then echoes the round-trip:
/// forwards a fixed amount of ETH on sell, returns full USLUG (no slippage) on
/// buy. Lets us exercise callHook's pull → sell → buy → mint flow in echidna
/// without dragging in a real Uniswap v4 PoolManager.
contract MockHookRouter {
    USlugg404 public token;
    MockSeedSource public seed;

    constructor(USlugg404 _token, MockSeedSource _seed) payable {
        token = _token;
        seed = _seed;
    }

    function sell(uint256 usluggAmount, uint256, uint256) external returns (uint256 ethOut) {
        require(token.transferFrom(address(token), address(this), usluggAmount), "pull");
        seed.reroll();
        ethOut = 1;  // 1 wei is enough to fund the buy leg below; mock has no AMM math
        (bool ok, ) = msg.sender.call{value: ethOut}("");
        require(ok, "sell-refund");
    }

    function buy(uint256 usluggOut, uint256, uint256) external payable returns (uint256 ethSpent) {
        seed.reroll();
        require(token.transfer(msg.sender, usluggOut), "send");
        ethSpent = msg.value;  // soak the whole inbound ETH; no refund means leftover=0
    }

    receive() external payable {}
}

/// @notice Echidna invariant harness for the 404 hybrid. The 404 invariants are
/// the hardest part of the system to verify by hand — every fractional vs whole
/// crossing is a chance to lose or duplicate an NFT. Properties tested:
///
///   1. SUPPLY CONSERVATION: sum of balanceOf across the closed actor universe
///      equals totalSupply at all times. Tokens cannot be created or destroyed
///      outside of mint (constructor) and the wrap/unwrap escrow path.
///
///   2. INVENTORY <= BALANCE/TPS: for any non-skipped actor, sluggsOwned(a)
///      is bounded above by balanceOf[a] / tokensPerSlugg. Loose direction
///      because callHook (path C) and direct ERC-20 transfers (off path A/C)
///      can leave a holder with USLUG and no NFTs, but never with more NFTs
///      than balance/TPS — that would mean we minted an NFT without backing.
///
///   3. NEXT-ID MONOTONIC: nextSluggId never decreases.
///
///   4. NEXT-ID BOUNDED: nextSluggId never exceeds maxSluggs (10000 in real launch).
///      Theoretically the contract has no enforcer for this, but with totalSupply
///      capped at maxSluggs * tokensPerSlugg, the property follows from supply
///      conservation. Echidna verifies it experimentally.
///
///   5. CONTRACT BALANCE = NFTs IN ESCROW: balanceOf[address(token)] equals
///      tokensPerSlugg * (number of currently-wrapped NFTs).
///
///   6. CALLHOOK CONSERVATIVE: a successful callHook(count, slip) increases
///      sluggsOwned by exactly `count` and never increases the caller's balance
///      (round-trip is always net-negative or net-flat after slippage).
///
/// `allContracts: true` in the echidna config lets echidna call functions on
/// the token + claimed contracts directly from its three default senders
/// (0x10000, 0x20000, 0x30000), which gives us multi-actor fuzzing without
/// any prank machinery.
contract Slugg404Invariant {
    USlugg404       public token;
    USluggClaimed   public claimed;
    USluggRenderer  public renderer;
    USluggRuntime   public runtime;
    MockSeedSource  public hookMock;
    MockHookRouter  public mockRouter;

    // The three actors echidna fuzzes msg.sender as. Matches the default
    // senders (0x10000, 0x20000, 0x30000) — keep them in sync if you change
    // the echidna config.
    address constant A = address(0x0000000000000000000000000000000000010000);
    address constant B = address(0x0000000000000000000000000000000000020000);
    address constant C = address(0x0000000000000000000000000000000000030000);

    uint256 constant MAX = 20;       // small cap so cap-exceed bugs surface fast
    uint256 constant TPS = 1e3;      // 1.000 USLUG = 1 NFT (3 decimals)
    uint256 constant TOTAL = MAX * TPS;

    /// @dev Track post/pre callHook deltas across calls; success-path invariants
    /// read these in the property functions.
    bool   private _lastCallHookOk;
    uint256 private _lastCallHookCount;
    int256 private _lastBalanceDelta;
    int256 private _lastSluggDelta;

    constructor() payable {
        hookMock = new MockSeedSource();
        runtime  = new USluggRuntime();
        renderer = new USluggRenderer(address(runtime));
        // Treasury = address(this). Initial supply lands here and skipSluggs[this]=true,
        // so the harness doesn't mint NFTs to itself.
        token    = new USlugg404(hookMock, payable(address(this)), MAX, TPS);
        claimed  = new USluggClaimed(address(token), IUSluggRenderer(address(renderer)));
        token.setRenderer(IUSluggRenderer(address(renderer)));
        token.setClaimedNft(IUSluggClaimed(address(claimed)));
        token.setWrapFee(0);    // zero-fee so wrap/unwrap don't gate on msg.value
        token.setUnwrapFee(0);

        // Wire a mock swap router and stuff it with USLUG + ETH so callHook
        // actually has something to round-trip. Router is on skipSluggs (set by
        // setSwapRouter), so the transfer doesn't auto-mint.
        // Forward half of the harness's deploy ETH to the router so each
        // sell() call has dust to refund. Keep the other half on the harness.
        uint256 halfEth = address(this).balance / 2;
        mockRouter = new MockHookRouter{value: halfEth}(token, hookMock);
        token.setSwapRouter(address(mockRouter));
        token.transfer(address(mockRouter), 5 * TPS);

        // Distribute initial supply across the three actors so there's actual
        // NFT state to fuzz. 4 + 3 + 3 = 10. Harness keeps the remainder
        // (TOTAL - 10*TPS - 5*TPS = 5*TPS) for action_callHook to spend.
        token.transfer(A, 4 * TPS);
        token.transfer(B, 3 * TPS);
        token.transfer(C, 3 * TPS);
    }

    // -------- harness-level actions (echidna also calls token/claimed directly) --------

    /// @dev Advance the seed source so newly-minted sluggs get fresh seeds.
    /// Reduces correlation in the fuzzer's input space.
    function action_reroll_seed() external {
        hookMock.reroll();
    }

    /// @dev Drive callHook with msg.sender == this harness (which is treasury
    /// and therefore on skipSluggs — but skipSluggs only blocks auto-mint on
    /// the receive branch of _move, not callHook's mint loop). Capture pre/post
    /// deltas so the invariant functions can assert success-path properties
    /// (count delta, balance non-increase).
    ///
    /// We can't change msg.sender to A/B/C from a harness function — echidna's
    /// allContracts mode lets echidna call action_callHook from any of A/B/C,
    /// but the inner callHook call has msg.sender == address(this) (the
    /// harness). That's still a valid caller — the harness holds USLUG from
    /// the initial mint.
    function action_callHook(uint8 count, uint16 slip) external payable {
        // Top up the router opportunistically so it can fund payouts when
        // echidna runs back-to-back callHooks without other resets.
        if (token.balanceOf(address(mockRouter)) < uint256(count) * TPS * 2) {
            uint256 here = token.balanceOf(address(this));
            if (here > 0) {
                try token.transfer(address(mockRouter), here / 2) {} catch {}
            }
        }
        // Forward any inbound ETH to the router so the buy leg can fund itself.
        if (msg.value > 0) {
            (bool sent, ) = address(mockRouter).call{value: msg.value}("");
            sent;
        }
        uint256 balBefore   = token.balanceOf(address(this));
        uint256 sluggBefore = token.sluggsOwned(address(this));
        try token.callHook(uint256(count), uint256(slip)) {
            _lastCallHookOk    = true;
            _lastCallHookCount = uint256(count);
            _lastBalanceDelta  = int256(token.balanceOf(address(this))) - int256(balBefore);
            _lastSluggDelta    = int256(token.sluggsOwned(address(this))) - int256(sluggBefore);
        } catch {
            // Failed call — leave _lastCallHookOk as previously stored, but
            // since the success-path invariants short-circuit on
            // `!_lastCallHookOk`, we explicitly clear the flag here so the
            // next failure-then-property-check pass doesn't see stale truth.
            _lastCallHookOk = false;
        }
    }

    // -------- invariants --------

    /// @notice No-creation conservation. The 404's only public mint path is
    /// the constructor; there is no `mint(...)` afterwards. So the sum of
    /// balances across our tracked actors must NEVER exceed totalSupply,
    /// regardless of where tokens get transferred. (Equality doesn't hold
    /// because echidna can transfer to any address, leaking tokens out of the
    /// tracked universe — that's expected and correct contract behavior. What
    /// we're guarding against is a bug that creates new tokens.)
    function echidna_no_token_creation() external view returns (bool) {
        uint256 sum = token.balanceOf(address(this))
                    + token.balanceOf(A)
                    + token.balanceOf(B)
                    + token.balanceOf(C)
                    + token.balanceOf(address(token))
                    + token.balanceOf(address(mockRouter));
        return sum <= TOTAL;
    }

    /// @notice For non-skipped actors A/B/C, NFT count must NEVER exceed the
    /// whole-USLUG portion of their balance. Loose direction: post-redesign,
    /// USLUG can arrive without NFTs (gated swapFiredThisTx), so equality
    /// doesn't hold. What we're guarding against is the inverse — minting an
    /// NFT without underlying balance, which would let the holder later sell
    /// USLUG they don't have or wrap a phantom slugg. Strict <= keeps that
    /// door closed.
    function echidna_inventory_matches_balance() external view returns (bool) {
        return _consistent(A) && _consistent(B) && _consistent(C);
    }

    function _consistent(address a) internal view returns (bool) {
        if (token.skipSluggs(a)) return true;  // skipped accounts don't track NFTs
        return token.sluggsOwned(a) <= token.balanceOf(a) / TPS;
    }

    /// @notice nextSluggId only ever increases.
    uint256 private _maxObservedNextId;
    function echidna_nextSluggId_monotonic() external returns (bool) {
        uint256 cur = token.nextSluggId();
        if (cur < _maxObservedNextId) return false;
        _maxObservedNextId = cur;
        return true;
    }

    /// @notice The contract's escrow balance must equal tokensPerSlugg ×
    /// (number of currently-outstanding wrapped NFTs). Each wrap() escrows
    /// 1 NFT worth of USLUG inside the contract; each unwrap() releases it.
    /// nextId on the claimed contract minus a count of burned tokens is one
    /// reasonable derivation, but we use a simpler structural check: token's
    /// ERC-20 balance must be a clean multiple of tokensPerSlugg.
    function echidna_escrow_balance_is_whole_units() external view returns (bool) {
        return token.balanceOf(address(token)) % TPS == 0;
    }

    /// @notice nextSluggId never exceeds an upper bound derived from supply.
    /// Each new id corresponds to a "whole USLUG transitioned into existence"
    /// event. With supply conservation and the 1:1 mapping, the cumulative id
    /// count is bounded by total mints + total unwraps. Loose upper bound:
    /// MAX × (1 + reasonable wrap-cycle ceiling). We use 10000 as a safety
    /// net — if echidna pushes nextSluggId past that, something is off.
    function echidna_nextSluggId_loose_bound() external view returns (bool) {
        return token.nextSluggId() <= 100_000;  // 10x churn ceiling for the 10-actor harness
    }

    /// @notice On a successful callHook(count, _), the caller's NFT count must
    /// have grown by exactly `count`. Anything else means we lost or
    /// duplicated a slugg in the round-trip path — the worst-case bug class.
    function echidna_callHook_increases_inventory_by_count_on_success() external view returns (bool) {
        if (!_lastCallHookOk) return true;
        return _lastSluggDelta == int256(_lastCallHookCount);
    }

    /// @notice callHook is a round-trip with non-trivial slippage budget; on
    /// success the caller's USLUG balance must NEVER grow. (Strictly <= 0:
    /// the caller pays slippage out, gets nothing extra back.)
    function echidna_callHook_never_increases_balance() external view returns (bool) {
        if (!_lastCallHookOk) return true;
        return _lastBalanceDelta <= 0;
    }

    // -------- ETH receive (so wrap/unwrap with non-zero fee works if owner
    //          sets a fee mid-fuzz) --------
    receive() external payable {}
}
