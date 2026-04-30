// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockSeedSource}   from "../src/MockSeedSource.sol";
import {USluggRuntime}    from "../src/USluggRuntime.sol";
import {USluggRenderer}   from "../src/USluggRenderer.sol";
import {USlugg404}        from "../src/USlugg404.sol";
import {USluggClaimed}    from "../src/USluggClaimed.sol";
import {USluggFaucet, IUSlugg404} from "../src/USluggFaucet.sol";
import {ISeedSource}      from "../src/ISeedSource.sol";
import {IUSluggRenderer}  from "../src/IUSluggRenderer.sol";
import {IUSluggClaimed}   from "../src/IUSluggClaimed.sol";

/// @notice Testnet deploy: full 404 + claim flow without v4 pool.
///   - MockSeedSource replaces USluggHook (no PoolManager on testnet)
///   - USluggFaucet hands out free USLUG so users can mint
///
///   forge script script/DeployTestnet.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract DeployTestnet is Script {
    function run() external {
        address deployer = msg.sender;

        vm.startBroadcast();

        MockSeedSource seedSrc = new MockSeedSource();
        USluggRuntime  runtime = new USluggRuntime();
        USluggRenderer renderer = new USluggRenderer(address(runtime));

        // 10k slugg cap, 3 decimals (1e3 raw per slugg)
        uint256 maxSluggs = 10_000;
        uint256 tokensPerSlugg = 1e3;
        USlugg404 token = new USlugg404(
            ISeedSource(address(seedSrc)),
            payable(deployer),
            maxSluggs,
            tokensPerSlugg
        );
        token.setRenderer(IUSluggRenderer(address(renderer)));
        token.setClaimFee(0.0001 ether);   // testnet-cheap: $0.30
        token.setUnclaimFee(0.0005 ether); // testnet-cheap: $1.50

        USluggClaimed claimed = new USluggClaimed(address(token), IUSluggRenderer(address(renderer)));
        token.setClaimedNft(IUSluggClaimed(address(claimed)));

        // Faucet: each drip = 5.000 USLUG = 5 sluggs
        USluggFaucet faucet = new USluggFaucet(IUSlugg404(address(token)), 5e3);
        token.setSkip(address(faucet), true);  // faucet doesn't auto-mint NFTs to itself

        // Fund the faucet with 80% of supply (8000 sluggs worth = 8e6 raw)
        token.transfer(address(faucet), 8_000 * tokensPerSlugg);
        // Remaining 20% stays with treasury (deployer) for ops/airdrops
        // (deployer has skipSluggs=true so no NFTs minted to it either)

        vm.stopBroadcast();

        console2.log("== uSlugg testnet stack ==");
        console2.log("MockSeedSource:", address(seedSrc));
        console2.log("USluggRuntime: ", address(runtime));
        console2.log("USluggRenderer:", address(renderer));
        console2.log("USlugg404:     ", address(token));
        console2.log("USluggClaimed: ", address(claimed));
        console2.log("USluggFaucet:  ", address(faucet));
        console2.log("");
        console2.log("Treasury (deployer):       ", deployer);
        console2.log("Faucet USLUG balance:      ", token.balanceOf(address(faucet)));
        console2.log("Faucet drip per request:   ", faucet.dripAmount());
        console2.log("");
        console2.log("Test: cast send <faucet> 'drip()' --rpc-url $RPC --private-key $PK");
    }
}
