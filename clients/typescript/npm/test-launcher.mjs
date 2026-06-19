// Smoke test: build zigbase for the host, place it where the host's
// @zigbase/server-<platform> package would have it, and assert the typegen
// wrapper chain (typegen.js -> @zigbase/server binaryPath -> binary typegen)
// resolves and forwards args. Run: `node clients/typescript/npm/test-launcher.mjs`
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, symlinkSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../../..");
const key = `${process.platform}-${process.arch}`;

// 1) Build the host zigbase binary.
const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build", "-Dcpu=baseline"], {
  cwd: REPO_ROOT, stdio: "inherit",
});
if (b.error) throw b.error;
if (b.status !== 0) throw new Error("zigbase build failed");

// 2) Place it at @zigbase/server-<key>/zigbase (where binaryPath() resolves it).
const platformPkg = join(HERE, `server-${key}`);
mkdirSync(platformPkg, { recursive: true });
copyFileSync(join(REPO_ROOT, "zig-out/bin/zigbase"), join(platformPkg, "zigbase"));

// 3) node_modules wiring so require.resolve('@zigbase/server-<key>/zigbase') works:
//    create node_modules symlinks under server/ + typegen/ pointing at the sibling packages.
function linkPkg(modulesDir, linkName, targetDir) {
  mkdirSync(modulesDir, { recursive: true });
  const link = join(modulesDir, linkName);
  try { rmSync(link, { recursive: true, force: true }); } catch {}
  symlinkSync(targetDir, link, "dir");
}
const name = `server-${key}`;
// @zigbase/server-<key> resolvable from @zigbase/server.
linkPkg(join(HERE, "server", "node_modules", "@zigbase"), name, join(HERE, name));
// @zigbase/server resolvable from @zigbase/typegen.
linkPkg(join(HERE, "typegen", "node_modules", "@zigbase"), "server", join(HERE, "server"));

// 4) Run the wrapper with `--help`-style invocation; the engine's `typegen`
//    with no --out prints a usage/error and exits non-zero, but proves the
//    chain resolved the binary and forwarded the subcommand. We assert the
//    output mentions typegen usage and NOT the disabled-gate message.
const r = spawnSync(process.execPath, [join(HERE, "typegen", "bin", "typegen.js"), "--out", "/dev/null", "--data-dir", "/nonexistent-zb"], {
  encoding: "utf8",
});
const out = (r.stdout || "") + (r.stderr || "");
if (out.includes("was not built with .enable_typegen")) throw new Error("FAIL: binary lacks typegen");
if (!/typegen/i.test(out)) throw new Error(`FAIL: wrapper did not reach typegen; got:\n${out}`);
console.log("launcher smoke test OK");
