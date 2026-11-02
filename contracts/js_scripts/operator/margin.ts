// Margin calls. After each session, tracks every member's net spend of the day and writes an
// alert (receipts.ts) when its projected balance nears or crosses its floor. Off-chain only.

import { config } from "./config.js";
import type { Chain } from "./chain.js";
import type { Store } from "./store.js";
import type { Receipts } from "./receipts.js";
import type { SessionBatch } from "./netputs.js";

export class Margin {
  constructor(private chain: Chain, private store: Store, private receipts: Receipts) {}

  // Called right after session t of `day` is opened, with the positions it priced.
  async update(day: number, t: number, batch: SessionBatch): Promise<void> {
    const sess = await this.chain.session(day, t);
    if (!sess.opened) return;
    const r = BigInt(sess.priceR); // seller rate as stored on chain
    const c = BigInt(sess.priceC); // buyer rate
    for (const [slot, np] of batch) {
      const delta = np.buy * c - np.sell * r; // net cost of this session, internal units
      const net = this.store.addSpend(day, slot, delta); // net cost so far today
      const bal = this.store.balanceOf(day - 1, slot); // opening balance of the day
      const floor = this.store.floorOf(slot);
      if (bal === null || floor === null) continue; // nothing to compare against yet
      const projected = bal - (net > 0n ? net : 0n); // gains are not counted before settlement
      this.check(day, slot, projected, floor, "critical", config.marginCritNum);
      this.check(day, slot, projected, floor, "warning", config.marginWarnNum);
    }
  }

  // Writes one alert per day, slot and tier when projected < floor x num / den.
  private check(day: number, slot: number, projected: bigint, floor: bigint, tier: string, num: bigint): void {
    if (projected * config.marginDen >= floor * num) return; // above the threshold
    if (this.store.alertSent(day, slot, tier)) return; // already alerted today
    this.store.markAlert(day, slot, tier);
    this.receipts.writeAlert(day, slot, tier, projected, floor);
  }
}
