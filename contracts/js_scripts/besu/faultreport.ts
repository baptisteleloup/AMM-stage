// Reads the watcher log and the phase markers written by faults.sh, then reports,
// phase by phase, how many blocks were produced and the longest gap. Finally it
// compares, height by height, the block hash on every node: any difference means
// a fork, which QBFT is supposed to make impossible.
//
//   RPC_URLS=... WATCH=besu_results/watch.jsonl EVENTS=besu_results/events.jsonl \
//   npx tsx js_scripts/besu/faultreport.ts

import fs from "node:fs";

const RPC_URLS = (process.env.RPC_URLS ?? "http://127.0.0.1:8545").split(",").map((s) => s.trim());
const WATCH = process.env.WATCH ?? "besu_results/watch.jsonl";
const EVENTS = process.env.EVENTS ?? "besu_results/events.jsonl";
const OUT = process.env.OUT ?? "besu_results/faults.json";

type W = { t: number; node: number; up: boolean; number?: number; ts?: number };
type E = { t: number; phase: string };

const readJsonl = <T>(p: string): T[] =>
  fs.readFileSync(p, "utf-8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as T);

async function rpc(url: string, method: string, params: unknown[]) {
  const res = await fetch(url, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  return (await res.json()).result;
}

async function main() {
  const watch = readJsonl<W>(WATCH);
  const events = readJsonl<E>(EVENTS);
  const end = watch[watch.length - 1].t;
  const phases = events.map((e, i) => ({ phase: e.phase, from: e.t, to: events[i + 1]?.t ?? end }));

  // Chain progress in each phase, seen from the highest head among the nodes that are up.
  const report = phases.map((p) => {
    const rows = watch.filter((w) => w.t >= p.from && w.t < p.to && w.up);
    const byTime = new Map<number, number>();
    for (const r of rows) byTime.set(r.t, Math.max(byTime.get(r.t) ?? 0, r.number!));
    const series = [...byTime.entries()].sort((a, b) => a[0] - b[0]);
    const startH = series[0]?.[1] ?? 0, endH = series[series.length - 1]?.[1] ?? 0;
    let lastChange = series[0]?.[0] ?? p.from, prev = startH, longestGapS = 0;
    for (const [t, h] of series) {
      if (h !== prev) { longestGapS = Math.max(longestGapS, (t - lastChange) / 1000); lastChange = t; prev = h; }
    }
    longestGapS = Math.max(longestGapS, ((series[series.length - 1]?.[0] ?? p.to) - lastChange) / 1000);
    const durationS = (p.to - p.from) / 1000;
    const nodesUp = [...new Set(rows.map((r) => r.node))].sort();
    return { phase: p.phase, durationS, nodesUp, blocks: endH - startH,
             meanIntervalS: endH > startH ? durationS / (endH - startH) : null, longestGapS };
  });

  // Fork check: every height present on every node must have the same hash.
  const heads = await Promise.all(RPC_URLS.map((u) => rpc(u, "eth_blockNumber", []).then((h: string) => parseInt(h, 16))));
  const top = Math.min(...heads);
  let mismatches = 0;
  for (let h = 0; h <= top; h++) {
    const hashes = await Promise.all(RPC_URLS.map((u) => rpc(u, "eth_getBlockByNumber", ["0x" + h.toString(16), false]).then((b: { hash: string }) => b.hash)));
    if (new Set(hashes).size !== 1) mismatches++;
  }

  const result = { phases: report, forkCheck: { heightsCompared: top + 1, nodes: RPC_URLS.length, mismatches } };
  fs.writeFileSync(OUT, JSON.stringify(result, null, 1));
  for (const r of report) {
    console.log(`${r.phase.padEnd(28)} ${String(r.durationS.toFixed(0)).padStart(4)} s  nodes up ${r.nodesUp.join(",").padEnd(8)} blocks ${String(r.blocks).padStart(4)}  ` +
      `mean interval ${r.meanIntervalS ? r.meanIntervalS.toFixed(2) + " s" : "-"}  longest gap ${r.longestGapS.toFixed(0)} s`);
  }
  console.log(`fork check: ${top + 1} heights on ${RPC_URLS.length} nodes, ${mismatches} mismatch(es)`);
  console.log(`wrote ${OUT}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
