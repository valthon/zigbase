# SP3b — Typegen Distribution & Live Proof Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the SP3a `zigbase typegen` engine installable as `npx @zigbase/typegen` (no Zig toolchain) via esbuild-style per-platform server binaries, and prove the engine end-to-end with a live round-trip e2e.

**Architecture:** A new `dist-server` build target compiles the engine with comptime `enable_typegen = true`. CI/a bootstrap script build it for 4 targets and pack them into `@zigbase/server-<platform>` npm packages under an `optionalDependencies` meta `@zigbase/server` (a JS launcher resolves + execs the matching binary). `@zigbase/typegen` is a thin wrapper that runs `<server-bin> typegen <argv>`. A vitest integration test runs `typegen --url`/`--data-dir` against `dating-server`, asserts byte-equality with the committed golden, and exercises the generated client live.

**Tech Stack:** Zig 0.16 (`mise exec zig@0.16.0 -- zig …` ONLY), Node ≥18 (CJS launchers), npm (OIDC trusted publishing), GitHub Actions, vitest.

## Global Constraints

- **Zig 0.16 only.** Every zig command is `mise exec zig@0.16.0 -- zig …`. Plain `zig` is 0.15.2 and FAILS.
- **`zig build test` success signal:** exit 0 + no real `error:`/`panic:` lines. A trailing `failed command:` line on success is BENIGN.
- **Distributed binary = `enable_typegen = true`.** The default `zigbase` (src/main.zig) stays `enable_typegen = false`; only the new `dist-server` target flips it on.
- **Package names (exact):** `@zigbase/server`, `@zigbase/server-linux-x64`, `@zigbase/server-linux-arm64`, `@zigbase/server-darwin-x64`, `@zigbase/server-darwin-arm64`, `@zigbase/typegen`. Base SDK stays `@zigbase/client` (do NOT rename). `@zigbase/typegen` does NOT depend on the SDK.
- **Platforms (v1):** linux x64/arm64 (musl-static via `-Dtarget=x86_64-linux-musl` / `aarch64-linux-musl`), darwin x64/arm64 (`x86_64-macos` / `aarch64-macos`). Windows deferred.
- **Versioning:** `@zigbase/server*` share the version from `build.zig.zon` (currently `0.4.0`). `@zigbase/typegen` versions independently and depends on `^0.4.0` of `@zigbase/server`. Tags: `server-vX.Y.Z`, `typegen-vX.Y.Z`.
- **Publishing:** OIDC trusted publishing in CI (`id-token: write`, `npm publish --provenance`, NO `NODE_AUTH_TOKEN`). The first publish is manual via the bootstrap script (OIDC needs the package to pre-exist). Nothing publishes until a tag is pushed.
- **Package layout:** all new packages nest under `clients/typescript/npm/`. The `@zigbase/client` package at `clients/typescript/` is unchanged.
- **Binaries are NOT committed** to git — injected by CI / the bootstrap script before publish.
- **Docs sync:** any `docs/*.md` change mirrors into `site/src/content/docs/*.md`.

---

### Task 1: `dist-server` target (typegen-enabled engine binary)

A new build target producing the engine with `enable_typegen = true`, cross-compilable; plus a CI host smoke build.

**Files:**
- Create: `src/main_dist.zig`
- Modify: `build.zig` (add the `dist-server` exe + step)
- Modify: `.github/workflows/ci.yml` (build job: add a host smoke build)

**Interfaces:**
- Produces: `zig build dist-server [-Dtarget=… -Doptimize=ReleaseFast -Dcpu=baseline]` → `zig-out/bin/zigbase-dist`, a binary whose `typegen` subcommand is enabled.

- [ ] **Step 1: Create the distribution root**

`src/main_dist.zig`:
```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// The OFFICIAL distributed binary: the framework with the `typegen` subcommand
/// compiled in (comptime `enable_typegen = true`). The default `zigbase`
/// (src/main.zig) keeps it off so production server builds carry no codegen;
/// this target is what the @zigbase/server npm packages ship.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .enable_typegen = true }).runCli(init);
}
```

- [ ] **Step 2: Add the `dist-server` target to `build.zig`**

After the existing `dating-server` block (around build.zig:58), mirror the main `zigbase` exe but root at `src/main_dist.zig` and install under a distinct name so it does not collide with the default `zigbase` install. Add:

```zig
    // dist-server: the engine with `enable_typegen = true` — the binary the
    // @zigbase/server npm packages ship. Cross-compile via `-Dtarget=…`.
    const dist_mod = b.createModule(.{
        .root_source_file = b.path("src/main_dist.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dist_mod.addImport("zigbase", zigbase_mod);
    const dist_exe = b.addExecutable(.{ .name = "zigbase-dist", .root_module = dist_mod });
    const dist_step = b.step("dist-server", "Build the typegen-enabled engine binary for distribution");
    dist_step.dependOn(&b.addInstallArtifact(dist_exe, .{}).step);
```

> `zigbase_mod`, `target`, `optimize` already exist at the top of build.zig. The default `zig build` does NOT build this (it's only behind the `dist-server` step), so the regular `zigbase`/`dating-server` builds are unchanged.

- [ ] **Step 3: Verify it builds and typegen is enabled (host)**

Run: `mise exec zig@0.16.0 -- zig build dist-server -Dcpu=baseline`
Then: `./zig-out/bin/zigbase-dist typegen 2>&1 | head -5`
Expected: build exits 0; `zigbase-dist typegen` (no required args) prints the typegen usage / a "`--out` is required" error — proving the subcommand is COMPILED IN (a default-false binary would instead say "typegen: this binary was not built with .enable_typegen = true"). Confirm the latter string is ABSENT.

- [ ] **Step 4: Verify cross-compilation to all 4 targets (compile-only)**

Run each (compile check; the artifacts are what the release matrix produces):
```bash
for t in x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos; do
  mise exec zig@0.16.0 -- zig build dist-server -Dtarget=$t -Doptimize=ReleaseFast -Dcpu=baseline \
    && echo "OK $t" || echo "FAIL $t"
done
```
Expected: `OK` for all four (Zig cross-compiles the C deps — sqlite + facil.io — for each). If a darwin target fails to LINK from Linux (macOS SDK), note it: the release workflow builds darwin on a macOS runner (Task 4), so a Linux-host link failure for darwin is acceptable here as long as `x86_64-linux-musl` + `aarch64-linux-musl` succeed; record which of the four built on this host.

- [ ] **Step 5: Add a host smoke build to CI**

In `.github/workflows/ci.yml`, in the `build` job, immediately after the "Build dating-server (e2e fixture binary)" step, add:

```yaml
      - name: Build dist-server (typegen-enabled distribution binary smoke build)
        run: mise exec zig@0.16.0 -- zig build dist-server -Dcpu=baseline
```

This catches a broken `src/main_dist.zig` / `dist-server` target on every PR without running the full release matrix.

- [ ] **Step 6: Commit**

```bash
git add src/main_dist.zig build.zig .github/workflows/ci.yml
git commit -m "feat(dist): dist-server target (enable_typegen=true engine) + CI smoke build"
```

---

### Task 2: npm packages — server meta launcher, platform templates, typegen wrapper

Scaffold the six packages under `clients/typescript/npm/` and a launcher smoke test.

**Files:**
- Create: `clients/typescript/npm/server/package.json`, `clients/typescript/npm/server/bin/zigbase.js`, `clients/typescript/npm/server/index.js`, `clients/typescript/npm/server/README.md`
- Create: `clients/typescript/npm/server-{linux-x64,linux-arm64,darwin-x64,darwin-arm64}/package.json` (+ a `.gitkeep` so the dir exists)
- Create: `clients/typescript/npm/typegen/package.json`, `clients/typescript/npm/typegen/bin/typegen.js`, `clients/typescript/npm/typegen/README.md`
- Create: `clients/typescript/npm/test-launcher.mjs` (host smoke test)
- Modify: `.gitignore` (ignore injected binaries)

**Interfaces:**
- Produces: `@zigbase/server` exports `binaryPath(): string` (CJS) and a `bin` `zigbase` → `bin/zigbase.js`. `@zigbase/typegen` `bin` `zigbase-typegen`? — NO: the bin name is `typegen`? See Step 5 (npm maps `bin` keys to command names; the package is invoked as `npx @zigbase/typegen` which runs its single `bin`).

- [ ] **Step 1: Server meta — the platform resolver (`bin/zigbase.js` + `index.js`)**

`clients/typescript/npm/server/index.js` (CJS — resolves the matching platform package's binary):
```js
"use strict";
// Maps the host to its @zigbase/server-<platform> package and returns the
// absolute path to the bundled `zigbase` binary. Throws a clear error on an
// unsupported platform or a missing optionalDependency.
const SUPPORTED = {
  "linux-x64": "@zigbase/server-linux-x64",
  "linux-arm64": "@zigbase/server-linux-arm64",
  "darwin-x64": "@zigbase/server-darwin-x64",
  "darwin-arm64": "@zigbase/server-darwin-arm64",
};

function binaryPath() {
  const key = `${process.platform}-${process.arch}`;
  const pkg = SUPPORTED[key];
  if (!pkg) {
    throw new Error(
      `@zigbase/server: unsupported platform '${key}'. Supported: ${Object.keys(SUPPORTED).join(", ")}.`,
    );
  }
  try {
    return require.resolve(`${pkg}/zigbase`);
  } catch {
    throw new Error(
      `@zigbase/server: the '${pkg}' package is not installed. If you installed with ` +
        `--no-optional or --omit=optional, reinstall without it so the platform binary is fetched.`,
    );
  }
}

module.exports = { binaryPath };
```

`clients/typescript/npm/server/bin/zigbase.js` (the `bin` — forwards argv to the binary):
```js
#!/usr/bin/env node
"use strict";
const { execFileSync } = require("node:child_process");
const { binaryPath } = require("../index.js");

try {
  execFileSync(binaryPath(), process.argv.slice(2), { stdio: "inherit" });
} catch (err) {
  // Propagate the child's exit code; surface resolver errors clearly.
  if (typeof err.status === "number") process.exit(err.status);
  console.error(err.message || String(err));
  process.exit(1);
}
```

- [ ] **Step 2: Server meta `package.json`**

`clients/typescript/npm/server/package.json`:
```json
{
  "name": "@zigbase/server",
  "version": "0.4.0",
  "description": "ZigBase server — official prebuilt binary distribution (typegen-enabled).",
  "bin": { "zigbase": "bin/zigbase.js" },
  "main": "index.js",
  "files": ["bin", "index.js", "README.md"],
  "engines": { "node": ">=18" },
  "publishConfig": { "access": "public" },
  "optionalDependencies": {
    "@zigbase/server-linux-x64": "0.4.0",
    "@zigbase/server-linux-arm64": "0.4.0",
    "@zigbase/server-darwin-x64": "0.4.0",
    "@zigbase/server-darwin-arm64": "0.4.0"
  },
  "repository": { "type": "git", "url": "https://github.com/valthon/zigbase" },
  "license": "MIT"
}
```

- [ ] **Step 3: The four platform `package.json` templates**

For each `<key>`/`<os>`/`<cpu>` in {linux-x64/linux/x64, linux-arm64/linux/arm64, darwin-x64/darwin/x64, darwin-arm64/darwin/arm64}, create `clients/typescript/npm/server-<key>/package.json`:
```json
{
  "name": "@zigbase/server-<key>",
  "version": "0.4.0",
  "description": "ZigBase server prebuilt binary for <key>.",
  "os": ["<os>"],
  "cpu": ["<cpu>"],
  "files": ["zigbase", "README.md"],
  "publishConfig": { "access": "public" },
  "repository": { "type": "git", "url": "https://github.com/valthon/zigbase" },
  "license": "MIT"
}
```
(Concrete: `server-linux-x64` → `"os":["linux"],"cpu":["x64"]`; `server-linux-arm64` → `["linux"]/["arm64"]`; `server-darwin-x64` → `["darwin"]/["x64"]`; `server-darwin-arm64` → `["darwin"]/["arm64"]`.) Also add an empty `clients/typescript/npm/server-<key>/.gitkeep` so the directory is tracked (the `zigbase` binary is injected at publish, not committed).

- [ ] **Step 4: The typegen wrapper**

`clients/typescript/npm/typegen/bin/typegen.js`:
```js
#!/usr/bin/env node
"use strict";
const { execFileSync } = require("node:child_process");
const { binaryPath } = require("@zigbase/server");

try {
  execFileSync(binaryPath(), ["typegen", ...process.argv.slice(2)], { stdio: "inherit" });
} catch (err) {
  if (typeof err.status === "number") process.exit(err.status);
  console.error(err.message || String(err));
  process.exit(1);
}
```

`clients/typescript/npm/typegen/package.json`:
```json
{
  "name": "@zigbase/typegen",
  "version": "0.1.0",
  "description": "Generate a typed TypeScript client from a running ZigBase instance's schema — no Zig toolchain required.",
  "bin": { "zigbase-typegen": "bin/typegen.js" },
  "files": ["bin", "README.md"],
  "engines": { "node": ">=18" },
  "publishConfig": { "access": "public" },
  "dependencies": { "@zigbase/server": "^0.4.0" },
  "repository": { "type": "git", "url": "https://github.com/valthon/zigbase" },
  "license": "MIT"
}
```

> `npx @zigbase/typegen <args>` runs the package's single `bin`. The `bin` key name (`zigbase-typegen`) is the installed command name; `npx <pkg>` runs the package's bin regardless of key, so `npx @zigbase/typegen --data-dir … --out …` works.

- [ ] **Step 5: Host launcher smoke test (`clients/typescript/npm/test-launcher.mjs`)**

```js
// Smoke test: build dist-server for the host, place it where the host's
// @zigbase/server-<platform> package would have it, and assert the typegen
// wrapper chain (typegen.js -> @zigbase/server binaryPath -> binary typegen)
// resolves and forwards args. Run: `node clients/typescript/npm/test-launcher.mjs`
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../../..");
const key = `${process.platform}-${process.arch}`;

// 1) Build the host dist-server binary.
const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build", "dist-server", "-Dcpu=baseline"], {
  cwd: REPO_ROOT, stdio: "inherit",
});
if (b.status !== 0) throw new Error("dist-server build failed");

// 2) Place it at @zigbase/server-<key>/zigbase (where binaryPath() resolves it).
const platformPkg = join(HERE, `server-${key}`);
mkdirSync(platformPkg, { recursive: true });
copyFileSync(join(REPO_ROOT, "zig-out/bin/zigbase-dist"), join(platformPkg, "zigbase"));

// 3) node_modules wiring so require.resolve('@zigbase/server-<key>/zigbase') works:
//    create node_modules symlinks under server/ pointing at the sibling packages.
const serverNodeModules = join(HERE, "server", "node_modules", "@zigbase");
mkdirSync(serverNodeModules, { recursive: true });
const { symlinkSync, rmSync } = await import("node:fs");
for (const name of [`server-${key}`]) {
  const link = join(serverNodeModules, name);
  try { rmSync(link, { recursive: true, force: true }); } catch {}
  symlinkSync(join(HERE, name), link, "dir");
}
// And @zigbase/server resolvable from typegen.
const typegenNodeModules = join(HERE, "typegen", "node_modules", "@zigbase");
mkdirSync(typegenNodeModules, { recursive: true });
{
  const link = join(typegenNodeModules, "server");
  try { rmSync(link, { recursive: true, force: true }); } catch {}
  symlinkSync(join(HERE, "server"), link, "dir");
}

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
```

- [ ] **Step 6: gitignore injected binaries + smoke-test scratch**

Append to `.gitignore`:
```
clients/typescript/npm/server-*/zigbase
clients/typescript/npm/*/node_modules
```

- [ ] **Step 7: Run the smoke test**

Run: `node clients/typescript/npm/test-launcher.mjs`
Expected: prints `launcher smoke test OK` and exits 0. (Validates the full launcher chain on the host platform.)

- [ ] **Step 8: Commit**

```bash
git add clients/typescript/npm .gitignore
git commit -m "feat(npm): @zigbase/server (platform launcher) + @zigbase/typegen wrapper + smoke test"
```

---

### Task 3: Manual bootstrap publish script + RELEASING runbook

A Node script that assembles + publishes all six packages in dependency order, used for the first (pre-OIDC) publish and as a break-glass fallback. Reused by the CI workflow (Task 4) via `--skip-build --provenance`.

**Files:**
- Create: `clients/typescript/npm/publish.mjs`
- Create: `clients/typescript/npm/RELEASING.md`
- Test: dry-run invocation (Step 4)

**Interfaces:**
- Produces: `node clients/typescript/npm/publish.mjs [--dry-run] [--skip-build] [--provenance] [--what server|typegen|all]`. Default `--what all`. Publishes in order: 4 platform packages → `@zigbase/server` → `@zigbase/typegen`.

- [ ] **Step 1: Write the script**

`clients/typescript/npm/publish.mjs`:
```js
#!/usr/bin/env node
// Assemble + publish the @zigbase/server* and @zigbase/typegen packages.
// Manual bootstrap (with `npm login`) for the first publish; CI reuses it with
// --skip-build --provenance. Publishes in dependency order and skips versions
// already on the registry so a partial run can resume.
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../../..");
const args = new Set(process.argv.slice(2));
const DRY = args.has("--dry-run");
const SKIP_BUILD = args.has("--skip-build");
const PROVENANCE = args.has("--provenance");
const whatIdx = process.argv.indexOf("--what");
const WHAT = whatIdx >= 0 ? process.argv[whatIdx + 1] : "all";

const TARGETS = [
  { key: "linux-x64", zig: "x86_64-linux-musl" },
  { key: "linux-arm64", zig: "aarch64-linux-musl" },
  { key: "darwin-x64", zig: "x86_64-macos" },
  { key: "darwin-arm64", zig: "aarch64-macos" },
];

function pkgVersion(dir) {
  return JSON.parse(readFileSync(join(HERE, dir, "package.json"), "utf8")).version;
}
function pkgName(dir) {
  return JSON.parse(readFileSync(join(HERE, dir, "package.json"), "utf8")).name;
}
function alreadyPublished(name, version) {
  const r = spawnSync("npm", ["view", `${name}@${version}`, "version"], { encoding: "utf8" });
  return r.status === 0 && r.stdout.trim() === version;
}
function publishDir(dir) {
  const name = pkgName(dir);
  const version = pkgVersion(dir);
  if (alreadyPublished(name, version)) {
    console.log(`skip ${name}@${version} (already on registry)`);
    return;
  }
  const flags = ["publish", "--access", "public"];
  if (PROVENANCE) flags.push("--provenance");
  if (DRY) flags.push("--dry-run");
  console.log(`publish ${name}@${version} ${DRY ? "(dry-run)" : ""}`);
  execFileSync("npm", flags, { cwd: join(HERE, dir), stdio: "inherit" });
}

// 1) Build + inject platform binaries (unless --skip-build).
if (WHAT !== "typegen") {
  for (const t of TARGETS) {
    const dest = join(HERE, `server-${t.key}`, "zigbase");
    if (!SKIP_BUILD) {
      console.log(`building dist-server for ${t.zig}`);
      const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build", "dist-server",
        `-Dtarget=${t.zig}`, "-Doptimize=ReleaseFast", "-Dcpu=baseline"], { cwd: REPO_ROOT, stdio: "inherit" });
      if (b.status !== 0) throw new Error(`build failed for ${t.zig}`);
      copyFileSync(join(REPO_ROOT, "zig-out/bin/zigbase-dist"), dest);
    }
    if (!existsSync(dest)) throw new Error(`missing binary for ${t.key}: ${dest} (build it or drop it in)`);
  }
  // 2) Version consistency: all @zigbase/server* share one version.
  const v = pkgVersion("server");
  for (const t of TARGETS) {
    if (pkgVersion(`server-${t.key}`) !== v) throw new Error(`version mismatch: server-${t.key} != ${v}`);
  }
  // 3) Publish platform packages, then the meta.
  for (const t of TARGETS) publishDir(`server-${t.key}`);
  publishDir("server");
}

// 4) Publish typegen wrapper.
if (WHAT !== "server") {
  publishDir("typegen");
}
console.log("done");
```

- [ ] **Step 2: Make it executable + add a script alias**

Run: `chmod +x clients/typescript/npm/publish.mjs`
(No package.json script needed — it's invoked directly with `node`.)

- [ ] **Step 3: Write `clients/typescript/npm/RELEASING.md`**

Document: (1) the OIDC path (push a `server-vX.Y.Z` / `typegen-vX.Y.Z` tag → the workflow publishes; requires the per-package trusted publisher configured on npmjs.com, which requires the package to already exist); (2) the manual bootstrap for the FIRST publish: `npm login`, then `node clients/typescript/npm/publish.mjs --dry-run` to rehearse, then `node clients/typescript/npm/publish.mjs` to publish all six (build all four targets locally — run from macOS to cross-build darwin); (3) version bumping (bump all `@zigbase/server*` together to the `build.zig.zon` version; bump `@zigbase/typegen` independently); (4) the dependency order (platform → meta → typegen) and that the script skips already-published versions. Mirror the tone/structure of `clients/typescript/RELEASING.md`.

- [ ] **Step 4: Verify the dry-run path (no build, no publish)**

Drop placeholder binaries so `--skip-build` passes its existence check, then dry-run:
```bash
for k in linux-x64 linux-arm64 darwin-x64 darwin-arm64; do
  echo placeholder > clients/typescript/npm/server-$k/zigbase
done
node clients/typescript/npm/publish.mjs --dry-run --skip-build
rm -f clients/typescript/npm/server-*/zigbase
```
Expected: prints `publish @zigbase/server-linux-x64@0.4.0 (dry-run)` … through the meta `@zigbase/server@0.4.0` then `@zigbase/typegen@0.1.0 (dry-run)`, in that order, and `done`, exit 0. (`npm publish --dry-run` packs but does not upload; the `npm view` already-published checks may print warnings if offline — that's fine, the ordering + assembly is what this verifies.)

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/npm/publish.mjs clients/typescript/npm/RELEASING.md
git commit -m "feat(npm): bootstrap publish.mjs (dependency-ordered, dry-run) + RELEASING runbook"
```

---

### Task 4: Release workflow (OIDC, matrix build, dependency-ordered publish)

A tag-triggered workflow that builds the 4-target matrix on compatible runners and publishes via the bootstrap script with OIDC provenance.

**Files:**
- Create: `.github/workflows/release-server.yml`

**Interfaces:**
- Consumes: `zig build dist-server -Dtarget=…` (Task 1), `clients/typescript/npm/publish.mjs --skip-build --provenance` (Task 3), the package templates (Task 2).

- [ ] **Step 1: Write the workflow**

`.github/workflows/release-server.yml`:
```yaml
# Release @zigbase/server (platform matrix + meta) and @zigbase/typegen.
# DORMANT until: (a) the @zigbase npm org exists, AND (b) per-package OIDC
# "trusted publishers" are configured on npmjs.com (which requires each package
# to have been published once already — do the FIRST publish manually with
# clients/typescript/npm/publish.mjs; see clients/typescript/npm/RELEASING.md).
#
# Triggers:
#   server-vX.Y.Z  -> build the 4-target matrix, publish the 4 platform packages + @zigbase/server
#   typegen-vX.Y.Z -> publish @zigbase/typegen
name: Release Server

on:
  push:
    tags:
      - "server-v*"
      - "typegen-v*"

permissions:
  contents: read
  id-token: write # OIDC trusted publishing + provenance

jobs:
  build-binaries:
    if: startsWith(github.ref_name, 'server-v')
    strategy:
      matrix:
        include:
          - key: linux-x64
            zig: x86_64-linux-musl
            runner: ubuntu-latest
          - key: linux-arm64
            zig: aarch64-linux-musl
            runner: ubuntu-latest
          - key: darwin-x64
            zig: x86_64-macos
            runner: macos-latest
          - key: darwin-arm64
            zig: aarch64-macos
            runner: macos-latest
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v4
      - name: Build dist-server (${{ matrix.zig }})
        run: mise exec zig@0.16.0 -- zig build dist-server -Dtarget=${{ matrix.zig }} -Doptimize=ReleaseFast -Dcpu=baseline
      - name: Stage binary
        run: |
          mkdir -p staged
          cp zig-out/bin/zigbase-dist "staged/zigbase"
      - uses: actions/upload-artifact@v4
        with:
          name: zigbase-${{ matrix.key }}
          path: staged/zigbase
          if-no-files-found: error
          retention-days: 1

  publish-server:
    if: startsWith(github.ref_name, 'server-v')
    needs: build-binaries
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          registry-url: "https://registry.npmjs.org"
      - name: Assert @zigbase/server version matches the tag
        run: |
          tag="${GITHUB_REF_NAME}"; expected="${tag#server-v}"
          actual="$(node -p "require('./clients/typescript/npm/server/package.json').version")"
          echo "tag=$tag expected=$expected pkg=$actual"
          [ "$expected" = "$actual" ] || { echo "::error::tag $tag != @zigbase/server version $actual"; exit 1; }
      - name: Download platform binaries into package dirs
        run: |
          for k in linux-x64 linux-arm64 darwin-x64 darwin-arm64; do
            mkdir -p "clients/typescript/npm/server-$k"
          done
          # download-artifact below places each into its package dir
      - uses: actions/download-artifact@v4
        with: { name: zigbase-linux-x64, path: clients/typescript/npm/server-linux-x64 }
      - uses: actions/download-artifact@v4
        with: { name: zigbase-linux-arm64, path: clients/typescript/npm/server-linux-arm64 }
      - uses: actions/download-artifact@v4
        with: { name: zigbase-darwin-x64, path: clients/typescript/npm/server-darwin-x64 }
      - uses: actions/download-artifact@v4
        with: { name: zigbase-darwin-arm64, path: clients/typescript/npm/server-darwin-arm64 }
      - name: chmod binaries
        run: chmod +x clients/typescript/npm/server-*/zigbase
      - name: Publish server packages (platform → meta) with provenance
        run: node clients/typescript/npm/publish.mjs --skip-build --provenance --what server

  publish-typegen:
    if: startsWith(github.ref_name, 'typegen-v')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          registry-url: "https://registry.npmjs.org"
      - name: Assert @zigbase/typegen version matches the tag
        run: |
          tag="${GITHUB_REF_NAME}"; expected="${tag#typegen-v}"
          actual="$(node -p "require('./clients/typescript/npm/typegen/package.json').version")"
          echo "tag=$tag expected=$expected pkg=$actual"
          [ "$expected" = "$actual" ] || { echo "::error::tag $tag != @zigbase/typegen version $actual"; exit 1; }
      - name: Publish @zigbase/typegen with provenance
        run: node clients/typescript/npm/publish.mjs --skip-build --provenance --what typegen
```

> The `publish.mjs --skip-build` path requires the binaries present; the download steps place each artifact's `zigbase` into its package dir. The `--what server`/`--what typegen` split keeps the two tag triggers independent.

- [ ] **Step 2: Validate the workflow is well-formed**

Run (if `actionlint` is available): `actionlint .github/workflows/release-server.yml`. Otherwise validate YAML parses: `node -e "const y=require('fs').readFileSync('.github/workflows/release-server.yml','utf8'); require('child_process'); console.log('yaml length', y.length)"` and visually confirm: tag triggers `server-v*`/`typegen-v*`; `permissions.id-token: write`; no `NODE_AUTH_TOKEN` anywhere; publish steps call `publish.mjs --provenance`; matrix has the 4 targets on the right runners.
Expected: actionlint clean (or YAML parses) and the structural checks hold. (This workflow only runs on a pushed tag — there is no PR-time execution.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release-server.yml
git commit -m "ci(dist): release-server workflow (OIDC, 4-target matrix, ordered publish)"
```

---

### Task 5: Live round-trip e2e + harness `dataDir`

Prove introspection → generate → use against a live `dating-server`, in both `--url` and `--data-dir` modes.

**Files:**
- Modify: `clients/typescript/test/integration/harness.ts` (return `dataDir`)
- Create: `clients/typescript/test/integration/runtime-typegen.integration.test.ts`
- Modify: `.gitignore` (ignore the generated live file)

**Interfaces:**
- Consumes: `startAppServer({ bin }) -> { url, superuser, dataDir, stop }`, `DATING_BIN`, the committed golden `test/codegen/dating/zbase.runtime.gen.ts`, the `dating-server typegen` subcommand (enable_typegen=true).

- [ ] **Step 1: Add `dataDir` to the harness**

In `clients/typescript/test/integration/harness.ts`, extend the interface and the return:
```ts
export interface TestServer {
  url: string;
  superuser: { email: string; password: string };
  dataDir: string;
  stop(): void;
}
```
And in `startAppServer`'s returned object (after `superuser: { email, password },`):
```ts
    dataDir,
```
(`dataDir` is already the local variable created by `mkdtempSync` at line 77 — just expose it.)

- [ ] **Step 2: Write the failing e2e**

`clients/typescript/test/integration/runtime-typegen.integration.test.ts`:
```ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { spawnSync } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { startAppServer, DATING_BIN, type TestServer } from "./harness.js";

const HERE = resolve(fileURLToPath(new URL(".", import.meta.url)));
const GOLDEN = resolve(HERE, "../codegen/dating/zbase.runtime.gen.ts");
// Generate into a gitignored sibling of the golden so its `../../../src` imports resolve.
const LIVE_OUT = resolve(HERE, "../codegen/dating/zbase.runtime.live.gen.ts");

function runTypegen(extraArgs: string[]): void {
  const r = spawnSync(
    DATING_BIN,
    ["typegen", "--out", LIVE_OUT, "--api-prefix", "/api", ...extraArgs],
    { stdio: "inherit", env: { ...process.env, ZBASE_INREPO: "1" } },
  );
  if (r.status !== 0) throw new Error(`typegen failed: ${extraArgs.join(" ")}`);
}

let server: TestServer;
beforeAll(async () => {
  server = await startAppServer({ bin: DATING_BIN });
});
afterAll(() => {
  server?.stop();
  try { rmSync(LIVE_OUT, { force: true }); } catch { /* ignore */ }
});

describe("runtime typegen — live round-trip (dating-server)", () => {
  it("--data-dir generates a client byte-identical to the committed golden", () => {
    runTypegen(["--data-dir", server.dataDir]);
    expect(readFileSync(LIVE_OUT, "utf8")).toBe(readFileSync(GOLDEN, "utf8"));
  });

  it("--url (superuser-authed) generates a client byte-identical to the committed golden", () => {
    runTypegen([
      "--url", server.url,
      "--admin-email", server.superuser.email,
      "--admin-password", server.superuser.password,
    ]);
    expect(readFileSync(LIVE_OUT, "utf8")).toBe(readFileSync(GOLDEN, "utf8"));
  });

  it("the runtime-generated client works live: auth, CRUD, expand, realtime, int-coercion", async () => {
    runTypegen(["--data-dir", server.dataDir]);
    const mod = await import("../codegen/dating/zbase.runtime.live.gen.ts");
    const zb = mod.createClient(server.url, { WebSocket: globalThis.WebSocket });

    // auth as superuser, then create an auth-collection record.
    await zb.collection("_superusers").authWithPassword(server.superuser.email, server.superuser.password);
    const profile = await zb.db.profiles.create({
      email: "live@d.app", password: "pw-12345678", passwordConfirm: "pw-12345678",
      name: "Liv", age: 29, // age is number/.int — exercises int coercion on write
    });
    expect(profile.age).toBe(29);

    const tag = await zb.db.tags.create({ label: "trail" });
    const photo = await zb.db.photos.create({ owner: profile.id, caption: "ridge", tags: [tag.id] });

    // nested-relation filter
    const byOwner = await zb.db.photos.getList({ where: { owner: { name: { like: "Liv" } } } });
    expect(byOwner.items.length).toBeGreaterThanOrEqual(1);

    // expand
    const withTags = await zb.db.photos.getOne(photo.id, { expand: ["tags"] });
    expect(withTags.expand?.tags?.[0]?.label).toBe("trail");

    // realtime round-trip
    const events: unknown[] = [];
    const off = await zb.realtime.photos.subscribe((e: unknown) => { events.push(e); });
    await zb.db.photos.update(photo.id, { caption: "ridge-2" });
    await new Promise((r) => setTimeout(r, 500));
    off();
    expect(events.length).toBeGreaterThanOrEqual(1);
  });
});
```

> Verify the exact generated API surface against the committed golden before finalizing the assertions: confirm `createClient(url, { WebSocket })`, `zb.db.<collection>.{create,getList,getOne,update}`, `zb.realtime.<collection>.subscribe`, the `expand` option, and the auth field names (`email/password/passwordConfirm`, `name`, `age`) by reading `clients/typescript/test/codegen/dating/zbase.runtime.gen.ts` and the existing `dating.integration.test.ts`. Adjust field/method names to match the golden exactly — do NOT invent surface.

- [ ] **Step 3: gitignore the generated live file**

Append to `.gitignore`:
```
clients/typescript/test/codegen/dating/zbase.runtime.live.gen.ts
```

- [ ] **Step 4: Run the e2e**

Run: `cd clients/typescript && mise exec node@24 -- npm run test:integration -- runtime-typegen`
Expected: the 3 tests pass — both modes byte-match the golden, and the generated client drives auth/CRUD/expand/realtime/int-coercion against the live server. (First run builds dating-server via `ensureBuilt()` if no prebuilt binary.)

- [ ] **Step 5: Commit**

```bash
git add clients/typescript/test/integration/harness.ts clients/typescript/test/integration/runtime-typegen.integration.test.ts .gitignore
git commit -m "test(typegen): live round-trip e2e (url+data-dir => golden => exercise client) + harness dataDir"
```

---

### Task 6: Docs

Published READMEs for the two consumer packages + a pointer in the SDK docs.

**Files:**
- Create: `clients/typescript/npm/typegen/README.md`, `clients/typescript/npm/server/README.md`, and a `README.md` per platform package (one line each)
- Modify: `docs/typescript-sdk.md` + `site/src/content/docs/typescript-sdk.md`

- [ ] **Step 1: `@zigbase/typegen` README** (`clients/typescript/npm/typegen/README.md`)

Cover: one-line what-it-is; `npx @zigbase/typegen --data-dir ./zb_data --out src/zbase.gen.ts` and the `--url <origin> --admin-email --admin-password` form (superuser auth); the flags (`--out` required, `--api-prefix` `/api`, `--client-name` `ZbClient`, `--check`); that it emits the db/realtime/files surface and **not** `rpc.*`; that the generated file imports `@zigbase/client` + `@zigbase/client/typed`, which you install separately; that no Zig toolchain is needed (it bundles the engine via `@zigbase/server`).

- [ ] **Step 2: `@zigbase/server` README** (`clients/typescript/npm/server/README.md`)

Cover: the official prebuilt ZigBase server binary (typegen-enabled); `npx @zigbase/server serve --http-port 8090 --data-dir ./zb_data`; the supported platform matrix (linux x64/arm64, macОS x64/arm64; Windows not yet); that it's distributed esbuild-style (optional per-platform packages); a note that `@zigbase/typegen` builds on it.

- [ ] **Step 3: One-line platform READMEs**

Each `clients/typescript/npm/server-<key>/README.md`: a single line, e.g. `ZigBase server prebuilt binary for <key>. Installed automatically by @zigbase/server; do not depend on this directly.`

- [ ] **Step 4: SDK docs pointer (mirrored)**

In `docs/typescript-sdk.md`, in the existing "Runtime introspection (`zigbase typegen`)" section, add a short paragraph: the generator is installable with no Zig toolchain via `npx @zigbase/typegen --data-dir … --out …` (or `--url …`), which bundles the engine through `@zigbase/server`. Mirror the exact same paragraph into `site/src/content/docs/typescript-sdk.md` (preserving that file's front-matter/link conventions).

- [ ] **Step 5: Verify mirror parity**

Run: `diff docs/typescript-sdk.md site/src/content/docs/typescript-sdk.md`
Expected: only pre-existing front-matter/link-convention differences; your added paragraph matches in both.

- [ ] **Step 6: Commit**

```bash
git add clients/typescript/npm/*/README.md docs/typescript-sdk.md site/src/content/docs/typescript-sdk.md
git commit -m "docs(npm): @zigbase/server + @zigbase/typegen READMEs + SDK npx pointer"
```

---

## Self-Review

**Spec coverage:**
- (a) dist binary + build target + CI smoke → Task 1. ✓
- (b) npm packages (server meta launcher + binaryPath, 4 platform templates, typegen wrapper) + wrapper smoke test → Task 2. ✓
- (c) release-server.yml (OIDC, matrix, ordered publish, version assertion) → Task 4 (reuses Task 3's script). ✓
- (d) publish.mjs bootstrap (--dry-run/--skip-build/--provenance, version-check, ordered, skip-published) + RELEASING.md → Task 3. ✓
- (e) live round-trip e2e (url+data-dir → byte-equal golden → exercise) + harness dataDir → Task 5. ✓
- (f) docs (two READMEs + SDK pointer, mirrored) → Task 6. ✓
- Versioning (server* = 0.4.0, typegen independent ^0.4.0), Windows deferred, no SDK rename, binaries not committed → Global Constraints + Tasks 2/3/4. ✓

**Placeholder scan:** No TBD/TODO. Two explicit verification points (not placeholders): Task 1 Step 4 records which targets cross-link on the host (darwin-from-linux may need the macOS runner — handled in Task 4); Task 5 Step 2 directs the implementer to pin the e2e's API surface against the committed golden before finalizing (the golden is the source of truth for method/field names).

**Type/name consistency:** Package names, the `binaryPath()` export, `zigbase-dist` artifact name, the `server-<key>` dirs, the `--what server|typegen` split, `dataDir` on `TestServer`, and `ZBASE_INREPO=1` for the generated live file are used consistently across tasks. The CI smoke build (Task 1) and the release matrix (Task 4) both build `dist-server`; the publish workflow (Task 4) reuses `publish.mjs` (Task 3) so ordering/version logic lives once.

**Cross-task notes for the executor:**
- Task 5's e2e API surface MUST be reconciled against `zbase.runtime.gen.ts` (read it first); the dating fixture's collections are `profiles` (auth; fields incl. `name`, `age` number/.int, `gender` select), `tags`, `photos` (relation `owner`→profiles, `tags`→tags), etc.
- The release workflow is dormant until the `@zigbase` org + per-package OIDC trusted publishers exist; the FIRST publish is the manual `publish.mjs` run (Task 3). This is expected, not a gap.
