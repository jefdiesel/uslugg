// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks}            from "v4-core/libraries/Hooks.sol";
import {IPoolManager}     from "v4-core/interfaces/IPoolManager.sol";

import {USluggHook}       from "../src/USluggHook.sol";
import {USlugg404}        from "../src/USlugg404.sol";
import {USluggClaimed}    from "../src/USluggClaimed.sol";
import {USluggRenderer}   from "../src/USluggRenderer.sol";
import {USluggRuntime}    from "../src/USluggRuntime.sol";
import {IUSluggRenderer}  from "../src/IUSluggRenderer.sol";
import {IUSluggClaimed}   from "../src/IUSluggClaimed.sol";

/// @notice Full-stack deploy for the uSlugg launch.
///
/// Run:
///   POOL_MANAGER=<addr> \
///   forge script script/DeployUslugg.s.sol --rpc-url $RPC --private-key $PK --broadcast --verify
///
/// Env (all optional, defaults built in):
///   POOL_MANAGER     — v4 PoolManager (chain-id presets, mainnet/Base/etc.)
///   TREASURY         — initial supply recipient (defaults to deployer)
///   MAX_SLUGGS       — collection cap (default 10000)
///   TOKENS_PER_SLUGG — wei per Slugg (default 1e3 = 1.000 USLUG given decimals=3)
///   HOOK_OWNER       — final owner of USluggHook. REQUIRED on mainnet (multisig).
///                      If unset on chainid=1, deploy reverts.
///   CLAIM_FEE_WEI    — claim() ETH fee (default 0.001111 ether)
///   UNCLAIM_FEE_WEI  — unclaim() ETH fee (default 0.0069 ether)
contract DeployUslugg is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address deployer  = msg.sender;
        address treasury  = _envAddrOr("TREASURY", deployer);
        address poolMgr   = _envAddrOr("POOL_MANAGER", _defaultPoolManager(block.chainid));
        address hookOwner = _envAddrOr("HOOK_OWNER", deployer);
        require(poolMgr != address(0), "POOL_MANAGER not set and no default for chain");
        require(
            block.chainid != 1 || hookOwner != deployer,
            "HOOK_OWNER must be set (and != deployer) on mainnet"
        );

        uint256 maxSluggs      = _envUintOr("MAX_SLUGGS",      10_000);
        uint256 tokensPerSlugg = _envUintOr("TOKENS_PER_SLUGG", 1e3);  // 1.000 USLUG at decimals=3
        uint256 claimFeeWei    = _envUintOr("CLAIM_FEE_WEI",   0.001111 ether);
        uint256 unclaimFeeWei  = _envUintOr("UNCLAIM_FEE_WEI", 0.0069 ether);

        console2.log("== uSlugg deploy ==");
        console2.log("chainId:           ", block.chainid);
        console2.log("deployer/treasury: ", deployer);
        console2.log("treasury:          ", treasury);
        console2.log("poolManager:       ", poolMgr);
        console2.log("hookOwner (final): ", hookOwner);
        console2.log("maxSluggs:         ", maxSluggs);
        console2.log("tokensPerSlugg:    ", tokensPerSlugg);

        // 1. Mine hook salt (afterSwap + afterSwapReturnsDelta = 0x44)
        uint160 wantFlags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory hookCode = type(USluggHook).creationCode;
        bytes memory hookArgs = abi.encode(IPoolManager(poolMgr));
        (address predicted, bytes32 salt, uint256 iters) =
            _mineSalt(CREATE2_DEPLOYER, wantFlags, hookCode, hookArgs);
        console2.log("hook (predicted):  ", predicted);
        console2.log("salt iterations:   ", iters);

        // 2. Broadcast deploys
        vm.startBroadcast();

        USluggRuntime  runtime  = new USluggRuntime();
        USluggRenderer renderer = new USluggRenderer(address(runtime));
        USluggHook     hook     = new USluggHook{salt: salt}(IPoolManager(poolMgr));
        require(address(hook) == predicted, "hook addr mismatch");

        USlugg404 token = new USlugg404(hook, payable(treasury), maxSluggs, tokensPerSlugg);

        // Address ordering: USLUG must be < WETH so it's token0 in the USLUG/WETH pool.
        if (block.chainid == 1) {
            require(address(token) < 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                "USLUG >= WETH (mainnet) - re-roll deployer nonce");
        } else if (block.chainid == 11155111) {
            require(address(token) < 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
                "USLUG >= WETH (Sepolia) - re-roll deployer nonce");
        }

        token.setRenderer(IUSluggRenderer(address(renderer)));
        token.setSkip(poolMgr, true);  // PoolManager holds liquidity, exempt from minting NFTs
        token.setClaimFee(claimFeeWei);
        token.setUnclaimFee(unclaimFeeWei);

        USluggClaimed claimedNft = new USluggClaimed(address(token), IUSluggRenderer(address(renderer)));
        token.setClaimedNft(IUSluggClaimed(address(claimedNft)));

        // Hand off hook ownership last (no-op if HOOK_OWNER unset / == deployer)
        if (hookOwner != deployer) {
            hook.transferOwnership(hookOwner);
            console2.log("Hook ownership transferred to:", hookOwner);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("== addresses ==");
        console2.log("USluggRuntime:  ", address(runtime));
        console2.log("USluggRenderer: ", address(renderer));
        console2.log("USluggHook:     ", address(hook));
        console2.log("USlugg404:      ", address(token));
        console2.log("USluggClaimed:  ", address(claimedNft));
        console2.log("");
        console2.log("Treasury holds", token.totalSupply(), "raw units of USLUG");
        console2.log("                = ", token.totalSupply() / tokensPerSlugg, "whole sluggs (NFTs)");
        console2.log("");
        console2.log("== Next steps (manual via Uniswap UI or follow-up script) ==");
        console2.log("1. Initialize v4 pool: USLUG / WETH, 0.3% fee, hook=", address(hook));
        console2.log("2. Add launch LP via SeedLaunchLPMainnet (or SeedLaunchLP for testnet)");
        console2.log("3. Update site SWAP_CONTRACT, ROUTER, etc. to mainnet addresses");
    }

    // -------- helpers --------

    function _envAddrOr(string memory key, address dflt) internal view returns (address) {
        try vm.envAddress(key) returns (address v) { return v; } catch { return dflt; }
    }

    function _envUintOr(string memory key, uint256 dflt) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) { return v; } catch { return dflt; }
    }

    function _defaultPoolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == 1)        return 0x000000000004444c5dc75cB358380D2e3dE08A90;
        if (chainId == 8453)     return 0x498581fF718922c3f8e6A244956aF099B2652b2b;
        if (chainId == 42161)    return 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        if (chainId == 10)       return 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
        if (chainId == 137)      return 0x67366782805870060151383F4BbFF9daB53e5cD6;
        if (chainId == 11155111) return 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        if (chainId == 84532)    return 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        return address(0);
    }

    function _mineSalt(address deployer, uint160 flags, bytes memory code, bytes memory args)
        internal pure returns (address addr, bytes32 salt, uint256 iters)
    {
        bytes32 codeHash = keccak256(abi.encodePacked(code, args));
        for (uint256 i = 0; i < 1_000_000; ++i) {
            salt = bytes32(i);
            addr = address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)
            ))));
            if (uint160(addr) & uint160(0x3fff) == flags) {
                iters = i;
                return (addr, salt, iters);
            }
        }
        revert("HookMiner: not found");
    }
}
