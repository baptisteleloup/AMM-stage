// Client configuration, read only from environment variables. PROSUMER_KEY and MARKET_ADDRESS are
// required; receipts come from RECEIPTS_DIR (fs) or RECEIPTS_URL (http). Also the market constants
// the client recomputes with (sessions per day, token units, price grain).

import path from "node:path";

// Reads a required variable, with a hint on how to set it.
function req(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(
      `missing env ${name}\n`
      + `  example:\n`
      + `    export MARKET_ADDRESS=0x...   (from the deployment file)\n`
      + `    export PROSUMER_KEY=0x...     (the prosumer's private key)`,
    );
  }
  return v;
}

const dataDir = process.env.CLIENT_DATA_DIR ?? "./client-data"; // local state, inbox and store live here

export const config = {
  rpcUrl: process.env.RPC_URL ?? "http://127.0.0.1:8545", // chain node
  get prosumerKey(): string { // member's wallet key, also its decryption key
    return req("PROSUMER_KEY");
  },
  get marketAddress(): string { // MarketV4 address
    return req("MARKET_ADDRESS");
  },
  eeurAddress: process.env.EEUR_ADDRESS ?? "", // token address, optional (read from the market otherwise)
  dataDir,
  storePath: process.env.CLIENT_STORE ?? path.join(dataDir, "state.json"), // local state file (openings, sessions, verdicts)
  inboxDir: process.env.CLIENT_INBOX ?? path.join(dataDir, "inbox"), // where decrypted recourse data is written
  transport: (process.env.RECEIPT_TRANSPORT ?? "fs") as "fs" | "http", // how receipts reach the client
  get receiptsDir(): string { // fs transport: folder the operator's receipts are delivered to
    const v = process.env.RECEIPTS_DIR;
    if (!v) {
      throw new Error(
        "missing env RECEIPTS_DIR\n"
        + "  where this client reads the receipts the operator published for it.\n"
        + "  On one machine that is the operator's receipts directory; in a pilot\n"
        + "  it is wherever they are delivered. Set RECEIPT_TRANSPORT=http and\n"
        + "  RECEIPTS_URL instead to fetch them over the network.",
      );
    }
    return v;
  },
  receiptsUrl: process.env.RECEIPTS_URL ?? "", // http transport: base URL of the receipts
  meterPath: process.env.METER_PATH ?? "", // optional own meter readings, to cross-check receipts
  compressedKey: process.env.COMPRESSED_KEY === "1", // register a 33-byte key instead of 65 bytes
  autoFinalize: process.env.AUTO_FINALIZE !== "0", // call finalizeDay when a day is ready
  autoCancelOwn: process.env.AUTO_CANCEL_OWN === "1", // cancel a day on its own unanswered request
  autoSweep: process.env.AUTO_SWEEP === "1", // sweep the dust pot when non-zero
  autoRequestData: process.env.AUTO_REQUEST_DATA !== "0", // open recourse stage 1 when a check fails
  autoFetchData: process.env.AUTO_FETCH_DATA !== "0", // decrypt the stage 1 answer when posted
  autoRequestClear: process.env.AUTO_REQUEST_CLEAR !== "0", // open recourse stage 2 after stage 1
  pollMs: Number(process.env.CLIENT_POLL_MS ?? 30000), // watch loop period
  marginWarnNum: 12n, // margin warning when balance < 1.2 x floor
  marginCritNum: 10n, // margin critical when balance < 1.0 x floor
  marginDen: 10n,
};

export const SESSIONS = 96; // same as MarketV4.SESSIONS
export const WEI_PER_UNIT = 1_000_000n; // token wei per internal unit (1e-12 currency), as MarketV4
export const PRICE_SCALE = 100_000_000_000n; // 18-decimal price to stored 32-bit price, as MarketV4

// Lists the variables still missing, so the UI can show a setup screen instead of failing.
export function envReady(): { ok: boolean; missing: string[] } {
  const missing: string[] = [];
  if (!process.env.PROSUMER_KEY) missing.push("PROSUMER_KEY");
  if (!process.env.MARKET_ADDRESS) missing.push("MARKET_ADDRESS");
  const transport = process.env.RECEIPT_TRANSPORT ?? "fs";
  if (transport === "fs" && !process.env.RECEIPTS_DIR) missing.push("RECEIPTS_DIR");
  if (transport === "http" && !process.env.RECEIPTS_URL) missing.push("RECEIPTS_URL");
  return { ok: missing.length === 0, missing };
}
