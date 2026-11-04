// The member's view of a closing day: state, proofs, deadlines, open recourse requests, whether
// the day can be cancelled and on what ground, and what the member should do next.
// Also counts the session receipts held for a day (coverage).

import { Chain, DAY_STATE } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { SESSIONS } from "./config.js";

export type Deadline = {
  label: string;
  at: number;
  secondsLeft: number;
  expired: boolean;
  meaning: string;
};

export type DayView = {
  day: number;
  session: number;
  now: number;
  state: string;
  chunksVerified: string;
  chunksExpected: string;
  netputHashesPosted: boolean;
  myNetputHashPosted: boolean;
  deadlines: Deadline[];
  openRequests: { stage: number; deadline: number; secondsLeft: number; answered: boolean }[];
  cancellable: { possible: boolean; ground: string | null };
  actionable: string[];
};

const ZERO32 = "0x" + "0".repeat(64);

// One deadline, seconds left from chain time.
function mk(label: string, at: number, now: number, meaning: string): Deadline {
  return { label, at, secondsLeft: at - now, expired: now > at, meaning };
}

// Builds the view of a day, by default yesterday (the day closing now).
export async function dayView(chain: Chain, id: Identity, store: Store, dayArg?: number): Promise<DayView> {
  const slot = store.slot || (await chain.slotOf(id.address));
  if (slot === 0) throw new Error("not registered");

  const clock = await chain.clock();
  const now = await chain.now();
  const day = dayArg ?? clock.day - 1; // yesterday by default

  const dc = await chain.dayClose(day);
  const state = DAY_STATE[dc.state] ?? String(dc.state);
  const posted = (await chain.market.netputHashesPosted(day)) as boolean;
  const myHash = await chain.netputHash(day, slot);
  // batches expected, known once the day is frozen
  const expected = posted ? ((await chain.market.chunkCountFor(day)) as bigint) : 0n;

  const deadlines: Deadline[] = [];
  if (dc.disputeDeadline > 0n) {
    // the recourse deadline (disputeDeadline), seen from the member's side
    deadlines.push(mk("time to object", Number(dc.disputeDeadline), now,
      "nothing is paid before this; check the day and object if it does not add up"));
  }

  const r = await chain.revealOf(day, slot);
  const openRequests: DayView["openRequests"] = [];
  if (r.stage1Deadline > 0n) {
    openRequests.push({
      stage: 1, deadline: Number(r.stage1Deadline),
      secondsLeft: Number(r.stage1Deadline) - now, answered: r.stage1Done,
    });
    if (!r.stage1Done) {
      deadlines.push(mk("data request", Number(r.stage1Deadline), now,
        "operator must publish your data before this, or the day can be cancelled"));
    }
  }
  if (r.stage2Deadline > 0n) {
    openRequests.push({
      stage: 2, deadline: Number(r.stage2Deadline),
      secondsLeft: Number(r.stage2Deadline) - now, answered: r.stage2Done,
    });
    if (!r.stage2Done) {
      deadlines.push(mk("clear-balance request", Number(r.stage2Deadline), now,
        "operator must reveal your balance before this, or the day can be cancelled"));
    }
  }

  const pastDeadline = dc.disputeDeadline > 0n && now > Number(dc.disputeDeadline); // proofs and objections window over
  const grace = Number((await chain.market.SETTLEMENT_GRACE()) as bigint); // SETTLEMENT_GRACE, read from the contract
  const pastGrace = dc.disputeDeadline > 0n && now > Number(dc.disputeDeadline) + grace;
  const proofsMissing = dc.chunksVerified < expected;
  const stage1Timeout = r.stage1Deadline > 0n && !r.stage1Done && now > Number(r.stage1Deadline);
  const stage2Timeout = r.stage2Deadline > 0n && !r.stage2Done && now > Number(r.stage2Deadline);

  let ground: string | null = null; // same grounds as MarketV4.cancelDay
  if (state === "Closing") {
    if (pastDeadline && proofsMissing) ground = "proof timeout";
    else if (stage1Timeout || stage2Timeout) ground = "unanswered disclosure request";
    else if (pastGrace) ground = "settlement still failing past the grace period";
  }

  const actionable: string[] = [];
  if (state === "Closing") {
    // operator posted no commitment for this slot
    if (myHash === ZERO32) actionable.push("no fingerprint posted for your slot on this day");
    if (!store.opening(day)) actionable.push("no day-close packet held: run `sync`, or `request-data` to compel the operator");
    if (ground) actionable.push(`the day can be cancelled now (${ground})`);
    if (!ground && store.opening(day)) actionable.push("check this day before the time to object runs out");
  }
  if (state === "Finalized" && !store.opening(day)) {
    actionable.push("day settled but you hold no packet for it: request your data");
  }
  if (state === "Cancelled") {
    actionable.push("day cancelled: no balance moved, the queues survive for the next close");
  }

  return {
    day, session: clock.t, now, state,
    chunksVerified: dc.chunksVerified.toString(),
    chunksExpected: expected.toString(),
    netputHashesPosted: posted,
    myNetputHashPosted: myHash !== ZERO32,
    deadlines, openRequests,
    cancellable: { possible: ground !== null, ground },
    actionable,
  };
}

// Which sessions of a day have a receipt in the store, up to the current session.
export async function coverage(chain: Chain, id: Identity, store: Store, day: number): Promise<{ day: number; held: number; expected: number; missing: number[] }> {
  const clock = await chain.clock();
  const upTo = day === clock.day ? clock.t : SESSIONS - 1; // today: only sessions already passed
  const held = store.sessionsOf(day).map((r) => r.t);
  const missing: number[] = [];
  for (let t = 0; t <= upTo; t++) if (!held.includes(t)) missing.push(t);
  return { day, held: held.length, expected: upTo + 1, missing };
}
