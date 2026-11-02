// Operator daemon entry point. Every TICK_MS it opens the current session, closes and settles
// the previous day, and answers recourse requests. Configuration comes from the environment
// (config.ts). Run from contracts/:  npx tsx js_scripts/operator/main.ts

import fs from "node:fs";
import { config } from "./config.js";
import { Chain } from "./chain.js";
import { Store } from "./store.js";
import { Receipts } from "./receipts.js";
import { Margin } from "./margin.js";
import { Sessions } from "./sessions.js";
import { Close } from "./close.js";
import { Reveals } from "./reveals.js";
import { NiceSource, SyntheticSource, type NetputSource } from "./netputs.js";
import { Prover } from "./prover.js";

// Metering source: the NETPUTS_JSON file if it exists, else synthetic curves.
async function buildSource(chain: Chain): Promise<NetputSource> {
  // name => wallet
  const prosumers = JSON.parse(fs.readFileSync(config.prosumersJson, "utf-8")) as Record<string, string>;
  const slotByName = new Map<string, number>();
  for (const [name, addr] of Object.entries(prosumers)) {
    const slot = await chain.slotOf(addr); // 0 if the wallet has not registered
    if (slot > 0) slotByName.set(name, slot);
  }
  if (fs.existsSync(config.netputsJson)) {
    console.log(`[main] source: NiceSource (${slotByName.size} registered prosumers)`);
    return new NiceSource(config.netputsJson, slotByName); // file-based source
  }
  console.log(`[main] source: SyntheticSource (${config.netputsJson} not found)`);
  return new SyntheticSource([...slotByName.values()]);
}

async function main(): Promise<void> {
  const chain = new Chain();
  const chainId = await chain.chainId(); // EIP-712 domain of the receipts
  const store = new Store();
  const receipts = new Receipts(chain.wallet, chainId);
  const margin = new Margin(chain, store, receipts);
  const source = await buildSource(chain);
  const prover = new Prover(); // proofs in a child process
  const sessions = new Sessions(chain, source, receipts, margin, store);
  const close = new Close(chain, store, source, receipts, prover);
  const reveals = new Reveals(chain, store, prover);

  console.log(`[main] operator daemon up, market=${config.marketAddress} chainId=${chainId}`);
  console.log(`[main] proofs run in a separate process; session opening is never blocked by one`);

  const stop = () => { prover.stop(); process.exit(0); }; // also kills the proving child
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);

  for (;;) {
    const started = Date.now();

    // Each task is isolated: an error in one does not stop the others or the loop.
    try {
      await sessions.tick(); // open the current session if needed
    } catch (e) {
      console.error("[sessions]", (e as Error).message);
    }
    try {
      await close.tick(); // freeze, prove, settle yesterday
    } catch (e) {
      console.error("[close]", (e as Error).message);
    }
    try {
      await reveals.tick(); // answer recourse requests
    } catch (e) {
      console.error("[reveals]", (e as Error).message);
    }

    const spent = Date.now() - started;
    if (spent > config.tickMs * 2) {
      console.error(`[main] a tick took ${spent}ms, longer than expected, sessions may be late`);
    }
    await new Promise((res) => setTimeout(res, Math.max(0, config.tickMs - spent))); // keep a steady period
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
