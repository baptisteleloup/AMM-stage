// How the operator's receipts reach the client: read from a folder (fs, RECEIPTS_DIR) or fetched
// over HTTP (RECEIPTS_URL). Both use the layout slot-<n>/day-<d>/t-<t>.json, day-close.json,
// and slot-<n>/floor-opening.json. Signatures are checked in receipts.ts.

import fs from "node:fs";
import path from "node:path";
import { config } from "./config.js";

// Signed per-session receipt: the member's position in session t.
export type RawSessionReceipt = {
  day: number;
  t: number;
  slot: number;
  sell: string;
  buy: string;
  sig: string;
};

// Signed day-close packet: the new balance and the blindings that open the day's commitments.
export type RawDayClosePacket = {
  day: number;
  slot: number;
  newBalance: string;
  newBlind: string;
  netputBlind: string; // seed of the position commitment
  sig: string;
};

// Opening of the member's floor commitment.
export type RawFloorOpening = {
  slot: number;
  floor: string;
  blind: string;
  sig?: string; // optional
};

// Common interface; null means not published yet.
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
    if (!fs.existsSync(file)) return null; // not published yet
    try {
      return JSON.parse(fs.readFileSync(file, "utf-8")) as T;
    } catch {
      return null; // half-written file: retry at the next poll
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
    const url = `${config.receiptsUrl.replace(/\/$/, "")}/${suffix}`; // base URL without trailing slash
    const res = await fetch(url);
    if (res.status === 404) return null; // not published yet
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
  if (config.transport === "http") { // RECEIPT_TRANSPORT=http
    if (!config.receiptsUrl) throw new Error("RECEIPT_TRANSPORT=http requires RECEIPTS_URL");
    return new HttpTransport();
  }
  return new FsTransport();
}
