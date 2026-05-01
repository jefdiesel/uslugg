// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}                 from "forge-std/Test.sol";
import {IPoolManager}                   from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}                         from "v4-core/interfaces/IHooks.sol";
import {PoolKey}                        from "v4-core/types/PoolKey.sol";
import {Currency}                       from "v4-core/types/Currency.sol";
import {USluggSwap, IWETH9, IERC20Min}  from "../src/USluggSwap.sol";

/// @notice USluggSwap perimeter tests. The full happy-path buy/sell flow runs
/// against a real v4 PoolManager and is exercised end-to-end by the testnet
/// site (Sepolia). Here we cover the synchronous guards: constructor ordering,
/// deadlines, msg.value floor, and the unlockCallback-only-PoolManager check.
contract USluggSwapTest is Test {
    USluggSwap swap;

    address poolManager = address(0xCAFE);
    // Token addresses chosen so address(slugg) < address(weth).
    address slugg       = address(0x0000000000000000000000000000000000000111);
    address weth        = address(0x0000000000000000000000000000000000000222);

    address alice = address(0xA11CE);

    function setUp() public {
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(slugg),
            currency1:   Currency.wrap(weth),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });
        swap = new USluggSwap(
            IPoolManager(poolManager),
            IWETH9(weth),
            IERC20Min(slugg),
            key
        );
    }

    // -------- constructor ordering --------

    function test_constructor_rejects_swapped_token_order() public {
        // weth address < slugg address violates the "USLUG must be token0" rule.
        address lo = address(0x0000000000000000000000000000000000000001);
        address hi = address(0x0000000000000000000000000000000000000002);
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(hi),  // <-- intentionally wrong
            currency1:   Currency.wrap(lo),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });
        vm.expectRevert(bytes("USLUG must be token0"));
        new USluggSwap(
            IPoolManager(poolManager),
            IWETH9(lo),
            IERC20Min(hi),  // slugg > weth — fails check
            key
        );
    }

    // -------- buy: deadline + msg.value --------

    function test_buy_reverts_after_deadline() public {
        vm.warp(1000);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(USluggSwap.Expired.selector);
        swap.buy{value: 0.5 ether}(1_000, 0.5 ether, /* deadline */ 999);
    }

    function test_buy_reverts_when_msg_value_below_maxEthIn() public {
        vm.warp(100);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("msg.value < maxEthIn"));
        swap.buy{value: 0.4 ether}(
            /* usluggOut */ 1_000,
            /* maxEthIn  */ 0.5 ether,
            /* deadline  */ block.timestamp + 60
        );
    }

    // -------- sell: deadline --------

    function test_sell_reverts_after_deadline() public {
        vm.warp(2_000);
        vm.prank(alice);
        vm.expectRevert(USluggSwap.Expired.selector);
        swap.sell(1_000, 0.001 ether, /* deadline */ 1_999);
    }

    // -------- unlockCallback: only PoolManager --------

    function test_unlockCallback_rejects_non_pool_manager() public {
        // Build a CB that would otherwise be valid; the auth check fires first.
        bytes memory raw = abi.encode(
            USluggSwap.CB({sender: alice, isBuy: true, amountSpec: 1_000, limit: 1 ether})
        );

        vm.prank(alice);
        vm.expectRevert(USluggSwap.WrongCallback.selector);
        swap.unlockCallback(raw);
    }

    // -------- receive() --------

    function test_receive_accepts_eth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(swap).call{value: 0.1 ether}("");
        assertTrue(ok, "receive() must accept");
        assertEq(address(swap).balance, 0.1 ether);
    }
}

