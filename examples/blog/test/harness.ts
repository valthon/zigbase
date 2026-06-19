import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const EXAMPLE_ROOT = resolve(HERE, ".."); // examples/blog
const BIN = process.env.ZIGBASE_TEST_BLOG_BINARY || join(EXAMPLE_ROOT, "zig-out", "bin", "blog");

export interface BlogServer {
  url: string;
  superuser: { email: string; password: string };
  stop(): void;
}

async function waitForHealth(url: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { if ((await fetch(`${url}/api/health`)).ok) return; } catch { /* not up */ }
    if (Date.now() > deadline) throw new Error("blog did not become healthy");
    await new Promise((r) => setTimeout(r, 200));
  }
}

export async function startBlog(): Promise<BlogServer> {
  if (!process.env.ZIGBASE_TEST_BLOG_BINARY) {
    const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
    if (b.status !== 0) throw new Error("blog build failed");
  }
  const dataDir = mkdtempSync(join(tmpdir(), "blog-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const email = "admin@blog.local", password = "test-password-123";
  const su = spawnSync(BIN, ["superuser", "create", "--email", email, "--password", password, "--data-dir", dataDir], { stdio: "inherit" });
  if (su.status !== 0) throw new Error("superuser create failed");
  const proc: ChildProcess = spawn(BIN, ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
  const url = `http://127.0.0.1:${port}`;
  try { await waitForHealth(url); }
  catch (err) { proc.kill("SIGKILL"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } throw err; }
  return { url, superuser: { email, password }, stop() { proc.kill("SIGTERM"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } } };
}
