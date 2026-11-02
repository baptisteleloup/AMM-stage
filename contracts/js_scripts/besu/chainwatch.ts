// Polls the head block of every Besu node once a second until stopped, and appends one JSON
// line per node and tick to OUT: { t (wall clock ms), node, up, number, hash, ts, miner }.
// Started in the background by network/faults.sh and network/skew.sh. By hand, from contracts/:
//   RPC_URLS=http://127.0.0.1:8545,...,http://127.0.0.1:8548 OUT=besu_results/watch.jsonl npx tsx js_scripts/besu/chainwatch.ts

import fs from "node:fs";

const RPC_URLS = (process.env.RPC_URLS ?? "http://127.0.0.1:8545").split(",").map((s) => s.trim());
const OUT = process.env.OUT ?? "besu_results/watch.jsonl";
const EVERY_MS = Number(process.env.EVERY_MS ?? 1000); // polling period

// Latest block of one node, or { up: false } if it does not answer within 800 ms.
async function head(url: string) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 800); // a stopped node must not stall the loop
  try {
    const res = await fetch(url, {
      method: "POST", headers: { "content-type": "application/json" }, signal: ctl.signal,
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getBlockByNumber", params: ["latest", false] }),
    });
    const b = (await res.json()).result;
    return { up: true, number: parseInt(b.number, 16), hash: b.hash, ts: parseInt(b.timestamp, 16), miner: b.miner };
  } catch {
    return { up: false }; // node down, recorded as such
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  fs.mkdirSync(OUT.split("/").slice(0, -1).join("/") || ".", { recursive: true }); // folder of OUT
  const out = fs.createWriteStream(OUT, { flags: "a" }); // append, one JSON line per node and tick
  let running = true;
  const stop = () => { running = false; };
  process.on("SIGINT", stop); // the experiment scripts kill the watcher at the end
  process.on("SIGTERM", stop);
  while (running) {
    const t = Date.now();
    const heads = await Promise.all(RPC_URLS.map(head)); // all nodes at the same instant
    heads.forEach((h, node) => out.write(JSON.stringify({ t, node: node + 1, ...h }) + "\n")); // nodes numbered from 1
    await new Promise((r) => setTimeout(r, Math.max(0, EVERY_MS - (Date.now() - t)))); // keep a steady period
  }
  out.end();
}

main();
