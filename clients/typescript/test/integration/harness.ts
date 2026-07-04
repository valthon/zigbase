import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** Number of times to retry a failed server start (fresh port each attempt). */
const START_ATTEMPTS = 5;

/**
 * Ask the OS for a free loopback TCP port (bind :0, read the assignment, release).
 * This shrinks the collision window vs. a blind random port; the retry loop in the
 * start* helpers is the actual guarantee against a lost race. Falls back to a random
 * high port if the probe fails.
 */
async function freePort(): Promise<number> {
  return await new Promise<number>((resolvePort) => {
    const srv = createServer();
    srv.on("error", () => resolvePort(20000 + Math.floor(Math.random() * 20000)));
    srv.listen(0, "127.0.0.1", () => {
      const addr = srv.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      srv.close(() => resolvePort(port || 20000 + Math.floor(Math.random() * 20000)));
    });
  });
}

/**
 * Resolve once the server is healthy; reject FAST if the child exits before then.
 * An early non-bind start failure (e.g. zap `ListenError` on a port collision) exits
 * the process, so we surface it immediately instead of waiting out the health deadline.
 */
async function waitForHealthOrExit(url: string, proc: ChildProcess, label: string): Promise<void> {
  const exitPromise = new Promise<never>((_, reject) => {
    proc.once("exit", (code, signal) =>
      reject(new Error(`${label} exited before becoming healthy (code=${code} signal=${signal})`)),
    );
    // A spawn failure (missing binary, permissions, wrong arch) emits "error", not
    // "exit" — reject fast instead of waiting out the full health deadline.
    proc.once("error", (err) => reject(new Error(`${label} failed to spawn: ${String(err)}`)));
  });
  exitPromise.catch(() => {}); // avoid an unhandled rejection when health wins the race
  await Promise.race([waitForHealth(url), exitPromise]);
}

// This file lives at clients/typescript/test/integration/harness.ts, so the repo
// root (the dir containing build.zig / zig-out) is four levels up.
const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const REPO_ROOT = resolve(HERE, "../../../..");
// CI supplies a prebuilt binary via ZIGBASE_TEST_BINARY; otherwise use the
// zig-out path produced by ensureBuilt()'s `zig build`. `||` (not `??`) so an
// empty-string override also falls back, matching ensureBuilt()'s truthy guard
// below and avoiding a spawn of "".
const BIN = process.env.ZIGBASE_TEST_BINARY || join(REPO_ROOT, "zig-out", "bin", "zigbase");
/**
 * Absolute path to the dating fixture compiled as a server (Task 2: `zig build dating-server`).
 * CI supplies a prebuilt one via ZIGBASE_TEST_DATING_BINARY; otherwise it is the
 * zig-out path produced by ensureBuilt()'s `zig build dating-server`.
 */
export const DATING_BIN =
  process.env.ZIGBASE_TEST_DATING_BINARY || join(REPO_ROOT, "zig-out", "bin", "dating-server");
/**
 * Absolute path to the auth-round-2 e2e fixture compiled as a server (Task 5:
 * `zig build auth2-server` — `.auth.session.store = .table` + a registered `beforeAuthSuccess`).
 * CI supplies a prebuilt one via ZIGBASE_TEST_AUTH2_BINARY; otherwise it is the
 * zig-out path produced by ensureBuilt()'s `zig build auth2-server`.
 */
export const AUTH2_BIN =
  process.env.ZIGBASE_TEST_AUTH2_BINARY || join(REPO_ROOT, "zig-out", "bin", "auth2-server");

export interface TestServer {
  url: string;
  superuser: { email: string; password: string };
  dataDir: string;
  stop(): void;
}

let built = false;
function ensureBuilt(): void {
  if (built) return;
  // Prebuilt binaries supplied via ZIGBASE_TEST_BINARY + ZIGBASE_TEST_DATING_BINARY +
  // ZIGBASE_TEST_AUTH2_BINARY (e.g. CI artifacts) skip the toolchain entirely — no
  // Zig needed in that job.
  if (
    process.env.ZIGBASE_TEST_BINARY &&
    process.env.ZIGBASE_TEST_DATING_BINARY &&
    process.env.ZIGBASE_TEST_AUTH2_BINARY
  ) {
    built = true;
    return;
  }
  // The binaries MUST be built with zig 0.16.0; plain `zig` on PATH may be older.
  // Build the generic binary (runtime-created collections), the dating-server
  // fixture, and the auth2-server fixture (schemas baked in) so every integration
  // test can spawn.
  for (const steps of [["build"], ["build", "dating-server"], ["build", "auth2-server"]]) {
    const r = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", ...steps], {
      cwd: REPO_ROOT,
      stdio: "inherit",
    });
    if (r.status !== 0) throw new Error(`zig ${steps.join(" ")} failed`);
  }
  built = true;
}

async function waitForHealth(url: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const res = await fetch(`${url}/api/health`);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    if (Date.now() > deadline) throw new Error("server did not become healthy");
    await new Promise((r) => setTimeout(r, 200));
  }
}

/**
 * Spawn an already-built zigbase app binary (schema baked in), seed a superuser,
 * and wait for health. `bin` may be an absolute path (e.g. DATING_BIN) or a bare
 * name resolved under zig-out/bin/.
 */
export async function startAppServer(opts: {
  bin: string;
  seedSuperuser?: { email: string; password: string };
}): Promise<TestServer> {
  ensureBuilt();
  const bin = opts.bin.includes("/") ? opts.bin : join(REPO_ROOT, "zig-out", "bin", opts.bin);
  const { email, password } = opts.seedSuperuser ?? {
    email: "admin@test.local",
    password: "test-password-123",
  };

  // Retry the spawn on a fresh port each attempt: a port collision (concurrent test,
  // TIME_WAIT, another process) makes the zap listener fail to bind, so the server
  // exits early. We detect that exit fast and retry instead of failing the test.
  let lastErr: unknown;
  for (let attempt = 1; attempt <= START_ATTEMPTS; attempt++) {
    const dataDir = mkdtempSync(join(tmpdir(), "zb-it-"));
    const su = spawnSync(
      bin,
      ["superuser", "create", "--email", email, "--password", password, "--data-dir", dataDir],
      { stdio: "inherit" },
    );
    if (su.status !== 0) {
      try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
      throw new Error("superuser create failed");
    }

    const port = await freePort();
    const proc: ChildProcess = spawn(
      bin,
      ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"],
      { stdio: "inherit" },
    );
    const url = `http://127.0.0.1:${port}`;

    try {
      await waitForHealthOrExit(url, proc, "server");
      return {
        url,
        superuser: { email, password },
        dataDir,
        stop() {
          proc.kill("SIGTERM");
          try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
        },
      };
    } catch (err) {
      lastErr = err;
      proc.kill("SIGKILL");
      try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
    }
  }

  throw new Error(
    `server did not start after ${START_ATTEMPTS} attempts; last error: ${String(lastErr)}`,
  );
}

/** Backward-compatible: spawn the generic zigbase binary (runtime-created collections). */
export async function startServer(): Promise<TestServer> {
  // ensureBuilt() (invoked by startAppServer) builds the generic binary too.
  return startAppServer({ bin: BIN });
}

/** Authenticate as the superuser and return the bearer token. */
export async function superuserToken(server: TestServer): Promise<string> {
  const res = await fetch(`${server.url}/api/collections/_superusers/auth-with-password`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identity: server.superuser.email, password: server.superuser.password }),
  });
  if (!res.ok) throw new Error(`superuser auth failed: ${res.status}`);
  return ((await res.json()) as { token: string }).token;
}

/** Create a collection via the superuser collections API. */
export async function createCollection(
  server: TestServer,
  token: string,
  definition: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const res = await fetch(`${server.url}/api/collections`, {
    method: "POST",
    headers: { "content-type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify(definition),
  });
  if (!res.ok) throw new Error(`create collection failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as Record<string, unknown>;
}
