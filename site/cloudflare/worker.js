// Cloudflare Worker port of the Vercel function api/rpc.js:
// proxies read-only JSON-RPC calls to Alchemy. ALCHEMY_KEY is a Worker secret.
//   POST /api/rpc?chain=eth-sepolia  body: { jsonrpc: "2.0", method: "eth_call", params: [...], id: 1 }
// Everything else is served from static assets.

const ALLOWED_CHAINS = new Set(["eth-mainnet", "eth-sepolia"]);

const ALLOWED_METHODS = new Set([
  "eth_call", "eth_blockNumber", "eth_chainId", "eth_getCode",
  "eth_getStorageAt", "eth_getBalance", "eth_getLogs",
  "eth_getBlockByNumber", "eth_getBlockByHash",
  "eth_getTransactionByHash", "eth_getTransactionReceipt",
  "eth_getTransactionCount",
]);

const json = (status, obj, headers = {}) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...headers },
  });

async function rpc(request, env) {
  if (request.method !== "POST") return json(405, { error: "POST only" });

  const chain = new URL(request.url).searchParams.get("chain");
  if (!ALLOWED_CHAINS.has(chain)) return json(400, { error: `unsupported chain: ${chain}` });

  const key = env.ALCHEMY_KEY;
  if (!key) return json(500, { error: "ALCHEMY_KEY not configured on server" });

  let body;
  try {
    body = await request.json();
  } catch {
    body = null;
  }
  if (!body || !body.method) return json(400, { error: "missing jsonrpc body" });
  if (!ALLOWED_METHODS.has(body.method)) return json(403, { error: `method not allowed: ${body.method}` });

  try {
    const r = await fetch(`https://${chain}.g.alchemy.com/v2/${key}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    return json(r.status, j, { "Cache-Control": "public, max-age=15" });
  } catch (e) {
    return json(502, { error: "upstream error", detail: String(e) });
  }
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/api/rpc" || pathname === "/api/rpc/") return rpc(request, env);
    return env.ASSETS.fetch(request);
  },
};
