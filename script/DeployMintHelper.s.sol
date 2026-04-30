// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {USluggMintHelper, IUSlugg404} from "../src/USluggMintHelper.sol";

interface ITokenAdmin {
    function transfer(address to, uint256 amount) external returns (bool);
    function setSkip(address a, bool v) external;
}

/// @notice Deploys USluggMintHelper and funds it from the deployer's USLUG balance.
///   TOKEN=0x... FUND_AMOUNT=8000 forge script script/DeployMintHelper.s.sol --broadcast
contract DeployMintHelper is Script {
    function run() external {
        address token = vm.envAddress("TOKEN");
        // Fund amount in WHOLE sluggs (helper multiplies by tokensPerSlugg)
        uint256 fundSluggs = vm.envOr("FUND_SLUGGS", uint256(8000));
        uint256 tokensPerSlugg = 1e3; // 3 decimals

        vm.startBroadcast();

        USluggMintHelper helper = new USluggMintHelper(IUSlugg404(token), tokensPerSlugg);
        ITokenAdmin(token).setSkip(address(helper), true);
        ITokenAdmin(token).transfer(address(helper), fundSluggs * tokensPerSlugg);

        vm.stopBroadcast();

        console2.log("USluggMintHelper:", address(helper));
        console2.log("Funded with", fundSluggs, "sluggs worth of USLUG");
    }
}
