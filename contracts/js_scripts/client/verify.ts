import { Chain, DAY_STATE } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { readMeter } from "./meter.js";
import { SESSIONS } from "./config.js";
import { peurToEur } from "./units.js";
import { hashNetputs, commitBalance, toHex32 } from "../scenario.js";

export type Check = {
  name: string;
  status: "pass" | "fail" | "skip";
  detail: string;
};

export type DayVerdict = {
  day: number;
  slot: number;
  dayState: string;
  checks: Check[];
  verdict: "verified" | "mismatch" | "incomplete";
  amountPeur: string | null;
  amountEur: string | null;
  newBalancePeur: string | null;
  discrepancies: { t: number; field: string; receipt: string; meter: string }[];
};

const ZERO32 = "0x" + "0".repeat(64);

function pad(hex: string): string {
  return hex.toLowerCase();
}

function norm(x: bigint): string {
  return pad(toHex32(x));
}

export async function verifyDay(chain: Chain, id: Identity, store: Store, day: number): Promise<DayVerdict> {
  const slot = store.slot || (await chain.slotOf(id.address));
  if (slot === 0) throw new Error("not registered");

  const checks: Check[] = [];
  const add = (name: string, status: Check["status"], detail: string) => checks.push({ name, status, detail });

  const dc = await chain.dayClose(day);
  const dayState = DAY_STATE[dc.state] ?? String(dc.state);

  const opening = store.opening(day);
  if (!opening) {
    add("day-close packet", "skip", "not received - run `sync` or exercise the data request");
    return {
      day, slot, dayState, checks, verdict: "incomplete",
      amountPeur: null, amountEur: null, newBalancePeur: null, discrepancies: [],
    };
  }

  const rows = store.sessionsOf(day);
  const sell: bigint[] = Array(SESSIONS).fill(0n);
  const buy: bigint[] = Array(SESSIONS).fill(0n);
  for (const r of rows) {
    sell[r.t] = BigInt(r.sell);
    buy[r.t] = BigInt(r.buy);
  }
  add("session receipts", rows.length > 0 ? "pass" : "skip",
    `${rows.length}/${SESSIONS} sessions held; missing ones are treated as zero`);

  for (let t = 0; t < SESSIONS; t++) {
    if (sell[t] !== 0n && buy[t] !== 0n) {
      add("one side per session", "fail", `session ${t}: both sell=${sell[t]} and buy=${buy[t]} are non-zero`);
      break;
    }
  }
  if (!checks.some((c) => c.name === "one side per session")) {
    add("one side per session", "pass", "no session has both a sale and a purchase");
  }

  const nblind = BigInt(opening.netputBlind);
  const computedHash = await hashNetputs(BigInt(slot), nblind, sell, buy);
  const onchainHash = await chain.netputHash(day, slot);
  const hashOk = norm(computedHash) === pad(onchainHash);
  add("netput fingerprint", hashOk ? "pass" : "fail",
    hashOk
      ? "locally recomputed chained hash matches the one posted on chain"
      : `computed ${norm(computedHash)} but chain holds ${pad(onchainHash)}`);

  let paidOut = 0n;
  let paidIn = 0n;
  const priceMissing: number[] = [];
  for (let t = 0; t < SESSIONS; t++) {
    if (sell[t] === 0n && buy[t] === 0n) continue;
    const s = await chain.session(day, t);
    if (!s.opened) { priceMissing.push(t); continue; }
    paidOut += s.priceR * sell[t];
    paidIn += s.priceC * buy[t];
  }
  if (priceMissing.length > 0) {
    add("session prices", "fail", `traded in sessions with no price on chain: ${priceMissing.join(",")}`);
  } else {
    add("session prices", "pass", "every traded session has a price stored on chain");
  }

  const snap = await chain.snapshot(day, slot);

  const floor = store.floor();
  if (!floor) {
    add("minimum balance requirement", "skip", "no opening held for the requirement - cannot check participation");
  } else {
    const fc = await commitBalance(BigInt(floor.floor), BigInt(floor.blind));
    const ok = norm(fc) === pad(snap.floorCommit);
    add("minimum balance requirement", ok ? "pass" : "fail",
      ok ? `opening matches the commitment frozen for day ${day}`
         : `opening does not match the frozen commitment (${pad(snap.floorCommit)})`);
  }

  const prevOpening = store.opening(day - 1);
  let oldBal: bigint;
  let oldBlind: bigint;
  if (prevOpening) {
    oldBal = BigInt(prevOpening.balance);
    oldBlind = BigInt(prevOpening.blind);
  } else {
    oldBal = 0n;
    oldBlind = 0n;
  }

  const zeroCommit = (await chain.market.ZERO_BAL_COMMIT()) as string;
  const oldCommitComputed = await commitBalance(oldBal, oldBlind);
  const oldCommitIsZero = norm(oldCommitComputed) === pad(zeroCommit);
  if (!prevOpening && oldCommitIsZero) {
    add("opening balance", "skip", "no packet for the previous day; assuming an untouched account (balance zero)");
  } else if (!prevOpening) {
    add("opening balance", "skip", "no packet for the previous day - transition cannot be chained");
  } else {
    add("opening balance", "pass", `chained from day ${day - 1}: ${peurToEur(oldBal)} EUR`);
  }

  if (!floor) {
    add("participation", "skip", "no requirement opening held - cannot tell whether trading was allowed");
  } else if (!prevOpening) {
    add("participation", "skip", `opening balance unknown without the day ${day - 1} packet`);
  } else {
    const participating = oldBal >= BigInt(floor.floor);
    const traded = sell.some((v) => v !== 0n) || buy.some((v) => v !== 0n);
    if (!participating && traded) {
      add("participation", "fail", "receipts show trades while the opening balance was below the requirement");
    } else {
      add("participation", "pass", participating
        ? "opening balance cleared the requirement"
        : "below the requirement, and no trade recorded");
    }
  }

  const afterTrade = oldBal + paidOut + snap.deposit - paidIn;
  const paid = snap.withdrawal < afterTrade ? snap.withdrawal : afterTrade;
  const newBal = afterTrade - paid;
  const claimed = BigInt(opening.balance);

  // The transition can only be checked against a known opening balance. Without
  // the previous day's packet there is nothing to chain from, and assuming zero
  // would turn a gap in what we hold into an accusation that the operator lied.
  // Report what is missing instead, and say what opening the packet implies so
  // it can be cross-checked by other means.
  if (!prevOpening) {
    const implied: bigint =
      claimed + paid + paidIn - BigInt(snap.deposit) - paidOut;
    add("balance transition", "skip",
      `cannot be chained: no packet for day ${day - 1}. Collect that day's receipts `
      + `and check again. Taken at face value this packet implies an opening balance `
      + `of ${peurToEur(implied)} EUR.`);
  } else {
    const balOk = newBal === claimed;
    add("balance transition", balOk ? "pass" : "fail",
      balOk
        ? `old ${peurToEur(oldBal)} + earned ${peurToEur(paidOut)} + deposit ${peurToEur(snap.deposit)} - spent ${peurToEur(paidIn)} - withdrawn ${peurToEur(paid)} = ${peurToEur(newBal)} EUR`
        : `recomputed ${peurToEur(newBal)} EUR but the packet claims ${peurToEur(claimed)} EUR`);
  }

  const stagedPaid = await chain.market.stagedWithdrawalPaid(day, slot);
  if (snap.withdrawal > 0n && !prevOpening) {
    add("withdrawal payout", "skip",
      `the payout is min(request, available) and the available balance is unknown `
      + `without the day ${day - 1} packet`);
  } else if (snap.withdrawal > 0n) {
    const ok = BigInt(stagedPaid) === paid;
    add("withdrawal payout", ok ? "pass" : "fail",
      ok ? `${peurToEur(paid)} EUR paid of ${peurToEur(snap.withdrawal)} requested`
         : `chain staged ${stagedPaid} but min(request, available) is ${paid}`);
    if (ok && paid < snap.withdrawal) {
      add("withdrawal disclosure", "pass",
        "payout was capped: this is public and reveals the available balance was exactly the amount paid");
    }
  }

  const commitComputed = await commitBalance(claimed, BigInt(opening.blind));
  const staged = await chain.stagedCommit(day, slot);
  const settled = await chain.balCommit(slot);
  const target = staged !== ZERO32 ? staged : settled;
  const commitOk = norm(commitComputed) === pad(target);
  add("balance commitment", commitOk ? "pass" : "fail",
    commitOk
      ? `opening matches the commitment held on chain (${staged !== ZERO32 ? "staged" : "settled"})`
      : `opening hashes to ${norm(commitComputed)} but chain holds ${pad(target)}`);

  const discrepancies: DayVerdict["discrepancies"] = [];
  const meter = readMeter(day);
  if (!meter) {
    add("meter comparison", "skip", "no meter data configured (set METER_PATH)");
  } else {
    for (let t = 0; t < SESSIONS; t++) {
      if (meter.sell[t] !== sell[t]) {
        discrepancies.push({ t, field: "sell", receipt: sell[t].toString(), meter: meter.sell[t].toString() });
      }
      if (meter.buy[t] !== buy[t]) {
        discrepancies.push({ t, field: "buy", receipt: buy[t].toString(), meter: meter.buy[t].toString() });
      }
    }
    add("meter comparison", discrepancies.length === 0 ? "pass" : "fail",
      discrepancies.length === 0
        ? "committed net positions match the meter on every session"
        : `${discrepancies.length} session(s) differ from the meter - grounds for a dispute`);
  }

  const failed = checks.some((c) => c.status === "fail");
  const skipped = checks.some((c) => c.status === "skip" && c.name !== "meter comparison");
  const verdict: DayVerdict["verdict"] = failed ? "mismatch" : skipped ? "incomplete" : "verified";

  const out: DayVerdict = {
    day, slot, dayState, checks, verdict,
    amountPeur: (paidOut - paidIn).toString(),
    amountEur: peurToEur(paidOut - paidIn),
    newBalancePeur: newBal.toString(),
    discrepancies,
  };
  store.putVerdict(`day-${day}`, { verdict, at: new Date().toISOString(), failed: checks.filter((c) => c.status === "fail").map((c) => c.name) });
  return out;
}
