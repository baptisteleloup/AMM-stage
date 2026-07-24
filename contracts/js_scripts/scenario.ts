import { readFileSync } from "fs";
import { Noir } from "@noir-lang/noir_js";

export const SESSIONS = 96;
export const BATCH = 8;
export const N_PROSUMERS = 2; // alice = slot 1, bob = slot 2

export const FLOOR = 31_000_000_000_000n; // 31 EUR in pEUR
export const DEPOSIT_D0 = 50_000_000_000_000n; // 50 EUR in pEUR

export const T1 = 10;
export const T2 = 50;
export const ALICE_SELL_T1 = 100n; // Wh
export const BOB_BUY_T1 = 100n;
export const BOB_BUY_T2 = 200n;


export const blind = (day: number, slot: number): bigint =>
  slot === 0 ? 0n : 1_000_003n * BigInt(day + 1) + BigInt(slot);

export const floorBlind = (slot: number): bigint =>
  slot === 0 ? 0n : 9_000_017n + BigInt(slot);


export const netputBlind = (day: number, slot: number): bigint =>
  slot === 0 ? 0n : 5_000_011n * BigInt(day + 1) + BigInt(slot);

export const toHex32 = (x: bigint): string =>
  "0x" + x.toString(16).padStart(64, "0");

let helper: Noir | null = null;
function getHelper(): Noir {
  if (helper === null) {
    const circuit = JSON.parse(
      readFileSync("circuits/poseidon_helper/target/poseidon_helper.json", "utf8"),
    );
    helper = new Noir(circuit);
  }
  return helper;
}

async function helperRun(
  slot: bigint,
  nblind: bigint,
  sell: bigint[],
  buy: bigint[],
  bal: bigint,
  b: bigint,
): Promise<[bigint, bigint]> {
  const { returnValue } = await getHelper().execute({
    slot: slot.toString(),
    nblind: nblind.toString(),
    sell: sell.map(String),
    buy: buy.map(String),
    bal: bal.toString(),
    blind: b.toString(),
  });
  const arr = (Array.isArray(returnValue) ? returnValue : [returnValue]) as unknown[];
  const flat = arr.flat(Infinity).map((v) => BigInt(v as string));
  if (flat.length !== 2) {
    throw new Error(`helper returned ${flat.length} values, expected 2`);
  }
  return [flat[0], flat[1]];
}

const ZEROS: bigint[] = Array(SESSIONS).fill(0n);

export async function hashNetputs(
  slot: bigint,
  nblind: bigint,
  sell: bigint[],
  buy: bigint[],
): Promise<bigint> {
  const [h] = await helperRun(slot, nblind, sell, buy, 0n, 0n);
  return h;
}

export async function commitBalance(bal: bigint, b: bigint): Promise<bigint> {
  const [, c] = await helperRun(0n, 0n, ZEROS, ZEROS, bal, b);
  return c;
}


export interface DayPrices {
  r: bigint[]; // price_r[96], pEUR/Wh, as stored on-chain (0 if unopened)
  c: bigint[]; // price_c[96]
}

export function emptyPrices(): DayPrices {
  return { r: Array(SESSIONS).fill(0n), c: Array(SESSIONS).fill(0n) };
}

export function netputsFor(day: 0 | 1) {
  const sell = Array.from({ length: BATCH }, () => Array(SESSIONS).fill(0n) as bigint[]);
  const buy = Array.from({ length: BATCH }, () => Array(SESSIONS).fill(0n) as bigint[]);
  if (day === 1) {
    sell[0][T1] = ALICE_SELL_T1; // alice, slot 1 -> index 0
    buy[1][T1] = BOB_BUY_T1; // bob, slot 2 -> index 1
    buy[1][T2] = BOB_BUY_T2;
  }
  return { sell, buy };
}


export async function dayState(day: 0 | 1, prices: DayPrices) {
  const { sell, buy } = netputsFor(day);

  const slots = Array.from({ length: BATCH }, (_, i) =>
    i < N_PROSUMERS ? BigInt(i + 1) : 0n,
  );
  const floors = slots.map((s) => (s === 0n ? 0n : FLOOR));
  const deposits = slots.map((s) => (day === 0 && s !== 0n ? DEPOSIT_D0 : 0n));
  const withdrawals = Array(BATCH).fill(0n) as bigint[];
  const withdrawalsPaid = Array(BATCH).fill(0n) as bigint[];


  const oldBals = slots.map((s) => (day === 1 && s !== 0n ? DEPOSIT_D0 : 0n));
  const oldBlinds = slots.map((s) =>
    day === 1 && s !== 0n ? blind(0, Number(s)) : 0n,
  );

  const floorBlinds = slots.map((s) => floorBlind(Number(s)));
  const netputBlinds = slots.map((s) => netputBlind(day, Number(s)));

  const paidOut = sell.map((row) => row.reduce((a, x, t) => a + prices.r[t] * x, 0n));
  const paidIn = buy.map((row) => row.reduce((a, x, t) => a + prices.c[t] * x, 0n));

  const newBals = oldBals.map(
    (b, i) => b + paidOut[i] - paidIn[i] + deposits[i] - withdrawalsPaid[i],
  );
  const newBlinds = slots.map((s) => (s === 0n ? 0n : blind(day, Number(s))));

  const oldCommits: bigint[] = [];
  const newCommits: bigint[] = [];
  const netputHashes: bigint[] = [];
  const floorCommits: bigint[] = [];
  for (let i = 0; i < BATCH; i++) {
    oldCommits.push(await commitBalance(oldBals[i], oldBlinds[i]));
    newCommits.push(await commitBalance(newBals[i], newBlinds[i]));
    netputHashes.push(await hashNetputs(slots[i], netputBlinds[i], sell[i], buy[i]));
    floorCommits.push(await commitBalance(floors[i], floorBlinds[i]));
  }

  const partialS = Array(SESSIONS).fill(0n) as bigint[];
  const partialD = Array(SESSIONS).fill(0n) as bigint[];
  for (let t = 0; t < SESSIONS; t++) {
    for (let n = 0; n < BATCH; n++) {
      partialS[t] += sell[n][t];
      partialD[t] += buy[n][t];
    }
  }
  const partialPaidOut = paidOut.reduce((a, x) => a + x, 0n);
  const partialPaidIn = paidIn.reduce((a, x) => a + x, 0n);

  return {
    sell, buy, slots, floors, floorBlinds, floorCommits, netputBlinds,
    deposits, withdrawals, withdrawalsPaid,
    oldBals, oldBlinds, oldCommits, newBals, newBlinds, newCommits,
    netputHashes, partialS, partialD,
    partialPaidOut, partialPaidIn,
  };
}
