// Signed records the operator hands to members, as EIP-712 typed data, in
// RECEIPTS_DIR/slot-N/day-D/: one receipt per session (t-<t>.json), the day-close packet
// (day-close.json, needed for recourse and escape) and margin alerts (alerts.jsonl).

import fs from "node:fs";
import path from "node:path";
import { ethers } from "ethers";
import { config } from "./config.js";
import type { SessionBatch } from "./netputs.js";

const TYPES_SESSION = { // the position the operator used for this member in session t
  SessionReceipt: [
    { name: "day", type: "uint256" },
    { name: "t", type: "uint256" },
    { name: "slot", type: "uint256" },
    { name: "sell", type: "uint32" },
    { name: "buy", type: "uint32" },
  ],
};

const TYPES_DAYCLOSE = { // the opening of the member's new balance commitment
  DayClosePacket: [
    { name: "day", type: "uint256" },
    { name: "slot", type: "uint256" },
    { name: "newBalance", type: "uint64" },
    { name: "newBlind", type: "bytes32" },
    { name: "netputBlind", type: "bytes32" },
  ],
};

export class Receipts {
  private domain: ethers.TypedDataDomain;

  constructor(private wallet: ethers.Wallet, chainId: bigint) {
    this.domain = { // ties every signature to this market and chain
      name: "EnergyMarket",
      version: "4",
      chainId,
      verifyingContract: config.marketAddress,
    };
  }

  private dir(slot: number, day: number): string {
    const p = path.join(config.receiptsDir, `slot-${slot}`, `day-${day}`);
    fs.mkdirSync(p, { recursive: true });
    return p;
  }

  // One signed receipt per member in the batch.
  async writeSessionReceipts(day: number, t: number, batch: SessionBatch): Promise<void> {
    for (const [slot, np] of batch) {
      const message = { day, t, slot, sell: Number(np.sell), buy: Number(np.buy) };
      const sig = await this.wallet.signTypedData(this.domain, TYPES_SESSION, message);
      const receipt = { ...message, sell: np.sell.toString(), buy: np.buy.toString(), sig };
      fs.writeFileSync(path.join(this.dir(slot, day), `t-${t}.json`), JSON.stringify(receipt, null, 2));
    }
  }

  // Signed opening of the new balance after the day: balance, blinding and position seed.
  async writeDayClosePacket(day: number, slot: number, newBalance: bigint, newBlind: bigint, netputBlind: bigint): Promise<void> {
    const message = {
      day, slot,
      newBalance,
      newBlind: ethers.toBeHex(newBlind, 32),
      netputBlind: ethers.toBeHex(netputBlind, 32),
    };
    const sig = await this.wallet.signTypedData(this.domain, TYPES_DAYCLOSE, message);
    const packet = { day, slot, newBalance: newBalance.toString(), newBlind: message.newBlind, netputBlind: message.netputBlind, sig };
    fs.writeFileSync(path.join(this.dir(slot, day), "day-close.json"), JSON.stringify(packet, null, 2));
  }

  // Floor opening for the member (no caller; Store.putFloor writes the same file).
  writeFloorOpening(slot: number, floor: bigint, blind: bigint): void {
    const dir = path.join(config.receiptsDir, `slot-${slot}`);
    fs.mkdirSync(dir, { recursive: true });
    const packet = {
      slot,
      floor: floor.toString(),
      blind: ethers.toBeHex(blind, 32),
    };
    fs.writeFileSync(path.join(dir, "floor-opening.json"), JSON.stringify(packet, null, 2));
  }
  
  // Appends one margin alert to the day's alerts.jsonl.
  writeAlert(day: number, slot: number, tier: string, projected: bigint, floor: bigint): void {
    const line = JSON.stringify({
      day, tier,
      projectedBalance: projected.toString(),
      floor: floor.toString(),
      at: new Date().toISOString(),
    });
    fs.appendFileSync(path.join(this.dir(slot, day), "alerts.jsonl"), line + "\n");
  }
}
