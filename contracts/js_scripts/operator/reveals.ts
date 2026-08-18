import fs from "node:fs";
import path from "node:path";
import { encrypt } from "eciesjs";
import { config } from "./config.js";
import { commitBalance } from "../scenario.js";
import type { Chain } from "./chain.js";
import type { Store } from "./store.js";
import type { Prover } from "./prover.js";

export class Reveals {
  // Requests whose proof is in flight. The cursor is only advanced past a
  // request once it is served or definitively abandoned, so nothing is lost if
  // the daemon restarts mid-proof.
  private pending = new Set<string>();

  constructor(private chain: Chain, private store: Store, private prover: Prover) {}

  async tick(): Promise<void> {
    const cursor = Number(this.store.metaGet("revealCursor") ?? "0");
    const latest = await this.chain.blockNumber();
    if (cursor >= latest) return;

    const events = await this.chain.dataRequests(cursor + 1);
    let last = cursor;
    let blocked = false;

    // Nothing asked in the blocks scanned: move the cursor to the tip so the
    // next tick does not scan them again. Without this the scan restarts from
    // the same block forever, grows with the chain, and by itself is enough to
    // push a tick past the session period — the sessions then arrive late, one
    // is missed, and the day can no longer be proven.
    if (events.length === 0) {
      this.store.metaSet("revealCursor", String(latest));
      return;
    }

    for (const ev of events) {
      let served = true;
      try {
        // Stage 1 is a hash and a transaction: cheap, done here and now.
        // Stage 2 needs a proof, so it is handed to the prover and collected on
        // a later tick. Either way this method returns promptly.
        served = ev.stage === 1
          ? await this.stage1(ev.day, ev.slot)
          : await this.stage2(ev.day, ev.slot);
      } catch (e) {
        console.error(`[reveals] day=${ev.day} slot=${ev.slot} stage=${ev.stage}:`, (e as Error).message);
      }
      // Do not step the cursor past a request still waiting on its proof, or a
      // restart would forget it was ever asked.
      if (!served) blocked = true;
      if (!blocked && ev.block > last) last = ev.block;
    }
    // Everything scanned was served: the cursor can go all the way to the tip,
    // not just to the last event. Something still pending keeps it just before
    // that request so it is seen again next tick.
    if (!blocked) last = latest;
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
    // The opening holds a balance and blinding factors as BigInt, which
    // JSON.stringify refuses outright. Without this replacer the whole disclosure
    // fails before anything is encrypted — the prosumer asks, nothing is ever
    // published, and the request stays open. Decimal strings are also what the
    // client's own receipt files use, so it reads them back unchanged.
    return Buffer.from(
      JSON.stringify(
        { day, slot, receipts: files, opening },
        (_k, v) => (typeof v === "bigint" ? v.toString() : v),
      ),
      "utf-8",
    );
  }

  private async stage1(day: number, slot: number): Promise<boolean> {
    const r = await this.chain.revealOf(day, slot);
    if (r.stage1Done) return true;
    const pk = await this.chain.encryptionKeyOf(slot);
    const cipher = encrypt(Buffer.from(pk.slice(2), "hex"), this.blobFor(day, slot));
    await this.chain.postEncryptedData(day, slot, "0x" + Buffer.from(cipher).toString("hex"));
    console.log(`[reveals] stage 1 served: day=${day} slot=${slot}`);
    return true;
  }

  private async stage2(day: number, slot: number): Promise<boolean> {
    const r = await this.chain.revealOf(day, slot);
    if (r.stage2Done) return true;
    const opening = this.store.openingOf(day, slot);
    if (!opening) throw new Error("no stored opening for this (day, slot)");

    const jobId = `reveal:${day}:${slot}`;
    const job = this.prover.state(jobId);

    if (job.state === "idle") {
      const commitment = await commitBalance(opening.balance, opening.blind);
      this.prover.requestReveal(jobId, commitment, opening.balance, opening.blind);
      if (!this.pending.has(jobId)) {
        this.pending.add(jobId);
        console.log(`[reveals] stage 2 queued for proving: day=${day} slot=${slot}`);
      }
      return false;
    }
    if (job.state === "running") return false;
    if (job.state === "failed") {
      this.prover.clear(jobId);
      this.pending.delete(jobId);
      console.error(`[reveals] stage 2 proof failed: day=${day} slot=${slot} — ${job.error.slice(0, 120)}`);
      return false;
    }

    await this.chain.clearReveal(day, slot, opening.balance, job.proof);
    this.prover.clear(jobId);
    this.pending.delete(jobId);
    console.log(`[reveals] stage 2 served: day=${day} slot=${slot} bal=${opening.balance} (proof took ${(job.ms / 1000).toFixed(1)}s)`);
    return true;
  }
}
