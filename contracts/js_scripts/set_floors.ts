import fs from "node:fs";
import { ethers } from "ethers";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const DEPLOY_FILE = process.env.DEPLOY_OUT ?? "deployed_demo.json";
const FLOOR_EUR = process.env.FLOOR_EUR ?? "31";
const ONLY_SLOT = process.env.SLOT ? Number(process.env.SLOT) : 0;

const PEUR_PER_EUR = 1_000_000_000_000n;

const ABI = [
  "function prosumerCount() view returns (uint256)",
  "function proposeFloor(uint256 slot,bytes32 floorCommit)",
  "function confirmFloor(uint256 slot,bytes32 floorCommit)",
  "function floorCommitOf(uint256) view returns (bytes32)",
];

type Deploy = {
  market?: string;
  contracts?: Record<string, string>;
  roles: Record<string, { address: string; privateKey: string }>;
};

function randField(): bigint {
  return BigInt("0x" + Buffer.from(ethers.randomBytes(31)).toString("hex"));
}

function loadDeploy(): { dep: Deploy; marketAddr: string } {
  if (!fs.existsSync(DEPLOY_FILE)) {
    throw new Error(`${DEPLOY_FILE} not found - run this from contracts/ after deploy_demo`);
  }
  const dep = JSON.parse(fs.readFileSync(DEPLOY_FILE, "utf-8")) as Deploy;
  const marketAddr = dep.market ?? dep.contracts?.market ?? dep.contracts?.MarketV4;
  if (!marketAddr) throw new Error(`could not find the market address in ${DEPLOY_FILE}`);
  return { dep, marketAddr };
}

async function main(): Promise<void> {
  const { dep, marketAddr } = loadDeploy();

  process.env.OPERATOR_KEY ??= dep.roles.operator.privateKey;
  process.env.MARKET_ADDRESS ??= marketAddr;

  const { Store } = await import("./operator/store.js");
  const { commitBalance, toHex32 } = await import("./scenario.js");

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const operator = new ethers.Wallet(dep.roles.operator.privateKey, provider);
  const floorAdmin = new ethers.Wallet(dep.roles.floorAdmin.privateKey, provider);

  const asOperator = new ethers.Contract(marketAddr, ABI, operator);
  const asFloorAdmin = new ethers.Contract(marketAddr, ABI, floorAdmin);

  const store = new Store();

  const floor = BigInt(Math.round(Number(FLOOR_EUR) * 1e6)) * (PEUR_PER_EUR / 1_000_000n);
  const n = Number(await asOperator.prosumerCount());
  if (n === 0) throw new Error("no prosumer registered on this market");
  const slots = ONLY_SLOT > 0 ? [ONLY_SLOT] : Array.from({ length: n }, (_, i) => i + 1);

  console.log(`market ${marketAddr}`);
  console.log(`setting a floor of ${FLOOR_EUR} EUR (${floor} pEUR) on ${slots.length} slot(s)\n`);

  for (const slot of slots) {
    const blind = randField();
    const commit = toHex32(await commitBalance(floor, blind));

    store.putFloor(slot, floor, blind);

    await (await asOperator.proposeFloor(slot, commit)).wait();
    await (await asFloorAdmin.confirmFloor(slot, commit)).wait();

    const onchain = (await asOperator.floorCommitOf(slot)) as string;
    const ok = onchain.toLowerCase() === commit.toLowerCase();
    console.log(`slot ${String(slot).padStart(3)}  ${ok ? "ok" : "MISMATCH"}  ${commit}`);
    if (!ok) throw new Error(`slot ${slot}: chain holds ${onchain}`);
  }

  console.log(`\ndone: ${slots.length} floor(s) set, stored, and written to the prosumer inboxes`);
}

main().catch((e) => {
  console.error((e as Error).message);
  process.exit(1);
});
