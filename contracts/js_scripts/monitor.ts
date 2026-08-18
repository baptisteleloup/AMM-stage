import fs from "node:fs";
import Database from "better-sqlite3";
import { ethers } from "ethers";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const OPERATOR_DB = process.env.OPERATOR_DB ?? "operator-data/operator.db";
const SESSIONS = 96;
const PRICE_SCALE = 1e11;
const PEUR_PER_EUR = 1e12;

const ABI = [
  "function currentDayId() view returns (uint256)",
  "function currentSessionIdx() view returns (uint256)",
  "function prosumerCount() view returns (uint256)",
  "function sessions(uint256,uint256) view returns (uint32 s,uint32 d,uint32 priceR,uint32 priceC,uint32 lambdaLo,uint32 lambdaHi,bool opened)",
  "function dayCloses(uint256) view returns (uint8 state,uint256 chunksVerified,uint256 accPaidOut,uint256 accPaidIn,uint256 disputeDeadline,uint256 prosumerCountAt)",
];

const C = {
  dim: "\x1b[90m", sell: "\x1b[33m", buy: "\x1b[34m",
  ok: "\x1b[32m", warn: "\x1b[31m", head: "\x1b[36m", off: "\x1b[0m",
};

function market(): string {
  if (process.env.MARKET_ADDRESS) return process.env.MARKET_ADDRESS;
  const f = process.env.DEPLOYMENT_JSON ?? "deployed_demo.json";
  if (!fs.existsSync(f)) throw new Error("set MARKET_ADDRESS or run where deployed_demo.json is");
  const dep = JSON.parse(fs.readFileSync(f, "utf-8"));
  const m = dep.market ?? dep.contracts?.market ?? dep.contracts?.MarketV4;
  if (!m) throw new Error("no market address in deployed_demo.json");
  return m;
}

function eur(peur: bigint | number): string {
  return (Number(peur) / PEUR_PER_EUR).toFixed(4);
}

function kwh(wh: number): string {
  return (wh / 1000).toFixed(2);
}

function bar(value: number, peak: number, width: number, colour: string): string {
  if (peak <= 0) return " ".repeat(width);
  const n = Math.min(width, Math.round((value / peak) * width));
  return colour + "█".repeat(n) + C.off + " ".repeat(width - n);
}

type DayRow = {
  day: number;
  state: string;
  opened: number;
  sold: number;
  bought: number;
  internal: number;
  paidOut: bigint;
  paidIn: bigint;
  avgR: number;
  avgC: number;
};

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function balanceHistory(slots: number, fromDay: number, toDay: number): Map<number, Map<number, bigint>> {
  const out = new Map<number, Map<number, bigint>>();
  if (!fs.existsSync(OPERATOR_DB)) return out;
  const db = new Database(OPERATOR_DB, { readonly: true });
  const rows = db.prepare(
    "SELECT day, slot, balance FROM openings WHERE day>=? AND day<=? ORDER BY day"
  ).all(fromDay, toDay) as { day: number; slot: number; balance: string }[];
  for (const r of rows) {
    if (!out.has(r.slot)) out.set(r.slot, new Map());
    out.get(r.slot)!.set(r.day, BigInt(r.balance));
  }
  db.close();
  return out;
}

function floors(slots: number): Map<number, bigint> {
  const out = new Map<number, bigint>();
  if (!fs.existsSync(OPERATOR_DB)) return out;
  const db = new Database(OPERATOR_DB, { readonly: true });
  for (const r of db.prepare("SELECT slot, floor FROM floors").all() as { slot: number; floor: string }[]) {
    out.set(r.slot, BigInt(r.floor));
  }
  db.close();
  return out;
}

async function history(read: ethers.Contract, slots: number, today: number, span: number): Promise<void> {
  const from = Math.max(0, today - span + 1);
  const hist = balanceHistory(slots, from, today);
  const flo = floors(slots);

  if (hist.size === 0) {
    console.log(`${C.dim}no balances yet in ${OPERATOR_DB}.`);
    console.log(`they appear once the operator closes its first day. balances are not`);
    console.log(`on chain — only commitments are — so this view reads the operator's`);
    console.log(`own records, which is the privacy property working.${C.off}`);
    return;
  }

  const days: number[] = [];
  for (let d = from; d <= today; d++) days.push(d);

  let head = `${C.head}slot  ` + days.map((d) => String(d).padStart(11)).join("") + `      floor   trend${C.off}`;
  console.log(head);

  for (const slot of [...hist.keys()].sort((a, b) => a - b)) {
    const row = hist.get(slot)!;
    const cells = days.map((d) => {
      const v = row.get(d);
      if (v === undefined) return "          -";
      const below = flo.has(slot) && v < flo.get(slot)!;
      return (below ? C.warn : "") + eur(v).padStart(11) + (below ? C.off : "");
    }).join("");

    const seen = days.map((d) => row.get(d)).filter((v) => v !== undefined) as bigint[];
    let trend = "";
    if (seen.length >= 2) {
      const delta = seen[seen.length - 1] - seen[0];
      const sign = delta > 0n ? `${C.ok}+` : delta < 0n ? `${C.warn}` : `${C.dim} `;
      trend = `${sign}${eur(delta)}${C.off}`;
    }
    const f = flo.has(slot) ? eur(flo.get(slot)!).padStart(11) : "          -";
    console.log(`${String(slot).padStart(4)}  ${cells}${f}  ${trend}`);
  }
  console.log(`${C.dim}      EUR at the opening of each day; red = under the floor, so barred from trading${C.off}`);
}

const STATES = ["Pending", "Closing", "Finalized", "Cancelled"];

async function readDay(read: ethers.Contract, day: number): Promise<DayRow> {
  const dc = await read.dayCloses(day);
  let sold = 0, bought = 0, opened = 0, rSum = 0, cSum = 0, priced = 0;

  for (let t = 0; t < SESSIONS; t++) {
    const s = await read.sessions(day, t);
    if (!s[6]) continue;
    opened += 1;
    sold += Number(s[0]);
    bought += Number(s[1]);
    if (Number(s[0]) > 0 || Number(s[1]) > 0) {
      rSum += Number(s[2]) / PRICE_SCALE;
      cSum += Number(s[3]) / PRICE_SCALE;
      priced += 1;
    }
  }

  return {
    day,
    state: STATES[Number(dc[0])] ?? String(dc[0]),
    opened,
    sold,
    bought,
    internal: Math.min(sold, bought),
    paidOut: dc[2] as bigint,
    paidIn: dc[3] as bigint,
    avgR: priced ? rSum / priced : 0,
    avgC: priced ? cSum / priced : 0,
  };
}

function balances(day: number, slots: number): { slot: number; balance: string; floor: string; below: boolean }[] {
  if (!fs.existsSync(OPERATOR_DB)) return [];
  const db = new Database(OPERATOR_DB, { readonly: true });
  const out: { slot: number; balance: string; floor: string; below: boolean }[] = [];
  for (let slot = 1; slot <= slots; slot++) {
    const b = db.prepare("SELECT balance FROM openings WHERE day=? AND slot=?").get(day, slot) as { balance: string } | undefined;
    const f = db.prepare("SELECT floor FROM floors WHERE slot=?").get(slot) as { floor: string } | undefined;
    if (!b) continue;
    const bal = BigInt(b.balance);
    const flo = f ? BigInt(f.floor) : 0n;
    out.push({ slot, balance: eur(bal), floor: eur(flo), below: bal < flo });
  }
  db.close();
  return out;
}

function ribbon(rows: { t: number; s: number; d: number }[]): string {
  const peak = Math.max(1, ...rows.map((r) => Math.max(r.s, r.d)));
  const up = rows.map((r) => (r.s === 0 ? " " : r.s / peak > 0.6 ? "█" : r.s / peak > 0.25 ? "▄" : "▁")).join("");
  const dn = rows.map((r) => (r.d === 0 ? " " : r.d / peak > 0.6 ? "█" : r.d / peak > 0.25 ? "▀" : "▔")).join("");
  return `  ${C.sell}${up}${C.off}  sold\n  ${C.buy}${dn}${C.off}  bought\n  ${C.dim}0h      3h      6h      9h      12h     15h     18h     21h${C.off}`;
}

async function main(): Promise<void> {
  const address = market();
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const read = new ethers.Contract(address, ABI, provider);

  const mode = process.argv[2] ?? "days";
  const arg = process.argv[3];

  if (mode === "watch") {
    const every = Number(arg ?? 10) * 1000;
    for (;;) {
      const day = Number(await read.currentDayId());
      const t = Number(await read.currentSessionIdx());
      const slots = Number(await read.prosumerCount());
      process.stdout.write("\x1b[2J\x1b[H");
      console.log(`${C.head}day ${day}, quarter-hour ${t}/96${C.off}   ${slots} prosumer(s)   ` +
        `${C.dim}${new Date().toLocaleTimeString()}  refresh every ${every / 1000}s, Ctrl-C to stop${C.off}`);
      console.log("");
      await history(read, slots, day, 6);
      console.log("");
      for (const d of [day, day - 1]) {
        if (d < 0) continue;
        const row = await readDay(read, d);
        const label = d === day ? "today  " : "settles next";
        console.log(`${C.head}day ${d}${C.off} ${C.dim}${label}${C.off}  ${row.state}  ` +
          `${row.opened}/96 sessions   ` +
          `offered ${kwh(row.sold)}  wanted ${kwh(row.bought)}  ` +
          `${C.ok}matched ${kwh(row.internal)} kWh${C.off}` +
          (row.bought > 0 ? `  (${Math.round((row.internal / row.bought) * 100)}% of demand)` : "") +
          (row.avgR ? `   sell ${row.avgR.toFixed(3)} buy ${row.avgC.toFixed(3)}` : ""));
      }
      await sleep(every);
    }
  }

  const today = Number(await read.currentDayId());
  const t = Number(await read.currentSessionIdx());
  const slots = Number(await read.prosumerCount());

  console.log(`${C.head}market${C.off} ${address}   day ${today}, quarter-hour ${t}/96   ${slots} prosumer(s)`);
  console.log("");

  if (mode === "history") {
    await history(read, slots, today, Number(arg ?? 10));
    return;
  }

  if (mode === "day") {
    const day = arg ? Number(arg) : today - 1;
    const rows: { t: number; s: number; d: number }[] = [];
    for (let i = 0; i < SESSIONS; i++) {
      const s = await read.sessions(day, i);
      rows.push({ t: i, s: s[6] ? Number(s[0]) : 0, d: s[6] ? Number(s[1]) : 0 });
    }
    const row = await readDay(read, day);
    console.log(`${C.head}day ${day}${C.off}  ${row.state}  ${row.opened}/96 sessions opened`);
    console.log("");
    console.log(ribbon(rows));
    console.log("");
    console.log(`  offered ${kwh(row.sold)} kWh   wanted ${kwh(row.bought)} kWh   ` +
      `matched locally ${C.ok}${kwh(row.internal)} kWh${C.off}   ` +
      `(${row.bought > 0 ? Math.round((row.internal / row.bought) * 100) : 0}% of demand)`);
    console.log(`  average price  sell ${row.avgR.toFixed(4)}  buy ${row.avgC.toFixed(4)} EUR/kWh`);
    console.log(`  settled        paid out ${eur(row.paidOut)}  paid in ${eur(row.paidIn)} EUR`);
    console.log("");

    const bals = balances(day, slots);
    if (bals.length === 0) {
      console.log(`  ${C.dim}no operator database at ${OPERATOR_DB}, so no balances.`);
      console.log(`  balances are not on chain — only commitments are. This view needs`);
      console.log(`  the operator's own records, which is the privacy property working.${C.off}`);
    } else {
      console.log(`  ${C.head}balances at the opening of day ${day}${C.off} ${C.dim}(operator-side, not public)${C.off}`);
      for (const b of bals) {
        const flag = b.below ? `${C.warn}below floor${C.off}` : "";
        console.log(`    slot ${String(b.slot).padStart(3)}   ${b.balance.padStart(12)} EUR   floor ${b.floor.padStart(10)}   ${flag}`);
      }
    }
    return;
  }

  const count = arg ? Number(arg) : 7;
  const rows: DayRow[] = [];
  for (let d = today; d > today - count && d >= 0; d--) rows.push(await readDay(read, d));

  const peak = Math.max(1, ...rows.map((r) => Math.max(r.sold, r.bought)));
  console.log(`${C.head}day     state       sess   offered      wanted     matched   sell    buy${C.off}`);
  for (const r of rows) {
    const colour = r.state === "Finalized" ? C.ok : r.state === "Cancelled" ? C.warn : C.dim;
    console.log(
      `${String(r.day).padEnd(8)}${colour}${r.state.padEnd(12)}${C.off}` +
      `${String(r.opened).padStart(4)}  ` +
      `${bar(r.sold, peak, 10, C.sell)}${kwh(r.sold).padStart(8)}  ` +
      `${bar(r.bought, peak, 10, C.buy)}${kwh(r.bought).padStart(8)}  ` +
      `${kwh(r.internal).padStart(8)}  ` +
      `${r.avgR ? r.avgR.toFixed(3) : "  -  "}  ${r.avgC ? r.avgC.toFixed(3) : "  -  "}`);
  }
  console.log(`${C.dim}        kWh; matched = min(offered, wanted), the part that never touched the grid${C.off}`);
  console.log("");

  const bals = balances(today - 1, slots);
  if (bals.length > 0) {
    console.log(`${C.head}balances at the opening of day ${today - 1}${C.off} ${C.dim}(operator-side, not public)${C.off}`);
    const peakBal = Math.max(...bals.map((b) => Number(b.balance)));
    for (const b of bals) {
      const flag = b.below ? `  ${C.warn}below floor${C.off}` : "";
      console.log(`  slot ${String(b.slot).padStart(3)}  ${bar(Number(b.balance), peakBal, 24, b.below ? C.warn : C.ok)} ${b.balance.padStart(12)} EUR${flag}`);
    }
  } else {
    console.log(`${C.dim}no operator database at ${OPERATOR_DB} — balances live there, not on chain.${C.off}`);
  }
}

main().catch((e) => {
  console.error(`${C.warn}${(e as Error).message}${C.off}`);
  process.exit(1);
});
