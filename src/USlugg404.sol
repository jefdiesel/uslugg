// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISeedSource}      from "./ISeedSource.sol";
import {IUSluggRenderer}  from "./IUSluggRenderer.sol";
import {IUSluggClaimed}   from "./IUSluggClaimed.sol";

interface IUSluggClaimedRendererSet {
    function setRenderer(IUSluggRenderer r) external;
}

/// @notice Hybrid ERC-20 + Slugg NFT, with ERC-721 visibility events so wallets
/// and explorers auto-detect the NFTs without an explicit claim.
///
/// Holding 1.000 USLUG token = owning 1 Slugg NFT (joined at the hip). Selling
/// burns your NFT; the buyer gets a freshly-minted one with a new seed (so a
/// token unit cycling through 3 owners has been 3 different sluggs).
///
/// You can OPTIONALLY `claim(id)` to lift a specific Slugg out into a
/// standalone USluggClaimed ERC-721 (separately tradeable on OpenSea, etc.).
/// claim() charges a fee in ETH that goes to the treasury.
///
/// Decimals: 3. Smallest unit = 0.001 USLUG (1 raw). Mint threshold = 1.000 USLUG (1e3 raw).
/// People can hold fractional USLUG without minting an NFT — collectible above 1.0.
contract USlugg404 {
    string  public constant name     = "uSlugg";
    string  public constant symbol   = "USLUG";
    uint8   public constant decimals = 3;

    uint256 public immutable maxSluggs;
    uint256 public immutable tokensPerSlugg;
    uint256 public immutable totalSupply;

    struct Slugg {
        bytes32 seed;
        address originalMinter;
        uint64  mintedAtSwap;
    }

    // ERC-20 state
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // NFT state
    mapping(uint256 => Slugg)     public sluggs;
    mapping(uint256 => address)   public ownerOf;
    mapping(address => uint256[]) internal _inventory;
    mapping(address => bool)      public skipSluggs;

    uint256 public nextSluggId;
    address public owner;
    address payable public treasury;
    /// @dev Claim fee in ETH (wei). Sent to treasury when a holder calls claim().
    uint256 public claimFeeWei;
    /// @dev Unclaim fee in ETH (wei). Discourages tight round-trip wrapping.
    uint256 public unclaimFeeWei;

    ISeedSource public seed;
    IUSluggRenderer public renderer;
    IUSluggClaimed  public claimedNft;

    // -------- events --------

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    // ERC-721 visibility (separate event because Solidity disallows event overload)
    event Transfer721(address indexed from, address indexed to, uint256 indexed id);

    event SluggMinted(uint256 indexed id, address indexed to, bytes32 seed);
    event SluggBurned(uint256 indexed id, address indexed from);
    event SeedSourceSet(address indexed seed);
    event SkipSet(address indexed account, bool skipped);
    event RendererSet(address indexed renderer);
    event ClaimedNftSet(address indexed claimedNft);
    event TreasurySet(address indexed treasury);
    event ClaimFeeSet(uint256 feeWei);
    event UnclaimFeeSet(uint256 feeWei);
    event ClaimFeePaid(address indexed payer, address indexed treasury, uint256 amount);
    event SluggClaimed(address indexed holder, uint256 indexed sluggId, uint256 indexed claimedId, uint256 fee);
    event SluggUnclaimed(address indexed holder, uint256 indexed claimedId, uint256 indexed newSluggId);

    // -------- errors --------

    error NotOwner();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroTokensPerSlugg();
    error NotSluggHolder();
    error NotClaimedHolder();
    error ClaimedNotConfigured();
    error TreasuryNotSet();
    error TransferDisabled();   // ERC-721 transfer not allowed; use ERC-20
    error WrongClaimFee();
    error WrongUnclaimFee();
    error TreasuryRejectedEth();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        ISeedSource _seed,
        address payable _treasury,
        uint256 _maxSluggs,
        uint256 _tokensPerSlugg
    ) {
        if (_tokensPerSlugg == 0) revert ZeroTokensPerSlugg();
        owner          = msg.sender;
        seed           = _seed;
        treasury       = _treasury;
        maxSluggs      = _maxSluggs;
        tokensPerSlugg = _tokensPerSlugg;
        totalSupply    = _maxSluggs * _tokensPerSlugg;
        skipSluggs[_treasury] = true;
        balanceOf[_treasury]  = totalSupply;
        emit Transfer(address(0), _treasury, totalSupply);
    }

    // -------- admin --------

    function setSeedSource(ISeedSource s) external onlyOwner {
        seed = s;
        emit SeedSourceSet(address(s));
    }

    function setSkip(address a, bool v) external onlyOwner {
        skipSluggs[a] = v;
        emit SkipSet(a, v);
    }

    function setRenderer(IUSluggRenderer r) external onlyOwner {
        renderer = r;
        emit RendererSet(address(r));
    }

    function setClaimedNft(IUSluggClaimed c) external onlyOwner {
        claimedNft = c;
        emit ClaimedNftSet(address(c));
    }

    /// @notice Owner passthrough so the Claimed ERC-721's renderer can be swapped.
    function setClaimedRenderer(address newRenderer) external onlyOwner {
        require(address(claimedNft) != address(0), "claimedNft not configured");
        IUSluggClaimedRendererSet(address(claimedNft)).setRenderer(IUSluggRenderer(newRenderer));
    }

    function setTreasury(address payable t) external onlyOwner {
        treasury = t;
        emit TreasurySet(t);
    }

    function setClaimFee(uint256 feeWei) external onlyOwner {
        claimFeeWei = feeWei;
        emit ClaimFeeSet(feeWei);
    }

    function setUnclaimFee(uint256 feeWei) external onlyOwner {
        unclaimFeeWei = feeWei;
        emit UnclaimFeeSet(feeWei);
    }

    // -------- ERC-20 --------

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = a - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 fb = balanceOf[from];
        if (fb < amount) revert InsufficientBalance();

        uint256 fromWholeBefore = fb / tokensPerSlugg;
        uint256 toWholeBefore   = balanceOf[to] / tokensPerSlugg;

        unchecked {
            balanceOf[from] = fb - amount;
            balanceOf[to]  += amount;
        }

        uint256 fromWholeAfter = balanceOf[from] / tokensPerSlugg;
        uint256 toWholeAfter   = balanceOf[to]   / tokensPerSlugg;

        if (!skipSluggs[from] && fromWholeAfter < fromWholeBefore) {
            uint256 lose = fromWholeBefore - fromWholeAfter;
            for (uint256 i; i < lose; ++i) {
                uint256 last = _inventory[from].length - 1;
                uint256 id   = _inventory[from][last];
                _inventory[from].pop();
                delete sluggs[id];
                delete ownerOf[id];
                emit SluggBurned(id, from);
                emit Transfer721(from, address(0), id);
            }
        }

        if (!skipSluggs[to] && toWholeAfter > toWholeBefore) {
            uint256 gain     = toWholeAfter - toWholeBefore;
            bytes32 hookSeed = seed.currentSeed();
            uint64  swapNo   = seed.swapCount();
            for (uint256 i; i < gain; ++i) {
                uint256 id = nextSluggId++;
                bytes32 s  = keccak256(abi.encode(hookSeed, id, to));
                sluggs[id]  = Slugg({ seed: s, originalMinter: to, mintedAtSwap: swapNo });
                ownerOf[id] = to;
                _inventory[to].push(id);
                emit SluggMinted(id, to, s);
                emit Transfer721(address(0), to, id);
            }
        }

        emit Transfer(from, to, amount);
    }

    // -------- views --------

    function inventoryOf(address a) external view returns (uint256[] memory) {
        return _inventory[a];
    }

    function sluggsOwned(address a) external view returns (uint256) {
        return _inventory[a].length;
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        Slugg memory c = sluggs[id];
        return renderer.tokenURI(id, c.seed);
    }

    function nftBalanceOf(address a) external view returns (uint256) {
        return _inventory[a].length;
    }

    // -------- ERC-721 transfer surface (intentionally disabled) --------
    // The NFT and the underlying ERC-20 are joined at the hip. To trade a
    // specific Slugg, either move the whole USLUG token via ERC-20 functions,
    // or claim() it into a standalone USluggClaimed ERC-721.

    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }
    function approveNft(address, uint256) external pure { revert TransferDisabled(); }
    function setApprovalForAll(address, bool) external pure { revert TransferDisabled(); }
    function transferFrom(address, address, uint256, bytes calldata) external pure { revert TransferDisabled(); }
    function safeTransferFrom(address, address, uint256) external pure { revert TransferDisabled(); }
    function safeTransferFrom(address, address, uint256, bytes calldata) external pure { revert TransferDisabled(); }

    // -------- claim / unclaim (standalone ERC-721 wrapping with treasury fee) --------

    function claim(uint256 id) external payable returns (uint256 claimedId) {
        if (address(claimedNft) == address(0)) revert ClaimedNotConfigured();
        if (ownerOf[id] != msg.sender) revert NotSluggHolder();
        if (treasury == address(0) && claimFeeWei > 0) revert TreasuryNotSet();
        if (msg.value != claimFeeWei) revert WrongClaimFee();
        if (balanceOf[msg.sender] < tokensPerSlugg) revert InsufficientBalance();

        Slugg memory c = sluggs[id];

        _removeFromInventory(msg.sender, id);
        delete sluggs[id];
        delete ownerOf[id];

        unchecked {
            balanceOf[msg.sender] -= tokensPerSlugg;
            balanceOf[address(this)] += tokensPerSlugg;
        }
        emit Transfer(msg.sender, address(this), tokensPerSlugg);

        if (msg.value > 0) {
            (bool ok, ) = treasury.call{value: msg.value}("");
            if (!ok) revert TreasuryRejectedEth();
            emit ClaimFeePaid(msg.sender, treasury, msg.value);
        }

        emit SluggBurned(id, msg.sender);
        emit Transfer721(msg.sender, address(0), id);

        claimedId = claimedNft.mint(msg.sender, c.seed, id);
        emit SluggClaimed(msg.sender, id, claimedId, msg.value);
    }

    function unclaim(uint256 claimedId) external payable returns (uint256 newSluggId) {
        if (address(claimedNft) == address(0)) revert ClaimedNotConfigured();
        if (claimedNft.ownerOf(claimedId) != msg.sender) revert NotClaimedHolder();
        if (treasury == address(0) && unclaimFeeWei > 0) revert TreasuryNotSet();
        if (msg.value != unclaimFeeWei) revert WrongUnclaimFee();

        (bytes32 oldSeed,,) = claimedNft.claimed(claimedId);

        claimedNft.burn(claimedId);

        if (msg.value > 0) {
            (bool ok, ) = treasury.call{value: msg.value}("");
            if (!ok) revert TreasuryRejectedEth();
            emit ClaimFeePaid(msg.sender, treasury, msg.value);
        }

        unchecked {
            balanceOf[address(this)] -= tokensPerSlugg;
            balanceOf[msg.sender]    += tokensPerSlugg;
        }
        emit Transfer(address(this), msg.sender, tokensPerSlugg);

        newSluggId = nextSluggId++;
        sluggs[newSluggId] = Slugg({
            seed:           oldSeed,
            originalMinter: msg.sender,
            mintedAtSwap:   seed.swapCount()
        });
        ownerOf[newSluggId] = msg.sender;
        _inventory[msg.sender].push(newSluggId);
        emit SluggMinted(newSluggId, msg.sender, oldSeed);
        emit Transfer721(address(0), msg.sender, newSluggId);
        emit SluggUnclaimed(msg.sender, claimedId, newSluggId);
    }

    function _removeFromInventory(address holder, uint256 id) internal {
        uint256[] storage inv = _inventory[holder];
        uint256 n = inv.length;
        for (uint256 i = 0; i < n; i++) {
            if (inv[i] == id) {
                inv[i] = inv[n - 1];
                inv.pop();
                return;
            }
        }
        revert NotSluggHolder();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7  // ERC-165
            || id == 0x36372b07  // ERC-20 (loose)
            || id == 0x80ac58cd  // ERC-721
            || id == 0x5b5e139f; // ERC-721 Metadata
    }
}
