import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** Number of times to retry a failed server start (fresh port each attempt). */
const START_ATTEMPTS = 5;

/**
 * Ask the OS for a free loopback TCP port (bind :0, read the assignment, release).
 * Shrinks the collision window; the retry loop in startPlugins() is the real guard.
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
 * Resolve once healthy; reject FAST if the child exits first (e.g. zap `ListenError`
 * on a port collision) so the caller can retry instead of waiting out the deadline.
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

const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const EXAMPLE_ROOT = resolve(HERE, ".."); // examples/plugins
const FRONTEND_ROOT = join(EXAMPLE_ROOT, "frontend");
const FRONTEND_DIST = join(FRONTEND_ROOT, "dist", "index.html");
const BIN = process.env.ZIGBASE_TEST_PLUGINS_BINARY || join(EXAMPLE_ROOT, "zig-out", "bin", "plugins");

export interface PluginsServer {
  url: string;
  dataDir: string;
  bin: string;
  stop(): void;
}

function ensureFrontend(): void {
  if (existsSync(FRONTEND_DIST)) return;
  const i = spawnSync("mise", ["exec", "node@24", "--", "npm", "install"], { cwd: FRONTEND_ROOT, stdio: "inherit" });
  if (i.status !== 0) throw new Error("plugins frontend npm install failed");
  const b = spawnSync("mise", ["exec", "node@24", "--", "npm", "run", "build"], { cwd: FRONTEND_ROOT, stdio: "inherit" });
  if (b.status !== 0) throw new Error("plugins frontend build failed");
}

async function waitForHealth(url: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { if ((await fetch(`${url}/api/health`)).ok) return; } catch { /* not up */ }
    if (Date.now() > deadline) throw new Error("plugins did not become healthy");
    await new Promise((r) => setTimeout(r, 200));
  }
}

export async function startPlugins(): Promise<PluginsServer> {
  if (!process.env.ZIGBASE_TEST_PLUGINS_BINARY) {
    ensureFrontend();
    const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
    if (b.status !== 0) throw new Error("plugins build failed");
  }
  // Retry on a fresh port each attempt: a port collision makes the zap listener fail
  // to bind, so the server exits early. Detect that exit fast and retry.
  let lastErr: unknown;
  for (let attempt = 1; attempt <= START_ATTEMPTS; attempt++) {
    const dataDir = mkdtempSync(join(tmpdir(), "plug-it-"));
    const su = spawnSync(BIN, ["superuser", "create", "--email", "admin@plug.local", "--password", "test-password-123", "--data-dir", dataDir], { stdio: "inherit" });
    if (su.status !== 0) { try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } throw new Error("superuser create failed"); }
    const port = await freePort();
    // authors.private_notes is an .encrypted field, so serve requires ZIGBASE_FIELD_KEY
    // (fail-closed startup otherwise). A fixed dev key is fine for the e2e fixture.
    const proc: ChildProcess = spawn(BIN, ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"], { cwd: EXAMPLE_ROOT, stdio: "inherit", env: { ...process.env, ZIGBASE_FIELD_KEY: "plugins-e2e-field-key" } });
    const url = `http://127.0.0.1:${port}`;
    try {
      await waitForHealthOrExit(url, proc, "plugins"); // health == collections provisioned into the data dir
      return { url, dataDir, bin: BIN, stop() { proc.kill("SIGTERM"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } } };
    } catch (err) {
      lastErr = err;
      proc.kill("SIGKILL");
      try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
    }
  }
  throw new Error(`plugins did not start after ${START_ATTEMPTS} attempts; last error: ${String(lastErr)}`);
}
