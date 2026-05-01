// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUSlugg404 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function tokensPerSlugg() external view returns (uint256);
}

/// @notice Testnet faucet for USlugg404. Holds an initial pile of USLUG and
/// drips a configurable amount to any caller, with cooldown.
///
/// On mainnet this is replaced by Uniswap v4 swap-mint — users buy USLUG to
/// get sluggs. On testnet, no LP exists, so the faucet hands out tokens.
///
/// The faucet has skipSluggs=true on the parent so receiving USLUG into the
/// faucet itself doesn't auto-mint NFTs (admin-set after deploy).
contract USluggFaucet {
    IUSlugg404 public immutable token;
    address public immutable owner;

    /// @dev Tokens (raw units, 3 decimals) per request. Default 5e3 = 5.000 USLUG → 5 sluggs.
    uint256 public dripAmount;
    /// @dev Min seconds between requests per address.
    uint256 public cooldown = 1 hours;

    mapping(address => uint256) public lastRequest;

    event Dripped(address indexed to, uint256 amount);
    event DripAmountSet(uint256 amount);
    event CooldownSet(uint256 seconds_);

    error NotOwner();
    error CooldownActive(uint256 nextAt);
    error FaucetEmpty();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IUSlugg404 _token, uint256 _dripAmount) {
        token = _token;
        owner = msg.sender;
        dripAmount = _dripAmount;
    }

    function setDripAmount(uint256 a) external onlyOwner { dripAmount = a; emit DripAmountSet(a); }
    function setCooldown(uint256 s) external onlyOwner   { cooldown = s; emit CooldownSet(s); }

    /// @notice Hand out `dripAmount` of USLUG to caller. Triggers NFT mints
    /// in the parent because caller doesn't have skipSluggs set.
    function drip() external {
        uint256 last = lastRequest[msg.sender];
        if (last != 0 && block.timestamp < last + cooldown) {
            revert CooldownActive(last + cooldown);
        }
        if (token.balanceOf(address(this)) < dripAmount) revert FaucetEmpty();
        // CEI: write state + log before the external transfer. Required for
        // any token whose transfer can re-enter; defense-in-depth here since
        // USlugg404._move never returns false but a future swap could.
        lastRequest[msg.sender] = block.timestamp;
        emit Dripped(msg.sender, dripAmount);
        require(token.transfer(msg.sender, dripAmount), "drip transfer failed");
    }

    /// @notice View — when can `who` request again? Returns 0 if never requested.
    function nextRequestAt(address who) external view returns (uint256) {
        uint256 last = lastRequest[who];
        if (last < 1) return 0;
        return last + cooldown;
    }
}
