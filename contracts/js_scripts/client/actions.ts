// Automatic actions of the watch loop: verify recent days, run recourse when a day does not check out,
// settle verified days, cancel on the member's own unanswered request, sweep dust. Each AUTO_* flag
// in config.ts switches one of them; every attempt is reported, done or not.

import { Chain, DAY_STATE } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { config } from "./config.js";
import { verifyDay } from "./verify.js";
import { requestData, fetchData, requestClearReveal } from "./recourse.js";

// What one action did, or why it was not attempted.
export type ActionAttempt = {
  action: string;
  day?: number;
  attempted: boolean;
  tx: string | null;
  reason: string;
};

// Last verdict this client reached on its own data for a day, if any.
function verdictOf(store: Store, day: number): string | undefined {
  return (store.verdict(`day-${day}`) as { verdict?: string } | undefined)?.verdict;
}

// Calls finalizeDay once its conditions hold. If settlement keeps reverting past the grace period, cancels the day.
export async function tryFinalize(chain: Chain, id: Identity, store: Store, day: number): Promise<ActionAttempt> {
  const dc = await chain.dayClose(day);
  if (dc.state !== 1) { // 1 = Closing
    return { action: "finalizeDay", day, attempted: false, tx: null, reason: `day is ${DAY_STATE[dc.state]}` };
  }
  const expected = (await chain.market.chunkCountFor(day)) as bigint;
  if (dc.chunksVerified !== expected) {
    return { action: "finalizeDay", day, attempted: false, tx: null, reason: `${dc.chunksVerified}/${expected} batches proven` };
  }
  const now = await chain.now();
  if (now < Number(dc.disputeDeadline)) {
    return { action: "finalizeDay", day, attempted: false, tx: null, reason: `deadline in ${Number(dc.disputeDeadline) - now}s` };
  }
  const open = (await chain.market.openRevealCount(day)) as bigint;
  if (open > 0n) {
    return { action: "finalizeDay", day, attempted: false, tx: null, reason: `${open} disclosure request(s) unanswered` };
  }

  try {
    const rc = await (await chain.market.finalizeDay(day)).wait(); // MarketV4.finalizeDay
    return { action: "finalizeDay", day, attempted: true, tx: rc.hash, reason: "settled" };
  } catch (e) {
    const why = (e as Error).message.slice(0, 120);
    const grace = Number((await chain.market.SETTLEMENT_GRACE()) as bigint);
    if (now > Number(dc.disputeDeadline) + grace) { // grace over: cancelDay accepts the stuck-day ground
      try {
        const rc = await (await chain.market.cancelDay(day, 0, `settlement impossible: ${why.slice(0, 80)}`)).wait(); // revealSlot 0: general ground
        return { action: "cancelDay", day, attempted: true, tx: rc.hash, reason: `settlement kept failing past the grace period (${why}); day cancelled so later days can proceed` };
      } catch (e2) {
        return { action: "cancelDay", day, attempted: true, tx: null, reason: `settlement failing (${why}) and cancel refused: ${(e2 as Error).message.slice(0, 80)}` };
      }
    }
    return { action: "finalizeDay", day, attempted: true, tx: null, reason: `reverted: ${why}` };
  }
}

// Cancels a day on this member's own recourse request left unanswered past its deadline.
export async function tryCancelOwn(chain: Chain, id: Identity, store: Store, day: number): Promise<ActionAttempt> {
  const slot = store.slot || (await chain.slotOf(id.address));
  const dc = await chain.dayClose(day);
  if (dc.state !== 1) {
    return { action: "cancelDay", day, attempted: false, tx: null, reason: `day is ${DAY_STATE[dc.state]}` };
  }
  const r = await chain.revealOf(day, slot);
  const now = await chain.now();
  const mine =
    (r.stage1Deadline > 0n && !r.stage1Done && now > Number(r.stage1Deadline))
    || (r.stage2Deadline > 0n && !r.stage2Done && now > Number(r.stage2Deadline));
  if (!mine) {
    return { action: "cancelDay", day, attempted: false, tx: null, reason: "no unanswered request of your own has timed out" };
  }
  try {
    const rc = await (await chain.market.cancelDay(day, slot, "disclosure request unanswered")).wait(); // revealSlot = own slot
    return { action: "cancelDay", day, attempted: true, tx: rc.hash, reason: "cancelled on your own timeout" };
  } catch (e) {
    return { action: "cancelDay", day, attempted: true, tx: null, reason: `reverted: ${(e as Error).message.slice(0, 120)}` };
  }
}

// Sends the dust pot to the reserve, if any.
export async function trySweep(chain: Chain): Promise<ActionAttempt> {
  const dust = (await chain.market.dustPot()) as bigint;
  if (dust === 0n) {
    return { action: "sweepDust", attempted: false, tx: null, reason: "no dust" };
  }
  try {
    const rc = await (await chain.market.sweepDust()).wait();
    return { action: "sweepDust", attempted: true, tx: rc.hash, reason: `${dust} pEUR swept to the reserve` };
  } catch (e) {
    return { action: "sweepDust", attempted: true, tx: null, reason: `reverted: ${(e as Error).message.slice(0, 120)}` };
  }
}

// Checks a day once its packet is held; an incomplete check is retried at the next tick.
export async function tryVerify(chain: Chain, id: Identity, store: Store, day: number): Promise<ActionAttempt> {
  if (!store.opening(day)) {
    return { action: "verify", day, attempted: false, tx: null, reason: "no day-close packet held yet" };
  }
  const prior = store.verdict(`day-${day}`) as { verdict?: string } | undefined;
  if (prior && prior.verdict !== "incomplete") { // verified or mismatch is final
    return { action: "verify", day, attempted: false, tx: null, reason: `already ${prior.verdict}` };
  }
  try {
    const r = await verifyDay(chain, id, store, day);
    const failed = r.checks.filter((c) => c.status === "fail").map((c) => c.name);
    return {
      action: "verify", day, attempted: true, tx: null,
      reason: r.verdict === "mismatch"
        ? `MISMATCH — ${failed.join(", ")}. Demand your data before the day settles.`
        : r.verdict === "verified"
          ? `verified, net ${r.amountEur} EUR`
          : "incomplete: something is still missing, will retry",
    };
  } catch (e) {
    return { action: "verify", day, attempted: false, tx: null, reason: (e as Error).message.slice(0, 120) };
  }
}


// Recourse ladder for a closing day: request data, read the answer and re-check, then ask for a clear reveal.
async function tryRecourse(
  chain: Chain, id: Identity, store: Store, day: number, needsData: boolean,
): Promise<ActionAttempt[]> {
  const out: ActionAttempt[] = [];
  const slot = store.slot || (await chain.slotOf(id.address));
  if (slot === 0) return out;
  const r = await chain.revealOf(day, slot);

  // Stage 1: the packet is missing, or it does not match the commitment on chain.
  if (r.stage1Deadline === 0n) { // stage 1 not requested yet: packet missing or mismatch
    if (!needsData || !config.autoRequestData) return out;
    try {
      const res = await requestData(chain, id, store, day);
      out.push({ action: "requestData", day, attempted: true, tx: res.tx, reason: res.outcome });
    } catch (e) {
      out.push({ action: "requestData", day, attempted: false, tx: null, reason: (e as Error).message.slice(0, 120) });
    }
    return out;
  }

  if (r.stage1Done && config.autoFetchData && !store.verdict(`fetched-${day}`)) { // read the operator's answer once, then re-check the day
    let usable = true;
    try {
      const res = await fetchData(chain, id, store, day);
      out.push({ action: "fetchData", day, attempted: true, tx: res.tx, reason: res.outcome });
    } catch (e) {
      usable = false;
      out.push({ action: "fetchData", day, attempted: true, tx: null, reason: `unusable answer: ${(e as Error).message.slice(0, 100)}` });
    }
    store.putVerdict(`fetched-${day}`, { at: new Date().toISOString(), usable });
    if (usable) {
      try {
        const v = await verifyDay(chain, id, store, day);
        out.push({ action: "verify", day, attempted: true, tx: null, reason: `after the operator's answer: ${v.verdict}` });
      } catch (e) {
        out.push({ action: "verify", day, attempted: false, tx: null, reason: (e as Error).message.slice(0, 120) });
      }
    }
  }

  if (r.stage1Done && r.stage2Deadline === 0n && config.autoRequestClear // stage 2 when the answer still does not verify
      && store.verdict(`fetched-${day}`) && verdictOf(store, day) !== "verified") {
    try {
      const res = await requestClearReveal(chain, id, store, day);
      out.push({ action: "requestClearReveal", day, attempted: true, tx: res.tx, reason: res.outcome });
    } catch (e) {
      out.push({ action: "requestClearReveal", day, attempted: false, tx: null, reason: (e as Error).message.slice(0, 120) });
    }
  }
  return out;
}

// One tick over the last two days, then the global actions.
export async function actionTick(chain: Chain, id: Identity, store: Store): Promise<ActionAttempt[]> {
  const out: ActionAttempt[] = [];
  const clock = await chain.clock();

  for (const day of [clock.day - 1, clock.day - 2]) { // days still closing or just settled
    const v = await tryVerify(chain, id, store, day);
    if (v.attempted) out.push(v);

    const dc = await chain.dayClose(day);
    const closing = DAY_STATE[dc.state] === "Closing";
    if (closing) {
      const needsData = verdictOf(store, day) === "mismatch" || !store.opening(day); // recourse only when the data is missing or wrong
      for (const a of await tryRecourse(chain, id, store, day, needsData)) out.push(a);
    }

    if (config.autoFinalize && closing) { // settle only a day this client has verified, never a mismatch
      const verdict = verdictOf(store, day);
      if (verdict === "verified") {
        const a = await tryFinalize(chain, id, store, day);
        if (a.attempted) out.push(a);
      } else if (verdict === "mismatch") {
        out.push({
          action: "finalizeDay", day, attempted: false, tx: null,
          reason: "not settled by this client: the day did not verify. Settlement is "
            + "permissionless, so someone else may still settle it - act now if you object.",
        });
      }
    }

    if (config.autoCancelOwn) {
      const c = await tryCancelOwn(chain, id, store, day);
      if (c.attempted) out.push(c);
    }
  }
  if (config.autoSweep) {
    const s = await trySweep(chain);
    if (s.attempted) out.push(s);
  }
  return out;
}
