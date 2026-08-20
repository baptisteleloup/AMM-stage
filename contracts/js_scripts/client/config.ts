import path from "node:path";

function req(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(
      `missing env ${name}\n`
      + `  example:\n`
      + `    export MARKET_ADDRESS=0x...   (from deployed_demo.json)\n`
      + `    export PROSUMER_KEY=0x...     (a prosumer privateKey from deployed_demo.json)`,
    );
  }
  return v;
}

const dataDir = process.env.CLIENT_DATA_DIR ?? "./client-data";

export const config = {
  rpcUrl: process.env.RPC_URL ?? "http://127.0.0.1:8545",
  get prosumerKey(): string {
    return req("PROSUMER_KEY");
  },
  get marketAddress(): string {
    return req("MARKET_ADDRESS");
  },
  eeurAddress: process.env.EEUR_ADDRESS ?? "",
  dataDir,
  storePath: process.env.CLIENT_STORE ?? path.join(dataDir, "state.json"),
  inboxDir: process.env.CLIENT_INBOX ?? path.join(dataDir, "inbox"),
  transport: (process.env.RECEIPT_TRANSPORT ?? "fs") as "fs" | "http",
  get receiptsDir(): string {
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
  receiptsUrl: process.env.RECEIPTS_URL ?? "",
  meterPath: process.env.METER_PATH ?? "",
  compressedKey: process.env.COMPRESSED_KEY === "1",
  autoFinalize: process.env.AUTO_FINALIZE !== "0",
  autoCancelOwn: process.env.AUTO_CANCEL_OWN === "1",
  autoSweep: process.env.AUTO_SWEEP === "1",
  // First rung of the recourse ladder, on by default. It costs only gas, it is
  // reversible in effect, and it is the standard remedy for a day that will not
  // verify. The rungs above it are not automated: revealing a balance in the
  // clear is irreversible and public, and cancelling a day undoes trading for
  // the whole community — neither should follow from one local check, which can
  // fail for a corrupted file as easily as for a dishonest operator.
  autoRequestData: process.env.AUTO_REQUEST_DATA !== "0",
  autoFetchData: process.env.AUTO_FETCH_DATA !== "0",
  pollMs: Number(process.env.CLIENT_POLL_MS ?? 30000),
  marginWarnNum: 12n,
  marginCritNum: 10n,
  marginDen: 10n,
};

export const SESSIONS = 96;
export const WEI_PER_UNIT = 1_000_000n;
export const PRICE_SCALE = 100_000_000_000n;

export function envReady(): { ok: boolean; missing: string[] } {
  const missing: string[] = [];
  if (!process.env.PROSUMER_KEY) missing.push("PROSUMER_KEY");
  if (!process.env.MARKET_ADDRESS) missing.push("MARKET_ADDRESS");
  const transport = process.env.RECEIPT_TRANSPORT ?? "fs";
  if (transport === "fs" && !process.env.RECEIPTS_DIR) missing.push("RECEIPTS_DIR");
  if (transport === "http" && !process.env.RECEIPTS_URL) missing.push("RECEIPTS_URL");
  return { ok: missing.length === 0, missing };
}
