// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Test, console2} from "forge-std/Test.sol";
import {USluggRuntime}  from "../src/USluggRuntime.sol";
import {USluggRenderer} from "../src/USluggRenderer.sol";
import {USluggBeta, IUSluggRenderer} from "../src/USluggBeta.sol";

/// @notice Mints 4 sluggs and dumps each tokenURI's animation_url HTML to
/// `samples/uslugg-<id>.html`. Open those in a browser to verify the runtime
/// animates correctly with that specific on-chain key.
contract POCTest is Test {
    USluggRuntime  runtime;
    USluggRenderer renderer;
    USluggBeta     token;

    function setUp() public {
        runtime  = new USluggRuntime();
        renderer = new USluggRenderer(address(runtime));
        token    = new USluggBeta();
        token.setRenderer(IUSluggRenderer(address(renderer)));
    }

    function test_mint_and_dump_tokenURIs() public {
        // Vary block.timestamp + block.number per mint to get distinct keys
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < 4; i++) {
            vm.warp(1700000000 + i * 13);
            vm.roll(20000000 + i * 7);
            uint256[] memory minted = token.mint(1);
            ids[i] = minted[0];
        }

        // Dump each tokenURI's animation_url HTML to a file we can open
        for (uint256 i; i < 4; i++) {
            string memory uri = token.tokenURI(ids[i]);
            string memory html = _extractAnimationUrl(uri);
            string memory path = string.concat("samples/uslugg-", _u(ids[i]), ".html");
            vm.writeFile(path, html);
            console2.log("wrote:", path, "key:", uint256(token.keyOf(ids[i])));
        }

        // Also dump an index page that <iframe>s all 4 side-by-side
        string memory idx = "<!doctype html><html><head><meta charset='utf-8'><title>uSlugg POC</title><style>body{margin:0;background:#111;color:#eee;font:4px monospace;padding:16px}h1{color:#c3ff00}.g{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}.c{background:#000;border:1px solid #333}.c iframe{width:100%;aspect-ratio:1;border:0;display:block}.l{padding:6px;font-size:10px;color:#888;border-top:1px solid #222}</style></head><body><h1>USLUGG BETA POC - 4 FRESH MINTS</h1><p>Each frame below is the tokenURI animation_url running in an iframe sandbox, exactly as a wallet would render it.</p><div class='g'>";
        for (uint256 i; i < 4; i++) {
            idx = string.concat(idx,
                "<div class='c'><iframe src='uslugg-", _u(ids[i]), ".html'></iframe>",
                "<div class='l'>#", _u(ids[i]), "</div></div>"
            );
        }
        idx = string.concat(idx, "</div></body></html>");
        vm.writeFile("samples/index.html", idx);
        console2.log("wrote: samples/index.html (open this)");

        // Single-piece refresh viewer with the runtime embedded inline
        // (so it works from file:// without CORS/fetch issues)
        vm.writeFile("samples/one.html", _viewer(string(runtime.data())));
        console2.log("wrote: samples/one.html (single-piece refresh viewer)");
    }

    function _viewer(string memory rt) internal pure returns (string memory) {
        return string.concat(
            "<!doctype html><html><head><meta charset='utf-8'><title>uSlugg viewer</title>",
            "<style>",
            "html,body{margin:0;background:#0a0a0a;color:#eee;font:13px ui-monospace,monospace;height:100%}",
            "body{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:16px;padding:24px}",
            "#frame{width:400px;height:400px;border:1px solid #222;background:#000}",
            "#frame iframe{width:100%;height:100%;border:0;display:block}",
            "button{background:#c3ff00;color:#000;border:0;padding:10px 24px;font:inherit;font-weight:600;letter-spacing:2px;text-transform:uppercase;border-radius:4px;cursor:pointer}",
            "button:hover{filter:brightness(1.1)}",
            "#key{font-size:10px;color:#666;word-break:break-all;max-width:560px;text-align:center}",
            "</style></head><body>",
            "<div id='frame'><iframe id='if' sandbox='allow-scripts'></iframe></div>",
            "<button onclick='roll()'>NEW SLUGG</button>",
            "<div id='key'></div>",
            // Stash runtime JS in a script-type/text-plain block so it doesn't execute here
            "<script id='RT' type='text/plain'>", rt, "</script>",
            "<script>",
            "const RT=document.getElementById('RT').textContent;",
            "function roll(){",
            "const buf=new Uint8Array(32);crypto.getRandomValues(buf);",
            "const key='0x'+Array.from(buf).map(b=>b.toString(16).padStart(2,'0')).join('');",
            "document.getElementById('key').textContent='key '+key;",
            "const html='<!doctype html><html><head><meta charset=\"utf-8\"></head><body><script>window.KEY=\"'+key+'\";'+RT+'<\\/script></body></html>';",
            "document.getElementById('if').srcdoc=html;",
            "}",
            "roll();",
            "</script></body></html>"
        );
    }

    /// @dev Crude parser: find `"animation_url":"...HTML..."}` and pull HTML out.
    function _extractAnimationUrl(string memory uri) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        bytes memory needle = bytes("\"animation_url\":\"data:text/html;utf8,");
        // find needle
        uint256 start = 0;
        for (uint256 i = 0; i + needle.length < b.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (b[i + j] != needle[j]) { ok = false; break; }
            }
            if (ok) { start = i + needle.length; break; }
        }
        require(start > 0, "animation_url not found");
        // end is the closing "} of the JSON
        uint256 end = b.length - 2;  // strip trailing "}
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) out[i] = b[start + i];
        return string(out);
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v; uint256 len;
        while (j != 0) { len++; j /= 10; }
        bytes memory b = new bytes(len);
        while (v != 0) { len--; b[len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
}
