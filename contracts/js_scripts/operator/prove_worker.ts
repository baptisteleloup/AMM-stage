// Child process forked by prover.ts. Receives one proof job at a time over IPC, proves it with
// prove.ts and sends back the proof or the error. Never run directly.

import { proveChunk, proveReveal, type ChunkWitness } from "./prove.js";

type Request = // job sent by the parent
  | { id: string; kind: "chunk"; witness: ChunkWitness }
  | { id: string; kind: "reveal"; commitment: string; bal: string; blind: string };

type Response = // answer sent back, proof as plain numbers for IPC
  | { id: string; ok: true; proof: number[]; ms: number }
  | { id: string; ok: false; error: string; ms: number };

function send(msg: Response): void {
  if (process.send) process.send(msg); // only set when forked with an IPC channel
}

process.on("message", (raw: unknown) => {
  void (async () => {
    const req = raw as Request;
    const started = Date.now();
    try {
      const proof = req.kind === "chunk"
        ? await proveChunk(req.witness) // day_chunk circuit
        : await proveReveal(BigInt(req.commitment), BigInt(req.bal), BigInt(req.blind)); // reveal circuit
      send({ id: req.id, ok: true, proof: Array.from(proof), ms: Date.now() - started });
    } catch (e) {
      send({ id: req.id, ok: false, error: (e as Error).message, ms: Date.now() - started });
    }
  })();
});

process.on("disconnect", () => process.exit(0)); // parent gone: stop
