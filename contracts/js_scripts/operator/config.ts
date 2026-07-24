import path from "node:path";

function req(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

const dataDir = process.env.DATA_DIR ?? "./operator-data";

export const config = {
  rpcUrl: process.env.RPC_URL ?? "http://127.0.0.1:8545",
  operatorKey: req("OPERATOR_KEY"),
  marketAddress: req("MARKET_ADDRESS"),
  dataDir,
  dbPath: process.env.DB_PATH ?? path.join(dataDir, "operator.db"),
  receiptsDir: process.env.RECEIPTS_DIR ?? path.join(dataDir, "receipts"),
  prosumersJson: process.env.PROSUMERS_JSON ?? "./prosumers_nice.json",
  netputsJson: process.env.NETPUTS_JSON ?? "./netputs_nice.json",
  tickMs: Number(process.env.TICK_MS ?? 5000),
  marginWarnNum: 12n,
  marginCritNum: 10n,
  marginDen: 10n,
};
