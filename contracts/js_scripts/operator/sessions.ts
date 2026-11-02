// Session opening. Each tick, if the current session is not open yet, reads the previous
// quarter-hour's positions of the participating members, posts the aggregates (s, d) on chain,
// then writes the signed session receipts and updates the margin checks.

import type { Chain } from "./chain.js";
import { physicalOf, type NetputSource, type SessionBatch } from "./netputs.js";
import type { Receipts } from "./receipts.js";
import type { Margin } from "./margin.js";
import type { Store } from "./store.js";

const MAX_U32 = 0xffffffffn; // aggregates are uint32 on chain

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

  // Participation bit, frozen at the member's first session of the day: floor set and opening balance >= floor.
  private participates(day: number, slot: number): boolean {
    const cached = this.store.participationOf(day, slot);
    if (cached !== null) return cached; // already frozen for the day
    const floor = this.store.floorOf(slot);
    const bal = this.store.balanceOf(day - 1, slot) ?? 0n; // balance after yesterday's close
    const yes = floor !== null && bal >= floor;
    this.store.putParticipation(day, slot, yes);
    return yes;
  }

  async tick(): Promise<void> {
    const { day, t } = await this.chain.clock(); // current session from the chain's clock
    const sess = await this.chain.session(day, t);
    if (sess.opened) return;

    // Opening balances come from yesterday's close: wait for its packets unless participation is already frozen.
    if (this.store.participationOf(day, 1) === null
        && this.store.metaGet(`packets:${day - 1}`) !== "done") {
      return;
    }

    const prev = physicalOf(day, t); // the quarter-hour this session settles
    const raw = await this.source.read(prev.day, prev.t);
    const batch: SessionBatch = new Map();
    for (const [slot, np] of raw) {
      if (this.participates(day, slot)) batch.set(slot, np); // members below their floor are left out
    }

    let s = 0n; // aggregate offered, Wh
    let d = 0n; // aggregate demanded, Wh
    for (const np of batch.values()) {
      s += np.sell;
      d += np.buy;
    }

    await this.chain.openSession(day, t, clampU32(s), clampU32(d)); // the contract prices the session
    await this.receipts.writeSessionReceipts(day, t, batch); // each member's signed position
    await this.margin.update(day, t, batch);
    console.log(`[sessions] opened day=${day} t=${t} s=${s} d=${d} (physical ${prev.day}/${prev.t})`);
  }
}
