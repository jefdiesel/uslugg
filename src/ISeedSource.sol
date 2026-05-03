// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for the v4 hook, surfaced to USlugg404.
///         Post-hardening (no-prevrandao redesign), the hook is no longer the
///         randomness source — randomness is deferred to a future-block
///         blockhash at reveal time, which is unpredictable to builders.
///         The hook's only job toward USlugg404 is the transient
///         swap-fired flag that gates receive-side auto-minting.
interface ISeedSource {
    /// @notice Transient flag (EIP-1153): true iff afterSwap fired on the
    /// locked pool earlier in this same tx. USlugg404._move uses this to
    /// gate receive-side auto-mints — non-pool transfers MUST NOT auto-mint.
    function swapFiredThisTx() external view returns (bool);
}
