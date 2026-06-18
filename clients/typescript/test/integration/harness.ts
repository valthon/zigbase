import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

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

export interface TestServer {
  url: string;
  superuser: { email: string; password: string };
  dataDir: string;
  stop(): void;
}

let built = false;
function ensureBuilt(): void {
  if (built) return;
  // Prebuilt binaries supplied via ZIGBASE_TEST_BINARY + ZIGBASE_TEST_DATING_BINARY
  // (e.g. CI artifacts) skip the toolchain entirely — no Zig needed in that job.
  if (process.env.ZIGBASE_TEST_BINARY && process.env.ZIGBASE_TEST_DATING_BINARY) {
    built = true;
    return;
  }
  // The binaries MUST be built with zig 0.16.0; plain `zig` on PATH may be older.
  // Build both the generic binary (runtime-created collections) and the
  // dating-server fixture (schema baked in) so every integration test can spawn.
  for (const steps of [["build"], ["build", "dating-server"]]) {
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
  const dataDir = mkdtempSync(join(tmpdir(), "zb-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const { email, password } = opts.seedSuperuser ?? {
    email: "admin@test.local",
    password: "test-password-123",
  };

  const su = spawnSync(
    bin,
    ["superuser", "create", "--email", email, "--password", password, "--data-dir", dataDir],
    { stdio: "inherit" },
  );
  if (su.status !== 0) throw new Error("superuser create failed");

  const proc: ChildProcess = spawn(
    bin,
    ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"],
    { stdio: "inherit" },
  );

  const url = `http://127.0.0.1:${port}`;
  try {
    await waitForHealth(url);
  } catch (err) {
    proc.kill("SIGKILL");
    try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
    throw err;
  }

  return {
    url,
    superuser: { email, password },
    dataDir,
    stop() {
      proc.kill("SIGTERM");
      try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
    },
  };
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
