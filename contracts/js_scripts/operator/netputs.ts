import fs from "node:fs";

export type Netput = { sell: bigint; buy: bigint };
export type SessionBatch = Map<number, Netput>;

export interface NetputSource {
  read(day: number, t: number): Promise<SessionBatch>;
}

export function physicalOf(day: number, t: number): { day: number; t: number } {
  return t === 0 ? { day: day - 1, t: 95 } : { day, t: t - 1 };
}

type Pair = [number, number];

type NiceFile = {
  sessions: number;
  unit: string;
  baseDay?: number;
  profiles: Record<string, Pair[] | Record<string, Pair[]>>;
};

function asDayCurves(profile: Pair[] | Record<string, Pair[]>): Pair[][] {
  if (Array.isArray(profile)) return [profile];
  return Object.keys(profile)
    .map(Number)
    .filter(Number.isInteger)
    .sort((a, b) => a - b)
    .map((k) => profile[String(k)]);
}

export class NiceSource implements NetputSource {
  private curves: Map<number, Pair[][]> = new Map();
  private sessions: number;
  private baseDay: number;

  constructor(netputsJsonPath: string, slotByName: Map<string, number>) {
    const raw = JSON.parse(fs.readFileSync(netputsJsonPath, "utf-8")) as NiceFile;
    if (raw.unit !== "Wh") throw new Error(`netputs file unit is ${raw.unit}, expected Wh`);
    this.sessions = raw.sessions;
    this.baseDay = raw.baseDay ?? 0;
    for (const [name, profile] of Object.entries(raw.profiles)) {
      const slot = slotByName.get(name);
      if (slot && slot > 0) this.curves.set(slot, asDayCurves(profile));
    }
  }

  async read(day: number, t: number): Promise<SessionBatch> {
    const batch: SessionBatch = new Map();
    if (day < 0 || t < 0 || t >= this.sessions) return batch;
    for (const [slot, days] of this.curves) {
      if (days.length === 0) continue;
      const n = days.length;
      const idx = (((day - this.baseDay) % n) + n) % n;
      const [sell, buy] = days[idx][t] ?? [0, 0];
      batch.set(slot, { sell: BigInt(sell), buy: BigInt(buy) });
    }
    return batch;
  }
}

export class SyntheticSource implements NetputSource {
  constructor(private slots: number[]) {}

  async read(day: number, t: number): Promise<SessionBatch> {
    const batch: SessionBatch = new Map();
    if (day < 0 || t < 0) return batch;
    for (let i = 0; i < this.slots.length; i++) {
      const slot = this.slots[i];
      const kind = i % 3;
      if (kind === 0) {
        const buy = 120 + Math.round(60 * Math.abs(Math.sin((2 * Math.PI * (t + 4)) / 96)));
        batch.set(slot, { sell: 0n, buy: BigInt(buy) });
      } else if (kind === 1) {
        const daylight = Math.max(0, Math.sin((Math.PI * (t - 28)) / 40));
        batch.set(slot, { sell: BigInt(Math.round(500 * daylight)), buy: 0n });
      } else {
        const wind = 80 + ((day * 31 + t * 7 + i * 13) % 120);
        batch.set(slot, { sell: BigInt(wind), buy: 0n });
      }
    }
    return batch;
  }
}
