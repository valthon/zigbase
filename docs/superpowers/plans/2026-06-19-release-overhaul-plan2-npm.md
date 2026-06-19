# Release Overhaul — Plan 2: Single `targets.json` + Generated npm Packages

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make adding a platform a one-line change by introducing a single committed `targets.json` and a generator that emits the four platform packages + the meta package (`package.json` + `README.md`) from it, deleting all committed per-target boilerplate.

**Architecture:** `clients/typescript/npm/server/targets.json` becomes the single source of truth for supported platforms (the launcher reads it at runtime; `publish.mjs` and — in Plan 3 — the build matrix read it too). A new `gen-server-packages.mjs` reads `targets.json` + the version from `build.zig.zon` and writes the five `@zigbase/server*` `package.json`s and READMEs into their dirs (gitignored, like the binaries already are). The committed `package.json`/`README.md` boilerplate is deleted; `publish.mjs`, `test-launcher.mjs`, and `release-server.yml` run the generator before they need those files.

**Tech Stack:** Node ESM (`node:fs`, `node:test`), GitHub Actions YAML. (No Zig changes.)

## Global Constraints

- Single source of truth for the platform list is `clients/typescript/npm/server/targets.json`. Adding a target = one entry there, no new committed files. (spec §6.1)
- Generated artifacts are NEVER committed: the four `server-<key>/package.json` + `README.md`, and `server/package.json` + `server/README.md`, are produced by the generator and gitignored. (spec §6.3)
- Server package version is single-sourced from `build.zig.zon` `.version`; the generator reads it from there. (spec §3, §6.2)
- All generated `@zigbase/server*` packages declare `"license": "Apache-2.0"` (the project license; PR #42 corrects the committed ones — the generator must match).
- The launcher LOGIC (`server/index.js`, `server/bin/zigbase.js`) stays committed; only the target DATA is single-sourced.
- DRY/YAGNI/TDD, frequent commits. After every task the repo builds and the launcher smoke test passes.
- Run Node via `mise exec node@24 -- node …`.

---

## File Structure

- `clients/typescript/npm/server/targets.json` — **create** (committed single source): `[{key, zig, os, cpu}]`.
- `clients/typescript/npm/gen-server-packages.mjs` — **create**: exports `genServerPackages({version, targets, npmDir})`, plus a CLI entry. Emits the five `package.json`s + READMEs.
- `clients/typescript/npm/gen-server-packages.test.mjs` — **create**: `node:test` unit test of the generator.
- `clients/typescript/npm/server/index.js` — **modify**: build `SUPPORTED` from `./targets.json` instead of a hardcoded map.
- `clients/typescript/npm/publish.mjs` — **modify**: read targets from `server/targets.json`; run the generator before the version check + publish.
- `clients/typescript/npm/test-launcher.mjs` — **modify**: run the generator before placing binaries (so the package.jsons exist for resolution).
- `.gitignore` — **modify**: ignore the generated `package.json`/`README.md` files.
- **delete**: `server/package.json`, `server/README.md`, and all four `server-<key>/{package.json,README.md,.gitkeep}`.
- `.github/workflows/release-server.yml` — **modify**: add a "Generate server packages" step after checkout (Plan 3 replaces this workflow wholesale; this keeps it working in the meantime).
- `.github/workflows/ci.yml` — **modify**: run the generator unit test.

---

## Task 1: `targets.json` + the generator (+ unit test)

**Files:**
- Create: `clients/typescript/npm/server/targets.json`
- Create: `clients/typescript/npm/gen-server-packages.mjs`
- Test: `clients/typescript/npm/gen-server-packages.test.mjs`

**Interfaces:**
- Consumes: `build.zig.zon` `.version`.
- Produces: `genServerPackages({version, targets, npmDir})` writes `server/package.json`, `server/README.md`, and `server-<key>/{package.json,README.md}` for each target, and returns the array of written file paths. CLI: `node gen-server-packages.mjs` reads `server/targets.json` + `build.zig.zon` and generates into the real dirs. Task 2 consumes both the function and the CLI.

- [ ] **Step 1: Create the single-source `targets.json`**

Create `clients/typescript/npm/server/targets.json`:

```json
[
  { "key": "linux-x64", "zig": "x86_64-linux-musl", "os": "linux", "cpu": "x64" },
  { "key": "linux-arm64", "zig": "aarch64-linux-musl", "os": "linux", "cpu": "arm64" },
  { "key": "darwin-x64", "zig": "x86_64-macos", "os": "darwin", "cpu": "x64" },
  { "key": "darwin-arm64", "zig": "aarch64-macos", "os": "darwin", "cpu": "arm64" }
]
```

- [ ] **Step 2: Write the failing generator test**

Create `clients/typescript/npm/gen-server-packages.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { genServerPackages } from "./gen-server-packages.mjs";

const TARGETS = [
  { key: "linux-x64", zig: "x86_64-linux-musl", os: "linux", cpu: "x64" },
  { key: "darwin-arm64", zig: "aarch64-macos", os: "darwin", cpu: "arm64" },
];

function generate() {
  const dir = mkdtempSync(join(tmpdir(), "genpkg-"));
  genServerPackages({ version: "9.9.9", targets: TARGETS, npmDir: dir });
  return dir;
}
const readJson = (dir, ...p) => JSON.parse(readFileSync(join(dir, ...p), "utf8"));

test("platform package.json has name, version, os, cpu, license", () => {
  const dir = generate();
  try {
    const pkg = readJson(dir, "server-linux-x64", "package.json");
    assert.equal(pkg.name, "@zigbase/server-linux-x64");
    assert.equal(pkg.version, "9.9.9");
    assert.deepEqual(pkg.os, ["linux"]);
    assert.deepEqual(pkg.cpu, ["x64"]);
    assert.equal(pkg.license, "Apache-2.0");
    assert.deepEqual(pkg.files, ["zigbase", "README.md"]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("meta package.json: version, optionalDependencies, license, files include targets.json", () => {
  const dir = generate();
  try {
    const meta = readJson(dir, "server", "package.json");
    assert.equal(meta.name, "@zigbase/server");
    assert.equal(meta.version, "9.9.9");
    assert.equal(meta.license, "Apache-2.0");
    assert.deepEqual(meta.optionalDependencies, {
      "@zigbase/server-linux-x64": "9.9.9",
      "@zigbase/server-darwin-arm64": "9.9.9",
    });
    assert.ok(meta.files.includes("targets.json"));
    assert.ok(meta.files.includes("index.js"));
    assert.ok(meta.files.includes("bin"));
    assert.equal(meta.bin.zigbase, "bin/zigbase.js");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("meta README has a row per target", () => {
  const dir = generate();
  try {
    const readme = readFileSync(join(dir, "server", "README.md"), "utf8");
    assert.match(readme, /Linux x64.*@zigbase\/server-linux-x64/);
    assert.match(readme, /macOS arm64.*@zigbase\/server-darwin-arm64/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("one entry per target -> one platform dir each, no more", () => {
  const dir = generate();
  try {
    readJson(dir, "server-linux-x64", "package.json");
    readJson(dir, "server-darwin-arm64", "package.json");
    assert.throws(() => readJson(dir, "server-darwin-x64", "package.json"));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd clients/typescript/npm && mise exec node@24 -- node --test gen-server-packages.test.mjs 2>&1 | tail -15`
Expected: FAIL — cannot import `genServerPackages` from a non-existent `gen-server-packages.mjs`.

- [ ] **Step 4: Write the generator**

Create `clients/typescript/npm/gen-server-packages.mjs`:

```js
#!/usr/bin/env node
// Generate the @zigbase/server* npm package.json + README files from the single
// source of truth (server/targets.json) and the version in build.zig.zon. The
// generated files are gitignored; only this script + targets.json are committed.
// Adding a platform = one entry in server/targets.json.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

const REPO = {
  type: "git",
  url: "git+https://github.com/valthon/zigbase.git",
};
const LICENSE = "Apache-2.0";

const OS_LABEL = { linux: "Linux", darwin: "macOS" };
function platformLabel(t) {
  return `${OS_LABEL[t.os] ?? t.os} ${t.cpu}`;
}

function writeJson(path, obj) {
  writeFileSync(path, JSON.stringify(obj, null, 2) + "\n");
}

/** Read the server version from build.zig.zon (single source of truth). */
export function versionFromBuildZon(repoRoot) {
  const zon = readFileSync(join(repoRoot, "build.zig.zon"), "utf8");
  const m = zon.match(/\.version\s*=\s*"([^"]+)"/);
  if (!m) throw new Error("gen-server-packages: could not read .version from build.zig.zon");
  return m[1];
}

/**
 * Generate the platform + meta package.json/README into `npmDir`.
 * @returns {string[]} the paths written.
 */
export function genServerPackages({ version, targets, npmDir }) {
  const written = [];

  // Platform packages.
  for (const t of targets) {
    const dir = join(npmDir, `server-${t.key}`);
    mkdirSync(dir, { recursive: true });
    const pkgPath = join(dir, "package.json");
    writeJson(pkgPath, {
      name: `@zigbase/server-${t.key}`,
      version,
      description: `ZigBase server prebuilt binary for ${t.key}.`,
      os: [t.os],
      cpu: [t.cpu],
      files: ["zigbase", "README.md"],
      publishConfig: { access: "public" },
      repository: REPO,
      license: LICENSE,
    });
    const readmePath = join(dir, "README.md");
    writeFileSync(
      readmePath,
      `ZigBase server prebuilt binary for ${t.key}. Installed automatically by @zigbase/server; do not depend on this directly.\n`,
    );
    written.push(pkgPath, readmePath);
  }

  // Meta package.
  const serverDir = join(npmDir, "server");
  mkdirSync(serverDir, { recursive: true });
  const optionalDependencies = {};
  for (const t of targets) optionalDependencies[`@zigbase/server-${t.key}`] = version;
  const metaPath = join(serverDir, "package.json");
  writeJson(metaPath, {
    name: "@zigbase/server",
    version,
    description: "ZigBase server — official prebuilt binary distribution (typegen-enabled).",
    bin: { zigbase: "bin/zigbase.js" },
    main: "index.js",
    files: ["bin", "index.js", "targets.json", "README.md"],
    engines: { node: ">=18" },
    publishConfig: { access: "public" },
    optionalDependencies,
    repository: REPO,
    license: LICENSE,
  });

  const rows = targets
    .map((t) => `| ${platformLabel(t)} | \`@zigbase/server-${t.key}\` |`)
    .join("\n");
  const metaReadmePath = join(serverDir, "README.md");
  writeFileSync(
    metaReadmePath,
    `# @zigbase/server

The official prebuilt ZigBase server binary, typegen-enabled. Ships as a meta-launcher that
resolves the correct platform-specific binary from the corresponding \`@zigbase/server-<platform>\`
optional dependency — the same distribution strategy as \`esbuild\`.

## Usage

\`\`\`sh
npx @zigbase/server serve --http-port 8090 --data-dir ./zb_data
\`\`\`

The \`zigbase\` binary is also available on PATH after \`npm install\`:

\`\`\`sh
zigbase serve --http-port 8090 --data-dir ./zb_data
zigbase --help
\`\`\`

From Node.js, resolve the binary path programmatically:

\`\`\`js
const { binaryPath } = require("@zigbase/server");
const bin = binaryPath(); // absolute path to the platform binary
\`\`\`

## Supported platforms

| Platform | Package |
| --- | --- |
${rows}

Windows support is not yet available.

The per-platform packages are installed automatically as optional dependencies — you do not need
to depend on them directly. If no platform package matches the current host, \`binaryPath()\` throws
a clear error.

## Typegen

\`@zigbase/server\` ships a typegen-enabled binary. \`@zigbase/typegen\` builds on it to provide
\`npx @zigbase/typegen\` — no Zig toolchain required.

## Requirements

- Node.js >=18
- One of the supported platforms listed above
`,
  );
  written.push(metaPath, metaReadmePath);
  return written;
}

// CLI: generate into the real npm dir using the committed targets.json + build.zig.zon.
if (import.meta.url === `file://${process.argv[1]}`) {
  const npmDir = HERE;
  const repoRoot = join(HERE, "..", "..", "..");
  const targets = JSON.parse(readFileSync(join(npmDir, "server", "targets.json"), "utf8"));
  const version = versionFromBuildZon(repoRoot);
  const written = genServerPackages({ version, targets, npmDir });
  console.log(`generated ${written.length} files for @zigbase/server* at version ${version}`);
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd clients/typescript/npm && mise exec node@24 -- node --test gen-server-packages.test.mjs 2>&1 | tail -15`
Expected: `# pass 4`, `# fail 0`.

- [ ] **Step 6: Verify version sourcing against the real `build.zig.zon` (read-only)**

Do NOT run the CLI against the real dirs here — it would overwrite the still-committed `server/package.json` and dirty the tree. Verify the version read instead (no writes):

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2/clients/typescript/npm
mise exec node@24 -- node -e "import('./gen-server-packages.mjs').then(m => console.log('version from build.zig.zon =', m.versionFromBuildZon('../../..')))"
```
Expected: prints the current `build.zig.zon` version (e.g. `version from build.zig.zon = 0.4.0`). Real-dir generation is exercised in Task 2 (where these manifests become generated + gitignored). Confirm `git status --short` shows ONLY the three new files (no modified `server/package.json`).

- [ ] **Step 7: Commit (committed = targets.json, generator, test only)**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2
git add clients/typescript/npm/server/targets.json clients/typescript/npm/gen-server-packages.mjs clients/typescript/npm/gen-server-packages.test.mjs
git commit -m "feat(npm): single targets.json + generator for @zigbase/server* packages"
```

---

## Task 2: Wire it in — read targets.json, delete boilerplate, regenerate on publish/test/CI

**Files:**
- Modify: `clients/typescript/npm/server/index.js`
- Modify: `clients/typescript/npm/publish.mjs`
- Modify: `clients/typescript/npm/test-launcher.mjs`
- Modify: `.gitignore`
- Delete: `clients/typescript/npm/server/package.json`, `clients/typescript/npm/server/README.md`, `clients/typescript/npm/server-<key>/{package.json,README.md,.gitkeep}` (all four)
- Modify: `.github/workflows/release-server.yml`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the generator + `server/targets.json` from Task 1.
- Produces: a repo where the only committed npm-server files are the launcher logic, `targets.json`, the generator, and the test; `publish.mjs`/`test-launcher.mjs`/`release-server.yml` regenerate the manifests on demand; the launcher resolves platforms from `targets.json`.

- [ ] **Step 1: Make `server/index.js` read `targets.json`**

In `clients/typescript/npm/server/index.js`, replace the hardcoded `SUPPORTED` block:

```js
const SUPPORTED = {
  "linux-x64": "@zigbase/server-linux-x64",
  "linux-arm64": "@zigbase/server-linux-arm64",
  "darwin-x64": "@zigbase/server-darwin-x64",
  "darwin-arm64": "@zigbase/server-darwin-arm64",
};
```

with one derived from the single source:

```js
const targets = require("./targets.json");
const SUPPORTED = Object.fromEntries(
  targets.map((t) => [t.key, `@zigbase/server-${t.key}`]),
);
```

(Leave the rest of `index.js` unchanged.)

- [ ] **Step 2: Read targets in `publish.mjs` and regenerate before publishing**

In `clients/typescript/npm/publish.mjs`:

a) Add the imports near the top (with the other imports):
```js
import { genServerPackages, versionFromBuildZon } from "./gen-server-packages.mjs";
```

b) Replace the hardcoded `const TARGETS = [ … ];` array with a read of the single source:
```js
const TARGETS = JSON.parse(readFileSync(join(HERE, "server", "targets.json"), "utf8"));
```
(`readFileSync` and `join` are already imported; `HERE` already exists.)

c) Generate the manifests before the build/version/publish logic. Immediately after the `TARGETS` line and the `if (WHAT !== "typegen") {` opening, BEFORE the `for (const t of TARGETS)` build loop, add:
```js
  // Regenerate the server package.json + README files from targets.json + build.zig.zon.
  genServerPackages({ version: versionFromBuildZon(REPO_ROOT), targets: TARGETS, npmDir: HERE });
```
(`REPO_ROOT` already exists in publish.mjs.)

- [ ] **Step 3: Regenerate in `test-launcher.mjs` before placing binaries**

In `clients/typescript/npm/test-launcher.mjs`, add the import near the top:
```js
import { genServerPackages, versionFromBuildZon } from "./gen-server-packages.mjs";
import { readFileSync } from "node:fs";
```
(merge `readFileSync` into the existing `node:fs` import line instead of duplicating if that's cleaner.)

Then, immediately after `const key = …;` and BEFORE step 1 (the build), add:
```js
// Generate the server package.json files so require.resolve treats the platform
// + meta dirs as packages.
const TARGETS = JSON.parse(readFileSync(join(HERE, "server", "targets.json"), "utf8"));
genServerPackages({ version: versionFromBuildZon(REPO_ROOT), targets: TARGETS, npmDir: HERE });
```

- [ ] **Step 4: gitignore the generated manifests**

In `.gitignore`, after the existing `clients/typescript/npm/server-*/zigbase` line, add:
```
clients/typescript/npm/server-*/package.json
clients/typescript/npm/server-*/README.md
clients/typescript/npm/server/package.json
clients/typescript/npm/server/README.md
```

- [ ] **Step 5: Delete the committed boilerplate**

```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2
git rm clients/typescript/npm/server/package.json clients/typescript/npm/server/README.md
git rm clients/typescript/npm/server-linux-x64/package.json clients/typescript/npm/server-linux-x64/README.md clients/typescript/npm/server-linux-x64/.gitkeep
git rm clients/typescript/npm/server-linux-arm64/package.json clients/typescript/npm/server-linux-arm64/README.md clients/typescript/npm/server-linux-arm64/.gitkeep
git rm clients/typescript/npm/server-darwin-x64/package.json clients/typescript/npm/server-darwin-x64/README.md clients/typescript/npm/server-darwin-x64/.gitkeep
git rm clients/typescript/npm/server-darwin-arm64/package.json clients/typescript/npm/server-darwin-arm64/README.md clients/typescript/npm/server-darwin-arm64/.gitkeep
```

- [ ] **Step 6: Verify the launcher smoke test passes end-to-end**

Run:
```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2
mise exec node@24 -- node clients/typescript/npm/test-launcher.mjs && echo "LAUNCHER SMOKE OK"
```
Expected: it generates the manifests, builds `zigbase`, resolves the platform binary via `targets.json`, and prints `launcher smoke test OK` then `LAUNCHER SMOKE OK`.

- [ ] **Step 7: Verify a dry-run publish still assembles all packages**

Run:
```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2
mise exec node@24 -- node clients/typescript/npm/publish.mjs --dry-run --skip-build 2>&1 | tail -20 || true
```
Expected: it generates manifests, the version-consistency check passes (all share the `build.zig.zon` version), and it prints `publish …(dry-run)` lines for the four platform packages, the meta, and typegen — then `done`. (It will `skip` any version already on the registry; that's fine. The `--skip-build` means binaries aren't required for a dry run of packaging — if the script errors on a missing binary, note it: the dry run still proves manifest generation + ordering.)

- [ ] **Step 8: Add a generate step to `release-server.yml`**

In `.github/workflows/release-server.yml`, after the `- uses: jdx/mise-action@v4` step in BOTH jobs that touch the server packages (the build/publish job), add a generate step BEFORE any step that reads `server/package.json` or runs `publish.mjs`. Concretely, find the publish job's steps (the one with the version-guard `require('./clients/typescript/npm/server/package.json').version` and the `node clients/typescript/npm/publish.mjs … --what server` step) and insert, right after its `checkout`/`mise-action` setup:

```yaml
      - name: Generate server package manifests
        run: mise exec node@24 -- node clients/typescript/npm/gen-server-packages.mjs
```

This makes the deleted-from-git `server/package.json` exist before the version guard reads it. (Plan 3 replaces this workflow; this is the minimal bridge.)

- [ ] **Step 9: Run the generator unit test in CI**

In `.github/workflows/ci.yml`, in the `ts-sdk` job (which already runs Node), add a step that runs the generator test. After the existing SDK test steps, add:

```yaml
      - name: Server package generator unit test
        run: cd clients/typescript/npm && mise exec node@24 -- node --test gen-server-packages.test.mjs
```
(If the `ts-sdk` job step names differ, place it among the other `node --test`/SDK steps in that job. Read the job first and insert consistently.)

- [ ] **Step 10: Confirm nothing stale + working tree has only intended files**

Run:
```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2
git status --short
echo "--- generated files must be untracked/ignored, not staged ---"
git check-ignore clients/typescript/npm/server/package.json clients/typescript/npm/server-linux-x64/package.json && echo "GENERATED FILES IGNORED OK"
echo "--- committed npm-server files (should be: targets.json, index.js, bin/, generator, test) ---"
git ls-files clients/typescript/npm/server clients/typescript/npm/gen-server-packages.mjs clients/typescript/npm/gen-server-packages.test.mjs
```
Expected: the four `server-<key>/` dirs have no tracked files; `server/` tracks only `index.js`, `bin/zigbase.js`, `targets.json`; generated `package.json`/`README.md` are git-ignored.

- [ ] **Step 11: Full check — generator test + launcher smoke**

Run:
```bash
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2
cd clients/typescript/npm && mise exec node@24 -- node --test gen-server-packages.test.mjs 2>&1 | grep -E "# (pass|fail)"
cd /home/valthon/nothlav/zigbase/.claude/worktrees/ts-sdk-plan2 && mise exec node@24 -- node clients/typescript/npm/test-launcher.mjs >/dev/null 2>&1 && echo "LAUNCHER SMOKE OK"
```
Expected: `# pass 4`, `# fail 0`, `LAUNCHER SMOKE OK`.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "refactor(npm): generate server package.json/README from targets.json; drop committed boilerplate"
```

---

## Notes for the executor

- After Plan 2, adding a platform is one entry in `server/targets.json`. The only committed npm-server files are the launcher (`index.js`, `bin/zigbase.js`), `targets.json`, the generator, and its test. `publish.mjs`, `test-launcher.mjs`, and `release-server.yml` regenerate the manifests on demand.
- `release-server.yml` is only minimally bridged here (a generate step); Plan 3 replaces it with the unified `v*` build-once workflow and moves the version guard onto `build.zig.zon`.
- The license is Apache-2.0 throughout (matches PR #42). If PR #42 has not merged when this runs, that's fine — Plan 2 deletes the committed manifests and the generator emits Apache-2.0 regardless.
