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
    const cached = this.store.participationOf(day, slot);
    if (cached !== null) return cached;
    const floor = this.store.floorOf(slot) ?? 0n;
    const bal = this.store.balanceOf(day - 1, slot) ?? 0n;
    const yes = floor === 0n ? true : bal >= floor;
    this.store.putParticipation(day, slot, yes);
    return yes;
  }

  async tick(): Promise<void> {
    const { day, t } = await this.chain.clock();
    const sess = await this.chain.session(day, t);
    if (sess.opened) return;

    if (this.store.participationOf(day, 1) === null
        && this.store.metaGet(`packets:${day - 1}`) !== "done") {
      return;
    }

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
