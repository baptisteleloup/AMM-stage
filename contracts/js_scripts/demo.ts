import fs from "node:fs";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { ethers } from "ethers";

const RPC_URL = "http://127.0.0.1:8545";
const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const N_PROSUMERS = Number(process.env.N_PROSUMERS ?? 8);
const DAYS = Number(process.env.DAYS ?? 3);
const FLOOR_EUR = process.env.FLOOR_EUR ?? "31";
const TICK_MS = process.env.TICK_MS ?? "200";
const BLOCK_TIME = process.env.BLOCK_TIME ?? "1";
const SESSION_TIMEOUT_MS = Number(process.env.SESSION_TIMEOUT_MS ?? 20000);
const SESSIONS = 96;
const SESSION_SECONDS = 900;
const SESSION_ANCHOR = 60;

const ABI = [
  "function currentDayId() view returns (uint256)",
  "function currentSessionIdx() view returns (uint256)",
  "function sessions(uint256,uint256) view returns (uint32 s,uint32 d,uint32 priceR,uint32 priceC,uint32 lambdaLo,uint32 lambdaHi,bool opened)",
  "function dayCloses(uint256) view returns (uint8 state,uint256 chunksVerified,uint256 accPaidOut,uint256 accPaidIn,uint256 disputeDeadline,uint256 prosumerCountAt)",
  "function chunkCountFor(uint256) view returns (uint256)",
  "function netputHashesPosted(uint256) view returns (bool)",
  "function finalizeDay(uint256 dayId)",
  "function openRevealCount(uint256) view returns (uint256)",
  "function disputerOf(uint256) view returns (address)",
];

const children: ChildProcess[] = [];
let anvil: ChildProcess | null = null;

function log(msg: string): void {
  console.log(`\x1b[36m[demo]\x1b[0m ${msg}`);
}

function ok(msg: string): void {
  console.log(`\x1b[32m[demo]\x1b[0m ${msg}`);
}

function fail(msg: string): void {
  console.log(`\x1b[31m[demo]\x1b[0m ${msg}`);
}

function cleanup(): void {
  for (const c of children) {
    try { c.kill("SIGTERM"); } catch { /* already gone */ }
  }
  if (anvil) {
    try { anvil.kill("SIGTERM"); } catch { /* already gone */ }
  }
}

process.on("SIGINT", () => { cleanup(); process.exit(130); });
process.on("exit", cleanup);

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitFor(
  label: string,
  predicate: () => Promise<boolean>,
  timeoutMs: number,
  pollMs = 250,
): Promise<boolean> {
  const start = Date.now();
  for (;;) {
    if (await predicate()) return true;
    if (Date.now() - start > timeoutMs) {
      fail(`timeout waiting for ${label} (${Math.round(timeoutMs / 1000)}s)`);
      return false;
    }
    await sleep(pollMs);
  }
}

function run(cmd: string, args: string[], env: Record<string, string>): void {
  const r = spawnSync(cmd, args, {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, ...env },
  });
  if (r.status !== 0) {
    console.log(r.stdout?.toString() ?? "");
    console.log(r.stderr?.toString() ?? "");
    throw new Error(`${cmd} ${args.join(" ")} failed`);
  }
}

function runSoft(cmd: string, args: string[], env: Record<string, string>): boolean {
  const r = spawnSync(cmd, args, {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, ...env },
  });
  return r.status === 0;
}

async function startAnvil(): Promise<void> {
  log("starting anvil");
  anvil = spawn("anvil", ["--port", "8545", "--block-time", BLOCK_TIME], { stdio: "ignore" });
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const up = await waitFor("anvil", async () => {
    try { await provider.getBlockNumber(); return true; } catch { return false; }
  }, 30000, 300);
  if (!up) throw new Error("anvil did not start (is it installed and port 8545 free?)");
  ok("anvil up on 8545");
}

function resetState(): void {
  for (const p of ["operator-data", "client-data", "deployed_demo.json", "prosumers_demo.json"]) {
    fs.rmSync(p, { recursive: true, force: true });
  }
  log("previous state cleared");
}

function deploy(): { market: string; operatorKey: string; prosumerKey: string } {
  log(`deploying (${N_PROSUMERS} prosumers)`);
  run("npx", ["tsx", "js_scripts/deploy_demo.ts"], {
    DEPLOYER_KEY,
    N_PROSUMERS: String(N_PROSUMERS),
  });
  const dep = JSON.parse(fs.readFileSync("deployed_demo.json", "utf-8")) as {
    market?: string;
    contracts?: Record<string, string>;
    roles: Record<string, { privateKey: string }>;
    prosumers: Record<string, { privateKey: string; slot: number }>;
  };
  const market = dep.market ?? dep.contracts?.market ?? dep.contracts?.MarketV4 ?? "";
  if (!market) throw new Error("market address missing from deployed_demo.json");
  const entry = Object.values(dep.prosumers).find((p) => p.slot === 1);
  if (!entry) throw new Error("no prosumer with slot 1");
  ok(`market ${market}`);

  log(`setting floors (${FLOOR_EUR} EUR)`);
  run("npx", ["tsx", "js_scripts/set_floors.ts"], { FLOOR_EUR });
  ok("floors set and openings written");

  return { market, operatorKey: dep.roles.operator.privateKey, prosumerKey: entry.privateKey };
}

function startDaemon(market: string, operatorKey: string): void {
  log("starting operator daemon");
  const child = spawn("npx", ["tsx", "js_scripts/operator/main.ts"], {
    env: {
      ...process.env,
      OPERATOR_KEY: operatorKey,
      MARKET_ADDRESS: market,
      PROSUMERS_JSON: "prosumers_demo.json",
      TICK_MS,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(child);
  const show = (buf: Buffer) => {
    for (const line of buf.toString().split("\n")) {
      if (!line.trim()) continue;
      if (line.includes("[sessions]") || line.includes("[close]") || line.includes("[main]") || line.includes("Generated proof")) {
        console.log(`\x1b[90m  ${line.slice(0, 160)}\x1b[0m`);
      }
    }
  };
  child.stdout?.on("data", show);
  child.stderr?.on("data", show);
}

function stopDaemon(): void {
  for (const c of children) {
    try { c.kill("SIGTERM"); } catch { /* already gone */ }
  }
  children.length = 0;
}

async function main(): Promise<void> {
  resetState();
  await startAnvil();
  const { market, operatorKey, prosumerKey } = deploy();

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const keeper = new ethers.Wallet(DEPLOYER_KEY, provider);
  const read = new ethers.Contract(market, ABI, provider);
  const asKeeper = new ethers.Contract(market, ABI, keeper);

  const nowTs = async (): Promise<number> => (await provider.getBlock("latest"))!.timestamp;

  const advanceTo = async (target: number): Promise<void> => {
    const now = await nowTs();
    const delta = target - now;
    if (delta > 0) await provider.send("evm_increaseTime", [delta]);
    await provider.send("evm_mine", []);
  };

  const bump = async (seconds: number): Promise<void> => {
    await provider.send("evm_increaseTime", [seconds]);
    await provider.send("evm_mine", []);
  };

  const clock = async (): Promise<{ day: number; t: number }> => {
    const ts = await nowTs();
    return { day: Math.floor(ts / 86400), t: Math.floor((ts % 86400) / SESSION_SECONDS) };
  };

  const settleReady = async (): Promise<void> => {
    const { day: today } = await clock();
    for (let d = today - 6; d < today; d++) {
      if (d < 0) continue;
      const dc = await read.dayCloses(d);
      if (Number(dc[0]) !== 1) continue;
      const expected = await read.chunkCountFor(d);
      if (expected === 0n || dc[1] !== expected) continue;
      const now = await nowTs();
      if (now < Number(dc[4])) continue;
      if ((await read.openRevealCount(d)) > 0n) continue;
      if ((await read.disputerOf(d)) !== ethers.ZeroAddress) continue;
      try {
        await (await asKeeper.finalizeDay(d)).wait();
        ok(`day ${d} settled`);
      } catch (e) {
        fail(`finalizeDay(${d}): ${(e as Error).message.slice(0, 90)}`);
      }
    }
  };

  {
    const c = await clock();
    await advanceTo((c.day + 1) * 86400 + SESSION_ANCHOR);
  }

  startDaemon(market, operatorKey);
  await sleep(3000);

  const tradingDays: number[] = [];

  for (let n = 0; n < DAYS; n++) {
    const { day } = await clock();
    log(`--- day ${day} : opening ${SESSIONS} sessions ---`);
    let opened = 0;
    let missed = 0;

    for (let t = 0; t < SESSIONS; t++) {
      await advanceTo(day * 86400 + t * SESSION_SECONDS + SESSION_ANCHOR);
      const got = await waitFor(
        `day ${day} session ${t}`,
        async () => (await read.sessions(day, t))[6] as boolean,
        t === 0 ? SESSION_TIMEOUT_MS * 6 : SESSION_TIMEOUT_MS,
      );
      if (got) opened++; else missed++;
      if (t % 8 === 0) await settleReady();
    }

    if (missed === 0) ok(`day ${day}: ${opened}/${SESSIONS} sessions opened`);
    else fail(`day ${day}: ${opened}/${SESSIONS} sessions opened (${missed} missed)`);
    if (opened > 0) tradingDays.push(day);

    await advanceTo((day + 1) * 86400 + SESSION_ANCHOR);

    log(`waiting for the close of day ${day} (proof generation)`);
    const proven = await waitFor(
      `close of day ${day}`,
      async () => {
        const dc = await read.dayCloses(day);
        const expected = await read.chunkCountFor(day);
        return Number(dc[0]) >= 1 && expected > 0n && dc[1] === expected;
      },
      600000,
      1000,
    );
    if (!proven) throw new Error(`day ${day} was never proven`);
    ok(`day ${day}: proof verified on chain`);
  }

  for (let pass = 0; pass < DAYS + 2; pass++) {
    await bump(SESSION_SECONDS * 30);
    await settleReady();
  }

  const clientEnv = {
    MARKET_ADDRESS: market,
    PROSUMER_KEY: prosumerKey,
    RECEIPTS_DIR: "./operator-data/receipts",
  };

  console.log("");
  log("=== client: ingesting receipts ===");
  const bootstrapDay = tradingDays.length > 0 ? tradingDays[0] - 1 : -1;
  if (bootstrapDay >= 0) {
    if (runSoft("npx", ["tsx", "js_scripts/client/cli.ts", "sync", String(bootstrapDay)], clientEnv)) {
      ok(`bootstrap day ${bootstrapDay} ingested (opening balance of day ${tradingDays[0]})`);
    } else {
      fail(`bootstrap day ${bootstrapDay} has no packet — day ${tradingDays[0]} will not chain`);
    }
  }
  for (const day of tradingDays) {
    run("npx", ["tsx", "js_scripts/client/cli.ts", "sync", String(day)], clientEnv);
  }
  ok(`${tradingDays.length} trading day(s) ingested`);

  console.log("");
  log("=== client: verifying ===");
  let verified = 0;
  for (const day of tradingDays) {
    let verdict = "?";
    let amount = "?";
    let fails: string[] = [];
    for (let attempt = 0; attempt < 8; attempt++) {
      if (attempt > 0) {
        await sleep(5000);
        runSoft("npx", ["tsx", "js_scripts/client/cli.ts", "sync", String(day)], clientEnv);
      }
      const r = spawnSync("npx", ["tsx", "js_scripts/client/cli.ts", "verify", String(day)], {
        env: { ...process.env, ...clientEnv },
        encoding: "utf-8",
      });
      const out = r.stdout ?? "";
      verdict = /"verdict":\s*"(\w+)"/.exec(out)?.[1] ?? "?";
      amount = /"amountEur":\s*"([^"]*)"/.exec(out)?.[1] ?? "?";
      fails = [...out.matchAll(/"name":\s*"([^"]+)",\s*"status":\s*"fail"/g)].map((m) => m[1]);
      if (verdict !== "incomplete") break;
    }
    if (verdict === "verified") {
      verified++;
      ok(`day ${day}: ${verdict}, amount ${amount} EUR`);
    } else {
      fail(`day ${day}: ${verdict}, amount ${amount} EUR${fails.length ? " — failed: " + fails.join(", ") : ""}`);
    }
  }

  stopDaemon();

  console.log("");
  if (verified > 0) {
    ok(`${verified}/${tradingDays.length} day(s) fully verified by the prosumer client`);
  } else {
    fail("no day fully verified — see the checks above");
  }

  console.log("");
  log("operator daemon stopped; anvil is still running. The client is usable with:");
  console.log(`  export MARKET_ADDRESS=${market}`);
  console.log(`  export PROSUMER_KEY=${prosumerKey}`);
  console.log(`  export RECEIPTS_DIR=./operator-data/receipts`);
  console.log(`  npx tsx js_scripts/client/cli.ts day`);
  console.log("");
  log("to restart the daemon (needed for the recourse demo):");
  console.log(`  OPERATOR_KEY=$(node -e "console.log(require('./deployed_demo.json').roles.operator.privateKey)") \\`);
  console.log(`  MARKET_ADDRESS=${market} PROSUMERS_JSON=prosumers_demo.json \\`);
  console.log(`  npx tsx js_scripts/operator/main.ts`);
  console.log("");
  log("press Ctrl-C to stop anvil");
  await new Promise(() => { /* keep alive */ });
}

main().catch((e) => {
  fail((e as Error).message);
  cleanup();
  process.exit(1);
});
