// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}                 from "forge-std/Test.sol";
import {USluggBeta, IUSluggRenderer}    from "../src/USluggBeta.sol";

/// @notice USluggBeta is testnet-only, but its admin handoff is the only
/// governance hook (sets the renderer). Two-step transfer prevents a typo
/// from permanently bricking renderer upgrades.
contract USluggBetaTest is Test {
    USluggBeta beta;
    address admin;
    address newAdmin = address(0xBEEF);
    address rando    = address(0xDEAD);

    function setUp() public {
        admin = address(this);
        beta = new USluggBeta();
    }

    function test_initial_admin_is_deployer() public view {
        assertEq(beta.admin(), admin);
        assertEq(beta.pendingAdmin(), address(0));
    }

    function test_only_admin_can_propose() public {
        vm.prank(rando);
        vm.expectRevert(USluggBeta.NotAdmin.selector);
        beta.transferAdmin(newAdmin);
    }

    function test_transferAdmin_does_not_take_effect_until_accept() public {
        beta.transferAdmin(newAdmin);
        assertEq(beta.admin(), admin, "admin unchanged");
        assertEq(beta.pendingAdmin(), newAdmin, "pending set");

        // Old admin still functions.
        beta.setRenderer(IUSluggRenderer(address(0xAA)));

        // New admin is rejected until accept.
        vm.prank(newAdmin);
        vm.expectRevert(USluggBeta.NotAdmin.selector);
        beta.setRenderer(IUSluggRenderer(address(0xBB)));
    }

    function test_acceptAdmin_finalizes_handoff() public {
        beta.transferAdmin(newAdmin);

        vm.prank(newAdmin);
        beta.acceptAdmin();

        assertEq(beta.admin(),       newAdmin, "moved");
        assertEq(beta.pendingAdmin(), address(0), "cleared");

        // Old admin loses control.
        vm.expectRevert(USluggBeta.NotAdmin.selector);
        beta.setRenderer(IUSluggRenderer(address(0xCC)));

        // New admin operates.
        vm.prank(newAdmin);
        beta.setRenderer(IUSluggRenderer(address(0xDD)));
    }

    function test_only_pending_admin_can_accept() public {
        beta.transferAdmin(newAdmin);
        vm.prank(rando);
        vm.expectRevert(USluggBeta.NotPendingAdmin.selector);
        beta.acceptAdmin();
    }

    function test_transfer_to_zero_cancels_pending() public {
        beta.transferAdmin(newAdmin);
        beta.transferAdmin(address(0));
        assertEq(beta.pendingAdmin(), address(0));

        vm.prank(newAdmin);
        vm.expectRevert(USluggBeta.NotPendingAdmin.selector);
        beta.acceptAdmin();
    }
}
