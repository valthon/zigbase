import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const EXAMPLE_ROOT = resolve(HERE, ".."); // examples/golfsim
const BIN = join(EXAMPLE_ROOT, "zig-out", "bin", "golfsim");
const FRONTEND_ROOT = join(EXAMPLE_ROOT, "frontend");
const FRONTEND_DIST = join(FRONTEND_ROOT, "dist", "index.html");

export interface GolfServer { url: string; stop(): void; }

/**
 * golfsim bakes in `.static_files = .{ .dir = "frontend/dist" }` at comptime, so
 * the server REFUSES to boot unless that dir exists (resolved relative to its
 * working directory). Build the Astro frontend once if it's missing so the e2e is
 * self-contained.
 */
function ensureFrontend(): void {
  if (existsSync(FRONTEND_DIST)) return;
  const install = spawnSync("mise", ["exec", "node@24", "--", "npm", "install"], { cwd: FRONTEND_ROOT, stdio: "inherit" });
  if (install.status !== 0) throw new Error("frontend npm install failed");
  const build = spawnSync("mise", ["exec", "node@24", "--", "npm", "run", "build"], { cwd: FRONTEND_ROOT, stdio: "inherit" });
  if (build.status !== 0) throw new Error("frontend build failed");
}

async function waitForHealth(url: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { if ((await fetch(`${url}/api/health`)).ok) return; } catch { /* not up */ }
    if (Date.now() > deadline) throw new Error("golfsim did not become healthy");
    await new Promise((r) => setTimeout(r, 200));
  }
}

export async function startGolfsim(): Promise<GolfServer> {
  const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
  if (b.status !== 0) throw new Error("golfsim build failed");
  ensureFrontend();
  const dataDir = mkdtempSync(join(tmpdir(), "golf-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const su = spawnSync(BIN, ["superuser", "create", "--email", "admin@golf.local", "--password", "test-password-123", "--data-dir", dataDir], { stdio: "inherit" });
  if (su.status !== 0) throw new Error("superuser create failed");
  // cwd MUST be EXAMPLE_ROOT: the comptime `.static_files = .{ .dir = "frontend/dist" }`
  // is resolved relative to the server's working directory.
  const proc: ChildProcess = spawn(BIN, ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
  const url = `http://127.0.0.1:${port}`;
  try {
    await waitForHealth(url);
  } catch (err) {
    proc.kill("SIGKILL");
    try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
    throw err;
  }
  return { url, stop() { proc.kill("SIGTERM"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } } };
}
