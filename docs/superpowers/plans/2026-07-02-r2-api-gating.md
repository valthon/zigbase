# SP3 Stream R2 — Gating, Config & API Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Land the 16 R2 retro fixes from `/home/valthon/.claude/jobs/85efdf24/tmp/theme-r-triage.md` — comptime route/job/auth-method/admin gating (the "no unconditional fn-pointer" invariant), the `-Dfts5` flag, the `{items}`/204/dash-case/pagination API-consistency sweep, the RecordEvent/RouteEvent surface cleanup, the env/config doc-parity fixes, and (last) the `.auth` config grouping.

**Architecture:** One branch, dependency-ordered commits. The urgent one-line README security-doc fix goes first. Then the gating block (demo-flag eviction → comptime `Gates` route assembly + `.admin` key → selectable auth-method builtins → gated builtin job kinds → an nm-based absent-symbols invariant harness → `-Dfts5`). Then the wire-format block (list envelopes + analytics cursor; 204 bodies + `magic-link` path) with `@zigbase/client` and the admin SPA updated in the same commit as each wire change. Then the Zig event-surface cleanup (examples updated in-task). Then docs/parity (env SSOT test, config-key table regen, gating policy prose). The `.auth` grouping (E3) is the FINAL task and carries an explicit rebase checkpoint on auth-2 landing.

**Tech Stack:** Zig 0.16 (mise-pinned), TypeScript (`@zigbase/client`, vitest + `tsc --noEmit`), Preact/htm admin SPA (`src/admin/app.js`, no build step), Python/Playwright browser suite (`tests/admin/`), Astro site mirror (`site/`).

**Decision record:** `/home/valthon/.claude/jobs/85efdf24/tmp/theme-r-triage.md` (R2 section; contested-item decisions at the bottom are FINAL). Evidence: `audit-gating-consistency.md` and `audit-api-ergonomics.md` in the same directory.

**Baseline:** `origin/main` @ `0ae3289` (all file:line refs below are against that commit). CAUTION: the long-lived checkout at `/home/valthon/nothlav/zigbase` has been observed STALE relative to `origin/main` — always `git fetch origin` and branch from `origin/main`, never from a local `main` ref.

## Global Constraints

- **Branch/worktree:** create the feature branch from `origin/main` after a fresh `git fetch origin` (e.g. `git worktree add … -b feat/r2-api-gating origin/main`). `main` is protected: PR + CI, merge with `gh pr merge --merge` (merge commits only; no squash, no auto-merge). `gh pr edit` is broken on this repo — use `gh api -X PATCH` to edit the PR.
- **Zig build/test:** `mise exec zig@0.16.0 -- zig build` and `mise exec zig@0.16.0 -- zig build test --summary all`. The authoritative signal is the `Build Summary: N/N tests passed` line — a spurious `failed command: …` line appears even on success. There is no per-test filter.
- **Stream ownership:** this stream OWNS the `src/framework.zig` config surface, `src/server.zig`'s route table, `build.zig`, and `src/main.zig`. Do NOT assume any other SP3 stream (A/C/D/E/F/R1/Docker) is merged — write every task against `origin/main` as it is today. R2 merges LAST among the SP3 streams; only Task 14 (E3) additionally waits for auth-2.
- **Changelog:** NEVER edit `CHANGELOG.md` or `site/src/content/docs/changelog.md`. Each task adds its own fragment `changelog.d/<slug>.md` (see `changelog.d/README.md`). The following changes MUST carry `### Breaking` entries: E4/N6 (list envelopes), E5 (204 bodies), E6 (`magic-link` path), E8/E9/E10 (event surface), N1 (`.jobs.pool_size`), E3 (`.auth` grouping). The job-kind gating (Task 6) is also embedder-visible → `### Breaking`.
- **SDK + admin SPA ride along:** every server wire change updates `clients/typescript/src/**` (with tests) AND `src/admin/app.js` call sites **in the same task/commit**. TS commands run from `clients/typescript/`: `mise exec node@24 -- npm test`, `mise exec node@24 -- npm run typecheck` (run `npm ci || npm install` once if `node_modules` is missing).
- **Examples ride along:** event-surface changes (Task 11) and config re-shapes (Task 14) update `examples/blog`, `examples/golfsim`, `examples/plugins` in the same task; each example must build: `cd examples/<name> && mise exec zig@0.16.0 -- zig build` (plugins needs `cd examples/plugins/frontend && mise exec node@24 -- npm ci && npm run build` first).
- **Docs mirrors:** every `docs/*.md` change is mirrored to `site/src/content/docs/*.md`; also check `README.md` and `KNOWN_LIMITATIONS.md`. Run `cd site && mise exec node@24 -- npm run build` before the final task completes. `docs/superpowers/` and `docs/dx-assessment.md` are historical — do NOT rewrite them.
- **Goldens:** VERIFIED — no task in this plan touches `src/codegen/emit.zig`, `src/codegen/gen_client.zig`, or the dating fixture schema, so the byte-exact golden (`gen-test`) must not change and no regeneration is needed. Task 9 touches only the codegen *input* side (`src/codegen/acquire_http.zig`). If `gen-test` ever fails during this work, you changed emitter behavior unintentionally — STOP and revert.
- **Browser suite:** run `mise exec python@3.13 -- python -m pytest tests/admin -q` after Tasks 2, 4, 9, 10, and once at the very end. A green `zig build test` does NOT cover the admin SPA or end-to-end auth behavior. (First run may need `mise exec python@3.13 -- python -m pip install pytest playwright aiosmtpd && mise exec python@3.13 -- python -m playwright install chromium`.)
- **Compile-error probes:** Zig has no expect-compile-error test harness. Where a task verifies a `@compileError`, create a throwaway probe file, run the build, confirm the message, then revert the probe **with Edit/rm of the probe file only** — NEVER `git checkout <file>`.
- **New `src/*.zig` files** must be added to the `test { _ = @import(...); }` block in `src/root.zig` or their tests never run. (This plan adds no new files under `src/`; `fixtures/` and `scripts/` files are outside the unit-test root.)
- Commit after each task with the message given in the task. All paths are repo-root-relative.

---

### Task 1: E11 — fix the backwards OAuth-state security default in README (FIRST, one line)

**Files:**
- Modify: `README.md` (~line 140, the `ZIGBASE_OAUTH_STATE_SERVER` row)
- Modify: any mirror of that row found by grep (check `site/src/content/docs/configuration.md` and `site/src/content/docs/api.md`)
- Create: `changelog.d/r2-oauth-state-doc.md`

**Interfaces:** none (doc-only). The code default is `true` (`src/config.zig:73`, `src/app.zig:33`; test "oauth_state_server defaults ON" at `src/config.zig:295`). `docs/api.md:777,805` already say `true` correctly — do not touch them.

- [ ] **Step 1: Find every wrong row**

Run: `grep -rn "OAUTH_STATE_SERVER" README.md docs/ site/src/content/ | grep -v changelog`
Expected: the README row reads `| \`ZIGBASE_OAUTH_STATE_SERVER\` | — | \`false\` | enable server-side OAuth \`state\` (CSRF) store; …` — that default is documented backwards. Note every file repeating the `false` default.

- [ ] **Step 2: Fix the README row (and any mirror repeating it)**

Replace the row with:

```markdown
| `ZIGBASE_OAUTH_STATE_SERVER` | — | `true` | server-side OAuth `state` (CSRF) store is **on by default**; set `false` to opt out (client-driven state only — PKCE still required) |
```

- [ ] **Step 3: Add the changelog fragment**

Create `changelog.d/r2-oauth-state-doc.md`:

```markdown
### Fixes

- README documented the `ZIGBASE_OAUTH_STATE_SERVER` default backwards (`false`); the server-side OAuth state store has defaulted **on** since it shipped. The env table now matches the code (set `=false` to opt out).
```

- [ ] **Step 4: Verify no stale `false` default remains**

Run: `grep -rn "OAUTH_STATE_SERVER" README.md docs/ site/src/content/ | grep -i "false"`
Expected: only lines describing "set `false` to opt out" — no line claiming the *default* is `false`.

- [ ] **Step 5: Commit**

```bash
git add README.md site/src/content changelog.d/r2-oauth-state-doc.md
git commit -m "docs(security): ZIGBASE_OAUTH_STATE_SERVER defaults ON — fix backwards README default (E11)"
```

---

### Task 2: R2-1 — evict the demo flags/experiments from the shipped binary into a fixture app

**Files:**
- Modify: `src/main.zig` (drop `.flags`/`.experiments`; keep `.enable_typegen = true`)
- Create: `fixtures/features/main.zig` (the demo-features consumer app)
- Modify: `build.zig` (add a `features-fixture` exe + step, next to the dating-server block at `build.zig:108-120`)
- Modify: `tests/admin/test_features.py` (+ any other admin test using the demo flags — grep) to launch the fixture binary
- Modify: `.github/workflows/ci.yml` (build + artifact + env-var wiring for the fixture binary)
- Create: `changelog.d/r2-demo-flags-eviction.md`

**Interfaces:**
- Produces: `zig build features-fixture` → `zig-out/bin/features-fixture`, a server binary declaring flags `dark_mode`, `maintenance` and experiment `onboarding_flow` (identical literals to today's `src/main.zig:11-24`). Tests resolve it via env `ZIGBASE_FEATURES_BINARY` with the same `resolve_binary` helper conftest already uses (`tests/_bin.py`).
- Consumed by: Task 7's gating check indirectly (a clean `src/main.zig` keeps the shipped binary's symbol set honest).

- [ ] **Step 1: Find every test that depends on the demo flags**

Run: `grep -rln "dark_mode\|onboarding_flow\|maintenance" tests/`
Expected: at least `tests/admin/test_features.py`; possibly `test_state.py`/`test_settings.py`. Every file found must be moved onto the fixture binary in Step 4 (module-level `binary` fixture override).

- [ ] **Step 2: Create the fixture app and clean `src/main.zig`**

Create `fixtures/features/main.zig`:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// Demo feature flags + an A/B experiment, moved OUT of the release binary
/// (they were Playwright fixtures riding in production). Built as
/// `zig build features-fixture` and driven by tests/admin/test_features.py.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .flags = .{
            .dark_mode = false,
            .maintenance = .{ .default = false, .description = "Enable maintenance mode" },
        },
        .experiments = .{
            .onboarding_flow = .{
                .variants = .{ "control", "streamlined" },
                .weights = .{ 70, 30 },
                .description = "Onboarding flow A/B test",
            },
        },
    }).runCli(init);
}
```

Rewrite `src/main.zig` to:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// The shipped binary: the framework with the `typegen` subcommand compiled in.
/// One binary serves both the GitHub release tarballs and the @zigbase/server
/// npm packages. `enable_typegen` stays a framework option for embedders who
/// want it off. Demo flags/experiments live in fixtures/features (test-only).
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .enable_typegen = true }).runCli(init);
}
```

- [ ] **Step 3: Wire the fixture into `build.zig`**

Mirror the dating-server block (`build.zig:108-120`) — add after it:

```zig
    // --- features-fixture: demo flags/experiments server for the browser suite ---
    const features_fix_mod = b.createModule(.{
        .root_source_file = b.path("fixtures/features/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    features_fix_mod.addImport("zigbase", zigbase_mod);
    const features_fix_exe = b.addExecutable(.{ .name = "features-fixture", .root_module = features_fix_mod });
    const features_fix_step = b.step("features-fixture", "Build the demo-features fixture server (browser tests)");
    features_fix_step.dependOn(&b.addInstallArtifact(features_fix_exe, .{}).step);
```

(Copy the exact module-creation keyword set from the dating-server block in the tree — it is the pattern of record.)

Run: `mise exec zig@0.16.0 -- zig build && mise exec zig@0.16.0 -- zig build features-fixture`
Expected: both succeed; `zig-out/bin/features-fixture` exists.

- [ ] **Step 4: Point the feature tests at the fixture binary**

In `tests/admin/test_features.py` (and every file found in Step 1), add a module-level fixture override ABOVE the tests (pytest: a `binary` fixture defined in the test module shadows conftest's for that module; conftest's function-scoped `server`/`page` fixtures then launch the fixture binary automatically):

```python
import pathlib, pytest
from _bin import resolve_binary

REPO = pathlib.Path(__file__).resolve().parents[2]

@pytest.fixture(scope="session")
def binary():
    # The demo flags/experiments were evicted from the release binary (R2-1);
    # these tests drive the dedicated fixture app instead.
    return resolve_binary("ZIGBASE_FEATURES_BINARY", REPO, "features-fixture")
```

Also update the module docstring ("The standalone zigbase binary declares two flags… in src/main.zig" → "The features-fixture binary (fixtures/features/main.zig) declares…").

- [ ] **Step 5: Check `tests/_bin.py` builds unknown names**

Read `tests/_bin.py`. If `resolve_binary(env, repo, name)` falls back to `zig build` of a step named after the binary, confirm the step name `features-fixture` matches; if it only resolves `zig-out/bin/<name>`, add a build invocation or document that `zig build features-fixture` must run first (and make CI do it — Step 7).

- [ ] **Step 6: Run the feature browser tests locally**

Run: `mise exec zig@0.16.0 -- zig build features-fixture && mise exec python@3.13 -- python -m pytest tests/admin/test_features.py tests/admin/test_state.py tests/admin/test_settings.py -q`
Expected: all pass. Then run the FULL suite once (`… -m pytest tests/admin -q`) — the main binary no longer declares flags, so any non-features test that incidentally assumed them must be caught here.

- [ ] **Step 7: CI wiring**

In `.github/workflows/ci.yml` build job: add `mise exec zig@0.16.0 -- zig build features-fixture` next to the dating-server build step, and include `zig-out/bin/features-fixture` in the uploaded `zigbase-binaries` artifact paths. In the browser job's "Export prebuilt binary paths" step add:

```yaml
          chmod +x artifacts/zig-out/bin/features-fixture
          echo "ZIGBASE_FEATURES_BINARY=$GITHUB_WORKSPACE/artifacts/zig-out/bin/features-fixture" >> "$GITHUB_ENV"
```

- [ ] **Step 8: Changelog fragment** — create `changelog.d/r2-demo-flags-eviction.md`:

```markdown
### Changed

- The release binary no longer ships the demo feature flags/experiment (`dark_mode`, `maintenance`, `onboarding_flow`) — they were Playwright fixtures riding in production. `GET /api/features` on a stock binary is now empty until you declare your own.

### Internal

- Browser feature tests drive a dedicated `features-fixture` binary (`fixtures/features/`).
```

- [ ] **Step 9: Full test run + commit**

Run: `mise exec zig@0.16.0 -- zig build test --summary all` — expect the `Build Summary: N/N tests passed` line.

```bash
git add -A
git commit -m "feat(gating)!: evict demo flags/experiments from the release binary into fixtures/features (R2-1)"
```

---

### Task 3: E1 + N1 — `.migrations` accepts bare tuples; delete legacy `.jobs.pool_size`

**Files:**
- Modify: `src/framework.zig` (`migrationsCoerce` at :171, `provision_migrations` at :876-883, `job_pool_size` at :530-534)
- Modify: `src/queue/config.zig` (`reserved_pool_size_key` handling at :178-260 — skip becomes a pointed `@compileError`)
- Modify: `docs/framework.md` (`jobs` table row ~:93 and the migrations wording) + `site/src/content/docs/framework.md`
- Create: `changelog.d/r2-config-trivia.md`

**Interfaces:**
- Produces: `.migrations = .{ .{ .id = "0001_x", .up = fnPtr } }` (bare tuple) now lowers to `[]const provision.Migration`; the typed-slice form `&[_]zigbase.Migration{…}` keeps working. `.jobs.pool_size` is a `@compileError` naming `.pools = .{ .jobs = N }`.

- [ ] **Step 1: Write the failing comptime test** (in `src/framework.zig`, next to the existing App comptime tests — grep `test "App` for placement):

```zig
test "E1: .migrations accepts a bare tuple (lowered like .static_routes)" {
    const M = struct {
        fn up(_: std.mem.Allocator, _: std.Io, _: *db.Db) anyerror!void {}
    };
    const A = App(.{ .migrations = .{
        .{ .id = "0001_tuple_form", .up = M.up },
    } });
    try std.testing.expectEqual(@as(usize, 1), A.provision_migrations.len);
    try std.testing.expectEqualStrings("0001_tuple_form", A.provision_migrations[0].id);

    const B = App(.{ .migrations = &[_]provision.Migration{
        .{ .id = "0001_slice_form", .up = M.up },
    } });
    try std.testing.expectEqual(@as(usize, 1), B.provision_migrations.len);
}
```

(Match `provision.Migration`'s actual field set — read its definition in `src/provision.zig` first; if `.up`'s signature differs, copy the signature the plugins example uses at `examples/plugins/src/main.zig:635`.)

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL at comptime with the "'.migrations' must be a typed slice" error.

- [ ] **Step 2: Implement the tuple lowering** — replace the body of `provision_migrations` (framework.zig:876-883):

```zig
        pub const provision_migrations: []const provision.Migration = blk: {
            if (!@hasField(@TypeOf(cfg), "migrations")) break :blk &.{};
            const raw = cfg.migrations;
            if (migrationsCoerce(@TypeOf(raw))) break :blk raw; // typed slice / array ptr
            // Bare-tuple form (E1): lower each entry to a Migration, mirroring .static_routes.
            const RT = @TypeOf(raw);
            const info = @typeInfo(RT);
            if (info != .@"struct" or !info.@"struct".is_tuple)
                @compileError("'.migrations' must be a tuple of '.{ .id = \"...\", .up = fn }' entries or a typed slice '&[_]zigbase.Migration{ ... }'; got '" ++ @typeName(RT) ++ "'");
            const n = std.meta.fields(RT).len;
            var out: [n]provision.Migration = undefined;
            for (0..n) |i| out[i] = raw[i]; // anonymous struct literal coerces per-element
            const final = out;
            break :blk &final;
        };
```

If the per-element coercion errors on anonymous literals, coerce explicitly: `out[i] = provision.Migration{ .id = raw[i].id, .up = raw[i].up };` (extend with any other `Migration` fields, e.g. `.down`, if the struct has them — copy the full field list from `src/provision.zig`).

- [ ] **Step 3: Run the test** — `mise exec zig@0.16.0 -- zig build test --summary all` → PASS.

- [ ] **Step 4: Delete the `.jobs.pool_size` fallback** — replace `job_pool_size` (framework.zig:530-534):

```zig
        /// Worker pool size for the scheduler: `.pools = .{ .jobs = N }` (default 2).
        /// The pre-0.10 `.jobs = .{ .pool_size = N }` spelling is a compile error.
        pub const job_pool_size: usize = blk: {
            if (@hasField(@TypeOf(cfg), "jobs") and @hasField(@TypeOf(cfg.jobs), "pool_size"))
                @compileError("'.jobs.pool_size' was removed; set '.pools = .{ .jobs = N }' instead");
            if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "jobs")) break :blk cfg.pools.jobs;
            break :blk 2;
        };
```

In `src/queue/config.zig`: keep `reserved_pool_size_key` REJECTED rather than skipped — in `jobsMeta`/`JobEnum`/`assertNoReservedJobKinds` (the three `continue` sites at :194, :224, :260), replace the skip with the same `@compileError` message. Update the affected doc comments (:178-184, :216-218) and fix the test at :358 ("passes for non-colliding kinds (incl. pool_size…)") to no longer feed a `pool_size` key.

- [ ] **Step 5: Compile-error probe (then revert with Edit)** — create `/tmp/probe_pool_size.zig` is NOT possible (must be in-tree to import). Instead temporarily add to `src/framework.zig` tests:

```zig
// PROBE (do not commit): uncommenting must fail with "'.jobs.pool_size' was removed"
// _ = App(.{ .jobs = .{ .pool_size = 4 } });
```

Uncomment, run `zig build test`, confirm the exact message, re-comment/remove the probe **with Edit** (never `git checkout`).

- [ ] **Step 6: Docs + mirror** — `docs/framework.md`: the `jobs` table row (~:93) drops "Scheduler `.pool_size` **and**" (it is now only the job-kind registry); the `migrations` row and §migrations prose gain "bare tuple or typed slice". Grep for `pool_size` across `docs/ site/src/content examples/` and update every mention. Apply identical edits to `site/src/content/docs/framework.md`.

- [ ] **Step 7: Changelog fragment** — `changelog.d/r2-config-trivia.md`:

```markdown
### Breaking

- Removed the legacy `.jobs = .{ .pool_size = N }` spelling; set `.pools = .{ .jobs = N }`. The old key is now a pointed compile error (N1).

### Features

- `.migrations` accepts a bare tuple (`.migrations = .{ .{ .id = "...", .up = f } }`) like every other list-shaped config key; the typed-slice form still works (E1).
```

- [ ] **Step 8: Full test + commit**

```bash
mise exec zig@0.16.0 -- zig build test --summary all
git add -A && git commit -m "feat(config)!: .migrations bare-tuple widening (E1); remove legacy .jobs.pool_size (N1)"
```

---

### Task 4: R2-2 + R2-3 — comptime `Gates` route assembly in server.zig + the `.admin = .disabled` key

**Files:**
- Modify: `src/server.zig` (:38-112 — `Gates` struct, generic `Server(comptime gates)`, comptime-assembled route table, gated admin dispatch in `onRequest` at :846-847; new route-table tests)
- Modify: `src/framework.zig` (`allowed` tuple :277 gains `"admin"`; new `enable_admin` lowering; `ServeOpts` :1108 gains `gates: server_mod.Gates = .{}`; `Opts` :983 populates it; `serveImpl` :2008 instantiates `server.Server(opts.gates)`)
- Modify: `docs/framework.md` + `site/src/content/docs/framework.md` (new `.admin` key row; a short "what an unset key excludes" paragraph — the full table rewrite is Task 13)
- Create: `changelog.d/r2-route-gating.md`

**Interfaces:**
- Produces: `server.Gates = struct { admin, analytics, senders, mail_webhook, tenancy, webauthn, magic_link, oauth2 — all bool, all default true }` and `pub fn Server(comptime gates: Gates) type` with the same `{ app, host, port }` fields + `listen()` + `pub var instance: ?*Self`. `ServeOpts.gates` is how framework threads it. Task 5 refines the three auth-method gates; Task 7 asserts the symbol-level effect.
- Consumes: `tenancy_config.enabled` (comptime, framework.zig:935-958).

Background (the invariant this implements): `builtin_routes` is a plain fn-pointer table referenced by `onRequest` for every app; taking a function's address forces full codegen, so every consumer today compiles analytics/senders/mail-webhook/tenancy/WebAuthn handlers (audit §1c Anchor 1). Making the table a comptime-assembled slice keyed on config restores Zig's lazy analysis. Runtime behavior for unconfigured subsystems is already 404/fail-closed, so dropping their routes is behaviorally near-invisible.

- [ ] **Step 1: Read the current dispatch end-to-end** — `src/server.zig:34-112` (routes + `Server` + `listen`), `:816-919` (`onRequest`), and check who references `Server` outside the file: `grep -rn "server\.Server\|Server\.instance" src/`. Expected: only `src/framework.zig:2008` constructs it; in-file tests use local route tables, not `Server`. If anything else references `Server.instance`, adapt it in Step 3.

- [ ] **Step 2: Write the failing route-table tests** (bottom of `src/server.zig`):

```zig
fn hasRoute(rs: []const router.Route, method: http.Method, pattern: []const u8) bool {
    for (rs) |r| if (r.method == method and std.mem.eql(u8, r.pattern, pattern)) return true;
    return false;
}

test "R2-3: Gates assemble the built-in route table at comptime" {
    const full = Server(.{}); // all-on default == today's table
    try std.testing.expect(hasRoute(full.routes, .GET, "/api/analytics/events"));
    try std.testing.expect(hasRoute(full.routes, .GET, "/api/senders"));
    try std.testing.expect(hasRoute(full.routes, .POST, "/api/mail/webhooks/:provider"));
    try std.testing.expect(hasRoute(full.routes, .POST, "/api/accounts/:id/activate"));
    try std.testing.expect(hasRoute(full.routes, .POST, "/api/collections/:col/auth/webauthn/register/begin"));

    const lean = Server(.{
        .admin = false, .analytics = false, .senders = false, .mail_webhook = false,
        .tenancy = false, .webauthn = false, .magic_link = false, .oauth2 = false,
    });
    // Core stays.
    try std.testing.expect(hasRoute(lean.routes, .GET, "/api/health"));
    try std.testing.expect(hasRoute(lean.routes, .POST, "/api/collections/:col/auth-with-password"));
    try std.testing.expect(hasRoute(lean.routes, .GET, "/api/settings"));
    // Optional subsystems are ABSENT (not 404-at-runtime — absent from the table).
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/analytics/events"));
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/analytics/rollups/:name"));
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/senders"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/senders/:id/verify"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/mail/webhooks/:provider"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/accounts/:id/activate"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/collections/:col/auth/webauthn/register/begin"));
    try std.testing.expect(!hasRoute(lean.routes, .POST, "/api/collections/:col/auth/webauthn/register/finish"));
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/collections/:col/auth/magic_link/consume"));
    try std.testing.expect(!hasRoute(lean.routes, .GET, "/api/collections/:col/auth/oauth2/providers"));
    try std.testing.expect(!hasRoute(lean.routes, .DELETE, "/api/collections/:col/records/:id/external-auths/:provider"));
}
```

Run: `mise exec zig@0.16.0 -- zig build test --summary all` — expect FAIL (`Server` is not a function; `routes` not a member).

- [ ] **Step 3: Restructure `src/server.zig`**

Replace the module-level `const routes = [_]router.Route{ … }` (:38-91) and `pub const Server = struct { … }` (:93-112) with:

```zig
/// Comptime gates for the built-in route table + admin SPA (R2-3/R2-2). Every
/// field default-true: `Server(.{})` is byte-equivalent to the historical table.
/// INVARIANT (gating policy): no unconditional fn-pointer registration for
/// optional capabilities — fn-pointer tables are where Zig's lazy analysis dies,
/// so every optional subsystem's routes concat in ONLY under its gate.
pub const Gates = struct {
    admin: bool = true,
    analytics: bool = true,
    senders: bool = true,
    mail_webhook: bool = true,
    tenancy: bool = true,
    webauthn: bool = true,
    magic_link: bool = true,
    oauth2: bool = true,
};

pub fn Server(comptime gates: Gates) type {
    return struct {
        const Self = @This();

        /// The comptime-assembled built-in route table for this app's gates.
        pub const routes: []const router.Route = blk: {
            var t: []const router.Route = &.{
                .{ .method = .GET, .pattern = "/api/health", .handler = healthHandler },
                // … EVERY route from today's table (:40-66, :78-86) that is NOT
                // listed in a gated group below, in the same order:
                // collections CRUD, records CRUD+abilities, auth-with-password,
                // auth-refresh, auth-logout, request/confirm-verification,
                // request/confirm-password-reset, auth/:method/initiate|complete,
                // files serve+token, /api/state, /api/settings (4 verbs), /api/features.
            };
            if (gates.magic_link) t = t ++ &[_]router.Route{
                .{ .method = .GET, .pattern = "/api/collections/:col/auth/magic_link/consume", .handler = magic_link_consume_api.consume },
            };
            if (gates.webauthn) t = t ++ &[_]router.Route{
                .{ .method = .POST, .pattern = "/api/collections/:col/auth/webauthn/register/begin", .handler = webauthn_register_api.begin },
                .{ .method = .POST, .pattern = "/api/collections/:col/auth/webauthn/register/finish", .handler = webauthn_register_api.finish },
            };
            if (gates.oauth2) t = t ++ &[_]router.Route{
                .{ .method = .GET, .pattern = "/api/collections/:col/auth/oauth2/providers", .handler = oauth_api.oauth2Providers },
                .{ .method = .DELETE, .pattern = "/api/collections/:col/records/:id/external-auths/:provider", .handler = oauth_api.unlinkProvider },
            };
            if (gates.tenancy) t = t ++ &[_]router.Route{
                .{ .method = .POST, .pattern = "/api/accounts/:id/activate", .handler = accounts_api.activate },
            };
            if (gates.senders) t = t ++ &[_]router.Route{
                .{ .method = .GET, .pattern = "/api/senders", .handler = senders_api.list },
                .{ .method = .POST, .pattern = "/api/senders", .handler = senders_api.create },
                .{ .method = .POST, .pattern = "/api/senders/:id/verify", .handler = senders_api.verify },
            };
            if (gates.mail_webhook) t = t ++ &[_]router.Route{
                .{ .method = .POST, .pattern = "/api/mail/webhooks/:provider", .handler = mail_inbound.webhook_handler },
            };
            if (gates.analytics) t = t ++ &[_]router.Route{
                .{ .method = .GET, .pattern = "/api/analytics/events", .handler = analytics_api.events },
                .{ .method = .GET, .pattern = "/api/analytics/rollups/:name", .handler = analytics_api.rollups },
            };
            break :blk t;
        };

        app: *app_mod.App,
        host: [:0]const u8,
        port: u16,

        pub var instance: ?*Self = null;

        pub fn listen(self: *Self) !void {
            instance = self;
            var listener = zap.HttpListener.init(.{ .port = self.port, .on_request = onRequest, .on_upgrade = realtime_ws.handleUpgrade, .log = false, .max_body_size = @intCast(self.app.max_upload_size) });
            try listener.listen();
            std.log.info("zigbase listening on http://{s}:{d}", .{ self.host, self.port });
            realtime_ws.active = true;
            realtime_ws.startRemoteListener(self.app);
            zap.start(.{ .threads = 4, .workers = 1 });
        }

        fn onRequest(r: zap.Request) !void {
            const self = Self.instance.?;
            // … body moved VERBATIM from the current module-level onRequest (:816-918),
            // with exactly TWO edits:
            //   1. `Server.instance.?` → `Self.instance.?` (above)
            //   2. the admin dispatch (:846-847) gains the comptime gate:
            //        if (comptime gates.admin) {
            //            if (std.mem.startsWith(u8, ctx.path, "/_/") or std.mem.eql(u8, ctx.path, "/_"))
            //                break :blk admin.serve(&ctx);
            //        }
            //      (when gates.admin is false, `admin.serve` — and the ~58 KiB of
            //      @embedFile'd SPA assets in admin.zig — is never referenced)
            //   3. `router.tryDispatch(&routes, &ctx)` → `router.tryDispatch(routes, &ctx)`
            //      (routes is already a slice)
        }
    };
}
```

Keep every helper (`methodFromZap`, `clientIpFrom`, `zapHeaderLookup`, `statusToCode`, `dispatchCustom`, `applyMultipart`, `sendRawEnvelope`, `setZapStatus`, all tests) module-level and untouched — only `routes`, the `Server` struct, and `onRequest` move inside the generic. Do NOT re-type or reorder route entries while moving them; this diff must be mechanical.

- [ ] **Step 4: Add the `.admin` key + gates lowering in `src/framework.zig`**

1. `allowed` tuple (:277): append `"admin"`.
2. Below `enable_typegen` (:542), add:

```zig
        /// R2-2: `.admin = .disabled` removes the embedded admin SPA (route dispatch
        /// AND the @embedFile'd assets) from the binary. Default: served at /_/ .
        pub const enable_admin: bool = blk: {
            if (!@hasField(@TypeOf(cfg), "admin")) break :blk true;
            const a = cfg.admin;
            if (@TypeOf(a) != @TypeOf(.enum_literal))
                @compileError(".admin: expected the enum literal .disabled (the admin UI is on by default; omit the key to keep it)");
            if (std.mem.eql(u8, @tagName(a), "disabled")) break :blk false;
            @compileError(".admin: unknown value '." ++ @tagName(a) ++ "'; only .disabled is recognized");
        };

        /// R2-3: comptime route gates derived from cfg. Auth-method gates are refined
        /// from the assembled method set in Task 5; until then they stay default-true.
        pub const route_gates: server_mod.Gates = .{
            .admin = enable_admin,
            .analytics = @hasField(@TypeOf(cfg), "analytics"),
            .senders = @hasField(@TypeOf(cfg), "mail"),
            .mail_webhook = @hasField(@TypeOf(cfg), "mail"),
            .tenancy = tenancy_config.enabled,
        };
```

(`server_mod` = the existing `@import("server.zig")` alias in framework.zig — grep for it and reuse its name.)

3. `ServeOpts` (:1108): add `gates: @import("server.zig").Gates = .{},` (use the file's import alias).
4. `Opts` (:983-1007): add `.gates = route_gates,`.
5. `serveImpl` (:2008): `var srv = server.Server(opts.gates){ .app = &app, .host = host_z, .port = cfg.http_port };` — where `server.Server(opts.gates)` needs `comptime` context; since `opts` is a comptime param this is already comptime-known. Alias it first for clarity: `const Srv = server.Server(opts.gates); var srv = Srv{ … }; … try srv.listen();`.

- [ ] **Step 5: Run tests** — `mise exec zig@0.16.0 -- zig build test --summary all` → the Step 2 test passes, everything else stays green. Then `mise exec zig@0.16.0 -- zig build` → the shipped binary builds (all gates ON for the stock `App(.{ .enable_typegen = true })`? NO — check: the stock binary has no `.analytics`/`.mail`/`.tenancy` keys, so those routes are now ABSENT from it; that is the intended behavior per the audit — they were 404/fail-closed anyway. The admin SPA and all auth methods remain).

- [ ] **Step 6: Browser suite** — `mise exec python@3.13 -- python -m pytest tests/admin -q` → all pass (admin SPA + settings/features/state routes unaffected; no admin test exercises analytics/senders/tenancy endpoints — if one does, it must move to a fixture app with those keys configured; flag it rather than silently reconfiguring the main binary).

- [ ] **Step 7: Compile-error probe for `.admin`** — temporarily add `_ = App(.{ .admin = .off });` in a test, confirm the "unknown value '.off'" message, revert with Edit.

- [ ] **Step 8: Docs** — `docs/framework.md` §3 table: add the `admin` row (`.admin = .disabled` removes the admin SPA — route + embedded assets — for headless/embedded consumers; the standalone binary keeps it). Add one paragraph after the table: "Route gating: analytics, senders/mail-webhook, and tenancy built-in endpoints exist only when their config key is set (`.analytics`, `.mail`, `.tenancy.enabled`); unset keys leave no trace in your binary." Mirror both edits to `site/src/content/docs/framework.md`. Also update `docs/api.md`'s route inventory if it states these endpoints are always present (grep `analytics/events` in docs/) — annotate "present when configured".

- [ ] **Step 9: Changelog fragment** — `changelog.d/r2-route-gating.md`:

```markdown
### Features

- New comptime `.admin = .disabled` key: headless/embedded consumers can drop the admin SPA (dispatch + ~58 KiB embedded assets) from their binary. Default unchanged — the admin UI serves at `/_/`.

### Changed

- Built-in routes are now comptime-assembled from your `App(.{…})` config: analytics, senders, the inbound mail webhook, and `accounts/:id/activate` are registered (and compiled) only when `.analytics`, `.mail`, or `.tenancy` is configured. Previously these routes always existed and answered 404/fail-closed when unconfigured; now they 404 as unknown routes. The standalone release binary is unaffected except that these unconfigured endpoints now 404 uniformly.
```

- [ ] **Step 10: Commit**

```bash
git add -A && git commit -m "feat(gating): comptime Gates route assembly + .admin = .disabled key (R2-2/R2-3)"
```

---

### Task 5: R2-4 — selectable built-in auth methods (`.auth_methods = .{ .builtins = …, .custom = … }`)

**Files:**
- Modify: `src/auth/registry.zig` (`assembleTypes` :31-43 + new tests)
- Modify: `src/framework.zig` (derive the `webauthn`/`magic_link`/`oauth2` gates in `route_gates` from the assembled method set)
- Modify: `docs/framework.md` (+ mirror) `auth_methods` row + §auth-methods prose; `docs/recipes.md` "enable magic-link + OTP via config" recipe (~:740) gains the builtins form
- Create: `changelog.d/r2-selectable-auth-methods.md`

**Interfaces:**
- Consumes: Task 4's `Gates`/`route_gates`.
- Produces: `registry.assembleTypes(cfg)` accepts three forms — absent (all 5 builtins), legacy bare tuple `.{CustomT, …}` (all 5 builtins ++ customs, unchanged), and the new `.{ .builtins = .{ .password, .otp }, .custom = .{CustomT} }` (exact set). Builtin enum literals: `.password`, `.magic_link`, `.otp`, `.webauthn`, `.oauth2`. Non-breaking: both old forms keep today's meaning. Task 7's lean fixture uses `.builtins = .{ .password }`.

- [ ] **Step 1: Write the failing tests** (in `src/auth/registry.zig`, after the existing three tests):

```zig
test "R2-4: assembleTypes .builtins selects an exact subset" {
    const types = comptime assembleTypes(.{ .auth_methods = .{ .builtins = .{ .password, .otp } } });
    try std.testing.expectEqual(@as(usize, 2), types.len);
    comptime std.debug.assert(types[0] == PasswordMethod);
    comptime std.debug.assert(types[1] == OtpMethod);
}

test "R2-4: assembleTypes .builtins + .custom composes" {
    const FakeMethod = struct {
        pub fn create(_: std.mem.Allocator, _: std.Io, _: anytype) !@This() { return .{}; }
        pub fn method(self: *@This()) AuthMethod {
            return .{ .slug = "fake", .ctx = self, .vtable = &vt };
        }
        pub fn deinit(_: *@This()) void {}
        const vt = AuthMethod.VTable{ .initiate = undefined, .complete = undefined };
    };
    const types = comptime assembleTypes(.{ .auth_methods = .{ .builtins = .{ .webauthn }, .custom = .{FakeMethod} } });
    try std.testing.expectEqual(@as(usize, 2), types.len);
    comptime std.debug.assert(types[0] == WebAuthnMethod);
    comptime std.debug.assert(types[1] == FakeMethod);
}

test "R2-4: legacy bare tuple still means all builtins ++ customs" {
    // (mirror of the existing ".auth_methods appends custom types" test — keep both green)
    const types = comptime assembleTypes(.{ .auth_methods = .{} }); // empty tuple
    try std.testing.expectEqual(@as(usize, 5), types.len);
}
```

Run: `mise exec zig@0.16.0 -- zig build test --summary all` — expect FAIL (`.builtins` treated as a method type).

- [ ] **Step 2: Implement `assembleTypes`** — replace :31-43:

```zig
/// Comptime `[]const type` of auth methods. Three accepted forms for `cfg.auth_methods`:
///   absent                        → all five built-ins (back-compat)
///   .{ CustomT, ... } (tuple)     → all five built-ins ++ customs (back-compat)
///   .{ .builtins = .{ .password, ... }, .custom = .{ CustomT, ... } }
///                                 → EXACTLY the named built-ins (in the order given)
///                                   ++ customs. Omitting .builtins keeps all five;
///                                   .builtins = .{} drops every built-in. R2-4: a
///                                   deselected built-in (e.g. .webauthn, ~3.2k LOC)
///                                   is never analyzed → absent from the binary.
pub fn assembleTypes(comptime cfg: anytype) []const type {
    const all_builtins: []const type = &.{ PasswordMethod, MagicLinkMethod, OtpMethod, WebAuthnMethod, OAuth2Method };
    if (!@hasField(@TypeOf(cfg), "auth_methods")) return all_builtins;
    const am = cfg.auth_methods;
    const AM = @TypeOf(am);
    const info = @typeInfo(AM);
    if (info != .@"struct")
        @compileError(".auth_methods must be a tuple of method types or '.{ .builtins = .{ ... }, .custom = .{ ... } }'");

    if (!info.@"struct".is_tuple) {
        // New named form.
        for (std.meta.fields(AM)) |f| {
            if (!std.mem.eql(u8, f.name, "builtins") and !std.mem.eql(u8, f.name, "custom"))
                @compileError(".auth_methods: unknown key '." ++ f.name ++ "' (recognized: .builtins, .custom)");
        }
        comptime var result: []const type = &.{};
        if (@hasField(AM, "builtins")) {
            inline for (std.meta.fields(@TypeOf(am.builtins))) |bf| {
                const lit = @field(am.builtins, bf.name);
                const name = @tagName(lit);
                const T: type = blk: {
                    if (std.mem.eql(u8, name, "password")) break :blk PasswordMethod;
                    if (std.mem.eql(u8, name, "magic_link")) break :blk MagicLinkMethod;
                    if (std.mem.eql(u8, name, "otp")) break :blk OtpMethod;
                    if (std.mem.eql(u8, name, "webauthn")) break :blk WebAuthnMethod;
                    if (std.mem.eql(u8, name, "oauth2")) break :blk OAuth2Method;
                    @compileError(".auth_methods.builtins: unknown built-in '." ++ name ++ "' (expected .password/.magic_link/.otp/.webauthn/.oauth2)");
                };
                for (result) |seen| if (seen == T) @compileError(".auth_methods.builtins: duplicate '." ++ name ++ "'");
                result = result ++ &[_]type{T};
            }
        } else {
            result = all_builtins;
        }
        if (@hasField(AM, "custom")) {
            inline for (std.meta.fields(@TypeOf(am.custom))) |f| {
                result = result ++ &[_]type{@field(am.custom, f.name)};
            }
        }
        return result;
    }

    // Legacy bare tuple: all built-ins ++ customs (unchanged).
    comptime var result: []const type = all_builtins;
    inline for (info.@"struct".fields) |f| {
        result = result ++ &[_]type{@field(am, f.name)};
    }
    return result;
}
```

- [ ] **Step 3: Run tests** → all `registry.zig` tests pass (old + new). `assertAuthMethodContract` in framework.zig:606-614 already validates every assembled type — no change needed there.

- [ ] **Step 4: Derive the method route-gates** — in `src/framework.zig`, extend `route_gates` (Task 4's decl):

```zig
        /// True iff `T` is in the assembled auth-method set.
        fn hasAuthMethod(comptime T: type) bool {
            for (auth_method_types) |M| if (M == T) return true;
            return false;
        }

        pub const route_gates: server_mod.Gates = .{
            .admin = enable_admin,
            .analytics = @hasField(@TypeOf(cfg), "analytics"),
            .senders = @hasField(@TypeOf(cfg), "mail"),
            .mail_webhook = @hasField(@TypeOf(cfg), "mail"),
            .tenancy = tenancy_config.enabled,
            .webauthn = hasAuthMethod(@import("auth/methods/webauthn.zig").WebAuthnMethod),
            .magic_link = hasAuthMethod(@import("auth/methods/magic_link.zig").MagicLinkMethod),
            .oauth2 = hasAuthMethod(@import("auth/methods/oauth2.zig").OAuth2Method),
        };
```

Add a framework-level comptime test:

```zig
test "R2-4: deselecting a built-in drops its method-specific routes" {
    const A = App(.{ .auth_methods = .{ .builtins = .{ .password } } });
    try std.testing.expect(!A.route_gates.webauthn);
    try std.testing.expect(!A.route_gates.magic_link);
    try std.testing.expect(!A.route_gates.oauth2);
    const B = App(.{});
    try std.testing.expect(B.route_gates.webauthn);
}
```

- [ ] **Step 5: Run the full suite** — `mise exec zig@0.16.0 -- zig build test --summary all` → green; `zig build` → the stock binary still assembles all five methods (no `.auth_methods` in `src/main.zig`).

- [ ] **Step 6: Docs** — `docs/framework.md` `auth_methods` table row becomes: "Auth method set. Bare tuple = register custom `AuthMethod` TYPES alongside all five built-ins; `.{ .builtins = .{ .password, … }, .custom = .{ … } }` selects the exact built-in set (a deselected built-in — e.g. `.webauthn`, ~3.2k LOC — is excluded from your binary, along with its routes)." Extend the §auth-methods prose with the builtins form + one sentence: the flat `auth-with-password`/`auth-refresh`/`auth-logout`/verification/reset routes are core and remain regardless of the built-in set (they do not go through the method registry). Update `docs/recipes.md` (~:740 "enable magic-link + OTP via config") to show the exact-set form. Mirror all three files to `site/src/content/docs/`.

- [ ] **Step 7: Changelog fragment** — `changelog.d/r2-selectable-auth-methods.md`:

```markdown
### Features

- `.auth_methods` gains an exact-set form: `.{ .builtins = .{ .password, .otp }, .custom = .{ MyMethod } }`. Deselected built-ins (WebAuthn's CBOR/COSE stack, magic-link, OAuth2, OTP) are excluded from the binary together with their routes. Absent key / bare-tuple form keep today's all-five behavior — non-breaking.
```

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat(auth): selectable built-in auth methods + method-derived route gates (R2-4)"
```

---

### Task 6: R2-5 — gate the built-in `"mail"`/`"webhook"` job kinds

**Files:**
- Modify: `src/framework.zig` (`builtin_job_regs` :394-397, `reserved_job_kinds` :401-406; new `.webhooks` key in `allowed` :277 + lowering)
- Modify: `src/ctx.zig` (doc comments on `ctx.webhook` :294-321 and `MailApi.enqueue` :1024-1032; keep the test-only `mail_job_reg` :1980 as-is)
- Modify: `src/queue/` (locate the unknown-kind dispatch error via `grep -rn "jobByKind\|UnknownJob" src/queue/ src/ctx.zig` and improve its message)
- Modify: `docs/framework.md` + `docs/jobs-and-webhooks.md` (if present; grep) + mirrors
- Create: `changelog.d/r2-builtin-job-gating.md`

**Interfaces:**
- Produces: the `"webhook"` job kind (and `webhook.zig`'s ~689 LOC) is compiled/registered iff `.webhooks = true` (new top-level bool key). The `"mail"` job kind is registered iff `.mailer` OR `.mail` is set — the documented enable signal for `ctx.mail().enqueue` with the default env-configured mailer is `.mail = .{}`. Both kind NAMES stay reserved unconditionally (a consumer `.jobs` entry named `mail`/`webhook` is still a compile error, so enabling later can't collide). Verification/password-reset emails are unaffected (they deliver via `app.mailer` directly — `src/api/auth.zig:809-815` — not via the queue).

- [ ] **Step 1: Write the failing comptime tests** (in `src/framework.zig` near the queue tests):

```zig
test "R2-5: built-in job kinds register only when their capability is configured" {
    const Bare = App(.{});
    try std.testing.expectEqual(@as(usize, 0), Bare.job_regs.len);

    const WithMail = App(.{ .mail = .{} });
    try std.testing.expectEqual(@as(usize, 1), WithMail.job_regs.len);
    try std.testing.expectEqualStrings("mail", WithMail.job_regs[0].kind);

    const WithHooks = App(.{ .webhooks = true });
    try std.testing.expectEqual(@as(usize, 1), WithHooks.job_regs.len);
    try std.testing.expectEqualStrings("webhook", WithHooks.job_regs[0].kind);
}

test "R2-5: mail/webhook kind names stay reserved even when unregistered" {
    // Must @compileError if uncommented — probe manually in Step 4, keep commented here:
    // _ = App(.{ .jobs = .{ .mail = someHandler } });
    try std.testing.expect(true);
}
```

(If consumer `.jobs` entries exist in other framework tests, adjust expected lengths accordingly — `job_regs` = builtins ++ consumer jobs.)

Run: expect FAIL (Bare.job_regs.len == 2 today).

- [ ] **Step 2: Implement** — in `src/framework.zig`:

1. `allowed` (:277): append `"webhooks"`.
2. Add the key lowering next to `enable_typegen`:

```zig
        /// R2-5: `.webhooks = true` registers the built-in "webhook" job kind
        /// (managed outbound deliveries via ctx.webhook). Unset → webhook.zig is
        /// not compiled into your binary and ctx.webhook fails at enqueue time.
        pub const enable_webhooks: bool = blk: {
            if (!@hasField(@TypeOf(cfg), "webhooks")) break :blk false;
            if (@TypeOf(cfg.webhooks) != bool)
                @compileError(".webhooks must be a bool; got '" ++ @typeName(@TypeOf(cfg.webhooks)) ++ "'");
            break :blk cfg.webhooks;
        };

        /// R2-5: the "mail" job kind (ctx.mail().enqueue) registers when mail is
        /// configured — a `.mailer` plugin or the `.mail` policy key (use `.mail = .{}`
        /// to enable background delivery with the default env-configured mailer).
        const enable_mail_job: bool = @hasField(@TypeOf(cfg), "mailer") or @hasField(@TypeOf(cfg), "mail");
```

3. Replace `builtin_job_regs` (:394-397):

```zig
        const builtin_job_regs: []const queue.JobReg = blk: {
            var t: []const queue.JobReg = &.{};
            if (enable_mail_job) t = t ++ &[_]queue.JobReg{.{ .kind = "mail", .handler = mail_send.jobHandler }};
            if (enable_webhooks) t = t ++ &[_]queue.JobReg{.{ .kind = webhook.job_kind, .handler = webhook.webhookJobHandler }};
            break :blk t;
        };
```

4. Replace `reserved_job_kinds` (:401-406) with a STATIC list (independent of what's registered):

```zig
        /// Reserved built-in kind names — reserved UNCONDITIONALLY (even when the
        /// built-in is gated off) so enabling a capability later never collides
        /// with a consumer job kind.
        const reserved_job_kinds: []const []const u8 = &.{ "mail", "webhook" };
```

- [ ] **Step 3: Improve the runtime unknown-kind error** — find the dispatch/enqueue failure path (`grep -rn "UnknownJobKind\|unknown job\|jobByKind" src/`). Where an enqueue names an unregistered kind, log a pointed hint before returning the error:

```zig
std.log.err("job kind '{s}' is not registered — built-ins are config-gated: \"webhook\" needs `.webhooks = true`, \"mail\" needs `.mail`/`.mailer` in App(.{{...}})", .{kind});
```

Update `ctx.webhook`'s doc comment (ctx.zig:294-321): "Requires `.webhooks = true` in the App config — without it the 'webhook' kind is not compiled in and this call fails at enqueue with error.UnknownJobKind." Update `MailApi.enqueue`'s doc (:1024) analogously for `.mail`/`.mailer`.

- [ ] **Step 4: Probe the reserved-name guard** — temporarily add `_ = App(.{ .jobs = .{ .webhook = <any handler fn> } });` to a test, run `zig build test`, confirm `assertNoReservedJobKinds` still rejects it (it receives `reserved_job_kinds` — verify the static list is what's passed at :415), revert the probe with Edit.

- [ ] **Step 5: Run everything** — `mise exec zig@0.16.0 -- zig build test --summary all` → green (fix any framework/ctx tests that assumed 2 builtin regs — `src/ctx.zig:1972-1980`'s mail-job round-trip test constructs its own registry and should be untouched; verify). `zig build` → stock binary now excludes `webhook.zig` + `mail/send.zig` job handler.

- [ ] **Step 6: Docs** — `docs/framework.md`: add the `webhooks` key row; update the jobs/queues section and the `ctx.webhook`/`ctx.mail().enqueue` docs with the enable signals. Grep `docs/ site/src/content` for `ctx.webhook` and `deliverLater\|mail().enqueue` and update each. Mirrors.

- [ ] **Step 7: Changelog fragment** — `changelog.d/r2-builtin-job-gating.md`:

```markdown
### Breaking

- The built-in job kinds are now config-gated (embedded consumers): `ctx.webhook` requires `.webhooks = true`; `ctx.mail().enqueue` requires `.mail` (use `.mail = .{}` for defaults) or a `.mailer` plugin. Without the key the kind is not compiled in and enqueue fails loudly with a hint. Direct mailer delivery (verification/password-reset emails) is unaffected. The kind names `mail`/`webhook` remain reserved either way.
```

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat(gating)!: config-gate built-in mail/webhook job kinds (R2-5)"
```

---

### Task 7: the gating invariant — lean-consumer fixture + nm absent-symbols check

**Files:**
- Create: `fixtures/minimal/main.zig` (a consumer-shaped app with nothing optional configured)
- Modify: `build.zig` (add a `minimal-server` exe + step, next to the features-fixture block from Task 2)
- Create: `scripts/check-gating.sh` (the nm-based invariant; executable)
- Modify: `.github/workflows/ci.yml` (run the check in the build job)
- Create: `changelog.d/r2-gating-invariant.md`

**Interfaces:**
- Consumes: Task 4's `.admin = .disabled`, Task 5's `.builtins` form, Task 6's job gating.
- Produces: `zig build minimal-server` (Debug, unstripped) + `scripts/check-gating.sh`, which FAILS the build if any deselected subsystem's symbols appear in the lean binary — and self-checks each pattern against the full binary (a pattern matching nothing in the FULL binary means the symbol names drifted and the check would be vacuous → also a failure).

Design note (why nm, not comptime): Zig has no "assert this decl was never analyzed" primitive, and sneaking `@compileError` into production decls is not an option. The comptime route/job-table tests (Tasks 4-6) prove the *tables* are right; only a symbol-table check proves no OTHER anchor still references the code. Debug builds keep full namespaced symbol names (e.g. `auth.methods.webauthn.WebAuthnMethod.create`), which is what the patterns match.

- [ ] **Step 1: Create the lean fixture** — `fixtures/minimal/main.zig`:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// The gating-invariant probe (audit: gating-consistency §4): a consumer-shaped
/// build with NOTHING optional configured. scripts/check-gating.sh asserts that
/// deselected subsystems leave no symbols in this binary. Update the App literal
/// when config keys move (e.g. the .auth grouping) — the script is the guard.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .admin = .disabled,
        .auth_methods = .{ .builtins = .{ .password } },
    }).runCli(init);
}
```

- [ ] **Step 2: Wire it into `build.zig`** (mirror the features-fixture block from Task 2, name `minimal-server`, root `fixtures/minimal/main.zig`, step description "Build the lean gating-invariant fixture (Debug, unstripped)"). IMPORTANT: this exe must NOT be stripped — check how `-Dstrip` defaults interact (`build.zig:7-12`: strip is off in Debug, and Debug is the default optimize) — building with plain `zig build minimal-server` is sufficient.

Run: `mise exec zig@0.16.0 -- zig build minimal-server && ls zig-out/bin/minimal-server`

- [ ] **Step 3: Explore the real symbol names ONCE before writing patterns**

Run: `nm --defined-only zig-out/bin/zigbase | grep -io "webauthn\|cbor\|analytics[._]api\|api[._]senders\|inbound\|webhookJobHandler\|admin[._]serve\|magic_link\|oauth" | sort | uniq -c | head -30`
(first `zig build` the full binary). Record which spellings actually appear — Zig symbol names are dot-namespaced module paths. Adjust the pattern list in Step 4 to the OBSERVED names; the positive-control loop will catch any you get wrong.

- [ ] **Step 4: Write `scripts/check-gating.sh`**

```bash
#!/usr/bin/env bash
# Gating invariant (R2-3/R2-4/R2-5, audit gating-consistency §4): a consumer App
# with nothing optional configured must contain NO symbols from deselected
# subsystems. Each pattern is also required to match in the FULL binary — a
# pattern that matches nothing anywhere has drifted (rename) and would make the
# check vacuous, so that fails too.
set -euo pipefail
cd "$(dirname "$0")/.."

FULL=zig-out/bin/zigbase
LEAN=zig-out/bin/minimal-server
[ -x "$FULL" ] || { echo "build $FULL first (zig build)"; exit 2; }
[ -x "$LEAN" ] || { echo "build $LEAN first (zig build minimal-server)"; exit 2; }

# subsystem -> symbol substring expected ONLY in the full binary
# (verify/adjust spellings against Step 3's nm exploration)
PATTERNS=(
  "webauthn"            # WebAuthn method + register endpoints + CBOR/COSE stack
  "cbor"                # WebAuthn attestation parsing
  "methods.magic_link"  # magic-link method (consume route + mailer body)
  "methods.oauth2"      # OAuth2 method
  "analytics.api"       # analytics read endpoints
  "api.senders"         # senders endpoints
  "mail.inbound"        # inbound SES/Postmark webhook
  "webhookJobHandler"   # built-in webhook job kind
  "mail.send.jobHandler" # built-in mail job kind
  "admin.serve"         # admin SPA dispatch (+ its @embedFile assets)
)

fail=0
for p in "${PATTERNS[@]}"; do
  full_n=$(nm --defined-only "$FULL" | grep -c -i -- "$p" || true)
  lean_n=$(nm --defined-only "$LEAN" | grep -c -i -- "$p" || true)
  if [ "$full_n" -eq 0 ]; then
    echo "DRIFT: pattern '$p' matches nothing in the FULL binary — update the pattern"; fail=1
  fi
  if [ "$lean_n" -ne 0 ]; then
    echo "LEAK: '$p' found $lean_n symbol(s) in the lean binary:"
    nm --defined-only "$LEAN" | grep -i -- "$p" | head -5
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "gating invariant OK (${#PATTERNS[@]} patterns)"
exit $fail
```

`chmod +x scripts/check-gating.sh`.

- [ ] **Step 5: Run it and iterate**

Run: `mise exec zig@0.16.0 -- zig build && mise exec zig@0.16.0 -- zig build minimal-server && ./scripts/check-gating.sh`
Expected: `gating invariant OK`. If a LEAK fires, that's a REAL finding — some anchor still references the subsystem (e.g. a stray import in ctx/root); trace the symbol with `nm | grep` and fix the anchor (do not weaken the pattern). If DRIFT fires, fix the pattern to the observed spelling. Note: bare `oauth2`/`analytics`/`senders`/`magic_link` substrings will false-positive on schema-option/`ctx.track`/mail-body symbols — that is WHY the patterns above are namespaced; keep them so.

- [ ] **Step 6: CI** — in `.github/workflows/ci.yml` build job, after the existing binary builds:

```yaml
      - name: Build lean gating fixture
        run: mise exec zig@0.16.0 -- zig build minimal-server
      - name: Gating invariant (absent-symbols check)
        run: ./scripts/check-gating.sh
```

- [ ] **Step 7: Changelog fragment** — `changelog.d/r2-gating-invariant.md`:

```markdown
### Internal

- CI now enforces the gating invariant: a minimal consumer build (`fixtures/minimal/`) is nm-scanned to prove deselected subsystems (WebAuthn, magic-link, OAuth2, analytics API, senders, mail webhook, webhook/mail job kinds, admin SPA) leave zero symbols (`scripts/check-gating.sh`).
```

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "test(gating): lean fixture + nm absent-symbols invariant in CI (R2-3/4/5 guard)"
```

---

### Task 8: R2-6 — `-Dfts5` build flag (default ON)

**Files:**
- Modify: `build.zig` (option + build_options + conditional `-DSQLITE_ENABLE_FTS5` at :60)
- Modify: `src/search/fts.zig` (comptime `enabled` gate on the SQLite/FTS5 paths, mirroring `src/search/vector.zig:46-47`)
- Modify: the `?search=` handler path in `src/records.zig` (clean 400 when disabled) and the startup `ensureIndex` call site (fail loudly on a searchable SQLite schema without FTS5) — locate via `grep -rn "fts\." src/records.zig src/framework.zig src/provision.zig`
- Modify: `.github/workflows/ci.yml` (unit job gains a `-Dfts5=false` build check), `docs/framework.md`/`README.md` build-flags docs + mirrors, `docs/search.md` if present
- Create: `changelog.d/r2-fts5-flag.md`

**Interfaces:**
- Produces: `zig build -Dfts5=false` compiles SQLite without `-DSQLITE_ENABLE_FTS5` (~250-400 KB smaller) and `search.fts.enabled == false`; `?search=` on SQLite then 400s ("Full-text search is not enabled in this build."); a `.searchable` field on a SQLite backend refuses at startup. Default `true` — the shipped binary is byte-identical in behavior. Postgres FTS (`buildPostgres`, GIN path) is NOT behind this flag.

- [ ] **Step 1: Add the flag in `build.zig`** — next to the `vector` option (:35-44):

```zig
    const fts5 = b.option(bool, "fts5", "Compile SQLite FTS5 full-text search into the binary (default true; -Dfts5=false for lean builds without .searchable fields)") orelse true;
    build_options.addOption(bool, "fts5", fts5);
```

Make the SQLite C-flags conditional — the flags array at :55-70 is a comptime literal; restructure to:

```zig
    const sqlite_base_flags = [_][]const u8{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_DQS=0",
        // … every existing flag EXCEPT -DSQLITE_ENABLE_FTS5, unchanged …
    };
    const sqlite_flags: []const []const u8 = if (fts5)
        &(sqlite_base_flags ++ [_][]const u8{"-DSQLITE_ENABLE_FTS5"})
    else
        &sqlite_base_flags;
    zigbase_mod.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = sqlite_flags });
```

Update the "NOT trimmed: FTS5" comment (:66-67) to describe the new flag. Check whether the examples' vendored build files compile sqlite independently (`grep -rn "SQLITE_ENABLE_FTS5" examples/`) — if they do, leave them (examples default to full builds).

- [ ] **Step 2: Gate `src/search/fts.zig`** — add at the top (mirror vector.zig:46):

```zig
const build_options = @import("build_options");
/// Comptime gate: SQLite FTS5 is compiled in (`-Dfts5`, default ON). When false,
/// the SQLite MATCH/ensureIndex paths are comptime-dead and `?search=` fails
/// closed with a clean 400. Postgres FTS is NOT behind this flag.
pub const enabled = build_options.fts5;
```

In the SQLite-dialect branch of the search clause builder (the fn `records.list` calls — read fts.zig:117-260 to find it) add `if (comptime !enabled) return error.SearchDisabled;` at the top of the SQLite path (add `SearchDisabled` to the fn's error set); in `ensureIndex`'s SQLite branch (:216-276) add the same guard BEFORE any SQL, returning `error.SearchDisabled`. Leave `buildPostgres`/the Postgres GIN `ensureIndex` (:278+) ungated.

- [ ] **Step 3: Fail closed at the two consumer chokepoints**

1. In `src/records.zig` where the search clause error is handled (grep how `?vector=` maps `error.VectorDisabled` to a 400 — copy that pattern exactly): map `error.SearchDisabled` → 400 `"Full-text search is not enabled in this build."`.
2. At the startup `ensureIndex` call site (framework/provision — found in Step 0 grep): on a SQLite backend with any searchable collection and `!fts.enabled`, log `refusing to start: collection '{s}' declares .searchable fields but this binary was built with -Dfts5=false` and return `error.FtsDisabled` (mirror the encrypted-field refusal at framework.zig:1751-1754).

- [ ] **Step 4: Tests** — in `src/search/fts.zig` add:

```zig
test "fts5 flag: enabled reflects build_options (default true in the test build)" {
    try std.testing.expect(enabled == build_options.fts5);
}
```

(The disabled behavior can't be unit-tested in a default test build — it is covered by the CI compile check below plus the comptime-dead guarantee.)

- [ ] **Step 5: Both builds compile** —

Run: `mise exec zig@0.16.0 -- zig build test --summary all` (default) then `mise exec zig@0.16.0 -- zig build -Dfts5=false && mise exec zig@0.16.0 -- zig build test -Dfts5=false --summary all` (if the test step doesn't accept the flag, at minimum the build must pass — check how `-Ddev-clock=false` is exercised in `.github/workflows/ci.yml:109` and copy that arrangement).

- [ ] **Step 6: CI** — unit job: add a step mirroring the `-Ddev-clock=false` prod-gate step at ci.yml:109 for `-Dfts5=false` (build-only is acceptable if tests hard-require FTS5).

- [ ] **Step 7: Docs** — README build/size notes + `docs/framework.md` build-flags section (alongside `-Dpostgres`/`-Dvector`/`-Ddev-clock`): `-Dfts5` default ON, what turns off, the startup refusal, "Postgres FTS unaffected". Check `docs/search.md` + `site/src/content/docs/search.md` for a build-requirements note. Mirrors.

- [ ] **Step 8: Changelog fragment** — `changelog.d/r2-fts5-flag.md`:

```markdown
### Features

- New `-Dfts5` build flag (default **on**): lean custom builds can drop SQLite's FTS5 (~250-400 KB). With `-Dfts5=false`, `?search=` answers 400 and a `.searchable` SQLite schema refuses at startup. Default builds are unchanged; Postgres full-text search is independent of the flag.
```

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "feat(build): -Dfts5 flag, default ON (R2-6)"
```

---

### Task 9: E4 + N6 + E7 — list-shape unification: `{items}` envelopes + analytics house cursor (Breaking; SDK + admin SPA in this task)

**Files:**
- Modify: `src/api/collections.zig` (:68-81 `list`), `src/api/settings.zig` (:56-67 `list`), `src/api/oauth.zig` (:83-99 providers root key), `src/analytics/api.zig` (`events` gains `cursor`/`nextCursor`/`hasNext`)
- Modify: `src/codegen/acquire_http.zig` (parse the `{items}` envelope) + its tests
- Modify: `src/admin/app.js` (:25 `collections`, :31 `settingsList` unwrap `.items`)
- Modify: `clients/typescript/src/collection.ts` (:105 `listAuthProviders` return type), `clients/typescript/src/analytics.ts` (`events` cursor opt + return type), `clients/typescript/test/integration/harness.ts` (:193), SDK tests
- Modify: `docs/api.md` rows for `GET /api/collections`, `GET /api/settings`, oauth2 providers, analytics events + mirrors
- Create: `changelog.d/r2-list-envelopes.md`

**Interfaces:**
- Produces (wire, server ≥ next release): `GET /api/collections` → `{"items":[…]}`; `GET /api/settings` → `{"items":[…]}` (per-key GET unchanged); `GET /api/collections/:col/auth/oauth2/providers` → `{"items":[…]}` (was `{"providers":…}`); `GET /api/analytics/events` → `{"items":[…],"nextCursor":"<opaque>"|null,"hasNext":bool}` and accepts `?cursor=` alongside the existing `name`/`actor`/`since`/`limit` (limit cap 200 unchanged). House pagination = the records cursor vocabulary (`cursor`/`limit` params; `items`/`nextCursor`/`hasNext` keys — see `src/records.zig:1214-1216`).
- SDK: `listAuthProviders(): Promise<{ items: OAuth2Provider[] }>`; `analytics.events(opts)` gains `cursor?: string`, returns `{ items, nextCursor: string | null, hasNext: boolean }`.

- [ ] **Step 1: Server unit tests first.** In `src/api/collections.zig` and `src/api/settings.zig`, find the existing `list` tests (grep `test "list`); update their body assertions from a bare `[` prefix to the envelope, e.g. expect the body to start with `{"items":[`. In `src/api/oauth.zig`'s providers test, expect `"items"` as the root key. Run `zig build test` → these FAIL.

- [ ] **Step 2: Implement the three envelopes.**

`collections.zig` `list` (:75-80) — wrap:

```zig
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "items", .{ .array = arr });
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{});
```

`settings.zig` `list` (:62-66) — identical wrap around its `arr`.
`oauth.zig` (:97) — `try root.put(ctx.allocator, "providers", …)` → `"items"`.

- [ ] **Step 3: Analytics cursor.** Read `src/analytics/api.zig:100-160` and the `_events` DDL (grep `_events` in `src/migrations.zig` ~:440,468) to confirm the ordering column set. Implement keyset pagination in `events`:
  - Accept `?cursor=` = the opaque `"<occurred_at>|<id>"` of the last row of the previous page (both columns already selected).
  - `WHERE … AND (occurred_at, id) < (?, ?)` in the existing ORDER BY direction — read the current `ORDER BY` first; if SQLite row-value comparison is unavailable in this build, expand to `(occurred_at < ? OR (occurred_at = ? AND id < ?))`.
  - Fetch `limit + 1` rows; `hasNext = fetched > limit`; `nextCursor` = the cursor of row `limit` when `hasNext`, else null; emit both keys next to `items` always.
  - Malformed cursor → 400 `"Invalid cursor."` (match records' wording — grep `Invalid cursor` in `src/records.zig` and reuse it exactly).

Add unit tests in `analytics/api.zig` mirroring the existing events tests (:474+): a two-page walk over 3 seeded events with `limit=2` asserting no dup/skip and terminal `hasNext=false`, plus the malformed-cursor 400.

- [ ] **Step 4: codegen acquisition.** `src/codegen/acquire_http.zig` parses "a `GET /api/collections` JSON array" (:5) — change to parse `{items:[…]}` (accept ONLY the new envelope — no dual-shape shim, consistent with the no-shims stance of the 0.3.0 SDK work). Update its doc comments + tests, and the sibling comment in `src/codegen/acquire.zig:5`. Also update `clients/typescript/test/integration/harness.ts:193` to read `(await res.json()).items`.

- [ ] **Step 5: Admin SPA.** `src/admin/app.js`: change line 25 to `collections: () => api('GET', '/collections').then(r => r.items),` and line 31 to `settingsList: () => api('GET', '/settings').then(r => r.items),` — the three `API.collections()` consumers (:105, :161, :238) and the settings view (:615) then work unchanged.

- [ ] **Step 6: SDK.** `clients/typescript/src/collection.ts:105`: `listAuthProviders(): Promise<{ items: OAuth2Provider[] }>` (adjust the doc comment: "Changed in server 0.10: was `{providers}`"). `clients/typescript/src/analytics.ts`: `events` opts gain `cursor?: string`; return type `Promise<{ items: AnalyticsEvent[]; nextCursor: string | null; hasNext: boolean }>`; forward `cursor` in the query object. Update/extend the vitest mocks (`test/analytics.test.ts`, and grep `providers` in `clients/typescript/test/` for the listAuthProviders shape). Run from `clients/typescript/`: `mise exec node@24 -- npm test && mise exec node@24 -- npm run typecheck` → PASS.

- [ ] **Step 7: Zig suite + browser suite.**

Run: `mise exec zig@0.16.0 -- zig build test --summary all` → green (the golden `gen-test` must be untouched — if it fails, STOP per Global Constraints).
Run: `mise exec python@3.13 -- python -m pytest tests/admin -q` → green (test_schema/test_settings exercise the changed admin fetches end-to-end).

- [ ] **Step 8: Docs.** `docs/api.md`: the four endpoint rows get the new shapes + "(changed: was a bare array / `{providers}`)"; the analytics events row documents `cursor`/`nextCursor`/`hasNext` and states the house list contract ("all list endpoints return `{items}`; paginated ones add the records cursor vocabulary"). Mirror to `site/src/content/docs/api.md` (+ `analytics.md` page if it documents the events shape — grep). `docs/framework.md` senders/analytics bullets if they show shapes.

- [ ] **Step 9: Changelog fragment** — `changelog.d/r2-list-envelopes.md`:

```markdown
### Breaking

- `GET /api/collections` and `GET /api/settings` now return `{"items":[…]}` instead of a bare JSON array (superuser endpoints; admin SPA + typegen updated). `zigbase typegen --url` requires a server from this release.
- `GET /api/collections/:col/auth/oauth2/providers` returns `{"items":[…]}` (was `{"providers":[…]}`); `@zigbase/client`'s `listAuthProviders` types updated.

### Changed

- `GET /api/analytics/events` adopts the house cursor pagination: `?cursor=` request param and `nextCursor`/`hasNext` response keys (additive; `limit` cap 200 unchanged).
```

- [ ] **Step 10: Commit**

```bash
git add -A && git commit -m "feat(api)!: {items} envelopes for collections/settings/providers + analytics house cursor (E4/N6/E7)"
```

---

### Task 10: E5 + E6 — uniform 204 side-effect bodies + `magic-link` path rename (Breaking; SDK in this task)

**Files:**
- Modify: `src/api/auth.zig` (`confirmVerification` :911-928 → 204; `confirmPasswordReset` (~:995-1015) → 204; their tests at :1232, :1289 and any other `200` assertions on these two)
- Modify: `src/api/webauthn_register.zig` (`finish` :130 doc + :237 body → 204; `begin` keeps its 200 challenge JSON)
- Modify: `src/server.zig` (the gated magic_link route pattern from Task 4: `auth/magic_link/consume` → `auth/magic-link/consume`)
- Modify: `src/auth/methods/magic_link.zig` (emailed URL :150 and its test :426)
- Modify: `clients/typescript/src/collection.ts` (`confirmVerification` → `Promise<void>`, `confirmPasswordReset` → `Promise<void>`) + SDK tests
- Modify: `docs/api.md` (:592, :618, :627 magic-link rows; confirm-* rows; webauthn finish row) + `docs/recipes.md` magic-link mentions + mirrors; Task 4's route-table test (the magic_link pattern string)
- Create: `changelog.d/r2-auth-wire-polish.md`

**Interfaces:**
- Produces (wire): `POST …/confirm-verification` → 204 empty (was 200 `{"verified":true}`); `POST …/confirm-password-reset` → 204 empty (was 200 `{"success":true}`); `POST …/auth/webauthn/register/finish` → 204 empty (was 200 `{"registered":true}`); `GET /api/collections/:col/auth/magic-link/consume` (was `magic_link`; HARD cutover, no redirect shim — tokens are short-lived). The method SLUG stays `magic_link` (registry lookup, `onAuth` tag, `/auth/magic_link/initiate|complete` generic routes are UNCHANGED — only the bespoke consume path is renamed). This 204 convention is the E13 house rule already broadcast to the email-2/auth-2 streams.

- [ ] **Step 1: Update the Zig tests first** — in `src/api/auth.zig`, flip the `confirmVerification` assertions (:1232, :1289) to `204`, and grep the file for other `confirm` status/body assertions (incl. any `{"success":true}` expectations). In `src/api/webauthn_register.zig`, grep `registered` and flip the finish-path test to 204/empty. Run `zig build test` → FAIL (still 200).

- [ ] **Step 2: Implement.** `auth.zig:928` → `return .{ .status = 204, .body = "" };` (delete the `{"verified":true}` literal); the `confirmPasswordReset` tail (`{"success":true}`) → same. `webauthn_register.zig:237` → `return http.Response{ .status = 204, .body = "" };` and fix the `finish` doc comment (:130): `Returns: 204 No Content on success.` Run `zig build test` → PASS.

- [ ] **Step 3: Rename the consume path.** In Task 4's gated group in `src/server.zig`: pattern → `"/api/collections/:col/auth/magic-link/consume"` (handler unchanged). Update the Task 4 route-table test string. In `src/auth/methods/magic_link.zig:150` change the emailed URL segment `auth/magic_link/consume` → `auth/magic-link/consume`; update the expectation at :426. Grep the repo for any other `magic_link/consume` literal: `grep -rn "magic_link/consume" src/ docs/ site/ clients/ examples/ tests/` — every hit must flip (docs/api.md:627 in particular).

- [ ] **Step 4: SDK.** `clients/typescript/src/collection.ts`: `confirmVerification(token: string): Promise<void>` and `confirmPasswordReset(token: string, password: string): Promise<void>` (bodies unchanged — `transport.send` already handles 204 as void for `requestVerification`; verify by reading `transport.ts`'s 204 path). Update any vitest fixtures returning `{verified:true}`/`{success:true}` (grep `clients/typescript/test/` for both) to 204 responses. Run `mise exec node@24 -- npm test && mise exec node@24 -- npm run typecheck` → PASS.

- [ ] **Step 5: Docs.** `docs/api.md`: confirm-verification/confirm-password-reset rows → "204 No Content"; webauthn finish row → 204; the magic-link consume row (:627) gets the new dash path + a "(renamed from `magic_link` — emailed URLs from older servers stop working at upgrade; tokens are short-lived)" note; :592's initiate/complete rows stay `magic_link` (slug). `docs/recipes.md` magic-link recipe URLs. Mirrors for both files.

- [ ] **Step 6: Full suites.** `mise exec zig@0.16.0 -- zig build test --summary all` → green. Browser suite: `mise exec python@3.13 -- python -m pytest tests/admin -q` (no admin test hits these routes today, but this is an auth-route change — run it per Global Constraints).

- [ ] **Step 7: Changelog fragment** — `changelog.d/r2-auth-wire-polish.md`:

```markdown
### Breaking

- Side-effect auth successes are now uniform **204 No Content**: `confirm-verification` (was `{"verified":true}`), `confirm-password-reset` (was `{"success":true}`), `webauthn/register/finish` (was `{"registered":true}`). Treat any 2xx as success; `@zigbase/client` types updated to `Promise<void>`.
- The magic-link consume URL is now dash-case: `GET …/auth/magic-link/consume` (was `auth/magic_link/consume`). Hard cutover — links emailed by pre-upgrade servers 404 (tokens are short-lived). The method slug (`/auth/magic_link/initiate|complete`, `onAuth` tag) is unchanged.
```

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat(auth)!: uniform 204 side-effect bodies + magic-link dash path (E5/E6)"
```

---

### Task 11: E8 + E9 + E10 — event-surface cleanup: `ev.rctx`, delete `RouteEvent`, drop `RecordEvent.app` (Breaking; examples in this task)

**Files:**
- Modify: `src/events.zig` (`RecordEvent` :106-119: `ctx`→`rctx`, delete `app`; delete `RouteEvent` :213-244 + its doc block :16-38 references; audit `WriterData`/`ReaderData`/`acquireWriter`/`acquireReader` :43-95 — delete if RouteEvent was their only consumer)
- Modify: every internal constructor/consumer — find with `grep -rn "RecordEvent{\|\.ctx = \|ev\.app\|ev\.ctx" src/` (expect: `src/records.zig` hook-firing sites, `src/api/records.zig` if split, `src/data.zig`, events.zig tests ~:1464, `src/api/auth.zig:1367-1390` RouteEvent test)
- Modify: `src/root.zig` (remove the `RouteEvent` re-export; keep `RecordEvent`)
- Modify: `examples/blog/src/main.zig` (:72 `ev.ctx.auth`), `examples/golfsim/src/main.zig` (~:112), `examples/plugins/src/main.zig` (:394-409 comments + `ev.ctx.auth`), plus each example's README (`ev.app.allocator` warnings)
- Modify: `docs/framework.md` (the RecordEvent reference §, the CRITICAL/UB arena warning ~:198-203, any RouteEvent mention, "Reading the request (`ev.ctx`)" subsection → `ev.rctx`), `docs/recipes.md` (:340 `ev.ctx.resolveMacro`, :416; :524/:564 are JobEvent — LEAVE, `JobEvent.app` stays) + mirrors. `docs/dx-assessment.md` is historical — do NOT touch.
- Create: `changelog.d/r2-event-surface.md`

**Interfaces:**
- Produces: `RecordEvent = { rctx: *const request.RequestContext, arena, collection, record, phase }` — no `app`, no `ctx`. Hooks reach the app via their `ctx: *Ctx` param (`ctx.app`); the arena-footgun (`ev.app.allocator`) is no longer expressible. `RouteEvent` is gone (live routes have received `*Ctx` since the Ctx migration; it was constructed only in tests). `ErrorEvent`/`JobEvent`/auth events are UNCHANGED (they keep `.app`/`.ctx`). Decision recorded: the audit's optional `ev.putField` helper is DECLINED (YAGNI) — revisit if hook-authoring pain shows up.

- [ ] **Step 1: Inventory before editing**

Run: `grep -rn "RouteEvent\|WriterData\|ReaderData" src/ examples/ | grep -v dx-assessment` and `grep -rn "ev\.app\|ev\.ctx\|\.app = \|RecordEvent{" src/records.zig src/events.zig src/data.zig src/api/ | head -50`
Record every constructor site and every read of `RecordEvent.app`/`.ctx`. If ANY live (non-test) code constructs `RouteEvent`, stop and re-read — the audit found only tests (`events.zig:1464`, `api/auth.zig:1387`).

- [ ] **Step 2: Rename + drop on `RecordEvent`** (`src/events.zig:106-119`):

```zig
pub const RecordEvent = struct {
    /// Resolved request context (auth identity, is_superuser, method) for the
    /// triggering request. Named `rctx` to match `Ctx.rctx` — `ctx` always means
    /// `*Ctx` in a handler signature.
    rctx: *const request.RequestContext,
    /// Request-scoped allocator that owns `record`'s JSON storage. Hooks MUST use
    /// this for any allocation that becomes part of `record`. (The old `ev.app`
    /// escape to the WRONG allocator was removed — use `ctx.app` for app access.)
    arena: std.mem.Allocator,
    collection: []const u8,
    record: *std.json.Value,
    phase: RecordPhase,
};
```

Fix every constructor (`.app = …` deleted, `.ctx = …` → `.rctx = …`) and every internal `ev.app`/`ev.ctx` read found in Step 1 (internal `ev.app.X` reads become a threaded `app` local or `ctx.app` where a `*Ctx` is in scope).

- [ ] **Step 3: Delete `RouteEvent`** (:213-244) and its re-export in `src/root.zig`. Migrate the test at `src/api/auth.zig:1367-1390` to call the seam directly (it exists per the RouteEvent doc: `auth_helpers.issueSession(ev.ctx, w.conn, collection, record_id)`):

```zig
test "auth_helpers.issueSession mints a session and fires onAuth(custom)" {
    // …same env setup as before; replace the RouteEvent construction with:
    const w = env.app.pool.acquireWriter();
    defer env.app.pool.releaseWriter();
    const issued = try @import("../auth_helpers.zig").issueSession(&hctx, w, "users", rid);
    _ = issued;
    // …same assertions on the onAuth firing + cookies as before.
}
```

(Adapt import path/arg types to the real `issueSession` signature — read `src/auth_helpers.zig` first.) Then check `WriterData`/`ReaderData`/`acquireWriter`/`acquireReader` (events.zig:43-95): if RouteEvent was the only consumer (`grep -rn "WriterData\|ReaderData" src/`), delete all four; if something else uses them, leave them with a comment.

- [ ] **Step 4: Fix the events.zig tests** (~:1464 and any others that constructed RouteEvent or set `.app`/`.ctx` on RecordEvent). Run `mise exec zig@0.16.0 -- zig build test --summary all` → green.

- [ ] **Step 5: Examples.** In each of blog/golfsim/plugins `src/main.zig`: `ev.ctx.` → `ev.rctx.`; delete/reword any `ev.app.allocator` warning comments ("the footgun field was removed; use ctx.app if you need the app"). Update the three example READMEs' hook prose likewise. Build all three:

```bash
(cd examples/blog && mise exec zig@0.16.0 -- zig build)
(cd examples/golfsim && mise exec zig@0.16.0 -- zig build)
(cd examples/plugins/frontend && mise exec node@24 -- npm ci && mise exec node@24 -- npm run build) && (cd examples/plugins && mise exec zig@0.16.0 -- zig build)
```

- [ ] **Step 6: Docs.** `docs/framework.md`: the record-hook reference (`ev.ctx` → `ev.rctx` throughout; simplify the ~:198-203 UB warning — the wrong allocator is no longer one dot away, but keep "always allocate record data with `ev.arena`"); check :527's `ev.app.allocator` usage — if it's a JobEvent context, leave it, if RecordEvent, fix it. `docs/recipes.md`: :340/:416 hook snippets → `ev.rctx`; :524/:564 (jobs) unchanged. Remove RouteEvent from any live doc (grep `RouteEvent docs/ site/` excluding dx-assessment + superpowers). Mirrors for both files.

- [ ] **Step 7: Changelog fragment** — `changelog.d/r2-event-surface.md`:

```markdown
### Breaking

- `RecordEvent.ctx` is now `RecordEvent.rctx` (`ctx` always means `*Ctx` in a hook signature). Mechanical migration: `ev.ctx.` → `ev.rctx.`.
- `RecordEvent.app` was removed — it put the UB footgun (`ev.app.allocator` vs `ev.arena`) one dot from every hook. Use the hook's `ctx.app`; allocate record data with `ev.arena`. (`JobEvent.app`/`ErrorEvent.app` are unchanged.)
- `RouteEvent` was deleted. It was never passed to a live route (handlers take `*Ctx`); it existed only in tests. Events carry data; `ctx` carries capabilities.
```

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat(events)!: ev.rctx rename, drop RecordEvent.app, delete vestigial RouteEvent (E8/E9/E10)"
```

---

### Task 12: E12 + N12 — env-var discoverability + a single-source parity test

**Files:**
- Modify: `README.md` (env table gains `ZIGBASE_DB_URL`, `ZIGBASE_PUBLIC_URL`, `ZIGBASE_SENDMAIL_COMMAND`)
- Modify: `src/framework.zig` (top-level `help` env section ~:1291-1316 gains the same three)
- Create: `tests/admin/test_docs_parity.py` (pure-text pytest — no `server`/`page` fixture, so it never launches a browser; shared with Task 13)
- Modify: mirrors (`site/src/content/docs/configuration.md` if it repeats the env table — grep)
- Create: `changelog.d/r2-env-docs.md`

**Interfaces:**
- Produces: every `ZIGBASE_*` env var referenced by the code is documented in BOTH the README env table and the top-level `zigbase help` text, enforced by `tests/admin/test_docs_parity.py::test_env_vars_documented` (this IS the N12 "single source of truth" mechanism: the source of truth is the code; the docs are parity-tested against it — chosen over a comptime help-renderer refactor as the audit's "at minimum a parity test" option).

- [ ] **Step 1: Write the failing parity test** — `tests/admin/test_docs_parity.py`:

```python
"""Doc-drift guards (R2, audit api-ergonomics E2/E12/N12).

Pure text tests: no server, no browser. They parse source + docs and fail when
either drifts. If one fails, fix the DOCS (or, for a deliberately-undocumented
var, add it to the allowlist below with a comment).
"""
import pathlib, re

REPO = pathlib.Path(__file__).resolve().parents[2]

# Dev/test-only or internal names that deliberately stay out of the README table.
# EXACT matches only — a prefix rule would silently swallow real vars (e.g. a
# "ZIGBASE_OAUTH_" prefix rule would hide ZIGBASE_OAUTH_STATE_SERVER, the E11 var!).
# "ZIGBASE_OAUTH_" / "ZIGBASE_FIELD_KEY_V" appear as exact captures because the
# source builds those names with format strings ("ZIGBASE_OAUTH_{s}_…" etc.);
# their user-facing spellings ARE documented (ZIGBASE_OAUTH_<NAME>_CLIENT_ID,
# ZIGBASE_FIELD_KEY_V<n>). Adjust after the first run against real captures.
ENV_ALLOWLIST = {
    "ZIGBASE_FAKE_NOW", "ZIGBASE_FAKE_SEED",          # -Ddev-clock builds only
    "ZIGBASE_FIELD_KEY_V",                            # bare fmt prefix capture (see above)
    "ZIGBASE_OAUTH_",                                 # bare fmt prefix capture (see above)
    "ZIGBASE_TEST_BINARY", "ZIGBASE_FEATURES_BINARY", # test harness only
}

def _code_env_vars():
    names = set()
    for f in (REPO / "src").rglob("*.zig"):
        for m in re.finditer(r'"(ZIGBASE_[A-Z0-9_]+)"', f.read_text()):
            names.add(m.group(1))
    return names - ENV_ALLOWLIST

def test_env_vars_documented_in_readme():
    readme = (REPO / "README.md").read_text()
    missing = sorted(n for n in _code_env_vars() if n not in readme)
    assert not missing, f"env vars referenced in src/ but missing from the README env table: {missing}"

def test_env_vars_listed_in_top_level_help():
    fw = (REPO / "src" / "framework.zig").read_text()
    # Anchor on the help text itself (framework.zig ~:1291), NOT on the first
    # occurrence of an env name — code above the help string also names env vars
    # (e.g. ZIGBASE_DB_URL in openPoolSelect), which would make the slice vacuous.
    anchor = "Token-signing secret (>= 32 bytes). When UNSET"
    assert anchor in fw, "help-text anchor drifted — update this test's anchor string"
    help_block = fw[fw.index(anchor):]
    missing = sorted(n for n in _code_env_vars() if n not in help_block)
    assert not missing, f"env vars referenced in src/ but missing from `zigbase help`: {missing}"
```

Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q`
Expected: FAIL listing at least `ZIGBASE_DB_URL`, `ZIGBASE_PUBLIC_URL`, `ZIGBASE_SENDMAIL_COMMAND` (E12), possibly more (e.g. `ZIGBASE_SMTP_*` variants, `ZIGBASE_STATIC_DIR` if some stream added it) — every extra finding is a REAL doc gap: document it, don't allowlist it, unless it is genuinely internal.

- [ ] **Step 2: Fill the README table.** Add rows (keep the table's existing column format `| env | flag | default | description |`):

```markdown
| `ZIGBASE_DB_URL` | — | `""` (embedded SQLite) | database backend selector: a `postgres://…` URL routes storage to Postgres (requires a `-Dpostgres` build); unset/empty = SQLite in the data dir |
| `ZIGBASE_PUBLIC_URL` | — | `""` | public base URL used to build user-facing links (magic-link sign-in emails). Unset → magic-link emails contain the raw token instead of a clickable URL |
| `ZIGBASE_SENDMAIL_COMMAND` | — | `""` | deliver mail by piping RFC-822 to this command (e.g. `sendmail -t`) instead of SMTP; takes precedence per the mailer docs (see docs/api.md) |
```

(Verify each default/behavior claim against `src/config.zig:22-23,128`, `src/framework.zig:1494-1520`, and the sendmail handling in the default mailer — `grep -n SENDMAIL src/` — before committing the wording.)

- [ ] **Step 3: Fill the help text.** In the top-level help env block (`src/framework.zig:1291-1316`) add, keeping the existing alignment style:

```
        \\  ZIGBASE_DB_URL            postgres://… routes storage to Postgres (-Dpostgres builds);
        \\                            unset = embedded SQLite in the data dir.
        \\  ZIGBASE_PUBLIC_URL        Public base URL for user-facing links (magic-link emails).
        \\  ZIGBASE_SENDMAIL_COMMAND  Pipe outbound mail to this command instead of SMTP.
```

Add every other var Step 1 surfaced, or extend the allowlist with a justifying comment.

- [ ] **Step 4: Green the parity test + suites.**

Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q` → PASS.
Run: `mise exec zig@0.16.0 -- zig build test --summary all` → green (help text is a string literal; nothing behavioral).
Check mirrors: `grep -rn "ZIGBASE_DB_URL\|ZIGBASE_PUBLIC_URL" site/src/content/docs/` — if the site duplicates the env table (configuration.md), add the same rows there.

- [ ] **Step 5: Changelog fragment** — `changelog.d/r2-env-docs.md`:

```markdown
### Fixes

- `ZIGBASE_DB_URL` (the SQLite-vs-Postgres selector), `ZIGBASE_PUBLIC_URL` (magic-link URL base), and `ZIGBASE_SENDMAIL_COMMAND` are now documented in the README env table and `zigbase help` — they were previously undiscoverable.

### Internal

- Doc-drift guard: `tests/admin/test_docs_parity.py` fails CI when a `ZIGBASE_*` var referenced in `src/` is missing from the README table or the help text.
```

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "docs(env): document DB_URL/PUBLIC_URL/SENDMAIL_COMMAND + env-doc parity test (E12/N12)"
```

---

### Task 13: E2 + R2-16 — config-key table regen (with laziness contract) + gating policy docs + CLAUDE.md note

**Files:**
- Modify: `docs/framework.md` §3 (regenerated key table + the config-plane rule + the laziness contract) + `site/src/content/docs/framework.md`
- Modify: `tests/admin/test_docs_parity.py` (add the table↔`allowed`-tuple parity test)
- Modify: `CLAUDE.md` (sharpening-rhythm note)
- Create: `changelog.d/r2-config-docs.md`

**Interfaces:**
- Consumes: the `allowed` tuple in `src/framework.zig` (now includes `admin`, `webhooks` from Tasks 4/6).
- Produces: a complete §3 table (framework.md:76-110 claimed exhaustiveness while omitting 9+ keys: `captcha`, `tenancy`, `abilities`, `mail`, `analytics`, `static_routes`, `enable_spa_marker`, `onFeatureExposure`, `features` — plus this stream's `admin`/`webhooks`), each row carrying the laziness contract; `test_config_key_table_matches_allowed_tuple` enforcing table = tuple in BOTH docs copies forever.

- [ ] **Step 1: Write the failing parity test** — append to `tests/admin/test_docs_parity.py`:

```python
def _allowed_keys():
    fw = (REPO / "src" / "framework.zig").read_text()
    m = re.search(r'const allowed = \.\{([^}]*)\}', fw)
    assert m, "allowed tuple not found in src/framework.zig"
    return set(re.findall(r'"(\w+)"', m.group(1)))

def _table_keys(md_path):
    text = md_path.read_text()
    start = text.index("accepts exactly these optional keys")
    keys = set()
    for line in text[start:].splitlines():
        m = re.match(r'\|\s*`(\w+)`\s*\|', line)
        if m:
            keys.add(m.group(1))
        elif keys and line.startswith("##"):
            break  # end of the section
    return keys

def test_config_key_table_matches_allowed_tuple():
    allowed = _allowed_keys()
    for doc in (REPO / "docs" / "framework.md", REPO / "site" / "src" / "content" / "docs" / "framework.md"):
        table = _table_keys(doc)
        assert table == allowed, (
            f"{doc}: config-key table drift. missing={sorted(allowed - table)} stale={sorted(table - allowed)}"
        )
```

Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q` → FAIL listing the omitted keys.

- [ ] **Step 2: Regenerate the §3 table.** Rewrite the framework.md table (:79-110) to contain EXACTLY one row per `allowed` entry, keeping every existing row's prose and adding the missing ones (`captcha`, `tenancy`, `abilities`, `mail`, `analytics`, `static_routes`, `enable_spa_marker`, `onFeatureExposure`, `features`, `admin`, `webhooks`, …) — source each new row's description from the corresponding lowering doc-comment in framework.zig (e.g. `.captcha` :885-911, `.tenancy` :933-958, `.mail` :960-978, `.static_routes` :639-643). Add a third column **"Unset ⇒ in your binary?"** stating the laziness contract per key, with three values: `excluded` (comptime-dead when unset — e.g. `analytics` routes/jobs, `webhooks`, `admin` when `.disabled`, deselected `auth_methods` builtins, durable queue backend), `data-only` (only lowered consts remain — e.g. `captcha`), or `always` (core — e.g. `hooks` dispatch plumbing, `pagination`). Base each cell on the audit's §1c/§2 findings — do NOT guess; where unsure, verify with `nm` against the Task 7 fixture.

- [ ] **Step 3: Write the policy prose (R2-16).** Add a short subsection after the table, "Choosing a config plane", containing verbatim:

> **The assignment rule:** structure/behavior = comptime `App(.{…})` key; deploy-varying values & secrets = env var (+ CLI flag if path-like); alternatives with real binary cost (extra C sources, wire protocols, dev-only codepaths) = `-D` build flag. Never gate a whole subsystem on a runtime value alone.
>
> **The laziness contract:** for every key marked *excluded* above, "unset" means the subsystem is not in your binary — not compiled, not routed, not registered. This holds because of the gating invariant: **no unconditional fn-pointer registration for optional capabilities** (fn-pointer tables defeat Zig's lazy analysis; `builtin_routes` and the built-in job registry are comptime-assembled from your config, enforced by `scripts/check-gating.sh` in CI).

Mirror the full §3 rewrite + prose to `site/src/content/docs/framework.md`. Re-run the parity test → PASS for both copies.

- [ ] **Step 4: CLAUDE.md sharpening note.** Add one paragraph to the "Conventions that bite" section:

```markdown
- **Sharpening rhythm & house API conventions.** Periodic "sharpening" audits sweep the config/API surface; fixes land as dedicated streams (see docs/superpowers/plans). The standing conventions they enforce: every list endpoint returns `{items}`; side-effect success = `204`; pagination = the records cursor vocabulary (`cursor`/`limit`, `nextCursor`/`hasNext`); URL segments are dash-case; config planes follow the assignment rule in docs/framework.md §3 (comptime = structure, env = deploy-varying, build flag = binary cost); optional subsystems must be comptime-gated (no unconditional fn-pointer registration — CI enforces via scripts/check-gating.sh); `tests/admin/test_docs_parity.py` fails on config-key-table or env-table drift. New endpoints/keys MUST follow these or update them deliberately.
```

- [ ] **Step 5: Site build + suites.**

Run: `cd site && mise exec node@24 -- npm run build` → succeeds.
Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q` → PASS.

- [ ] **Step 6: Changelog fragment** — `changelog.d/r2-config-docs.md`:

```markdown
### Fixes

- The `App(.{…})` config-key table in docs/framework.md claimed to be exhaustive while omitting 9 keys (`captcha`, `tenancy`, `abilities`, `mail`, `analytics`, `static_routes`, `enable_spa_marker`, `onFeatureExposure`, `features`); it is now complete, states each key's binary-size contract ("unset ⇒ excluded"), and is drift-guarded by a parity test.
```

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "docs(config): complete key table + laziness contract + gating policy + parity test (E2/R2-16)"
```

---

### Task 14: E3 — the `.auth` config grouping (LAST; rebases on auth-2)

**Files:**
- Modify: `src/framework.zig` (`allowed` :277; the `.auth` dispatcher guard :296-300; `assembleTypes` call site :606-614 feeds `cfg.auth.methods`; captcha lowering :885-920 reads `cfg.auth.captcha`; `session_store_config` :572-580 + `session_gc_cron` :585-592 read `cfg.auth.session.*`; pointed moved-key compile errors)
- Modify: `src/auth/registry.zig` (`assembleTypes` reads the methods VALUE it is handed — signature change, see Interfaces)
- Modify: `fixtures/minimal/main.zig` + `scripts/check-gating.sh` comment (Task 7), `fixtures/features/main.zig` if it grew auth keys, `examples/plugins/src/main.zig` (`.auth_methods` :~630), any example/fixture using `.captcha`/`.session_store`/`.auth`
- Modify: `docs/framework.md` (§3 table rows collapse into one `auth` row with sub-keys; §auth-methods/§captcha/§sessions sections) + `docs/recipes.md` (~:740) + mirrors; Task 13's parity test keeps passing because the table and tuple change together
- Create: `changelog.d/r2-auth-grouping.md`

**Interfaces:**
- Produces the grouped comptime key:

```zig
.auth = .{
    .hooks   = .{ .register = …, .logout = …, .refresh = …, .password_change = … }, // was top-level .auth
    .methods = .{ .builtins = .{ … }, .custom = .{ … } },                            // was .auth_methods (both forms)
    .captcha = .{ .provider = …, .secret = … },                                      // was .captcha
    .session = .{ .store = .epoch | .table, .gc_cron = "0 * * * *" },                // was .session_store / .session_gc_cron
},
```

Old spellings (`.auth = .{ .register = … }` direct hook fields, top-level `.auth_methods`, `.captcha`, `.session_store`, `.session_gc_cron`) are pointed `@compileError`s naming the new location. Runtime/env auth knobs (`auth_token_ttl`, `oauth_state_*`, `cookie_secure`, `rate_limit_*`) deliberately STAY env-only — documented as such per the Task 13 assignment rule.

**SEQUENCING — read before starting:**

- [ ] **Step 0: REBASE CHECKPOINT.** This task is written against today's `origin/main`, but the R2 branch merges AFTER the auth-2 stream (F). Before starting: `git fetch origin && git rebase origin/main`, confirm auth-2 has landed (`git log origin/main --oneline | head -30` — look for the auth-2/sessions merge). Then re-inventory the auth config surface: `grep -n "auth" src/framework.zig | grep -i "hasField\|allowed"` and diff against this task's assumptions. Auth-2's spec adds session REST routes and `ctx.auth()` verbs, NOT new config keys — but if it DID add any auth-adjacent comptime key (e.g. a session knob), fold it into the `.auth.session` group here and note it in the fragment. If auth-2 has NOT merged yet, STOP — park this task; everything before it can ship.

- [ ] **Step 1: Write the failing comptime tests** (in `src/framework.zig`):

```zig
test "E3: grouped .auth lowers hooks/methods/captcha/session" {
    const H = struct {
        fn onRegister(_: *ctx_mod.Ctx, _: *events.AuthLifecycleEvent) anyerror!void {}
    };
    const A = App(.{ .auth = .{
        .hooks = .{ .register = .{ .after = H.onRegister } },
        .methods = .{ .builtins = .{ .password, .otp } },
        .captcha = .{ .provider = .recaptcha_v3 },
        .session = .{ .store = .table, .gc_cron = "30 * * * *" },
    } });
    try std.testing.expectEqual(@as(usize, 2), A.auth_method_types.len);
    try std.testing.expectEqual(app_mod.SessionStore.table, A.session_store_config);
    try std.testing.expectEqualStrings("30 * * * *", A.session_gc_cron);
    try std.testing.expect(A.captcha_provider != null); // pub const on the App struct (framework.zig:893)
}
```

(Adapt the hook literal to the REAL `.auth` hook-group shape — read `events.buildAuthLifecycleDispatcher` and an existing `.auth` test first; the assertion targets are the lowered consts, whose names do not change.)

- [ ] **Step 2: Implement the re-shape in framework.zig.**

1. `allowed` (:277): REMOVE `"auth_methods"`, `"captcha"`, `"session_store"`, `"session_gc_cron"` (keep `"auth"`).
2. In the key-validation loop (:283-289), special-case the moved keys BEFORE the generic unknown-key error:

```zig
            const moved = .{
                .{ "auth_methods", ".auth = .{ .methods = ... }" },
                .{ "captcha", ".auth = .{ .captcha = ... }" },
                .{ "session_store", ".auth = .{ .session = .{ .store = ... } }" },
                .{ "session_gc_cron", ".auth = .{ .session = .{ .gc_cron = ... } }" },
            };
            for (std.meta.fields(@TypeOf(cfg))) |f| {
                inline for (moved) |mv| {
                    if (std.mem.eql(u8, f.name, mv[0]))
                        @compileError("'." ++ mv[0] ++ "' moved in the auth config grouping: use '" ++ mv[1] ++ "'");
                }
                // …existing allowed check…
            }
```

3. Validate `.auth` sub-keys (only `hooks`, `methods`, `captcha`, `session`); if a field matches an old direct hook-group name (`register`/`logout`/`refresh`/`password_change` — copy the exact set from the current `.auth` guard), emit: `".auth hook groups moved under .auth.hooks = .{ ... }"`.
4. Repoint the lowerings: dispatcher guard reads `cfg.auth.hooks` (with the same ≥1-field emptiness rule, :296-300); `auth_method_types` builds from `cfg.auth.methods`; captcha consts read `cfg.auth.captcha`; `session_store_config`/`session_gc_cron` read `cfg.auth.session.store`/`.gc_cron` (same validation messages, updated key paths — including the "gc_cron without .store = .table" guard at :589-590).
5. `registry.assembleTypes`: change its contract to take the methods VALUE, not the whole cfg — `pub fn assembleTypes(comptime methods: anytype) []const type` where `methods` is `null`-like absence handled by the CALLER (framework passes `if (@hasField(…)) cfg.auth.methods else .{}` — pick the cleanest encoding and update registry.zig's own tests to the new signature). Keep the tuple/named-struct dual-form logic from Task 5 intact.

- [ ] **Step 3: Probe every moved key** — temporarily instantiate `App(.{ .auth_methods = … })`, `App(.{ .captcha = … })`, `App(.{ .session_store = .table })`, `App(.{ .auth = .{ .register = … } })`; confirm each pointed message; revert probes with Edit.

- [ ] **Step 4: Sweep consumers.** `grep -rn "auth_methods\|\.captcha\|session_store\|session_gc_cron" src/ fixtures/ examples/ docs/ site/src/content tests/ clients/ | grep -v "col.options\|oauth"` — update every cfg-literal hit: `fixtures/minimal/main.zig` (→ `.auth = .{ .methods = .{ .builtins = .{ .password } } }`), `examples/plugins/src/main.zig` (:~630 `.auth_methods = .{ApiTokenMethod}` → `.auth = .{ .methods = .{ApiTokenMethod} }` — wait: the legacy bare-tuple form now lives at `.auth.methods = .{ApiTokenMethod}`; verify Task 5's dual-form logic still accepts the bare tuple THERE), golfsim/blog if they use any moved key, every doc snippet. NOTE the distinction: collection-level `.options.auth.*` (schema) is UNRELATED — do not touch those hits.

- [ ] **Step 5: Full verification.**

```bash
mise exec zig@0.16.0 -- zig build test --summary all      # green, incl. Task 4/5 gating tests
mise exec zig@0.16.0 -- zig build minimal-server && ./scripts/check-gating.sh   # invariant still holds
(cd examples/blog && mise exec zig@0.16.0 -- zig build) && (cd examples/golfsim && mise exec zig@0.16.0 -- zig build) && (cd examples/plugins && mise exec zig@0.16.0 -- zig build)
mise exec python@3.13 -- python -m pytest tests/admin -q  # full browser suite (final gate)
cd site && mise exec node@24 -- npm run build
```

- [ ] **Step 6: Docs.** framework.md §3: the four rows collapse into one `auth` row ("Auth config group: `.hooks` (lifecycle hooks), `.methods` (built-in set + custom types), `.captcha`, `.session` (`.store`/`.gc_cron`)") — Task 13's parity test forces the table update in both copies; rewrite the §auth-methods/§captcha/§sessions snippets to the grouped spelling; add one line documenting which auth knobs deliberately stay env-only. recipes.md ~:740. Mirrors.

- [ ] **Step 7: Changelog fragment** — `changelog.d/r2-auth-grouping.md`:

```markdown
### Breaking

- Auth config is grouped under one comptime key: `.auth = .{ .hooks, .methods, .captcha, .session = .{ .store, .gc_cron } }`. The old spellings (top-level `.auth_methods`, `.captcha`, `.session_store`, `.session_gc_cron`, and hook groups directly under `.auth`) are pointed compile errors naming the new location. Runtime auth knobs (TTLs, `ZIGBASE_OAUTH_STATE_*`, cookie/rate-limit settings) intentionally remain env-configured.
```

- [ ] **Step 8: Commit + PR**

```bash
git add -A && git commit -m "feat(config)!: group auth config under .auth = .{ .hooks, .methods, .captcha, .session } (E3)"
```

Then open the stream PR (base `main`): title `SP3 R2: gating, config & API consistency retro fixes`; body lists the Breaking items (fragments have the details) and ends with the required Claude Code footer. Verify branch freshness against `origin/main` first (fetch + `git status`), and confirm CI (build, unit, browser, postgres, ts-sdk) is green before `gh pr merge --merge`. A ts-sdk `ListenError` failure is a known port-race flake — rerun that job before treating it as real.

---

## Self-review notes (kept for the executor)

- **Coverage:** R2-1→Task 2; R2-2/R2-3→Task 4; R2-4→Task 5; R2-5→Task 6; invariant test→Task 7; R2-6→Task 8; R2-7(E1)+R2-14(N1)→Task 3; R2-8(E2)→Task 13; R2-9(E4/E7/N6)→Task 9; R2-10(E5)+R2-11(E6)→Task 10; R2-12(E8/E9/E10)→Task 11; R2-13(E11)→Task 1, (E12/N12)→Task 12; R2-15(E3)→Task 14; R2-16→Task 13 (+ the invariant comment in Task 4 and script in Task 7). E13 cross-stream conventions were already sent to the other plan writers (no task here).
- **Deliberately NOT in this plan (triage decisions are final):** OAuth provider camelCase stays (N5 exception documented by auth-2); `migrate-db` rename declined (N13); `.mail` rename (N2) + static grouping (N4) deferred to the next sharpening round; all 11 bikeshed items declined; `ev.putField` declined (YAGNI, noted in Task 11).
- **Known judgment calls an executor may revisit with the reviewer:** (a) Task 6 gates the `"mail"` job kind on `.mailer`-or-`.mail` presence — the triage said "registered only when reachable" without naming the signal; `.mail = .{}` as the enable idiom is this plan's call. (b) Task 4 leaves `/api/state`, `/api/settings`, `/api/features` ungated (tied to the always-present features resolver; the triage scoped R2-3 to analytics/senders/mail-webhook/tenancy/WebAuthn). (c) Task 12 implements N12 as parity-tests-against-code rather than a comptime help renderer (the audit offered both; the test is smaller and catches the same drift).
- **Type-consistency spot-checks done:** `Gates` field names match between Task 4 (definition), Task 5 (derivation), Task 7 (fixture/script); `assembleTypes` forms match between Task 5 and Task 14 Step 2.5's signature change; `{items}`/`nextCursor`/`hasNext` names match records.zig:1214-1216 and Task 9's SDK types; `provision_migrations`/`job_regs`/`route_gates` decl names are consistent across Tasks 3/4/5/6 tests.
