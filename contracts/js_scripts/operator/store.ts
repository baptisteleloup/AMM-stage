import Database from "better-sqlite3";
import fs from "node:fs";
import path from "node:path";
import { config } from "./config.js";

export class Store {
  db: Database.Database;

  constructor(dbPath: string = config.dbPath) {
    fs.mkdirSync(path.dirname(dbPath), { recursive: true });
    this.db = new Database(dbPath);
    this.db.pragma("journal_mode = WAL");
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS openings(
        day INTEGER NOT NULL, slot INTEGER NOT NULL,
        balance TEXT NOT NULL, blind TEXT NOT NULL, netput_blind TEXT NOT NULL,
        PRIMARY KEY(day, slot));
      CREATE TABLE IF NOT EXISTS floors(
        slot INTEGER PRIMARY KEY, floor TEXT NOT NULL, blind TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS participation(
        day INTEGER NOT NULL, slot INTEGER NOT NULL, yes INTEGER NOT NULL,
        PRIMARY KEY(day, slot));
      CREATE TABLE IF NOT EXISTS spend(
        day INTEGER NOT NULL, slot INTEGER NOT NULL, net TEXT NOT NULL,
        PRIMARY KEY(day, slot));
      CREATE TABLE IF NOT EXISTS alerts(
        day INTEGER NOT NULL, slot INTEGER NOT NULL, tier TEXT NOT NULL,
        PRIMARY KEY(day, slot, tier));
      CREATE TABLE IF NOT EXISTS dayblinds(
        day INTEGER NOT NULL, slot INTEGER NOT NULL,
        netput_blind TEXT NOT NULL, new_blind TEXT NOT NULL,
        PRIMARY KEY(day, slot));
      CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
    `);
  }

  blindOf(day: number, slot: number): bigint | null {
    const r = this.db.prepare("SELECT blind FROM openings WHERE day=? AND slot=?").get(day, slot) as { blind: string } | undefined;
    return r ? BigInt(r.blind) : null;
  }

  openingOf(day: number, slot: number): Opening | null {
    const r = this.db.prepare("SELECT balance, blind, netput_blind FROM openings WHERE day=? AND slot=?").get(day, slot) as { balance: string; blind: string; netput_blind: string } | undefined;
    return r ? { balance: BigInt(r.balance), blind: BigInt(r.blind), netputBlind: BigInt(r.netput_blind) } : null;
  }

  floorBlindOf(slot: number): bigint | null {
    const r = this.db.prepare("SELECT blind FROM floors WHERE slot=?").get(slot) as { blind: string } | undefined;
    return r ? BigInt(r.blind) : null;
  }

  dayBlinds(day: number, slot: number): { netputBlind: bigint; newBlind: bigint } | null {
    const r = this.db.prepare("SELECT netput_blind, new_blind FROM dayblinds WHERE day=? AND slot=?").get(day, slot) as { netput_blind: string; new_blind: string } | undefined;
    return r ? { netputBlind: BigInt(r.netput_blind), newBlind: BigInt(r.new_blind) } : null;
  }

  putDayBlinds(day: number, slot: number, netputBlind: bigint, newBlind: bigint): void {
    this.db.prepare("INSERT OR REPLACE INTO dayblinds(day,slot,netput_blind,new_blind) VALUES(?,?,?,?)")
      .run(day, slot, netputBlind.toString(), newBlind.toString());
  }

  metaGet(k: string): string | null {
    const r = this.db.prepare("SELECT v FROM meta WHERE k=?").get(k) as { v: string } | undefined;
    return r ? r.v : null;
  }

  metaSet(k: string, v: string): void {
    this.db.prepare("INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)").run(k, v);
  }

  balanceOf(day: number, slot: number): bigint | null {
    const r = this.db.prepare("SELECT balance FROM openings WHERE day=? AND slot=?").get(day, slot) as { balance: string } | undefined;
    return r ? BigInt(r.balance) : null;
  }

  putOpening(day: number, slot: number, balance: bigint, blind: bigint, netputBlind: bigint): void {
    this.db.prepare("INSERT OR REPLACE INTO openings(day,slot,balance,blind,netput_blind) VALUES(?,?,?,?,?)")
      .run(day, slot, balance.toString(), blind.toString(), netputBlind.toString());
  }

  floorOf(slot: number): bigint | null {
    const r = this.db.prepare("SELECT floor FROM floors WHERE slot=?").get(slot) as { floor: string } | undefined;
    return r ? BigInt(r.floor) : null;
  }

  putFloor(slot: number, floor: bigint, blind: bigint): void {
    this.db.prepare("INSERT OR REPLACE INTO floors(slot,floor,blind) VALUES(?,?,?)")
      .run(slot, floor.toString(), blind.toString());

    const dir = path.join(config.receiptsDir, `slot-${slot}`);
    fs.mkdirSync(dir, { recursive: true });
    const packet = {
      slot,
      floor: floor.toString(),
      blind: "0x" + blind.toString(16).padStart(64, "0"),
    };
    fs.writeFileSync(path.join(dir, "floor-opening.json"), JSON.stringify(packet, null, 2));
  }

  participationOf(day: number, slot: number): boolean | null {
    const r = this.db.prepare("SELECT yes FROM participation WHERE day=? AND slot=?").get(day, slot) as { yes: number } | undefined;
    return r === undefined ? null : r.yes === 1;
  }

  putParticipation(day: number, slot: number, yes: boolean): void {
    this.db.prepare("INSERT OR IGNORE INTO participation(day,slot,yes) VALUES(?,?,?)")
      .run(day, slot, yes ? 1 : 0);
  }

  netSpend(day: number, slot: number): bigint {
    const r = this.db.prepare("SELECT net FROM spend WHERE day=? AND slot=?").get(day, slot) as { net: string } | undefined;
    return r ? BigInt(r.net) : 0n;
  }

  addSpend(day: number, slot: number, delta: bigint): bigint {
    const next = this.netSpend(day, slot) + delta;
    this.db.prepare("INSERT OR REPLACE INTO spend(day,slot,net) VALUES(?,?,?)")
      .run(day, slot, next.toString());
    return next;
  }

  alertSent(day: number, slot: number, tier: string): boolean {
    return !!this.db.prepare("SELECT 1 FROM alerts WHERE day=? AND slot=? AND tier=?").get(day, slot, tier);
  }

  markAlert(day: number, slot: number, tier: string): void {
    this.db.prepare("INSERT OR IGNORE INTO alerts(day,slot,tier) VALUES(?,?,?)").run(day, slot, tier);
  }
}

export type Opening = { balance: bigint; blind: bigint; netputBlind: bigint };
