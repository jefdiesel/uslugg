// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {USluggRuntime}    from "../src/USluggRuntime.sol";
import {USluggRenderer}   from "../src/USluggRenderer.sol";
import {IUSluggRenderer}  from "../src/IUSluggRenderer.sol";

interface IUSluggBetaSet {
    function setRenderer(IUSluggRenderer r) external;
}

/// @notice Redeploy USluggRuntime + USluggRenderer with new art rules,
/// then rewire an existing USluggBeta (or USlugg404) to use them.
///
///   TOKEN=0x... forge script script/UpdateRuntime.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract UpdateRuntime is Script {
    function run() external {
        address token = vm.envAddress("TOKEN");

        vm.startBroadcast();
        USluggRuntime  runtime  = new USluggRuntime();
        USluggRenderer renderer = new USluggRenderer(address(runtime));
        IUSluggBetaSet(token).setRenderer(IUSluggRenderer(address(renderer)));
        vm.stopBroadcast();

        console2.log("new runtime:  ", address(runtime));
        console2.log("new renderer: ", address(renderer));
        console2.log("rewired token:", token);
    }
}
