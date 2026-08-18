import { proveChunk, proveReveal, type ChunkWitness } from "./prove.js";

/**
 * prove_worker.ts — a child process whose only job is to generate proofs.
 *
 * Proof generation is the one operation in this daemon that takes seconds. Run
 * in the main process it blocks session opening, and sessions that fail to open
 * can never be recovered: the day close rebuilds all 96 sessions from the netput
 * source while the chain only holds the ones that opened, so the aggregates no
 * longer match and the day becomes unprovable. That failure is reachable by any
 * prosumer exercising its right to a disclosure — a denial of service through a
 * legitimate action. Hence this process.
 *
 * The protocol is one message in, one message out. The parent (prover.ts) owns
 * the queue, the timeouts and the restarts; this file stays deliberately dumb.
 */

type Request =
  | { id: string; kind: "chunk"; witness: ChunkWitness }
  | { id: string; kind: "reveal"; commitment: string; bal: string; blind: string };

type Response =
  | { id: string; ok: true; proof: number[]; ms: number }
  | { id: string; ok: false; error: string; ms: number };

function send(msg: Response): void {
  if (process.send) process.send(msg);
}

process.on("message", (raw: unknown) => {
  void (async () => {
    const req = raw as Request;
    const started = Date.now();
    try {
      const proof = req.kind === "chunk"
        ? await proveChunk(req.witness)
        : await proveReveal(BigInt(req.commitment), BigInt(req.bal), BigInt(req.blind));
      send({ id: req.id, ok: true, proof: Array.from(proof), ms: Date.now() - started });
    } catch (e) {
      send({ id: req.id, ok: false, error: (e as Error).message, ms: Date.now() - started });
    }
  })();
});

process.on("disconnect", () => process.exit(0));
