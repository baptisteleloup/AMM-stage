import { Chain, DAY_STATE } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { config } from "./config.js";
import { verifyDay } from "./verify.js";
import { requestData, fetchData } from "./recourse.js";

export type ActionAttempt = {
  action: string;
  day?: number;
  attempted: boolean;
  tx: string | null;
  reason: string;
};

export async function tryFinalize(chain: Chain, id: Identity, store: Store, day: number): Promise<ActionAttempt> {
  const dc = await chain.dayClose(day);
  if (dc.state !== 1) {
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
  const disputer = (await chain.market.disputerOf(day)) as string;
  if (disputer !== "0x0000000000000000000000000000000000000000") {
    return { action: "finalizeDay", day, attempted: false, tx: null, reason: "a dispute is open" };
  }
  const open = (await chain.market.openRevealCount(day)) as bigint;
  if (open > 0n) {
    return { action: "finalizeDay", day, attempted: false, tx: null, reason: `${open} disclosure request(s) unanswered` };
  }

  try {
    const rc = await (await chain.market.finalizeDay(day)).wait();
    return { action: "finalizeDay", day, attempted: true, tx: rc.hash, reason: "settled" };
  } catch (e) {
    return { action: "finalizeDay", day, attempted: true, tx: null, reason: `reverted: ${(e as Error).message.slice(0, 120)}` };
  }
}

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
    const rc = await (await chain.market.cancelDay(day, slot, "disclosure request unanswered")).wait();
    return { action: "cancelDay", day, attempted: true, tx: rc.hash, reason: "cancelled on your own timeout" };
  } catch (e) {
    return { action: "cancelDay", day, attempted: true, tx: null, reason: `reverted: ${(e as Error).message.slice(0, 120)}` };
  }
}

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

/**
 * Check a closed day, at most once per verdict, and remember the result.
 *
 * Nothing on chain does this for you. The proof binds the settlement to the
 * fingerprints the operator posted; it says nothing about whether those
 * fingerprints match the receipts he signed and sent to you. That link is only
 * ever tested here, by you, against your own copy.
 *
 * Doing it automatically matters because of when it matters: settlement is
 * permissionless, so abstaining protects nobody — someone else will settle the
 * day regardless. What the check buys is the alert, raised while the window to
 * demand data or open a dispute is still open.
 */
export async function tryVerify(chain: Chain, id: Identity, store: Store, day: number): Promise<ActionAttempt> {
  if (!store.opening(day)) {
    return { action: "verify", day, attempted: false, tx: null, reason: "no day-close packet held yet" };
  }
  const prior = store.verdict(`day-${day}`) as { verdict?: string } | undefined;
  if (prior && prior.verdict !== "incomplete") {
    // A settled verdict does not change. An incomplete one can, once the
    // missing piece arrives, so that case is retried.
    return { action: "verify", day, attempted: false, tx: null, reason: `already ${prior.verdict}` };
  }
  try {
    const r = await verifyDay(chain, id, store, day);
    const failed = r.checks.filter((c) => c.status === "fail").map((c) => c.name);
    return {
      action: "verify", day, attempted: true, tx: null,
      reason: r.verdict === "mismatch"
        ? `MISMATCH — ${failed.join(", ")}. Demand your data or open a dispute before the day settles.`
        : r.verdict === "verified"
          ? `verified, net ${r.amountEur} EUR`
          : "incomplete: something is still missing, will retry",
    };
  } catch (e) {
    return { action: "verify", day, attempted: false, tx: null, reason: (e as Error).message.slice(0, 120) };
  }
}

/**
 * First rung of the ladder, walked without the prosumer.
 *
 * A recourse window is only a right if it can be exercised while it is open.
 * Days close at midnight and the window runs on chain time, so a person who
 * looks at their app in the evening has already missed it. Demanding data costs
 * only gas and blocks settlement until answered, so a keeper can do it on its
 * own; the rungs above cannot, because they are irreversible, cost a bond, or
 * affect the whole community.
 *
 * Two triggers: a day that will not verify, and a day whose closing packet never
 * arrived. Both are answered the same way — ask the operator, on chain, and
 * decrypt what comes back.
 */
async function tryRecourse(
  chain: Chain, id: Identity, store: Store, day: number, needsData: boolean,
): Promise<ActionAttempt[]> {
  const out: ActionAttempt[] = [];
  if (!needsData || !config.autoRequestData) return out;

  const slot = store.slot || (await chain.slotOf(id.address));
  if (slot === 0) return out;
  const r = await chain.revealOf(day, slot);

  if (r.stage1Deadline === 0n) {
    try {
      const res = await requestData(chain, id, store, day);
      out.push({ action: "requestData", day, attempted: true, tx: res.tx, reason: res.outcome });
    } catch (e) {
      out.push({ action: "requestData", day, attempted: false, tx: null, reason: (e as Error).message.slice(0, 120) });
    }
    return out;
  }

  // The request is already open. Once the operator has answered, take what was
  // published — it arrives through the chain, so it works even with the
  // operator's own server unreachable.
  if (r.stage1Done && config.autoFetchData && !store.opening(day)) {
    try {
      const res = await fetchData(chain, id, store, day);
      out.push({ action: "fetchData", day, attempted: true, tx: res.tx, reason: res.outcome });
    } catch (e) {
      out.push({ action: "fetchData", day, attempted: false, tx: null, reason: (e as Error).message.slice(0, 120) });
    }
  }
  return out;
}

export async function actionTick(chain: Chain, id: Identity, store: Store): Promise<ActionAttempt[]> {
  const out: ActionAttempt[] = [];
  const clock = await chain.clock();

  for (const day of [clock.day - 1, clock.day - 2]) {
    // Check before settling, so a bad day is flagged while there is still time
    // to act on it rather than after the money has moved.
    const v = await tryVerify(chain, id, store, day);
    if (v.attempted) out.push(v);
    const bad = v.attempted && v.reason.startsWith("MISMATCH");

    // Only escalate on a day that is actually closing — a settled or cancelled
    // day cannot be acted on, and asking would just waste gas.
    const dc = await chain.dayClose(day);
    if (DAY_STATE[dc.state] === "Closing") {
      const needsData = bad || !store.opening(day);
      for (const a of await tryRecourse(chain, id, store, day, needsData)) out.push(a);
    }

    if (config.autoFinalize && !bad) {
      const a = await tryFinalize(chain, id, store, day);
      if (a.attempted) out.push(a);
    } else if (config.autoFinalize && bad) {
      out.push({
        action: "finalizeDay", day, attempted: false, tx: null,
        reason: "not settled by this client: the day did not verify. Settlement is "
          + "permissionless, so someone else may still settle it — act now if you object.",
      });
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
