import { ethers } from "ethers";
import { Chain } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { eurToWei, weiToPeur, peurToEur, roundDownToUnit } from "./units.js";
import { WEI_PER_UNIT } from "./config.js";

export type DepositResult = {
  amountEur: string;
  amountWei: string;
  amountPeur: string;
  approveTx: string | null;
  depositTx: string;
  pendingDepositPeur: string;
};

export type WithdrawResult = {
  requestedEur: string;
  requestedPeur: string;
  tx: string;
  pendingWithdrawalPeur: string;
  warning: string;
};

async function requireSlot(chain: Chain, id: Identity, store: Store): Promise<number> {
  const slot = await chain.slotOf(id.address);
  if (slot === 0) throw new Error("not registered: run `register` first");
  if (store.slot !== slot) store.setIdentity(slot, id.address, await chain.now());
  return slot;
}

export async function deposit(chain: Chain, id: Identity, store: Store, eur: string): Promise<DepositResult> {
  const slot = await requireSlot(chain, id, store);

  const raw = eurToWei(eur);
  const amount = roundDownToUnit(raw);
  if (amount === 0n) throw new Error(`amount too small: minimum is ${WEI_PER_UNIT} wei`);
  if (amount !== raw) {
    throw new Error(`amount must be a whole pEUR; ${eur} rounds to ${amount} wei, retry with that value`);
  }

  const token = await chain.eeur();
  const held = (await token.balanceOf(id.address)) as bigint;
  if (held < amount) {
    throw new Error(`insufficient token balance: have ${held} wei, need ${amount} wei`);
  }

  let approveTx: string | null = null;
  const allowance = (await token.allowance(id.address, chain.market.target)) as bigint;
  if (allowance < amount) {
    const tx = await token.approve(chain.market.target, amount);
    const rc = await tx.wait();
    approveTx = rc.hash;
  }

  const dtx = await chain.market.deposit(amount);
  const drc = await dtx.wait();

  const pending = await chain.pending(slot);
  return {
    amountEur: eur,
    amountWei: amount.toString(),
    amountPeur: weiToPeur(amount).toString(),
    approveTx,
    depositTx: drc.hash,
    pendingDepositPeur: pending.deposit.toString(),
  };
}

export async function requestWithdraw(chain: Chain, id: Identity, store: Store, eur: string): Promise<WithdrawResult> {
  const slot = await requireSlot(chain, id, store);

  const raw = eurToWei(eur);
  const amount = roundDownToUnit(raw);
  if (amount === 0n) throw new Error(`amount too small: minimum is ${WEI_PER_UNIT} wei`);
  if (amount !== raw) {
    throw new Error(`amount must be a whole pEUR; ${eur} rounds to ${amount} wei, retry with that value`);
  }

  const tx = await chain.market.requestWithdraw(amount);
  const rc = await tx.wait();
  const pending = await chain.pending(slot);

  return {
    requestedEur: eur,
    requestedPeur: weiToPeur(amount).toString(),
    tx: rc.hash,
    pendingWithdrawalPeur: pending.withdrawal.toString(),
    warning:
      "this is a request, not a guarantee: settlement pays min(requested, available). "
      + "A partial payout is public and reveals that the available balance was exactly the amount paid.",
  };
}

export type Position = {
  slot: number;
  pendingDepositPeur: string;
  pendingDepositEur: string;
  pendingWithdrawalPeur: string;
  pendingWithdrawalEur: string;
  balanceCommitment: string;
  knownBalancePeur: string | null;
  knownBalanceEur: string | null;
  knownAtDay: number | null;
  tokenBalanceWei: string;
  // How much of the queued deposit is already inside knownBalance. A deposit is
  // frozen for a day at that day's close, and the packet for that day already
  // adds it in — but the on-chain queue only empties at settlement, which is a
  // whole objection window later. Between the two the same money shows up in
  // both figures, and adding them would count it twice.
  depositAlreadyInBalancePeur: string;
  depositAlreadyInBalanceEur: string;
  // What is still to come: the queue minus the part the packet already counted.
  // This is the figure to show, because it is the one that changes the balance
  // from here on. The raw queue stays available above for anyone comparing the
  // screen with the chain.
  depositStillToApplyPeur: string;
  depositStillToApplyEur: string;
};

export async function position(chain: Chain, id: Identity, store: Store): Promise<Position> {
  const slot = await requireSlot(chain, id, store);
  const pending = await chain.pending(slot);
  const commit = await chain.balCommit(slot);
  const token = await chain.eeur();
  const held = (await token.balanceOf(id.address)) as bigint;

  let knownBalance: bigint | null = null;
  let knownAtDay: number | null = null;
  const { day } = await chain.clock();
  for (let d = day; d >= day - 30; d--) {
    const o = store.opening(d);
    if (o) {
      knownBalance = BigInt(o.balance);
      knownAtDay = d;
      break;
    }
  }

  // The freeze for the day whose packet we hold is exactly the part of the
  // queue that has already been counted.
  let counted = 0n;
  if (knownAtDay !== null && pending.deposit > 0n) {
    try {
      const frozen = (await chain.market.snapDeposit(knownAtDay, slot)) as bigint;
      counted = frozen < pending.deposit ? frozen : pending.deposit;
    } catch {
      counted = 0n;
    }
  }

  const stillToApply = pending.deposit - counted;

  return {
    slot,
    depositStillToApplyPeur: stillToApply.toString(),
    depositStillToApplyEur: peurToEur(stillToApply),
    depositAlreadyInBalancePeur: counted.toString(),
    depositAlreadyInBalanceEur: peurToEur(counted),
    pendingDepositPeur: pending.deposit.toString(),
    pendingDepositEur: peurToEur(pending.deposit),
    pendingWithdrawalPeur: pending.withdrawal.toString(),
    pendingWithdrawalEur: peurToEur(pending.withdrawal),
    balanceCommitment: commit,
    knownBalancePeur: knownBalance === null ? null : knownBalance.toString(),
    knownBalanceEur: knownBalance === null ? null : peurToEur(knownBalance),
    knownAtDay,
    tokenBalanceWei: held.toString(),
  };
}
