// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}                 from "forge-std/Test.sol";
import {IPoolManager}                   from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}                         from "v4-core/interfaces/IHooks.sol";
import {PoolKey}                        from "v4-core/types/PoolKey.sol";
import {Currency}                       from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta}   from "v4-core/types/BalanceDelta.sol";
import {SwapParams}                     from "v4-core/types/PoolOperation.sol";
import {USluggHook}                     from "../src/USluggHook.sol";

/// @notice USluggHook tests focus on auth, two-step ownership, fee cap, and
/// seed mutation. The afterSwap fee-take math depends on a real PoolManager,
/// which we mock at the function-selector level via vm.mockCall.
contract USluggHookTest is Test {
    USluggHook hook;

    address poolManager = address(0xCAFE);
    address owner;       // deployer
    address newOwner    = address(0xBEEF);
    address alice       = address(0xA11CE);

    function setUp() public {
        owner = address(this);
        hook = new USluggHook(IPoolManager(poolManager));

        // Stub poolManager.take(...) so afterSwap doesn't blow up reaching for
        // a non-existent contract at the EOA poolManager address.
        vm.mockCall(poolManager, abi.encodeWithSelector(IPoolManager.take.selector), "");
    }

    // -------- access control --------

    function test_only_pool_manager_can_call_afterSwap() public {
        PoolKey memory key = _key();
        SwapParams memory sp = SwapParams({
            zeroForOne:        true,
            amountSpecified:   -1_000_000,
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(int128(1_000_000), int128(-1_500_000));

        vm.prank(alice);
        vm.expectRevert(USluggHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, sp, delta, "");
    }

    function test_only_owner_can_setFeeBps() public {
        vm.prank(alice);
        vm.expectRevert(USluggHook.NotOwner.selector);
        hook.setFeeBps(20);
    }

    function test_only_owner_can_withdrawFees() public {
        vm.prank(alice);
        vm.expectRevert(USluggHook.NotOwner.selector);
        hook.withdrawFees(Currency.wrap(address(0)), alice, 0);
    }

    function test_withdrawFees_rejects_zero_recipient() public {
        // Owner mistake guard — sending fees to address(0) would burn them.
        vm.expectRevert(bytes("to=0"));
        hook.withdrawFees(Currency.wrap(address(0)), address(0), 0);
    }

    function test_only_owner_can_transferOwnership() public {
        vm.prank(alice);
        vm.expectRevert(USluggHook.NotOwner.selector);
        hook.transferOwnership(newOwner);
    }

    // -------- fee cap --------

    function test_setFeeBps_caps_at_100() public {
        hook.setFeeBps(100);            // 1% — at cap, allowed
        assertEq(hook.feeBps(), 100);

        vm.expectRevert(USluggHook.FeeTooHigh.selector);
        hook.setFeeBps(101);            // > 1%, must revert
    }

    // -------- two-step ownership --------

    function test_transferOwnership_does_not_take_effect_until_accept() public {
        hook.transferOwnership(newOwner);

        // Owner is unchanged; pendingOwner is set.
        assertEq(hook.owner(),        owner,    "owner stays");
        assertEq(hook.pendingOwner(), newOwner, "pending set");

        // Old owner can still operate.
        hook.setFeeBps(15);
        assertEq(hook.feeBps(), 15);

        // New owner cannot — hasn't accepted.
        vm.prank(newOwner);
        vm.expectRevert(USluggHook.NotOwner.selector);
        hook.setFeeBps(20);
    }

    function test_acceptOwnership_finalizes_handoff() public {
        hook.transferOwnership(newOwner);

        vm.prank(newOwner);
        hook.acceptOwnership();

        assertEq(hook.owner(),        newOwner, "owner moved");
        assertEq(hook.pendingOwner(), address(0), "pending cleared");

        // New owner can now operate; old owner cannot.
        vm.prank(newOwner);
        hook.setFeeBps(50);
        assertEq(hook.feeBps(), 50);

        vm.expectRevert(USluggHook.NotOwner.selector);
        hook.setFeeBps(60);
    }

    function test_only_pending_owner_can_accept() public {
        hook.transferOwnership(newOwner);

        vm.prank(alice);
        vm.expectRevert(USluggHook.NotPendingOwner.selector);
        hook.acceptOwnership();
    }

    function test_transfer_to_zero_cancels_pending() public {
        hook.transferOwnership(newOwner);
        assertEq(hook.pendingOwner(), newOwner);

        hook.transferOwnership(address(0));
        assertEq(hook.pendingOwner(), address(0), "pending cleared");

        // newOwner can no longer accept — it was un-proposed.
        vm.prank(newOwner);
        vm.expectRevert(USluggHook.NotPendingOwner.selector);
        hook.acceptOwnership();
    }

    function test_transferOwnership_can_be_re_proposed() public {
        hook.transferOwnership(newOwner);
        hook.transferOwnership(alice);     // overwrite
        assertEq(hook.pendingOwner(), alice);

        // Old proposed address cannot accept any longer.
        vm.prank(newOwner);
        vm.expectRevert(USluggHook.NotPendingOwner.selector);
        hook.acceptOwnership();
    }

    // -------- afterSwap seed + fee logic --------

    function test_seed_mutates_each_call_and_swapCount_increments() public {
        bytes32 s0 = hook.currentSeed();
        uint64  c0 = hook.swapCount();

        _afterSwap(true, -1_000, 1_000, -1_500);  // exact-input zeroForOne, fee taken on currency1
        bytes32 s1 = hook.currentSeed();
        uint64  c1 = hook.swapCount();
        assertTrue(s1 != s0, "seed mutates");
        assertEq(c1, c0 + 1, "count++");

        _afterSwap(false, 1_000, 1_000, -1_500);
        bytes32 s2 = hook.currentSeed();
        assertTrue(s2 != s1, "seed mutates again");
        assertEq(hook.swapCount(), c0 + 2, "count++ again");
    }

    function test_afterSwap_returns_fee_in_unspecified_currency() public {
        // Exact-input on token0 (zeroForOne=true, amountSpecified<0) →
        // unspecified is currency1 → fee delta is on amount1.
        // amount1 = -1500 (pool credits user); |delta| * feeBps / 10000 at default 10 bps = 1500*10/10000 = 1.
        (bytes4 selector, int128 feeDelta) = _afterSwap(true, -1_000, 1_000, -1_500);
        assertEq(selector, IHooks.afterSwap.selector, "selector");
        assertEq(int256(feeDelta), int256(1), "fee = floor(1500 * 10 / 10000)");
    }

    function test_afterSwap_zero_fee_returns_zero_delta() public {
        // Tiny swap → 5 * 10 / 10000 = 0.005, floors to 0; hook returns 0.
        (, int128 feeDelta) = _afterSwap(true, -5, 5, -5);
        assertEq(int256(feeDelta), int256(0), "below 1-unit threshold");
    }

    function test_afterSwap_fee_scales_with_feeBps() public {
        hook.setFeeBps(100);  // 1%
        // amount1 = -1500, fee = 1500 * 100 / 10000 = 15
        (, int128 feeDelta) = _afterSwap(true, -1_000, 1_000, -1_500);
        assertEq(int256(feeDelta), int256(15));
    }

    // -------- disabled hooks revert --------

    function test_disabled_hooks_revert() public {
        PoolKey memory key = _key();
        vm.expectRevert(USluggHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, 0);
    }

    // -------- VULN: hook is permissionless across pools --------
    // Anyone can attach this hook to any pool they create. Without lockPool,
    // attacker-pool swaps mutate currentSeed too, letting MEV searchers grind
    // for rare sluggs deterministically.

    function test_VULN_unlocked_hook_seed_mutates_for_any_pool() public {
        // Two distinct pool keys — neither has been locked yet.
        PoolKey memory ourKey      = _keyWith(address(0x111), address(0x222));
        PoolKey memory attackerKey = _keyWith(address(0xAAA), address(0xBBB));

        bytes32 s0 = hook.currentSeed();
        _afterSwapWithKey(ourKey,      true, -1_000, 1_000, -1_500);
        bytes32 s1 = hook.currentSeed();
        assertTrue(s1 != s0, "our pool: seed should mutate");

        // VULN: an attacker pool also mutates the seed pre-lock.
        _afterSwapWithKey(attackerKey, true, -1_000, 1_000, -1_500);
        bytes32 s2 = hook.currentSeed();
        assertTrue(s2 != s1, "attacker pool ALSO mutates seed pre-lock (this is the bug)");
    }

    function test_FIX_locked_hook_ignores_other_pools() public {
        PoolKey memory ourKey      = _keyWith(address(0x111), address(0x222));
        PoolKey memory attackerKey = _keyWith(address(0xAAA), address(0xBBB));

        // Lock to ourKey.
        hook.lockPool(ourKey);
        assertTrue(hook.lockedPoolHash() != bytes32(0), "lockedPoolHash set");

        // Our pool: seed still mutates.
        bytes32 s0 = hook.currentSeed();
        uint64  c0 = hook.swapCount();
        _afterSwapWithKey(ourKey, true, -1_000, 1_000, -1_500);
        bytes32 s1 = hook.currentSeed();
        assertTrue(s1 != s0, "our pool: seed must still mutate after lock");
        assertEq(hook.swapCount(), c0 + 1, "our pool: swapCount++");

        // Attacker pool: NOTHING happens. Same seed, same swapCount.
        _afterSwapWithKey(attackerKey, true, -1_000, 1_000, -1_500);
        assertEq(hook.currentSeed(), s1,    "attacker pool MUST NOT mutate seed");
        assertEq(hook.swapCount(),   c0 + 1, "attacker pool MUST NOT advance swapCount");

        // Attacker pool also gets zero fee back (the second return value),
        // verified by re-running through the helper.
        (, int128 fee) = _afterSwapReturn(attackerKey, true, -1_000_000, 1_000_000, -1_500_000);
        assertEq(int256(fee), int256(0), "attacker pool fee delta must be zero");
    }

    function test_lockPool_only_owner() public {
        PoolKey memory ourKey = _keyWith(address(0x111), address(0x222));
        vm.prank(alice);
        vm.expectRevert(USluggHook.NotOwner.selector);
        hook.lockPool(ourKey);
    }

    function test_lockPool_is_one_shot() public {
        PoolKey memory ourKey      = _keyWith(address(0x111), address(0x222));
        PoolKey memory attackerKey = _keyWith(address(0xAAA), address(0xBBB));

        hook.lockPool(ourKey);

        // Owner cannot re-lock to a different pool — protects against late
        // owner compromise / mistake.
        vm.expectRevert(USluggHook.AlreadyLocked.selector);
        hook.lockPool(attackerKey);
    }

    // -------- helpers --------

    function _key() internal pure returns (PoolKey memory) {
        return _keyWith(address(0xCC0), address(0xCC1));
    }

    function _keyWith(address c0, address c1) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0:   Currency.wrap(c0),
            currency1:   Currency.wrap(c1),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });
    }

    function _afterSwap(bool zeroForOne, int256 amountSpecified, int128 amount0, int128 amount1)
        internal returns (bytes4 selector, int128 feeDelta)
    {
        return _afterSwapReturn(_key(), zeroForOne, amountSpecified, amount0, amount1);
    }

    function _afterSwapWithKey(PoolKey memory key, bool zeroForOne, int256 amountSpecified, int128 amount0, int128 amount1)
        internal
    {
        _afterSwapReturn(key, zeroForOne, amountSpecified, amount0, amount1);
    }

    function _afterSwapReturn(PoolKey memory key, bool zeroForOne, int256 amountSpecified, int128 amount0, int128 amount1)
        internal returns (bytes4 selector, int128 feeDelta)
    {
        SwapParams memory sp = SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   amountSpecified,
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(amount0, amount1);
        vm.prank(poolManager);
        (selector, feeDelta) = hook.afterSwap(address(this), key, sp, delta, "");
    }
}
