
import { readFileSync } from "fs";
import { AbiCoder } from "ethers";
import { Noir } from "@noir-lang/noir_js";
import { UltraHonkBackend, Barretenberg } from "@aztec/bb.js";
import {
  BATCH, N_PROSUMERS, SESSIONS, T1, T2, FLOOR, floorBlind,
  dayState, emptyPrices, hashNetputs, commitBalance, toHex32,
} from "./scenario";

const log = (...a: unknown[]) => console.error("[daychunk]", ...a);

const ffiOut = process.stdout.write.bind(process.stdout);
process.stdout.write = process.stderr.write.bind(process.stderr) as never;

async function main() {
  const mode = process.argv[2];
  const abi = AbiCoder.defaultAbiCoder();

  if (mode === "constants") {
    const zeros = Array(SESSIONS).fill(0n) as bigint[];
    const empty = await hashNetputs(0n, 0n, zeros, zeros);
    const zeroCommit = await commitBalance(0n, 0n);
    const floorC1 = await commitBalance(FLOOR, floorBlind(1));
    const floorC2 = await commitBalance(FLOOR, floorBlind(2));
    ffiOut(
      abi.encode(
        ["bytes32", "bytes32", "bytes32", "bytes32"],
        [toHex32(empty), toHex32(zeroCommit), toHex32(floorC1), toHex32(floorC2)],
      ),
    );
    return;
  }

  const day = Number(mode) as 0 | 1;
  if (day !== 0 && day !== 1) throw new Error(`bad mode: ${mode}`);

  const prices = emptyPrices();
  if (day === 1) {
    const [r10, c10, r50, c50] = process.argv.slice(3, 7).map(BigInt);
    prices.r[T1] = r10;
    prices.c[T1] = c10;
    prices.r[T2] = r50;
    prices.c[T2] = c50;
  }

  const st = await dayState(day, prices);

  const F = (x: bigint) => x.toString();
  const inputs = {
    price_r: prices.r.map(F),
    price_c: prices.c.map(F),
    slots: st.slots.map(F),
    netput_hashes: st.netputHashes.map(F),
    old_commits: st.oldCommits.map(F),
    new_commits: st.newCommits.map(F),
    deposits: st.deposits.map(F),
    withdrawals: st.withdrawals.map(F),
    withdrawals_paid: st.withdrawalsPaid.map(F),
    floor_commits: st.floorCommits.map(F), 
    partial_s: st.partialS.map(F),
    partial_d: st.partialD.map(F),
    partial_paid_out: F(st.partialPaidOut),
    partial_paid_in: F(st.partialPaidIn),
    sell: st.sell.map((row) => row.map(F)),
    buy: st.buy.map((row) => row.map(F)),
    old_bals: st.oldBals.map(F),
    old_blinds: st.oldBlinds.map(F),
    new_blinds: st.newBlinds.map(F),
    floors: st.floors.map(F),          
    floor_blinds: st.floorBlinds.map(F),
    netput_blinds: st.netputBlinds.map(F), 
  };

  const circuit = JSON.parse(
    readFileSync("circuits/day_chunk/target/day_chunk.json", "utf8"),
  );
  const noir = new Noir(circuit);
  log(`day ${day}: executing circuit...`);
  const { witness } = await noir.execute(inputs);


  const api = await Barretenberg.new({ threads: 1 });
  const backend = new UltraHonkBackend(circuit.bytecode, api);
  log(`day ${day}: proving (takes a few seconds)...`);
  const { proof, publicInputs } = await backend.generateProof(witness, {
    verifierTarget: "evm",
  });
  await api.destroy(); 
  log(`day ${day}: proof ${proof.length} bytes, ${publicInputs.length} public inputs`);


  const expected = SESSIONS * 4 + BATCH * 8 + 2;
  if (publicInputs.length !== expected) {
    throw new Error(
      `public input count ${publicInputs.length} != contract's ${expected} -- circuit and _buildPublicInputs are OUT OF SYNC`,
    );
  }

  ffiOut(
    abi.encode(
      ["bytes", "bytes32[]", "bytes32[]", "uint256", "uint256"],
      [
        proof,
        st.netputHashes.slice(0, N_PROSUMERS).map(toHex32),
        st.newCommits.map(toHex32),
        st.partialPaidOut,
        st.partialPaidIn,
      ],
    ),
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
