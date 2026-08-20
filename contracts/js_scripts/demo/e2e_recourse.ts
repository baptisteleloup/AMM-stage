import fs from "node:fs";
import { ethers } from "ethers";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const DEPLOY_FILE = process.env.DEPLOY_OUT ?? "demo/state/deployed_demo.json";
const DAY = process.env.DAY ? Number(process.env.DAY) : 0;
const SLOT = Number(process.env.SLOT ?? 1);

const ABI = [
  "function slotOf(address) view returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
  "function dayCloses(uint256) view returns (uint8 state,uint256 chunksVerified,uint256 accPaidOut,uint256 accPaidIn,uint256 disputeDeadline,uint256 prosumerCountAt)",
  "function chunkCountFor(uint256) view returns (uint256)",
  "function reveals(uint256,uint256) view returns (uint64 stage1Deadline,uint64 stage2Deadline,bool stage1Done,bool stage2Done)",
  "function openRevealCount(uint256) view returns (uint256)",
  "function requestData(uint256 dayId)",
  "function postEncryptedData(uint256 dayId,uint256 slot,bytes blob)",
  "function requestClearReveal(uint256 dayId)",
  "function finalizeDay(uint256 dayId)",
  "function cancelDay(uint256 dayId,uint256 revealSlot,string reason)",
  "function currentDayId() view returns (uint256)",
];

const STATE = ["Pending", "Closing", "Finalized", "Cancelled"];

function step(n: number, title: string): void {
  console.log(`\n${"=".repeat(64)}\nSTEP ${n}  ${title}\n${"=".repeat(64)}`);
}

async function expectRevert(label: string, fn: () => Promise<unknown>): Promise<boolean> {
  try {
    await fn();
    console.log(`  ${label}: SUCCEEDED - expected it to be blocked`);
    return false;
  } catch (e) {
    const m = (e as Error).message;
    const reason = /reason="([^"]+)"/.exec(m)?.[1] ?? m.slice(0, 80);
    console.log(`  ${label}: blocked (${reason})`);
    return true;
  }
}

async function main(): Promise<void> {
  const dep = JSON.parse(fs.readFileSync(DEPLOY_FILE, "utf-8")) as {
    market?: string;
    contracts?: Record<string, string>;
    roles: Record<string, { address: string; privateKey: string }>;
    prosumers: Record<string, { address: string; privateKey: string; slot: number }>;
  };
  const marketAddr = dep.market ?? dep.contracts?.market ?? dep.contracts?.MarketV4;
  if (!marketAddr) throw new Error("market address not found in the deploy file");

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const operator = new ethers.Wallet(dep.roles.operator.privateKey, provider);

  const entry = Object.values(dep.prosumers).find((p) => p.slot === SLOT);
  if (!entry) throw new Error(`no prosumer with slot ${SLOT} in the deploy file`);
  const prosumer = new ethers.Wallet(entry.privateKey, provider);

  const asOperator = new ethers.Contract(marketAddr, ABI, operator);
  const asProsumer = new ethers.Contract(marketAddr, ABI, prosumer);
  const read = new ethers.Contract(marketAddr, ABI, provider);

  const day = DAY || Number(await read.currentDayId()) - 1;

  console.log(`market   ${marketAddr}`);
  console.log(`day      ${day}`);
  console.log(`slot     ${SLOT}  (${prosumer.address})`);

  const dc0 = await read.dayCloses(day);
  console.log(`state    ${STATE[Number(dc0[0])]}  batches ${dc0[1]}/${await read.chunkCountFor(day)}`);
  if (Number(dc0[0]) !== 1) {
    throw new Error(`day ${day} is ${STATE[Number(dc0[0])]}, this demonstration needs a day in Closing`);
  }

  let passed = 0;
  let total = 0;

  step(1, "The prosumer demands its data");
  const before = await read.openRevealCount(day);
  await (await asProsumer.requestData(day)).wait();
  const after = await read.openRevealCount(day);
  const r1 = await read.reveals(day, SLOT);
  console.log(`  open requests: ${before} -> ${after}`);
  console.log(`  operator must answer before ${r1[0]}`);
  total++; if (after > before) { passed++; console.log("  OK: the request is recorded and counted"); }

  step(2, "Settlement is blocked while the request is open");
  total++; if (await expectRevert("finalizeDay", async () => (await asOperator.finalizeDay(day)).wait())) passed++;
  console.log("  -> a single unanswered request stops the whole day from settling");

  step(3, "The operator answers by publishing encrypted data");
  const blob = "0x" + Buffer.from(JSON.stringify({ day, slot: SLOT, note: "demonstration payload" })).toString("hex");
  await (await asOperator.postEncryptedData(day, SLOT, blob)).wait();
  const r2 = await read.reveals(day, SLOT);
  const open2 = await read.openRevealCount(day);
  console.log(`  stage1Done: ${r2[2]}   open requests: ${open2}`);
  total++; if (r2[2] && open2 === before) { passed++; console.log("  OK: answering releases the block"); }

  step(4, "The prosumer escalates and demands the balance in the clear");
  await (await asProsumer.requestClearReveal(day)).wait();
  const r3 = await read.reveals(day, SLOT);
  const open3 = await read.openRevealCount(day);
  console.log(`  stage2Deadline: ${r3[1]}   open requests: ${open3}`);
  total++; if (r3[1] > 0n && open3 > before) { passed++; console.log("  OK: stage 2 opened and blocks settlement again"); }

  step(5, "Settlement is blocked again");
  total++; if (await expectRevert("finalizeDay", async () => (await asOperator.finalizeDay(day)).wait())) passed++;
  console.log("  -> only a proof opening the commitment can clear this one");

  step(6, "Summary");
  console.log(`  ${passed}/${total} properties demonstrated`);
  console.log(`
  What this run shows, on a live chain:
   - a prosumer can compel the operator to publish its data, on the ledger
   - an unanswered request blocks settlement for the whole community
   - answering releases the block, so the operator is incentivised to answer
   - the prosumer can escalate to a clear-text opening of its balance
   - a stage-2 request blocks settlement until the opening is proven

  Not exercised here (they end the day):
   - cancelDay after a timeout, which requires waiting out the 12h window
   - cancelDay past the settlement grace, when settlement itself keeps failing`);

  if (passed !== total) process.exit(1);
}

main().catch((e) => {
  console.error((e as Error).message);
  process.exit(1);
});
