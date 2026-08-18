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
  disputeOpen: boolean;
  cancellable: { possible: boolean; ground: string | null };
  actionable: string[];
};

const ZERO32 = "0x" + "0".repeat(64);

function mk(label: string, at: number, now: number, meaning: string): Deadline {
  return { label, at, secondsLeft: at - now, expired: now > at, meaning };
}

export async function dayView(chain: Chain, id: Identity, store: Store, dayArg?: number): Promise<DayView> {
  const slot = store.slot || (await chain.slotOf(id.address));
  if (slot === 0) throw new Error("not registered");

  const clock = await chain.clock();
  const now = await chain.now();
  const day = dayArg ?? clock.day - 1;

  const dc = await chain.dayClose(day);
  const state = DAY_STATE[dc.state] ?? String(dc.state);
  const posted = (await chain.market.netputHashesPosted(day)) as boolean;
  const myHash = await chain.netputHash(day, slot);
  const expected = posted ? ((await chain.market.chunkCountFor(day)) as bigint) : 0n;

  const deadlines: Deadline[] = [];
  if (dc.disputeDeadline > 0n) {
    // One deadline, two roles: it is the operator's time to finish proving, and
    // it is your time to check the day and object before any money moves. Named
    // from your side, because that is whose window it is.
    deadlines.push(mk("time to object", Number(dc.disputeDeadline), now,
      "until then nothing is paid: check the day, demand your data, or dispute. "
      + "After it, a fully proven day can be settled by anyone, and a day still "
      + "missing a batch can be cancelled by anyone"));
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
        "the operator must publish your encrypted data before this; past it you may cancel the day"));
    }
  }
  if (r.stage2Deadline > 0n) {
    openRequests.push({
      stage: 2, deadline: Number(r.stage2Deadline),
      secondsLeft: Number(r.stage2Deadline) - now, answered: r.stage2Done,
    });
    if (!r.stage2Done) {
      deadlines.push(mk("clear-balance request", Number(r.stage2Deadline), now,
        "the operator must open your balance in the clear before this"));
    }
  }

  const disputer = (await chain.market.disputerOf(day)) as string;
  const disputeOpen = disputer !== "0x0000000000000000000000000000000000000000";

  const pastDeadline = dc.disputeDeadline > 0n && now > Number(dc.disputeDeadline);
  const proofsMissing = dc.chunksVerified < expected;
  const stage1Timeout = r.stage1Deadline > 0n && !r.stage1Done && now > Number(r.stage1Deadline);
  const stage2Timeout = r.stage2Deadline > 0n && !r.stage2Done && now > Number(r.stage2Deadline);

  let ground: string | null = null;
  if (state === "Closing") {
    if (pastDeadline && proofsMissing) ground = "proof timeout";
    else if (stage1Timeout || stage2Timeout) ground = "unanswered disclosure request";
    else if (disputeOpen && pastDeadline) ground = "dispute open past the deadline";
  }

  const actionable: string[] = [];
  if (state === "Closing") {
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
    deadlines, openRequests, disputeOpen,
    cancellable: { possible: ground !== null, ground },
    actionable,
  };
}

export async function coverage(chain: Chain, id: Identity, store: Store, day: number): Promise<{ day: number; held: number; expected: number; missing: number[] }> {
  const clock = await chain.clock();
  const upTo = day === clock.day ? clock.t : SESSIONS - 1;
  const held = store.sessionsOf(day).map((r) => r.t);
  const missing: number[] = [];
  for (let t = 0; t <= upTo; t++) if (!held.includes(t)) missing.push(t);
  return { day, held: held.length, expected: upTo + 1, missing };
}
