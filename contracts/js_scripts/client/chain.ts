// Read and write access to MarketV4 (and its token) for one member, through ethers and RPC_URL.
// Reads public state only: sessions, day closes, commitments, frozen queues and recourse events.

import { ethers } from "ethers";
import { config } from "./config.js";

// The part of the MarketV4 ABI the client uses.
const MARKET_ABI = [
  "function register(bytes encryptionKey)",
  "function deposit(uint256 amount)",
  "function requestWithdraw(uint256 amount)",
  "function requestData(uint256 dayId)",
  "function requestClearReveal(uint256 dayId)",
  "function cancelDay(uint256 dayId,uint256 revealSlot,string reason)",
  "function slotOf(address) view returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
  "function encryptionKeyOf(uint256) view returns (bytes)",
  "function prosumerCount() view returns (uint256)",
  "function balCommitOf(uint256) view returns (bytes32)",
  "function floorCommitOf(uint256) view returns (bytes32)",
  "function pendingFloorCommit(uint256) view returns (bytes32)",
  "function pendingDeposit(uint256) view returns (uint256)",
  "function pendingWithdrawal(uint256) view returns (uint256)",
  "function snapDeposit(uint256,uint256) view returns (uint256)",
  "function snapWithdrawal(uint256,uint256) view returns (uint256)",
  "function snapFloorCommit(uint256,uint256) view returns (bytes32)",
  "function stagedCommit(uint256,uint256) view returns (bytes32)",
  "function stagedWithdrawalPaid(uint256,uint256) view returns (uint256)",
  "function netputHashOf(uint256,uint256) view returns (bytes32)",
  "function netputHashesPosted(uint256) view returns (bool)",
  "function sessions(uint256,uint256) view returns (uint32 s,uint32 d,uint32 priceR,uint32 priceC,uint32 lambdaLo,uint32 lambdaHi,bool opened)",
  "function dayCloses(uint256) view returns (uint8 state,uint256 chunksVerified,uint256 accPaidOut,uint256 accPaidIn,uint256 disputeDeadline,uint256 prosumerCountAt)",
  "function chunkCountFor(uint256) view returns (uint256)",
  "function reveals(uint256,uint256) view returns (uint64 stage1Deadline,uint64 stage2Deadline,bool stage1Done,bool stage2Done)",
  "function SETTLEMENT_GRACE() view returns (uint256)",
  "function finalizeDay(uint256 dayId)",
  "function sweepDust()",
  "function dustPot() view returns (uint256)",
  "function openRevealCount(uint256) view returns (uint256)",
  "function currentDayId() view returns (uint256)",
  "function currentSessionIdx() view returns (uint256)",
  "function eeur() view returns (address)",
  "function operator() view returns (address)",
  "function WEI_PER_UNIT() view returns (uint256)",
  "function REVEAL_WINDOW() view returns (uint256)",
  "function ZERO_BAL_COMMIT() view returns (bytes32)",
  "event EncryptedDataPosted(uint256 indexed dayId,uint256 slot,bytes blob)",
  "event BalanceRevealed(uint256 indexed dayId,uint256 slot,uint64 bal)",
  "event DayFinalized(uint256 indexed dayId,uint256 paidOut,uint256 paidIn)",
  "event DayCancelled(uint256 indexed dayId,string reason)",
  "event FloorProposed(uint256 indexed slot,bytes32 floorCommit)",
  "event FloorSet(uint256 indexed slot)",
];

// Token calls for deposits (approve) and balances.
const ERC20_ABI = [
  "function approve(address spender,uint256 amount) returns (bool)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
];

// Typed copies of MarketV4 structs.
export type SessionView = {
  s: bigint; d: bigint; priceR: bigint; priceC: bigint;
  lambdaLo: bigint; lambdaHi: bigint; opened: boolean;
};

export type DayCloseView = {
  state: number; chunksVerified: bigint; accPaidOut: bigint;
  accPaidIn: bigint; disputeDeadline: bigint; prosumerCountAt: bigint;
};

export type RevealView = {
  stage1Deadline: bigint; stage2Deadline: bigint;
  stage1Done: boolean; stage2Done: boolean;
};

export const DAY_STATE = ["Pending", "Closing", "Finalized", "Cancelled"] as const; // index = MarketV4.DayState

// Member-side handle on the market; read-only when built without a signer.
export class Chain {
  readonly provider: ethers.JsonRpcProvider;
  readonly market: ethers.Contract;
  private token: ethers.Contract | null = null;

  constructor(private signer?: ethers.Wallet) {
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    if (signer) this.signer = signer.connect(this.provider) as ethers.Wallet; // signs as the member
    this.market = new ethers.Contract(config.marketAddress, MARKET_ABI, this.signer ?? this.provider);
  }

  async chainId(): Promise<bigint> {
    return (await this.provider.getNetwork()).chainId;
  }

  async now(): Promise<number> {
    const b = await this.provider.getBlock("latest"); // chain time, the only clock the contract trusts
    if (!b) throw new Error("no latest block");
    return b.timestamp;
  }

  async clock(): Promise<{ day: number; t: number }> {
    const ts = await this.now();
    return { day: Math.floor(ts / 86400), t: Math.floor((ts % 86400) / 900) }; // same day and session numbering as MarketV4
  }

  async eeur(): Promise<ethers.Contract> {
    if (this.token) return this.token;
    const addr = config.eeurAddress || (await this.market.eeur()); // EEUR_ADDRESS, else the market's token
    this.token = new ethers.Contract(addr, ERC20_ABI, this.signer ?? this.provider);
    return this.token;
  }

  async slotOf(address: string): Promise<number> {
    return Number(await this.market.slotOf(address));
  }

  async register(pubkey: string): Promise<string> {
    const tx = await this.market.register(pubkey);
    const rc = await tx.wait(); // waits for inclusion
    return rc.hash;
  }

  async session(day: number, t: number): Promise<SessionView> {
    const r = await this.market.sessions(day, t);
    return {
      s: BigInt(r[0]), d: BigInt(r[1]), priceR: BigInt(r[2]), priceC: BigInt(r[3]),
      lambdaLo: BigInt(r[4]), lambdaHi: BigInt(r[5]), opened: Boolean(r[6]),
    };
  }

  async dayClose(day: number): Promise<DayCloseView> {
    const r = await this.market.dayCloses(day);
    return {
      state: Number(r[0]), chunksVerified: BigInt(r[1]), accPaidOut: BigInt(r[2]),
      accPaidIn: BigInt(r[3]), disputeDeadline: BigInt(r[4]), prosumerCountAt: BigInt(r[5]),
    };
  }

  async revealOf(day: number, slot: number): Promise<RevealView> {
    const r = await this.market.reveals(day, slot);
    return {
      stage1Deadline: BigInt(r[0]), stage2Deadline: BigInt(r[1]),
      stage1Done: Boolean(r[2]), stage2Done: Boolean(r[3]),
    };
  }

  async balCommit(slot: number): Promise<string> {
    return await this.market.balCommitOf(slot);
  }

  async stagedCommit(day: number, slot: number): Promise<string> {
    return await this.market.stagedCommit(day, slot);
  }

  async netputHash(day: number, slot: number): Promise<string> {
    return await this.market.netputHashOf(day, slot);
  }

  async floorCommit(slot: number): Promise<string> {
    return await this.market.floorCommitOf(slot);
  }

  async snapshot(day: number, slot: number): Promise<{ deposit: bigint; withdrawal: bigint; floorCommit: string }> { // queues frozen at that day's midnight
    const [deposit, withdrawal, floorCommit] = await Promise.all([
      this.market.snapDeposit(day, slot),
      this.market.snapWithdrawal(day, slot),
      this.market.snapFloorCommit(day, slot),
    ]);
    return { deposit: BigInt(deposit), withdrawal: BigInt(withdrawal), floorCommit };
  }

  async pending(slot: number): Promise<{ deposit: bigint; withdrawal: bigint }> { // queues not yet applied
    const [deposit, withdrawal] = await Promise.all([
      this.market.pendingDeposit(slot),
      this.market.pendingWithdrawal(slot),
    ]);
    return { deposit: BigInt(deposit), withdrawal: BigInt(withdrawal) };
  }

  async encryptedDataFor(day: number, slot: number, fromBlock = 0): Promise<string[]> { // stage 1 answers for this member and day, as encrypted blobs
    const f = this.market.filters.EncryptedDataPosted(day); // dayId is indexed, slot is filtered below
    const logs = await this.market.queryFilter(f, fromBlock, "latest");
    const events = logs.filter((l): l is ethers.EventLog => "args" in l);
    return events
      .filter((l) => Number(l.args[1]) === slot)
      .map((l) => l.args[2] as string);
  }
}
