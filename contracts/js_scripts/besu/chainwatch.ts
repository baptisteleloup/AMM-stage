// Records the head of every node once a second, until stopped.
// Nodes that are down are recorded as such, so a fault experiment keeps running.
//
//   RPC_URLS=http://127.0.0.1:8545,...,http://127.0.0.1:8548 OUT=besu_results/watch.jsonl \
//   npx tsx js_scripts/besu/chainwatch.ts
//
// Each line: { t (wall clock ms), node, up, number, hash, ts, miner }.

import fs from "node:fs";

const RPC_URLS = (process.env.RPC_URLS ?? "http://127.0.0.1:8545").split(",").map((s) => s.trim());
const OUT = process.env.OUT ?? "besu_results/watch.jsonl";
const EVERY_MS = Number(process.env.EVERY_MS ?? 1000);

async function head(url: string) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 800);
  try {
    const res = await fetch(url, {
      method: "POST", headers: { "content-type": "application/json" }, signal: ctl.signal,
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getBlockByNumber", params: ["latest", false] }),
    });
    const b = (await res.json()).result;
    return { up: true, number: parseInt(b.number, 16), hash: b.hash, ts: parseInt(b.timestamp, 16), miner: b.miner };
  } catch {
    return { up: false };
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  fs.mkdirSync(OUT.split("/").slice(0, -1).join("/") || ".", { recursive: true });
  const out = fs.createWriteStream(OUT, { flags: "a" });
  let running = true;
  const stop = () => { running = false; };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  while (running) {
    const t = Date.now();
    const heads = await Promise.all(RPC_URLS.map(head));
    heads.forEach((h, node) => out.write(JSON.stringify({ t, node: node + 1, ...h }) + "\n"));
    await new Promise((r) => setTimeout(r, Math.max(0, EVERY_MS - (Date.now() - t))));
  }
  out.end();
}

main();
