// Conversions between token wei (18 decimals), internal units pEUR (1e-12 of the currency) and
// decimal strings for display. The contract only accepts whole pEUR.

import { ethers } from "ethers";
import { WEI_PER_UNIT } from "./config.js";

export const PEUR_PER_EUR = 1_000_000_000_000n; // pEUR per unit of currency

export function eurToWei(eur: string): bigint { // decimal string -> wei
  return ethers.parseUnits(eur, 18);
}

export function weiToEur(wei: bigint): string { // wei -> decimal string
  return ethers.formatUnits(wei, 18);
}

export function weiToPeur(wei: bigint): bigint { // wei -> pEUR, rejects amounts the contract would refuse
  if (wei % WEI_PER_UNIT !== 0n) throw new Error(`amount is not a whole pEUR: ${wei} wei`);
  return wei / WEI_PER_UNIT;
}

export function peurToWei(peur: bigint): bigint { // pEUR -> wei
  return peur * WEI_PER_UNIT;
}

export function peurToEur(peur: bigint): string { // pEUR -> exact decimal string, without float rounding
  const sign = peur < 0n ? "-" : "";
  const abs = peur < 0n ? -peur : peur;
  const whole = abs / PEUR_PER_EUR;
  const frac = abs % PEUR_PER_EUR;
  if (frac === 0n) return `${sign}${whole}`;
  const decimals = frac.toString().padStart(12, "0").replace(/0+$/, ""); // 12 decimals, trailing zeros dropped
  return `${sign}${whole}.${decimals}`;
}

export function roundDownToUnit(wei: bigint): bigint { // largest whole-pEUR amount not above wei
  return (wei / WEI_PER_UNIT) * WEI_PER_UNIT;
}
