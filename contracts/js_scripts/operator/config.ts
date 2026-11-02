// Operator configuration, read once from the environment at import. Throws if a required
// variable is missing. Every module of the daemon imports `config` from here.

import path from "node:path";

const REQUIRED = { // must be set, no default
  OPERATOR_KEY: "the operator's signing key",
  MARKET_ADDRESS: "the deployed MarketV4 address",
  PROSUMERS_JSON: "name to slot map for this community",
  NETPUTS_JSON: "the metering source this operator reads",
} as const;

// Lists the required variables that are not set.
export function envReady(): { ok: boolean; missing: string[] } {
  const missing = Object.keys(REQUIRED).filter((n) => !process.env[n]);
  return { ok: missing.length === 0, missing };
}

const ready = envReady();
if (!ready.ok) { // fail at start-up rather than mid-run
  throw new Error(
    "missing environment:\n"
    + ready.missing.map((n) => `  ${n} — ${REQUIRED[n as keyof typeof REQUIRED]}`).join("\n"),
  );
}

function req(name: string): string {
  return process.env[name] as string; // presence checked above
}

const dataDir = process.env.DATA_DIR ?? "./operator-data"; // operator's private state

export const config = {
  rpcUrl: process.env.RPC_URL ?? "http://127.0.0.1:8545",
  operatorKey: req("OPERATOR_KEY"),
  marketAddress: req("MARKET_ADDRESS"),
  dataDir,
  dbPath: process.env.DB_PATH ?? path.join(dataDir, "operator.db"), // SQLite store (store.ts)
  receiptsDir: process.env.RECEIPTS_DIR ?? path.join(dataDir, "receipts"), // signed receipts, one folder per slot
  prosumersJson: req("PROSUMERS_JSON"), // { name: wallet address }
  netputsJson: req("NETPUTS_JSON"), // metered positions per name, see netputs.ts
  tickMs: Number(process.env.TICK_MS ?? 5000), // period of the main loop
  marginWarnNum: 12n, // warning when the projected balance falls below 1.2 x floor
  marginCritNum: 10n, // critical when it falls below the floor itself
  marginDen: 10n,
};
