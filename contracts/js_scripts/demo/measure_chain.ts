import fs from "node:fs";
import path from "node:path";
import { ethers } from "ethers";

const DEPLOY_FILE = process.env.DEPLOY_OUT ?? "demo/state/deployed_demo.json";
const RECEIPTS_DIR = process.env.RECEIPTS_DIR ?? "demo/state/operator-data/receipts";
const LOG_FILE = process.env.DEMO_LOG ?? "demo/state/demo.log";
const OUT_FILE = process.env.MEASURE_OUT ?? "demo/measure_chain.json";

const MARKET_ABI = [
  "function register(bytes encryptionKey)",
  "function proposeFloor(uint256 slot,bytes32 floorCommit)",
  "function confirmFloor(uint256 slot,bytes32 floorCommit)",
  "function deposit(uint256 amount)",
  "function requestWithdraw(uint256 amount)",
  "function openSession(uint256 dayId,uint256 t,uint32 s,uint32 d)",
  "function postNetputHashes(uint256 dayId,bytes32[] hashes)",
  "function submitChunk(uint256 dayId,uint256 k,(bytes32[] newCommits,uint256[] withdrawalsPaid,uint32[96] partialS,uint32[96] partialD,uint256 partialPaidOut,uint256 partialPaidIn) sub,bytes proof)",
  "function finalizeDay(uint256 dayId)",
  "function requestData(uint256 dayId)",
  "function postEncryptedData(uint256 dayId,uint256 slot,bytes blob)",
  "function requestClearReveal(uint256 dayId)",
  "function clearReveal(uint256 dayId,uint256 slot,uint64 bal,bytes proof)",
  "function cancelDay(uint256 dayId,uint256 revealSlot,string reason)",
  "function sweepDust()",
  "function sessions(uint256,uint256) view returns (uint32 s,uint32 d,uint32 priceR,uint32 priceC,uint32 lambdaLo,uint32 lambdaHi,bool opened)",
  "function dayCloses(uint256) view returns (uint8 state,uint256 chunksVerified,uint256 accPaidOut,uint256 accPaidIn,uint256 disputeDeadline,uint256 prosumerCountAt)",
  "function snapDeposit(uint256,uint256) view returns (uint256)",
  "function chunkCountFor(uint256) view returns (uint256)",
  "function dustPot() view returns (uint256)",
  "event DustAccrued(uint256 indexed dayId, uint256 amount)",
];
const TARIFF_ABI = [
  "function submitDailyPrices(uint32 day,uint256[96] low,uint256[96] high)",
  "function setSchedule((uint256 feedIn,uint256 retailOffPeak,uint256 retailPeak,uint32[] winStart,uint32[] winEnd) s)",
];

type FnStat = { count: number; gasMin: bigint; gasMax: bigint; gasSum: bigint; bytesSum: number };
type DayStat = {
  openSession: number; openGas: bigint; postHashes: bigint; chunks: number; chunkGas: bigint;
  proofBytes: number[]; finalize: bigint; finalized: boolean; cancelled: boolean;
};

function stat(m: Map<string, FnStat>, name: string, gas: bigint, bytes: number): void {
  const s = m.get(name) ?? { count: 0, gasMin: gas, gasMax: gas, gasSum: 0n, bytesSum: 0 };
  s.count += 1;
  if (gas < s.gasMin) s.gasMin = gas;
  if (gas > s.gasMax) s.gasMax = gas;
  s.gasSum += gas;
  s.bytesSum += bytes;
  m.set(name, s);
}

function day(m: Map<number, DayStat>, id: number): DayStat {
  let d = m.get(id);
  if (!d) {
    d = { openSession: 0, openGas: 0n, postHashes: 0n, chunks: 0, chunkGas: 0n, proofBytes: [], finalize: 0n, finalized: false, cancelled: false };
    m.set(id, d);
  }
  return d;
}

function readJson(p: string): any {
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

async function main(): Promise<void> {
  const dep = readJson(DEPLOY_FILE);
  const rpc = process.env.RPC_URL ?? dep.rpcUrl ?? "http://127.0.0.1:8545";
  const marketAddr: string = (dep.market ?? dep.contracts?.market).toLowerCase();
  const tariffAddr: string | undefined = dep.contracts?.tariff?.toLowerCase();
  const provider = new ethers.JsonRpcProvider(rpc);
  const marketIf = new ethers.Interface(MARKET_ABI);
  const tariffIf = new ethers.Interface(TARIFF_ABI);
  const market = new ethers.Contract(marketAddr, MARKET_ABI, provider);

  const latest = await provider.getBlockNumber();
  const fns = new Map<string, FnStat>();
  const days = new Map<number, DayStat>();
  const paidWithdrawal = new Map<string, bigint>();
  let firstTs = 0, lastTs = 0, txCount = 0, blocksWithTx = 0;

  for (let b = 0; b <= latest; b++) {
    const block = await provider.getBlock(b, true);
    if (!block) continue;
    let touched = false;
    for (const tx of block.prefetchedTransactions) {
      const to = tx.to?.toLowerCase();
      if (to !== marketAddr && to !== tariffAddr) continue;
      const rc = await provider.getTransactionReceipt(tx.hash);
      if (!rc) continue;
      const bytes = (tx.data.length - 2) / 2;
      const iface = to === marketAddr ? marketIf : tariffIf;
      let name = "unknown";
      let parsed: ethers.TransactionDescription | null = null;
      try {
        parsed = iface.parseTransaction({ data: tx.data, value: tx.value });
        if (parsed) name = parsed.name;
      } catch { /* not in ABI */ }
      stat(fns, name, rc.gasUsed, bytes);
      touched = true;
      txCount += 1;
      if (!firstTs) firstTs = block.timestamp;
      lastTs = block.timestamp;
      if (!parsed || to !== marketAddr) continue;
      const a = parsed.args;
      if (name === "openSession") {
        const d = day(days, Number(a.dayId));
        d.openSession += 1; d.openGas += rc.gasUsed;
      } else if (name === "postNetputHashes") {
        day(days, Number(a.dayId)).postHashes += rc.gasUsed;
      } else if (name === "submitChunk") {
        const d = day(days, Number(a.dayId));
        d.chunks += 1; d.chunkGas += rc.gasUsed;
        d.proofBytes.push((a.proof.length - 2) / 2);
        const k = Number(a.k);
        const paid: bigint[] = a.sub.withdrawalsPaid.map((x: bigint) => BigInt(x));
        paid.forEach((w, lane) => paidWithdrawal.set(`${Number(a.dayId)}:${k * 8 + lane + 1}`, w));
      } else if (name === "finalizeDay") {
        const d = day(days, Number(a.dayId));
        d.finalize += rc.gasUsed;
        if (rc.status === 1) d.finalized = true;
      } else if (name === "cancelDay") {
        if (rc.status === 1) day(days, Number(a.dayId)).cancelled = true;
      }
    }
    if (touched) blocksWithTx += 1;
  }

  const proofTimes: number[] = [];
  if (fs.existsSync(LOG_FILE)) {
    for (const m of fs.readFileSync(LOG_FILE, "utf-8").matchAll(/proof took ([0-9.]+)s/g)) proofTimes.push(Number(m[1]));
  }

  const fidelity: { day: number; slot: number; expected: string; actual: string; ok: boolean }[] = [];
  const priceCache = new Map<number, { r: bigint; c: bigint }[]>();
  async function pricesOf(d: number): Promise<{ r: bigint; c: bigint }[]> {
    let p = priceCache.get(d);
    if (!p) {
      p = [];
      for (let t = 0; t < 96; t++) {
        const s = await market.sessions(d, t);
        p.push({ r: BigInt(s.priceR), c: BigInt(s.priceC) });
      }
      priceCache.set(d, p);
    }
    return p;
  }
  if (fs.existsSync(RECEIPTS_DIR)) {
    for (const slotDir of fs.readdirSync(RECEIPTS_DIR).filter((x) => x.startsWith("slot-"))) {
      const slot = Number(slotDir.slice(5));
      const base = path.join(RECEIPTS_DIR, slotDir);
      const dayIds = fs.readdirSync(base).filter((x) => x.startsWith("day-")).map((x) => Number(x.slice(4))).sort((a, b) => a - b);
      for (const d of dayIds) {
        const dir = path.join(base, `day-${d}`);
        const closeFile = path.join(dir, "day-close.json");
        const prevFile = path.join(base, `day-${d - 1}`, "day-close.json");
        if (!fs.existsSync(closeFile) || !fs.existsSync(prevFile)) continue;
        const dc = await market.dayCloses(d);
        if (Number(dc.state) !== 2) continue;
        const prev = BigInt(readJson(prevFile).newBalance);
        const actual = BigInt(readJson(closeFile).newBalance);
        const prices = await pricesOf(d);
        let amount = 0n;
        for (let t = 0; t < 96; t++) {
          const rf = path.join(dir, `t-${t}.json`);
          if (!fs.existsSync(rf)) continue;
          const r = readJson(rf);
          amount += BigInt(r.sell) * prices[t].r - BigInt(r.buy) * prices[t].c;
        }
        const depo = BigInt(await market.snapDeposit(d, slot));
        const paid = paidWithdrawal.get(`${d}:${slot}`) ?? 0n;
        const expected = prev + amount + depo - paid;
        fidelity.push({ day: d, slot, expected: expected.toString(), actual: actual.toString(), ok: expected === actual });
      }
    }
  }

  const dustEvents = await market.queryFilter(market.filters.DustAccrued(), 0, latest);
  const dust = dustEvents.map((e: any) => ({ day: Number(e.args.dayId), amount: e.args.amount.toString() }));

  const perFn = Object.fromEntries([...fns.entries()].map(([k, v]) => [k, {
    count: v.count,
    gasMin: v.gasMin.toString(),
    gasMean: (v.gasSum / BigInt(v.count)).toString(),
    gasMax: v.gasMax.toString(),
    gasTotal: v.gasSum.toString(),
    calldataBytesTotal: v.bytesSum,
  }]));

  const perDay = [...days.entries()].sort((a, b) => a[0] - b[0]).map(([id, d]) => ({
    day: id,
    sessionsOpened: d.openSession,
    gasSessions: d.openGas.toString(),
    gasNetputHashes: d.postHashes.toString(),
    chunks: d.chunks,
    gasChunks: d.chunkGas.toString(),
    proofBytesPerChunk: d.proofBytes,
    gasFinalize: d.finalize.toString(),
    gasDayTotal: (d.openGas + d.postHashes + d.chunkGas + d.finalize).toString(),
    finalized: d.finalized,
    cancelled: d.cancelled,
  }));

  const mean = (xs: number[]) => xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0;
  const summary = {
    rpc, market: marketAddr, blocks: latest + 1, blocksWithMarketTx: blocksWithTx, txToContracts: txCount,
    spanSeconds: lastTs - firstTs,
    proofTimeSeconds: { n: proofTimes.length, mean: mean(proofTimes), min: Math.min(...proofTimes), max: Math.max(...proofTimes) },
    proofBytes: { mean: mean(perDay.flatMap((d) => d.proofBytesPerChunk)) },
    fidelity: { checked: fidelity.length, mismatches: fidelity.filter((f) => !f.ok).length },
    dustPot: (await market.dustPot()).toString(),
  };

  const out = { summary, perFunction: perFn, perDay, dustPerDay: dust, fidelityMismatches: fidelity.filter((f) => !f.ok) };
  fs.writeFileSync(OUT_FILE, JSON.stringify(out, null, 2));

  console.log(`blocks ${summary.blocks}, ${txCount} transactions to the contracts over ${summary.spanSeconds}s`);
  for (const [k, v] of Object.entries(perFn)) {
    console.log(`  ${k.padEnd(20)} n=${String(v.count).padStart(4)}  gas mean=${v.gasMean.padStart(9)}  max=${v.gasMax.padStart(9)}  calldata=${v.calldataBytesTotal} B`);
  }
  for (const d of perDay) {
    console.log(`day ${d.day}: ${d.sessionsOpened} sessions, ${d.chunks} chunks, proof ${d.proofBytesPerChunk[0] ?? "-"} B, gas total ${d.gasDayTotal}, ${d.finalized ? "finalized" : d.cancelled ? "cancelled" : "open"}`);
  }
  console.log(`proof time: n=${summary.proofTimeSeconds.n} mean=${summary.proofTimeSeconds.mean.toFixed(1)}s max=${summary.proofTimeSeconds.max}s`);
  console.log(`fidelity: ${summary.fidelity.checked} slot-days checked, ${summary.fidelity.mismatches} mismatches`);
  console.log(`dust pot: ${summary.dustPot} pEUR`);
  console.log(`wrote ${OUT_FILE}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
