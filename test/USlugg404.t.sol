// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ISeedSource}     from "../src/ISeedSource.sol";
import {USlugg404}       from "../src/USlugg404.sol";
import {USluggClaimed}   from "../src/USluggClaimed.sol";
import {USluggRenderer}  from "../src/USluggRenderer.sol";
import {USluggRuntime}   from "../src/USluggRuntime.sol";
import {IUSluggRenderer} from "../src/IUSluggRenderer.sol";
import {IUSluggClaimed}  from "../src/IUSluggClaimed.sol";

/// @dev Stub ISeedSource so tests don't need the real v4 hook + PoolManager
/// dance. Mimics what USluggHook would expose: a currentSeed that mutates
/// every "swap" plus a swapCount counter.
contract MockSeedSource is ISeedSource {
    bytes32 public override currentSeed;
    uint64  public override swapCount;

    function reroll() external {
        unchecked { swapCount++; }
        currentSeed = keccak256(abi.encode(currentSeed, swapCount, block.prevrandao));
    }
}

contract USlugg404Test is Test {
    MockSeedSource  hook;
    USluggRuntime   runtime;
    USluggRenderer  renderer;
    USlugg404       token;
    USluggClaimed   claimed;

    address payable treasury = payable(address(0x100));
    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);

    uint256 constant MAX = 10_000;
    uint256 constant TPS = 1e3;  // tokensPerSlugg with decimals=3 → 1.000 USLUG/NFT

    function setUp() public {
        hook = new MockSeedSource();
        hook.reroll();  // give it a non-zero starting seed

        runtime  = new USluggRuntime();
        renderer = new USluggRenderer(address(runtime));
        token    = new USlugg404(hook, treasury, MAX, TPS);
        claimed  = new USluggClaimed(address(token), IUSluggRenderer(address(renderer)));

        token.setRenderer(IUSluggRenderer(address(renderer)));
        token.setClaimedNft(IUSluggClaimed(address(claimed)));
        token.setClaimFee(0.001111 ether);
        token.setUnclaimFee(0.0069 ether);
    }

    /// @notice Treasury → Alice transfer of 5.000 USLUG mints 5 NFTs to Alice.
    function test_buy_mints_nfts() public {
        vm.prank(treasury);
        token.transfer(alice, 5 * TPS);

        assertEq(token.balanceOf(alice), 5 * TPS, "alice balance");
        assertEq(token.sluggsOwned(alice), 5, "alice nft count");

        // All NFTs have unique seeds derived from hook's currentSeed
        bytes32 a0; bytes32 a1;
        (a0,,) = token.sluggs(0);
        (a1,,) = token.sluggs(1);
        assertTrue(a0 != a1, "seeds must differ across mints");

        assertEq(token.ownerOf(0), alice);
        assertEq(token.ownerOf(4), alice);
    }

    /// @notice Selling burns NFTs; the next buyer gets fresh seeds.
    function test_sell_burns_then_rebuy_mints_new_seeds() public {
        vm.prank(treasury);
        token.transfer(alice, 1 * TPS);

        bytes32 firstSeed;
        (firstSeed,,) = token.sluggs(0);

        // Alice sells back to treasury — burns NFT 0
        vm.prank(alice);
        token.transfer(treasury, 1 * TPS);
        assertEq(token.sluggsOwned(alice), 0, "alice nfts after sell");

        // Hook re-rolls, then Bob buys
        hook.reroll();
        vm.prank(treasury);
        token.transfer(bob, 1 * TPS);

        bytes32 bobSeed;
        (bobSeed,,) = token.sluggs(1);  // nextSluggId continues, so id=1
        assertEq(token.ownerOf(1), bob);
        assertTrue(firstSeed != bobSeed, "rebuy must produce new seed");
    }

    /// @notice Fractional balance below 1.000 doesn't mint an NFT.
    function test_fractional_holds_no_nft() public {
        vm.prank(treasury);
        token.transfer(alice, TPS - 1);  // 0.999 USLUG

        assertEq(token.balanceOf(alice), TPS - 1);
        assertEq(token.sluggsOwned(alice), 0, "fractional holds no NFT");
    }

    /// @notice claim() lifts a Slugg into the standalone ERC-721. Pays fee.
    function test_claim_creates_standalone_erc721() public {
        vm.prank(treasury);
        token.transfer(alice, 1 * TPS);

        uint256 sluggId = 0;
        bytes32 origSeed;
        (origSeed,,) = token.sluggs(sluggId);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 claimedId = token.claim{value: 0.001111 ether}(sluggId);

        // 404 NFT burned, claimed NFT minted
        assertEq(token.ownerOf(sluggId), address(0), "404 nft cleared");
        assertEq(claimed.ownerOf(claimedId), alice, "claimed nft owned by alice");

        (bytes32 cSeed,,) = claimed.claimed(claimedId);
        assertEq(cSeed, origSeed, "claimed seed preserved");

        // Treasury received the fee
        assertEq(treasury.balance, 0.001111 ether);
    }

    /// @notice unclaim() returns USLUG and re-mints into 404.
    function test_unclaim_returns_to_404() public {
        vm.prank(treasury);
        token.transfer(alice, 1 * TPS);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 claimedId = token.claim{value: 0.001111 ether}(0);

        vm.prank(alice);
        uint256 newSluggId = token.unclaim{value: 0.0069 ether}(claimedId);

        assertEq(token.ownerOf(newSluggId), alice);
        assertEq(token.balanceOf(alice), 1 * TPS, "balance restored");
        assertEq(treasury.balance, 0.001111 ether + 0.0069 ether);
    }

    /// @notice tokenURI returns valid HTML metadata with animation_url + image fallback.
    function test_tokenURI_format() public {
        vm.prank(treasury);
        token.transfer(alice, 1 * TPS);

        string memory uri = token.tokenURI(0);
        bytes memory u = bytes(uri);

        assertTrue(_contains(u, "data:application/json;utf8,"), "json prefix");
        assertTrue(_contains(u, "\"name\":\"uSlugg #0\""), "name");
        assertTrue(_contains(u, "\"animation_url\":\"data:text/html;utf8,"), "animation_url");
        assertTrue(_contains(u, "window.KEY="), "key embedded");
        assertTrue(_contains(u, "<svg"), "svg fallback");
    }

    function _contains(bytes memory hay, string memory ndl) internal pure returns (bool) {
        bytes memory n = bytes(ndl);
        if (n.length > hay.length) return false;
        for (uint256 i = 0; i + n.length <= hay.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (hay[i + j] != n[j]) { ok = false; break; }
            }
            if (ok) return true;
        }
        return false;
    }
}
