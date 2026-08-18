import fs from "node:fs";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { ethers } from "ethers";

const RPC_URL = "http://127.0.0.1:8545";
const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const N_PROSUMERS = Number(process.env.N_PROSUMERS ?? 8);
const FLOOR_EUR = process.env.FLOOR_EUR ?? "31";
const TARIFF_MODE = process.env.TARIFF_MODE ?? "schedule";
const PRICES_JSON = process.env.PRICES_JSON ?? "prices.json";
const PRICE_HORIZON_DAYS = process.env.PRICE_HORIZON_DAYS ?? "40";
const TICK_MS = process.env.TICK_MS ?? "200";
const BLOCK_TIME = process.env.BLOCK_TIME ?? "1";
const SESSION_PACE_MS = Number(process.env.SESSION_PACE_MS ?? 4000);
const SESSION_TIMEOUT_MS = Number(process.env.SESSION_TIMEOUT_MS ?? 30000);
const CLIENT_SLOTS = (process.env.CLIENT_SLOTS ?? "1").split(",").map((s) => Number(s.trim()));
const CLIENT_POLL_MS = process.env.CLIENT_POLL_MS ?? "5000";
const BASE_PORT = Number(process.env.CLIENT_UI_PORT ?? 8787);
const OPEN_BROWSER = process.env.OPEN_BROWSER !== "0";
const SESSIONS = 96;
const SESSION_SECONDS = 900;
const SESSION_ANCHOR = 60;

const ABI = [
  "function sessions(uint256,uint256) view returns (uint32 s,uint32 d,uint32 priceR,uint32 priceC,uint32 lambdaLo,uint32 lambdaHi,bool opened)",
  "function dayCloses(uint256) view returns (uint8 state,uint256 chunksVerified,uint256 accPaidOut,uint256 accPaidIn,uint256 disputeDeadline,uint256 prosumerCountAt)",
  "function chunkCountFor(uint256) view returns (uint256)",
];

const children: ChildProcess[] = [];
let anvil: ChildProcess | null = null;

function log(msg: string): void {
  console.log(`\x1b[36m[demo-ui]\x1b[0m ${msg}`);
}

function ok(msg: string): void {
  console.log(`\x1b[32m[demo-ui]\x1b[0m ${msg}`);
}

function fail(msg: string): void {
  console.log(`\x1b[31m[demo-ui]\x1b[0m ${msg}`);
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

function pipe(child: ChildProcess, tag: string, colour: string, keep: (line: string) => boolean): void {
  const show = (buf: Buffer) => {
    for (const line of buf.toString().split("\n")) {
      if (!line.trim() || !keep(line)) continue;
      console.log(`${colour}  [${tag}] ${line.trim().slice(0, 150)}\x1b[0m`);
    }
  };
  child.stdout?.on("data", show);
  child.stderr?.on("data", show);
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

type Deployment = {
  market: string;
  operatorKey: string;
  prosumers: Record<number, { privateKey: string; address?: string }>;
};

function deploy(): Deployment {
  log(`deploying (${N_PROSUMERS} prosumers)`);
  run("npx", ["tsx", "js_scripts/deploy_demo.ts"], {
    DEPLOYER_KEY,
    N_PROSUMERS: String(N_PROSUMERS),
    TARIFF_MODE,
  });
  const dep = JSON.parse(fs.readFileSync("deployed_demo.json", "utf-8")) as {
    market?: string;
    contracts?: Record<string, string>;
    roles: Record<string, { privateKey: string }>;
    prosumers: Record<string, { privateKey: string; address?: string; slot: number }>;
  };
  const market = dep.market ?? dep.contracts?.market ?? dep.contracts?.MarketV4 ?? "";
  if (!market) throw new Error("market address missing from deployed_demo.json");

  const prosumers: Deployment["prosumers"] = {};
  for (const p of Object.values(dep.prosumers)) {
    prosumers[p.slot] = { privateKey: p.privateKey, address: p.address };
  }
  ok(`market ${market}`);

  if (TARIFF_MODE.toLowerCase() === "feed") {
    log(`posting day-ahead prices (${PRICE_HORIZON_DAYS} days from ${PRICES_JSON})`);
    run("npx", ["tsx", "js_scripts/post_prices.ts", PRICE_HORIZON_DAYS], {
      PRICES_JSON,
      DEPLOYMENT_JSON: "deployed_demo.json",
    });
    ok("prices finalised on chain by the reporter quorum");
  }

  log(`setting floors (${FLOOR_EUR} EUR)`);
  run("npx", ["tsx", "js_scripts/set_floors.ts"], { FLOOR_EUR });
  ok("floors set and openings written");

  return { market, operatorKey: dep.roles.operator.privateKey, prosumers };
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
  pipe(child, "operator", "\x1b[90m", (l) =>
    // Keep the continuation lines too: a failure now spans several lines and the
    // useful detail is on the ones after the first.
    l.includes("[close]") || l.includes("[main]") || l.includes("[reveals]")
    || l.includes("Generated proof") || l.includes("reverted") || l.includes("Error")
    || l.startsWith("      "));
}

function startClient(slot: number, market: string, key: string, port: number): void {
  const child = spawn("npx", ["tsx", "js_scripts/client/server.ts"], {
    env: {
      ...process.env,
      MARKET_ADDRESS: market,
      PROSUMER_KEY: key,
      DEPLOYMENT_JSON: "deployed_demo.json",
      CLIENT_DATA_DIR: `./client-data/slot-${slot}`,
      RECEIPTS_DIR: process.env.RECEIPTS_DIR ?? "./operator-data/receipts",
      CLIENT_UI_PORT: String(port),
      CLIENT_POLL_MS,
      KEEPER: "1",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(child);
  pipe(child, `client-${slot}`, "\x1b[35m", (l) => !l.startsWith("  "));
}

async function main(): Promise<void> {
  resetState();
  await startAnvil();
  const dep = deploy();

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const read = new ethers.Contract(dep.market, ABI, provider);

  const nowTs = async (): Promise<number> => (await provider.getBlock("latest"))!.timestamp;

  const advanceTo = async (target: number): Promise<void> => {
    const now = await nowTs();
    const delta = target - now;
    if (delta > 0) await provider.send("evm_increaseTime", [delta]);
    await provider.send("evm_mine", []);
  };

  const clock = async (): Promise<{ day: number; t: number }> => {
    const ts = await nowTs();
    return { day: Math.floor(ts / 86400), t: Math.floor((ts % 86400) / SESSION_SECONDS) };
  };

  {
    const c = await clock();
    await advanceTo((c.day + 1) * 86400 + SESSION_ANCHOR);
  }

  startDaemon(dep.market, dep.operatorKey);
  await sleep(3000);

  const ports: number[] = [];
  for (let i = 0; i < CLIENT_SLOTS.length; i++) {
    const slot = CLIENT_SLOTS[i];
    const entry = dep.prosumers[slot];
    if (!entry) { fail(`no prosumer at slot ${slot}, skipping`); continue; }
    const port = BASE_PORT + i;
    ports.push(port);
    startClient(slot, dep.market, entry.privateKey, port);
    ok(`client for slot ${slot} at http://127.0.0.1:${port}`);
  }
  await sleep(2500);

  console.log("");
  ok("everything is up. Leave this running and watch the browser.");
  log(`one quarter-hour every ${Math.round(SESSION_PACE_MS / 1000)}s, so a full day takes about ${Math.round((SESSIONS * SESSION_PACE_MS) / 60000)} min`);
  log("press Ctrl-C to stop the chain, the operator and the clients");
  log("run `touch PAUSE` to freeze the clock while you click through the client,");
  log("then `rm PAUSE` to let it run again");
  console.log("");

  if (OPEN_BROWSER && process.platform === "darwin" && ports.length > 0) {
    spawnSync("open", [`http://127.0.0.1:${ports[0]}`]);
  }

  let { day } = await clock();

  for (;;) {
    log(`--- day ${day} ---`);
    let opened = 0;

    for (let t = 0; t < SESSIONS; t++) {
      // The clock must not run while you are exercising recourse by hand. A
      // disclosure request makes the operator prove something, which blocks its
      // tick loop for seconds; sessions missed in that window can never be
      // proven, because close.ts rebuilds all 96 from the source while the chain
      // only holds the ones that opened. Create a file named PAUSE to freeze
      // time, delete it to resume.
      let paused = false;
      while (fs.existsSync("PAUSE")) {
        if (!paused) {
          log("PAUSE file found — the clock is frozen. Delete it to resume.");
          paused = true;
        }
        await sleep(2000);
      }
      if (paused) ok("resumed");

      await advanceTo(day * 86400 + t * SESSION_SECONDS + SESSION_ANCHOR);
      const got = await waitFor(
        `day ${day} session ${t}`,
        async () => (await read.sessions(day, t))[6] as boolean,
        SESSION_TIMEOUT_MS,
      );
      if (got) opened++;
      await sleep(SESSION_PACE_MS);
    }

    if (opened === SESSIONS) ok(`day ${day}: ${opened}/${SESSIONS} sessions opened`);
    else fail(`day ${day}: ${opened}/${SESSIONS} sessions opened`);

    await advanceTo((day + 1) * 86400 + SESSION_ANCHOR);
    log(`day ${day} is closing, the operator is proving it`);

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
    if (proven) ok(`day ${day}: proof verified on chain, a client keeper will settle it`);
    else fail(`day ${day} was never proven, continuing anyway`);

    day += 1;
  }
}

main().catch((e) => {
  fail((e as Error).message);
  cleanup();
  process.exit(1);
});
