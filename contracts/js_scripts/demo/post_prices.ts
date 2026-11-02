// Feed mode: posts HORIZON days (default 40) of day-ahead prices from PRICES_JSON to GridTariff, one
// vote per reporter up to the quorum. Chain days are aligned with the netput days of NETPUTS_JSON so
// loads and prices of the same date meet. Reads DEPLOYMENT_JSON. From contracts/:
//   npx tsx js_scripts/demo/post_prices.ts [days]

import fs from "node:fs";
import { ethers } from "ethers";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const PRICES_JSON = process.env.PRICES_JSON ?? "demo/data/prices.json";
const NETPUTS_JSON = process.env.NETPUTS_JSON ?? "demo/data/netputs_raw.json";
const DEPLOYMENT = process.env.DEPLOYMENT_JSON ?? "demo/state/deployed_demo.json";
const HORIZON = Number(process.argv[2] ?? process.env.PRICE_HORIZON_DAYS ?? 40); // days posted ahead
const UNIT_SCALE = Number(process.env.PRICE_UNIT_SCALE ?? 100); // prices.json is per kWh in currency, GridTariff wants cents

const ABI = [
  "function submitDailyPrices(uint32 day, uint256[96] low, uint256[96] high)",
  "function activeHash(uint32) view returns (bytes32)",
  "function mode() view returns (uint8)",
];

// Price date used for a chain day. Anchored: same date as the netput day replayed that day.
// Otherwise the price days simply cycle from today.
function priceDateFor(day: number, cycle: string[], baseDay: number, anchored: boolean, today: number): string {
  if (anchored) {
    const n = cycle.length;
    const idx = (((day - baseDay) % n) + n) % n; // non-negative modulo
    return cycle[idx];
  }
  return cycle[(day - today) % cycle.length];
}

async function main(): Promise<void> {
  if (!fs.existsSync(PRICES_JSON)) throw new Error(`${PRICES_JSON} not found, run fetch_prices.py first`);
  if (!fs.existsSync(DEPLOYMENT)) throw new Error(`${DEPLOYMENT} not found`);

  const feed = JSON.parse(fs.readFileSync(PRICES_JSON, "utf-8")) as {
    days: string[];
    prices: Record<string, { low: number[]; high: number[] }>;
  };
  const dep = JSON.parse(fs.readFileSync(DEPLOYMENT, "utf-8")) as {
    contracts: { tariff: string };
    tariffMode?: string;
    quorum?: number;
    reporters?: { privateKey: string }[];
  };

  if (dep.tariffMode !== "feed") {
    console.log("the tariff is in schedule mode; nothing to post"); // schedule mode needs no feed
    return;
  }
  const reporters = dep.reporters ?? [];
  const quorum = dep.quorum ?? reporters.length; // only the first `quorum` reporters vote
  if (reporters.length < quorum) throw new Error(`${reporters.length} reporter(s) for a quorum of ${quorum}`);

  if (feed.days.length === 0) throw new Error(`${PRICES_JSON} holds no days`);

  let cycle = feed.days;
  let baseDay = 0;
  let anchored = false;
  if (fs.existsSync(NETPUTS_JSON)) {
    const net = JSON.parse(fs.readFileSync(NETPUTS_JSON, "utf-8")) as { days?: number; baseDay?: number };
    const nDays = net.days ?? 0;
    if (nDays > 0 && nDays <= feed.days.length) {
      cycle = feed.days.slice(0, nDays); // one price day per netput day
      baseDay = net.baseDay ?? 0; // chain day of netput day 0
      anchored = true;
    } else {
      console.log(`[prices] warning: ${NETPUTS_JSON} declares ${nDays} day(s) but ${PRICES_JSON} holds ${feed.days.length}; falling back to the unanchored cycle`);
    }
  } else {
    console.log(`[prices] warning: ${NETPUTS_JSON} not found; falling back to the unanchored cycle, the load/price pairing will rotate across the run`);
  }

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallets = reporters.slice(0, quorum).map((r) => new ethers.Wallet(r.privateKey, provider));

  const now = (await provider.getBlock("latest"))!.timestamp;
  const today = Math.floor(now / 86400); // chain day, from the block clock

  const sample = feed.prices[cycle[0]];
  const loC = sample.low[48] * UNIT_SCALE; // session 48 = noon, sanity check of the units
  const hiC = sample.high[48] * UNIT_SCALE;
  console.log(`posting ${HORIZON} day(s) from day ${today}, cycling ${cycle.length} day(s) of prices`);
  if (anchored) {
    console.log(`  aligned with ${NETPUTS_JSON}: chain day D gets the price date of netput day (D - ${baseDay}) mod ${cycle.length}`);
    console.log(`  trading day ${today + 1} pairs with ${priceDateFor(today + 1, cycle, baseDay, true, today)}`);
  }
  console.log(`  midday sample: sell ${loC.toFixed(2)} c/kWh, buy ${hiC.toFixed(2)} c/kWh`);
  if (hiC < 1 || hiC > 200) {
    throw new Error(
      `a retail price of ${hiC.toFixed(4)} c/kWh is not plausible. GridTariff wants ` +
      `cents per kWh (the schedule mode deploys 21.46 for the peak rate). Check ` +
      `PRICE_UNIT_SCALE, currently ${UNIT_SCALE}.`);
  }
  console.log(`  ${quorum} reporter(s) of ${reporters.length} must agree for a day to finalise`);

  let posted = 0;
  for (let i = 0; i < HORIZON; i++) {
    const day = today + i;
    const src = feed.prices[priceDateFor(day, cycle, baseDay, anchored, today)];
    const low = src.low.map((v) => ethers.parseEther((v * UNIT_SCALE).toFixed(12))); // cents per kWh, 18 decimals
    const high = src.high.map((v) => ethers.parseEther((v * UNIT_SCALE).toFixed(12)));

    for (const w of wallets) {
      const t = new ethers.Contract(dep.contracts.tariff, ABI, w);
      await (await t.submitDailyPrices(day, low, high)).wait(); // identical votes, the quorum-th adopts the day
    }
    posted += 1;
    if (i === 0 || (i + 1) % 10 === 0) console.log(`  day ${day} finalised (${posted}/${HORIZON})`);
  }

  const check = new ethers.Contract(dep.contracts.tariff, ABI, provider);
  const h = await check.activeHash(today); // today must have adopted prices
  if (h === ethers.ZeroHash) throw new Error("day 0 did not finalise, check the quorum");
  console.log(`prices live from day ${today} to ${today + HORIZON - 1}`);
}

main().catch((e) => {
  console.error(`[prices] ${(e as Error).message}`);
  process.exit(1);
});
