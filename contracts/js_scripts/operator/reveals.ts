// Recourse answers. Follows DataRequested events from a cursor kept in the store. Stage 1:
// posts the member's receipts and opening, encrypted to its key. Stage 2: proves the balance
// opening with the reveal circuit and posts it with clearReveal.

import fs from "node:fs";
import path from "node:path";
import { encrypt } from "eciesjs";
import { config } from "./config.js";
import { commitBalance } from "../scenario.js";
import type { Chain } from "./chain.js";
import type { Store } from "./store.js";
import type { Prover } from "./prover.js";

export class Reveals {
  private pending = new Set<string>(); // reveal jobs already logged as queued

  constructor(private chain: Chain, private store: Store, private prover: Prover) {}

  async tick(): Promise<void> {
    const cursor = Number(this.store.metaGet("revealCursor") ?? "0"); // last block fully handled
    const latest = await this.chain.blockNumber();
    if (cursor >= latest) return;

    const events = await this.chain.dataRequests(cursor + 1);
    let last = cursor;
    let blocked = false;

    if (events.length === 0) {
      this.store.metaSet("revealCursor", String(latest)); // nothing to answer
      return;
    }

    for (const ev of events) {
      let served = true;
      try {
        served = ev.stage === 1
          ? await this.stage1(ev.day, ev.slot)
          : await this.stage2(ev.day, ev.slot);
      } catch (e) {
        console.error(`[reveals] day=${ev.day} slot=${ev.slot} stage=${ev.stage}:`, (e as Error).message);
        served = false; // retried next tick instead of being skipped by the cursor
      }
      
      if (!served) blocked = true; // a request still waits: do not move the cursor past it
      if (!blocked && ev.block > last) last = ev.block;
    }
    if (!blocked) last = latest; // all served: jump to the latest block
    if (last > cursor) this.store.metaSet("revealCursor", String(last));
  }

  // Stage 1 payload: every receipt of the member for that day plus its stored opening.
  private blobFor(day: number, slot: number): Buffer {
    const dir = path.join(config.receiptsDir, `slot-${slot}`, `day-${day}`);
    const files: Record<string, unknown> = {};
    if (fs.existsSync(dir)) {
      for (const f of fs.readdirSync(dir)) {
        if (f.endsWith(".json")) files[f] = JSON.parse(fs.readFileSync(path.join(dir, f), "utf-8"));
      }
    }
    const opening = this.store.openingOf(day, slot);
    return Buffer.from(
      JSON.stringify(
        { day, slot, receipts: files, opening },
        (_k, v) => (typeof v === "bigint" ? v.toString() : v), // JSON has no bigint
      ),
      "utf-8",
    );
  }

  private async stage1(day: number, slot: number): Promise<boolean> {
    const r = await this.chain.revealOf(day, slot);
    if (r.stage1Done) return true; // already answered
    if (!this.store.openingOf(day, slot)) return false; // openings not stored yet: answer once the day is proven
    const pk = await this.chain.encryptionKeyOf(slot);
    // ECIES to the key given at registration
    const cipher = encrypt(Buffer.from(pk.slice(2), "hex"), this.blobFor(day, slot));
    await this.chain.postEncryptedData(day, slot, "0x" + Buffer.from(cipher).toString("hex"));
    console.log(`[reveals] stage 1 served: day=${day} slot=${slot}`);
    return true;
  }

  private async stage2(day: number, slot: number): Promise<boolean> {
    const r = await this.chain.revealOf(day, slot);
    if (r.stage2Done) return true; // already answered
    const opening = this.store.openingOf(day, slot);
    if (!opening) return false; // openings not stored yet: check again next tick

    const jobId = `reveal:${day}:${slot}`;
    const job = this.prover.state(jobId);

    if (job.state === "idle") { // start the proof in the background
      const commitment = await commitBalance(opening.balance, opening.blind);
      this.prover.requestReveal(jobId, commitment, opening.balance, opening.blind);
      if (!this.pending.has(jobId)) {
        this.pending.add(jobId);
        console.log(`[reveals] stage 2 queued for proving: day=${day} slot=${slot}`);
      }
      return false;
    }
    if (job.state === "running") return false; // check again next tick
    if (job.state === "failed") { // cleared so the next tick retries
      this.prover.clear(jobId);
      this.pending.delete(jobId);
      console.error(`[reveals] stage 2 proof failed: day=${day} slot=${slot}: ${job.error.slice(0, 120)}`);
      return false;
    }

    await this.chain.clearReveal(day, slot, opening.balance, job.proof);
    this.prover.clear(jobId);
    this.pending.delete(jobId);
    console.log(`[reveals] stage 2 served: day=${day} slot=${slot} bal=${opening.balance} (proof took ${(job.ms / 1000).toFixed(1)}s)`);
    return true;
  }
}
