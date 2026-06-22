import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const EXAMPLE_ROOT = resolve(HERE, ".."); // examples/golfsim
// CI supplies a prebuilt binary via ZIGBASE_TEST_GOLFSIM_BINARY (no Zig toolchain
// in that job); otherwise use the zig-out path produced by `zig build` below.
const BIN = process.env.ZIGBASE_TEST_GOLFSIM_BINARY || join(EXAMPLE_ROOT, "zig-out", "bin", "golfsim");
const FRONTEND_ROOT = join(EXAMPLE_ROOT, "frontend");
const FRONTEND_DIST = join(FRONTEND_ROOT, "dist", "index.html");

export interface GolfServer {
  url: string;
  stop(): void;
  /**
   * Wait for the LogMailer to emit a verification token for `email` (subject
   * "Verify your email"). Returns the raw JWT string. Rejects after `timeoutMs`
   * if no matching token appears.
   *
   * Call this immediately after POST /api/collections/users/request-verification
   * so the token is captured from the server's LogMailer output (server stderr).
   * The LogMailer emits (via std.log.info):
   *   info: [mail] to=<email> subject=Verify your email body=Verify your email (users). Your verification token:\n\n<TOKEN>\n
   */
  captureVerificationToken(email: string, timeoutMs?: number): Promise<string>;
}

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
  // A prebuilt binary supplied via ZIGBASE_TEST_GOLFSIM_BINARY skips the zig build
  // entirely — no Zig toolchain needed in that job.
  if (!process.env.ZIGBASE_TEST_GOLFSIM_BINARY) {
    const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
    if (b.status !== 0) throw new Error("golfsim build failed");
  }
  // The Astro frontend is built unconditionally: the binary serves frontend/dist
  // at runtime regardless of how the binary itself was produced.
  ensureFrontend();
  const dataDir = mkdtempSync(join(tmpdir(), "golf-it-"));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const su = spawnSync(BIN, ["superuser", "create", "--email", "admin@golf.local", "--password", "test-password-123", "--data-dir", dataDir], { stdio: "inherit" });
  if (su.status !== 0) { try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } throw new Error("superuser create failed"); }
  // cwd MUST be EXAMPLE_ROOT: the comptime `.static_files = .{ .dir = "frontend/dist" }`
  // is resolved relative to the server's working directory.
  // stderr is piped so captureVerificationToken() can read LogMailer output;
  // stdout (facil.io startup banner) is inherited for visibility.
  const proc: ChildProcess = spawn(BIN, ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"], { cwd: EXAMPLE_ROOT, stdio: ["inherit", "inherit", "pipe"] });
  const url = `http://127.0.0.1:${port}`;

  // Accumulate all server stderr text for token extraction; mirror to process stderr.
  let stderrText = "";
  proc.stderr!.on("data", (chunk: Buffer) => {
    const text = chunk.toString();
    process.stderr.write(text);
    stderrText += text;
  });

  try {
    await waitForHealth(url);
  } catch (err) {
    proc.kill("SIGKILL");
    try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
    throw err;
  }

  return {
    url,
    stop() { proc.kill("SIGTERM"); try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } },
    async captureVerificationToken(email: string, timeoutMs = 5_000): Promise<string> {
      // The LogMailer emits (via std.log.info, writing to stderr):
      //   info: [mail] to=<email> subject=Verify your email body=Verify your email (users). Your verification token:\n\nTOKEN\n
      // The body newlines are literal — the log entry spans multiple lines in stderr.
      const marker = `[mail] to=${email} subject=Verify your email body=`;
      const tokenRe = /Your verification token:\s*\n+([A-Za-z0-9._\-]+)/;
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        const idx = stderrText.indexOf(marker);
        if (idx !== -1) {
          const m = stderrText.slice(idx).match(tokenRe);
          if (m) return m[1]!;
        }
        if (Date.now() > deadline) throw new Error(`No verification token logged for ${email} within ${timeoutMs}ms`);
        await new Promise((r) => setTimeout(r, 100));
      }
    },
  };
}
