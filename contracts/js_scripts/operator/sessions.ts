import type { Chain } from "./chain.js";
import { physicalOf, type NetputSource, type SessionBatch } from "./netputs.js";
import type { Receipts } from "./receipts.js";
import type { Margin } from "./margin.js";
import type { Store } from "./store.js";

const MAX_U32 = 0xffffffffn;

function clampU32(v: bigint): number {
  return Number(v > MAX_U32 ? MAX_U32 : v);
}

export class Sessions {
  constructor(
    private chain: Chain,
    private source: NetputSource,
    private receipts: Receipts,
    private margin: Margin,
    private store: Store,
  ) {}

  private participates(day: number, slot: number): boolean {
    const floor = this.store.floorOf(slot) ?? 0n;
    if (floor === 0n) return true;
    const bal = this.store.balanceOf(day - 1, slot) ?? 0n;
    return bal >= floor;
  }

  async tick(): Promise<void> {
    const { day, t } = await this.chain.clock();
    const sess = await this.chain.session(day, t);
    if (sess.opened) return;

    const prev = physicalOf(day, t);
    const raw = await this.source.read(prev.day, prev.t);
    const batch: SessionBatch = new Map();
    for (const [slot, np] of raw) {
      if (this.participates(day, slot)) batch.set(slot, np);
    }

    let s = 0n;
    let d = 0n;
    for (const np of batch.values()) {
      s += np.sell;
      d += np.buy;
    }

    await this.chain.openSession(day, t, clampU32(s), clampU32(d));
    await this.receipts.writeSessionReceipts(day, t, batch);
    await this.margin.update(day, t, batch);
    console.log(`[sessions] opened day=${day} t=${t} s=${s} d=${d} (physical ${prev.day}/${prev.t})`);
  }
}
