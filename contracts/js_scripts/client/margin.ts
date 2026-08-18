import { Chain } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { config } from "./config.js";
import { peurToEur } from "./units.js";

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

export async function marginState(chain: Chain, id: Identity, store: Store, dayArg?: number): Promise<MarginState> {
  const slot = store.slot || (await chain.slotOf(id.address));
  if (slot === 0) throw new Error("not registered");

  const clock = await chain.clock();
  const day = dayArg ?? clock.day;

  const rows = store.sessionsOf(day);
  let earned = 0n;
  let spent = 0n;
  let counted = 0;
  for (const row of rows) {
    const sell = BigInt(row.sell);
    const buy = BigInt(row.buy);
    if (sell === 0n && buy === 0n) continue;
    const s = await chain.session(day, row.t);
    if (!s.opened) continue;
    earned += s.priceR * sell;
    spent += s.priceC * buy;
    counted++;
  }
  const netSpend = spent - earned;

  const prev = store.opening(day - 1);
  const floor = store.floor();

  if (!prev || !floor) {
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

  // The queue holds money that may already be inside `opening`. A deposit is
  // frozen for a day at that day's close and the packet for that day adds it in
  // straight away, but the on-chain queue only empties at settlement — a whole
  // objection window later. Adding the raw queue to the opening counts the same
  // euros twice, which is how a 200 EUR account came to show 399 EUR projected.
  let alreadyIn = 0n;
  if (snap.deposit > 0n) {
    try {
      const frozen = (await chain.market.snapDeposit(day - 1, slot)) as bigint;
      alreadyIn = BigInt(frozen) < snap.deposit ? BigInt(frozen) : snap.deposit;
    } catch {
      alreadyIn = 0n;
    }
  }
  const incomingDeposit = snap.deposit - alreadyIn;

  const projected = opening + earned + incomingDeposit - spent;
  const conservative = opening - (netSpend > 0n ? netSpend : 0n);
  const f = BigInt(floor.floor);

  let tier: MarginState["tier"] = "ok";
  if (conservative * config.marginDen < f * config.marginCritNum) tier = "critical";
  else if (conservative * config.marginDen < f * config.marginWarnNum) tier = "warning";

  const headroom = conservative - f;
  const message =
    tier === "critical"
      ? `projected balance is below the requirement: trading would stop at the next close (headroom ${peurToEur(headroom)} EUR)`
      : tier === "warning"
        ? `projected balance is within 20% of the requirement (headroom ${peurToEur(headroom)} EUR): consider depositing`
        : `projected balance clears the requirement with ${peurToEur(headroom)} EUR of headroom`;

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

export function shouldNotify(store: Store, day: number, tier: MarginState["tier"]): boolean {
  if (tier !== "warning" && tier !== "critical") return false;
  const key = `alert-${day}-${tier}`;
  if (store.verdict(key)) return false;
  store.putVerdict(key, { at: new Date().toISOString() });
  return true;
}
