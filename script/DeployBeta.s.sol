// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {USluggRuntime}    from "../src/USluggRuntime.sol";
import {USluggRenderer}   from "../src/USluggRenderer.sol";
import {USluggBeta}       from "../src/USluggBeta.sol";
import {IUSluggRenderer}  from "../src/IUSluggRenderer.sol";

/// @notice Lightweight deploy of just the renderer + beta token (public mint, no v4).
/// Use this for testnet where we want to verify the JS-animation tokenURI flow
/// in real wallets without spinning up a v4 pool.
///
///   forge script script/DeployBeta.s.sol --rpc-url $RPC --private-key $PK --broadcast --verify
contract DeployBeta is Script {
    function run() external {
        vm.startBroadcast();
        USluggRuntime  runtime  = new USluggRuntime();
        USluggRenderer renderer = new USluggRenderer(address(runtime));
        USluggBeta     token    = new USluggBeta();
        token.setRenderer(IUSluggRenderer(address(renderer)));
        vm.stopBroadcast();

        console2.log("== uSlugg beta deployed ==");
        console2.log("USluggRuntime: ", address(runtime));
        console2.log("USluggRenderer:", address(renderer));
        console2.log("USluggBeta:    ", address(token));
    }
}
