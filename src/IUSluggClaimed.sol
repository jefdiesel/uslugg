// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUSluggClaimed {
    function mint(address to, bytes32 seed, uint256 origin404Id) external returns (uint256);
    function burn(uint256 id) external;
    function ownerOf(uint256 id) external view returns (address);
    function claimed(uint256 id) external view returns (bytes32 seed, uint256 origin404Id, uint64 claimedAt);
}
