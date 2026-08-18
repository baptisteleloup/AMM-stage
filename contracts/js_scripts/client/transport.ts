import fs from "node:fs";
import path from "node:path";
import { config } from "./config.js";

export type RawSessionReceipt = {
  day: number;
  t: number;
  slot: number;
  sell: string;
  buy: string;
  sig: string;
};

export type RawDayClosePacket = {
  day: number;
  slot: number;
  newBalance: string;
  newBlind: string;
  netputBlind: string;
  sig: string;
};

export type RawFloorOpening = {
  slot: number;
  floor: string;
  blind: string;
  sig?: string;
};

export interface Transport {
  session(slot: number, day: number, t: number): Promise<RawSessionReceipt | null>;
  dayClose(slot: number, day: number): Promise<RawDayClosePacket | null>;
  floorOpening(slot: number): Promise<RawFloorOpening | null>;
}

class FsTransport implements Transport {
  private dir(slot: number, day: number): string {
    return path.join(config.receiptsDir, `slot-${slot}`, `day-${day}`);
  }

  private read<T>(file: string): T | null {
    if (!fs.existsSync(file)) return null;
    try {
      return JSON.parse(fs.readFileSync(file, "utf-8")) as T;
    } catch {
      return null;
    }
  }

  async session(slot: number, day: number, t: number): Promise<RawSessionReceipt | null> {
    return this.read<RawSessionReceipt>(path.join(this.dir(slot, day), `t-${t}.json`));
  }

  async dayClose(slot: number, day: number): Promise<RawDayClosePacket | null> {
    return this.read<RawDayClosePacket>(path.join(this.dir(slot, day), "day-close.json"));
  }

  async floorOpening(slot: number): Promise<RawFloorOpening | null> {
    return this.read<RawFloorOpening>(path.join(config.receiptsDir, `slot-${slot}`, "floor-opening.json"));
  }
}

class HttpTransport implements Transport {
  private async get<T>(suffix: string): Promise<T | null> {
    const url = `${config.receiptsUrl.replace(/\/$/, "")}/${suffix}`;
    const res = await fetch(url);
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`transport ${res.status} on ${suffix}`);
    return (await res.json()) as T;
  }

  async session(slot: number, day: number, t: number): Promise<RawSessionReceipt | null> {
    return this.get<RawSessionReceipt>(`slot-${slot}/day-${day}/t-${t}.json`);
  }

  async dayClose(slot: number, day: number): Promise<RawDayClosePacket | null> {
    return this.get<RawDayClosePacket>(`slot-${slot}/day-${day}/day-close.json`);
  }

  async floorOpening(slot: number): Promise<RawFloorOpening | null> {
    return this.get<RawFloorOpening>(`slot-${slot}/floor-opening.json`);
  }
}

export function makeTransport(): Transport {
  if (config.transport === "http") {
    if (!config.receiptsUrl) throw new Error("RECEIPT_TRANSPORT=http requires RECEIPTS_URL");
    return new HttpTransport();
  }
  return new FsTransport();
}
