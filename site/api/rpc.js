// Vercel serverless function: proxy JSON-RPC calls to Alchemy.
// The Alchemy key lives in Vercel env vars (ALCHEMY_KEY) and is NEVER exposed to the browser.
//
// Usage from frontend:
//   POST /api/rpc?chain=eth-sepolia
//   body: { jsonrpc: "2.0", method: "eth_call", params: [...], id: 1 }

const ALLOWED_CHAINS = new Set([
  "eth-mainnet",
  "eth-sepolia",
]);

// Allow only safe read methods. Block anything that could send a transaction.
const ALLOWED_METHODS = new Set([
  "eth_call", "eth_blockNumber", "eth_chainId", "eth_getCode",
  "eth_getStorageAt", "eth_getBalance", "eth_getLogs",
  "eth_getBlockByNumber", "eth_getBlockByHash",
  "eth_getTransactionByHash", "eth_getTransactionReceipt",
  "eth_getTransactionCount",
]);

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "POST only" });
    return;
  }

  const chain = req.query.chain;
  if (!ALLOWED_CHAINS.has(chain)) {
    res.status(400).json({ error: `unsupported chain: ${chain}` });
    return;
  }

  const key = process.env.ALCHEMY_KEY;
  if (!key) {
    res.status(500).json({ error: "ALCHEMY_KEY not configured on server" });
    return;
  }

  // Validate the body — block any non-read methods
  const body = req.body;
  if (!body || !body.method) {
    res.status(400).json({ error: "missing jsonrpc body" });
    return;
  }
  if (!ALLOWED_METHODS.has(body.method)) {
    res.status(403).json({ error: `method not allowed: ${body.method}` });
    return;
  }

  const url = `https://${chain}.g.alchemy.com/v2/${key}`;
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    res.setHeader("Cache-Control", "public, max-age=15");
    res.status(r.status).json(j);
  } catch (e) {
    res.status(502).json({ error: "upstream error", detail: String(e) });
  }
}
