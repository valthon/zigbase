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

export interface TestServer {
  url: string;
  superuser: { email: string; password: string };
  stop(): void;
}

let built = false;
function ensureBuilt(): void {
  if (built) return;
  // A prebuilt binary supplied via ZIGBASE_TEST_BINARY (e.g. a CI artifact)
  // skips the build entirely — no Zig toolchain needed in that job.
  if (process.env.ZIGBASE_TEST_BINARY) {
    built = true;
    return;
  }
  // The binary MUST be built with zig 0.16.0; plain `zig` on PATH may be older.
  const r = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], {
    cwd: REPO_ROOT,
    stdio: "inherit",
  });
  if (r.status !== 0) throw new Error("zig build failed");
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

export async function startServer(): Promise<TestServer> {
  ensureBuilt();
  const dataDir = mkdtempSync(join(tmpdir(), "zb-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const email = "admin@test.local";
  const password = "test-password-123";

  const su = spawnSync(
    BIN,
    ["superuser", "create", "--email", email, "--password", password, "--data-dir", dataDir],
    { stdio: "inherit" },
  );
  if (su.status !== 0) throw new Error("superuser create failed");

  const proc: ChildProcess = spawn(
    BIN,
    ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"],
    { stdio: "inherit" },
  );

  const url = `http://127.0.0.1:${port}`;
  await waitForHealth(url);

  return {
    url,
    superuser: { email, password },
    stop() {
      proc.kill("SIGTERM");
      try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
    },
  };
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
