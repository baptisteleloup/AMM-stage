import path from "node:path";

const REQUIRED = {
  OPERATOR_KEY: "the operator's signing key",
  MARKET_ADDRESS: "the deployed MarketV4 address",
  PROSUMERS_JSON: "name to slot map for this community",
  NETPUTS_JSON: "the metering source this operator reads",
} as const;

export function envReady(): { ok: boolean; missing: string[] } {
  const missing = Object.keys(REQUIRED).filter((n) => !process.env[n]);
  return { ok: missing.length === 0, missing };
}

const ready = envReady();
if (!ready.ok) {
  throw new Error(
    "missing environment:\n"
    + ready.missing.map((n) => `  ${n} — ${REQUIRED[n as keyof typeof REQUIRED]}`).join("\n"),
  );
}

function req(name: string): string {
  return process.env[name] as string;
}

const dataDir = process.env.DATA_DIR ?? "./operator-data";

export const config = {
  rpcUrl: process.env.RPC_URL ?? "http://127.0.0.1:8545",
  operatorKey: req("OPERATOR_KEY"),
  marketAddress: req("MARKET_ADDRESS"),
  dataDir,
  dbPath: process.env.DB_PATH ?? path.join(dataDir, "operator.db"),
  receiptsDir: process.env.RECEIPTS_DIR ?? path.join(dataDir, "receipts"),
  prosumersJson: req("PROSUMERS_JSON"),
  netputsJson: req("NETPUTS_JSON"),
  tickMs: Number(process.env.TICK_MS ?? 5000),
  marginWarnNum: 12n,
  marginCritNum: 10n,
  marginDen: 10n,
};
