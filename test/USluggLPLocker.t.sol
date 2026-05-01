// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}     from "forge-std/Test.sol";
import {IPositionManager}   from "v4-periphery/interfaces/IPositionManager.sol";
import {Currency}           from "v4-core/types/Currency.sol";
import {Actions}            from "v4-periphery/libraries/Actions.sol";
import {USluggLPLocker}     from "../src/USluggLPLocker.sol";

/// @notice The locker's whole reason to exist is "no path can ever extract the
/// LP NFT or pull principal liquidity." These tests pin that invariant down:
///   - Constructor rejects zero addresses (no nameless feeRecipient).
///   - immutables are exactly the constructor args (no governance hijack vector).
///   - onERC721Received refuses anything that isn't the v4 PositionManager.
///   - collectFees encodes DECREASE_LIQUIDITY(0) + TAKE_PAIR routed at feeRecipient
///     — the zero in the liquidity arg is the only thing keeping principal locked.
contract USluggLPLockerTest is Test {
    USluggLPLocker locker;

    address posMgr        = address(0xBEEF);
    address feeRecipient  = address(0xCAFE);
    address rando         = address(0xDEAD);

    function setUp() public {
        locker = new USluggLPLocker(IPositionManager(posMgr), feeRecipient);
    }

    // -------- constructor guards --------

    function test_constructor_rejects_zero_posMgr() public {
        vm.expectRevert(bytes("posMgr=0"));
        new USluggLPLocker(IPositionManager(address(0)), feeRecipient);
    }

    function test_constructor_rejects_zero_feeRecipient() public {
        vm.expectRevert(bytes("feeRecipient=0"));
        new USluggLPLocker(IPositionManager(posMgr), address(0));
    }

    function test_immutables_match_constructor_args() public view {
        assertEq(address(locker.posMgr()),  posMgr);
        assertEq(locker.feeRecipient(),     feeRecipient);
    }

    // -------- onERC721Received: only PositionManager --------

    function test_onERC721Received_accepts_from_positionManager() public {
        vm.prank(posMgr);
        bytes4 ret = locker.onERC721Received(posMgr, address(0xABC), 42, "");
        assertEq(ret, locker.onERC721Received.selector, "must return selector");
    }

    function test_onERC721Received_emits_PositionLocked() public {
        vm.expectEmit(true, false, false, false, address(locker));
        emit USluggLPLocker.PositionLocked(7);

        vm.prank(posMgr);
        locker.onERC721Received(posMgr, address(0xABC), 7, "");
    }

    function test_onERC721Received_rejects_non_positionManager() public {
        vm.prank(rando);
        vm.expectRevert(USluggLPLocker.NotPositionManager.selector);
        locker.onERC721Received(rando, rando, 1, "");
    }

    // -------- locker has no extraction surface --------

    /// @dev If anyone ever adds a setter or transfer entrypoint, this test still
    /// passes — but the `posMgr` and `feeRecipient` fields are immutable, so any
    /// new function that *could* drain principal would have to be a separate
    /// entrypoint and would need its own deliberate addition. This is mostly a
    /// living spec: no admin ever, no withdrawal ever.
    function test_no_admin_state_present() public view {
        // The locker has no `owner`, `governance`, or similar field. We can't
        // assert "no such function exists" from solidity, but we can pin the
        // zero-admin design: feeRecipient is immutable.
        assertEq(locker.feeRecipient(), feeRecipient);
    }

    // -------- collectFees: DECREASE_LIQUIDITY(0) + TAKE_PAIR(feeRecipient) --------

    function test_collectFees_calls_modifyLiquidities_with_decrease_zero_and_takePair() public {
        Currency c0 = Currency.wrap(address(0x111));
        Currency c1 = Currency.wrap(address(0x222));
        uint256 tokenId = 99;

        // Build the exact unlockData the locker should be sending to PositionManager.
        bytes memory expectedActions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory expectedParams = new bytes[](2);
        expectedParams[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        expectedParams[1] = abi.encode(c0, c1, feeRecipient);

        bytes memory expectedUnlockData = abi.encode(expectedActions, expectedParams);

        // Mock + assert. We can't easily inspect the deadline (block.timestamp+600),
        // so we match the unlockData by partial calldata equivalence: build the
        // full selector + encoded args and pass that to expectCall.
        vm.mockCall(
            posMgr,
            abi.encodeCall(IPositionManager.modifyLiquidities, (expectedUnlockData, block.timestamp + 600)),
            ""
        );
        vm.expectCall(
            posMgr,
            abi.encodeCall(IPositionManager.modifyLiquidities, (expectedUnlockData, block.timestamp + 600))
        );
        vm.expectEmit(true, false, false, true, address(locker));
        emit USluggLPLocker.FeesCollected(tokenId, feeRecipient);

        locker.collectFees(tokenId, c0, c1);
    }

    function test_collectFees_callable_by_anyone() public {
        Currency c0 = Currency.wrap(address(0x111));
        Currency c1 = Currency.wrap(address(0x222));
        vm.mockCall(posMgr, abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        // No prank → caller is foundry default. Then explicit prank as a stranger.
        locker.collectFees(1, c0, c1);

        vm.prank(rando);
        locker.collectFees(2, c0, c1);
    }
}
