import { proveChunk, proveReveal, type ChunkWitness } from "./prove.js";


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
