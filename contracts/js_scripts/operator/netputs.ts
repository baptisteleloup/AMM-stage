// Metering sources: where the operator reads each member's (sell, buy) per session, in Wh.
// NetputSource is the interface; NiceSource reads a JSON file of profiles by member name,
// SyntheticSource makes simple curves when no file is given.

import fs from "node:fs";

export type Netput = { sell: bigint; buy: bigint }; // Wh offered and demanded in one session
export type SessionBatch = Map<number, Netput>; // slot => position

export interface NetputSource {
  read(day: number, t: number): Promise<SessionBatch>; // positions metered in session t of `day`
}

// Session t on chain prices the meter reading of the previous quarter-hour (t - 1, or 95 of the day before).
export function physicalOf(day: number, t: number): { day: number; t: number } {
  return t === 0 ? { day: day - 1, t: 95 } : { day, t: t - 1 };
}

type Pair = [number, number]; // [sell, buy] in Wh

// Layout of the netputs file.
type NiceFile = {
  sessions: number; // sessions per day, 96
  unit: string; // must be "Wh"
  baseDay?: number; // day number of the file's first day
  profiles: Record<string, Pair[] | Record<string, Pair[]>>; // name => one day, or { dayIndex: day }
};

// Normalises a profile to a list of days, in day-index order.
function asDayCurves(profile: Pair[] | Record<string, Pair[]>): Pair[][] {
  if (Array.isArray(profile)) return [profile]; // single day, repeated every day
  return Object.keys(profile)
    .map(Number)
    .filter(Number.isInteger) // ignore non-numeric keys
    .sort((a, b) => a - b)
    .map((k) => profile[String(k)]);
}

// File-based source. The days of the file are replayed in a loop from baseDay on.
export class NiceSource implements NetputSource {
  private curves: Map<number, Pair[][]> = new Map(); // slot => days of (sell, buy)
  private sessions: number;
  private baseDay: number;

  constructor(netputsJsonPath: string, slotByName: Map<string, number>) {
    const raw = JSON.parse(fs.readFileSync(netputsJsonPath, "utf-8")) as NiceFile;
    if (raw.unit !== "Wh") throw new Error(`netputs file unit is ${raw.unit}, expected Wh`);
    this.sessions = raw.sessions;
    this.baseDay = raw.baseDay ?? 0;
    for (const [name, profile] of Object.entries(raw.profiles)) {
      const slot = slotByName.get(name);
      if (slot && slot > 0) this.curves.set(slot, asDayCurves(profile)); // only registered members
    }
  }

  async read(day: number, t: number): Promise<SessionBatch> {
    const batch: SessionBatch = new Map();
    if (day < 0 || t < 0 || t >= this.sessions) return batch;
    for (const [slot, days] of this.curves) {
      if (days.length === 0) continue;
      const n = days.length;
      const idx = (((day - this.baseDay) % n) + n) % n; // wraps around the file's days
      const [sell, buy] = days[idx][t] ?? [0, 0];
      batch.set(slot, { sell: BigInt(sell), buy: BigInt(buy) });
    }
    return batch;
  }
}

// Synthetic source: members cycle through a consumer, a solar producer and a wind producer.
export class SyntheticSource implements NetputSource {
  constructor(private slots: number[]) {}

  async read(day: number, t: number): Promise<SessionBatch> {
    const batch: SessionBatch = new Map();
    if (day < 0 || t < 0) return batch;
    for (let i = 0; i < this.slots.length; i++) {
      const slot = this.slots[i];
      const kind = i % 3;
      if (kind === 0) {
        const buy = 120 + Math.round(60 * Math.abs(Math.sin((2 * Math.PI * (t + 4)) / 96))); // consumer, 120 to 180 Wh
        batch.set(slot, { sell: 0n, buy: BigInt(buy) });
      } else if (kind === 1) {
        const daylight = Math.max(0, Math.sin((Math.PI * (t - 28)) / 40)); // solar bell from 7:00 to 17:00
        batch.set(slot, { sell: BigInt(Math.round(500 * daylight)), buy: 0n });
      } else {
        const wind = 80 + ((day * 31 + t * 7 + i * 13) % 120); // wind, deterministic pseudo-noise
        batch.set(slot, { sell: BigInt(wind), buy: 0n });
      }
    }
    return batch;
  }
}
