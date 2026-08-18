import { ethers } from "ethers";
import { WEI_PER_UNIT } from "./config.js";

export const PEUR_PER_EUR = 1_000_000_000_000n;

export function eurToWei(eur: string): bigint {
  return ethers.parseUnits(eur, 18);
}

export function weiToEur(wei: bigint): string {
  return ethers.formatUnits(wei, 18);
}

export function weiToPeur(wei: bigint): bigint {
  if (wei % WEI_PER_UNIT !== 0n) throw new Error(`amount is not a whole pEUR: ${wei} wei`);
  return wei / WEI_PER_UNIT;
}

export function peurToWei(peur: bigint): bigint {
  return peur * WEI_PER_UNIT;
}

export function peurToEur(peur: bigint): string {
  const sign = peur < 0n ? "-" : "";
  const abs = peur < 0n ? -peur : peur;
  const whole = abs / PEUR_PER_EUR;
  const frac = abs % PEUR_PER_EUR;
  if (frac === 0n) return `${sign}${whole}`;
  const decimals = frac.toString().padStart(12, "0").replace(/0+$/, "");
  return `${sign}${whole}.${decimals}`;
}

export function roundDownToUnit(wei: bigint): bigint {
  return (wei / WEI_PER_UNIT) * WEI_PER_UNIT;
}
