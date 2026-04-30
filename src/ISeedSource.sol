// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISeedSource {
    function currentSeed() external view returns (bytes32);
    function swapCount() external view returns (uint64);
}
