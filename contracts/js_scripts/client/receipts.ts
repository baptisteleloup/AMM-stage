import { ethers } from "ethers";
import { decrypt } from "eciesjs";
import { Chain } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { makeTransport, type Transport, type RawSessionReceipt, type RawDayClosePacket } from "./transport.js";
import { SESSIONS } from "./config.js";

const TYPES_SESSION = {
  SessionReceipt: [
    { name: "day", type: "uint256" },
    { name: "t", type: "uint256" },
    { name: "slot", type: "uint256" },
    { name: "sell", type: "uint32" },
    { name: "buy", type: "uint32" },
  ],
};

const TYPES_DAYCLOSE = {
  DayClosePacket: [
    { name: "day", type: "uint256" },
    { name: "slot", type: "uint256" },
    { name: "newBalance", type: "uint64" },
    { name: "newBlind", type: "bytes32" },
    { name: "netputBlind", type: "bytes32" },
  ],
};

export type IngestReport = {
  day: number;
  slot: number;
  newSessions: number[];
  badSignatures: number[];
  wrongSlot: number[];
  dayCloseIngested: boolean;
  dayCloseRejected: string | null;
  floorIngested: boolean;
  coverage: string;
};

export class ReceiptInbox {
  private domain: ethers.TypedDataDomain | null = null;
  private operator: string | null = null;
  private transport: Transport;

  constructor(private chain: Chain, private id: Identity, private store: Store) {
    this.transport = makeTransport();
  }

  private async ctx(): Promise<{ domain: ethers.TypedDataDomain; operator: string }> {
    if (!this.domain || !this.operator) {
      const chainId = await this.chain.chainId();
      this.domain = {
        name: "EnergyMarket",
        version: "4",
        chainId,
        verifyingContract: await this.chain.market.getAddress(),
      };
      this.operator = ((await this.chain.market.operator()) as string).toLowerCase();
    }
    return { domain: this.domain, operator: this.operator };
  }

  private async checkSession(r: RawSessionReceipt, slot: number): Promise<"ok" | "sig" | "slot"> {
    if (Number(r.slot) !== slot) return "slot";
    const { domain, operator } = await this.ctx();
    const message = {
      day: r.day, t: r.t, slot: r.slot,
      sell: Number(r.sell), buy: Number(r.buy),
    };
    try {
      const signer = ethers.verifyTypedData(domain, TYPES_SESSION, message, r.sig);
      return signer.toLowerCase() === operator ? "ok" : "sig";
    } catch {
      return "sig";
    }
  }

  private async checkDayClose(p: RawDayClosePacket, slot: number): Promise<"ok" | "sig" | "slot"> {
    if (Number(p.slot) !== slot) return "slot";
    const { domain, operator } = await this.ctx();
    const message = {
      day: p.day, slot: p.slot,
      newBalance: BigInt(p.newBalance),
      newBlind: p.newBlind,
      netputBlind: p.netputBlind,
    };
    try {
      const signer = ethers.verifyTypedData(domain, TYPES_DAYCLOSE, message, p.sig);
      return signer.toLowerCase() === operator ? "ok" : "sig";
    } catch {
      return "sig";
    }
  }

  async tick(day?: number): Promise<IngestReport> {
    const slot = this.store.slot || (await this.chain.slotOf(this.id.address));
    if (slot === 0) throw new Error("not registered");

    const clock = await this.chain.clock();
    const d = day ?? clock.day;
    const upTo = d === clock.day ? clock.t : SESSIONS - 1;

    const newSessions: number[] = [];
    const badSignatures: number[] = [];
    const wrongSlot: number[] = [];

    for (let t = 0; t <= upTo; t++) {
      if (this.store.session(d, t)) continue;
      const r = await this.transport.session(slot, d, t);
      if (!r) continue;
      const verdict = await this.checkSession(r, slot);
      if (verdict === "sig") { badSignatures.push(t); continue; }
      if (verdict === "slot") { wrongSlot.push(t); continue; }
      this.store.putSession({ day: d, t, sell: String(r.sell), buy: String(r.buy), sig: r.sig });
      newSessions.push(t);
    }

    let dayCloseIngested = false;
    let dayCloseRejected: string | null = null;
    if (!this.store.opening(d)) {
      const p = await this.transport.dayClose(slot, d);
      if (p) {
        const verdict = await this.checkDayClose(p, slot);
        if (verdict === "ok") {
          this.store.putOpening(d, { balance: String(p.newBalance), blind: p.newBlind, netputBlind: p.netputBlind });
          dayCloseIngested = true;
        } else {
          dayCloseRejected = verdict === "sig" ? "signature not from operator" : "packet addressed to another slot";
        }
      }
    }

    let floorIngested = false;
    if (!this.store.floor()) {
      const f = await this.transport.floorOpening(slot);
      if (f && Number(f.slot) === slot) {
        this.store.setFloor({ floor: String(f.floor), blind: f.blind });
        floorIngested = true;
      }
    }

    const have = this.store.sessionsOf(d).length;
    return {
      day: d, slot, newSessions, badSignatures, wrongSlot,
      dayCloseIngested, dayCloseRejected, floorIngested,
      coverage: `${have}/${upTo + 1} sessions held for day ${d}`,
    };
  }

  async ingestOnChainBlob(day: number): Promise<{ sessions: number; opening: boolean; source: string }> {
    const slot = this.store.slot || (await this.chain.slotOf(this.id.address));
    if (slot === 0) throw new Error("not registered");

    const blobs = await this.chain.encryptedDataFor(day, slot);
    if (blobs.length === 0) throw new Error(`no encrypted data posted on chain for day ${day}`);

    const cipher = Buffer.from(blobs[blobs.length - 1].slice(2), "hex");
    const plain = Buffer.from(decrypt(this.id.decryptionKeyHex, cipher)).toString("utf-8");
    const parsed = JSON.parse(plain) as {
      day: number;
      slot: number;
      receipts: Record<string, RawSessionReceipt | RawDayClosePacket>;
      opening: { balance: string; blind: string; netputBlind?: string } | null;
    };

    if (Number(parsed.slot) !== slot) throw new Error("blob addressed to another slot");

    let sessions = 0;
    for (const [name, body] of Object.entries(parsed.receipts ?? {})) {
      const m = /^t-(\d+)\.json$/.exec(name);
      if (!m) continue;
      const r = body as RawSessionReceipt;
      const verdict = await this.checkSession(r, slot);
      if (verdict !== "ok") continue;
      this.store.putSession({ day, t: Number(m[1]), sell: String(r.sell), buy: String(r.buy), sig: r.sig });
      sessions++;
    }

    let opening = false;
    if (parsed.opening && !this.store.opening(day)) {
      this.store.putOpening(day, {
        balance: String(parsed.opening.balance),
        blind: parsed.opening.blind,
        netputBlind: parsed.opening.netputBlind ?? "0x0",
      });
      opening = true;
    }

    return { sessions, opening, source: "on-chain encrypted blob" };
  }
}
