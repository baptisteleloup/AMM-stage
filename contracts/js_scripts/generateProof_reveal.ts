import { readFileSync } from "fs";
import { AbiCoder } from "ethers";
import { Noir } from "@noir-lang/noir_js";
import { UltraHonkBackend, Barretenberg } from "@aztec/bb.js";
import { T1, T2, dayState, emptyPrices, toHex32 } from "./scenario";

const log = (...a: unknown[]) => console.error("[reveal]", ...a);
const ffiOut = process.stdout.write.bind(process.stdout);
process.stdout.write = process.stderr.write.bind(process.stderr) as never;

async function main() {
  const slot = Number(process.argv[2]);
  const [r10, c10, r50, c50] = process.argv.slice(3, 7).map(BigInt);

  const prices = emptyPrices();
  prices.r[T1] = r10;
  prices.c[T1] = c10;
  prices.r[T2] = r50;
  prices.c[T2] = c50;

  const st = await dayState(1, prices);
  const i = slot - 1;
  const bal = st.newBals[i];
  const blind_ = st.newBlinds[i];
  const commitment = st.newCommits[i];
  log(`slot ${slot}: bal=${bal} pEUR`);

  const circuit = JSON.parse(
    readFileSync("circuits/reveal/target/reveal.json", "utf8"),
  );
  const noir = new Noir(circuit);
  const { witness } = await noir.execute({
    commitment: commitment.toString(),
    bal: bal.toString(),
    blind: blind_.toString(),
  });

  const api = await Barretenberg.new({ threads: 1 });
  const backend = new UltraHonkBackend(circuit.bytecode, api);
  log("proving...");
  const { proof } = await backend.generateProof(witness, { verifierTarget: "evm" });
  await api.destroy();
  log(`proof ${proof.length} bytes`);

  ffiOut(
    AbiCoder.defaultAbiCoder().encode(["bytes", "uint256"], [proof, bal]),
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
