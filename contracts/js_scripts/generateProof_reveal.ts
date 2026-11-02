// FFI helper of test/MarketV4.ffi.t.sol: proves with the reveal circuit that a member's day-1 balance
// of the scenario opens its commitment, and prints abi.encode(proof, bal) on stdout for vm.ffi.
// Called from contracts/ as: npx tsx js_scripts/generateProof_reveal.ts <slot> <r10> <c10> <r50> <c50>

import { readFileSync } from "fs";
import { AbiCoder } from "ethers";
import { Noir } from "@noir-lang/noir_js";
import { UltraHonkBackend, Barretenberg } from "@aztec/bb.js";
import { T1, T2, dayState, emptyPrices, toHex32 } from "./scenario";

const log = (...a: unknown[]) => console.error("[reveal]", ...a);
const ffiOut = process.stdout.write.bind(process.stdout); // the only write vm.ffi reads
process.stdout.write = process.stderr.write.bind(process.stderr) as never; // library logs go to stderr

async function main() {
  const slot = Number(process.argv[2]);
  const [r10, c10, r50, c50] = process.argv.slice(3, 7).map(BigInt); // on-chain rates of sessions T1 and T2

  const prices = emptyPrices();
  prices.r[T1] = r10;
  prices.c[T1] = c10;
  prices.r[T2] = r50;
  prices.c[T2] = c50;

  const st = await dayState(1, prices); // the balance after day 1 is the one revealed
  const i = slot - 1; // lane index
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

  const api = await Barretenberg.new({ threads: 1 }); // UltraHonk prover
  const backend = new UltraHonkBackend(circuit.bytecode, api);
  log("proving...");
  const { proof } = await backend.generateProof(witness, { verifierTarget: "evm" }); // format of RevealVerifier.sol
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
