import fs from "node:fs";
import path from "node:path";
import { encrypt } from "eciesjs";
import { config } from "./config.js";
import { commitBalance } from "../scenario.js";
import type { Chain } from "./chain.js";
import type { Store } from "./store.js";
import { proveReveal } from "./prove.js";

export class Reveals {
  constructor(private chain: Chain, private store: Store) {}

  async tick(): Promise<void> {
    const cursor = Number(this.store.metaGet("revealCursor") ?? "0");
    const events = await this.chain.dataRequests(cursor + 1);
    let last = cursor;
    for (const ev of events) {
      try {
        if (ev.stage === 1) await this.stage1(ev.day, ev.slot);
        else await this.stage2(ev.day, ev.slot);
      } catch (e) {
        console.error(`[reveals] day=${ev.day} slot=${ev.slot} stage=${ev.stage}:`, (e as Error).message);
      }
      if (ev.block > last) last = ev.block;
    }
    if (last > cursor) this.store.metaSet("revealCursor", String(last));
  }

  private blobFor(day: number, slot: number): Buffer {
    const dir = path.join(config.receiptsDir, `slot-${slot}`, `day-${day}`);
    const files: Record<string, unknown> = {};
    if (fs.existsSync(dir)) {
      for (const f of fs.readdirSync(dir)) {
        if (f.endsWith(".json")) files[f] = JSON.parse(fs.readFileSync(path.join(dir, f), "utf-8"));
      }
    }
    const opening = this.store.openingOf(day, slot);
    return Buffer.from(JSON.stringify({ day, slot, receipts: files, opening }), "utf-8");
  }

  private async stage1(day: number, slot: number): Promise<void> {
    const r = await this.chain.revealOf(day, slot);
    if (r.stage1Done) return;
    const pk = await this.chain.encryptionKeyOf(slot);
    const cipher = encrypt(Buffer.from(pk.slice(2), "hex"), this.blobFor(day, slot));
    await this.chain.postEncryptedData(day, slot, "0x" + Buffer.from(cipher).toString("hex"));
    console.log(`[reveals] stage 1 served: day=${day} slot=${slot}`);
  }

  private async stage2(day: number, slot: number): Promise<void> {
    const r = await this.chain.revealOf(day, slot);
    if (r.stage2Done) return;
    const opening = this.store.openingOf(day, slot);
    if (!opening) throw new Error("no stored opening for this (day, slot)");
    const commitment = await commitBalance(opening.balance, opening.blind);
    const proof = await proveReveal(commitment, opening.balance, opening.blind);
    await this.chain.clearReveal(day, slot, opening.balance, proof);
    console.log(`[reveals] stage 2 served: day=${day} slot=${slot} bal=${opening.balance}`);
  }
}
