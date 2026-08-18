import { fork, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import type { ChunkWitness } from "./prove.js";

/**
 * prover.ts — hands proof generation to a separate process and never blocks.
 *
 * Everything that calls this asks for a job by name and gets one of four
 * answers back immediately: idle, running, done, or failed. Nothing here waits
 * for a proof. Callers submit on one tick and collect on a later one, which is
 * what keeps session opening on time while a proof is in flight.
 *
 * The worker is restarted if it dies or overruns, and a job that overruns is
 * reported as failed rather than left hanging, so the caller can count it and
 * eventually give up.
 */

export type JobState =
  | { state: "idle" }
  | { state: "running"; sinceMs: number }
  | { state: "done"; proof: Uint8Array; ms: number }
  | { state: "failed"; error: string; ms: number };

type Pending = {
  id: string;
  message: Record<string, unknown>;
  startedAt: number;
};

const TIMEOUT_MS = Number(process.env.PROOF_TIMEOUT_MS ?? 300000);

// import.meta is unavailable here: with no "type": "module" in package.json the
// project transpiles to CommonJS, which rejects it. The daemon is launched from
// the repository root, so resolve against the working directory and let
// OPERATOR_DIR override it if that ever stops being true.
function workerPath(): string {
  const candidates = [
    process.env.PROVE_WORKER,
    process.env.OPERATOR_DIR ? path.join(process.env.OPERATOR_DIR, "prove_worker.ts") : undefined,
    path.join(process.cwd(), "js_scripts", "operator", "prove_worker.ts"),
    path.join(process.cwd(), "operator", "prove_worker.ts"),
    path.join(process.cwd(), "prove_worker.ts"),
  ].filter(Boolean) as string[];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  throw new Error(
    "cannot find prove_worker.ts. Run the daemon from the repository root, or "
    + "set PROVE_WORKER to its path. Looked in:\n  " + candidates.join("\n  "));
}

export class Prover {
  private child: ChildProcess | null = null;
  private queue: Pending[] = [];
  private current: Pending | null = null;
  private results = new Map<string, JobState>();
  private timer: ReturnType<typeof setTimeout> | null = null;

  private ensureChild(): ChildProcess {
    if (this.child && this.child.connected) return this.child;

    // The daemon is normally run under tsx, whose loader lives in execArgv;
    // passing it on is what lets the child import a .ts file at all.
    const child = fork(workerPath(), [], {
      execArgv: process.execArgv,
      stdio: ["ignore", "inherit", "inherit", "ipc"],
      env: process.env,
    });

    child.on("message", (raw: unknown) => {
      const msg = raw as { id: string; ok: boolean; proof?: number[]; error?: string; ms: number };
      if (this.current && this.current.id === msg.id) {
        this.results.set(msg.id, msg.ok
          ? { state: "done", proof: Uint8Array.from(msg.proof ?? []), ms: msg.ms }
          : { state: "failed", error: msg.error ?? "unknown", ms: msg.ms });
        this.finishCurrent();
      }
    });

    child.on("exit", (code: number | null, signal: string | null) => {
      if (this.current) {
        this.results.set(this.current.id, {
          state: "failed",
          error: `prover process exited (${signal ?? code}) mid-job`,
          ms: Date.now() - this.current.startedAt,
        });
        this.finishCurrent();
      }
      this.child = null;
    });

    this.child = child;
    return child;
  }

  private finishCurrent(): void {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    this.current = null;
    this.pump();
  }

  private pump(): void {
    if (this.current || this.queue.length === 0) return;
    const job = this.queue.shift()!;
    job.startedAt = Date.now();
    this.current = job;
    const child = this.ensureChild();
    child.send(job.message);

    this.timer = setTimeout(() => {
      if (!this.current || this.current.id !== job.id) return;
      this.results.set(job.id, {
        state: "failed",
        error: `no proof after ${Math.round(TIMEOUT_MS / 1000)}s`,
        ms: Date.now() - job.startedAt,
      });
      // A worker that overran is not trusted to recover; replace it.
      try { this.child?.kill("SIGKILL"); } catch { /* already gone */ }
      this.child = null;
      this.finishCurrent();
    }, TIMEOUT_MS);
  }

  private submit(id: string, message: Record<string, unknown>): void {
    if (this.current?.id === id) return;
    if (this.queue.some((j) => j.id === id)) return;
    if (this.results.has(id)) return;
    this.queue.push({ id, message, startedAt: 0 });
    this.pump();
  }

  /** Ask for a chunk proof. Returns at once; poll with `state` on later ticks. */
  requestChunk(id: string, witness: ChunkWitness): void {
    this.submit(id, { id, kind: "chunk", witness });
  }

  /** Ask for a reveal proof. Returns at once. */
  requestReveal(id: string, commitment: bigint, bal: bigint, blind: bigint): void {
    this.submit(id, {
      id, kind: "reveal",
      commitment: commitment.toString(), bal: bal.toString(), blind: blind.toString(),
    });
  }

  state(id: string): JobState {
    const done = this.results.get(id);
    if (done) return done;
    if (this.current?.id === id) return { state: "running", sinceMs: Date.now() - this.current.startedAt };
    if (this.queue.some((j) => j.id === id)) return { state: "running", sinceMs: 0 };
    return { state: "idle" };
  }

  /** Drop a finished job so the same id can be asked for again. */
  clear(id: string): void {
    this.results.delete(id);
  }

  get busy(): boolean {
    return this.current !== null || this.queue.length > 0;
  }

  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    try { this.child?.kill("SIGTERM"); } catch { /* already gone */ }
    this.child = null;
  }
}
