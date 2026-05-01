// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ISeedSource}     from "../src/ISeedSource.sol";
import {USlugg404}       from "../src/USlugg404.sol";
import {USluggClaimed}   from "../src/USluggClaimed.sol";
import {USluggRenderer}  from "../src/USluggRenderer.sol";
import {USluggRuntime}   from "../src/USluggRuntime.sol";
import {IUSluggRenderer} from "../src/IUSluggRenderer.sol";
import {IUSluggClaimed}  from "../src/IUSluggClaimed.sol";

/// @dev Stub ISeedSource so tests don't need the real v4 hook + PoolManager
/// dance. Mimics what USluggHook would expose: a currentSeed that mutates
/// every "swap" plus a swapCount counter, and a configurable swapFiredThisTx
/// flag that gates auto-mint on the receive branch of _move.
contract MockSeedSource is ISeedSource {
    bytes32 public override currentSeed;
    uint64  public override swapCount;
    /// @dev Test-controlled. Tests that exercise auto-mint set this true; tests
    /// that exercise "USLUG without slugg" leave it false. Production hook uses
    /// EIP-1153 transient storage gated on locked-pool afterSwap.
    bool public swapFired = true;

    function reroll() external {
        unchecked { swapCount++; }
        currentSeed = keccak256(abi.encode(currentSeed, swapCount, block.prevrandao));
    }

    function swapFiredThisTx() external view override returns (bool) {
        return swapFired;
    }

    function setSwapFired(bool v) external {
        swapFired = v;
    }
}

/// @dev Light-weight stand-in for USluggSwap that exercises just the
/// IUSluggSwapRouter surface USlugg404.callHook depends on. Configurable price,
/// slippage, and fault injection cover the suite's positive + negative paths.
///
/// Behavior:
///   sell(amount, minOut, deadline): pulls USLUG via transferFrom against the
///     max-allowance USlugg404 grants in setSwapRouter, then forwards
///     `sellEthOut` ETH back to the caller. Rolls the mock seed to mimic the
///     locked-pool afterSwap.
///   buy{value: maxEth}(usluggOut, maxEthIn, deadline): exact-output by
///     construction. Spends `buyEthCost` (configurable), refunds the rest,
///     and transfers `usluggOut` USLUG back to the caller from its own
///     working balance. Rolls the seed again.
///
/// We don't model real AMM math — for slippage scenarios the test rigs sets
/// `slippageBps` so the mock returns slightly less USLUG than requested
/// (when allowed), letting the buffer test fire the underflow that the
/// production buffer check is meant to catch.
contract MockSwapRouter {
    USlugg404 public token;
    MockSeedSource public seed;
    uint256 public sellEthOut = 1 ether;
    uint256 public buyEthCost = 1 ether;
    uint256 public slippageBps;     // if >0, buy returns usluggOut*(10000-slippageBps)/10000
    bool    public revertOnBuy;     // if true, buy() reverts (for all-or-nothing test)
    bool    public reentrantBuy;    // if true, buy() re-enters callHook (for reentrancy test)

    constructor(USlugg404 _token, MockSeedSource _seed) {
        token = _token;
        seed = _seed;
    }

    function setSellEthOut(uint256 v) external { sellEthOut = v; }
    function setBuyEthCost(uint256 v) external { buyEthCost = v; }
    function setSlippageBps(uint256 v) external { slippageBps = v; }
    function setRevertOnBuy(bool v) external { revertOnBuy = v; }
    function setReentrantBuy(bool v) external { reentrantBuy = v; }

    function sell(uint256 usluggAmount, uint256 /*minEthOut*/, uint256 /*deadline*/)
        external returns (uint256 ethOut)
    {
        // Pull USLUG via the max-allowance USlugg404 set up for us.
        require(
            token.transferFrom(address(token), address(this), usluggAmount),
            "mock: pull failed"
        );
        seed.reroll();
        seed.setSwapFired(true);
        ethOut = sellEthOut;
        (bool ok, ) = msg.sender.call{value: ethOut}("");
        require(ok, "mock: sell refund failed");
    }

    function buy(uint256 usluggOut, uint256 /*maxEthIn*/, uint256 /*deadline*/)
        external payable returns (uint256 ethSpent)
    {
        if (revertOnBuy) revert("mock: buy reverted");
        if (reentrantBuy) {
            // Try to re-enter callHook from inside the buy leg's ETH refund.
            // The nonReentrant guard on USlugg404.callHook should slap this
            // down with Reentrant().
            USlugg404(payable(address(token))).callHook(1, 100);
        }
        seed.reroll();
        seed.setSwapFired(true);

        // Send back USLUG (possibly less due to mock-configured slippage).
        uint256 actualOut = slippageBps == 0
            ? usluggOut
            : (usluggOut * (10_000 - slippageBps)) / 10_000;
        require(token.transfer(msg.sender, actualOut), "mock: send failed");

        ethSpent = buyEthCost;
        // Refund the difference between provided ETH and ethSpent. We require
        // msg.value >= ethSpent — otherwise the buy can't fund itself.
        require(msg.value >= ethSpent, "mock: insufficient eth");
        uint256 refund = msg.value - ethSpent;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "mock: buy refund failed");
        }
    }

    receive() external payable {}
}

contract USlugg404Test is Test {
    MockSeedSource  hook;
    USluggRuntime   runtime;
    USluggRenderer  renderer;
    USlugg404       token;
    USluggClaimed   claimed;

    address payable treasury = payable(address(0x100));
    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);

    uint256 constant MAX = 10_000;
    uint256 constant TPS = 1e3;  // tokensPerSlugg with decimals=3 → 1.000 USLUG/NFT

    function setUp() public {
        hook = new MockSeedSource();
        hook.reroll();  // give it a non-zero starting seed

        runtime  = new USluggRuntime();
        renderer = new USluggRenderer(address(runtime));
        token    = new USlugg404(hook, treasury, MAX, TPS);
        claimed  = new USluggClaimed(address(token), IUSluggRenderer(address(renderer)));

        token.setRenderer(IUSluggRenderer(address(renderer)));
        token.setClaimedNft(IUSluggClaimed(address(claimed)));
        token.setWrapFee(0.001111 ether);
        token.setUnwrapFee(0.0069 ether);
    }

    /// @notice Constructor must reject treasury=0 — otherwise the entire
    /// initial supply is assigned to address(0) and irrecoverable.
    function test_constructor_rejects_zero_treasury() public {
        vm.expectRevert(USlugg404.ZeroTreasury.selector);
        new USlugg404(hook, payable(address(0)), MAX, TPS);
    }

    function test_constructor_rejects_zero_tokensPerSlugg() public {
        vm.expectRevert(USlugg404.ZeroTokensPerSlugg.selector);
        new USlugg404(hook, treasury, MAX, 0);
    }

    /// @notice Treasury → Alice transfer of 5.000 USLUG mints 5 NFTs to Alice.
    function test_buy_mints_nfts() public {
        vm.prank(treasury);
        token.transfer(alice, 5 * TPS);

        assertEq(token.balanceOf(alice), 5 * TPS, "alice balance");
        assertEq(token.sluggsOwned(alice), 5, "alice nft count");

        // All NFTs have unique seeds derived from hook's currentSeed
        bytes32 a0; bytes32 a1;
        (a0,,) = token.sluggs(0);
        (a1,,) = token.sluggs(1);
        assertTrue(a0 != a1, "seeds must differ across mints");

        assertEq(token.ownerOf(0), alice);
        assertEq(token.ownerOf(4), alice);
    }

    /// @notice Selling burns NFTs; the next buyer gets fresh seeds.
    function test_sell_burns_then_rebuy_mints_new_seeds() public {
        vm.prank(treasury);
        token.transfer(alice, 1 * TPS);

        bytes32 firstSeed;
        (firstSeed,,) = token.sluggs(0);

        // Alice sells back to treasury — burns NFT 0
        vm.prank(alice);
        token.transfer(treasury, 1 * TPS);
        assertEq(token.sluggsOwned(alice), 0, "alice nfts after sell");

        // Hook re-rolls, then Bob buys
        hook.reroll();
        vm.prank(treasury);
        token.transfer(bob, 1 * TPS);

        bytes32 bobSeed;
        (bobSeed,,) = token.sluggs(1);  // nextSluggId continues, so id=1
        assertEq(token.ownerOf(1), bob);
        assertTrue(firstSeed != bobSeed, "rebuy must produce new seed");
    }

    /// @notice Fractional balance below 1.000 doesn't mint an NFT.
    function test_fractional_holds_no_nft() public {
        vm.prank(treasury);
        token.transfer(alice, TPS - 1);  // 0.999 USLUG

        assertEq(token.balanceOf(alice), TPS - 1);
        assertEq(token.sluggsOwned(alice), 0, "fractional holds no NFT");
    }

    /// @notice wrap() lifts a Slugg into the standalone ERC-721. Pays fee.
    function test_wrap_creates_standalone_erc721() public {
        vm.prank(treasury);
        token.transfer(alice, 1 * TPS);

        uint256 sluggId = 0;
        bytes32 origSeed;
        (origSeed,,) = token.sluggs(sluggId);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 claimedId = token.wrap{value: 0.001111 ether}(sluggId);

        // 404 NFT burned, claimed NFT minted
        assertEq(token.ownerOf(sluggId), address(0), "404 nft cleared");
        assertEq(claimed.ownerOf(claimedId), alice, "claimed nft owned by alice");

        (bytes32 cSeed,,) = claimed.claimed(claimedId);
        assertEq(cSeed, origSeed, "claimed seed preserved");

        // Treasury received the fee
        assertEq(treasury.balance, 0.001111 ether);
    }

    /// @notice unwrap() returns USLUG and re-mints into 404.
    function test_unwrap_returns_to_404() public {
        vm.prank(treasury);
        token.transfer(alice, 1 * TPS);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 claimedId = token.wrap{value: 0.001111 ether}(0);

        vm.prank(alice);
        uint256 newSluggId = token.unwrap{value: 0.0069 ether}(claimedId);

        assertEq(token.ownerOf(newSluggId), alice);
        assertEq(token.balanceOf(alice), 1 * TPS, "balance restored");
        assertEq(treasury.balance, 0.001111 ether + 0.0069 ether);
    }

    /// @notice tokenURI returns valid HTML metadata with animation_url + image fallback.
    function test_tokenURI_format() public {
        vm.prank(treasury);
        token.transfer(alice, 1 * TPS);

        string memory uri = token.tokenURI(0);
        bytes memory u = bytes(uri);

        assertTrue(_contains(u, "data:application/json;utf8,"), "json prefix");
        assertTrue(_contains(u, "\"name\":\"uSlugg #0\""), "name");
        assertTrue(_contains(u, "\"animation_url\":\"data:text/html;utf8,"), "animation_url");
        assertTrue(_contains(u, "window.KEY="), "key embedded");
        assertTrue(_contains(u, "<svg"), "svg fallback");
    }

    function _contains(bytes memory hay, string memory ndl) internal pure returns (bool) {
        bytes memory n = bytes(ndl);
        if (n.length > hay.length) return false;
        for (uint256 i = 0; i + n.length <= hay.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (hay[i + j] != n[j]) { ok = false; break; }
            }
            if (ok) return true;
        }
        return false;
    }

    // -------- _move auto-mint gating tests --------

    /// @notice Direct ERC-20 transfer with the seed source's swapFired flag
    /// off must NOT auto-mint a slugg on the receive side. Path A and path C
    /// are the only paths that materialize sluggs; everything else (faucet,
    /// airdrop, p2p) ships USLUG without sluggs.
    function test_move_does_not_auto_mint_when_swap_not_fired() public {
        hook.setSwapFired(false);

        vm.prank(treasury);
        token.transfer(alice, 3 * TPS);

        assertEq(token.balanceOf(alice), 3 * TPS, "alice has USLUG");
        assertEq(token.sluggsOwned(alice), 0, "no sluggs minted without swap");
    }

    /// @notice Same flow with swapFired=true mints sluggs to the receiver.
    function test_move_auto_mints_when_swap_fired() public {
        hook.setSwapFired(true);

        vm.prank(treasury);
        token.transfer(alice, 4 * TPS);

        assertEq(token.balanceOf(alice), 4 * TPS, "alice balance");
        assertEq(token.sluggsOwned(alice), 4, "sluggs auto-minted when swap fired");
    }

    /// @notice Holders who picked up USLUG without sluggs (path A/C off) must
    /// still be able to spend their balance — the lossy-burn branch in _move
    /// handles "balance crossed a whole, but inventory[from] is empty" without
    /// underflowing on `_inventory[from].length - 1`.
    function test_move_lossy_burn_when_inventory_empty() public {
        // Alice receives USLUG with no sluggs (path B-equivalent).
        hook.setSwapFired(false);
        vm.prank(treasury);
        token.transfer(alice, 2 * TPS);

        assertEq(token.sluggsOwned(alice), 0, "no inventory yet");

        // Alice transfers some away — would naively try to burn her last NFT
        // but she has none. Pre-fix, this would underflow and brick transfers.
        vm.prank(alice);
        token.transfer(bob, 1 * TPS);

        assertEq(token.balanceOf(alice), 1 * TPS, "alice balance halved");
        assertEq(token.sluggsOwned(alice), 0, "still no sluggs");
        // Bob got USLUG but no slugg either (still gated off).
        assertEq(token.balanceOf(bob), 1 * TPS);
        assertEq(token.sluggsOwned(bob), 0);
    }
}

// =====================================================================
// callHook test suite. We run callHook through a lightweight mock router
// that implements the IUSluggSwapRouter surface and stages the ETH ↔ USLUG
// round-trip. The mock exposes knobs for slippage, revert, and reentrancy
// so we can exercise every error path the production contract guards.
// =====================================================================
contract USlugg404CallHookTest is Test {
    MockSeedSource  hook;
    USluggRuntime   runtime;
    USluggRenderer  renderer;
    USlugg404       token;
    USluggClaimed   claimed;
    MockSwapRouter  router;

    address payable treasury = payable(address(0x100));
    address alice    = address(0xA11CE);

    uint256 constant MAX = 10_000;
    uint256 constant TPS = 1e3;

    /// @dev Re-emit the event signatures here so vm.expectEmit can match.
    event CallHookCompleted(
        address indexed caller,
        uint256 usluggIn,
        uint256 ethRoundTrip,
        uint256 usluggBack,
        uint256 count
    );

    function setUp() public {
        hook = new MockSeedSource();
        hook.reroll();

        runtime  = new USluggRuntime();
        renderer = new USluggRenderer(address(runtime));
        token    = new USlugg404(hook, treasury, MAX, TPS);
        claimed  = new USluggClaimed(address(token), IUSluggRenderer(address(renderer)));

        token.setRenderer(IUSluggRenderer(address(renderer)));
        token.setClaimedNft(IUSluggClaimed(address(claimed)));

        router = new MockSwapRouter(token, hook);
        token.setSwapRouter(address(router));

        // Pre-fund the mock router with enough ETH (for sell payouts) and
        // USLUG (to deliver during buy). The USLUG transfer to router will
        // skip auto-mint because setSwapRouter put router on skipSluggs.
        vm.deal(address(router), 100 ether);
        vm.prank(treasury);
        token.transfer(address(router), 100 * TPS);
    }

    /// @notice Bug #1: dust left over from the buy leg's exact-output refund
    /// must be forwarded to the caller, not stranded on the contract.
    function test_callHook_refunds_eth_dust_to_caller() public {
        // Stage prices so sell pays out 1 ETH but buy only spends 0.4 ETH —
        // the 0.6 ETH delta is the refund we expect to land on alice.
        router.setSellEthOut(1 ether);
        router.setBuyEthCost(0.4 ether);

        // Pre-fund USlugg404 with extra ETH so we can verify ethBefore is
        // anchored — pre-existing balance must NOT be swept to the caller.
        vm.deal(address(token), 0.25 ether);

        // Alice has 2*TPS for the round-trip plus a healthy buffer. We
        // keep her at 0 existing sluggs (swapFired=false on the seed) so
        // the buffer math is just count*TPS plus the slippage allowance.
        hook.setSwapFired(false);
        vm.prank(treasury);
        token.transfer(alice, 2 * TPS + 100); // count*TPS + 5% buffer headroom
        assertEq(token.sluggsOwned(alice), 0, "no sluggs yet (gate off)");

        uint256 callerEthBefore = alice.balance;
        uint256 contractEthBefore = address(token).balance;

        vm.prank(alice);
        token.callHook(2, 100);

        assertEq(
            address(token).balance,
            contractEthBefore,
            "contract balance restored to pre-call snapshot"
        );
        // The dust = sell payout - buy cost = 1 ether - 0.4 ether = 0.6 ether.
        assertEq(alice.balance - callerEthBefore, 0.6 ether, "alice received the buy-leg dust");
        assertEq(token.sluggsOwned(alice), 2, "sluggs minted");
    }

    /// @notice Bug #2: callHook must reject a balance that exactly matches
    /// `count*TPS` — slippage erosion would push `balance/TPS` below
    /// `inventory.length`, breaking the invariant.
    function test_callHook_reverts_without_slippage_buffer() public {
        // Alice has exactly count*TPS, no buffer. With maxSlippageBps=100
        // (the UI default) the buffer requirement is `count*TPS + 1%`, so
        // alice falls short.
        hook.setSwapFired(false);
        vm.prank(treasury);
        token.transfer(alice, 3 * TPS);

        vm.prank(alice);
        vm.expectRevert(USlugg404.InsufficientBuffer.selector);
        token.callHook(3, 100);
    }

    /// @notice Buffer-meets-requirement happy path. Caller has count*TPS plus
    /// the worst-case slippage; callHook completes; post-state invariant
    /// `inventory.length <= balance/TPS` holds.
    function test_callHook_succeeds_with_buffer() public {
        // Configure mock for exact-output behavior — usluggBack equals
        // amountIn. Buy spends 1 ether so there's no dust delta to test here.
        router.setSlippageBps(0);
        router.setSellEthOut(1 ether);
        router.setBuyEthCost(1 ether);

        hook.setSwapFired(false);
        // count=3, maxSlippageBps=100 → buffer = 3 * 1e3 * 1% = 30. Round up
        // to 100 to give clean headroom. balance must be >= 3*TPS + 100.
        uint256 amountIn = 3 * TPS;
        uint256 buffer = (amountIn * 100) / 10_000; // 30
        vm.prank(treasury);
        token.transfer(alice, amountIn + buffer + 5);  // a hair over the floor

        vm.prank(alice);
        token.callHook(3, 100);

        // Post-state: alice has 3 sluggs and balance ≥ 3 * TPS (no slippage,
        // so balance equals starting balance).
        assertEq(token.sluggsOwned(alice), 3, "sluggs minted");
        // Invariant: inventory.length <= balance/TPS.
        assertTrue(
            token.sluggsOwned(alice) <= token.balanceOf(alice) / TPS,
            "post-call inventory invariant holds"
        );
    }

    /// @notice On a fresh deploy with no setSwapRouter call, callHook must
    /// revert immediately on the router-not-set guard.
    function test_callHook_reverts_when_router_unset() public {
        // Fresh USlugg404 with no setSwapRouter ever called.
        USlugg404 fresh = new USlugg404(hook, treasury, MAX, TPS);

        // Move some USLUG to alice on the fresh token so the early-return is
        // genuinely the router-not-set check (not InsufficientBalance/Buffer).
        vm.prank(treasury);
        fresh.transfer(alice, 5 * TPS);

        vm.prank(alice);
        vm.expectRevert(USlugg404.RouterNotSet.selector);
        fresh.callHook(1, 100);
    }

    /// @notice maxSlippageBps above the on-chain hard cap (500) reverts. The
    /// UI defaults to 100 (1%); 500 (5%) is the absolute ceiling.
    function test_callHook_reverts_on_excess_slippage_param() public {
        vm.prank(treasury);
        token.transfer(alice, 5 * TPS);

        vm.prank(alice);
        vm.expectRevert(USlugg404.SlippageTooHigh.selector);
        token.callHook(1, 501);
    }

    /// @notice The nonReentrant guard must trip if a malicious receiver
    /// re-enters callHook during the ETH refund inside buy(). The mock router
    /// re-enters synthetically in the same call frame.
    function test_callHook_reentrancy_guard() public {
        // Disable auto-mint so alice doesn't pre-load with sluggs that would
        // bust the buffer — the test wants the call to enter callHook and
        // reach the reentrant buy(), not bounce on InsufficientBuffer.
        hook.setSwapFired(false);
        router.setReentrantBuy(true);
        vm.prank(treasury);
        token.transfer(alice, 5 * TPS);

        vm.prank(alice);
        // The reentrant call inside the mock buy() hits USlugg404.callHook
        // again while _locked == 2, triggering Reentrant(). That selector
        // bubbles up through the outer call frame as the revert reason.
        vm.expectRevert(USlugg404.Reentrant.selector);
        token.callHook(1, 100);
    }

    /// @notice All-or-nothing: when the buy leg reverts, the user's USLUG must
    /// be returned (because the entire tx unwinds) and no sluggs are minted.
    function test_callHook_all_or_nothing() public {
        router.setRevertOnBuy(true);

        hook.setSwapFired(false);
        vm.prank(treasury);
        token.transfer(alice, 5 * TPS);

        uint256 aliceBalBefore = token.balanceOf(alice);
        uint256 sluggsBefore   = token.sluggsOwned(alice);
        uint256 nextIdBefore   = token.nextSluggId();

        vm.prank(alice);
        vm.expectRevert();
        token.callHook(2, 100);

        // Full unwind: balance restored, no sluggs minted, nextSluggId
        // unchanged.
        assertEq(token.balanceOf(alice), aliceBalBefore, "USLUG returned");
        assertEq(token.sluggsOwned(alice), sluggsBefore, "no sluggs minted");
        assertEq(token.nextSluggId(), nextIdBefore, "nextSluggId rolled back");
    }

    /// @notice Two consecutive callHook invocations must produce different
    /// seeds — the second swap should re-roll the seed source. With our mock
    /// rerolling on every sell+buy, two calls advance the seed 4 times.
    function test_callHook_fresh_seed_per_invocation() public {
        // Drop into "raw USLUG, no auto-mint" mode so alice's pre-call balance
        // doesn't pull in 10 sluggs from the receive branch — that would push
        // her existing-sluggs coverage past her balance and fail the buffer.
        hook.setSwapFired(false);
        vm.prank(treasury);
        token.transfer(alice, 10 * TPS);

        vm.prank(alice);
        token.callHook(1, 100);
        bytes32 firstSeed;
        (firstSeed,,) = token.sluggs(0);

        vm.prank(alice);
        token.callHook(1, 100);
        bytes32 secondSeed;
        (secondSeed,,) = token.sluggs(1);

        assertTrue(firstSeed != secondSeed, "fresh seed each invocation");
    }

    /// @notice CallHookCompleted event must fire on success with the right
    /// arguments. This is the analytics surface for the round-trip path.
    function test_callHook_emits_CallHookCompleted_event() public {
        router.setSellEthOut(1 ether);
        router.setBuyEthCost(0.5 ether);

        // Disable auto-mint so alice's pre-call slugg count is zero — keeps
        // the buffer arithmetic exact: required = 2*TPS + slip.
        hook.setSwapFired(false);
        vm.prank(treasury);
        token.transfer(alice, 5 * TPS);

        // Match the indexed `caller` and the four payload fields. usluggIn =
        // 2*TPS = 2000, ethRoundTrip = 1 ether (sell payout), usluggBack =
        // (amountIn * (10000 - maxSlippageBps)) / 10000 = 2000*9900/10000 = 1980,
        // count = 2.
        uint256 amountIn   = 2 * TPS;
        uint256 expected   = (amountIn * (10_000 - 100)) / 10_000;
        vm.expectEmit(true, true, true, true, address(token));
        emit CallHookCompleted(alice, amountIn, 1 ether, expected, 2);

        vm.prank(alice);
        token.callHook(2, 100);
    }
}
