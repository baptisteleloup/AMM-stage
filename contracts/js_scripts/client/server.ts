import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { Chain } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { register, status } from "./register.js";
import { deposit, requestWithdraw, position } from "./money.js";
import { ReceiptInbox } from "./receipts.js";
import { verifyDay } from "./verify.js";
import { dayView, coverage } from "./clock.js";
import { marginState, shouldNotify } from "./margin.js";
import * as recourse from "./recourse.js";
import { actionTick, tryFinalize, trySweep } from "./actions.js";
import { config, envReady, SESSIONS } from "./config.js";

const PORT = Number(process.env.CLIENT_UI_PORT ?? 8787);
const UI_DIR = process.env.CLIENT_UI_DIR ?? path.join(process.cwd(), "js_scripts", "client", "ui");

let id: Identity;
let chain: Chain;
let store: Store;
let inbox: ReceiptInbox;

type LogEntry = { seq: number; at: string; kind: "keeper" | "action" | "alert" | "error" | "info"; text: string; data?: unknown };
const log: LogEntry[] = [];
let seq = 0;

function note(kind: LogEntry["kind"], text: string, data?: unknown): void {
  seq += 1;
  log.push({ seq, at: new Date().toISOString(), kind, text, data });
  if (log.length > 400) log.splice(0, log.length - 400);
}

let queue: Promise<unknown> = Promise.resolve();
function serial<T>(fn: () => Promise<T>): Promise<T> {
  const next = queue.then(fn, fn);
  queue = next.catch(() => undefined);
  return next;
}

const keeper = {
  running: false,
  timer: null as ReturnType<typeof setInterval> | null,
  lastRun: null as string | null,
  lastError: null as string | null,
  ticks: 0,
};

function bootstrapEnv(): void {
  if (process.env.PROSUMER_KEY && process.env.MARKET_ADDRESS) return;
  const file = process.env.DEPLOYMENT_JSON;
  if (!file || !fs.existsSync(file)) return;
  const dep = JSON.parse(fs.readFileSync(file, "utf-8")) as {
    market?: string;
    contracts?: Record<string, string>;
    prosumers: Record<string, { privateKey: string; slot: number }>;
  };
  const wanted = Number(process.env.CLIENT_SLOT ?? 1);
  const entry = Object.values(dep.prosumers ?? {}).find((p) => p.slot === wanted);
  if (!process.env.MARKET_ADDRESS) {
    const market = dep.market ?? dep.contracts?.market ?? dep.contracts?.MarketV4 ?? "";
    if (market) process.env.MARKET_ADDRESS = market;
  }
  if (!process.env.PROSUMER_KEY && entry) process.env.PROSUMER_KEY = entry.privateKey;
}

const CATCH_UP_DAYS = Number(process.env.CLIENT_CATCH_UP_DAYS ?? 7);

/**
 * Collecting only today is not enough. A day that closes while the keeper is
 * stopped, or while its tick is busy, is never picked up again — and a missing
 * day-close packet makes the FOLLOWING day unverifiable too, because the balance
 * transition has nothing to chain from. So on every pass, look back over the
 * recent days and fetch whatever is still missing.
 */
async function catchUp(today: number): Promise<void> {
  for (let d = today - 1; d >= Math.max(0, today - CATCH_UP_DAYS); d--) {
    if (store.opening(d)) continue;          // already complete for that day
    const r = await inbox.tick(d);
    if (r.dayCloseIngested) {
      note("keeper", `caught up: day-close packet for day ${d}`);
    } else if (r.newSessions.length) {
      note("keeper", `caught up: ${r.newSessions.length} receipt(s) for day ${d}`);
    }
    if (r.dayCloseRejected) {
      note("error", `day-close packet rejected for day ${d}: ${r.dayCloseRejected}`);
    }
    if (r.badSignatures.length) {
      note("error", `${r.badSignatures.length} receipt(s) with a bad signature on day ${d}`, r.badSignatures);
    }
  }
}

async function keeperTick(): Promise<void> {
  await serial(async () => {
    try {
      const r = await inbox.tick();
      if (r.newSessions.length) note("keeper", `${r.newSessions.length} new receipt(s) for day ${r.day}`, r.newSessions);
      if (r.dayCloseIngested) note("keeper", `day-close packet received for day ${r.day}`);
      if (r.floorIngested) note("keeper", "minimum balance requirement opening received");
      if (r.dayCloseRejected) note("error", `day-close packet rejected for day ${r.day}: ${r.dayCloseRejected}`);
      if (r.badSignatures.length) note("error", `${r.badSignatures.length} receipt(s) with a bad signature on day ${r.day}`, r.badSignatures);

      await catchUp(r.day);

      if (r.newSessions.length) {
        const m = await marginState(chain, id, store);
        if (shouldNotify(store, m.day, m.tier)) note("alert", m.message, { day: m.day, tier: m.tier });
      }

      for (const a of await actionTick(chain, id, store)) {
        // A day that does not verify is the one thing in this loop that needs
        // the prosumer's attention, so it is raised as an alert rather than
        // buried among the routine action lines.
        const kind = a.reason.startsWith("MISMATCH") ? "alert" : "action";
        note(kind, `${a.action}${a.day !== undefined ? ` day ${a.day}` : ""}: ${a.reason}`, a);
      }

      keeper.lastError = null;
    } catch (e) {
      keeper.lastError = (e as Error).message;
      note("error", (e as Error).message);
    }
    keeper.ticks += 1;
    keeper.lastRun = new Date().toISOString();
  });
}

function startKeeper(): void {
  if (keeper.running) return;
  keeper.running = true;
  note("info", `keeper started, checking every ${Math.round(config.pollMs / 1000)}s`);
  void keeperTick();
  keeper.timer = setInterval(() => void keeperTick(), config.pollMs);
}

function stopKeeper(): void {
  if (!keeper.running) return;
  keeper.running = false;
  if (keeper.timer) clearInterval(keeper.timer);
  keeper.timer = null;
  note("info", "keeper stopped");
}

function jsonify(value: unknown): string {
  return JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v));
}

async function overview(): Promise<unknown> {
  const clock = await chain.clock();
  const reg = await status(chain, id, store);
  let pos: unknown = null;
  let margin: unknown = null;
  if (reg.registered) {
    pos = await position(chain, id, store);
    try {
      margin = await marginState(chain, id, store);
    } catch (e) {
      margin = { tier: "unknown", message: (e as Error).message };
    }
  }
  return {
    address: id.address,
    market: config.marketAddress,
    rpcUrl: config.rpcUrl,
    receiptsDir: config.receiptsDir,
    meterConfigured: config.meterPath !== "",
    clock,
    registration: reg,
    position: pos,
    margin,
    keeper: {
      running: keeper.running,
      ticks: keeper.ticks,
      lastRun: keeper.lastRun,
      lastError: keeper.lastError,
      pollSeconds: Math.round(config.pollMs / 1000),
      autoFinalize: config.autoFinalize,
      autoCancelOwn: config.autoCancelOwn,
      autoSweep: config.autoSweep,
    },
  };
}

async function dayDetail(day: number): Promise<unknown> {
  const view = await dayView(chain, id, store, day);
  const cov = await coverage(chain, id, store, day);
  const rows = store.sessionsOf(day);
  const strip = Array.from({ length: SESSIONS }, (_v, t) => {
    const row = rows.find((r) => r.t === t);
    if (!row) return { t, held: false, sell: "0", buy: "0" };
    return { t, held: true, sell: row.sell, buy: row.buy };
  });
  let margin: unknown = null;
  try {
    margin = await marginState(chain, id, store, day);
  } catch (e) {
    margin = { tier: "unknown", message: (e as Error).message };
  }
  return {
    view,
    coverage: cov,
    strip,
    margin,
    hasOpening: store.opening(day) !== null,
    lastVerdict: store.verdict(`day-${day}`) ?? null,
  };
}

async function daysIndex(count: number): Promise<unknown> {
  const clock = await chain.clock();
  const out: unknown[] = [];
  for (let d = clock.day; d > clock.day - count; d--) {
    const dc = await chain.dayClose(d);
    const cov = await coverage(chain, id, store, d);
    out.push({
      day: d,
      state: ["Pending", "Closing", "Finalized", "Cancelled"][dc.state] ?? String(dc.state),
      held: cov.held,
      expected: cov.expected,
      hasOpening: store.opening(d) !== null,
      lastVerdict: store.verdict(`day-${d}`) ?? null,
      isToday: d === clock.day,
    });
  }
  return out;
}

type Handler = (body: Record<string, unknown>, url: URL) => Promise<unknown>;

const routes: Record<string, Handler> = {
  "GET /api/overview": async () => overview(),
  "GET /api/days": async (_b, url) => daysIndex(Number(url.searchParams.get("count") ?? 7)),
  "GET /api/day": async (_b, url) => dayDetail(Number(url.searchParams.get("day"))),
  "GET /api/log": async (_b, url) => {
    const since = Number(url.searchParams.get("since") ?? 0);
    return { seq, entries: log.filter((e) => e.seq > since) };
  },

  "POST /api/register": async () => register(chain, id, store),
  "POST /api/deposit": async (b) => deposit(chain, id, store, String(b.eur)),
  "POST /api/withdraw": async (b) => requestWithdraw(chain, id, store, String(b.eur)),

  "POST /api/sync": async (b) => inbox.tick(b.day === undefined ? undefined : Number(b.day)),
  "POST /api/sync-onchain": async (b) => inbox.ingestOnChainBlob(Number(b.day)),
  "POST /api/verify": async (b) => verifyDay(chain, id, store, Number(b.day)),

  "POST /api/request-data": async (b) => recourse.requestData(chain, id, store, Number(b.day)),
  "POST /api/fetch-data": async (b) => recourse.fetchData(chain, id, store, Number(b.day)),
  "POST /api/request-clear": async (b) => recourse.requestClearReveal(chain, id, store, Number(b.day)),
  "POST /api/revealed": async (b) => recourse.readRevealed(chain, id, store, Number(b.day)),
  "POST /api/cancel": async (b) => recourse.cancel(chain, id, store, Number(b.day), String(b.reason ?? "client-initiated")),

  "POST /api/finalize": async (b) => tryFinalize(chain, id, store, Number(b.day)),
  "POST /api/sweep": async () => trySweep(chain),

  "POST /api/keeper": async (b) => {
    if (b.on) startKeeper(); else stopKeeper();
    return { running: keeper.running };
  },
};

const LOGGED = new Set([
  "POST /api/register", "POST /api/deposit", "POST /api/withdraw",
  "POST /api/request-data", "POST /api/fetch-data", "POST /api/request-clear",
  "POST /api/cancel", "POST /api/finalize", "POST /api/sweep",
]);

function readBody(req: http.IncomingMessage): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf-8");
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw) as Record<string, unknown>);
      } catch {
        reject(new Error("request body is not valid JSON"));
      }
    });
    req.on("error", reject);
  });
}

function main(): void {
  bootstrapEnv();

  const env = envReady();
  if (!env.ok) {
    console.error(`missing environment: ${env.missing.join(", ")}`);
    console.error("set PROSUMER_KEY and MARKET_ADDRESS, or point DEPLOYMENT_JSON at a deployment file");
    process.exit(1);
  }

  id = new Identity();
  chain = new Chain(id.wallet);
  store = new Store();
  inbox = new ReceiptInbox(chain, id, store);

  const server = http.createServer((req: http.IncomingMessage, res: http.ServerResponse) => {
    void (async () => {
      const url = new URL(req.url ?? "/", `http://127.0.0.1:${PORT}`);
      const key = `${req.method} ${url.pathname}`;

      if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
        const html = fs.readFileSync(path.join(UI_DIR, "index.html"), "utf-8");
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        res.end(html);
        return;
      }

      const handler = routes[key];
      if (!handler) {
        res.writeHead(404, { "content-type": "application/json" });
        res.end(jsonify({ error: `no route for ${key}` }));
        return;
      }

      try {
        const body = req.method === "POST" ? await readBody(req) : {};
        const result = await serial(() => handler(body, url));
        if (LOGGED.has(key)) note("action", `${key.replace("POST /api/", "")} ok`, result);
        res.writeHead(200, { "content-type": "application/json" });
        res.end(jsonify(result));
      } catch (e) {
        const message = (e as Error).message;
        if (LOGGED.has(key)) note("error", `${key.replace("POST /api/", "")} failed: ${message}`);
        res.writeHead(400, { "content-type": "application/json" });
        res.end(jsonify({ error: message }));
      }
    })();
  });

  server.listen(PORT, "127.0.0.1", () => {
    console.log(`prosumer client at http://127.0.0.1:${PORT}`);
    console.log(`  address ${id.address}`);
    console.log(`  market  ${config.marketAddress}`);
    console.log(`  key stays in this process and is never sent to the browser`);
    if (process.env.KEEPER === "1") startKeeper();
  });

  process.on("SIGINT", () => {
    stopKeeper();
    server.close();
    process.exit(0);
  });
}

main();
