import fs from "node:fs";

export type Netput = { sell: bigint; buy: bigint };
export type SessionBatch = Map<number, Netput>;

export interface NetputSource {
  read(day: number, t: number): Promise<SessionBatch>;
}

export function physicalOf(day: number, t: number): { day: number; t: number } {
  return t === 0 ? { day: day - 1, t: 95 } : { day, t: t - 1 };
}

type NiceFile = {
  sessions: number;
  unit: string;
  profiles: Record<string, [number, number][]>;
};

export class NiceSource implements NetputSource {
  private curves: Map<number, [number, number][]> = new Map();
  private sessions: number;

  constructor(netputsJsonPath: string, slotByName: Map<string, number>) {
    const raw = JSON.parse(fs.readFileSync(netputsJsonPath, "utf-8")) as NiceFile;
    if (raw.unit !== "Wh") throw new Error(`netputs file unit is ${raw.unit}, expected Wh`);
    this.sessions = raw.sessions;
    for (const [name, curve] of Object.entries(raw.profiles)) {
      const slot = slotByName.get(name);
      if (slot && slot > 0) this.curves.set(slot, curve);
    }
  }

  async read(day: number, t: number): Promise<SessionBatch> {
    const batch: SessionBatch = new Map();
    if (day < 0 || t < 0 || t >= this.sessions) return batch;
    for (const [slot, curve] of this.curves) {
      const [sell, buy] = curve[t] ?? [0, 0];
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
