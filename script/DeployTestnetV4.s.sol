// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {Hooks}               from "v4-core/libraries/Hooks.sol";
import {IPoolManager}        from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}             from "v4-core/types/PoolKey.sol";
import {Currency}            from "v4-core/types/Currency.sol";
import {IHooks}              from "v4-core/interfaces/IHooks.sol";
import {TickMath}            from "v4-core/libraries/TickMath.sol";

import {USluggHook}          from "../src/USluggHook.sol";
import {USluggRuntime}       from "../src/USluggRuntime.sol";
import {USluggRenderer}      from "../src/USluggRenderer.sol";
import {USlugg404}           from "../src/USlugg404.sol";
import {USluggClaimed}       from "../src/USluggClaimed.sol";
import {USluggSwap, IERC20Min, IWETH9} from "../src/USluggSwap.sol";
import {ISeedSource}         from "../src/ISeedSource.sol";
import {IUSluggRenderer}     from "../src/IUSluggRenderer.sol";
import {IUSluggClaimed}      from "../src/IUSluggClaimed.sol";

/// @notice Real v4 testnet stack: hook + pool + LP + swap router. No faucet.
///
///   POOL_MANAGER=0xE03A... WETH=0xfFf9... \
///   forge script script/DeployTestnetV4.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract DeployTestnetV4 is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address deployer = msg.sender;
        address poolMgr  = vm.envOr("POOL_MANAGER", address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543)); // sepolia v4 PM
        address weth     = vm.envOr("WETH",         address(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14)); // sepolia WETH

        // Mine hook salt for afterSwap + RETURNS_DELTA = 0x44
        uint160 wantFlags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory hookCode = type(USluggHook).creationCode;
        bytes memory hookArgs = abi.encode(IPoolManager(poolMgr));
        (address predicted, bytes32 salt,) = _mineSalt(CREATE2_DEPLOYER, wantFlags, hookCode, hookArgs);

        vm.startBroadcast();

        // 1. Hook (CREATE2 to get correct flag bits)
        USluggHook hook = new USluggHook{salt: salt}(IPoolManager(poolMgr));
        require(address(hook) == predicted, "hook addr mismatch");

        // 2. Renderer chain
        USluggRuntime  runtime  = new USluggRuntime();
        USluggRenderer renderer = new USluggRenderer(address(runtime));

        // 3. 404 token (treasury = deployer; deployer must end up with USLUG < WETH for token0)
        USlugg404 token = new USlugg404(
            ISeedSource(address(hook)),
            payable(deployer),
            10_000,
            1e3
        );
        require(address(token) < weth, "USLUG must be < WETH (re-roll deployer nonce)");
        token.setRenderer(IUSluggRenderer(address(renderer)));
        token.setClaimFee(0.0001 ether);
        token.setUnclaimFee(0.0005 ether);

        USluggClaimed claimed = new USluggClaimed(address(token), IUSluggRenderer(address(renderer)));
        token.setClaimedNft(IUSluggClaimed(address(claimed)));

        // 4. Pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token)),
            currency1: Currency.wrap(weth),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // 5. Init pool at price = 1 USLUG / 0.0001 ETH  (testnet starting price)
        // sqrtPriceX96 = sqrt(1/(0.0001 * 1e15)) << 96   ← USLUG has 3 decimals (1e3 raw = 1.000), WETH has 18.
        // For 1 USLUG = 0.0001 WETH:
        //   ratio_token1_per_token0 = 0.0001e18 / 1e3 = 1e11
        //   sqrtPriceX96 = sqrt(1e11) * 2^96 = 316227 * 2^96
        // Use TickMath: tick = log_1.0001(1e11) ≈ 253399
        //
        // For simpler launch: use tick = 0 (price = 1) and rely on the LP curve
        // to set effective price via tick range.
        IPoolManager(poolMgr).initialize(key, TickMath.getSqrtPriceAtTick(0));

        // 6. Swap router (so the page can use buy()/sell() instead of UniversalRouter)
        USluggSwap swap = new USluggSwap(IPoolManager(poolMgr), IWETH9(weth), IERC20Min(address(token)), key);
        token.setSkip(address(swap), true);  // swap router doesn't auto-mint NFTs to itself

        vm.stopBroadcast();

        console2.log("== uSlugg testnet v4 stack ==");
        console2.log("USluggHook:    ", address(hook));
        console2.log("USluggRuntime: ", address(runtime));
        console2.log("USluggRenderer:", address(renderer));
        console2.log("USlugg404:     ", address(token));
        console2.log("USluggClaimed: ", address(claimed));
        console2.log("USluggSwap:    ", address(swap));
        console2.log("Pool initialized at tick 0. Feed liquidity via SeedLaunchLP next.");
    }

    function _mineSalt(address d, uint160 flags, bytes memory code, bytes memory args)
        internal pure returns (address addr, bytes32 salt, uint256 iters)
    {
        bytes32 codeHash = keccak256(abi.encodePacked(code, args));
        for (uint256 i = 0; i < 1_000_000; ++i) {
            salt = bytes32(i);
            addr = address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xff), d, salt, codeHash)
            ))));
            if (uint160(addr) & uint160(0x3fff) == flags) { iters = i; return (addr, salt, iters); }
        }
        revert("salt not found");
    }
}
