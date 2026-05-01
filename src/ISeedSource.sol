// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISeedSource {
    function currentSeed() external view returns (bytes32);
    function swapCount() external view returns (uint64);
    /// @notice Transient flag (EIP-1153): true iff afterSwap fired on the
    /// locked pool earlier in this same tx. Used by USlugg404._move to gate
    /// receive-side auto-mints — non-pool transfers must NOT auto-mint stale
    /// seed sluggs.
    function swapFiredThisTx() external view returns (bool);
}
