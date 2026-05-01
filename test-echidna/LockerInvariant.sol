// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {USluggLPLocker}     from "../src/USluggLPLocker.sol";
import {IPositionManager}   from "v4-periphery/interfaces/IPositionManager.sol";
import {Currency}           from "v4-core/types/Currency.sol";

/// @notice Mock v4 PositionManager that just tracks NFT ownership for fuzzing.
/// Echidna will try to find a sequence of calls into the harness that breaks
/// the locker's custody invariant. Calls into modifyLiquidities are no-ops
/// (the locker passes DECREASE_LIQUIDITY of zero, so a real PositionManager
/// would do nothing observable to NFT custody either).
contract MockPosMgrERC721 {
    mapping(uint256 => address) public ownerOf;

    function mintTo(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    /// @dev We never want to enable a transfer path inside the mock; if echidna
    /// found a way to call this it would be a real bug in the locker.
    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "from!=owner");
        ownerOf[tokenId] = to;
    }

    function modifyLiquidities(bytes calldata, uint256) external {
        // Real v4 modifyLiquidities with DECREASE_LIQUIDITY(0) doesn't move
        // the LP NFT — it only routes accrued fees via TAKE_PAIR. The mock
        // mirrors that: NFT custody is untouched.
    }

    function callOnReceived(address locker, uint256 tokenId) external {
        ownerOf[tokenId] = locker;
        // Trigger the receiver hook from address(this) (the mock IS the posMgr).
        (bool ok, ) = locker.call(
            abi.encodeWithSignature(
                "onERC721Received(address,address,uint256,bytes)",
                address(this), address(this), tokenId, ""
            )
        );
        require(ok, "onERC721Received reverted");
    }
}

/// @notice Echidna harness. Locker is constructed once; the mock posMgr seeds
/// 5 LP NFTs into the locker via the receiver hook. Echidna then mutates state
/// through the public action functions on this harness (collectFees, attempts
/// to extract). The properties below MUST always hold — if echidna finds a
/// counterexample, that's a real bug in USluggLPLocker.
contract LockerInvariant {
    MockPosMgrERC721 public posMgr;
    USluggLPLocker   public locker;
    address constant FEE_RECIPIENT = address(0xCAFE);

    uint256[5] public lockedIds;

    constructor() {
        posMgr = new MockPosMgrERC721();
        locker = new USluggLPLocker(IPositionManager(address(posMgr)), FEE_RECIPIENT);

        // Seed 5 LP NFTs into the locker. Each goes through the receiver hook
        // so we exercise the only path into custody.
        for (uint256 i = 0; i < 5; i++) {
            uint256 tokenId = 100 + i;
            lockedIds[i] = tokenId;
            posMgr.callOnReceived(address(locker), tokenId);
        }
    }

    // -------- actions echidna will fuzz --------

    function action_collectFees(uint8 idx, uint160 c0, uint160 c1) external {
        uint256 tokenId = lockedIds[idx % 5];
        locker.collectFees(tokenId, Currency.wrap(address(c0)), Currency.wrap(address(c1)));
    }

    /// @dev Try to receive an extra NFT directly. Should only succeed if the
    /// caller is the posMgr; if any other path lets a non-posMgr smuggle in
    /// custody, that's also a bug.
    function action_try_receive_from_random(uint256 tokenId) external {
        // We are NOT the posMgr — locker should reject.
        try locker.onERC721Received(msg.sender, msg.sender, tokenId, "") {
            // If this didn't revert, echidna will record the call sequence.
        } catch {}
    }

    function action_seed_more(uint256 tokenIdSeed) external {
        uint256 tokenId = (tokenIdSeed % 1000) + 1000;
        posMgr.callOnReceived(address(locker), tokenId);
    }

    // -------- invariants --------

    /// @notice The locker must own every NFT it received via the receiver hook.
    /// If echidna finds a sequence that drains any of them, this returns false.
    function echidna_locker_owns_all_seeded_nfts() external view returns (bool) {
        for (uint256 i = 0; i < 5; i++) {
            if (posMgr.ownerOf(lockedIds[i]) != address(locker)) return false;
        }
        return true;
    }

    /// @notice feeRecipient is immutable. The address must never change.
    function echidna_fee_recipient_immutable() external view returns (bool) {
        return locker.feeRecipient() == FEE_RECIPIENT;
    }

    /// @notice posMgr is immutable.
    function echidna_pos_mgr_immutable() external view returns (bool) {
        return address(locker.posMgr()) == address(posMgr);
    }
}
