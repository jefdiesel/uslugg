// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}     from "forge-std/Test.sol";
import {USluggClaimed}      from "../src/USluggClaimed.sol";
import {USluggRenderer}     from "../src/USluggRenderer.sol";
import {USluggRuntime}      from "../src/USluggRuntime.sol";
import {IUSluggRenderer}    from "../src/IUSluggRenderer.sol";

/// @notice USluggClaimed tests. Trust model: only the immutable `uslugg404`
/// address may mint/burn/setRenderer/setRoyalty. Everything else is plain
/// minimal ERC-721 (transfer/approve) plus an EIP-2981 royalty cap of 10%.
contract USluggClaimedTest is Test {
    USluggClaimed   claimed;
    USluggRenderer  renderer;
    USluggRuntime   runtime;

    address parent  = address(this);   // constructor sets uslugg404 = msg.sender
    address alice   = address(0xA11CE);
    address bob     = address(0xB0B);
    address carol   = address(0xCAA01);
    address rando   = address(0xDEAD);

    function setUp() public {
        runtime  = new USluggRuntime();
        renderer = new USluggRenderer(address(runtime));
        claimed  = new USluggClaimed(parent, IUSluggRenderer(address(renderer)));
    }

    // -------- constructor guard --------

    function test_constructor_rejects_zero_parent() public {
        vm.expectRevert(USluggClaimed.Uslugg404Zero.selector);
        new USluggClaimed(address(0), IUSluggRenderer(address(renderer)));
    }

    // -------- access control: only USlugg404 (= parent) --------

    function test_only_parent_can_mint() public {
        vm.prank(rando);
        vm.expectRevert(USluggClaimed.OnlyUSlugg404.selector);
        claimed.mint(alice, bytes32(uint256(1)), 0);
    }

    function test_only_parent_can_burn() public {
        // First mint legitimately.
        uint256 id = claimed.mint(alice, bytes32(uint256(1)), 0);

        vm.prank(rando);
        vm.expectRevert(USluggClaimed.OnlyUSlugg404.selector);
        claimed.burn(id);
    }

    function test_only_parent_can_setRenderer() public {
        vm.prank(rando);
        vm.expectRevert(USluggClaimed.OnlyUSlugg404.selector);
        claimed.setRenderer(IUSluggRenderer(address(0xBEEF)));
    }

    function test_only_parent_can_setRoyalty() public {
        vm.prank(rando);
        vm.expectRevert(USluggClaimed.OnlyUSlugg404.selector);
        claimed.setRoyalty(rando, 500);
    }

    // -------- mint --------

    function test_mint_assigns_owner_balance_and_seed() public {
        bytes32 seed = bytes32(uint256(0xC0FFEE));
        uint256 origin404 = 7;

        uint256 id = claimed.mint(alice, seed, origin404);
        assertEq(id, 0, "first id == 0");
        assertEq(claimed.ownerOf(id),  alice, "owner");
        assertEq(claimed.balanceOf(alice), 1,  "balance");

        (bytes32 s, uint256 o, uint64 t) = claimed.claimed(id);
        assertEq(s, seed,                "seed");
        assertEq(o, origin404,           "origin");
        assertEq(uint256(t), block.timestamp, "timestamp");
    }

    function test_mint_increments_nextId_per_call() public {
        claimed.mint(alice, bytes32(uint256(1)), 0);
        uint256 id2 = claimed.mint(alice, bytes32(uint256(2)), 0);
        assertEq(id2, 1, "ids increment");
        assertEq(claimed.nextId(), 2);
    }

    function test_mint_to_zero_address_reverts() public {
        vm.expectRevert(USluggClaimed.InvalidRecipient.selector);
        claimed.mint(address(0), bytes32(uint256(1)), 0);
    }

    function test_mint_emits_Transfer_from_zero() public {
        vm.expectEmit(true, true, true, false, address(claimed));
        emit USluggClaimed.Transfer(address(0), alice, 0);
        claimed.mint(alice, bytes32(uint256(1)), 0);
    }

    // -------- burn --------

    function test_burn_clears_owner_seed_and_balance() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(0xCAFE)), 9);
        claimed.burn(id);

        assertEq(claimed.ownerOf(id),     address(0), "owner cleared");
        assertEq(claimed.balanceOf(alice), 0,         "balance decremented");

        (bytes32 s, uint256 o, uint64 t) = claimed.claimed(id);
        assertEq(s, bytes32(0));
        assertEq(o, 0);
        assertEq(t, 0);
    }

    function test_burn_nonexistent_reverts() public {
        vm.expectRevert(USluggClaimed.NotOwner.selector);
        claimed.burn(999);
    }

    function test_burn_emits_Transfer_to_zero() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(1)), 0);
        vm.expectEmit(true, true, true, false, address(claimed));
        emit USluggClaimed.Transfer(alice, address(0), id);
        claimed.burn(id);
    }

    // -------- royalty --------

    function test_setRoyalty_caps_at_1000_bps() public {
        claimed.setRoyalty(alice, 1000);              // 10% — at cap, allowed
        assertEq(claimed.royaltyBps(), 1000);

        vm.expectRevert(USluggClaimed.RoyaltyTooHigh.selector);
        claimed.setRoyalty(alice, 1001);
    }

    function test_royaltyInfo_math() public {
        claimed.setRoyalty(bob, 500);  // 5%
        (address recv, uint256 amt) = claimed.royaltyInfo(0, 100 ether);
        assertEq(recv, bob);
        assertEq(amt, 5 ether);
    }

    function test_royaltyInfo_zero_when_unset() public view {
        (address recv, uint256 amt) = claimed.royaltyInfo(0, 100 ether);
        assertEq(recv, address(0));
        assertEq(amt, 0);
    }

    // -------- transfer / approve --------

    function test_transferFrom_by_owner() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(1)), 0);

        vm.prank(alice);
        claimed.transferFrom(alice, bob, id);

        assertEq(claimed.ownerOf(id),     bob);
        assertEq(claimed.balanceOf(alice), 0);
        assertEq(claimed.balanceOf(bob),   1);
    }

    function test_transferFrom_unauthorized_reverts() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(1)), 0);

        vm.prank(rando);
        vm.expectRevert(USluggClaimed.NotAuthorized.selector);
        claimed.transferFrom(alice, bob, id);
    }

    function test_transferFrom_via_approval() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(1)), 0);

        vm.prank(alice);
        claimed.approve(carol, id);

        vm.prank(carol);
        claimed.transferFrom(alice, bob, id);
        assertEq(claimed.ownerOf(id), bob);

        // Approval should be cleared after transfer.
        assertEq(claimed.getApproved(id), address(0), "approval cleared");
    }

    function test_transferFrom_via_setApprovalForAll() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(1)), 0);

        vm.prank(alice);
        claimed.setApprovalForAll(carol, true);
        assertTrue(claimed.isApprovedForAll(alice, carol));

        vm.prank(carol);
        claimed.transferFrom(alice, bob, id);
        assertEq(claimed.ownerOf(id), bob);
    }

    function test_transferFrom_wrong_from_reverts() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(1)), 0);

        vm.prank(alice);
        vm.expectRevert(USluggClaimed.WrongFrom.selector);
        claimed.transferFrom(bob, carol, id);  // alice owns id, but `from`=bob
    }

    function test_transferFrom_to_zero_reverts() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(1)), 0);

        vm.prank(alice);
        vm.expectRevert(USluggClaimed.InvalidRecipient.selector);
        claimed.transferFrom(alice, address(0), id);
    }

    function test_approve_unauthorized_reverts() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(1)), 0);

        vm.prank(rando);
        vm.expectRevert(USluggClaimed.NotAuthorized.selector);
        claimed.approve(bob, id);
    }

    function test_safeTransferFrom_works_like_transferFrom() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(1)), 0);

        vm.prank(alice);
        claimed.safeTransferFrom(alice, bob, id);
        assertEq(claimed.ownerOf(id), bob);

        // Variant with data
        vm.prank(bob);
        claimed.safeTransferFrom(bob, carol, id, "data");
        assertEq(claimed.ownerOf(id), carol);
    }

    // -------- tokenURI --------

    function test_tokenURI_returns_renderer_output() public {
        uint256 id = claimed.mint(alice, bytes32(uint256(0xABCDEF)), 5);
        string memory uri = claimed.tokenURI(id);
        assertTrue(bytes(uri).length > 0, "non-empty tokenURI");
    }

    function test_tokenURI_nonexistent_reverts() public {
        vm.expectRevert(USluggClaimed.TokenDoesNotExist.selector);
        claimed.tokenURI(123);
    }

    // -------- ERC-165 --------

    function test_supportsInterface() public view {
        assertTrue(claimed.supportsInterface(0x01ffc9a7), "ERC-165");
        assertTrue(claimed.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(claimed.supportsInterface(0x5b5e139f), "ERC-721 Metadata");
        assertTrue(claimed.supportsInterface(0x2a55205a), "EIP-2981");
        assertFalse(claimed.supportsInterface(0xdeadbeef));
    }
}
