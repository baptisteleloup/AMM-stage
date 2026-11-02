// Demo orchestrator, launched by demo/run.sh: starts anvil (or uses Besu with CHAIN=besu), deploys
// the community, posts prices and floors, starts the operator daemon and one client per CLIENT_SLOTS,
// then drives the clock session by session and waits for each day to be proven. State goes to
// demo/state/. From contracts/: npx tsx js_scripts/demo/demo_ui.ts (normally through demo/run.sh)

import fs from "node:fs";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { ethers } from "ethers";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const CHAIN = process.env.CHAIN ?? "anvil"; // "besu": the network in network/, real time, no time travel
const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // public anvil test key, also funded in the Besu genesis
const N_PROSUMERS = Number(process.env.N_PROSUMERS ?? 8);
const FLOOR_EUR = process.env.FLOOR_EUR ?? "31";
const TARIFF_MODE = process.env.TARIFF_MODE ?? "schedule";
const PRICES_JSON = process.env.PRICES_JSON ?? "demo/data/prices.json";
const PRICE_HORIZON_DAYS = process.env.PRICE_HORIZON_DAYS ?? "40";
const TICK_MS = process.env.TICK_MS ?? "200"; // operator loop period
const BLOCK_TIME = process.env.BLOCK_TIME ?? "1"; // anvil block time, s
const SESSION_PACE_MS = Number(process.env.SESSION_PACE_MS ?? 4000); // wall time per quarter-hour of market time
const SESSION_TIMEOUT_MS = Number(process.env.SESSION_TIMEOUT_MS ?? 30000); // wait for the operator to open a session
const CLIENT_SLOTS = (process.env.CLIENT_SLOTS ?? "1").split(",").map((s) => Number(s.trim())); // members that get a browser client
const CLIENT_POLL_MS = process.env.CLIENT_POLL_MS ?? "5000";
const BASE_PORT = Number(process.env.CLIENT_UI_PORT ?? 8787); // first client port, the next ones follow
const OPEN_BROWSER = process.env.OPEN_BROWSER !== "0";
const SESSIONS = 96;
const SESSION_SECONDS = 900;
const SESSION_ANCHOR = 60; // land 60 s into each session, never on its boundary

const ABI = [
  "function sessions(uint256,uint256) view returns (uint32 s,uint32 d,uint32 priceR,uint32 priceC,uint32 lambdaLo,uint32 lambdaHi,bool opened)",
  "function dayCloses(uint256) view returns (uint8 state,uint256 chunksVerified,uint256 accPaidOut,uint256 accPaidIn,uint256 disputeDeadline,uint256 prosumerCountAt)",
  "function chunkCountFor(uint256) view returns (uint256)",
];

const children: ChildProcess[] = []; // daemon and clients, killed on exit
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

// Stops every child process and anvil.
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

// Polls predicate until true or timeout; false on timeout.
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

// Runs a command to completion, prints its output and throws if it fails.
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

// Forwards the lines of a child process that pass `keep`, tagged and coloured.
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

// Starts anvil, or with CHAIN=besu checks that a Besu node answers.
async function startAnvil(): Promise<void> {
  if (CHAIN === "besu") {
    const provider = new ethers.JsonRpcProvider(RPC_URL);
    const up = await waitFor("besu", async () => {
      try { await provider.getBlockNumber(); return true; } catch { return false; }
    }, 30000, 1000);
    if (!up) throw new Error(`no Besu node answering at ${RPC_URL} (run Network/reset.sh first)`);
    ok(`Besu up at ${RPC_URL}, real-time clock`);
    return;
  }
  log("starting anvil");
  anvil = spawn("anvil", ["--port", "8545", "--block-time", BLOCK_TIME], { stdio: "ignore" });
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const up = await waitFor("anvil", async () => {
    try { await provider.getBlockNumber(); return true; } catch { return false; }
  }, 30000, 300);
  if (!up) throw new Error("anvil did not start (is it installed and port 8545 free?)");
  ok("anvil up on 8545");
}

// Deletes the previous run's operator data, client data and deployment files.
function resetState(): void {
  const wipe = [
    process.env.DATA_DIR ?? "demo/state/operator-data",
    process.env.CLIENT_DATA_DIR ?? "demo/state/client-data",
    process.env.DEPLOYMENT_JSON ?? "demo/state/deployed_demo.json",
    process.env.PROSUMERS_JSON ?? "demo/state/prosumers_demo.json",
  ];
  for (const p of wipe) {
    fs.rmSync(p, { recursive: true, force: true });
  }
  log("previous state cleared");
}

type Deployment = {
  market: string;
  operatorKey: string;
  prosumers: Record<number, { privateKey: string; address?: string }>;
};

// Deploys the contracts, posts prices in feed mode and sets the floors, each in a child script.
function deploy(): Deployment {
  log(`deploying (${N_PROSUMERS} prosumers)`);
  run("npx", ["tsx", "js_scripts/demo/deploy_demo.ts"], {
    DEPLOYER_KEY,
    N_PROSUMERS: String(N_PROSUMERS),
    TARIFF_MODE,
  });
  const dep = JSON.parse(fs.readFileSync(process.env.DEPLOYMENT_JSON ?? "demo/state/deployed_demo.json", "utf-8")) as {
    market?: string;
    contracts?: Record<string, string>;
    roles: Record<string, { privateKey: string }>;
    prosumers: Record<string, { privateKey: string; address?: string; slot: number }>;
  };
  const market = dep.market ?? dep.contracts?.market ?? dep.contracts?.MarketV4 ?? ""; // accepts the layouts the file has had
  if (!market) throw new Error("market address missing from deployed_demo.json");

  const prosumers: Deployment["prosumers"] = {};
  for (const p of Object.values(dep.prosumers)) {
    prosumers[p.slot] = { privateKey: p.privateKey, address: p.address }; // indexed by slot
  }
  ok(`market ${market}`);

  if (TARIFF_MODE.toLowerCase() === "feed") {
    log(`posting day-ahead prices (${PRICE_HORIZON_DAYS} days from ${PRICES_JSON})`);
    run("npx", ["tsx", "js_scripts/demo/post_prices.ts", PRICE_HORIZON_DAYS], {
      PRICES_JSON,
      DEPLOYMENT_JSON: process.env.DEPLOYMENT_JSON ?? "demo/state/deployed_demo.json",
    });
    ok("prices finalised on chain by the reporter quorum");
  }

  log(`setting floors (${FLOOR_EUR} EUR)`);
  run("npx", ["tsx", "js_scripts/demo/set_floors.ts"], { FLOOR_EUR });
  ok("floors set and openings written");

  return { market, operatorKey: dep.roles.operator.privateKey, prosumers };
}

// Starts the operator daemon, configured only through its environment.
function startDaemon(market: string, operatorKey: string): void {
  log("starting operator daemon");
  const child = spawn("npx", ["tsx", "js_scripts/operator/main.ts"], {
    env: {
      ...process.env,
      OPERATOR_KEY: operatorKey,
      MARKET_ADDRESS: market,
      PROSUMERS_JSON: process.env.PROSUMERS_JSON ?? "demo/state/prosumers_demo.json",
      DATA_DIR: process.env.DATA_DIR ?? "demo/state/operator-data",
      NETPUTS_JSON: process.env.NETPUTS_JSON ?? "demo/data/netputs_raw.json",
      TICK_MS,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(child);
  pipe(child, "operator", "\x1b[90m", (l) =>
    // Continuation lines are kept: an error's detail is on the lines after the first.
    l.includes("[close]") || l.includes("[main]") || l.includes("[reveals]")
    || l.includes("Generated proof") || l.includes("reverted") || l.includes("Error")
    || l.startsWith("      "));
}

// Starts the client server of one member, with its own data folder and port.
function startClient(slot: number, market: string, key: string, port: number): void {
  const child = spawn("npx", ["tsx", "js_scripts/client/server.ts"], {
    env: {
      ...process.env,
      MARKET_ADDRESS: market,
      PROSUMER_KEY: key,
      DEPLOYMENT_JSON: process.env.DEPLOYMENT_JSON ?? "demo/state/deployed_demo.json",
      CLIENT_DATA_DIR: `${process.env.CLIENT_DATA_DIR ?? "demo/state/client-data"}/slot-${slot}`,
      RECEIPTS_DIR: process.env.RECEIPTS_DIR ?? "demo/state/operator-data/receipts",
      CLIENT_UI_PORT: String(port),
      CLIENT_POLL_MS,
      KEEPER: "1", // the client also calls finalizeDay when a day is ready
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

  // Moves the chain clock to `target` (anvil), or waits until it gets there (Besu).
  const advanceTo = async (target: number): Promise<void> => {
    if (CHAIN === "besu") {
      // Real time: wait for the chain to reach the target instead of jumping to it.
      let announced = false;
      for (;;) {
        const now = await nowTs();
        if (now >= target) return;
        if (!announced && target - now > 120) {
          log(`waiting ${((target - now) / 3600).toFixed(1)} h of real time for the chain to reach ${new Date(target * 1000).toISOString()}`);
          announced = true;
        }
        await sleep(Math.min(5000, (target - now) * 1000));
      }
    }
    const now = await nowTs();
    const delta = target - now;
    if (delta > 0) await provider.send("evm_increaseTime", [delta]); // anvil time travel
    await provider.send("evm_mine", []); // a block at the new time
  };

  // Day and session index of the latest block.
  const clock = async (): Promise<{ day: number; t: number }> => {
    const ts = await nowTs();
    return { day: Math.floor(ts / 86400), t: Math.floor((ts % 86400) / SESSION_SECONDS) };
  };

  // Anvil: jump to the next day. Besu: the current day is the empty start-up day, trading starts at midnight.
  if (CHAIN !== "besu") {
    const c = await clock();
    await advanceTo((c.day + 1) * 86400 + SESSION_ANCHOR);
  }

  startDaemon(dep.market, dep.operatorKey);
  await sleep(3000); // let the daemon start

  const ports: number[] = [];
  for (let i = 0; i < CLIENT_SLOTS.length; i++) {
    const slot = CLIENT_SLOTS[i];
    const entry = dep.prosumers[slot];
    if (!entry) { fail(`no prosumer at slot ${slot}, skipping`); continue; }
    const port = BASE_PORT + i; // one port per client
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
      let paused = false;
      while (fs.existsSync("PAUSE")) { // `touch PAUSE` in contracts/ freezes the clock
        if (!paused) {
          log("PAUSE file found — the clock is frozen. Delete it to resume.");
          paused = true;
        }
        await sleep(2000);
      }
      if (paused) ok("resumed");

      await advanceTo(day * 86400 + t * SESSION_SECONDS + SESSION_ANCHOR); // into session t
      const got = await waitFor(
        `day ${day} session ${t}`,
        async () => (await read.sessions(day, t))[6] as boolean, // Session.opened
        SESSION_TIMEOUT_MS,
      );
      if (got) opened++;
      await sleep(SESSION_PACE_MS); // leaves time to watch the client
    }

    if (opened === SESSIONS) ok(`day ${day}: ${opened}/${SESSIONS} sessions opened`);
    else fail(`day ${day}: ${opened}/${SESSIONS} sessions opened`);

    await advanceTo((day + 1) * 86400 + SESSION_ANCHOR); // past midnight: the operator freezes and proves the day
    log(`day ${day} is closing, the operator is proving it`);

    const proven = await waitFor(
      `close of day ${day}`,
      async () => {
        const dc = await read.dayCloses(day);
        const expected = await read.chunkCountFor(day);
        return Number(dc[0]) >= 1 && expected > 0n && dc[1] === expected; // every batch verified
      },
      600000, // proving may take minutes
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
