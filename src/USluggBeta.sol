// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUSluggRenderer} from "./IUSluggRenderer.sol";

/// @notice Beta-test token for the uSlugg generative art system.
///
/// Pure ERC-721. Public mint(count) gives caller `count` pieces (cap 10k total),
/// each with a unique `key` derived from blockhash + timestamp + caller + id.
///
/// This is NOT the launch contract — the production version will be a v4-hook-driven
/// 404 hybrid (10k supply, 3 decimals, swap-mint). This beta exists to validate
/// the JS-animation tokenURI flow end-to-end on Sepolia before that lands.
contract USluggBeta {
    string  public constant name        = "uSlugg Beta";
    string  public constant symbol      = "USLUG";
    uint256 public constant MAX_SUPPLY  = 10_000;
    uint8   public constant MAX_PER_TX  = 20;

    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => bytes32) public keyOf;

    uint256 public totalSupply;
    address public admin;
    IUSluggRenderer public renderer;

    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event Approval(address indexed owner, address indexed approved, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event SluggMinted(uint256 indexed id, address indexed to, bytes32 key);
    event RendererSet(address renderer);

    error MaxSupply();
    error NotAdmin();
    error NotAuthorized();
    error InvalidRecipient();
    error WrongFrom();
    error TokenDoesNotExist();
    error BadCount();

    constructor() {
        admin = msg.sender;
    }

    // -------- admin --------

    function setRenderer(IUSluggRenderer r) external {
        if (msg.sender != admin) revert NotAdmin();
        renderer = r;
        emit RendererSet(address(r));
    }

    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin) revert NotAdmin();
        admin = newAdmin;
    }

    // -------- mint --------

    function mint(uint256 count) external returns (uint256[] memory ids) {
        if (count == 0 || count > MAX_PER_TX) revert BadCount();
        ids = new uint256[](count);
        for (uint256 i; i < count; i++) {
            if (totalSupply >= MAX_SUPPLY) revert MaxSupply();
            uint256 id = totalSupply;
            totalSupply = id + 1;
            bytes32 k = keccak256(abi.encode(
                blockhash(block.number - 1),
                block.timestamp,
                block.prevrandao,
                msg.sender,
                id,
                gasleft()
            ));
            keyOf[id] = k;
            _mint(msg.sender, id);
            emit SluggMinted(id, msg.sender, k);
            ids[i] = id;
        }
    }

    // -------- ERC-721 --------

    function _mint(address to, uint256 id) internal {
        if (to == address(0)) revert InvalidRecipient();
        ownerOf[id] = to;
        unchecked { balanceOf[to]++; }
        emit Transfer(address(0), to, id);
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

    function tokenURI(uint256 id) external view returns (string memory) {
        if (ownerOf[id] == address(0)) revert TokenDoesNotExist();
        return renderer.tokenURI(id, keyOf[id]);
    }

    function supportsInterface(bytes4 i) external pure returns (bool) {
        return i == 0x01ffc9a7 || i == 0x80ac58cd || i == 0x5b5e139f;
    }
}
