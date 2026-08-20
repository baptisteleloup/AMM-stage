import { Chain } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";
import { register, status } from "./register.js";
import { deposit, requestWithdraw, position } from "./money.js";
import { ReceiptInbox } from "./receipts.js";
import { verifyDay } from "./verify.js";
import { dayView, coverage } from "./clock.js";
import { marginState, shouldNotify } from "./margin.js";
import { requestData, fetchData, requestClearReveal, readRevealed, cancel } from "./recourse.js";
import { actionTick, tryFinalize, trySweep } from "./actions.js";
import { config, envReady } from "./config.js";

function print(o: unknown): void {
  console.log(JSON.stringify(o, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
}

const USAGE = `usage: client <command>

  identity    register | status | whoami
  money       deposit <eur> | withdraw <eur> | position
  receipts    sync [day] | sync-onchain <day> | coverage [day]
  checking    verify <day> | day [day] | margin [day]
  recourse    request-data <day> | fetch-data <day> | request-clear <day>
              revealed <day> | cancel <day> [reason]
  keeping     finalize <day> | sweep
  daemon      watch

environment:
  MARKET_ADDRESS   required   the market contract address
  PROSUMER_KEY     required   this prosumer's private key
  RPC_URL          optional   default http://127.0.0.1:8545
  RECEIPTS_DIR     optional   default ./operator-data/receipts
  METER_PATH       optional   meter data, enables the meter check in \`verify\``;

const COMMANDS = new Set([
  "register", "status", "whoami", "deposit", "withdraw", "position",
  "sync", "sync-onchain", "coverage", "verify", "day", "margin",
  "request-data", "fetch-data", "request-clear", "revealed", "cancel",
  "finalize", "sweep", "watch",
]);

async function main(): Promise<void> {
  const [cmd, arg] = process.argv.slice(2);

  if (!cmd || cmd === "help" || cmd === "--help" || cmd === "-h") {
    console.log(USAGE);
    return;
  }
  if (!COMMANDS.has(cmd)) {
    console.error(`unknown command: ${cmd}\n`);
    console.log(USAGE);
    process.exit(1);
  }

  const env = envReady();
  if (!env.ok) {
    console.error(`missing environment: ${env.missing.join(", ")}\n`);
    console.log(USAGE);
    process.exit(1);
  }

  const id = new Identity();
  const chain = new Chain(id.wallet);
  const store = new Store();

  switch (cmd) {
    case "register":
      print(await register(chain, id, store));
      break;

    case "status": {
      const st = await status(chain, id, store);
      const clock = await chain.clock();
      print({ ...st, day: clock.day, session: clock.t });
      break;
    }

    case "whoami":
      print({
        address: id.address,
        encryptionPubKey: id.encryptionPubKey,
        slot: store.slot || (await chain.slotOf(id.address)),
      });
      break;

    case "deposit":
      if (!arg) throw new Error("usage: deposit <amount in EUR>");
      print(await deposit(chain, id, store, arg));
      break;

    case "withdraw":
      if (!arg) throw new Error("usage: withdraw <amount in EUR>");
      print(await requestWithdraw(chain, id, store, arg));
      break;

    case "position":
      print(await position(chain, id, store));
      break;

    case "sync":
      print(await new ReceiptInbox(chain, id, store).tick(arg ? Number(arg) : undefined));
      break;

    case "verify": {
      if (!arg) throw new Error("usage: verify <dayId>");
      const v = await verifyDay(chain, id, store, Number(arg));
      print(v);
      if (v.verdict === "mismatch") process.exitCode = 2;
      break;
    }

    case "day": {
      print(await dayView(chain, id, store, arg ? Number(arg) : undefined));
      break;
    }

    case "coverage": {
      const clock = await chain.clock();
      print(await coverage(chain, id, store, arg ? Number(arg) : clock.day));
      break;
    }

    case "margin": {
      print(await marginState(chain, id, store, arg ? Number(arg) : undefined));
      break;
    }

    case "request-data":
      if (!arg) throw new Error("usage: request-data <dayId>");
      print(await requestData(chain, id, store, Number(arg)));
      break;

    case "fetch-data":
      if (!arg) throw new Error("usage: fetch-data <dayId>");
      print(await fetchData(chain, id, store, Number(arg)));
      break;

    case "request-clear":
      if (!arg) throw new Error("usage: request-clear <dayId>");
      print(await requestClearReveal(chain, id, store, Number(arg)));
      break;

    case "revealed":
      if (!arg) throw new Error("usage: revealed <dayId>");
      print(await readRevealed(chain, id, store, Number(arg)));
      break;

    case "cancel":
      if (!arg) throw new Error("usage: cancel <dayId>");
      print(await cancel(chain, id, store, Number(arg), process.argv[4] ?? "client-initiated"));
      break;

      break;

    case "finalize":
      if (!arg) throw new Error("usage: finalize <dayId>");
      print(await tryFinalize(chain, id, store, Number(arg)));
      break;

    case "sweep":
      print(await trySweep(chain));
      break;

    case "sync-onchain":
      if (!arg) throw new Error("usage: sync-onchain <dayId>");
      print(await new ReceiptInbox(chain, id, store).ingestOnChainBlob(Number(arg)));
      break;

    case "watch": {
      const inbox = new ReceiptInbox(chain, id, store);
      console.error(`watching, every ${config.pollMs} ms`);
      for (;;) {
        try {
          const r = await inbox.tick();
          if (r.newSessions.length || r.dayCloseIngested || r.floorIngested || r.badSignatures.length) print(r);
          if (r.newSessions.length) {
            const m = await marginState(chain, id, store);
            if (shouldNotify(store, m.day, m.tier)) print({ alert: m.tier, day: m.day, message: m.message });
          }
          for (const a of await actionTick(chain, id, store)) print(a);
        } catch (e) {
          console.error("[sync]", (e as Error).message);
        }
        await new Promise((res) => setTimeout(res, config.pollMs));
      }
    }

    default:
      console.log(USAGE);
      process.exit(1);
  }
}

main().catch((e) => {
  console.error((e as Error).message);
  process.exit(1);
});
