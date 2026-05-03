// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISeedSource} from "./ISeedSource.sol";

/// @notice Stand-in for USluggHook on testnet (where there's no v4 pool).
///
/// Post-no-prevrandao redesign, ISeedSource is just `swapFiredThisTx()`. The
/// mock returns true unconditionally so testnet flows that don't go through
/// a v4 pool still get auto-mints (e.g. faucet drips, direct transfers).
/// Mainnet's USluggHook backs this with EIP-1153 transient storage gated
/// on the locked pool's afterSwap.
contract MockSeedSource is ISeedSource {
    function swapFiredThisTx() external pure override returns (bool) {
        return true;
    }
}
