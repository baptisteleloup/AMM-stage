import fs from "node:fs";
import path from "node:path";
import { config, SESSIONS } from "./config.js";

export type MeterDay = {
  day: number;
  sell: bigint[];
  buy: bigint[];
};

type FlatFile = { day?: number; sell: (string | number)[]; buy: (string | number)[] };
type RowFile = { day?: number; sessions: Record<string, { sell: string | number; buy: string | number }> };

function zeros(): bigint[] {
  return Array(SESSIONS).fill(0n);
}

function parse(raw: unknown, day: number): MeterDay {
  const sell = zeros();
  const buy = zeros();

  if (raw && typeof raw === "object" && "sessions" in (raw as RowFile)) {
    const f = raw as RowFile;
    for (const [k, v] of Object.entries(f.sessions)) {
      const t = Number(k);
      if (!Number.isInteger(t) || t < 0 || t >= SESSIONS) continue;
      sell[t] = BigInt(v.sell ?? 0);
      buy[t] = BigInt(v.buy ?? 0);
    }
    return { day: f.day ?? day, sell, buy };
  }

  const f = raw as FlatFile;
  if (!Array.isArray(f.sell) || !Array.isArray(f.buy)) {
    throw new Error("meter file: expected {sell:[],buy:[]} or {sessions:{t:{sell,buy}}}");
  }
  if (f.sell.length !== SESSIONS || f.buy.length !== SESSIONS) {
    throw new Error(`meter file: expected ${SESSIONS} entries, got sell=${f.sell.length} buy=${f.buy.length}`);
  }
  for (let t = 0; t < SESSIONS; t++) {
    sell[t] = BigInt(f.sell[t] ?? 0);
    buy[t] = BigInt(f.buy[t] ?? 0);
  }
  return { day: f.day ?? day, sell, buy };
}

export function readMeter(day: number): MeterDay | null {
  if (!config.meterPath) return null;
  const candidates = fs.existsSync(config.meterPath) && fs.statSync(config.meterPath).isDirectory()
    ? [path.join(config.meterPath, `meter-${day}.json`), path.join(config.meterPath, `day-${day}.json`)]
    : [config.meterPath];

  for (const f of candidates) {
    if (!fs.existsSync(f)) continue;
    const raw = JSON.parse(fs.readFileSync(f, "utf-8")) as unknown;
    const m = parse(raw, day);
    if (m.day !== day) continue;
    return m;
  }
  return null;
}
