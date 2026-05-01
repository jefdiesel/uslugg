// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test}                           from "forge-std/Test.sol";
import {USluggHook}                     from "../src/USluggHook.sol";
import {USluggLPLocker}                 from "../src/USluggLPLocker.sol";
import {USluggClaimed}                  from "../src/USluggClaimed.sol";
import {USluggRenderer}                 from "../src/USluggRenderer.sol";
import {USluggRuntime}                  from "../src/USluggRuntime.sol";
import {IPoolManager}                   from "v4-core/interfaces/IPoolManager.sol";
import {IPositionManager}               from "v4-periphery/interfaces/IPositionManager.sol";
import {IUSluggRenderer}                from "../src/IUSluggRenderer.sol";
import {Currency}                       from "v4-core/types/Currency.sol";

/// @notice Halmos symbolic proofs. Each check_* function is verified by SMT
/// solver — inputs are symbolic, so any reachable failure is found with
/// mathematical certainty (modulo solver bounds and depth limits). Run with:
///
///   halmos --function check_ --match-contract Symbolic
///
/// Halmos does not support `vm.expectRevert(selector)`; we use try/catch and
/// assert(false)-on-success to encode "must revert" expectations.
contract Symbolic is Test {
    USluggHook      hook;
    USluggLPLocker  locker;
    USluggClaimed   claimed;
    USluggRenderer  renderer;
    USluggRuntime   runtime;

    address constant POOL_MANAGER = address(0xCAFE);
    address constant POS_MGR      = address(0xDEAD);
    address constant FEE_RECIP    = address(0xBEEF);
    address constant USLUGG404    = address(0xABCD);

    function setUp() public {
        hook     = new USluggHook(IPoolManager(POOL_MANAGER));
        locker   = new USluggLPLocker(IPositionManager(POS_MGR), FEE_RECIP);
        runtime  = new USluggRuntime();
        renderer = new USluggRenderer(address(runtime));
        claimed  = new USluggClaimed(USLUGG404, IUSluggRenderer(address(renderer)));
    }

    // -------- USluggHook --------

    /// @dev Halmos verifies for ALL uint16: setFeeBps reverts iff bps > 100.
    function check_setFeeBps_caps_at_100(uint16 bps) public {
        try hook.setFeeBps(bps) {
            // Success: must imply bps was within bound.
            assert(bps <= 100);
            assert(hook.feeBps() == bps);
        } catch {
            // Revert: must imply bps > 100.
            assert(bps > 100);
        }
    }

    /// @dev For ALL non-owner senders, setFeeBps reverts.
    function check_setFeeBps_only_owner(address caller, uint16 bps) public {
        vm.assume(caller != address(this));     // address(this) is the owner
        vm.assume(bps <= 100);                   // exclude the bps-cap path
        vm.prank(caller);
        try hook.setFeeBps(bps) {
            assert(false);                        // should not reach
        } catch {}
    }

    /// @dev For ALL non-owner senders, transferOwnership reverts.
    function check_transferOwnership_only_owner(address caller, address proposed) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        try hook.transferOwnership(proposed) {
            assert(false);
        } catch {}
    }

    /// @dev Propose to fixed `proposed`, then ANY non-pending caller fails accept.
    function check_acceptOwnership_only_pending(address proposed, address caller) public {
        vm.assume(proposed != address(0));
        vm.assume(caller != proposed);
        hook.transferOwnership(proposed);
        vm.prank(caller);
        try hook.acceptOwnership() {
            assert(false);
        } catch {}
    }

    /// @dev withdrawFees(_, 0, _) always reverts.
    function check_withdrawFees_rejects_zero_to(address currency, uint256 amount) public {
        try hook.withdrawFees(Currency.wrap(currency), address(0), amount) {
            assert(false);
        } catch {}
    }

    // -------- USluggLPLocker --------

    /// @dev For ALL non-PositionManager callers, onERC721Received reverts.
    function check_locker_onERC721Received_only_posMgr(address caller, uint256 tokenId) public {
        vm.assume(caller != POS_MGR);
        vm.prank(caller);
        try locker.onERC721Received(caller, address(0), tokenId, "") {
            assert(false);
        } catch {}
    }

    // -------- USluggClaimed --------

    /// @dev For ALL non-parent senders, mint reverts.
    function check_claimed_mint_only_parent(address caller, address to, bytes32 seed, uint256 origin) public {
        vm.assume(caller != USLUGG404);
        vm.assume(to != address(0));    // bypass the InvalidRecipient path
        vm.prank(caller);
        try claimed.mint(to, seed, origin) returns (uint256) {
            assert(false);
        } catch {}
    }

    /// @dev For ALL non-parent senders, burn reverts.
    function check_claimed_burn_only_parent(address caller, uint256 id) public {
        vm.assume(caller != USLUGG404);
        vm.prank(caller);
        try claimed.burn(id) {
            assert(false);
        } catch {}
    }

    /// @dev Halmos verifies for ALL uint96: setRoyalty reverts iff bps > 1000.
    function check_claimed_setRoyalty_caps_at_1000(address recipient, uint96 bps) public {
        vm.prank(USLUGG404);
        try claimed.setRoyalty(recipient, bps) {
            assert(bps <= 1000);
            assert(claimed.royaltyBps() == bps);
            assert(claimed.royaltyRecipient() == recipient);
        } catch {
            assert(bps > 1000);
        }
    }

    /// @dev mint to address(0) always reverts (even for the parent caller).
    function check_claimed_mint_rejects_zero_recipient(bytes32 seed, uint256 origin) public {
        vm.prank(USLUGG404);
        try claimed.mint(address(0), seed, origin) returns (uint256) {
            assert(false);
        } catch {}
    }
}
