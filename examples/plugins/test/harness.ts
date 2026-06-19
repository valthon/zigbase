import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const EXAMPLE_ROOT = resolve(HERE, ".."); // examples/plugins
const FRONTEND_ROOT = join(EXAMPLE_ROOT, "frontend");
const FRONTEND_DIST = join(FRONTEND_ROOT, "dist");
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
  const dataDir = mkdtempSync(join(tmpdir(), "plug-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const su = spawnSync(BIN, ["superuser", "create", "--email", "admin@plug.local", "--password", "test-password-123", "--data-dir", dataDir], { stdio: "inherit" });
  if (su.status !== 0) throw new Error("superuser create failed");
  const proc: ChildProcess = spawn(BIN, ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
  const url = `http://127.0.0.1:${port}`;
  try { await waitForHealth(url); } // health == collections provisioned into the data dir
  catch (err) { proc.kill("SIGKILL"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } throw err; }
  return { url, dataDir, bin: BIN, stop() { proc.kill("SIGTERM"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } } };
}
