// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUSluggRenderer} from "./IUSluggRenderer.sol";

/// @notice Mint/burn/lookup surface that USlugg404 calls during wrap/unwrap.
interface IUSluggClaimed {
    function mint(address to, bytes32 seed, uint256 origin404Id) external returns (uint256);
    function burn(uint256 id) external;
    function ownerOf(uint256 id) external view returns (address);
    function claimed(uint256 id) external view returns (bytes32 seed, uint256 origin404Id, uint64 claimedAt);
}

/// @notice Admin proxy surface — USlugg404's owner forwards renderer/royalty
/// updates here so the parent's governance applies to the standalone ERC-721.
/// Split from IUSluggClaimed so consumers needing only the mint/burn surface
/// don't import royalty machinery.
interface IUSluggClaimedAdmin {
    function setRenderer(IUSluggRenderer r) external;
    function setRoyalty(address recipient, uint96 bps) external;
}
