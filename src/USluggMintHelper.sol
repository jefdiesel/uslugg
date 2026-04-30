// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUSlugg404 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Open-amount testnet mint helper. No cooldown. User picks count.
/// Caps per-tx at 100 sluggs to keep gas sane (404 _move loop).
///
/// Production (mainnet) replaces this with a v4 swap UI — users buy USLUG
/// from the pool and the hook mints NFTs on the swap-receive path.
contract USluggMintHelper {
    IUSlugg404 public immutable token;
    /// @dev Amount of raw USLUG given per "1 slugg" requested (3 decimals → 1e3).
    uint256 public immutable tokensPerSlugg;
    uint256 public constant MAX_PER_TX = 100;

    event Minted(address indexed to, uint256 count);

    error BadCount();
    error Empty();

    constructor(IUSlugg404 _token, uint256 _tokensPerSlugg) {
        token = _token;
        tokensPerSlugg = _tokensPerSlugg;
    }

    function mint(uint256 count) external {
        if (count == 0 || count > MAX_PER_TX) revert BadCount();
        uint256 amount = count * tokensPerSlugg;
        if (token.balanceOf(address(this)) < amount) revert Empty();
        token.transfer(msg.sender, amount);
        emit Minted(msg.sender, count);
    }
}
