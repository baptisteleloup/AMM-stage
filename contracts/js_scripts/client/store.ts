// The client's local state, one JSON file (CLIENT_STORE, default <CLIENT_DATA_DIR>/state.json):
// slot, floor opening, per-day balance openings, session receipts, check verdicts and cursors.
// Every setter writes the file at once, so a restart loses nothing.

import fs from "node:fs";
import path from "node:path";
import { config } from "./config.js";

// Opening of a day's balance commitment, from the day-close packet.
export type Opening = {
  balance: string;
  blind: string;
  netputBlind: string;
};

// Opening of the floor commitment.
export type FloorOpening = {
  floor: string;
  blind: string;
};

// One verified session receipt.
export type SessionRow = {
  day: number;
  t: number;
  sell: string;
  buy: string;
  sig?: string;
};

type State = {
  slot: number;
  address: string;
  registeredAt: number | null; // block time of registration
  floor: FloorOpening | null;
  openings: Record<string, Opening>; // by day
  sessions: Record<string, SessionRow>; // by "day:t"
  verdicts: Record<string, unknown>; // results of the checks, by key
  cursors: Record<string, number>; // progress markers of the watch loop
};

const EMPTY: State = {
  slot: 0,
  address: "",
  registeredAt: null,
  floor: null,
  openings: {},
  sessions: {},
  verdicts: {},
  cursors: {},
};

export class Store {
  private state: State;

  constructor(private file: string = config.storePath) {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    if (fs.existsSync(this.file)) {
      // fill fields missing from older files
      this.state = { ...EMPTY, ...JSON.parse(fs.readFileSync(this.file, "utf-8")) };
    } else {
      this.state = { ...EMPTY };
      this.flush(); // create the file on first run
    }
  }

  private flush(): void {
    fs.writeFileSync(this.file, JSON.stringify(this.state, null, 2));
  }

  get slot(): number {
    return this.state.slot;
  }

  get address(): string {
    return this.state.address;
  }

  setIdentity(slot: number, address: string, at: number): void {
    this.state.slot = slot;
    this.state.address = address;
    this.state.registeredAt = at;
    this.flush();
  }

  setFloor(f: FloorOpening): void {
    this.state.floor = f;
    this.flush();
  }

  floor(): FloorOpening | null {
    return this.state.floor;
  }

  putOpening(day: number, o: Opening): void {
    this.state.openings[String(day)] = o;
    this.flush();
  }

  opening(day: number): Opening | null {
    return this.state.openings[String(day)] ?? null;
  }

  putSession(row: SessionRow): void {
    this.state.sessions[`${row.day}:${row.t}`] = row; // keyed "day:t"
    this.flush();
  }

  session(day: number, t: number): SessionRow | null {
    return this.state.sessions[`${day}:${t}`] ?? null;
  }

  sessionsOf(day: number): SessionRow[] {
    return Object.values(this.state.sessions).filter((r) => r.day === day).sort((a, b) => a.t - b.t);
  }

  putVerdict(key: string, v: unknown): void {
    this.state.verdicts[key] = v;
    this.flush();
  }

  verdict(key: string): unknown {
    return this.state.verdicts[key];
  }

  cursor(name: string): number {
    return this.state.cursors[name] ?? 0;
  }

  setCursor(name: string, v: number): void {
    this.state.cursors[name] = v;
    this.flush();
  }
}
