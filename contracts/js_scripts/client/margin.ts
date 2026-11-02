// Margin check: projects the member's balance at the end of the current day from yesterday's
// day-close balance and today's session receipts at the on-chain prices, and compares it to the floor.
// Tiers: critical below 1.0 x floor (trading stops at the next close), warning below 1.2 x floor.

import { Chain } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { config } from "./config.js";
import { peurToEur } from "./units.js";
// Formats pEUR as currency with two decimals.
function eur2(peur: bigint): string {
  return Number(peurToEur(peur)).toFixed(2); // display rounding only
}

export type MarginState = {
  day: number;
  slot: number;
  sessionsCounted: number;
  earnedPeur: string;
  spentPeur: string;
  netSpendPeur: string;
  openingBalancePeur: string | null;
  projectedPeur: string | null;
  projectedConservativePeur: string | null;
  incomingDepositPeur: string;
  floorPeur: string | null;
  projectedEur: string | null;
  floorEur: string | null;
  tier: "ok" | "warning" | "critical" | "unknown";
  headroomPeur: string | null;
  message: string;
};

// Projected balance and margin tier for a day (today by default).
export async function marginState(chain: Chain, id: Identity, store: Store, dayArg?: number): Promise<MarginState> {
  const slot = store.slot || (await chain.slotOf(id.address));
  if (slot === 0) throw new Error("not registered");

  const clock = await chain.clock();
  const day = dayArg ?? clock.day; // today by default

  const rows = store.sessionsOf(day);
  let earned = 0n;
  let spent = 0n;
  let counted = 0;
  for (const row of rows) {
    const sell = BigInt(row.sell);
    const buy = BigInt(row.buy);
    if (sell === 0n && buy === 0n) continue; // idle session, nothing to price
    const s = await chain.session(day, row.t);
    if (!s.opened) continue; // never opened: counts as zero on chain
    earned += s.priceR * sell; // same product as the circuit: price x Wh = pEUR
    spent += s.priceC * buy;
    counted++;
  }
  const netSpend = spent - earned;

  const prev = store.opening(day - 1); // opening of yesterday's balance commitment
  const floor = store.floor(); // opening of the floor commitment

  if (!prev || !floor) { // cannot anchor the projection
    return {
      day, slot, sessionsCounted: counted,
      earnedPeur: earned.toString(), spentPeur: spent.toString(), netSpendPeur: netSpend.toString(),
      openingBalancePeur: prev ? prev.balance : null,
      projectedPeur: null, projectedConservativePeur: null, incomingDepositPeur: "0", floorPeur: floor ? floor.floor : null,
      projectedEur: null, floorEur: floor ? peurToEur(BigInt(floor.floor)) : null,
      tier: "unknown", headroomPeur: null,
      message: !prev
        ? `no day-close packet for day ${day - 1}: cannot anchor the opening balance`
        : "no opening held for the minimum balance requirement: ask the operator for it",
    };
  }

  const opening = BigInt(prev.balance);
  const snap = await chain.pending(slot);
  let alreadyIn = 0n;
  if (snap.deposit > 0n) { // part of the pending deposit may already be applied by yesterday's close
    try {
      // deposit frozen at yesterday's midnight
      const frozen = (await chain.market.snapDeposit(day - 1, slot)) as bigint;
      alreadyIn = BigInt(frozen) < snap.deposit ? BigInt(frozen) : snap.deposit;
    } catch {
      alreadyIn = 0n;
    }
  }
  const incomingDeposit = snap.deposit - alreadyIn; // deposits that will reach today's balance

  const projected = opening + earned + incomingDeposit - spent; // expected end-of-day balance
  // worst case: a net gain and incoming deposits are ignored
  const conservative = opening - (netSpend > 0n ? netSpend : 0n);
  const f = BigInt(floor.floor);

  let tier: MarginState["tier"] = "ok";
  if (conservative * config.marginDen < f * config.marginCritNum) tier = "critical"; // balance < 1.0 x floor
  else if (conservative * config.marginDen < f * config.marginWarnNum) tier = "warning"; // balance < 1.2 x floor

  const headroom = conservative - f;
  const message =
    tier === "critical"
      ? `below the requirement by ${eur2(-headroom)} EUR: trading stops at the next close`
      : tier === "warning"
        ? `${eur2(headroom)} EUR above the requirement: consider depositing`
        : `${eur2(headroom)} EUR above the requirement`;

  return {
    day, slot, sessionsCounted: counted,
    earnedPeur: earned.toString(), spentPeur: spent.toString(), netSpendPeur: netSpend.toString(),
    openingBalancePeur: opening.toString(),
    projectedPeur: projected.toString(),
    projectedConservativePeur: conservative.toString(),
    incomingDepositPeur: incomingDeposit.toString(),
    floorPeur: f.toString(),
    projectedEur: peurToEur(projected),
    floorEur: peurToEur(f),
    tier, headroomPeur: headroom.toString(),
    message,
  };
}

// True once per day and tier, so each alert is raised only once.
export function shouldNotify(store: Store, day: number, tier: MarginState["tier"]): boolean {
  if (tier !== "warning" && tier !== "critical") return false;
  const key = `alert-${day}-${tier}`;
  if (store.verdict(key)) return false;
  store.putVerdict(key, { at: new Date().toISOString() });
  return true;
}
