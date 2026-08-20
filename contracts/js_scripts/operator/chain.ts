import { ethers } from "ethers";
import { config } from "./config.js";

const ABI = [
  "function currentDayId() view returns (uint256)",
  "function currentSessionIdx() view returns (uint256)",
  "function sessions(uint256,uint256) view returns (uint32 s,uint32 d,uint32 priceR,uint32 priceC,uint32 lambdaLo,uint32 lambdaHi,bool opened)",
  "function openSession(uint256 dayId,uint256 t,uint32 s,uint32 d)",
  "function prosumerCount() view returns (uint256)",
  "function slotOf(address) view returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
  "function encryptionKeyOf(uint256) view returns (bytes)",
  "function floorCommitOf(uint256) view returns (bytes32)",
  "function proposeFloor(uint256 slot,bytes32 floorCommit)",
  "function postNetputHashes(uint256 dayId,bytes32[] hashes)",
  "function netputHashesPosted(uint256) view returns (bool)",
  "function snapDeposit(uint256,uint256) view returns (uint256)",
  "function snapWithdrawal(uint256,uint256) view returns (uint256)",
  "function snapFloorCommit(uint256,uint256) view returns (bytes32)",
  "function dayCloses(uint256) view returns (uint8 state,uint256 chunksVerified,uint256 accPaidOut,uint256 accPaidIn,uint256 disputeDeadline,uint256 prosumerCountAt)",
  "function chunkDone(uint256,uint256) view returns (bool)",
  "function submitChunk(uint256 dayId,uint256 k,(bytes32[] newCommits,uint256[] withdrawalsPaid,uint32[96] partialS,uint32[96] partialD,uint256 partialPaidOut,uint256 partialPaidIn) sub,bytes proof)",
  "function EMPTY_NETPUT_HASH() view returns (bytes32)",
  "function ZERO_BAL_COMMIT() view returns (bytes32)",
  "function reveals(uint256,uint256) view returns (uint64 stage1Deadline,uint64 stage2Deadline,bool stage1Done,bool stage2Done)",
  "function postEncryptedData(uint256 dayId,uint256 slot,bytes blob)",
  "function clearReveal(uint256 dayId,uint256 slot,uint64 bal,bytes proof)",
  "function cancelDay(uint256 dayId,uint256 revealSlot,string reason)",
  "function finalizeDay(uint256 dayId)",
  "function SETTLEMENT_GRACE() view returns (uint256)",
  "function lastClosedDay() view returns (uint256)",
  "function chunkCountFor(uint256) view returns (uint256)",
  "function openRevealCount(uint256) view returns (uint256)",
  "event DataRequested(uint256 indexed dayId,uint256 slot,uint8 stage)",
];

export type SessionView = {
  s: number; d: number; priceR: number; priceC: number;
  lambdaLo: number; lambdaHi: number; opened: boolean;
};

export type DayCloseView = {
  state: number; chunksVerified: number; prosumerCountAt: number;
  disputeDeadline: bigint;
};

export type RevealView = {
  stage1Deadline: bigint; stage2Deadline: bigint; stage1Done: boolean; stage2Done: boolean;
};

export type ChunkSubmission = {
  newCommits: string[];
  withdrawalsPaid: bigint[];
  partialS: number[];
  partialD: number[];
  partialPaidOut: bigint;
  partialPaidIn: bigint;
};

export class Chain {
  provider: ethers.JsonRpcProvider;
  wallet: ethers.Wallet;
  market: ethers.Contract;

  constructor() {
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.wallet = new ethers.Wallet(config.operatorKey, this.provider);
    this.market = new ethers.Contract(config.marketAddress, ABI, this.wallet);
  }

  async chainId(): Promise<bigint> {
    return (await this.provider.getNetwork()).chainId;
  }

  async now(): Promise<number> {
    const b = await this.provider.getBlock("latest");
    if (!b) throw new Error("no latest block");
    return b.timestamp;
  }

  async clock(): Promise<{ day: number; t: number }> {
    const ts = await this.now();
    return { day: Math.floor(ts / 86400), t: Math.floor((ts % 86400) / 900) };
  }

  async session(day: number, t: number): Promise<SessionView> {
    const r = await this.market.sessions(day, t);
    return {
      s: Number(r.s), d: Number(r.d),
      priceR: Number(r.priceR), priceC: Number(r.priceC),
      lambdaLo: Number(r.lambdaLo), lambdaHi: Number(r.lambdaHi),
      opened: Boolean(r.opened),
    };
  }

  async openSession(day: number, t: number, s: number, d: number): Promise<void> {
    const tx = await this.market.openSession(day, t, s, d);
    await tx.wait();
  }

  async slotOf(addr: string): Promise<number> {
    return Number(await this.market.slotOf(addr));
  }

  async prosumerCount(): Promise<number> {
    return Number(await this.market.prosumerCount());
  }

  async netputHashesPosted(day: number): Promise<boolean> {
    return Boolean(await this.market.netputHashesPosted(day));
  }

  async postNetputHashes(day: number, hashes: string[]): Promise<void> {
    const tx = await this.market.postNetputHashes(day, hashes);
    await tx.wait();
  }

  async dayClose(day: number): Promise<DayCloseView> {
    const r = await this.market.dayCloses(day);
    return {
      state: Number(r.state),
      chunksVerified: Number(r.chunksVerified),
      prosumerCountAt: Number(r.prosumerCountAt),
      disputeDeadline: BigInt(r.disputeDeadline),
    };
  }

  async chunkDone(day: number, k: number): Promise<boolean> {
    return Boolean(await this.market.chunkDone(day, k));
  }

  async submitChunk(day: number, k: number, sub: ChunkSubmission, proof: Uint8Array): Promise<void> {
    const tx = await this.market.submitChunk(day, k, sub, ethers.hexlify(proof));
    await tx.wait();
  }

  async snapDeposit(day: number, slot: number): Promise<bigint> {
    return BigInt(await this.market.snapDeposit(day, slot));
  }

  async snapWithdrawal(day: number, slot: number): Promise<bigint> {
    return BigInt(await this.market.snapWithdrawal(day, slot));
  }

  async paddingConstants(): Promise<{ empty: string; zero: string }> {
    return {
      empty: String(await this.market.EMPTY_NETPUT_HASH()),
      zero: String(await this.market.ZERO_BAL_COMMIT()),
    };
  }

  async revealOf(day: number, slot: number): Promise<RevealView> {
    const r = await this.market.reveals(day, slot);
    return {
      stage1Deadline: BigInt(r.stage1Deadline), stage2Deadline: BigInt(r.stage2Deadline),
      stage1Done: Boolean(r.stage1Done), stage2Done: Boolean(r.stage2Done),
    };
  }

  async encryptionKeyOf(slot: number): Promise<string> {
    return String(await this.market.encryptionKeyOf(slot));
  }

  async postEncryptedData(day: number, slot: number, blobHex: string): Promise<void> {
    const tx = await this.market.postEncryptedData(day, slot, blobHex);
    await tx.wait();
  }

  async clearReveal(day: number, slot: number, bal: bigint, proof: Uint8Array): Promise<void> {
    const tx = await this.market.clearReveal(day, slot, bal, ethers.hexlify(proof));
    await tx.wait();
  }

  async chunkCountFor(day: number): Promise<number> {
    return Number(await this.market.chunkCountFor(day));
  }

  async openRevealCount(day: number): Promise<number> {
    return Number(await this.market.openRevealCount(day));
  }

  /**
   * Abandon a day that can no longer be closed. Permissionless by design: the
   * operator is not the only party who may call it, but it is the one that knows
   * first, so it should. revealSlot 0 is the general ground — a proof that never
   * arrived, or a dispute still open past the deadline. No balance moves; the
   * deposits and withdrawals frozen for the day return to the queue.
   */
  async finalizeDay(day: number): Promise<void> {
    const tx = await this.market.finalizeDay(day);
    await tx.wait();
  }

  async lastClosedDay(): Promise<number> {
    return Number(await this.market.lastClosedDay());
  }

  async settlementGrace(): Promise<bigint> {
    return BigInt(await this.market.SETTLEMENT_GRACE());
  }

  async cancelDay(day: number, revealSlot: number, reason: string): Promise<void> {
    const tx = await this.market.cancelDay(day, revealSlot, reason);
    await tx.wait();
  }

  async blockNumber(): Promise<number> {
    return this.provider.getBlockNumber();
  }

  async dataRequests(fromBlock: number): Promise<{ day: number; slot: number; stage: number; block: number }[]> {
    const latest = await this.provider.getBlockNumber();
    if (fromBlock > latest) return [];
    const logs = await this.market.queryFilter(this.market.filters.DataRequested(), fromBlock, latest);
    return logs.map((l) => {
      const e = l as ethers.EventLog;
      return {
        day: Number(e.args[0]), slot: Number(e.args[1]), stage: Number(e.args[2]),
        block: l.blockNumber,
      };
    });
  }
}
