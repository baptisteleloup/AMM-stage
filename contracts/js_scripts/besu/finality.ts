// Time to finality on the QBFT network: sends N empty transactions (BURST at a time) and times
// until every node in RPC_URLS returns the receipt (QBFT has no forks, so imported = final).
// Writes OUT (besu_results/finality_seq.json and finality_burst.json in the repo). From contracts/:
//   RPC_URLS=http://127.0.0.1:8545,http://127.0.0.1:8546 N=200 BURST=10 OUT=besu_results/finality_burst.json npx tsx js_scripts/besu/finality.ts

import fs from "node:fs";
import { ethers } from "ethers";

const RPC_URLS = (process.env.RPC_URLS ?? "http://127.0.0.1:8545").split(",").map((s) => s.trim());
const KEY = process.env.KEY ?? "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // public test key, funded in network/genesis.json
const N = Number(process.env.N ?? 200);          // number of transactions
const BURST = Number(process.env.BURST ?? 1);    // transactions sent at once per round
const POLL_MS = Number(process.env.POLL_MS ?? 50); // receipt polling period
const OUT = process.env.OUT ?? "besu_results/finality.json";

type Sample = {
  hash: string;
  sentAtMs: number;       // wall clock when the transaction was sent
  finalAtMs: number;      // wall clock when every node returned the receipt
  latencyMs: number;      // finalAtMs - sentAtMs
  blockNumber: number;
  blockTs: number;        // block timestamp (seconds)
  blockTsMinusSentS: number; // block timestamp minus send time, seconds
  proposer: string;       // validator that proposed the block
};

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// n, mean, median, p95, min, max of a list.
function stats(xs: number[]) {
  const s = [...xs].sort((a, b) => a - b);
  const q = (p: number) => s[Math.min(s.length - 1, Math.floor(p * s.length))];
  const mean = s.reduce((a, b) => a + b, 0) / s.length;
  return { n: s.length, mean, median: q(0.5), p95: q(0.95), max: s[s.length - 1], min: s[0] };
}

async function main() {
  const providers = RPC_URLS.map((u) => new ethers.JsonRpcProvider(u, undefined, { staticNetwork: true, pollingInterval: POLL_MS }));
  const wallet = new ethers.Wallet(KEY, providers[0]);
  const chainId = (await providers[0].getNetwork()).chainId;
  let nonce = await providers[0].getTransactionCount(wallet.address, "pending"); // nonces set by hand so a burst goes out at once
  const samples: Sample[] = [];

  console.log(`chain ${chainId}, ${RPC_URLS.length} node(s), ${N} transactions in bursts of ${BURST}`);

  while (samples.length < N) {
    const batch = Math.min(BURST, N - samples.length); // last round may be shorter
    const pending: { hash: string; sentAtMs: number }[] = [];
    for (let i = 0; i < batch; i++) {
      const tx = await wallet.signTransaction({
        to: wallet.address, value: 0n, nonce: nonce++, gasLimit: 21000n, // empty self-transfer
        gasPrice: 0n, chainId, type: 0, // free gas network, legacy transaction
      });
      const sentAtMs = Date.now();
      const hash = await providers[0].send("eth_sendRawTransaction", [tx]); // sent to the first node only
      pending.push({ hash, sentAtMs });
    }
    for (const p of pending) {
      const seen = new Array(providers.length).fill(false);
      let receipt: ethers.TransactionReceipt | null = null;
      for (;;) {
        await Promise.all(providers.map(async (pr, i) => {
          if (seen[i]) return;
          const r = await pr.getTransactionReceipt(p.hash).catch(() => null);
          if (r) { seen[i] = true; if (i === 0) receipt = r; } // keep the first node's receipt
        }));
        if (seen.every(Boolean)) break; // final once every node has it
        await sleep(POLL_MS);
      }
      const finalAtMs = Date.now();
      const r = receipt as unknown as ethers.TransactionReceipt;
      const block = await providers[0].getBlock(r.blockNumber);
      samples.push({
        hash: p.hash, sentAtMs: p.sentAtMs, finalAtMs, latencyMs: finalAtMs - p.sentAtMs,
        blockNumber: r.blockNumber, blockTs: block!.timestamp,
        blockTsMinusSentS: block!.timestamp - p.sentAtMs / 1000, proposer: block!.miner,
      });
    }
    process.stdout.write(`\r${samples.length}/${N}`); // progress
  }
  console.log("");

  // Block intervals and proposers over the whole measured range.
  const first = samples[0].blockNumber, last = samples[samples.length - 1].blockNumber;
  const heads: (ethers.Block | null)[] = [];
  for (let b = first; b <= last; b++) heads.push(await providers[0].getBlock(b));
  const intervals = heads.slice(1).map((h, i) => h!.timestamp - heads[i]!.timestamp);
  const proposers: Record<string, number> = {};
  for (const h of heads) proposers[h!.miner] = (proposers[h!.miner] ?? 0) + 1;

  const summary = {
    rpcUrls: RPC_URLS, n: N, burst: BURST,
    latencyMs: stats(samples.map((s) => s.latencyMs)),
    blockTsMinusSentS: stats(samples.map((s) => s.blockTsMinusSentS)),
    blockIntervalS: stats(intervals),
    blocks: heads.length, proposers,
  };
  fs.mkdirSync(OUT.split("/").slice(0, -1).join("/") || ".", { recursive: true });
  fs.writeFileSync(OUT, JSON.stringify({ summary, samples }, null, 1));

  const f = (x: number) => x.toFixed(2);
  console.log(`latency to finality (ms): mean ${f(summary.latencyMs.mean)}  median ${summary.latencyMs.median}  p95 ${summary.latencyMs.p95}  max ${summary.latencyMs.max}`);
  console.log(`block timestamp minus send time (s): mean ${f(summary.blockTsMinusSentS.mean)}  min ${f(summary.blockTsMinusSentS.min)}  max ${f(summary.blockTsMinusSentS.max)}`);
  console.log(`block interval (s): mean ${f(summary.blockIntervalS.mean)}  min ${summary.blockIntervalS.min}  max ${summary.blockIntervalS.max}`);
  console.log(`blocks per proposer: ${JSON.stringify(proposers)}`);
  console.log(`wrote ${OUT}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
