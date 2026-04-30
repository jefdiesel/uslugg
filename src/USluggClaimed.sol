// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUSluggRenderer} from "./IUSluggRenderer.sol";

/// @notice Standalone ERC-721 minted when a holder calls USlugg404.claim().
///
/// The reason this contract exists separately from the 404 hybrid: NFT marketplaces
/// (OpenSea, Blur, etc.) don't index 404 NFTs because they don't emit canonical
/// ERC-721 Transfer events on every transfer. Claimed sluggs are real ERC-721s
/// and trade like any other NFT collection.
///
/// Minimal ERC-721 implementation inlined to avoid the OpenZeppelin dependency.
contract USluggClaimed {
    string public constant name   = "uSlugg Claimed";
    string public constant symbol = "USLUG";

    struct Claimed {
        bytes32 seed;
        uint256 origin404Id; // the 404 id this was claimed from (informational)
        uint64  claimedAt;   // block.timestamp at claim
    }

    address public immutable uslugg404;
    IUSluggRenderer public renderer;

    mapping(uint256 => Claimed)                       public claimed;
    mapping(uint256 => address)                       public ownerOf;
    mapping(address => uint256)                       public balanceOf;
    mapping(uint256 => address)                       public getApproved;
    mapping(address => mapping(address => bool))      public isApprovedForAll;
    uint256 public nextId;

    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event Approval(address indexed owner, address indexed approved, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    error OnlyUSlugg404();
    error NotOwner();
    error InvalidRecipient();
    error WrongFrom();
    error NotAuthorized();
    error TokenDoesNotExist();

    modifier onlyUslugg404() {
        if (msg.sender != uslugg404) revert OnlyUSlugg404();
        _;
    }

    constructor(address _uslugg404, IUSluggRenderer _renderer) {
        uslugg404 = _uslugg404;
        renderer  = _renderer;
    }

    /// @notice Swap the renderer contract. Gated to USlugg404 so the parent's
    /// owner controls upgrades via USlugg404.setClaimedRenderer().
    function setRenderer(IUSluggRenderer r) external onlyUslugg404 {
        renderer = r;
    }

    /// @notice Mint a claimed NFT. Only callable by USlugg404 during claim().
    function mint(address to, bytes32 seed, uint256 origin404Id)
        external onlyUslugg404 returns (uint256 id)
    {
        if (to == address(0)) revert InvalidRecipient();
        id = nextId++;
        claimed[id] = Claimed({
            seed:        seed,
            origin404Id: origin404Id,
            claimedAt:   uint64(block.timestamp)
        });
        ownerOf[id] = to;
        unchecked { balanceOf[to]++; }
        emit Transfer(address(0), to, id);
    }

    /// @notice Burn a claimed NFT. Only callable by USlugg404 during unclaim().
    function burn(uint256 id) external onlyUslugg404 {
        address o = ownerOf[id];
        if (o == address(0)) revert NotOwner();
        delete claimed[id];
        delete getApproved[id];
        unchecked { balanceOf[o]--; }
        delete ownerOf[id];
        emit Transfer(o, address(0), id);
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        if (ownerOf[id] == address(0)) revert TokenDoesNotExist();
        Claimed memory c = claimed[id];
        return renderer.tokenURI(id, c.seed);
    }

    function transferFrom(address from, address to, uint256 id) public {
        if (ownerOf[id] != from) revert WrongFrom();
        if (to == address(0)) revert InvalidRecipient();
        if (msg.sender != from && getApproved[id] != msg.sender && !isApprovedForAll[from][msg.sender]) {
            revert NotAuthorized();
        }
        delete getApproved[id];
        unchecked { balanceOf[from]--; balanceOf[to]++; }
        ownerOf[id] = to;
        emit Transfer(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        transferFrom(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes calldata) external {
        transferFrom(from, to, id);
    }

    function approve(address to, uint256 id) external {
        address o = ownerOf[id];
        if (msg.sender != o && !isApprovedForAll[o][msg.sender]) revert NotAuthorized();
        getApproved[id] = to;
        emit Approval(o, to, id);
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
        emit ApprovalForAll(msg.sender, op, ok);
    }

    function supportsInterface(bytes4 i) external pure returns (bool) {
        return i == 0x01ffc9a7 || i == 0x80ac58cd || i == 0x5b5e139f;
    }
}
