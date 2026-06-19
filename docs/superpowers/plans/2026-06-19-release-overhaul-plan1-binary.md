# Release Overhaul — Plan 1: One Binary, One Variant, `--version`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a single typegen-enabled `zigbase` binary built in one consistent variant (`ReleaseSafe`, stripped, `-Dcpu=baseline`), and add a framework-level `--version` that prints build provenance (version + commit + mode + target + zig).

**Architecture:** `--version`/`version` becomes a new `Command` variant parsed in `src/cli.zig` and handled in `src/framework.zig`'s `runCliImpl`, printing values injected by `build.zig` via a `build_options` module (server version from `build.zig.zon`, git short SHA captured at configure time) plus compile-time facts from `@import("builtin")`. The `main.zig`/`main_dist.zig` split is retired: `src/main.zig` becomes typegen-enabled and is the only shipped binary; the `dist-server` build step and `src/main_dist.zig` are deleted, and every consumer (`publish.mjs`, `test-launcher.mjs`, CI, `release-server.yml`) is repointed to build `zigbase` with `ReleaseSafe`.

**Tech Stack:** Zig 0.16.0 (via `mise exec zig@0.16.0`), `build.zig` options modules, Node ESM scripts, GitHub Actions YAML.

## Global Constraints

- The shipped binary is always typegen-enabled (`App(.{ .enable_typegen = true })`); `enable_typegen` stays a framework option for embedders. (spec §5)
- One build variant everywhere: **`ReleaseSafe`**, stripped (strip is already wired via `-Dstrip`, default on outside Debug), `-Dcpu=baseline`. No `ReleaseFast` anywhere. (spec §5)
- Server/project version's single source of truth is `build.zig.zon` `.version`. Nothing else hard-codes it. (spec §3)
- `--version` is REQUIRED and implemented at the framework level so examples and downstream apps inherit it. Output lines, in order: `zigbase <version>`, `commit:  <sha|unknown>`, `build:   <mode>`, `target:  <arch>-<os>-<abi>`, `zig:     <zig_version>`. Git SHA degrades to `"unknown"` outside a git checkout. (spec §5.1)
- DRY/YAGNI/TDD, frequent commits. After every task the repo must `zig build` clean and stay releasable.
- Run Zig via `mise exec zig@0.16.0 -- zig …` (never a bare `zig`).

---

## File Structure

- `src/cli.zig` — add a `version` variant to the `Command` union and parse `version` / `--version` / `-V`.
- `src/framework.zig` — handle `.version` in `runCliImpl`'s `switch`; add `printVersion()`; add a `version` line to `printUsage`; `@import("build_options")` + `@import("builtin")`.
- `build.zig` — add a `gitCommit()` helper + a `build_options` module (`version` from `@import("build.zig.zon").version`, `commit` from `gitCommit`) attached to `zigbase_mod`; in Task 2, delete the `dist-server`/`dist_mod`/`dist_exe` block and fix the stale `ReleaseFast` comment.
- `src/main.zig` — flip to `App(.{ .enable_typegen = true })` (Task 2).
- `src/main_dist.zig` — **delete** (Task 2).
- `clients/typescript/npm/publish.mjs`, `clients/typescript/npm/test-launcher.mjs`, `.github/workflows/ci.yml`, `.github/workflows/release-server.yml`, `clients/typescript/npm/RELEASING.md` — repoint `dist-server`/`ReleaseFast` → `zigbase`/`ReleaseSafe` (Task 2).

> **Note (Zig exhaustive switch):** adding the `version` variant to `Command` (Task 1) makes the `runCliImpl` `switch` non-exhaustive until its handler is added, so the parser and handler are necessarily in the **same** task. Task 1 ends green; intermediate steps may not compile (normal TDD).

---

## Task 1: `--version` with build provenance

**Files:**
- Modify: `src/cli.zig` (the `Command` union near the top; the `parse` function's leading checks; inline `test {}` blocks)
- Modify: `src/framework.zig` (`runCliImpl` switch, `printVersion`, `printUsage`, imports)
- Modify: `build.zig` (`gitCommit` helper, `build_options` module attached to `zigbase_mod`)

**Interfaces:**
- Consumes: nothing.
- Produces: `Command` gains `version: void`; `parse(...)` returns `.{ .version = {} }` for a leading `version`/`--version`/`-V`; running the binary with any of those prints the 5 provenance lines. `@import("build_options")` exposes `version: []const u8` and `commit: []const u8` (consumed by Task 2's verification too).

- [ ] **Step 1: Write the failing parser test**

Add at the end of `src/cli.zig`, alongside the existing `test "…"` blocks:

```zig
test "version / --version / -V -> version command" {
    try std.testing.expectEqual(std.meta.activeTag(try parse(&.{"version"}, .{})), .version);
    try std.testing.expectEqual(std.meta.activeTag(try parse(&.{"--version"}, .{})), .version);
    try std.testing.expectEqual(std.meta.activeTag(try parse(&.{"-V"}, .{})), .version);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | tail -20`
Expected: FAIL — compile error that `version` is not a member of `Command`.

- [ ] **Step 3: Add the `version` variant and parse it**

In `src/cli.zig`, the union currently begins:

```zig
pub const Command = union(enum) {
    /// `help`/`--help`/`-h`/no-args -> top-level usage; `<cmd> --help` -> that command's usage.
    help: HelpTopic,
```

Add a `version` variant immediately after `help`:

```zig
    /// `version`/`--version`/`-V` -> print build provenance and exit.
    version: void,
```

In `parse`, after the existing help-top check:

```zig
    if (std.mem.eql(u8, args[0], "help") or isHelpFlag(args[0]))
        return .{ .help = .top };
```

add:

```zig
    if (std.mem.eql(u8, args[0], "version") or
        std.mem.eql(u8, args[0], "--version") or
        std.mem.eql(u8, args[0], "-V"))
        return .{ .version = {} };
```

- [ ] **Step 4: Add the `gitCommit` helper to `build.zig`**

At the END of `build.zig` (file scope, after the `build` function's closing brace):

```zig
/// Capture the short git commit at configure time; "unknown" outside a repo.
fn gitCommit(b: *std.Build) []const u8 {
    const root = b.build_root.path orelse ".";
    const res = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "-C", root, "rev-parse", "--short", "HEAD" },
    }) catch return "unknown";
    if (res.term != .Exited or res.term.Exited != 0) return "unknown";
    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    return if (trimmed.len == 0) "unknown" else trimmed;
}
```

- [ ] **Step 5: Create `build_options` and attach to `zigbase_mod`**

In `build.zig`, the library module is created near the top:

```zig
    const zigbase_mod = b.addModule("zigbase", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
```

Immediately AFTER that statement (before the `addIncludePath`/`addCSourceFile` lines), add:

```zig
    // Build provenance for `zigbase --version`. The server version is single-sourced
    // from build.zig.zon; the commit is captured at configure time.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    build_options.addOption([]const u8, "commit", gitCommit(b));
    zigbase_mod.addOptions("build_options", build_options);
```

- [ ] **Step 6: Add `printVersion()` + handle `.version` in `src/framework.zig`**

At the top of `src/framework.zig`, ensure these imports exist (add any missing — check what's already imported):

```zig
const builtin = @import("builtin");
const build_options = @import("build_options");
```

Add `printVersion` next to the other `printUsage`/`printServeUsage` helpers:

```zig
/// Print build provenance (for `--version`). std.debug.print keeps it prefix-free.
fn printVersion() void {
    std.debug.print(
        \\zigbase {s}
        \\commit:  {s}
        \\build:   {s}
        \\target:  {s}-{s}-{s}
        \\zig:     {s}
        \\
    , .{
        build_options.version,
        build_options.commit,
        @tagName(builtin.mode),
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
        builtin.zig_version_string,
    });
}
```

In `runCliImpl`, the dispatch switch begins with `.help => |topic| switch (topic) { … }`. Add a `.version` prong right after that block:

```zig
        .version => printVersion(),
```

- [ ] **Step 7: Add `version` to the top-level usage text**

In `printUsage`, the COMMANDS block has a `help` line:

```zig
        \\  help                Show this help. Also: --help, -h, or no arguments.
```

Add a `version` line after it:

```zig
        \\  version             Print version + build provenance. Also: --version, -V.
```

- [ ] **Step 8: Run unit tests (parser test now passes, switch is exhaustive)**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 9: Build and verify `--version` output**

Run:
```bash
mise exec zig@0.16.0 -- zig build -Dcpu=baseline
ZONVER=$(grep -oE '\.version = "[^"]+"' build.zig.zon | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
zig-out/bin/zigbase --version
zig-out/bin/zigbase --version 2>&1 | grep -qE "^zigbase ${ZONVER}$" && echo "VERSION LINE OK"
zig-out/bin/zigbase --version 2>&1 | grep -qE "^commit:  " && echo "COMMIT LINE OK"
zig-out/bin/zigbase --version 2>&1 | grep -qE "^build:   Debug$" && echo "BUILD LINE OK"
zig-out/bin/zigbase version 2>&1 | grep -qE "^zigbase ${ZONVER}$" && echo "SUBCOMMAND OK"
```
Expected: all four `… OK` lines print. (Default `zig build` is `Debug`, so the build line reads `Debug` here; release builds will read `ReleaseSafe`.)

- [ ] **Step 10: Commit**

```bash
git add src/cli.zig src/framework.zig build.zig
git commit -m "feat(cli): --version prints build provenance (version, commit, mode, target, zig)"
```

---

## Task 2: One typegen-enabled binary, converge on `ReleaseSafe`

**Files:**
- Modify: `src/main.zig` (enable typegen)
- Delete: `src/main_dist.zig`
- Modify: `build.zig` (delete the `dist-server` block + stale comment)
- Modify: `clients/typescript/npm/publish.mjs`, `clients/typescript/npm/test-launcher.mjs`, `.github/workflows/ci.yml`, `.github/workflows/release-server.yml`, `clients/typescript/npm/RELEASING.md`

**Interfaces:**
- Consumes: `--version` from Task 1 (the unified binary must still report it).
- Produces: the only shipped binary is `zig-out/bin/zigbase` (typegen-enabled). The `dist-server` step and `zigbase-dist` artifact no longer exist. All consumers build `zig build … -Doptimize=ReleaseSafe -Dcpu=baseline` and read `zig-out/bin/zigbase`.

- [ ] **Step 1: Capture the baseline (current default binary lacks typegen)**

Run: `mise exec zig@0.16.0 -- zig build -Dcpu=baseline && zig-out/bin/zigbase typegen 2>&1 | head -2`
Expected NOW (before the change): `typegen: this binary was not built with .enable_typegen = true`. This is the behavior Task 2 changes.

- [ ] **Step 2: Enable typegen in the shipped binary**

Replace the body of `src/main.zig`:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// The shipped binary: the framework with the `typegen` subcommand compiled in.
/// One binary serves both the GitHub release tarballs and the @zigbase/server
/// npm packages. `enable_typegen` stays a framework option for embedders who
/// want it off.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .enable_typegen = true }).runCli(init);
}
```

- [ ] **Step 3: Delete `main_dist.zig` and the `dist-server` build step**

```bash
git rm src/main_dist.zig
```

In `build.zig`, delete the entire `dist-server` block:

```zig
    // dist-server: the engine with `enable_typegen = true` — the binary the
    // @zigbase/server npm packages ship. Cross-compile via `-Dtarget=…`.
    const dist_mod = b.createModule(.{
        .root_source_file = b.path("src/main_dist.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });
    dist_mod.addImport("zigbase", zigbase_mod);
    const dist_exe = b.addExecutable(.{ .name = "zigbase-dist", .root_module = dist_mod });
    const dist_step = b.step("dist-server", "Build the typegen-enabled engine binary for distribution");
    dist_step.dependOn(&b.addInstallArtifact(dist_exe, .{}).step);
```

Also fix the stale strip-rationale comment near the top of `build.zig`: change the phrase `An unstripped ReleaseFast build is ~24 MiB` to `An unstripped release build is ~24 MiB`.

- [ ] **Step 4: Verify the unified binary builds and carries typegen + `--version`**

Run:
```bash
mise exec zig@0.16.0 -- zig build -Dcpu=baseline
zig-out/bin/zigbase typegen 2>&1 | grep -qE "typegen: --out <path> is required" && echo "TYPEGEN ENABLED OK"
zig-out/bin/zigbase --version 2>&1 | grep -qE "^zigbase " && echo "VERSION OK"
mise exec zig@0.16.0 -- zig build dist-server 2>&1 | grep -qiE "no step named 'dist-server'|expected" && echo "DIST-SERVER REMOVED OK"
```
Expected: `TYPEGEN ENABLED OK`, `VERSION OK`, `DIST-SERVER REMOVED OK`.

- [ ] **Step 5: Repoint `publish.mjs` to build `zigbase` with `ReleaseSafe`**

In `clients/typescript/npm/publish.mjs`, the build/inject block currently reads:

```js
    if (!SKIP_BUILD) {
      console.log(`building dist-server for ${t.zig}`);
      const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build", "dist-server",
        `-Dtarget=${t.zig}`, "-Doptimize=ReleaseFast", "-Dcpu=baseline"], { cwd: REPO_ROOT, stdio: "inherit" });
      if (b.status !== 0) throw new Error(`build failed for ${t.zig}`);
      copyFileSync(join(REPO_ROOT, "zig-out/bin/zigbase-dist"), dest);
    }
```

Replace with:

```js
    if (!SKIP_BUILD) {
      console.log(`building zigbase for ${t.zig}`);
      const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build",
        `-Dtarget=${t.zig}`, "-Doptimize=ReleaseSafe", "-Dcpu=baseline"], { cwd: REPO_ROOT, stdio: "inherit" });
      if (b.status !== 0) throw new Error(`build failed for ${t.zig}`);
      copyFileSync(join(REPO_ROOT, "zig-out/bin/zigbase"), dest);
    }
```

- [ ] **Step 6: Repoint `test-launcher.mjs`**

In `clients/typescript/npm/test-launcher.mjs`, change the host build invocation:

```js
const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build", "dist-server", "-Dcpu=baseline"], {
```
to:
```js
const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build", "-Dcpu=baseline"], {
```
Then update the remaining `dist-server`/`zigbase-dist` mentions in that file: the comment `Build the host dist-server binary` → `Build the host zigbase binary`, the error string `"dist-server build failed"` → `"zigbase build failed"`, and any `zig-out/bin/zigbase-dist` path → `zig-out/bin/zigbase`. (Read the file first; replace each occurrence exactly.)

- [ ] **Step 7: Repoint the two workflows**

In `.github/workflows/ci.yml`, the smoke build step:

```yaml
      - name: Build dist-server (typegen-enabled distribution binary smoke build)
        run: mise exec zig@0.16.0 -- zig build dist-server -Dcpu=baseline
```
becomes:
```yaml
      - name: Build zigbase (typegen-enabled binary smoke build)
        run: mise exec zig@0.16.0 -- zig build -Dcpu=baseline
```

In `.github/workflows/release-server.yml`, the build step:

```yaml
      - name: Build dist-server (${{ matrix.zig }})
        run: mise exec zig@0.16.0 -- zig build dist-server -Dtarget=${{ matrix.zig }} -Doptimize=ReleaseFast -Dcpu=baseline
```
becomes:
```yaml
      - name: Build zigbase (${{ matrix.zig }})
        run: mise exec zig@0.16.0 -- zig build -Dtarget=${{ matrix.zig }} -Doptimize=ReleaseSafe -Dcpu=baseline
```
And the immediately-following "Stage binary" step:

```yaml
      - name: Stage binary
        run: |
          mkdir -p staged
          cp zig-out/bin/zigbase-dist "staged/zigbase"
```
becomes (only the `cp` source path changes):

```yaml
      - name: Stage binary
        run: |
          mkdir -p staged
          cp zig-out/bin/zigbase "staged/zigbase"
```

- [ ] **Step 8: Repoint `RELEASING.md` (minimal)**

In `clients/typescript/npm/RELEASING.md`, change the bootstrap bullet:

```
   - Cross-build `zigbase-dist` for all four targets via
     `mise exec zig@0.16.0 -- zig build dist-server -Dtarget=<t> -Doptimize=ReleaseFast -Dcpu=baseline`.
```
to:
```
   - Cross-build `zigbase` for all four targets via
     `mise exec zig@0.16.0 -- zig build -Dtarget=<t> -Doptimize=ReleaseSafe -Dcpu=baseline`.
```
(Plan 3 rewrites this file fully; this keeps it accurate in the meantime.)

- [ ] **Step 9: Verify no stale references remain**

Run:
```bash
grep -rnE "dist-server|zigbase-dist|main_dist|ReleaseFast" . 2>/dev/null | grep -vE "docs/superpowers|/specs/|\.git/|zig-out/|node_modules/" || echo "NO STALE REFERENCES"
```
Expected: `NO STALE REFERENCES` (spec/plan docs under `docs/superpowers/` are allowed to mention them).

- [ ] **Step 10: Verify the launcher smoke test still works end-to-end**

Run:
```bash
node clients/typescript/npm/test-launcher.mjs && echo "LAUNCHER SMOKE OK"
```
Expected: builds `zigbase`, the launcher resolves + execs it, and the script exits 0 (`LAUNCHER SMOKE OK`).

- [ ] **Step 11: Confirm full build + tests green**

Run:
```bash
mise exec zig@0.16.0 -- zig build -Dcpu=baseline && mise exec zig@0.16.0 -- zig build test 2>&1 | tail -5 && echo "BUILD+TESTS OK"
```
Expected: `BUILD+TESTS OK`.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "refactor(dist): one typegen-enabled zigbase binary on ReleaseSafe; retire main_dist/dist-server"
```

---

## Notes for the executor

- After Plan 1, the repo builds one typegen-enabled `zigbase` on `ReleaseSafe`, every binary answers `--version`, and `server-v*` releases still publish (now from the unified binary). Plans 2–4 build on this: Plan 2 (`targets.json` + generated npm packages), Plan 3 (unified `v*` build-once pipeline + version guard), Plan 4 (site/docs auto-version).
- `release-server.yml` is intentionally only repointed here, not restructured — Plan 3 replaces it with the unified `v*` workflow.
- The optional `--version` example-binary inheritance (an example reporting the ZigBase version) is exercised naturally once Plan 2/the examples rebuild; no extra task here.
