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
 * Shrinks the collision window; the retry loop in startGolfsim() is the real guard.
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

/**
 * Options for {@link startGolfsim}.
 *
 * `env` injects extra environment variables into the spawned server process — used by the
 * determinism e2e to freeze time (`ZIGBASE_FAKE_NOW`) and point the booking webhook at a
 * loopback capture server (`GOLFSIM_BOOKING_WEBHOOK_URL`). The determinism seam is compiled
 * in only on a dev-clock build (the default Debug build used here).
 */
export interface StartOptions {
  env?: Record<string, string>;
}

export async function startGolfsim(opts: StartOptions = {}): Promise<GolfServer> {
  // A prebuilt binary supplied via ZIGBASE_TEST_GOLFSIM_BINARY skips the zig build
  // entirely — no Zig toolchain needed in that job.
  if (!process.env.ZIGBASE_TEST_GOLFSIM_BINARY) {
    const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build"], { cwd: EXAMPLE_ROOT, stdio: "inherit" });
    if (b.status !== 0) throw new Error("golfsim build failed");
  }
  // The Astro frontend is built unconditionally: the binary serves frontend/dist
  // at runtime regardless of how the binary itself was produced.
  ensureFrontend();

  // Retry on a fresh port each attempt: a port collision makes the zap listener fail
  // to bind, so the server exits early. Detect that exit fast and retry.
  let lastErr: unknown;
  for (let attempt = 1; attempt <= START_ATTEMPTS; attempt++) {
    const dataDir = mkdtempSync(join(tmpdir(), "golf-it-"));
    const su = spawnSync(BIN, ["superuser", "create", "--email", "admin@golf.local", "--password", "test-password-123", "--data-dir", dataDir], { stdio: "inherit" });
    if (su.status !== 0) { try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ } throw new Error("superuser create failed"); }
    const port = await freePort();
    // cwd MUST be EXAMPLE_ROOT: the comptime `.static_files = .{ .dir = "frontend/dist" }`
    // is resolved relative to the server's working directory.
    // stderr is piped so captureVerificationToken() can read LogMailer output;
    // stdout (facil.io startup banner) is inherited for visibility.
    const proc: ChildProcess = spawn(BIN, ["serve", "--http-port", String(port), "--data-dir", dataDir, "--insecure-cookies"], {
      cwd: EXAMPLE_ROOT,
      stdio: ["inherit", "inherit", "pipe"],
      env: { ...process.env, ...(opts.env ?? {}) },
    });
    const url = `http://127.0.0.1:${port}`;

    // Accumulate all server stderr text for token extraction; mirror to process stderr.
    let stderrText = "";
    proc.stderr!.on("data", (chunk: Buffer) => {
      const text = chunk.toString();
      process.stderr.write(text);
      stderrText += text;
    });

    try {
      await waitForHealthOrExit(url, proc, "golfsim");
    } catch (err) {
      lastErr = err;
      proc.kill("SIGKILL");
      try { rmSync(dataDir, { recursive: true, force: true }); } catch { /* ignore */ }
      continue;
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

  throw new Error(`golfsim did not start after ${START_ATTEMPTS} attempts; last error: ${String(lastErr)}`);
}
