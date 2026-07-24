import crypto from "node:crypto";
import { hashNetputs, commitBalance, toHex32 } from "../scenario.js";
import { config } from "./config.js";
import type { Chain, ChunkSubmission } from "./chain.js";
import type { Store } from "./store.js";
import type { Receipts } from "./receipts.js";
import { physicalOf, type NetputSource } from "./netputs.js";
import { proveChunk, type ChunkWitness } from "./prove.js";

const SESSIONS = 96;
const BATCH = 8;
const FIELD_BYTES = 31;

function randField(): bigint {
  return BigInt("0x" + crypto.randomBytes(FIELD_BYTES).toString("hex"));
}

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

  constructor(
    private chain: Chain,
    private store: Store,
    private source: NetputSource,
    private receipts: Receipts,
  ) {}

  async tick(): Promise<void> {
    const { day } = await this.chain.clock();
    const target = day - 1;
    if (target < 0) return;

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
    for (let t = 0; t < SESSIONS; t++) {
      const sess = await this.chain.session(target, t);
      if (!sess.opened) continue;
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
    if (floor === 0n) return true;
    const bal = this.store.balanceOf(target - 1, slot) ?? 0n;
    return bal >= floor;
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
    const prices: { r: bigint; c: bigint }[] = [];
    for (let t = 0; t < SESSIONS; t++) {
      const sess = await this.chain.session(target, t);
      prices.push({ r: BigInt(sess.priceR), c: BigInt(sess.priceC) });
    }

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

      console.log(`[close] day ${target}: proving chunk ${k + 1}/${K}...`);
      const proof = await proveChunk(w);
      await this.chain.submitChunk(target, k, sub, proof);
      console.log(`[close] day ${target}: chunk ${k} verified on-chain`);
    }
  }

  private async writePackets(target: number, N: number): Promise<void> {
    const per = await this.netputsFor(target, N);
    const prices: { r: bigint; c: bigint }[] = [];
    for (let t = 0; t < SESSIONS; t++) {
      const sess = await this.chain.session(target, t);
      prices.push({ r: BigInt(sess.priceR), c: BigInt(sess.priceC) });
    }
    for (let slot = 1; slot <= N; slot++) {
      const st = await this.slotState(target, slot, per.get(slot)!, prices);
      this.store.putOpening(target, slot, st.newBal, st.newBlind, st.netputBlind);
      await this.receipts.writeDayClosePacket(target, slot, st.newBal, st.newBlind, st.netputBlind);
    }
    this.store.metaSet(`packets:${target}`, "done");
    console.log(`[close] day ${target}: openings stored + day-close packets written`);
  }
}
