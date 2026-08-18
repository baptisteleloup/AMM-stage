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

async function buildSource(chain: Chain): Promise<NetputSource> {
  const prosumers = JSON.parse(fs.readFileSync(config.prosumersJson, "utf-8")) as Record<string, string>;
  const slotByName = new Map<string, number>();
  for (const [name, addr] of Object.entries(prosumers)) {
    const slot = await chain.slotOf(addr);
    if (slot > 0) slotByName.set(name, slot);
  }
  if (fs.existsSync(config.netputsJson)) {
    console.log(`[main] source: NiceSource (${slotByName.size} registered prosumers)`);
    return new NiceSource(config.netputsJson, slotByName);
  }
  console.log(`[main] source: SyntheticSource (${config.netputsJson} not found)`);
  return new SyntheticSource([...slotByName.values()]);
}

async function main(): Promise<void> {
  const chain = new Chain();
  const chainId = await chain.chainId();
  const store = new Store();
  const receipts = new Receipts(chain.wallet, chainId);
  const margin = new Margin(chain, store, receipts);
  const source = await buildSource(chain);
  const prover = new Prover();
  const sessions = new Sessions(chain, source, receipts, margin, store);
  const close = new Close(chain, store, source, receipts, prover);
  const reveals = new Reveals(chain, store, prover);

  console.log(`[main] operator daemon up — market=${config.marketAddress} chainId=${chainId}`);
  console.log(`[main] proofs run in a separate process; session opening is never blocked by one`);

  const stop = () => { prover.stop(); process.exit(0); };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);

  // Sessions come first and are the only step that is time-critical: a session
  // that fails to open in its quarter-hour cannot be recovered, and its absence
  // makes the whole day unprovable. Close and reveals never block on a proof —
  // they hand the work to the prover process and collect it on a later tick —
  // so this order is enough to keep session opening punctual.
  for (;;) {
    const started = Date.now();

    try {
      await sessions.tick();
    } catch (e) {
      console.error("[sessions]", (e as Error).message);
    }
    try {
      await close.tick();
    } catch (e) {
      console.error("[close]", (e as Error).message);
    }
    try {
      await reveals.tick();
    } catch (e) {
      console.error("[reveals]", (e as Error).message);
    }

    const spent = Date.now() - started;
    if (spent > config.tickMs * 2) {
      console.error(`[main] a tick took ${spent}ms, longer than expected — sessions may be late`);
    }
    await new Promise((res) => setTimeout(res, Math.max(0, config.tickMs - spent)));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
