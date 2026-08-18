import { ethers } from "ethers";
import { Chain, DAY_STATE } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { ReceiptInbox } from "./receipts.js";
import { peurToEur } from "./units.js";

export type RecourseResult = {
  action: string;
  day: number;
  slot: number;
  tx: string | null;
  outcome: string;
  next: string;
};

const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

async function slotOrThrow(chain: Chain, id: Identity, store: Store): Promise<number> {
  const slot = store.slot || (await chain.slotOf(id.address));
  if (slot === 0) throw new Error("not registered");
  return slot;
}

/**
 * Recourse only applies to a day that is closing: before that there is nothing
 * to challenge, after it the day is settled or cancelled and nothing can be
 * changed. The contract enforces this too — checking here turns a raw revert
 * into a sentence.
 */
async function closingOnly(
  chain: Chain, action: string, day: number, slot: number,
): Promise<RecourseResult | null> {
  const dc = await chain.dayClose(day);
  if (DAY_STATE[dc.state] === "Closing") return null;
  const state = DAY_STATE[dc.state];
  return {
    action, day, slot, tx: null,
    outcome: `day ${day} is ${state}, and recourse only applies while a day is closing`,
    next: state === "Pending"
      ? "wait for the day to close, then check your packet against the operator's"
      : "this day is finished; nothing about it can be challenged now",
  };
}

export async function requestData(chain: Chain, id: Identity, store: Store, day: number): Promise<RecourseResult> {
  const slot = await slotOrThrow(chain, id, store);
  const guard = await closingOnly(chain, "requestData", day, slot);
  if (guard) return guard;
  const r = await chain.revealOf(day, slot);
  if (r.stage1Deadline !== 0n) {
    return {
      action: "requestData", day, slot, tx: null,
      outcome: r.stage1Done ? "already answered by the operator" : "already open, waiting for the operator",
      next: r.stage1Done ? "run `fetch-data` to decrypt what was published" : `deadline at ${r.stage1Deadline}`,
    };
  }
  const tx = await chain.market.requestData(day);
  const rc = await tx.wait();
  const after = await chain.revealOf(day, slot);
  return {
    action: "requestData", day, slot, tx: rc.hash,
    outcome: "request recorded on chain; settlement of this day is now blocked until it is answered",
    next: `the operator must publish before ${after.stage1Deadline}; past that, \`cancel\` becomes available`,
  };
}

export async function fetchData(chain: Chain, id: Identity, store: Store, day: number): Promise<RecourseResult> {
  const slot = await slotOrThrow(chain, id, store);
  const r = await chain.revealOf(day, slot);
  if (!r.stage1Done) {
    return {
      action: "fetchData", day, slot, tx: null,
      outcome: "the operator has not published anything yet",
      next: r.stage1Deadline === 0n
        ? "run `request-data` first"
        : `wait, or cancel the day after ${r.stage1Deadline}`,
    };
  }
  const inbox = new ReceiptInbox(chain, id, store);
  const got = await inbox.ingestOnChainBlob(day);
  return {
    action: "fetchData", day, slot, tx: null,
    outcome: `decrypted and ingested ${got.sessions} session receipt(s)${got.opening ? " and the balance opening" : ""}`,
    next: "run `verify " + day + "` to check the settlement against this data",
  };
}

export async function requestClearReveal(chain: Chain, id: Identity, store: Store, day: number): Promise<RecourseResult> {
  const slot = await slotOrThrow(chain, id, store);
  const guard = await closingOnly(chain, "requestClearReveal", day, slot);
  if (guard) return guard;
  const r = await chain.revealOf(day, slot);
  if (!r.stage1Done) {
    return {
      action: "requestClearReveal", day, slot, tx: null,
      outcome: "stage 1 must be answered first",
      next: "run `request-data`, wait for the answer, then retry",
    };
  }
  if (r.stage2Deadline !== 0n) {
    return {
      action: "requestClearReveal", day, slot, tx: null,
      outcome: r.stage2Done ? "balance already opened in the clear" : "already open, waiting for the operator",
      next: r.stage2Done ? "read the revealed balance with `revealed " + day + "`" : `deadline at ${r.stage2Deadline}`,
    };
  }
  const tx = await chain.market.requestClearReveal(day);
  const rc = await tx.wait();
  const after = await chain.revealOf(day, slot);
  return {
    action: "requestClearReveal", day, slot, tx: rc.hash,
    outcome: "the operator must now prove the opening of your balance commitment",
    next: `deadline ${after.stage2Deadline}; the commitment is binding, so it cannot open onto a different value`,
  };
}

export async function readRevealed(chain: Chain, id: Identity, store: Store, day: number): Promise<RecourseResult> {
  const slot = await slotOrThrow(chain, id, store);
  const f = chain.market.filters.BalanceRevealed(day);
  const logs = await chain.market.queryFilter(f, 0, "latest");
  const mine = logs
    .filter((l): l is ethers.EventLog => "args" in l)
    .filter((l) => Number(l.args[1]) === slot);
  if (mine.length === 0) {
    return { action: "readRevealed", day, slot, tx: null, outcome: "no balance revealed on chain for this day", next: "run `request-clear` first" };
  }
  const bal = BigInt(mine[mine.length - 1].args[2] as bigint);
  const held = store.opening(day);
  const agrees = held !== null && BigInt(held.balance) === bal;
  return {
    action: "readRevealed", day, slot, tx: null,
    outcome: `chain reveals ${peurToEur(bal)} EUR (${bal} pEUR)`,
    next: held === null
      ? "no local packet to compare against"
      : agrees
        ? "matches the packet you hold"
        : `DISAGREES with your packet (${peurToEur(BigInt(held.balance))} EUR) - grounds for a dispute`,
  };
}

export async function cancel(chain: Chain, id: Identity, store: Store, day: number, reason: string): Promise<RecourseResult> {
  const slot = await slotOrThrow(chain, id, store);
  const dc = await chain.dayClose(day);
  if (dc.state !== 1) {
    return { action: "cancel", day, slot, tx: null, outcome: `day is ${DAY_STATE[dc.state]}, not closing`, next: "nothing to do" };
  }
  const r = await chain.revealOf(day, slot);
  const now = await chain.now();
  const mineTimedOut =
    (r.stage1Deadline > 0n && !r.stage1Done && now > Number(r.stage1Deadline))
    || (r.stage2Deadline > 0n && !r.stage2Done && now > Number(r.stage2Deadline));

  const revealSlot = mineTimedOut ? slot : 0;
  const tx = await chain.market.cancelDay(day, revealSlot, reason);
  const rc = await tx.wait();
  return {
    action: "cancel", day, slot, tx: rc.hash,
    outcome: mineTimedOut
      ? "day cancelled on your own unanswered request"
      : "day cancelled on a general ground (proof timeout or open dispute)",
    next: "no balance moved; the frozen deposits and withdrawals return to the queue for the next close",
  };
}

export async function dispute(chain: Chain, id: Identity, store: Store, day: number): Promise<RecourseResult> {
  const slot = await slotOrThrow(chain, id, store);
  const dc = await chain.dayClose(day);
  if (dc.state !== 1) {
    return { action: "dispute", day, slot, tx: null, outcome: `day is ${DAY_STATE[dc.state]}, disputes are only possible while closing`, next: "nothing to do" };
  }
  const existing = (await chain.market.disputerOf(day)) as string;
  if (existing !== ZERO_ADDR) {
    return { action: "dispute", day, slot, tx: null, outcome: "a dispute is already open for this day", next: "settlement is already blocked" };
  }

  const bond = (await chain.market.DISPUTE_BOND()) as bigint;
  const token = await chain.eeur();
  const held = (await token.balanceOf(id.address)) as bigint;
  if (held < bond) {
    throw new Error(`bond is ${peurToEur(bond / 1000000n)} EUR (${bond} wei) but you hold ${held} wei`);
  }
  const allowance = (await token.allowance(id.address, chain.market.target)) as bigint;
  if (allowance < bond) {
    await (await token.approve(chain.market.target, bond)).wait();
  }

  const tx = await chain.market.disputeDay(day);
  const rc = await tx.wait();
  return {
    action: "dispute", day, slot, tx: rc.hash,
    outcome: `bond of ${peurToEur(bond / 1000000n)} EUR locked; settlement of this day is blocked`,
    next: "adjudication happens off chain against the network operator's metering record; the bond is returned or forfeited accordingly",
  };
}
