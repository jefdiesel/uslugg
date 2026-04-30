// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUSluggRenderer} from "./IUSluggRenderer.sol";

interface IRuntime { function data() external pure returns (bytes memory); }

/// @notice Builds the data:application/json metadata for a uSlugg, with the
/// animated piece embedded as a data:text/html `animation_url`. The HTML
/// pulls the Canvas2D runtime from the chunk-stored USluggRuntime contract
/// and injects the token's `key` as window.KEY.
contract USluggRenderer is IUSluggRenderer {
    address public immutable runtime;

    constructor(address _runtime) {
        runtime = _runtime;
    }

    function tokenURI(uint256 id, bytes32 key) external view returns (string memory) {
        bytes memory js = IRuntime(runtime).data();

        string memory keyHex = _toHex(key);
        string memory html = string(abi.encodePacked(
            "<!doctype html><html><head><meta charset='utf-8'>",
            "<meta name='viewport' content='width=device-width,initial-scale=1'></head>",
            "<body><script>window.KEY='", keyHex, "';", js, "</script></body></html>"
        ));

        // Static image fallback (8x8 gray) so wallets that don't run animation_url
        // still show *something* in their grid view.
        string memory svgFallback = string(abi.encodePacked(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 8'>",
            "<rect width='8' height='8' fill='#222'/>",
            "<text x='1' y='5' font-size='2' fill='#c3ff00'>USLUG</text></svg>"
        ));

        return string(abi.encodePacked(
            "data:application/json;utf8,",
            "{\"name\":\"uSlugg #", _u(id), "\",",
            "\"description\":\"Animated on-chain generative art. Block hash + timestamp produce the key; the key produces the piece. The animation runs live in your wallet.\",",
            "\"image\":\"data:image/svg+xml;utf8,", svgFallback, "\",",
            "\"animation_url\":\"data:text/html;utf8,", html, "\"}"
        ));
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v; uint256 len;
        while (j != 0) { len++; j /= 10; }
        bytes memory b = new bytes(len);
        while (v != 0) { len--; b[len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }

    function _toHex(bytes32 b) internal pure returns (string memory) {
        bytes16 H = 0x30313233343536373839616263646566;
        bytes memory out = new bytes(66);
        out[0] = "0"; out[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            uint8 byteVal = uint8(b[i]);
            out[2 + i*2]     = H[byteVal >> 4];
            out[2 + i*2 + 1] = H[byteVal & 0x0f];
        }
        return string(out);
    }
}
