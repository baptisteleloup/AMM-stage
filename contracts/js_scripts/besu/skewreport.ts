// Clock-skew experiment report. Reads the watcher log (WATCH) and phase markers (EVENTS) of
// network/skew.sh and gives per phase the skewed validator's share of blocks, the block intervals
// and the lag between first sight and block timestamp. Writes OUT (skew.json); run by skew.sh, or:
//   WATCH=besu_results/skew_watch.jsonl EVENTS=besu_results/skew_events.jsonl SKEWED=0x2c8b... npx tsx js_scripts/besu/skewreport.ts

import fs from "node:fs";

const WATCH = process.env.WATCH ?? "besu_results/skew_watch.jsonl";
const EVENTS = process.env.EVENTS ?? "besu_results/skew_events.jsonl";
const OUT = process.env.OUT ?? "besu_results/skew.json";
const SKEWED = (process.env.SKEWED ?? "").toLowerCase(); // validator address of the skewed node

// one chainwatch line
type W = { t: number; node: number; up: boolean; number?: number; hash?: string; ts?: number; miner?: string };
type E = { t: number; phase: string }; // one phase marker

const readJsonl = <T>(p: string): T[] =>
  fs.readFileSync(p, "utf-8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as T);

// n, min, mean, max of a list, null if empty.
function stats(xs: number[]) {
  if (xs.length === 0) return null;
  const s = [...xs].sort((a, b) => a - b);
  return { n: s.length, min: s[0], mean: s.reduce((a, b) => a + b, 0) / s.length, max: s[s.length - 1] };
}

const watch = readJsonl<W>(WATCH);
const events = readJsonl<E>(EVENTS);
const end = watch[watch.length - 1].t;
// each phase runs to the next marker
const phases = events.map((e, i) => ({ phase: e.phase, from: e.t, to: events[i + 1]?.t ?? end }));

// First time each block number was seen by the watcher, on any node.
const firstSeen = new Map<number, W>();
for (const w of watch) if (w.up && w.number !== undefined && !firstSeen.has(w.number)) firstSeen.set(w.number, w);
const blocks = [...firstSeen.values()].sort((a, b) => a.number! - b.number!);

const report = phases.map((p) => {
  // Skip the first 30 s of each phase: the restarted node is still syncing.
  const inPhase = blocks.filter((b) => b.t >= p.from + 30000 && b.t < p.to);
  const byMiner: Record<string, number> = {};
  // blocks per proposer
  for (const b of inPhase) byMiner[b.miner!.toLowerCase()] = (byMiner[b.miner!.toLowerCase()] ?? 0) + 1;
  const intervals: number[] = [];
  for (let i = 1; i < inPhase.length; i++) {
    // timestamp gap of consecutive blocks
    if (inPhase[i].number === inPhase[i - 1].number! + 1) intervals.push(inPhase[i].ts! - inPhase[i - 1].ts!);
  }
  // wall clock at first sight minus block timestamp, s
  const lag = (list: W[]) => stats(list.map((b) => b.t / 1000 - b.ts!));
  return {
    phase: p.phase, blocks: inPhase.length,
    skewedShare: inPhase.length ? (byMiner[SKEWED] ?? 0) / inPhase.length : null, // a node ahead loses its turns
    blockIntervalS: stats(intervals),
    // a node behind backdates its blocks
    seenMinusTimestampS: { skewed: lag(inPhase.filter((b) => b.miner!.toLowerCase() === SKEWED)),
                           others: lag(inPhase.filter((b) => b.miner!.toLowerCase() !== SKEWED)) },
  };
});

fs.writeFileSync(OUT, JSON.stringify(report, null, 1));
const f = (x: number | undefined) => (x === undefined ? "  -  " : x.toFixed(1).padStart(5));
console.log("phase                         blocks  skewed share  interval min/mean/max   seen-ts lag skewed / others (mean, max)");
for (const r of report) {
  const iv = r.blockIntervalS, a = r.seenMinusTimestampS.skewed, o = r.seenMinusTimestampS.others;
  console.log(`${r.phase.padEnd(29)} ${String(r.blocks).padStart(5)}  ${r.skewedShare === null ? "  -" : (100 * r.skewedShare).toFixed(0).padStart(4) + " %"}       ` +
    `${f(iv?.min)} ${f(iv?.mean)} ${f(iv?.max)}      ${f(a?.mean)} ${f(a?.max)}  /  ${f(o?.mean)} ${f(o?.max)}`);
}
console.log(`wrote ${OUT}`);
