// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISeedSource} from "./ISeedSource.sol";

/// @notice Stand-in for USluggHook on testnet (where there's no v4 pool).
///
/// Anyone can call `reroll()` to advance the seed — typically called by the
/// faucet's drip() flow upstream, or directly by users for variety. Production
/// uses USluggHook which re-rolls inside afterSwap.
contract MockSeedSource is ISeedSource {
    bytes32 public override currentSeed;
    uint64  public override swapCount;

    constructor() {
        currentSeed = keccak256(abi.encode(block.prevrandao, block.timestamp, address(this)));
    }

    function reroll() external {
        unchecked { swapCount++; }
        currentSeed = keccak256(abi.encode(currentSeed, swapCount, block.prevrandao, block.timestamp, msg.sender));
    }
}
