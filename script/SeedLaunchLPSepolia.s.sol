// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {IPoolManager}        from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}              from "v4-core/interfaces/IHooks.sol";
import {PoolKey}             from "v4-core/types/PoolKey.sol";
import {Currency}            from "v4-core/types/Currency.sol";
import {TickMath}            from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts}    from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IPositionManager}    from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions}             from "v4-periphery/libraries/Actions.sol";

interface IUSlugg404 {
    function approve(address, uint256) external returns (bool);
}
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
interface IERC721Min {
    function nextTokenId() external view returns (uint256);
}

/// @notice Seeds a single-sided USLUG launch curve on Sepolia for the testnet pool.
///
/// Sepolia v4 deploy registry (Uniswap):
///   PoolManager:     0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
///   PositionManager: 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4
///   Permit2:         0x000000000022D473030F116dDEE9F6B43aC78BA3
///   WETH:            0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
///
///   USLUG_TOKEN=0x... HOOK=0x... \
///   forge script script/SeedLaunchLPSepolia.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract SeedLaunchLPSepolia is Script {
    address constant PERMIT2          = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POOL_MANAGER     = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant WETH             = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    function run() external {
        address token = vm.envAddress("USLUG_TOKEN");
        address hook  = vm.envAddress("HOOK");

        require(token < WETH, "USLUG must be < WETH");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        vm.startBroadcast();

        // Approve USLUG → Permit2 → PositionManager
        IUSlugg404(token).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(token, POSITION_MANAGER, type(uint160).max, type(uint48).max);

        // Seed two single-sided USLUG positions covering a wide tick band
        //   Pool was initialized at tick 0. We add USLUG-only liquidity ABOVE the
        //   current tick (so users buying USLUG with ETH walk up the curve).
        //
        //   Position 1: ticks [0, 6000]    — main band, 500 USLUG  (100 ticks)
        //   Position 2: ticks [6000, 12000] — upper tail, 100 USLUG (100 ticks)
        //
        //   Tighter ranges so each tx fits Sepolia's 16.7M gas cap.
        //   Total seeded: 600 sluggs (6e5 raw). Plenty for testnet trading.
        uint256 t1 = _mintPosition(key, 0,    6000, 500 * 1e3);
        uint256 t2 = _mintPosition(key, 6000, 12000, 100 * 1e3);

        vm.stopBroadcast();

        console2.log("=== launch LP seeded ===");
        console2.log("position 1 tokenId:", t1);
        console2.log("position 2 tokenId:", t2);
        console2.log("total USLUG locked:  1000 (single-sided)");
        console2.log("");
        console2.log("Pool now has liquidity. The site can quote + swap end-to-end.");
    }

    function _mintPosition(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 usluggAmount
    ) internal returns (uint256 tokenId) {
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sqrtL, sqrtU, usluggAmount);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liq),
            uint128(usluggAmount + usluggAmount / 100),  // 1% slop on max input
            uint128(0),                                    // max1 = 0 (single-sided)
            msg.sender,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        tokenId = IERC721Min(POSITION_MANAGER).nextTokenId();
        IPositionManager(POSITION_MANAGER).modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 600
        );
    }
}
