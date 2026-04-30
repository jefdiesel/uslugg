// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUSluggRenderer {
    function tokenURI(uint256 id, bytes32 key) external view returns (string memory);
}
