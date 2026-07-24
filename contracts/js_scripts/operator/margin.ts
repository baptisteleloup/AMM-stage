import { config } from "./config.js";
import type { Chain } from "./chain.js";
import type { Store } from "./store.js";
import type { Receipts } from "./receipts.js";
import type { SessionBatch } from "./netputs.js";

export class Margin {
  constructor(private chain: Chain, private store: Store, private receipts: Receipts) {}

  async update(day: number, t: number, batch: SessionBatch): Promise<void> {
    const sess = await this.chain.session(day, t);
    if (!sess.opened) return;
    const r = BigInt(sess.priceR);
    const c = BigInt(sess.priceC);
    for (const [slot, np] of batch) {
      const delta = np.buy * c - np.sell * r;
      const net = this.store.addSpend(day, slot, delta);
      const bal = this.store.balanceOf(day - 1, slot);
      const floor = this.store.floorOf(slot);
      if (bal === null || floor === null) continue;
      const projected = bal - (net > 0n ? net : 0n);
      this.check(day, slot, projected, floor, "critical", config.marginCritNum);
      this.check(day, slot, projected, floor, "warning", config.marginWarnNum);
    }
  }

  private check(day: number, slot: number, projected: bigint, floor: bigint, tier: string, num: bigint): void {
    if (projected * config.marginDen >= floor * num) return;
    if (this.store.alertSent(day, slot, tier)) return;
    this.store.markAlert(day, slot, tier);
    this.receipts.writeAlert(day, slot, tier, projected, floor);
  }
}
