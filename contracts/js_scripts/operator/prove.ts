import { readFileSync } from "node:fs";
import { Noir } from "@noir-lang/noir_js";
import { UltraHonkBackend, Barretenberg } from "@aztec/bb.js";

type Circuit = { bytecode: string; abi: unknown };

const cache = new Map<string, Circuit>();

function load(path: string): Circuit {
  let c = cache.get(path);
  if (!c) {
    c = JSON.parse(readFileSync(path, "utf-8")) as Circuit;
    cache.set(path, c);
  }
  return c;
}

async function prove(circuitPath: string, inputs: Record<string, unknown>): Promise<Uint8Array> {
  const circuit = load(circuitPath);
  const noir = new Noir(circuit as never);
  const { witness } = await noir.execute(inputs as never);
  const api = await Barretenberg.new({ threads: 1 });
  try {
    const backend = new UltraHonkBackend(circuit.bytecode, api);
    const { proof } = await backend.generateProof(witness, { verifierTarget: "evm" } as never);
    return proof;
  } finally {
    await api.destroy();
  }
}

export type ChunkWitness = {
  price_r: string[];
  price_c: string[];
  slots: string[];
  netput_hashes: string[];
  old_commits: string[];
  new_commits: string[];
  deposits: string[];
  withdrawals: string[];
  withdrawals_paid: string[];
  floor_commits: string[];
  partial_s: string[];
  partial_d: string[];
  partial_paid_out: string;
  partial_paid_in: string;
  sell: string[][];
  buy: string[][];
  old_bals: string[];
  old_blinds: string[];
  new_blinds: string[];
  floors: string[];
  floor_blinds: string[];
  netput_blinds: string[];
};

export function proveChunk(w: ChunkWitness): Promise<Uint8Array> {
  return prove("circuits/day_chunk/target/day_chunk.json", w);
}

export function proveReveal(commitment: bigint, bal: bigint, blind: bigint): Promise<Uint8Array> {
  return prove("circuits/reveal/target/reveal.json", {
    commitment: commitment.toString(),
    bal: bal.toString(),
    blind: blind.toString(),
  });
}
