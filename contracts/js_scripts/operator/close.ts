import crypto from "node:crypto";
import { hashNetputs, commitBalance, toHex32 } from "../scenario.js";
import { config } from "./config.js";
import type { Chain, ChunkSubmission } from "./chain.js";
import type { Store } from "./store.js";
import type { Receipts } from "./receipts.js";
import { physicalOf, type NetputSource } from "./netputs.js";
import type { ChunkWitness } from "./prove.js";
import type { Prover } from "./prover.js";

const SESSIONS = 96;
const BATCH = 8;
const FIELD_BYTES = 31;

// A day can become permanently unprovable — for instance if sessions failed to
// open, so the aggregates posted on chain no longer match what the netput source
// reconstructs. Retrying forever costs a full proof each time and starves
// everything else. Count the failures, back off, and once the dispute deadline
// has passed, abandon the day through the route the protocol already provides.
const MAX_PROOF_ATTEMPTS = Number(process.env.MAX_PROOF_ATTEMPTS ?? 3);
const RETRY_BACKOFF_MS = Number(process.env.PROOF_RETRY_BACKOFF_MS ?? 30000);

function randField(): bigint {
  return BigInt("0x" + crypto.randomBytes(FIELD_BYTES).toString("hex"));
}

type SessionRow = { opened: boolean; r: bigint; c: bigint };

type SlotDay = {
  sells: bigint[]; buys: bigint[];
  oldBal: bigint; oldBlind: bigint;
  floor: bigint; floorBlind: bigint;
  netputBlind: bigint; newBlind: bigint;
  deposit: bigint; withdrawal: bigint;
  paid: bigint; newBal: bigint; newCommit: bigint;
  participating: boolean;
};

export class Close {
  private padding: { empty: string; zero: string } | null = null;

  private nextAttemptAt = new Map<number, number>();

  // Once a day's netput hashes are posted the day is frozen: its 96 sessions can
  // no longer change. Re-reading them from the chain on every tick was costing
  // ~200 RPC round trips per pass, several seconds, every 200ms — enough on its
  // own to make session opening late and, when a session is missed, to make the
  // whole day unprovable. Read them once and keep them.
  private sessionCache = new Map<number, SessionRow[]>();

  private async sessionsOf(target: number): Promise<SessionRow[]> {
    const hit = this.sessionCache.get(target);
    if (hit) return hit;
    const rows: SessionRow[] = [];
    for (let t = 0; t < SESSIONS; t++) {
      const s = await this.chain.session(target, t);
      rows.push({ opened: s.opened, r: BigInt(s.priceR), c: BigInt(s.priceC) });
    }
    this.sessionCache.set(target, rows);
    // Keep only the days still in play; anything older is settled or cancelled.
    for (const d of this.sessionCache.keys()) if (d < target - 2) this.sessionCache.delete(d);
    return rows;
  }

  constructor(
    private chain: Chain,
    private store: Store,
    private source: NetputSource,
    private receipts: Receipts,
    private prover: Prover,
  ) {}

  private attempts(day: number): number {
    return Number(this.store.metaGet(`proofFails:${day}`) ?? "0");
  }

  private noteFailure(day: number, why: string): void {
    const n = this.attempts(day) + 1;
    this.store.metaSet(`proofFails:${day}`, String(n));
    this.nextAttemptAt.set(day, Date.now() + RETRY_BACKOFF_MS * n);
    console.error(`[close] day ${day}: proof attempt ${n}/${MAX_PROOF_ATTEMPTS} failed — ${why}`);
    if (n >= MAX_PROOF_ATTEMPTS) {
      console.error(`[close] day ${day}: giving up on proving it; will cancel once the dispute deadline passes`);
    }
  }

  /**
   * A day we have given up on, or one whose deadline has passed with the proof
   * incomplete, is cancelled rather than left to block settlement forever. No
   * balance moves; the deposits and withdrawals frozen for that day return to
   * the queue and are applied at the next successful close.
   */
  private async maybeCancel(day: number, dc: { chunksVerified: number; disputeDeadline: bigint }): Promise<boolean> {
    const now = await this.chain.now();
    if (BigInt(now) <= dc.disputeDeadline) return false;
    const expected = await this.chain.chunkCountFor(day);
    if (expected > 0 && dc.chunksVerified >= expected) return false;
    try {
      await this.chain.cancelDay(day, 0, `proof incomplete after ${this.attempts(day)} attempt(s)`);
      console.error(`[close] day ${day}: CANCELLED — it could not be proven before the deadline`);
      this.store.metaSet(`proofFails:${day}`, "0");
      return true;
    } catch (e) {
      console.error(`[close] day ${day}: cancelDay refused — ${(e as Error).message.slice(0, 120)}`);
      return false;
    }
  }

  async tick(): Promise<void> {
    const { day } = await this.chain.clock();
    const target = day - 1;
    if (target < 0) return;

    // Nothing to do on a day already settled or cancelled, nor on one whose
    // packets are written and whose chunks are all in — leave before touching
    // the chain again.
    if (this.store.metaGet(`packets:${target}`) === "done") return;

    const dc = await this.chain.dayClose(target);
    if (dc.state >= 2) return;

    if (!this.padding) this.padding = await this.chain.paddingConstants();

    const posted = await this.chain.netputHashesPosted(target);
    if (!posted) {
      await this.postHashes(target);
      return;
    }

    const K = Math.ceil(dc.prosumerCountAt / BATCH);
    if (dc.chunksVerified < K) {
      if (this.attempts(target) >= MAX_PROOF_ATTEMPTS) {
        await this.maybeCancel(target, dc);
        return;
      }
      const wait = this.nextAttemptAt.get(target) ?? 0;
      if (Date.now() < wait) return;
      await this.proveAndSubmit(target, dc.prosumerCountAt);
      return;
    }

    if (this.store.metaGet(`packets:${target}`) !== "done") {
      await this.writePackets(target, dc.prosumerCountAt);
    }
  }

  private async netputsFor(target: number, N: number): Promise<Map<number, { sells: bigint[]; buys: bigint[] }>> {
    const per = new Map<number, { sells: bigint[]; buys: bigint[] }>();
    for (let slot = 1; slot <= N; slot++) {
      per.set(slot, { sells: Array(SESSIONS).fill(0n), buys: Array(SESSIONS).fill(0n) });
    }
    const rows = await this.sessionsOf(target);
    for (let t = 0; t < SESSIONS; t++) {
      if (!rows[t].opened) continue;
      const phys = physicalOf(target, t);
      const batch = await this.source.read(phys.day, phys.t);
      for (const [slot, np] of batch) {
        const row = per.get(slot);
        if (!row) continue;
        if (!this.participates(target, slot)) continue;
        row.sells[t] = np.sell;
        row.buys[t] = np.buy;
      }
    }
    return per;
  }

  private participates(target: number, slot: number): boolean {
    const floor = this.store.floorOf(slot) ?? 0n;
    const bal = this.store.balanceOf(target - 1, slot) ?? 0n;
    const live = floor === 0n ? true : bal >= floor;
    const frozen = this.store.participationOf(target, slot);
    if (frozen === null) return live;
    return frozen && live;
  }

  private async postHashes(target: number): Promise<void> {
    const N = await this.chain.prosumerCount();
    const per = await this.netputsFor(target, N);
    const hashes: string[] = [];
    for (let slot = 1; slot <= N; slot++) {
      let blinds = this.store.dayBlinds(target, slot);
      if (!blinds) {
        blinds = { netputBlind: randField(), newBlind: randField() };
        this.store.putDayBlinds(target, slot, blinds.netputBlind, blinds.newBlind);
      }
      const row = per.get(slot)!;
      const h = await hashNetputs(BigInt(slot), blinds.netputBlind, row.sells, row.buys);
      hashes.push(toHex32(h));
    }
    await this.chain.postNetputHashes(target, hashes);
    console.log(`[close] day ${target}: netput hashes posted + freeze (N=${N})`);
  }

  private async slotState(target: number, slot: number, row: { sells: bigint[]; buys: bigint[] }, prices: { r: bigint; c: bigint }[]): Promise<SlotDay> {
    const blinds = this.store.dayBlinds(target, slot);
    if (!blinds) throw new Error(`missing day blinds for slot ${slot}`);
    const oldBal = this.store.balanceOf(target - 1, slot) ?? 0n;
    const oldBlind = this.store.blindOf(target - 1, slot) ?? 0n;
    const floor = this.store.floorOf(slot) ?? 0n;
    const floorBlind = this.store.floorBlindOf(slot) ?? 0n;
    const deposit = await this.chain.snapDeposit(target, slot);
    const withdrawal = await this.chain.snapWithdrawal(target, slot);
    const participating = this.participates(target, slot);

    let delta = 0n;
    for (let t = 0; t < SESSIONS; t++) {
      delta += row.sells[t] * prices[t].r - row.buys[t] * prices[t].c;
    }
    const available = oldBal + delta + deposit;
    const paid = withdrawal < available ? withdrawal : available;
    const newBal = available - paid;
    const newCommit = await commitBalance(newBal, blinds.newBlind);

    return {
      sells: row.sells, buys: row.buys,
      oldBal, oldBlind, floor, floorBlind,
      netputBlind: blinds.netputBlind, newBlind: blinds.newBlind,
      deposit, withdrawal, paid, newBal, newCommit,
      participating,
    };
  }

  private async proveAndSubmit(target: number, N: number): Promise<void> {
    const per = await this.netputsFor(target, N);
    const prices = (await this.sessionsOf(target)).map((s) => ({ r: s.r, c: s.c }));

    const K = Math.ceil(N / BATCH);
    for (let k = 0; k < K; k++) {
      if (await this.chain.chunkDone(target, k)) continue;

      const zero = BigInt(this.padding!.zero);
      const empty = BigInt(this.padding!.empty);
      const w: ChunkWitness = {
        price_r: prices.map((p) => p.r.toString()),
        price_c: prices.map((p) => p.c.toString()),
        slots: [], netput_hashes: [], old_commits: [], new_commits: [],
        deposits: [], withdrawals: [], withdrawals_paid: [], floor_commits: [],
        partial_s: [], partial_d: [], partial_paid_out: "0", partial_paid_in: "0",
        sell: [], buy: [], old_bals: [], old_blinds: [], new_blinds: [],
        floors: [], floor_blinds: [], netput_blinds: [],
      };
      const sub: ChunkSubmission = {
        newCommits: [], withdrawalsPaid: [],
        partialS: Array(SESSIONS).fill(0), partialD: Array(SESSIONS).fill(0),
        partialPaidOut: 0n, partialPaidIn: 0n,
      };
      const partialS = Array<bigint>(SESSIONS).fill(0n);
      const partialD = Array<bigint>(SESSIONS).fill(0n);
      let paidOut = 0n;
      let paidIn = 0n;

      for (let j = 0; j < BATCH; j++) {
        const slot = k * BATCH + j + 1;
        if (slot > N) {
          w.slots.push("0");
          w.netput_hashes.push(empty.toString());
          w.old_commits.push(zero.toString());
          w.new_commits.push(zero.toString());
          w.deposits.push("0");
          w.withdrawals.push("0");
          w.withdrawals_paid.push("0");
          w.floor_commits.push(zero.toString());
          w.sell.push(Array(SESSIONS).fill("0"));
          w.buy.push(Array(SESSIONS).fill("0"));
          w.old_bals.push("0");
          w.old_blinds.push("0");
          w.new_blinds.push("0");
          w.floors.push("0");
          w.floor_blinds.push("0");
          w.netput_blinds.push("0");
          sub.newCommits.push(toHex32(zero));
          sub.withdrawalsPaid.push(0n);
          continue;
        }
        const st = await this.slotState(target, slot, per.get(slot)!, prices);
        const netputHash = await hashNetputs(BigInt(slot), st.netputBlind, st.sells, st.buys);
        const oldCommit = target === 0 && st.oldBal === 0n && st.oldBlind === 0n
          ? zero
          : await commitBalance(st.oldBal, st.oldBlind);
        const floorCommit = st.floor === 0n && st.floorBlind === 0n
          ? zero
          : await commitBalance(st.floor, st.floorBlind);

        w.slots.push(String(slot));
        w.netput_hashes.push(netputHash.toString());
        w.old_commits.push(oldCommit.toString());
        w.new_commits.push(st.newCommit.toString());
        w.deposits.push(st.deposit.toString());
        w.withdrawals.push(st.withdrawal.toString());
        w.withdrawals_paid.push(st.paid.toString());
        w.floor_commits.push(floorCommit.toString());
        w.sell.push(st.sells.map(String));
        w.buy.push(st.buys.map(String));
        w.old_bals.push(st.oldBal.toString());
        w.old_blinds.push(st.oldBlind.toString());
        w.new_blinds.push(st.newBlind.toString());
        w.floors.push(st.floor.toString());
        w.floor_blinds.push(st.floorBlind.toString());
        w.netput_blinds.push(st.netputBlind.toString());

        sub.newCommits.push(toHex32(st.newCommit));
        sub.withdrawalsPaid.push(st.paid);
        for (let t = 0; t < SESSIONS; t++) {
          partialS[t] += st.sells[t];
          partialD[t] += st.buys[t];
          paidOut += st.sells[t] * prices[t].r;
          paidIn += st.buys[t] * prices[t].c;
        }
      }

      w.partial_s = partialS.map(String);
      w.partial_d = partialD.map(String);
      w.partial_paid_out = paidOut.toString();
      w.partial_paid_in = paidIn.toString();
      sub.partialS = partialS.map(Number);
      sub.partialD = partialD.map(Number);
      sub.partialPaidOut = paidOut;
      sub.partialPaidIn = paidIn;

      // The proof is asked for here and collected on a later tick. Nothing in
      // this method waits for it, so sessions keep opening on time.
      const jobId = `chunk:${target}:${k}`;
      const job = this.prover.state(jobId);

      if (job.state === "idle") {
        this.prover.requestChunk(jobId, w);
        console.log(`[close] day ${target}: chunk ${k + 1}/${K} queued for proving`);
        return;
      }
      if (job.state === "running") return;
      if (job.state === "failed") {
        this.prover.clear(jobId);
        this.noteFailure(target, `proving chunk ${k + 1}/${K}: ${job.error.slice(0, 120)}`);
        return;
      }

      // Everything the chain will check, recorded before the call. When a chunk
      // is rejected the revert data alone says nothing — these are the numbers
      // to compare against what the proof was built from.
      const before = await this.chain.dayClose(target);
      const ctx = `N at freeze=${before.prosumerCountAt}, chunks=${before.chunksVerified}/${K}, `
        + `sessions opened=${(await this.sessionsOf(target)).filter((r) => r.opened).length}/96, `
        + `slots in batch=${w.slots.filter((x) => x !== "0").join(",")}`;

      try {
        await this.chain.submitChunk(target, k, sub, job.proof);
        console.log(`[close] day ${target}: chunk ${k} verified on-chain (proof took ${(job.ms / 1000).toFixed(1)}s)`);
        this.prover.clear(jobId);
        this.store.metaSet(`proofFails:${target}`, "0");
      } catch (e) {
        this.prover.clear(jobId);
        const msg = (e as Error).message;
        // 0x9fc3a218 is SumcheckFailed: the proof does not satisfy the verifier,
        // which almost always means the witness was built from something other
        // than what the chain holds.
        const sel = /data="(0x[0-9a-f]{8})/.exec(msg)?.[1] ?? "";
        const named = sel === "0x9fc3a218" ? "SumcheckFailed (the proof does not match the posted data)" : sel;
        this.noteFailure(target, `chunk ${k + 1}/${K} rejected on chain: ${named}\n`
          + `      ${ctx}\n      raw: ${msg.slice(0, 300)}`);
        return;
      }
    }
  }

  private async writePackets(target: number, N: number): Promise<void> {
    const per = await this.netputsFor(target, N);
    const prices = (await this.sessionsOf(target)).map((s) => ({ r: s.r, c: s.c }));
    for (let slot = 1; slot <= N; slot++) {
      const st = await this.slotState(target, slot, per.get(slot)!, prices);
      this.store.putOpening(target, slot, st.newBal, st.newBlind, st.netputBlind);
      await this.receipts.writeDayClosePacket(target, slot, st.newBal, st.newBlind, st.netputBlind);
    }
    this.store.metaSet(`packets:${target}`, "done");
    console.log(`[close] day ${target}: openings stored + day-close packets written`);
  }
}
