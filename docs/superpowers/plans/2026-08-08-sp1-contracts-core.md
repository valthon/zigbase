# SP-1: Contracts Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a running ZigBase machine-legible to an AI agent — one frozen error-code vocabulary in one error envelope, structured/leveled/JSON logging with no silently swallowed 500s, env-var failures that name the variable, `--json` on the status-like CLI commands, and a `GET /api/meta` capability probe so frozen mode and build flags stop being discoverable only by string-matching a 403.

**Architecture:** A new `src/error_codes.zig` holds a closed `Code` enum whose `@tagName` *is* the wire string, gated by an append-only `src/error-codes.frozen` ledger enforced by embedded Zig tests (the zigapagos `diag-codes.frozen` pattern); every built-in error — canonical `ApiError`, typed-route `jsonError`, `ctx.jsonError`, auth-method failures — renders through the one canonical envelope, which becomes `{status, code, message, data}` (integer `status`, *string* machine `code`). A new `src/logging.zig` provides a pure format core plus a `std.Options.logFn`, re-exported from `root.zig` so the binary and every consumer `main.zig` opt in with one line; request logging and the four swallowed-error sites in `server.zig` route through it and through the existing `events.dispatchError` path. A new `src/api/meta.zig` serves build/config capability facts from `app.gates` + `build_options`, deliberately separate from `/api/health` (liveness) and `/api/state` (per-subject flags).

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0 --`), `@embedFile` ledger + comptime enum reflection, `std.Io.Writer` / `std.debug.lockStderr`, `std.json.Stringify` + `std.json.fmt`, pytest + `urllib.request` for the end-to-end suite.

## Coordination with SP-3 (dev-loop) — read before touching `src/cli.zig`

SP-3 (`serve --background` / `stop` / `status` / `logs` / `doctor` / `serve --ephemeral`) is being planned in parallel and will also edit `src/cli.zig` and `src/framework.zig`'s arg parsing and help text.

- **SP-1 owns the `--json` output conventions** (below). SP-3 follows them; it does not redefine them.
- **Keep CLI plumbing changes additive.** In `src/cli.zig` this plan adds exactly: one `Command` union member (`explain_code`), one `HelpTopic` member (`explain_code`), one new `if (std.mem.eql(u8, args[0], "explain-code"))` block, one `json: bool` field each on `MigrateArgs` and a new `VersionArgs`, and three `ServeArgs` fields (`log_format`, `log_level`, `log_requests`). It renames nothing and reorders nothing.
- In `src/framework.zig`'s `runCliImpl` switch (line 1863) this plan adds exactly one arm (`.explain_code`) and changes the bodies of `.version` and `.migrate .status`. It does not restructure the switch.
- **No ordering dependency on `src/logging.zig`.** SP-3's `serve --background` redirects the *child process's* stdout/stderr into `<data-dir>/serve.log` and tails that file; it never imports `src/logging.zig`, so it inherits whatever `--log-format` produces without a build-order constraint in either direction. (SP-3 lists `serve logs --json` — structured log *events* rather than raw lines — as an explicit follow-up that belongs with this plan's `--log-format=json` work, not with SP-3.)
- **CLI JSON casing is settled as `snake_case`** (convention 7 below), adopting SP-3's argument. SP-3's plan asks for convergence before either ships — this is that answer; no change is needed on SP-3's side. **SP-5 must converge**: its plan currently emits `dryRun`/`errorLog`/`baseUrl`/`deferredRelations` on stdout and has been corrected to `snake_case`. SP-5's *file* formats (the schema document, the import manifest, the replay capture) stay `camelCase` because they mirror REST/engine payload keys verbatim.

## Global Constraints

- Toolchain: Zig **0.16.0** only. Every Zig command is prefixed `mise exec zig@0.16.0 --` (e.g. `mise exec zig@0.16.0 -- zig build`). Another 0.16.x is not guaranteed to work.
- Unit tests: `mise exec zig@0.16.0 -- zig build test --summary all`. **The authoritative signal is the `Build Summary: N/N tests passed` line** — `zig build test` prints a spurious `failed command: …` line even on success. There is no per-test filter wired into `build.zig`.
- **Any new `src/*.zig` file's tests do not run until the file is added to `src/root.zig`'s `test { _ = @import(…); }` block** (block spans root.zig:331-541). This plan creates three: `src/logging.zig`, `src/error_codes.zig`, `src/api/meta.zig`. Each has an explicit registration step.
- Browser/e2e suite: `mise exec python@3.13 -- python -m pytest tests/admin -q -n auto` (parallel-safe). A green `zig build test` has repeatedly hidden regressions this suite catches — every task touching HTTP responses, CLI stdout, or logging runs its `tests/admin/` subset.
- **Changelog:** never edit `CHANGELOG.md`. Each task adds/extends its own `changelog.d/<slug>.md` fragment with `### <Section>` headings from the recognized set (Breaking, Features, Fixes, Changed, Performance, Deprecated, Removed, Security, Internal). One fragment per task keeps parallel PRs conflict-free.
- **Docs sync — a new `docs/*.md` needs FOUR coordinated edits**, not one; miss any and it silently never publishes. `site/src/content/docs/` is a **generated, gitignored mirror** — never hand-edit it. The four edits are: (1) an entry in `site/scripts/docs-registry.json`; (2) the slug added to the hardcoded `PUBLISHED` set in `site/scripts/gen-docs-mirror.mjs` (otherwise inbound cross-links degrade to GitHub blob URLs); (3) a line under the generated block in `site/.gitignore`; (4) an entry in `site/src/config/sidebar.ts`. SP-2 Task 14 adds `tests/admin/test_docs_parity.py` assertions that **fail the build** on any of the four being missed, so this is enforced, not advisory. After doc changes run `cd site && npm run build`.
- **Docs-parity gate:** `tests/admin/test_docs_parity.py` greps every `"ZIGBASE_[A-Z0-9_]+"` string literal under `src/` and requires each to appear (a) in `README.md` and (b) inside `src/framework.zig`'s `ENVIRONMENT VARIABLES:` block (framework.zig:1990-2064, before the `EXAMPLES:` anchor) — or in its `ENV_ALLOWLIST`. Every new env var updates all three.
- **NO_SLOP bar** (`NO_SLOP.md`): explicit allocators, `defer`/`errdefer` on every allocation, errors as values, no hidden control flow, disciplined comptime. Pure formatting cores separated from I/O shells so they are byte-exactly testable (the `src/report/log.zig` `formatLine`/`emit` split is the house pattern to copy).
- **Error-path/ownership audit before every commit:** trace every error and OOM path between an allocation and its ownership handoff.
- TDD throughout: every task writes a failing test, runs it to see it fail, writes the minimal implementation, runs it to see it pass, then commits.

### Shared output conventions (SP-1 defines these; all sub-projects follow)

1. **One object, one stream — and exactly two stdout shapes.** A command's `--json` stdout is *either* a **single result object** *or* a **findings stream**, never a mix:
   - **Single-result commands** (`version`, `migrate status`, `explain-code`, `schema dump`, `schema apply`, `import`, `serve status`, `serve --ephemeral`) write **exactly one JSON object to stdout and nothing else on stdout**. List-shaped output is wrapped in an object (`{"codes":[…]}`) — never a bare array, never two objects.
   - **Findings-stream commands** (`doctor`) write **NDJSON findings on stdout, one per line, terminated by exactly one summary object** carrying a self-identifying discriminator (`"summary":true`) so a consumer that skips a line can still find it by content rather than position. A findings stream may instead be written to a file named by a flag (`--error-log`, `--out`), in which case stdout carries only the single summary object — that is SP-5's shape and is equally sanctioned.
   In both shapes, prose, warnings, progress, and log records go to **stderr**.
2. **Exit codes are meaningful, and the scheme is program-wide and frozen.** SP-5 states the same four codes; they are one contract, not two:
   - `0` — success, or the thing being reported is OK (including a dry run whose findings need no judgment).
   - `1` — the command failed **or** reported a not-OK condition the caller must act on: bad input or a usage error (a bad flag is already exit 1 today, via the parser's returned error), a refused operation, an I/O or DB error, `migrate status` with anything pending or orphaned, `doctor` with at least one `error` finding, `serve status` with nothing running, `explain-code` on an unregistered code.
   - `2` — the command **ran correctly and found a condition requiring judgment** (`doctor` whose worst finding is a `warning`, with no `error`; `schema apply --dry-run` found destructive changes; `replay` found parity failures). Never used for a usage error — an agent must be able to distinguish "escalate to a human" from "the tool broke".
   - `3` — the command completed but **lost data or skipped work** (`import --continue-on-error` skipped at least one row).
   A command that only *reports* still uses these codes so it can gate a shell script.
3. **Streaming diagnostics are NDJSON** — one JSON object per line. A *findings* stream goes to stdout or to a `--*-log`/`--out` file per convention 1; incidental *diagnostics* that accompany another primary output (log records, progress) go to **stderr**. Consumers **must skip any line that does not parse as JSON and must never fail the run because of it** (a panic message, a linker warning, or a subprocess's own output can appear on the same stream). Document this wherever NDJSON is produced.
4. **Machine-readable ids are frozen.** Once shipped, an error `code` (and later, a doctor check id) is permanent: append-only ledger plus a test. Renaming is a removal plus an addition and breaks consumers silently.
5. **`message` is never contract.** Match on `code`, never on message text. Say this in the docs next to every code.
6. **JSON field order is stable per struct.** `std.json.Stringify` emits struct fields in declaration order and `std.json.ObjectMap` preserves insertion order; this plan declares that order part of the contract and pins it with exact-bytes tests. Reordering a struct's fields is a wire change.
7. **Two planes, two casings — `snake_case` for CLI JSON, `camelCase` for HTTP JSON.** SP-3 raised this (its `serve status --json` mirrors zigapagos's lockfile field names verbatim per program decision #8, e.g. `started_at`, `data_dir`), and SP-1 adopts it: `zigbase version --json`, `migrate status --json`, and `explain-code --json` all emit `snake_case`. The REST API is a different plane and keeps its existing `camelCase` — `GET /api/health` already ships `sqliteVec`, so `/api/meta` matches it. Never mix the two within one object.

## Design decisions (made during research — implement these, do not re-litigate)

**D1 — Logging: one custom `logFn`, not scoped loggers.** The tree today has *no* logging configuration at all: no `std_options`, no `logFn`, no level, and zap's listener is constructed with `.log = false` (server.zig:216), so there are zero request logs. Scoped loggers cannot give us runtime level filtering or a text→JSON switch, and they would not capture the `std.log.warn` calls already scattered through the framework and consumer hooks. A `std.Options.logFn` is the only mechanism that sees every log call. `src/root.zig` re-exports `pub const std_options` so `src/main.zig` and every consumer `main.zig` opt in with one line (a Zig binary's `std_options` must be declared in *its own* root, so this cannot be done for them).

**D2 — Request logging bypasses `std.log`.** A `logFn` only ever sees an already-formatted string, so routing request records through `std.log` would cram method/path/status into one `msg` string — useless to an agent. `logging.request(rec)` writes the structured record directly, sharing the same stderr lock, level gate, and format switch. Placed in `server.onRequest` (not in the socketless `route` seam) so it measures true wall time and does not pollute the in-process test harness.

**D3 — The ledger file is `src/error-codes.frozen`,** `@embedFile`-d by `src/error_codes.zig`, in the zigapagos `src/diag-codes.frozen` format: `#` comments, an `[ACTIVE]` section and a `[RETIRED]` section, one code per line, alphabetically sorted. Four Zig tests enforce it (every enum field is ACTIVE; every ACTIVE line is an enum field; no enum field matches a RETIRED line; ACTIVE is sorted and duplicate-free) plus a fifth requiring every code to carry a non-empty summary and explanation. The frozen file lives beside the `.zig` because `@embedFile` resolves relative to the importing file.

**D4 — Codes are compile-checked for ZigBase, open for consumers.** `FieldError.code` and the new `ApiError.code` stay `[]const u8`. Built-in sites write `codes.s(.validation_min)` — an inline function returning `@tagName`, so a typo'd tag is a *compile error* checked against the ledger — while `ctx.invalid` and `ctx.jsonError` keep accepting a raw string, which is a documented consumer capability (`docs/framework.md:1599-1604` shows `.code = "invalid"`). A pytest gate asserts no raw `"validation_…"` literal survives anywhere in `src/` outside `error_codes.zig` **and `api/error.zig`** (the latter keeps them inside expected-JSON byte literals in its tests, which a text grep cannot distinguish from a real assignment), so new built-in codes cannot bypass the ledger. Keeping the field type unchanged also means the ~200 `ApiError.notFound()`/`badRequest()` call sites need no edit: the constructors carry the codes.

**D5 — The envelope becomes `{status, code, message, data}`.** Today `code` is the integer HTTP status while `data.<field>.code` is a *string* machine code — the same key name meaning two different things, and no top-level machine code at all. Unifying: `status` is the integer, `code` is the frozen string. This makes "match on `code`, never `message`" literally true for the field named `code` at both levels. Blast radius is server-side only and fully enumerated: all four SDKs read only `message` and `data` and never touch `code` (`clients/typescript/src/errors.ts:34-48`, `clients/dart/lib/src/errors.dart:46-84`, `clients/python/src/zigbase/errors.py:55-93`, `clients/kotlin/…/errors/Errors.kt:52-90`), the admin SPA and all three example frontends read `message` only, and no SDK test asserts the shape. Exactly one pytest (`tests/admin/test_realtime.py:146`), two Zig string tests (`src/api/error.zig:67,77`), and four hard-coded raw literals (`src/ctx.zig:46`, `src/server.zig:318,349,355`) pin the old bytes; Task 2 updates all seven. Pre-1.0, so this is a Breaking fragment, not a compatibility shim.

**D6 — `/api/meta` is a new endpoint, not an extension of `/api/health` or `/api/state`.** Three endpoints, three jobs: `/api/health` is a liveness probe hit every few seconds by Docker/k8s and must stay small and cheap; `/api/state` is the *per-subject, DB-backed, cache-fed* feature-flag projection (`src/api/state.zig` takes a pooled reader and resolves sticky experiment assignments); `/api/meta` is *build-and-config* facts that are constant for the process lifetime, need no DB, no subject, and no cache. Merging any pair would couple unrelated cache semantics. Reconciliation with `/api/state` is documentation plus a cross-link in `/api/meta`'s `endpoints.state`, not a merge. **Security invariant for `/api/meta`: it exposes only facts an unauthenticated client can already establish by probing** — each capability bool corresponds to a route group that already 404s or 200s to anonymous requests, `collectionsFrozen` is already readable from the 403 at `src/api/collections.zig:63-69`, and `maxUploadSize` is already discoverable by uploading. No config value, path, credential, or connection string is ever added.

**D7 — Env parse failures fail fast with an out-param diagnostic; unknown vars warn.** `Config.load` is a pure loader taking a duck-typed getter, and its tests use stub getters — so the failure detail rides an out-param (`Config.loadDiag(getter, *LoadDiag)`) rather than a log line, keeping the exact message unit-testable. Parse errors abort boot (the house "fail fast at boot with actionable errors" philosophy). Unknown `ZIGBASE_*` variables only **warn**: the repo's own harnesses set `ZIGBASE_TEST_BINARY` and `ZIGBASE_PG_TEST_URL`, and a `ZIGBASE_FIELD_KEY_V<n>` is a templated name, so hard-failing would break existing setups.

---

### Task 1: The frozen error-code registry

**Files:**
- Create: `src/error_codes.zig`, `src/error-codes.frozen`
- Modify: `src/root.zig` (public re-export near the other `pub const` exports; test-block entry before the `if (@import("build_options").postgres)` guard at ~line 520)
- Create: `changelog.d/error-code-ledger.md`

**Interfaces:**
- Produces: `pub const Code = enum { … }`, `pub const Info = struct { summary: []const u8, explanation: []const u8 }`, `pub fn info(c: Code) Info`, `pub inline fn s(c: Code) []const u8`, `pub fn parse(text: []const u8) ?Code`, `pub fn forStatus(status: u16) Code`
- Consumed by: Task 2 (`src/api/error.zig`, `src/records.zig`, `src/schema.zig`, `src/api/collections.zig`, `src/route_types.zig`, `src/ctx.zig`), Task 3 (`explain-code`)

**The code set — 37 codes.** Enumerate the current field-level vocabulary with `grep -rho '"validation_[a-z0-9_]*"' src/ | sort -u` (27 distinct today). Ten top-level envelope codes join them: one per `ApiError` constructor, plus the frozen-collections case and the auth rate-limit case that Task 2 needs:

| Code | Emitted by | Summary (one line, no trailing period) |
|---|---|---|
| `bad_request` | `ApiError.badRequest` | the request was malformed or semantically invalid |
| `collections_frozen` | `api/collections.zig` `rejectIfFrozen` | runtime collection DDL is disabled by `.collections_frozen` |
| `conflict` | `ApiError.conflict` | the request conflicts with the current state of the resource |
| `forbidden` | `ApiError.forbidden` | the caller is authenticated but not permitted |
| `gone` | `ApiError.gone` | the resource existed but is no longer available (e.g. an expired cursor) |
| `internal` | `ApiError.internal` | an unexpected server-side failure; no detail is leaked |
| `not_found` | `ApiError.notFound` | no such resource, or the caller may not know whether it exists |
| `too_many_requests` | `auth/methods/otp.zig`, the auth rate limiter | the caller exceeded a rate limit and should back off |
| `unauthorized` | `ApiError.unauthorized` | no valid credentials were presented |
| `validation_failed` | `ApiError.validation` | one or more fields failed validation; see `data` |

The 27 field-level codes keep their exact current spellings. Their emitting sites are `src/records.zig` (43 references), `src/schema.zig` (39), `src/api/collections.zig` (4) — read each site's `.message` to write its summary. (`src/api/error.zig` holds 2 more, both inside test byte-expectations, not emission sites.) For reference, the value-coercion mapping at `src/records.zig:369-373` is `error.TooPrecise → validation_too_precise`, `error.TypeMismatch → validation_type`, `error.Overflow → validation_overflow`, `error.BadNumber → validation_number`, everything else `→ validation_value`.

**Steps:**

- [ ] Write `src/error-codes.frozen`. `[ACTIVE]` holds all 37 codes, one per line, **alphabetically sorted**; `[RETIRED]` starts empty:

```
# Frozen error-code registry (SP-1). THIS FILE IS THE STABILITY CONTRACT.
#
# A code, once shipped, is permanent. Agents and SDKs switch on these strings;
# the `message` field is NOT contract and may be reworded at any time.
#
#  * To ADD a code: add the enum field in src/error_codes.zig AND append a line
#    to ACTIVE, keeping the section alphabetical.
#  * To STOP emitting a code: MOVE its line from ACTIVE to RETIRED and delete
#    the enum field. The line never disappears.
#  * NEVER reuse a retired name for a different meaning, and NEVER rename a
#    code — that is a removal plus an addition, and consumers break silently.
#
# The `test "error_codes: …"` blocks in src/error_codes.zig enforce all of the
# above; `zigbase explain-code` is the human/agent-facing view.

[ACTIVE]
bad_request
collections_frozen
conflict
forbidden
gone
internal
not_found
too_many_requests
unauthorized
validation_date
validation_duplicate_name
validation_encrypted_index
validation_encrypted_type
validation_encrypted_unique
validation_failed
validation_invalid_email
validation_invalid_identity_field
validation_invalid_name
validation_invalid_scale
validation_invalid_tenant_field
validation_invalid_ttl_field
validation_max
validation_min
validation_not_found
validation_number
validation_overflow
validation_pattern
validation_relation
validation_required
validation_reserved_name
validation_reserved_suffix
validation_searchable_encrypted
validation_searchable_type
validation_select
validation_too_precise
validation_type
validation_value

[RETIRED]
```

- [ ] Write the failing ledger tests first. Create `src/error_codes.zig` with **only** the enum (all 37 fields, same order as the file), the `@embedFile`, the two helpers, and the seven tests below — no `info` yet, so the "documented" test fails to compile against a missing `info`:

```zig
const std = @import("std");

/// The frozen error-code registry. A tag name here IS the wire string emitted as
/// the envelope's `code` (and as a field error's `code`), so `@tagName` needs no
/// mapping table. See `src/error-codes.frozen` for the stability contract.
///
/// `message` text is explicitly NOT contract — consumers match on these codes.
pub const Code = enum {
    // top-level envelope codes (one per ApiError constructor)
    bad_request,
    collections_frozen,
    conflict,
    forbidden,
    gone,
    internal,
    not_found,
    too_many_requests,
    unauthorized,
    validation_failed,
    // field-level codes (emitted into `data.<field>.code`)
    validation_date,
    validation_duplicate_name,
    validation_encrypted_index,
    validation_encrypted_type,
    validation_encrypted_unique,
    validation_invalid_email,
    validation_invalid_identity_field,
    validation_invalid_name,
    validation_invalid_scale,
    validation_invalid_tenant_field,
    validation_invalid_ttl_field,
    validation_max,
    validation_min,
    validation_not_found,
    validation_number,
    validation_overflow,
    validation_pattern,
    validation_relation,
    validation_required,
    validation_reserved_name,
    validation_reserved_suffix,
    validation_searchable_encrypted,
    validation_searchable_type,
    validation_select,
    validation_too_precise,
    validation_type,
    validation_value,
};

/// The wire string for `c`. Built-in emission sites call this instead of writing
/// a raw literal, so a typo is a COMPILE error checked against the frozen ledger.
/// Consumer code (`ctx.invalid`, `ctx.jsonError`) may still pass its own string —
/// ZigBase never assigns meaning to a code it did not register.
pub inline fn s(c: Code) []const u8 {
    return @tagName(c);
}

/// Parse a wire string back into a registered `Code`; null for anything unregistered.
pub fn parse(text: []const u8) ?Code {
    return std.meta.stringToEnum(Code, text);
}

const frozen = @embedFile("error-codes.frozen");

fn frozenSection(comptime header: []const u8) []const u8 {
    const start_marker = "[" ++ header ++ "]";
    const start = std.mem.indexOf(u8, frozen, start_marker).? + start_marker.len;
    const rest = frozen[start..];
    const end = std.mem.indexOf(u8, rest, "\n[") orelse rest.len;
    return rest[0..end];
}

/// Split a `[SECTION]` slice into its non-blank, non-comment lines. The returned
/// list owns its backing array — the caller must `deinit(gpa)` it. The elements
/// are NOT owned: they are slices into the comptime `@embedFile` data, which
/// outlives every caller. `errdefer` covers a partial list on append failure.
fn frozenLines(section: []const u8, gpa: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, section, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try list.append(gpa, line);
    }
    return list;
}

test "error_codes: every Code appears in error-codes.frozen [ACTIVE]" {
    const gpa = std.testing.allocator;
    var active = try frozenLines(frozenSection("ACTIVE"), gpa);
    defer active.deinit(gpa);
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        var found = false;
        for (active.items) |line| {
            if (std.mem.eql(u8, line, field.name)) {
                found = true;
                break;
            }
        }
        if (!found) std.debug.print("Code.{s} has no matching line in [ACTIVE]\n", .{field.name});
        try std.testing.expect(found);
    }
}

test "error_codes: every [ACTIVE] line is a Code" {
    const gpa = std.testing.allocator;
    var active = try frozenLines(frozenSection("ACTIVE"), gpa);
    defer active.deinit(gpa);
    for (active.items) |line| {
        const matched = parse(line) != null;
        if (!matched) std.debug.print("[ACTIVE] line '{s}' matches no Code field\n", .{line});
        try std.testing.expect(matched);
    }
}

test "error_codes: no Code reuses a [RETIRED] name" {
    const gpa = std.testing.allocator;
    var retired = try frozenLines(frozenSection("RETIRED"), gpa);
    defer retired.deinit(gpa);
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        for (retired.items) |line| {
            if (std.mem.eql(u8, line, field.name)) {
                std.debug.print("Code.{s} reuses a RETIRED name — pick a new one\n", .{field.name});
                try std.testing.expect(false);
            }
        }
    }
}

test "error_codes: [ACTIVE] is alphabetically sorted with no duplicates" {
    const gpa = std.testing.allocator;
    var active = try frozenLines(frozenSection("ACTIVE"), gpa);
    defer active.deinit(gpa);
    for (active.items[1..], 1..) |line, i| {
        const prev = active.items[i - 1];
        if (std.mem.eql(u8, prev, line)) {
            std.debug.print("[ACTIVE] duplicate line '{s}'\n", .{line});
            try std.testing.expect(false);
        }
        if (std.mem.order(u8, prev, line) != .lt) {
            std.debug.print("[ACTIVE] not sorted: '{s}' should follow '{s}'\n", .{ prev, line });
            try std.testing.expect(false);
        }
    }
}

test "error_codes: every Code has a non-empty summary and explanation" {
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        const i = info(@as(Code, @enumFromInt(field.value)));
        try std.testing.expect(i.summary.len > 0);
        try std.testing.expect(i.explanation.len > 0);
    }
}

test "error_codes: s() round-trips through parse()" {
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        const c: Code = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(?Code, c), parse(s(c)));
    }
    try std.testing.expectEqual(@as(?Code, null), parse("definitely_not_a_code"));
}

test "error_codes: forStatus maps every constructor's status" {
    try std.testing.expectEqual(Code.bad_request, forStatus(400));
    try std.testing.expectEqual(Code.unauthorized, forStatus(401));
    try std.testing.expectEqual(Code.forbidden, forStatus(403));
    try std.testing.expectEqual(Code.not_found, forStatus(404));
    try std.testing.expectEqual(Code.conflict, forStatus(409));
    try std.testing.expectEqual(Code.gone, forStatus(410));
    try std.testing.expectEqual(Code.too_many_requests, forStatus(429));
    // Anything unmapped — including every 5xx — is `internal`, never a guess.
    try std.testing.expectEqual(Code.internal, forStatus(500));
    try std.testing.expectEqual(Code.internal, forStatus(418));
}
```

- [ ] Register the new file in `src/root.zig`'s test block so these tests run at all — add `_ = @import("error_codes.zig");` immediately before the `if (@import("build_options").postgres) {` guard (~root.zig:520). Also add the public re-export beside the other `pub const` exports:

```zig
/// The frozen error-code registry (`code` in the API error envelope and in each
/// `data.<field>` entry). Match on these; never on `message`.
pub const error_codes = @import("error_codes.zig");
pub const ErrorCode = error_codes.Code;
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all`. **Expected failure:** a compile error — `error: use of undeclared identifier 'info'` (and `'forStatus'`) from the last three tests. That is the RED state.

- [ ] Add `Info`, the exhaustive `info` switch, and `forStatus`. Write one arm per code following the two real arms below; because the switch has **no `else`**, the compiler enumerates every missing arm for you — that is the enforcement, not a checklist to maintain by hand. Each summary comes from the table above / the emitting site's `.message`; each explanation says what condition produced it and what the caller should change:

```zig
pub const Info = struct {
    /// One line, no trailing period. Shown by `zigbase explain-code` with no argument.
    summary: []const u8,
    /// The long form: what produced this code and what the caller should change.
    /// May be multi-line.
    explanation: []const u8,
};

/// Exhaustive on purpose: no `else` arm. A new `Code` field without a matching arm
/// here is a COMPILE ERROR — that is the whole enforcement behind "every registered
/// code is documented".
pub fn info(c: Code) Info {
    return switch (c) {
        .collections_frozen => .{
            .summary = "runtime collection DDL is disabled by `.collections_frozen`",
            .explanation =
            \\This deployment was built with `App(.{ .collections_frozen = true })`,
            \\so POST/PATCH/DELETE on /api/collections are categorically rejected —
            \\schema evolves through a `.migrations` entry plus a redeploy, not over
            \\REST. Reads (GET /api/collections) still work.
            \\
            \\Detect this BEFORE attempting DDL: GET /api/meta reports
            \\`capabilities.collectionsFrozen`. Never string-match this response's
            \\message text.
            ,
        },
        .validation_min => .{
            .summary = "a value is below the field's minimum, or shorter than its minimum length",
            .explanation =
            \\Emitted for both numeric `min` and string/length `min` constraints on a
            \\field — the accompanying message distinguishes them. Send a value that
            \\satisfies the constraint declared on the collection's field.
            \\
            \\Read the current constraint from GET /api/collections/<name>.
            ,
        },
        // …one arm per remaining Code. The compiler lists whatever is still missing.
    };
}

/// The envelope code for a bare HTTP status, used where an error reaches the
/// renderer without one (e.g. `ctx.fail(status, message)`). Deliberately
/// conservative: anything unmapped is `internal`, never an invented code.
pub fn forStatus(status: u16) Code {
    return switch (status) {
        400 => .bad_request,
        401 => .unauthorized,
        403 => .forbidden,
        404 => .not_found,
        409 => .conflict,
        410 => .gone,
        429 => .too_many_requests,
        else => .internal,
    };
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` and confirm the `Build Summary: N/N tests passed` line, with N seven higher than the pre-task baseline (record the baseline before starting).
- [ ] Prove the ledger gate actually bites: temporarily append `zz_bogus_code,` to the `Code` enum, run the suite, and confirm **both** `every Code appears in … [ACTIVE]` and `every Code has a non-empty summary` fail. **Revert with `Edit`, never `git checkout`** — a `git checkout <file>` in a shared worktree can discard unrelated work.
- [ ] Write `changelog.d/error-code-ledger.md`:

```markdown
### Features

- Error codes are now a frozen, documented registry (`src/error-codes.frozen`): every code ZigBase emits — the nine top-level envelope codes and the 27 field-level `validation_*` codes — is append-only and permanent, enforced by tests. Match on `code`; `message` text is explicitly not part of the contract and may be reworded at any time.
```

- [ ] Commit: `git commit -am "feat(errors): frozen, documented error-code registry"`

---

### Task 2: One error envelope — `{status, code, message, data}`

**Files:**
- Modify: `src/api/error.zig` (the whole `ApiError` + `renderBody` + both tests), `src/route_types.zig:240-251`, `src/ctx.zig:44-49` and `:705-720` and `:2281-2282` and the doc comments at `:494-495`, `src/server.zig:318,349,355`, `src/records.zig` (41 code literals), `src/schema.zig` (39), `src/api/collections.zig` (4 literals + `rejectIfFrozen` at :63-69), `src/auth/methods/oauth2.zig:44,47,50,55,60`, `src/auth/methods/webauthn.zig:62,67`, `src/auth/methods/otp.zig:70`, `src/auth/methods/magic_link.zig:47`
- Modify: `tests/admin/test_realtime.py:146`, `docs/api.md:22-35`, `docs/framework.md:471-473` and `:1360-1362,1401`
- Create: `changelog.d/error-envelope-unification.md`

**Interfaces:**
- Consumes: `error_codes.Code`, `error_codes.s`, `error_codes.forStatus` (Task 1)
- Produces: `ApiError{ status: u16, code: []const u8 = codes.s(.internal), message: []const u8, fields: []const FieldError = &.{} }`, `pub fn withCode(status: u16, code: Code, message: []const u8) ApiError`, unchanged `renderBody(alloc) ![]u8` / `toResponse(alloc) !http.Response`; `Ctx.jsonError(self: *Ctx, status: u16, code: []const u8, message: []const u8) !http_mod.Response` (signature change: gains `message`)

**Wire change.** Before: `{"code":404,"message":"Not found.","data":{}}`. After: `{"status":404,"code":"not_found","message":"Not found.","data":{}}`. Field order is declaration order and is contract (convention 6).

**Steps:**

- [ ] Rewrite the two tests in `src/api/error.zig` to the new bytes, and add the two new cases. This is the RED step — the tests fail against the current renderer:

```zig
test "renders empty-data envelope with a machine code" {
    const body = try ApiError.notFound().renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"status\":404,\"code\":\"not_found\",\"message\":\"Not found.\",\"data\":{}}",
        body,
    );
}

test "renders validation field errors under validation_failed" {
    const fields = [_]FieldError{.{ .field = "name", .code = codes.s(.validation_invalid_name), .message = "Invalid." }};
    const body = try ApiError.validation(&fields).renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"status\":400,\"code\":\"validation_failed\",\"message\":\"Failed to validate the request.\"," ++
            "\"data\":{\"name\":{\"code\":\"validation_invalid_name\",\"message\":\"Invalid.\"}}}",
        body,
    );
}

test "withCode carries a specific registered code at the same status" {
    const e = ApiError.withCode(403, .collections_frozen, "Collections are frozen.");
    const body = try e.renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"status\":403,\"code\":\"collections_frozen\",\"message\":\"Collections are frozen.\",\"data\":{}}",
        body,
    );
}

test "every constructor emits a registered code" {
    // A built-in error must never ship a code that is not in the frozen ledger.
    const cases = [_]ApiError{
        ApiError.notFound(),        ApiError.internal(),
        ApiError.badRequest("x"),   ApiError.conflict("x"),
        ApiError.gone("x"),         ApiError.validation(&.{}),
        ApiError.forbidden(),       ApiError.unauthorized(),
    };
    for (cases) |e| try std.testing.expect(codes.parse(e.code) != null);
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all`. **Expected failure:** the two rewritten tests fail with `expected …"status":404…, found …"code":404…`, and `withCode` is an undeclared identifier.

- [ ] Implement in `src/api/error.zig` — add the import, the `code` field, `withCode`, per-constructor codes, and the new `renderBody` key order:

```zig
const codes = @import("../error_codes.zig");

pub const FieldError = struct { field: []const u8, code: []const u8, message: []const u8 };

/// A renderable API error. Envelope: {status, code, message, data:{<field>:{code,message}}}.
///
/// `status` is the integer HTTP status; `code` is a FROZEN machine string from
/// `error_codes.Code` (or a consumer-supplied string via `ctx.jsonError`). Clients
/// match on `code` — `message` is human text and is explicitly not contract.
pub const ApiError = struct {
    status: u16,
    code: []const u8 = codes.s(.internal),
    message: []const u8,
    fields: []const FieldError = &.{},

    /// A specific registered code at an arbitrary status, for sites that carry more
    /// meaning than the generic per-status constructors below (e.g. collections_frozen).
    pub fn withCode(status: u16, code: codes.Code, message: []const u8) ApiError {
        return .{ .status = status, .code = codes.s(code), .message = message };
    }

    pub fn notFound() ApiError {
        return .{ .status = 404, .code = codes.s(.not_found), .message = "Not found." };
    }
    pub fn internal() ApiError {
        return .{ .status = 500, .code = codes.s(.internal), .message = "Something went wrong." };
    }
    pub fn badRequest(message: []const u8) ApiError {
        return .{ .status = 400, .code = codes.s(.bad_request), .message = message };
    }
    pub fn conflict(message: []const u8) ApiError {
        return .{ .status = 409, .code = codes.s(.conflict), .message = message };
    }
    /// 410 Gone — the resource existed but is no longer available (e.g. an expired cursor).
    pub fn gone(message: []const u8) ApiError {
        return .{ .status = 410, .code = codes.s(.gone), .message = message };
    }
    pub fn validation(fields: []const FieldError) ApiError {
        return .{ .status = 400, .code = codes.s(.validation_failed), .message = "Failed to validate the request.", .fields = fields };
    }
    pub fn forbidden() ApiError {
        return .{ .status = 403, .code = codes.s(.forbidden), .message = "Forbidden." };
    }
    pub fn unauthorized() ApiError {
        return .{ .status = 401, .code = codes.s(.unauthorized), .message = "Unauthorized." };
    }

    pub fn renderBody(self: ApiError, alloc: std.mem.Allocator) ![]u8 {
        // Build the ObjectMap tree in a temporary arena; serialize into `alloc`.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        var data: std.json.ObjectMap = .empty;
        for (self.fields) |fe| {
            var fo: std.json.ObjectMap = .empty;
            try fo.put(aa, "code", .{ .string = fe.code });
            try fo.put(aa, "message", .{ .string = fe.message });
            try data.put(aa, fe.field, .{ .object = fo });
        }
        // Insertion order IS the wire order (ObjectMap preserves it) and is contract.
        var root: std.json.ObjectMap = .empty;
        try root.put(aa, "status", .{ .integer = @intCast(self.status) });
        try root.put(aa, "code", .{ .string = self.code });
        try root.put(aa, "message", .{ .string = self.message });
        try root.put(aa, "data", .{ .object = data });
        return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
    }
    // toResponse unchanged.
};
```

- [ ] Run the suite; the four `src/api/error.zig` tests pass. Other suites now fail on the changed bytes — that is expected and is the next step's work.

- [ ] Update the four hard-coded raw envelopes so a rendering-OOM fallback stays byte-identical to what `renderBody` produces. `src/ctx.zig:44-49`:

```zig
/// Allocation-free last-resort 500 for the error path when even rendering the error envelope
/// fails (OOM). Byte-for-byte the envelope `ApiError.internal().renderBody` produces, so a client
/// or SDK parsing the `{status,code,message,data}` shape sees the same body it would on any other 500.
const static_internal_response = http_mod.Response{
    .status = 500,
    .body = "{\"status\":500,\"code\":\"internal\",\"message\":\"Something went wrong.\",\"data\":{}}",
};
```

and in `src/server.zig` replace the three literals — `:318` (`sendRawEnvelope(r, 500, …)`) with `"{\"status\":500,\"code\":\"internal\",\"message\":\"Something went wrong.\",\"data\":{}}"`, and `:349` and `:355` (`sendRawEnvelope(r, 404, …)`) with `"{\"status\":404,\"code\":\"not_found\",\"message\":\"Not found.\",\"data\":{}}"`.

- [ ] Add a drift guard so those four literals can never silently diverge again — append to `src/api/error.zig`:

```zig
test "the hard-coded raw fallback envelopes match renderBody byte-for-byte" {
    // ctx.zig's static_internal_response and server.zig's sendRawEnvelope literals are
    // allocation-free copies for the OOM path. If renderBody's shape changes and they
    // don't, a client sees two different 500 bodies. Pin them here.
    const internal_body = try ApiError.internal().renderBody(std.testing.allocator);
    defer std.testing.allocator.free(internal_body);
    try std.testing.expectEqualStrings(
        "{\"status\":500,\"code\":\"internal\",\"message\":\"Something went wrong.\",\"data\":{}}",
        internal_body,
    );
    const nf_body = try ApiError.notFound().renderBody(std.testing.allocator);
    defer std.testing.allocator.free(nf_body);
    try std.testing.expectEqualStrings(
        "{\"status\":404,\"code\":\"not_found\",\"message\":\"Not found.\",\"data\":{}}",
        nf_body,
    );
}
```

- [ ] Convert every built-in field-code literal to the compile-checked helper. In `src/records.zig`, `src/schema.zig`, and `src/api/collections.zig` add `const codes = @import("error_codes.zig");` (or `"../error_codes.zig"`) and rewrite each `.code = "validation_x"` as `.code = codes.s(.validation_x)`. Mechanical, but verify afterwards that the tree is clean:

```sh
grep -rn '"validation_' src/ | grep -v 'src/error_codes.zig' | grep -v 'src/api/error.zig'
```

**Expected output: nothing.** Two files are excluded on purpose and must stay excluded: `src/error_codes.zig` owns the vocabulary, and `src/api/error.zig` legitimately keeps `validation_*` inside `expectEqualStrings` *byte-expectation* literals (grep cannot tell `\"validation_failed\"` inside an expected-JSON string from a real `.code =` assignment). Note the emitting sites are not all `.code = "…"` — `src/records.zig:369-373` is a bare `switch` returning the literals directly — so the gate has to be the file-scoped grep above rather than a pattern match on `.code =`. Update that coercion mapping to return `codes.s(.validation_too_precise)` etc.

- [ ] Give the frozen-collections 403 its own code — `src/api/collections.zig:63-69`:

```zig
fn rejectIfFrozen(ctx: *http.RequestCtx, app: *app_mod.App) !?http.Response {
    if (!app.collections_frozen) return null;
    return try ApiError.withCode(
        403,
        .collections_frozen,
        "Collections are frozen (`.collections_frozen`); schema changes require a migration and a redeploy.",
    ).toResponse(ctx.allocator.a);
}
```

Strengthen the existing test at `src/api/collections.zig:244` — it currently only asserts the substring `"collections_frozen"` appears somewhere in the body, which the *message* already satisfied, so it never proved a code was emitted (see the house rule: read *why* a test passes). Replace that assertion with one that parses the body and checks the `code` field:

```zig
    // Discriminating: the machine code, not an incidental substring of the message.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, res.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("collections_frozen", parsed.value.object.get("code").?.string);
    try std.testing.expectEqual(@as(i64, 403), parsed.value.object.get("status").?.integer);
```

- [ ] Fold the typed-route envelope (B) into the canonical one — `src/route_types.zig:240-251`:

```zig
const ApiError = @import("api/error.zig").ApiError;
const codes = @import("error_codes.zig");

/// 400 with the canonical error envelope; falls back to a static body if alloc fails.
fn badRequest(a: std.mem.Allocator, msg: []const u8) @import("http.zig").Response {
    return jsonError(a, 400, msg) catch .{
        .status = 400,
        .body = "{\"status\":400,\"code\":\"bad_request\",\"message\":\"Bad request.\",\"data\":{}}",
    };
}

/// Typed routes render the SAME envelope as every other endpoint (SP-1): the second,
/// bare `{"message":…}` shape is gone. The code is derived from the status, since a
/// typed handler's `req.fail(status, message)` carries no code of its own.
fn jsonError(a: std.mem.Allocator, status: u16, message: []const u8) !@import("http.zig").Response {
    return (ApiError{
        .status = status,
        .code = codes.s(codes.forStatus(status)),
        .message = message,
    }).toResponse(a);
}
```

The existing substring test at `src/route_types.zig:534-551` still passes; add a discriminating one next to it:

```zig
test "typed-route errors render the canonical envelope, not a bare message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const resp = try jsonError(arena.allocator(), 404, "Booking not found");
    try std.testing.expectEqual(@as(u16, 404), resp.status);
    try std.testing.expectEqualStrings(
        "{\"status\":404,\"code\":\"not_found\",\"message\":\"Booking not found\",\"data\":{}}",
        resp.body,
    );
}
```

- [ ] Fold the third shape (`{"error":"<code>"}`) in too — `src/ctx.zig:711-720`. The signature gains `message`; there are no live call sites outside doc examples and one test, so this is the moment to fix it rather than ship a fourth shape:

```zig
    /// Build the canonical error envelope with a caller-supplied machine `code`
    /// (#138 / SP-1). Use this when the handler has a more specific code than the
    /// status implies, e.g. `ctx.jsonError(403, "captcha_required", "Captcha required.")`.
    /// `code` is NOT validated against ZigBase's frozen ledger — it is your vocabulary,
    /// and ZigBase never assigns meaning to a code it did not register.
    pub fn jsonError(self: *Ctx, status: u16, code: []const u8, message: []const u8) !http_mod.Response {
        return (ApiError{ .status = status, .code = code, .message = message }).toResponse(self.arena.a);
    }
```

Update the test at `src/ctx.zig:2281-2282`:

```zig
    // jsonError: the canonical envelope carrying a consumer-defined machine code.
    const e = try ctx.jsonError(400, "bad_token", "The token is not valid.");
    try std.testing.expectEqual(@as(u16, 400), e.status);
    try std.testing.expectEqualStrings(
        "{\"status\":400,\"code\":\"bad_token\",\"message\":\"The token is not valid.\",\"data\":{}}",
        e.body,
    );
```

and the doc-comment examples at `src/ctx.zig:494-495` to the three-argument form.

- [ ] Fold the auth-method error bodies. Each is a `InitiateResult{ .status = N, .body = "{\"message\":…}" }` literal; they are static strings, so write the canonical envelope statically too. `src/auth/methods/oauth2.zig:44,47,50` become `.body = "{\"status\":400,\"code\":\"bad_request\",\"message\":\"provider is required.\",\"data\":{}}"`; `:55` becomes the 404 `not_found` form with `"Provider not found."`; `:60` the 400 `bad_request` form with `"Provider misconfigured."`. Apply the same transform at `src/auth/methods/webauthn.zig:62,67`, `src/auth/methods/otp.zig:70` (429 → `"{\"status\":429,\"code\":\"too_many_requests\",\"message\":\"Too many requests.\",\"data\":{}}"`), and `src/auth/methods/magic_link.zig:47`.

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — green, with the new test count.

- [ ] Update the one pytest that pins the old bytes, `tests/admin/test_realtime.py:146`:

```python
    assert b'{"status":404,"code":"not_found","message":"Not found.","data":{}}' in bogus, f"non-oracle 404 body, got {bogus!r}"
```

- [ ] Run the affected e2e subset: `mise exec python@3.13 -- python -m pytest tests/admin/test_realtime.py tests/admin/test_password_change.py -q`. Green.

- [ ] Update `docs/api.md:22-35` — replace the error-envelope bullet:

```markdown
- **Error envelope:** every error response is a JSON object of the shape:

  ```json
  { "status": 404, "code": "not_found", "message": "Not found.", "data": {} }
  ```

  `status` is the HTTP status. `code` is a **frozen machine string** — it never changes
  meaning once shipped, and it is what your client should branch on. `message` is human
  text and is **not contract**: it may be reworded in any release, so never match on it.
  Run `zigbase explain-code` to list every code, or `zigbase explain-code <CODE>` for the
  long form. Key order is stable and part of the contract.

  For validation failures (`400`, `code: "validation_failed"`), `data` maps each offending
  field to its own frozen `{ "code": …, "message": … }`:

  ```json
  {
    "status": 400,
    "code": "validation_failed",
    "message": "Failed to validate the request.",
    "data": { "name": { "code": "validation_invalid_name", "message": "Invalid." } }
  }
  ```

  This is the **only** error shape. Typed (`rpc.*`) routes, auth-method endpoints, and
  custom routes all emit it; the older bare `{"message": …}` and `{"error": …}` bodies are gone.
```

- [ ] Update `docs/framework.md`: rewrite the `ctx.jsonError` bullet at `:471-473` to describe the canonical envelope with a caller-supplied `code`, and update the three call examples at `:1360`, `:1362`, `:1401` to the three-argument form. Rebuild the site: `cd site && npm run build`.

- [ ] Write `changelog.d/error-envelope-unification.md`:

```markdown
### Breaking

- **The API error envelope changed shape.** It is now `{"status": <int>, "code": "<string>", "message": "…", "data": {…}}` — the top-level `code` used to repeat the integer HTTP status and is now a frozen machine string (the integer moved to `status`). The three divergent shapes are gone: typed (`rpc.*`) routes, auth-method endpoints, and `ctx.jsonError` all emit this one envelope instead of the old bare `{"message": …}` and `{"error": …}` bodies. Branch on `code`; `message` text is not contract. The official SDKs read `message` and `data` only and need no change.
- `ctx.jsonError(status, code)` now takes a message: `ctx.jsonError(status, code, message)`.
```

- [ ] Commit: `git commit -am "feat(api)!: unify every error response on one {status,code,message,data} envelope"`

---

### Task 3: `zigbase explain-code [CODE] [--json]`

**Files:**
- Modify: `src/cli.zig` (add `ExplainCodeArgs`, a `Command` member, a `HelpTopic` member, a parse block, tests), `src/framework.zig` (`runCliImpl` switch ~:1863, a new `explainCodeImpl`, `printExplainCodeUsage`, the `COMMANDS:` block in `printUsage` ~:1948)
- Create: `changelog.d/explain-code.md`

**Interfaces:**
- Consumes: `error_codes.Code`, `error_codes.info`, `error_codes.parse`, `error_codes.s` (Task 1); `framework.emit(io, file, fmt, args)` (framework.zig:1926)
- Produces: `pub const ExplainCodeArgs = struct { code: ?[]const u8 = null, json: bool = false }`; `fn explainCodeImpl(io: std.Io, args: cli.ExplainCodeArgs) void`

**Output contract** (convention 1: one object on stdout, prose to stderr):

| invocation | stdout | exit |
|---|---|---|
| `explain-code` | every code, `<code>\t<summary>` one per line | 0 |
| `explain-code --json` | `{"codes":[{"code":…,"summary":…},…]}` | 0 |
| `explain-code not_found` | `not_found\n<summary>\n\n<explanation>\n` | 0 |
| `explain-code not_found --json` | `{"code":"not_found","known":true,"summary":…,"explanation":…}` | 0 |
| `explain-code bogus` | *(nothing)*; stderr names the code and points at the bare form | 1 |
| `explain-code bogus --json` | `{"code":"bogus","known":false}` | 1 |

A code ZigBase did not register is *unknown*, not an error in the CLI's own usage — consumers may pass their own strings through `ctx.jsonError`, so `known:false` is a legitimate answer, reported on stdout as one object with exit 1.

**Steps:**

- [ ] Add the failing parser tests to `src/cli.zig`:

```zig
test "explain-code parses a bare code, --json, and both" {
    const bare = try parse(&.{"explain-code"}, .{});
    try std.testing.expect(std.meta.activeTag(bare) == .explain_code);
    try std.testing.expectEqual(@as(?[]const u8, null), bare.explain_code.code);
    try std.testing.expectEqual(false, bare.explain_code.json);

    const one = try parse(&.{ "explain-code", "not_found" }, .{});
    try std.testing.expectEqualStrings("not_found", one.explain_code.code.?);

    const j = try parse(&.{ "explain-code", "--json" }, .{});
    try std.testing.expectEqual(true, j.explain_code.json);

    // Flag order is irrelevant; both forms carry the code AND the flag.
    const both = try parse(&.{ "explain-code", "--json", "not_found" }, .{});
    try std.testing.expectEqualStrings("not_found", both.explain_code.code.?);
    try std.testing.expectEqual(true, both.explain_code.json);
    const both_rev = try parse(&.{ "explain-code", "not_found", "--json" }, .{});
    try std.testing.expectEqualStrings("not_found", both_rev.explain_code.code.?);
    try std.testing.expectEqual(true, both_rev.explain_code.json);
}

test "explain-code rejects a second positional and unknown flags; --help routes" {
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "explain-code", "a", "b" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "explain-code", "--nope" }, .{}));
    try std.testing.expectEqual(HelpTopic.explain_code, (try parse(&.{ "explain-code", "--help" }, .{})).help);
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all`. **Expected failure:** compile error, `explain_code` is not a member of `Command`/`HelpTopic`.

- [ ] Implement the parser additions in `src/cli.zig` — a new args struct near the others, one `HelpTopic` field, one `Command` member, and one parse block placed beside the other bare-command blocks (e.g. right after the `vapid-keygen` block at :194-202):

```zig
/// `explain-code [CODE] [--json]`: print the long form for one frozen error code,
/// or list every registered code when CODE is omitted.
pub const ExplainCodeArgs = struct {
    code: ?[]const u8 = null,
    json: bool = false,
};
```

```zig
    if (std.mem.eql(u8, args[0], "explain-code")) {
        var ea = ExplainCodeArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .explain_code };
            } else if (std.mem.eql(u8, a, "--json")) {
                ea.json = true;
            } else if (!std.mem.startsWith(u8, a, "-")) {
                // Positional CODE. Only one is allowed.
                if (ea.code != null) return ParseError.BadValue;
                ea.code = a;
            } else return ParseError.UnknownFlag;
        }
        return .{ .explain_code = ea };
    }
```

- [ ] Run the suite; the two parser tests pass. `runCliImpl`'s switch is now non-exhaustive, so `src/framework.zig` fails to compile — that is the next RED.

- [ ] Implement `explainCodeImpl` in `src/framework.zig`, next to the other `*Impl` helpers. Note it deliberately takes no allocator: everything it prints is comptime data or a `std.json.fmt` view of it.

```zig
const error_codes = @import("error_codes.zig");

/// `zigbase explain-code [CODE] [--json]` (SP-1). Exactly ONE JSON object reaches
/// stdout under `--json`; prose diagnostics go to stderr. Exit 0 when the code is
/// registered (or when listing), 1 when it is not.
fn explainCodeImpl(io: std.Io, ea: cli.ExplainCodeArgs) void {
    const out = std.Io.File.stdout();

    const code_str = ea.code orelse {
        if (ea.json) {
            emit(io, out, "{{\"codes\":[", .{});
            inline for (@typeInfo(error_codes.Code).@"enum".fields, 0..) |field, idx| {
                const c: error_codes.Code = @enumFromInt(field.value);
                emit(io, out, "{s}{{\"code\":{f},\"summary\":{f}}}", .{
                    if (idx == 0) "" else ",",
                    std.json.fmt(error_codes.s(c), .{}),
                    std.json.fmt(error_codes.info(c).summary, .{}),
                });
            }
            emit(io, out, "]}}\n", .{});
        } else {
            inline for (@typeInfo(error_codes.Code).@"enum".fields) |field| {
                const c: error_codes.Code = @enumFromInt(field.value);
                emit(io, out, "{s}\t{s}\n", .{ error_codes.s(c), error_codes.info(c).summary });
            }
        }
        return;
    };

    const code = error_codes.parse(code_str) orelse {
        if (ea.json) {
            emit(io, out, "{{\"code\":{f},\"known\":false}}\n", .{std.json.fmt(code_str, .{})});
        } else {
            emit(io, std.Io.File.stderr(),
                "unknown error code '{s}'\n\n" ++
                    "ZigBase never registered this code. If a consumer route produced it\n" ++
                    "(ctx.jsonError takes an arbitrary string), ask that application.\n" ++
                    "Run `zigbase explain-code` with no argument to list every ZigBase code.\n",
                .{code_str});
        }
        std.process.exit(1);
    };

    const i = error_codes.info(code);
    if (ea.json) {
        emit(io, out, "{{\"code\":{f},\"known\":true,\"summary\":{f},\"explanation\":{f}}}\n", .{
            std.json.fmt(error_codes.s(code), .{}),
            std.json.fmt(i.summary, .{}),
            std.json.fmt(i.explanation, .{}),
        });
    } else {
        emit(io, out, "{s}\n{s}\n\n{s}\n", .{ error_codes.s(code), i.summary, i.explanation });
    }
}
```

- [ ] Wire it up: add `.explain_code => |ea| explainCodeImpl(init.io, ea),` to the `runCliImpl` switch (framework.zig:1863-1920), add `.explain_code => printExplainCodeUsage(init.io, std.Io.File.stdout()),` to the `.help` sub-switch, write `printExplainCodeUsage` beside the other `print*Usage` helpers, and add one line to `printUsage`'s `COMMANDS:` block (framework.zig:1948-1957), keeping the existing two-column alignment:

```
        \\  explain-code        Explain a frozen API error code, or list them all. Add --json for one JSON object.
```

- [ ] Run `mise exec zig@0.16.0 -- zig build && ./zig-out/bin/zigbase explain-code collections_frozen`. Confirm the text form. Then `./zig-out/bin/zigbase explain-code collections_frozen --json | python3 -m json.tool` — confirm it is valid JSON with the four keys. Then `./zig-out/bin/zigbase explain-code bogus --json; echo "exit=$?"` — confirm `{"code":"bogus","known":false}` on stdout and `exit=1`. Then `./zig-out/bin/zigbase explain-code --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['codes']))"` — confirm `37`.

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — green.

- [ ] Write `changelog.d/explain-code.md`:

```markdown
### Features

- `zigbase explain-code [CODE] [--json]` — print the summary and long-form explanation for any frozen API error code, or list every code with `explain-code` alone. `--json` emits exactly one JSON object on stdout (prose goes to stderr); the exit code is 0 for a registered code and 1 for an unknown one.
```

- [ ] Commit: `git commit -am "feat(cli): zigbase explain-code for the frozen error-code registry"`

---

### Task 4: `src/logging.zig` — leveled, structured, JSON-capable logging

**Files:**
- Create: `src/logging.zig`
- Modify: `src/clock.zig` (add `nowUnixNoIo`), `src/root.zig` (public `std_options` + `logging` re-exports; test-block entry), `src/main.zig` (opt the shipped binary in)
- Create: `changelog.d/structured-logging.md`

**Interfaces:**
- Consumes: `clock.nowUnixNoIo() i64` (new), `datetime.formatUtc(unix: i64) [19]u8` (`src/datetime.zig:93`)
- Produces: `pub const Format = enum { text, json }`; `pub var format: Format`; `pub var min_level: std.log.Level`; `pub var request_logging: bool`; `pub var sink: ?*const fn (line: []const u8) void`; `pub fn parseFormat(v: []const u8) ?Format`; `pub fn parseLevel(v: []const u8) ?std.log.Level`; `pub const RequestRecord = struct { method: []const u8, path: []const u8, status: u16, duration_ms: u64 }`; `pub fn formatMessage(buf: []u8, mode: Format, level: std.log.Level, scope: []const u8, msg: []const u8) []const u8`; `pub fn formatRequest(buf: []u8, mode: Format, rec: RequestRecord) []const u8`; `pub fn logFn(comptime level, comptime scope, comptime fmt, args) void`; `pub fn request(rec: RequestRecord) void`; `pub const std_options: std.Options`
- Consumed by: Task 5 (config wiring), Task 6 (request logging), Task 7 (the swallowed-error fix), SP-3 (`serve --background` log file)

**Why this shape.** The two `format*` functions are **pure** — they take a caller's buffer and return a slice, allocate nothing, and touch no globals — so the exact bytes of both modes are unit-testable without capturing stderr. `logFn`/`request` are thin I/O shells over them, exactly the `formatLine`/`emit` split already used in `src/report/log.zig:21-37`. `sink` is the same test seam as `report_log.log_sink` (Zig's test runner counts `std.log.err` as a failure, so a test that exercises an error path needs somewhere else to send it).

**Deliberate divergence from Zig's default logger:** `std.log.defaultLog` writes ANSI-colored, timestamp-free lines. Both modes here are uncolored and timestamped. Color codes are noise the moment the stream is a file or a pipe (which is the normal case for a server), and an agent parsing a log needs a timestamp in every line, not a TTY affordance.

**Steps:**

- [ ] Add the io-free clock read to `src/clock.zig` (place it directly after `nowUnix` at :113-118). It must honor the frozen-clock override so `ZIGBASE_FAKE_NOW` makes log timestamps deterministic in tests:

```zig
/// Wall-clock seconds without a `std.Io`. `std.Options.logFn` receives no `io`, and a
/// log line still needs a timestamp — so this reads the host clock directly (the
/// framework links libc and only targets Linux/macOS). It honors the same frozen
/// override as `nowUnix`, which is what makes log output deterministic under
/// `ZIGBASE_FAKE_NOW` in tests.
pub fn nowUnixNoIo() i64 {
    if (frozenUnix()) |v| return v;
    return wallSeconds();
}
```

- [ ] Create `src/logging.zig` containing **only** the types, the globals, the two parsers, and the tests below — no `formatMessage`/`formatRequest` yet. Register it in `src/root.zig`'s test block (`_ = @import("logging.zig");`, before the postgres guard) so the tests actually run:

```zig
test "logging: text format is timestamped, leveled, and scope-tagged" {
    clock.setForTest(1_754_654_400); // 2025-08-08T12:00:00Z — fixed so bytes are exact
    defer clock.resetForTest();
    var buf: [512]u8 = undefined;

    // The default scope is omitted; a named scope is parenthesized.
    try std.testing.expectEqualStrings(
        "2025-08-08T12:00:00Z info: listening on 127.0.0.1:8090\n",
        formatMessage(&buf, .text, .info, "default", "listening on 127.0.0.1:8090"),
    );
    try std.testing.expectEqualStrings(
        "2025-08-08T12:00:00Z error(http): boom\n",
        formatMessage(&buf, .text, .err, "http", "boom"),
    );
}

test "logging: json format escapes the message and keeps a fixed key order" {
    clock.setForTest(1_754_654_400);
    defer clock.resetForTest();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"ts\":\"2025-08-08T12:00:00Z\",\"level\":\"warn\",\"scope\":\"http\"," ++
            "\"msg\":\"a \\\"quoted\\\" thing\\nand a newline\"}\n",
        formatMessage(&buf, .json, .warn, "http", "a \"quoted\" thing\nand a newline"),
    );
}

test "logging: a request record carries its fields separately, not crammed into msg" {
    clock.setForTest(1_754_654_400);
    defer clock.resetForTest();
    var buf: [512]u8 = undefined;
    const rec = RequestRecord{ .method = "GET", .path = "/api/health", .status = 200, .duration_ms = 3 };
    try std.testing.expectEqualStrings(
        "2025-08-08T12:00:00Z info(http): GET /api/health 200 3ms\n",
        formatRequest(&buf, .text, rec),
    );
    try std.testing.expectEqualStrings(
        "{\"ts\":\"2025-08-08T12:00:00Z\",\"level\":\"info\",\"scope\":\"http\",\"msg\":\"request\"," ++
            "\"method\":\"GET\",\"path\":\"/api/health\",\"status\":200,\"duration_ms\":3}\n",
        formatRequest(&buf, .json, rec),
    );
}

test "logging: a path with a quote is escaped, never breaking the JSON line" {
    clock.setForTest(1_754_654_400);
    defer clock.resetForTest();
    var buf: [512]u8 = undefined;
    const rec = RequestRecord{ .method = "GET", .path = "/api/x\"y", .status = 404, .duration_ms = 0 };
    const line = formatRequest(&buf, .json, rec);
    // Parse it back: the only real proof that an attacker-controlled path can't
    // forge a log record. A substring check would not catch a broken escape.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/api/x\"y", parsed.value.object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 404), parsed.value.object.get("status").?.integer);
}

test "logging: an oversized message truncates and still yields ONE valid JSON line" {
    clock.setForTest(1_754_654_400);
    defer clock.resetForTest();
    var huge: [4096]u8 = undefined;
    @memset(&huge, 'x');
    var buf: [512]u8 = undefined; // deliberately too small for the message
    const line = formatMessage(&buf, .json, .err, "default", &huge);
    try std.testing.expect(line.len <= buf.len);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("msg") != null);
    try std.testing.expectEqual(@as(?std.json.Value, null), parsed.value.object.get("nope"));
}

test "logging: parseFormat and parseLevel accept only the documented spellings" {
    try std.testing.expectEqual(@as(?Format, .json), parseFormat("json"));
    try std.testing.expectEqual(@as(?Format, .text), parseFormat("text"));
    try std.testing.expectEqual(@as(?Format, null), parseFormat("JSON"));
    try std.testing.expectEqual(@as(?Format, null), parseFormat("ndjson"));
    try std.testing.expectEqual(@as(?std.log.Level, .debug), parseLevel("debug"));
    try std.testing.expectEqual(@as(?std.log.Level, .info), parseLevel("info"));
    try std.testing.expectEqual(@as(?std.log.Level, .warn), parseLevel("warn"));
    // Both spellings of the highest level are accepted; `std.log.Level` calls it `err`.
    try std.testing.expectEqual(@as(?std.log.Level, .err), parseLevel("error"));
    try std.testing.expectEqual(@as(?std.log.Level, .err), parseLevel("err"));
    try std.testing.expectEqual(@as(?std.log.Level, null), parseLevel("trace"));
}

test "logging: min_level suppresses lower-severity records at the sink" {
    const H = struct {
        var seen: usize = 0;
        var last: [256]u8 = undefined;
        var last_len: usize = 0;
        fn s(line: []const u8) void {
            seen += 1;
            const n = @min(line.len, last.len);
            @memcpy(last[0..n], line[0..n]);
            last_len = n;
        }
    };
    H.seen = 0;
    sink = H.s;
    defer sink = null;
    const prev = min_level;
    defer min_level = prev;

    min_level = .warn;
    logFn(.info, .default, "quiet", .{});
    try std.testing.expectEqual(@as(usize, 0), H.seen);
    logFn(.warn, .default, "loud", .{});
    try std.testing.expectEqual(@as(usize, 1), H.seen);
    try std.testing.expect(std.mem.indexOf(u8, H.last[0..H.last_len], "loud") != null);
}

test "logging: request() honors request_logging and min_level" {
    const H = struct {
        var seen: usize = 0;
        fn s(_: []const u8) void {
            seen += 1;
        }
    };
    H.seen = 0;
    sink = H.s;
    defer sink = null;
    const prev_req = request_logging;
    const prev_lvl = min_level;
    defer {
        request_logging = prev_req;
        min_level = prev_lvl;
    }
    const rec = RequestRecord{ .method = "GET", .path = "/", .status = 200, .duration_ms = 1 };

    min_level = .info;
    request_logging = false;
    request(rec);
    try std.testing.expectEqual(@as(usize, 0), H.seen);

    request_logging = true;
    request(rec);
    try std.testing.expectEqual(@as(usize, 1), H.seen);

    // Request lines are `info`; raising the floor above info silences them too.
    min_level = .warn;
    request(rec);
    try std.testing.expectEqual(@as(usize, 1), H.seen);
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all`. **Expected failure:** compile errors for the undeclared `formatMessage`, `formatRequest`, `logFn`, `request`, and `RequestRecord`.

- [ ] Implement the rest of `src/logging.zig`:

```zig
const std = @import("std");
const clock = @import("clock.zig");
const datetime = @import("datetime.zig");

/// Log line encoding. `text` is human-first; `json` is one JSON object per line —
/// i.e. an NDJSON stream on stderr. Per the SP-1 output conventions, a consumer of
/// that stream MUST skip any line that does not parse as JSON (a panic message or a
/// linked C library's own output can land on the same fd) and must never fail the
/// run because of one.
pub const Format = enum { text, json };

/// Process-wide logging state. Single-process server, resolved once at startup
/// before any worker thread exists (see `framework.runCliImpl`), then read-only —
/// so plain globals are correct here and an atomic would only add noise.
pub var format: Format = .text;
pub var min_level: std.log.Level = .info;
pub var request_logging: bool = true;

/// Test seam: when non-null, every emitted line goes here instead of stderr. Mirrors
/// `report/log.zig`'s `log_sink` — Zig's test runner counts a real `std.log.err` as a
/// test failure, so a test exercising an error path needs somewhere else to send it.
pub var sink: ?*const fn (line: []const u8) void = null;

/// A single HTTP request record. Emitted by `request()`, NOT through `std.log`:
/// `std.Options.logFn` only ever receives an already-formatted string, so routing
/// these through it would collapse every field into one opaque `msg`.
pub const RequestRecord = struct {
    method: []const u8,
    path: []const u8,
    status: u16,
    duration_ms: u64,
};

pub fn parseFormat(v: []const u8) ?Format {
    if (std.mem.eql(u8, v, "text")) return .text;
    if (std.mem.eql(u8, v, "json")) return .json;
    return null;
}

pub fn parseLevel(v: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, v, "debug")) return .debug;
    if (std.mem.eql(u8, v, "info")) return .info;
    if (std.mem.eql(u8, v, "warn")) return .warn;
    // `error` is the spelling operators expect; `err` is the std.log.Level tag name.
    if (std.mem.eql(u8, v, "error") or std.mem.eql(u8, v, "err")) return .err;
    return null;
}

/// `YYYY-MM-DDTHH:MM:SSZ` for the current instant (frozen-clock aware).
fn timestamp() [20]u8 {
    var out: [20]u8 = undefined;
    out[0..19].* = datetime.formatUtc(clock.nowUnixNoIo());
    out[19] = 'Z';
    return out;
}

/// Render one log line (including its trailing newline) into `buf`, returning the
/// written slice. Pure: allocates nothing, reads no mutable global except the clock.
///
/// TRUNCATION CONTRACT: if the line does not fit, the result is shortened but stays
/// WELL-FORMED for the mode — a truncated `json` line is still one parseable object,
/// because the message is clamped first and the envelope is composed around it. A
/// half-written line that broke JSON parsing would be worse than a lossy one.
pub fn formatMessage(buf: []u8, mode: Format, level: std.log.Level, scope: []const u8, msg: []const u8) []const u8 {
    const ts = timestamp();
    // Worst-case JSON escaping expands one byte to six (\uXXXX), so clamp the message
    // to a sixth of the remaining room before composing.
    const overhead = 96 + ts.len + scope.len;
    const room = if (buf.len > overhead) buf.len - overhead else 0;
    const max_msg = switch (mode) {
        .text => room,
        .json => room / 6,
    };
    const m = msg[0..@min(msg.len, max_msg)];

    const written = switch (mode) {
        .text => if (std.mem.eql(u8, scope, "default"))
            std.fmt.bufPrint(buf, "{s} {s}: {s}\n", .{ &ts, level.asText(), m })
        else
            std.fmt.bufPrint(buf, "{s} {s}({s}): {s}\n", .{ &ts, level.asText(), scope, m }),
        .json => std.fmt.bufPrint(
            buf,
            "{{\"ts\":\"{s}\",\"level\":\"{s}\",\"scope\":\"{s}\",\"msg\":{f}}}\n",
            .{ &ts, level.asText(), scope, std.json.fmt(m, .{}) },
        ),
    };
    // NoSpaceLeft can still occur if `scope` itself is pathological; drop to a fixed,
    // valid line rather than emitting a fragment.
    return written catch switch (mode) {
        .text => "log line too long\n",
        .json => "{\"ts\":\"\",\"level\":\"error\",\"scope\":\"default\",\"msg\":\"log line too long\"}\n",
    };
}

/// Render one request record. Same purity and truncation contract as `formatMessage`.
/// `path` is attacker-controlled, so the json branch escapes it through `std.json.fmt`
/// — a raw interpolation would let a crafted URL forge a second log record.
pub fn formatRequest(buf: []u8, mode: Format, rec: RequestRecord) []const u8 {
    const ts = timestamp();
    const written = switch (mode) {
        .text => std.fmt.bufPrint(buf, "{s} info(http): {s} {s} {d} {d}ms\n", .{
            &ts, rec.method, rec.path, rec.status, rec.duration_ms,
        }),
        .json => std.fmt.bufPrint(
            buf,
            "{{\"ts\":\"{s}\",\"level\":\"info\",\"scope\":\"http\",\"msg\":\"request\"," ++
                "\"method\":{f},\"path\":{f},\"status\":{d},\"duration_ms\":{d}}}\n",
            .{ &ts, std.json.fmt(rec.method, .{}), std.json.fmt(rec.path, .{}), rec.status, rec.duration_ms },
        ),
    };
    return written catch switch (mode) {
        .text => "log line too long\n",
        .json => "{\"ts\":\"\",\"level\":\"error\",\"scope\":\"http\",\"msg\":\"log line too long\"}\n",
    };
}

/// Write one already-formatted line to the sink (tests) or stderr (production).
fn write(line: []const u8) void {
    if (sink) |s| {
        s(line);
        return;
    }
    var lock_buf: [64]u8 = undefined;
    const locked = std.debug.lockStderr(&lock_buf);
    defer std.debug.unlockStderr();
    locked.file_writer.interface.writeAll(line) catch {};
    locked.file_writer.interface.flush() catch {};
}

/// The `std.Options.logFn` hook: EVERY `std.log` call in the framework, in the
/// vendored dependencies' Zig code, and in consumer hooks/routes lands here.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch msg_buf[0..];
    var line_buf: [8192]u8 = undefined;
    write(formatMessage(&line_buf, format, level, @tagName(scope), msg));
}

/// Emit one structured request record. No-op when request logging is off or the
/// level floor is above `info`.
pub fn request(rec: RequestRecord) void {
    if (!request_logging) return;
    if (@intFromEnum(std.log.Level.info) > @intFromEnum(min_level)) return;
    var line_buf: [8192]u8 = undefined;
    write(formatRequest(&line_buf, format, rec));
}

/// Drop this into your binary's root: `pub const std_options = zigbase.std_options;`.
/// `log_level` is `.debug` so nothing is filtered at COMPILE time — the runtime floor
/// is `min_level`, which `--log-level` / `ZIGBASE_LOG_LEVEL` set at startup.
pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};
```

Note `@intFromEnum` ordering: `std.log.Level` declares `err, warn, info, debug`, so a *lower* ordinal is *more* severe — hence `>` suppresses.

- [ ] Add the public re-exports to `src/root.zig`, beside the other `pub const` exports:

```zig
/// Structured logging. A consumer binary opts in from its own root:
///   `pub const std_options = zigbase.std_options;`
/// Without that line the binary keeps Zig's default logger and `--log-format`,
/// `--log-level`, and request logging have no effect.
pub const logging = @import("logging.zig");
pub const std_options = logging.std_options;
```

- [ ] Opt the shipped binary in — `src/main.zig` gains one line above `pub fn main`:

```zig
pub const std_options = zigbase.std_options;
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — green, eight new tests. Then `mise exec zig@0.16.0 -- zig build run -- serve --insecure-cookies --data-dir /tmp/zb-logcheck` for a few seconds and confirm the boot lines now carry a timestamp; Ctrl-C and `rm -rf /tmp/zb-logcheck`.

- [ ] Write `changelog.d/structured-logging.md`:

```markdown
### Features

- Structured logging. Every log line is now timestamped and leveled, and the whole stream can be switched to one JSON object per line. Embedding consumers opt in from their own binary root with `pub const std_options = zigbase.std_options;`.
```

- [ ] Commit: `git commit -am "feat(logging): timestamped, leveled, JSON-capable log core"`

---

### Task 5: Env-var fail-fast — parse errors name the variable, unknown vars warn

**Files:**
- Modify: `src/config.zig` (the whole `Config.load` body at :179-238; add `LoadDiag`, `loadDiag`, `known_vars`, `isKnown`, `warnUnknownVars`), `src/framework.zig` (`loadCfg` — grep for `fn loadCfg`), `tests/admin/test_docs_parity.py` (one new parity test)
- Create: `changelog.d/env-fail-fast.md`

**Interfaces:**
- Produces: `pub const LoadDiag = struct { var_name: []const u8 = "", value: []const u8 = "", expected: []const u8 = "" }`; `pub const LoadError = error{InvalidEnvValue}`; `pub fn loadDiag(getter: anytype, diag: *LoadDiag) LoadError!Config`; `pub fn load(getter: anytype) !Config` (unchanged signature, now a thin wrapper); `pub const known_vars: []const []const u8`; `pub fn isKnown(name: []const u8) bool`; `pub fn warnUnknownVars(environ: *const std.process.Environ.Map) void`
- Consumed by: `framework.loadCfg`; Task 6 adds three log keys through the same machinery

**Two defects being fixed.** (1) Every numeric var is a bare `try std.fmt.parseInt(...)` (config.zig:182-215), so `ZIGBASE_HTTP_PORT=eighty` aborts boot with a naked `error.InvalidCharacter` and no hint which variable is at fault. (2) Every boolean is `std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")` (e.g. :188, :195, :205, :212), so `ZIGBASE_TRUST_PROXY=yes` or `=TRUE` silently means **false** — a security-relevant knob quietly not applied. Both become fail-fast-at-boot with an actionable message.

**Steps:**

- [ ] Add the failing tests to `src/config.zig` (the file's existing stub-getter style):

```zig
test "a bad integer env value names the variable, the value, and what was expected" {
    const G = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_HTTP_PORT")) return "eighty";
            return null;
        }
    };
    var diag: LoadDiag = .{};
    try std.testing.expectError(LoadError.InvalidEnvValue, loadDiag(G{}, &diag));
    try std.testing.expectEqualStrings("ZIGBASE_HTTP_PORT", diag.var_name);
    try std.testing.expectEqualStrings("eighty", diag.value);
    try std.testing.expect(diag.expected.len > 0);
}

test "a bad boolean env value FAILS instead of silently meaning false" {
    // Regression guard: `ZIGBASE_TRUST_PROXY=yes` used to parse as false, silently
    // leaving a security knob unapplied. It must now abort boot.
    const G = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_TRUST_PROXY")) return "yes";
            return null;
        }
    };
    var diag: LoadDiag = .{};
    try std.testing.expectError(LoadError.InvalidEnvValue, loadDiag(G{}, &diag));
    try std.testing.expectEqualStrings("ZIGBASE_TRUST_PROXY", diag.var_name);
    try std.testing.expectEqualStrings("yes", diag.value);
    try std.testing.expectEqualStrings("true|false|1|0", diag.expected);
}

test "the documented boolean spellings all parse" {
    inline for (.{ .{ "true", true }, .{ "1", true }, .{ "false", false }, .{ "0", false } }) |case| {
        const G = struct {
            var raw: []const u8 = "";
            fn get(_: @This(), key: []const u8) ?[]const u8 {
                if (std.mem.eql(u8, key, "ZIGBASE_TRUST_PROXY")) return raw;
                return null;
            }
        };
        G.raw = case[0];
        try std.testing.expectEqual(case[1], (try load(G{})).trust_proxy);
    }
}

test "a bad enum env value names the variable and lists the choices" {
    const G = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_SMTP_TLS")) return "ssl";
            return null;
        }
    };
    var diag: LoadDiag = .{};
    try std.testing.expectError(LoadError.InvalidEnvValue, loadDiag(G{}, &diag));
    try std.testing.expectEqualStrings("ZIGBASE_SMTP_TLS", diag.var_name);
    try std.testing.expectEqualStrings("none|starttls|implicit|auto", diag.expected);
}

test "known_vars is sorted, deduplicated, and covers every consumer knob" {
    for (known_vars[1..], 1..) |name, i| {
        try std.testing.expect(std.mem.order(u8, known_vars[i - 1], name) == .lt);
    }
    // Spot-check both ends and a middle entry so a truncated list fails loudly.
    try std.testing.expect(isKnown("ZIGBASE_HTTP_PORT"));
    try std.testing.expect(isKnown("ZIGBASE_SMTP_TLS"));
    try std.testing.expect(isKnown("ZIGBASE_VAPID_PRIVATE_KEY"));
}

test "isKnown accepts the templated families and rejects a typo" {
    // These names are built with std.fmt at runtime, so they can never appear in
    // known_vars literally — they are matched by shape.
    try std.testing.expect(isKnown("ZIGBASE_FIELD_KEY_V2"));
    try std.testing.expect(isKnown("ZIGBASE_OAUTH_GOOGLE_CLIENT_ID"));
    try std.testing.expect(isKnown("ZIGBASE_OAUTH_GITHUB_CLIENT_SECRET"));
    // A near-miss must NOT be swallowed — catching this typo is the whole point.
    try std.testing.expect(!isKnown("ZIGBASE_HTTP_PORTS"));
    try std.testing.expect(!isKnown("ZIGBASE_TRUST_PROXIES"));
    try std.testing.expect(!isKnown("ZIGBASE_OAUTH_GOOGLE_SECRET"));
    // Non-ZIGBASE names are never our business.
    try std.testing.expect(!isKnown("PATH"));
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all`. **Expected failure:** compile errors for undeclared `LoadDiag`, `LoadError`, `loadDiag`, `known_vars`, `isKnown`.

- [ ] Implement in `src/config.zig`. Add the diagnostic type and three typed helpers above `Config`, then rewrite `load` as a wrapper over `loadDiag` and convert every `try std.fmt.parseInt(...)` and every `std.mem.eql(u8, v, "true") or …` in the body:

```zig
/// Detail about the single env var that failed to parse. Filled by `loadDiag` on
/// `error.InvalidEnvValue`. It rides an out-param rather than a log call because
/// `Config.load` is a pure loader driven by a stub getter in tests — this keeps the
/// exact operator-facing wording unit-testable.
pub const LoadDiag = struct {
    var_name: []const u8 = "",
    value: []const u8 = "",
    /// Human description of the accepted values, e.g. "u16 (decimal integer)" or
    /// "true|false|1|0". Rendered verbatim into the startup error.
    expected: []const u8 = "",
};

pub const LoadError = error{InvalidEnvValue};

fn envInt(comptime T: type, name: []const u8, v: []const u8, diag: *LoadDiag) LoadError!T {
    return std.fmt.parseInt(T, v, 10) catch {
        diag.* = .{ .var_name = name, .value = v, .expected = @typeName(T) ++ " (decimal integer)" };
        return error.InvalidEnvValue;
    };
}

/// Booleans accept exactly `true`, `false`, `1`, `0`. Anything else is a startup
/// error — the old "not exactly 'true' or '1' means false" rule silently discarded
/// `yes`, `TRUE`, and typos, which on a knob like ZIGBASE_TRUST_PROXY is a security bug.
fn envBool(name: []const u8, v: []const u8, diag: *LoadDiag) LoadError!bool {
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
    diag.* = .{ .var_name = name, .value = v, .expected = "true|false|1|0" };
    return error.InvalidEnvValue;
}

fn envEnum(comptime T: type, name: []const u8, v: []const u8, comptime choices: []const u8, diag: *LoadDiag) LoadError!T {
    return std.meta.stringToEnum(T, v) orelse {
        diag.* = .{ .var_name = name, .value = v, .expected = choices };
        return error.InvalidEnvValue;
    };
}
```

Inside `loadDiag`, each site becomes e.g. `cfg.http_port = try envInt(u16, "ZIGBASE_HTTP_PORT", v, diag);`, `cfg.trust_proxy = try envBool("ZIGBASE_TRUST_PROXY", v, diag);`, and the hand-rolled `ZIGBASE_SMTP_TLS` chain at :219-221 collapses to `cfg.smtp_tls = try envEnum(SmtpTls, "ZIGBASE_SMTP_TLS", v, "none|starttls|implicit|auto", diag);`. Keep `load` for the existing callers and tests:

```zig
/// Back-compat wrapper: same signature as before, diagnostic discarded. Boot uses
/// `loadDiag` so it can print which variable was wrong.
pub fn load(getter: anytype) !Config {
    var diag: LoadDiag = .{};
    return loadDiag(getter, &diag);
}
```

- [ ] Add the known-variable registry and the unknown-variable warning at the bottom of `src/config.zig`. Keep `known_vars` alphabetical — the test enforces it:

```zig
/// Every ZIGBASE_* variable `loadDiag` reads, alphabetically. The single source of
/// truth for "is this name a real knob"; `tests/admin/test_docs_parity.py` cross-checks
/// it against the string literals actually present in src/, so it cannot drift.
pub const known_vars = [_][]const u8{
    "ZIGBASE_AUTH_TOKEN_TTL",
    "ZIGBASE_COOKIE_SECURE",
    // …one entry per var read in loadDiag, in sorted order…
    "ZIGBASE_VAPID_PRIVATE_KEY",
    "ZIGBASE_VAPID_PUBLIC_KEY",
};

/// Every ZIGBASE_* variable that is a real knob but is NOT read by `loadDiag`, because it
/// is consumed outside `Config`. Kept separate from `known_vars` so the docs-parity test
/// (which cross-checks `known_vars` against what `loadDiag` reads) stays exact.
///
/// CROSS-PROJECT: SP-3 introduces `ZIGBASE_SERVE_BACKGROUND` (user-facing) and
/// `ZIGBASE_SERVE_BACKGROUND_CHILD` (internal recursion guard), both read by
/// `src/serve_control.zig`, never by `Config`. Without them here, every
/// `zigbase serve --background` would print a spurious "unknown environment variable"
/// warning — this warning firing on ZigBase's own variables is exactly the failure mode
/// that trains operators to ignore it. Whichever sub-project merges second adds the two
/// entries; if SP-3 merges first, add them in this task.
pub const known_external_vars = [_][]const u8{
    "ZIGBASE_SERVE_BACKGROUND",
    "ZIGBASE_SERVE_BACKGROUND_CHILD",
};

/// True when `name` is a knob ZigBase understands. Two families are matched by shape
/// rather than by literal, because their names are built with `std.fmt` at runtime and
/// so can never be listed: the field-key generations (`ZIGBASE_FIELD_KEY_V<n>`) and the
/// per-provider OAuth credentials (`ZIGBASE_OAUTH_<PROVIDER>_CLIENT_ID`/`_CLIENT_SECRET`).
pub fn isKnown(name: []const u8) bool {
    for (known_vars) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    for (known_external_vars) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    if (std.mem.startsWith(u8, name, "ZIGBASE_FIELD_KEY_V") and name.len > "ZIGBASE_FIELD_KEY_V".len) return true;
    if (std.mem.startsWith(u8, name, "ZIGBASE_OAUTH_") and
        (std.mem.endsWith(u8, name, "_CLIENT_ID") or std.mem.endsWith(u8, name, "_CLIENT_SECRET"))) return true;
    return false;
}

/// Warn once per unrecognized `ZIGBASE_*` variable in the environment. A WARNING, not
/// an error: the repo's own harnesses set ZIGBASE_TEST_BINARY / ZIGBASE_PG_TEST_URL, and
/// operators legitimately keep their own ZIGBASE_-prefixed values around, so failing
/// here would break working setups to catch a typo. The value is NEVER logged — an
/// unknown name could well be a secret.
pub fn warnUnknownVars(environ: *const std.process.Environ.Map) void {
    for (environ.keys()) |name| {
        if (!std.mem.startsWith(u8, name, "ZIGBASE_")) continue;
        if (isKnown(name)) continue;
        std.log.warn("unknown environment variable {s} is set and will be ignored (run `zigbase --help` for the supported list)", .{name});
    }
}
```

- [ ] Wire both into boot — in `src/framework.zig`'s `loadCfg` (grep `fn loadCfg`), swap `Config.load` for `loadDiag` and fail fast with the actionable message, then warn about unknowns:

```zig
    var diag: config.LoadDiag = .{};
    var cfg = config.Config.loadDiag(config.EnvGetter{ .environ = environ }, &diag) catch |e| switch (e) {
        error.InvalidEnvValue => {
            std.log.err(
                "invalid value for {s}: '{s}' — expected {s}. Fix the variable (or unset it to use the default) and start again.",
                .{ diag.var_name, diag.value, diag.expected },
            );
            return error.InvalidEnvValue;
        },
    };
    config.warnUnknownVars(environ);
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — green. Then prove it end to end:

```sh
mise exec zig@0.16.0 -- zig build
ZIGBASE_HTTP_PORT=eighty ./zig-out/bin/zigbase serve; echo "exit=$?"
ZIGBASE_TRUST_PROXY=yes  ./zig-out/bin/zigbase serve; echo "exit=$?"
ZIGBASE_HTTP_PORTS=9000  ./zig-out/bin/zigbase migrate status --data-dir /tmp/zb-envcheck
```

Expect the first two to print the variable name, the offending value, and the expected form, and to exit non-zero; expect the third to warn about `ZIGBASE_HTTP_PORTS` and continue. `rm -rf /tmp/zb-envcheck` afterwards.

- [ ] Add the drift gate to `tests/admin/test_docs_parity.py`, reusing its existing `_code_env_vars()` helper:

```python
def test_env_vars_are_registered_in_config_known_vars():
    """Every ZIGBASE_* knob in the code must be in config.known_vars, or the
    unknown-variable warning fires on a legitimate setting."""
    src = (REPO / "src" / "config.zig").read_text()
    m = re.search(r"pub const known_vars = \[_\]\[\]const u8\{(.*?)\n\};", src, re.S)
    assert m, "known_vars not found in src/config.zig — did it move or get renamed?"
    known = set(re.findall(r'"(ZIGBASE_[A-Z0-9_]+)"', m.group(1)))
    missing = sorted(n for n in _code_env_vars() if n not in known)
    assert not missing, f"env vars missing from config.known_vars: {missing}"
```

- [ ] Run `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q` — green (three existing tests plus the new one).

- [ ] Write `changelog.d/env-fail-fast.md`:

```markdown
### Changed

- **A malformed environment variable now aborts startup with a message naming the variable, the offending value, and the accepted form**, instead of dying with a bare parse error or silently falling back to a default.
- **Boolean environment variables accept exactly `true`, `false`, `1`, or `0`.** Any other spelling is now a startup error. Previously anything that was not `true` or `1` silently meant `false`, so `ZIGBASE_TRUST_PROXY=yes` quietly left the knob off.
- An unrecognized `ZIGBASE_*` variable now logs a startup warning naming it (never its value), so a typo'd knob is visible instead of ignored.
```

- [ ] Commit: `git commit -am "feat(config): fail fast on a bad env value and warn on unknown ZIGBASE_* vars"`

---

### Task 6: Wire the logging knobs — env vars, `serve` flags, boot ordering, docs

**Files:**
- Modify: `src/config.zig` (three new fields + three `loadDiag` sites + three `known_vars` entries), `src/logging.zig` (add `preinstallFromEnv`, `apply`), `src/cli.zig` (`ServeArgs` gains three fields + parse arms + tests), `src/framework.zig` (`runCliImpl` pre-pass at :1845, `loadCfg` flag overrides, `serveImpl` apply, `printUsage`'s `COMMON FLAGS` ~:1962 and `ENVIRONMENT VARIABLES:` block :1990-2064, `printServeUsage` ~:2126), `README.md` (three env-table rows, table at :169-219)
- Create: `docs/observability.md`, `changelog.d/logging-knobs.md`
- Modify: `site/scripts/docs-registry.json` (register the new doc)

**Interfaces:**
- Consumes: `logging.Format`, `logging.parseFormat`, `logging.parseLevel`, `logging.format`, `logging.min_level`, `logging.request_logging` (Task 4); `config.LoadDiag`, `config.envBool`, `config.envEnum` (Task 5)
- Produces: `Config.log_format: logging.Format = .text`, `Config.log_level: std.log.Level = .info`, `Config.log_requests: bool = true`; `ServeArgs.log_format: ?[]const u8`, `.log_level: ?[]const u8`, `.log_requests: ?bool`; `pub fn logging.preinstallFromEnv(environ: *const std.process.Environ.Map) void`; `pub fn logging.apply(cfg_format: Format, cfg_level: std.log.Level, cfg_requests: bool) void`

**Config-plane justification** (docs/framework.md §3's assignment rule at :152-155): these are *deploy-varying values*, not structure and not binary cost, so they are **env vars with `serve` flags** — never comptime `App(.{…})` keys and never `-D` build flags.

**Flag/env scope.** The three env vars apply to **every** subcommand; the three flags are **`serve`-only**. A one-shot command that wants JSON logs sets the env var (`ZIGBASE_LOG_FORMAT=json zigbase migrate`); adding the flags to every subcommand would enlarge the CLI surface for no gain and would collide with SP-3's parser work. Say this in `printServeUsage`.

**Boot ordering** (the chicken-and-egg): a bad `ZIGBASE_LOG_FORMAT` must be reported *by the logger it is configuring*. Resolution — `runCliImpl` runs `logging.preinstallFromEnv` as its very first statement, reading only `ZIGBASE_LOG_FORMAT`/`ZIGBASE_LOG_LEVEL` and **silently ignoring anything invalid**; the real, fail-fast validation happens moments later inside `Config.loadDiag`, which produces the actionable error. The pre-pass exists solely so that error is emitted in the right *format*; it never validates, so there is exactly one validation path and no drift.

**Steps:**

- [ ] Add the failing tests. In `src/config.zig`:

```zig
test "log knobs default to text/info/on and parse from env" {
    const G0 = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    const d = try load(G0{});
    try std.testing.expectEqual(logging.Format.text, d.log_format);
    try std.testing.expectEqual(std.log.Level.info, d.log_level);
    try std.testing.expectEqual(true, d.log_requests);

    const G1 = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_LOG_FORMAT")) return "json";
            if (std.mem.eql(u8, key, "ZIGBASE_LOG_LEVEL")) return "warn";
            if (std.mem.eql(u8, key, "ZIGBASE_LOG_REQUESTS")) return "false";
            return null;
        }
    };
    const c = try load(G1{});
    try std.testing.expectEqual(logging.Format.json, c.log_format);
    try std.testing.expectEqual(std.log.Level.warn, c.log_level);
    try std.testing.expectEqual(false, c.log_requests);
}

test "a bad log format or level fails fast with the accepted choices" {
    const GF = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_LOG_FORMAT")) return "ndjson";
            return null;
        }
    };
    var diag: LoadDiag = .{};
    try std.testing.expectError(LoadError.InvalidEnvValue, loadDiag(GF{}, &diag));
    try std.testing.expectEqualStrings("ZIGBASE_LOG_FORMAT", diag.var_name);
    try std.testing.expectEqualStrings("text|json", diag.expected);

    const GL = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZIGBASE_LOG_LEVEL")) return "trace";
            return null;
        }
    };
    diag = .{};
    try std.testing.expectError(LoadError.InvalidEnvValue, loadDiag(GL{}, &diag));
    try std.testing.expectEqualStrings("ZIGBASE_LOG_LEVEL", diag.var_name);
    try std.testing.expectEqualStrings("debug|info|warn|error", diag.expected);
}
```

and in `src/cli.zig`:

```zig
test "serve parses the logging flags; bad values are rejected at parse time" {
    const c = try parse(&.{ "serve", "--log-format", "json", "--log-level", "warn", "--no-request-log" }, .{});
    try std.testing.expectEqualStrings("json", c.serve.log_format.?);
    try std.testing.expectEqualStrings("warn", c.serve.log_level.?);
    try std.testing.expectEqual(@as(?bool, false), c.serve.log_requests);
    // Absent flags stay null so the env/default still wins.
    const bare = try parse(&.{"serve"}, .{});
    try std.testing.expectEqual(@as(?[]const u8, null), bare.serve.log_format);
    try std.testing.expectEqual(@as(?bool, null), bare.serve.log_requests);
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--log-format", "ndjson" }, .{}));
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "serve", "--log-level", "trace" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "serve", "--log-format" }, .{}));
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all`. **Expected failure:** compile errors — `log_format` is not a field of `Config`/`ServeArgs`.

- [ ] Implement. In `src/config.zig` add `const logging = @import("logging.zig");`, the three fields (with the doc comments the README rows mirror), and the three `loadDiag` sites:

```zig
    // Log line encoding. `text` (default) is human-first; `json` emits one JSON
    // object per line on stderr — the machine-readable stream agents consume.
    // Env: ZIGBASE_LOG_FORMAT. Flag (serve only): --log-format.
    log_format: logging.Format = .text,
    // Minimum severity that is emitted. Env: ZIGBASE_LOG_LEVEL; flag --log-level.
    log_level: std.log.Level = .info,
    // Per-request access lines (method, path, status, duration). On by default;
    // turn off on a high-traffic deployment that ships access logs from its proxy.
    // Env: ZIGBASE_LOG_REQUESTS; flag --no-request-log.
    log_requests: bool = true,
```

```zig
        if (getter.get("ZIGBASE_LOG_FORMAT")) |v| cfg.log_format = try envEnum(logging.Format, "ZIGBASE_LOG_FORMAT", v, "text|json", diag);
        if (getter.get("ZIGBASE_LOG_LEVEL")) |v| cfg.log_level = logging.parseLevel(v) orelse {
            diag.* = .{ .var_name = "ZIGBASE_LOG_LEVEL", .value = v, .expected = "debug|info|warn|error" };
            return error.InvalidEnvValue;
        };
        if (getter.get("ZIGBASE_LOG_REQUESTS")) |v| cfg.log_requests = try envBool("ZIGBASE_LOG_REQUESTS", v, diag);
```

(`log_level` cannot use `envEnum`: `std.log.Level`'s tag is `err`, but the documented spelling is `error`, and `parseLevel` is the single place that mapping lives.) Add all three names to `known_vars`, keeping it sorted.

- [ ] Add the parser arms in `src/cli.zig`'s `serve` loop (after `--trust-proxy` at :356-357), validating the value at parse time so a typo is rejected before boot:

```zig
        } else if (std.mem.eql(u8, a, "--log-format")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            if (logging.parseFormat(args[i]) == null) return ParseError.BadValue;
            sa.log_format = args[i];
        } else if (std.mem.eql(u8, a, "--log-level")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            if (logging.parseLevel(args[i]) == null) return ParseError.BadValue;
            sa.log_level = args[i];
        } else if (std.mem.eql(u8, a, "--no-request-log")) {
            sa.log_requests = false;
```

- [ ] Add `preinstallFromEnv` and `apply` to `src/logging.zig`:

```zig
/// First statement of `runCliImpl`: set the format/level so that everything logged
/// during startup — INCLUDING the fail-fast error for a malformed env var — comes out
/// in the operator's chosen encoding. Deliberately silent on an invalid value:
/// `Config.loadDiag` validates moments later and produces the actionable message, so
/// there is exactly one validation path and no chance of the two disagreeing.
pub fn preinstallFromEnv(environ: *const std.process.Environ.Map) void {
    if (environ.get("ZIGBASE_LOG_FORMAT")) |v| {
        if (parseFormat(v)) |f| format = f;
    }
    if (environ.get("ZIGBASE_LOG_LEVEL")) |v| {
        if (parseLevel(v)) |l| min_level = l;
    }
}

/// Install the fully resolved configuration (env, then `serve` flags). Called once
/// from `serveImpl` before any worker thread exists.
pub fn apply(cfg_format: Format, cfg_level: std.log.Level, cfg_requests: bool) void {
    format = cfg_format;
    min_level = cfg_level;
    request_logging = cfg_requests;
}
```

- [ ] Wire the three points in `src/framework.zig`: `logging.preinstallFromEnv(init.environ_map);` as the first statement of `runCliImpl` (before `cli.parse` at :1854); the flag overrides in `loadCfg` next to the other `ServeArgs` overrides (`if (sa.log_format) |v| cfg.log_format = logging.parseFormat(v).?;` — the `.?` is safe because `cli.parse` already rejected an invalid spelling, and the same for `log_level`; `if (sa.log_requests) |v| cfg.log_requests = v;`); and `logging.apply(cfg.log_format, cfg.log_level, cfg.log_requests);` at the top of `serveImpl`, before the pool opens.

- [ ] Update the help text — three rows in `printUsage`'s `ENVIRONMENT VARIABLES:` block (framework.zig:1990-2064, **before** the `EXAMPLES:` anchor at :2064, or `tests/admin/test_docs_parity.py` fails), matching the block's existing column style:

```
        \\  ZIGBASE_LOG_FORMAT          text|json — log line encoding (json = one object per line). Default text.
        \\  ZIGBASE_LOG_LEVEL           debug|info|warn|error — minimum severity. Default info.
        \\  ZIGBASE_LOG_REQUESTS        true|false — per-request access lines. Default true.
```

and the matching entries in `printServeUsage`, noting the flags are serve-only:

```
        \\  --log-format F      text|json. json emits one JSON object per line on stderr.
        \\  --log-level L       debug|info|warn|error. Default info.
        \\  --no-request-log    Suppress the per-request access lines.
        \\
        \\  The three logging knobs also work as ZIGBASE_LOG_FORMAT / ZIGBASE_LOG_LEVEL /
        \\  ZIGBASE_LOG_REQUESTS, which apply to every subcommand (these flags are serve-only).
```

- [ ] Add three rows to `README.md`'s env table (rows run :171-219, columns `| Env var | Flag | Default | Purpose |`):

```markdown
| `ZIGBASE_LOG_FORMAT` | `--log-format` | `text` | log encoding: `text` or `json` (one JSON object per line on stderr) |
| `ZIGBASE_LOG_LEVEL` | `--log-level` | `info` | minimum severity: `debug`, `info`, `warn`, `error` |
| `ZIGBASE_LOG_REQUESTS` | `--no-request-log` | `true` | emit a per-request access line (method, path, status, duration) |
```

- [ ] Create `docs/observability.md` — the canonical home for the machine-readable contracts this sub-project ships. Sections: **Log output** (both formats with a real sample line of each, the exact JSON keys and their order, the note that log records go to **stderr**); **The NDJSON contract** (convention 3 verbatim: skip non-JSON lines, never fail the run); **Request logging** (the record's fields, how to turn it off, that `path` is escaped and attacker-controlled); **Error codes** (the envelope, "match on `code`, never on `message`", `zigbase explain-code`, the append-only ledger and how to add a code); **Machine-readable CLI output** (conventions 1 and 2 including the full 0/1/2/3 exit scheme — in particular that **2 means the command ran correctly and found something needing judgment**, never that the tool broke — and the table of which commands support `--json`); **Capability discovery** (forward-reference to `GET /api/meta`, filled in by Task 10).

Under **Error codes**, include this paragraph so the casing split reads as a decision rather than drift — a reader who meets `validation_min` and `jwt-secret-persisted` in the same document will otherwise assume one of them is a mistake:

> **Two frozen id vocabularies, two casings — on purpose.** API error codes are `snake_case` (`validation_min`, `collections_frozen`): they were `snake_case` before they were frozen, and a code, once shipped, is permanent — respelling the existing 27 `validation_*` codes to gain cosmetic uniformity would break every consumer matching on them, which is exactly what the ledger exists to prevent. Doctor check ids are `dash-case` (`jwt-secret-persisted`), matching the repo's standing URL-segment convention. The two vocabularies never mix in one field, so nothing has to guess which rule applies: if it appears as an error envelope's `code` it is `snake_case`, and if it appears as a doctor check id it is `dash-case`.

Register it in `site/scripts/docs-registry.json` following the existing entry shape:

```json
  {
    "canonical": "docs/observability.md",
    "mirror": "observability.md",
    "frontmatter": {
      "title": "Observability & machine-readable output",
      "description": "Structured logging, the frozen error-code registry, JSON CLI output, and capability discovery — the contracts tools and agents build on.",
      "order": 5,
      "group": "reference"
    }
  }
```

`reference` currently runs 1 `api`, 2 `fields`, 3 `known-limitations`, 4 `changelog`, so **5 is free and uncontested** — SP-2, SP-3, and SP-5 all add to `guides`, not `reference`. Then make the other three edits from the four-edit rule: add `'observability'` to the `PUBLISHED` set in `site/scripts/gen-docs-mirror.mjs`, add `src/content/docs/observability.md` to `site/.gitignore`, and add `{ slug: 'observability', label: 'Observability' }` to the `reference` group in `site/src/config/sidebar.ts`. **Never hand-edit `site/src/content/docs/observability.md`** — it is generated.

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` (green), then `cd site && npm run build` (green, and the mirror appears), then the parity gate: `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q`.

- [ ] Verify end to end:

```sh
mise exec zig@0.16.0 -- zig build
./zig-out/bin/zigbase serve --insecure-cookies --data-dir /tmp/zb-logfmt --log-format json 2>&1 >/dev/null | head -5
```

Every line must parse as JSON. Ctrl-C, then `rm -rf /tmp/zb-logfmt`.

- [ ] Write `changelog.d/logging-knobs.md`:

```markdown
### Features

- `--log-format text|json` / `ZIGBASE_LOG_FORMAT` switches the whole log stream to one JSON object per line on stderr, and `--log-level` / `ZIGBASE_LOG_LEVEL` sets the minimum severity (`debug`, `info`, `warn`, `error`). The env vars apply to every subcommand; the flags are `serve`-only.
- New guide: **Observability & machine-readable output** (`docs/observability.md`) — the log formats, the NDJSON consumption rule, the frozen error-code registry, and the `--json` CLI conventions.
```

- [ ] Commit: `git commit -am "feat(logging): --log-format/--log-level knobs and the observability guide"`

---

### Task 7: Per-request access logging

**Files:**
- Modify: `src/server.zig` (`onRequest`, :283-362)
- Modify: `docs/observability.md` (fill in the Request logging section)
- Create: `changelog.d/request-logging.md`

**Interfaces:**
- Consumes: `logging.request(rec: RequestRecord)`, `logging.RequestRecord` (Task 4); `logging.request_logging` set by Task 6
- Produces: no new symbols

**Placement.** In `onRequest`, **not** in the socketless `route` seam. `route` is also driven by the in-process `zigbase.testing` harness (`App.routeForTest`, framework.zig:1662), which must not emit access logs, and only `onRequest` spans the true socket-to-response wall time. zap's own facil.io access log stays off (`.log = false`, server.zig:216) — its format is not ours to control and it would double every line.

**All exits must log.** `onRequest` has four `return` points: the `route(...) catch` raw-500 at :317-320, the two `resp.file` branches at :341-358, and the normal fall-through at :361. A `defer` placed immediately after `ctx` is constructed covers every one of them, including a future fifth.

**Steps:**

- [ ] Write the failing end-to-end test. Create `tests/admin/test_agent_contracts.py` with its own server launcher, because the shared `server` fixture sends stdout and stderr to `DEVNULL` (conftest.py:52) and this test must read the log stream. Model the launcher on `tests/admin/test_import.py:78-104`:

```python
import json, os, pathlib, shutil, socket, subprocess, tempfile, time, urllib.request, urllib.error
import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]


def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


class LoggedServer:
    """A `zigbase serve` whose stderr is captured to a file, so a test can assert on
    the log stream. The shared `server` fixture DEVNULLs both streams, so logging
    tests cannot use it."""

    def __init__(self, base, proc, log_path, data):
        self.base, self.proc, self.log_path, self.data = base, proc, log_path, data

    def log_lines(self):
        return self.log_path.read_text().splitlines()

    def get(self, path):
        try:
            with urllib.request.urlopen(f"{self.base}{path}", timeout=5) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()


@pytest.fixture()
def logged_server(binary, request):
    flags = list(getattr(request, "param", []) or [])
    data = tempfile.mkdtemp(prefix="zb_logged_")
    port = _free_port()
    log_path = pathlib.Path(data) / "server.log"
    env = {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_HTTP_PORT": str(port)}
    with open(log_path, "w") as log:
        proc = subprocess.Popen(
            [binary, "serve", "--insecure-cookies", *flags],
            env=env, stdout=log, stderr=subprocess.STDOUT,
        )
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            proc.terminate()
            pytest.fail(f"server never became reachable; log:\n{log_path.read_text()}")
        try:
            yield LoggedServer(f"http://127.0.0.1:{port}", proc, log_path, data)
        finally:
            proc.terminate(); proc.wait(timeout=5); shutil.rmtree(data, ignore_errors=True)


@pytest.mark.parametrize("logged_server", [["--log-format", "json"]], indirect=True)
def test_request_logging_json_is_one_object_per_line(logged_server):
    status, _ = logged_server.get("/api/health")
    assert status == 200
    status, _ = logged_server.get("/api/definitely-not-here")
    assert status == 404
    time.sleep(0.3)  # the line is written after the response is sent

    # EVERY line on the stream must be a JSON object — that is the NDJSON contract.
    records = []
    for line in logged_server.log_lines():
        if not line.strip():
            continue
        doc = json.loads(line)  # a non-JSON line is a hard failure for OUR own output
        assert set(doc) >= {"ts", "level", "scope", "msg"}, doc
        records.append(doc)

    reqs = [r for r in records if r.get("msg") == "request"]
    by_path = {r["path"]: r for r in reqs}
    assert by_path["/api/health"]["status"] == 200
    assert by_path["/api/health"]["method"] == "GET"
    assert isinstance(by_path["/api/health"]["duration_ms"], int)
    # The 404 fall-through path logs too — not just the happy path.
    assert by_path["/api/definitely-not-here"]["status"] == 404


@pytest.mark.parametrize("logged_server", [["--log-format", "json", "--no-request-log"]], indirect=True)
def test_no_request_log_suppresses_access_lines_but_not_startup_lines(logged_server):
    assert logged_server.get("/api/health")[0] == 200
    time.sleep(0.3)
    docs = [json.loads(l) for l in logged_server.log_lines() if l.strip()]
    assert not [d for d in docs if d.get("msg") == "request"], "access lines should be suppressed"
    # Discriminating negative control: the server still logged SOMETHING, so an empty
    # log (a broken server) cannot make this test pass.
    assert docs, "startup lines should still be present"
```

- [ ] Run `mise exec python@3.13 -- python -m pytest tests/admin/test_agent_contracts.py -q`. **Expected failure:** `KeyError: '/api/health'` — no request records exist yet.

- [ ] Implement in `src/server.zig`'s `onRequest`. Capture the start before the arena, and register the `defer` immediately after `ctx` is constructed (i.e. right after the `.app = self.app,` line at :293-294), before the header assignments:

```zig
        fn onRequest(r: zap.Request) !void {
            const self = Self.instance.?;
            const started_ns = std.Io.Timestamp.now(self.app.io, .awake).nanoseconds;
            var arena = std.heap.ArenaAllocator.init(self.app.allocator);
            defer arena.deinit();
            var ctx = http.RequestCtx{ … };
            // Access log. A `defer` (not a call at the bottom) because onRequest has four
            // `return` points — the raw-500 escape, both sendFile branches, and the normal
            // fall-through — and every one of them must produce exactly one line.
            // `logged_status` is what actually went on the wire, so a sendFile failure that
            // downgrades a 200 to a 404 is logged as the 404 the client saw.
            var logged_status: u16 = 0;
            defer {
                const elapsed_ns = std.Io.Timestamp.now(self.app.io, .awake).nanoseconds - started_ns;
                logging.request(.{
                    .method = @tagName(ctx.method),
                    .path = ctx.path,
                    .status = logged_status,
                    .duration_ms = @intCast(@max(0, @divTrunc(elapsed_ns, std.time.ns_per_ms))),
                });
            }
```

Add `const logging = @import("logging.zig");` to the imports at the top of the file. Then set `logged_status` at each exit: `logged_status = 500;` immediately before the `sendRawEnvelope(r, 500, …); return;` at :317-320; `logged_status = resp.status;` immediately after `setZapStatus(r, resp.status);` at :322; and `logged_status = 404;` inside each of the two `sendFileRange`/`sendFile` `catch` blocks at :347-350 and :354-356 (which downgrade to a raw 404).

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` (green), then `mise exec python@3.13 -- python -m pytest tests/admin/test_agent_contracts.py -q` (green).

- [ ] Confirm the same works in text mode, which is the default an operator sees:

```sh
mise exec zig@0.16.0 -- zig build
./zig-out/bin/zigbase serve --insecure-cookies --data-dir /tmp/zb-req 2>/tmp/zb-req.log &
sleep 1; curl -s localhost:8090/api/health >/dev/null; sleep 1; kill %1
grep 'info(http): GET /api/health 200' /tmp/zb-req.log
rm -rf /tmp/zb-req /tmp/zb-req.log
```

- [ ] Fill in the **Request logging** section of `docs/observability.md`: the record's five JSON keys in order (`msg` is always `"request"`, then `method`, `path`, `status`, `duration_ms`), the text-mode rendering, that `path` is client-controlled and therefore JSON-escaped, that these lines are `info` so `--log-level warn` silences them too, and that `--no-request-log` is the way to turn them off when a reverse proxy already ships access logs. Rebuild the site: `cd site && npm run build`.

- [ ] Write `changelog.d/request-logging.md`:

```markdown
### Features

- Per-request access logging: every HTTP request now emits one line with its method, path, status, and duration — as a structured record under `--log-format json`, or `GET /api/health 200 3ms` in text mode. Turn it off with `--no-request-log` / `ZIGBASE_LOG_REQUESTS=false` when a reverse proxy already ships access logs.
```

- [ ] Commit: `git commit -am "feat(logging): per-request access lines on every response path"`

---

### Task 8: Close the silent-500 hole — four swallowed error paths

**Files:**
- Modify: `src/server.zig` (`route`, :240-281; add a module-scope `reportRouteError` helper and a test)
- Modify: `docs/framework.md` (the `onError` section — grep for `onError`)
- Create: `changelog.d/silent-500-fix.md`

**Interfaces:**
- Consumes: `events.ErrorEvent`, `events.dispatchError(app, dispatch, *ErrorEvent)`, `request.RequestContext` — all already imported by `server.zig`
- Produces: `fn reportRouteError(ctx: *http.RequestCtx, app: *app_mod.App, err: anyerror, origin: []const u8) void`

**The four sites.** A consumer route's handler error is logged and dispatched to `onError` (server.zig:702-713). The built-in equivalents are not — they are swallowed:

| line | code today | consequence |
|---|---|---|
| 247-249 | `router.tryDispatch(routes, ctx) catch { return ApiError.internal()… }` | every built-in handler failure becomes an unexplained 500: no log line, no `onError`, no Sentry event |
| 260 | `state_api.handle(ctx) catch try ApiError.internal()…` | same, for a remapped `/api/state` |
| 263 | `if (dispatchCustom(ctx) catch null) \|hit\|` | `dispatchCustom`'s *own* failures (pool acquisition, `authenticate`) vanish and the request silently falls through to static/404 — a **wrong status**, not just a missing log |
| 271-276 | `static_files.serve(…) catch null` | a static read failure is indistinguishable from a genuine miss |

**Treatment differs by class**, matching the existing `dispatchCustom` policy that only `status >= 500` is an incident (server.zig:704-713): the first three are genuine server errors → log at `err` **and** dispatch an `ErrorEvent`; the fourth is a filesystem miss on a browser-facing path → log at `warn`, keep the 404, do **not** raise an incident.

**On the `RequestContext`.** `dispatchCustom` hands `onError` a fully resolved `rctx` (principal, tenancy, session). At the `route` layer no principal exists yet — built-in handlers authenticate internally — so the event carries a minimal context with only the method. Populating it with a fabricated principal would be worse than an honest blank.

**Steps:**

- [ ] Add the failing test to `src/server.zig`, beside the existing `dispatchCustom` error-policy test at :722. It drives the **real** code path — a built-in route failing under memory pressure — rather than calling the helper directly:

```zig
test "route: a failing BUILT-IN handler is reported to onError, not silently 500ed" {
    const db = @import("db.zig");
    const App = app_mod.App;
    const report_log = @import("report/log.zig");

    const H = struct {
        var on_error_calls: usize = 0;
        fn onErr(ev: *events.ErrorEvent) void {
            _ = ev;
            on_error_calls += 1;
        }
    };

    const ga = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
    defer ga.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
    defer ga.free(db_path);
    var pool = try db.Pool.init(ga, std.testing.io, db_path);
    defer pool.deinit();

    const dispatch = events.Dispatch{ .on_error = H.onErr };

    // Silence dispatchError's log fallback: the test runner counts std.log.err as a failure.
    report_log.log_sink = struct {
        fn sink(_: []const u8) void {}
    }.sink;
    defer report_log.log_sink = null;
    const prev_sink = logging.sink;
    logging.sink = struct {
        fn sink(_: []const u8) void {}
    }.sink;
    defer logging.sink = prev_sink;

    // NEGATIVE CONTROL first: a healthy request must NOT raise an incident. Without
    // this, a test that fires onError unconditionally would still pass below.
    {
        H.on_error_calls = 0;
        var arena = std.heap.ArenaAllocator.init(ga);
        defer arena.deinit();
        var app = App{ .allocator = arena.allocator(), .io = std.testing.io, .pool = &pool, .dispatch = &dispatch };
        var ctx = http.RequestCtx{ .method = .GET, .path = "/api/health", .allocator = RequestArena.from(&arena), .app = &app };
        const resp = try Server(.{}).route(&ctx);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqual(@as(usize, 0), H.on_error_calls);
    }

    // Now the real thing: starve the request arena so the built-in handler fails.
    // tryDispatch propagates the error into route()'s catch at server.zig:247.
    {
        H.on_error_calls = 0;
        var failing = std.testing.FailingAllocator.init(ga, .{ .fail_index = 0 });
        var arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena.deinit();
        var app = App{ .allocator = ga, .io = std.testing.io, .pool = &pool, .dispatch = &dispatch };
        var ctx = http.RequestCtx{ .method = .GET, .path = "/api/health", .allocator = RequestArena.from(&arena), .app = &app };
        // Rendering the 500 envelope needs the same starved arena, so route() surfaces
        // the error to onRequest (which writes the static raw envelope). Either outcome
        // is acceptable — what must NOT happen is silence.
        _ = Server(.{}).route(&ctx) catch {};
        try std.testing.expectEqual(@as(usize, 1), H.on_error_calls);
    }
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all`. **Expected failure:** `expected 1, found 0` in the second block — the error was swallowed.

- [ ] Add the helper at module scope in `src/server.zig` (beside `forbiddenResp`, ~:476), so it is compiled once rather than per-`gates` instantiation:

```zig
/// Report an error escaping a BUILT-IN routing path. Consumer-route handler errors
/// already take this route in `dispatchCustom` (:702-713); these paths used to swallow
/// theirs entirely, producing an unexplained 500 with no log line, no `onError`, and no
/// Sentry event. `origin` names which path failed so an operator can tell a built-in
/// handler failure from a feature-state one.
///
/// The `RequestContext` carries only the method: at this layer no principal has been
/// resolved (built-in handlers authenticate internally), and a fabricated one would be
/// worse than an honest blank.
fn reportRouteError(ctx: *http.RequestCtx, app: *app_mod.App, err: anyerror, origin: []const u8) void {
    std.log.err("{s} failed for {s} {s}: {s}", .{ origin, @tagName(ctx.method), ctx.path, @errorName(err) });
    var rctx = request.RequestContext{ .method = @tagName(ctx.method) };
    var ev = events.ErrorEvent{
        .app = app,
        .ctx = &rctx,
        .err = err,
        .phase = .request,
        .message = @errorName(err),
    };
    events.dispatchError(app, app.dispatch, &ev);
}
```

- [ ] Rewrite the four sites in `route` (:240-281):

```zig
            // Built-in API routes win over custom routes.
            const builtin = router.tryDispatch(routes, ctx) catch |e| {
                reportRouteError(ctx, app, e, "built-in route");
                return try ApiError.internal().toResponse(ctx.allocator.a);
            };
```

```zig
                    return state_api.handle(ctx) catch |e| {
                        reportRouteError(ctx, app, e, "feature-state route");
                        return try ApiError.internal().toResponse(ctx.allocator.a);
                    };
```

```zig
            // dispatchCustom's OWN failures (pool acquisition, authenticate) are server
            // errors — swallowing them here silently fell through to static/404, serving
            // the wrong status. A handler's error is already handled inside dispatchCustom.
            const custom = dispatchCustom(ctx) catch |e| {
                reportRouteError(ctx, app, e, "custom route dispatch");
                return try ApiError.internal().toResponse(ctx.allocator.a);
            };
            if (custom) |hit| return hit;
```

```zig
                const served = static_files.serve(app.io, ctx, app.static_source, .{ … }) catch |e| blk: {
                    // A static read failure is a browser-facing miss, not an incident:
                    // log it so it is diagnosable, but keep the 404 and do NOT raise an
                    // onError/Sentry event (same policy as a deliberate 4xx elsewhere).
                    std.log.warn("static file serve failed for {s}: {s}", .{ ctx.path, @errorName(e) });
                    break :blk null;
                };
                if (served) |hit| return hit;
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — green, both blocks of the new test passing.
- [ ] Prove the negative control bites: temporarily make `reportRouteError` fire on every request (call it unconditionally at the top of `route`), re-run, and confirm the **first** block now fails with `expected 0, found 1`. **Revert with `Edit`, not `git checkout`.**
- [ ] Run the broader e2e subset, since this touches the dispatch chain every request walks: `mise exec python@3.13 -- python -m pytest tests/admin/test_static_files.py tests/admin/test_state.py tests/admin/test_realtime.py tests/admin/test_agent_contracts.py -q`.
- [ ] Update the `onError` section of `docs/framework.md` to say that built-in handler failures now reach `onError` too, with a `RequestContext` carrying only the method. Rebuild the site: `cd site && npm run build`.

- [ ] Write `changelog.d/silent-500-fix.md`:

```markdown
### Fixes

- **A failing built-in endpoint no longer returns an unexplained 500 in silence.** Errors escaping the built-in route table, the feature-state route, and custom-route dispatch are now logged and delivered to your `onError` hook (and to Sentry, when configured) exactly as consumer-route errors already were. A static-file read failure is logged as a warning and still returns 404.
- Custom-route dispatch failures (connection-pool acquisition, authentication) used to be swallowed and fall through to static-file handling, answering with the wrong status; they now return 500.
```

- [ ] Commit: `git commit -am "fix(server): report errors escaping built-in routes instead of swallowing them"`

---

### Task 9: `--json` on `version` and `migrate status`

**Files:**
- Modify: `src/cli.zig` (`VersionArgs`, `Command.version` payload, `MigrateArgs.json`, parse arms, tests), `src/framework.zig` (`printVersion` :2091-2124, `migrateStatusImpl` :2422-2451, `printUsage` `COMMANDS:`, `printMigrateUsage` :2181), `docs/framework.md:3596-3605` (the `migrate status` example)
- Modify: `docs/observability.md` (fill in the machine-readable-CLI table), `tests/admin/test_agent_contracts.py`
- Create: `changelog.d/cli-json-output.md`

**Interfaces:**
- Produces: `pub const VersionArgs = struct { json: bool = false }`; `Command.version: VersionArgs` (was `void`); `MigrateArgs.json: bool = false`; `fn printVersionJson(io: std.Io, file: std.Io.File) void`; `fn migrateStatusJson(io: std.Io, out: std.Io.File, status: provision.MigrationStatus) void`
- Consumes: `build_options`, `provision.migrationStatus` (framework.zig:2438)

**Scope.** `version` and `migrate status` are the only status-like commands that exist today (`migrate dump` already has `--out`, `import` is a mutation with a human summary, `rewrap` and `typegen` are mutations). SP-3 adds `doctor` and `serve status` (a subcommand, not a `--status` flag); SP-5 adds `schema dump`/`schema apply` and a JSON `import` summary. All follow these conventions.

**Exit-code change.** `migrate status` currently always exits 0. It now exits **1 when anything is pending or orphaned**, in *both* text and JSON mode, so it works as a deployment gate (`zigbase migrate status || zigbase migrate`). Consistency between modes matters more than preserving an exit code nothing in this repo depends on — `grep -rn "migrate status" .github/ scripts/` finds no callers. This is a `Changed` entry.

**Output shapes** (field order is contract; `snake_case` per convention 7 — this is the CLI plane, not the REST plane):

```json
{"zigbase":"0.12.0","commit":"087ca67","build":"ReleaseSafe","target":"x86_64-linux-gnu","zig":"0.16.0","components":{"sqlite":"3.…","sqlite_source_id":"…","sqlite_vec":"0.…","sqlite_vec_linked":false,"zap":"0.…","zap_commit":"…","facil":"0.…"}}
```

```json
{"migrations":[{"id":"001_init","applied":true,"applied_at":"2026-08-08T12:00:00"},{"id":"002_x","applied":false,"applied_at":null}],"orphaned":[{"id":"000_gone","applied_at":"…"}],"summary":{"declared":2,"applied":1,"pending":1,"orphaned":1},"ok":false}
```

`ok` is the machine form of the exit code: `true` exactly when `pending == 0 and orphaned == 0`. An agent can branch on either.

**Steps:**

- [ ] Add the failing parser tests to `src/cli.zig`:

```zig
test "version accepts --json in every spelling" {
    try std.testing.expectEqual(false, (try parse(&.{"version"}, .{})).version.json);
    try std.testing.expectEqual(true, (try parse(&.{ "version", "--json" }, .{})).version.json);
    try std.testing.expectEqual(true, (try parse(&.{ "--version", "--json" }, .{})).version.json);
    try std.testing.expectEqual(true, (try parse(&.{ "-V", "--json" }, .{})).version.json);
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "version", "--nope" }, .{}));
}

test "migrate status accepts --json; the other actions reject it" {
    const s = try parse(&.{ "migrate", "status", "--json" }, .{});
    try std.testing.expectEqual(MigrateAction.status, s.migrate.action);
    try std.testing.expectEqual(true, s.migrate.json);
    try std.testing.expectEqual(false, (try parse(&.{ "migrate", "status" }, .{})).migrate.json);
    // --json is a status-only flag: it means nothing for apply/rollback/dump.
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate", "--json" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "migrate", "dump", "--json" }, .{}));
}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all`. **Expected failure:** compile error — `version` has no field `json`.

- [ ] Implement in `src/cli.zig`: add `pub const VersionArgs = struct { json: bool = false };`, change the union member to `version: VersionArgs`, add `json: bool = false` to `MigrateArgs`, replace the bare version branch at :130-133 with a loop that accepts `--json` and rejects anything else, and add `} else if (ma.action == .status and std.mem.eql(u8, a, "--json")) { ma.json = true;` to the migrate flag loop (mirroring how `--out` is gated to `.dump` at :186-189).

- [ ] Implement the two JSON emitters in `src/framework.zig`, beside their text counterparts:

```zig
/// `zigbase version --json` (SP-1). Exactly one object on stdout; same build_options
/// source of truth as `printVersion` and `GET /api/health`'s `versions`, so the three
/// can never disagree. Key order is contract.
fn printVersionJson(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        "{{\"zigbase\":{f},\"commit\":{f},\"build\":\"{t}\",\"target\":\"{t}-{t}-{t}\",\"zig\":{f}," ++
            "\"components\":{{\"sqlite\":{f},\"sqlite_source_id\":{f},\"sqlite_vec\":{f},\"sqlite_vec_linked\":{},"++
            "\"zap\":{f},\"zap_commit\":{f},\"facil\":{f}}}}}\n",
        .{
            std.json.fmt(build_options.version, .{}),
            std.json.fmt(build_options.commit, .{}),
            builtin.mode,
            builtin.target.cpu.arch,
            builtin.target.os.tag,
            builtin.target.abi,
            std.json.fmt(builtin.zig_version_string, .{}),
            std.json.fmt(build_options.sqlite_version, .{}),
            std.json.fmt(build_options.sqlite_source_id, .{}),
            std.json.fmt(build_options.sqlite_vec_version, .{}),
            build_options.vector,
            std.json.fmt(build_options.zap_version, .{}),
            std.json.fmt(build_options.zap_commit, .{}),
            std.json.fmt(build_options.facil_version, .{}),
        });
}
```

(`{t}` is Zig 0.16's enum/tag format specifier — the same one `printVersion` reaches for via `@tagName`; if it does not apply cleanly to these operands, use `@tagName(...)` with `{s}` as `printVersion` already does at :2110-2114.)

```zig
/// `zigbase migrate status --json`. One object, stdout only; the text renderer's
/// prose stays on the text path so the two never interleave.
fn migrateStatusJson(io: std.Io, out: std.Io.File, status: provision.MigrationStatus) void {
    emit(io, out, "{{\"migrations\":[", .{});
    for (status.declared, 0..) |e, i| {
        if (i > 0) emit(io, out, ",", .{});
        if (e.applied_at) |at|
            emit(io, out, "{{\"id\":{f},\"applied\":true,\"applied_at\":{f}}}", .{ std.json.fmt(e.id, .{}), std.json.fmt(at, .{}) })
        else
            emit(io, out, "{{\"id\":{f},\"applied\":false,\"applied_at\":null}}", .{std.json.fmt(e.id, .{})});
    }
    emit(io, out, "],\"orphaned\":[", .{});
    for (status.orphaned, 0..) |o, i| {
        if (i > 0) emit(io, out, ",", .{});
        emit(io, out, "{{\"id\":{f},\"applied_at\":{f}}}", .{ std.json.fmt(o.name, .{}), std.json.fmt(o.applied_at, .{}) });
    }
    emit(io, out,
        "],\"summary\":{{\"declared\":{d},\"applied\":{d},\"pending\":{d},\"orphaned\":{d}}},\"ok\":{}}}\n",
        .{
            status.declared.len,     status.applied_count,
            status.pending_count,    status.orphaned.len,
            status.pending_count == 0 and status.orphaned.len == 0,
        });
}
```

- [ ] Rewire the dispatch. In `runCliImpl`, `.version => |va| if (va.json) printVersionJson(init.io, std.Io.File.stdout()) else printVersion(init.io, std.Io.File.stdout()),`. In `migrateStatusImpl`, after `const status = try provision.migrationStatus(...)` (framework.zig:2436), branch on `ma.json` — call `migrateStatusJson` or keep the existing text block — then apply the exit code to **both**:

```zig
    // Exit 1 when the database is not up to date, so `migrate status` can gate a
    // deploy script. `ok` in the JSON body carries the same signal.
    if (status.pending_count != 0 or status.orphaned.len != 0) std.process.exit(1);
```

`emit` flushes on every call (framework.zig:1926-1931), so nothing is buffered when `std.process.exit` skips the deferred cleanup.

- [ ] Update the help text: append `Add --json for one JSON object.` to the `version` line in `printUsage`'s `COMMANDS:` block, and add a `--json` row plus the exit-code note to `printMigrateUsage` (framework.zig:2181-2185):

```
        \\  --json           (status only) Emit one JSON object on stdout instead of the text report.
        \\
        \\  `migrate status` exits 1 when any migration is pending or orphaned, so it can
        \\  gate a deploy: `zigbase migrate status || zigbase migrate`.
```

- [ ] Add the end-to-end tests to `tests/admin/test_agent_contracts.py`. These are the first CLI-stdout tests in the repo — there is no shared one-shot helper, so add a small local one:

```python
def _run(binary, *args, env_extra=None):
    env = {**os.environ, **(env_extra or {})}
    return subprocess.run([binary, *args], env=env, capture_output=True, text=True)


def test_version_json_is_exactly_one_object_on_stdout(binary):
    r = _run(binary, "version", "--json")
    assert r.returncode == 0, r.stderr
    doc = json.loads(r.stdout)  # fails if anything else shares stdout
    assert doc["zigbase"] and doc["commit"]
    assert set(doc["components"]) == {
        "sqlite", "sqlite_source_id", "sqlite_vec", "sqlite_vec_linked", "zap", "zap_commit", "facil",
    }
    # Convention 7: CLI JSON is snake_case; a camelCase key means the two planes got mixed.
    assert not [k for k in doc["components"] if any(c.isupper() for c in k)]
    # The text form must remain unchanged for humans.
    assert _run(binary, "version").stdout.startswith("zigbase ")


def test_migrate_status_json_and_exit_code(binary, tmp_path):
    data = str(tmp_path / "d")
    r = _run(binary, "migrate", "status", "--json", "--data-dir", data)
    doc = json.loads(r.stdout)
    assert set(doc) == {"migrations", "orphaned", "summary", "ok"}
    assert doc["ok"] is (doc["summary"]["pending"] == 0 and doc["summary"]["orphaned"] == 0)
    assert r.returncode == (0 if doc["ok"] else 1)
    # Convention 1: prose never contaminates stdout under --json.
    assert r.stdout.count("\n") == 1, f"expected one line on stdout, got {r.stdout!r}"


def test_explain_code_json_contract(binary):
    r = _run(binary, "explain-code", "collections_frozen", "--json")
    assert r.returncode == 0, r.stderr
    doc = json.loads(r.stdout)
    assert doc == {**doc, "code": "collections_frozen", "known": True}
    assert doc["summary"] and doc["explanation"]

    unknown = _run(binary, "explain-code", "not_a_real_code", "--json")
    assert unknown.returncode == 1
    assert json.loads(unknown.stdout) == {"code": "not_a_real_code", "known": False}

    listing = _run(binary, "explain-code", "--json")
    assert listing.returncode == 0
    codes = json.loads(listing.stdout)["codes"]
    assert {"code", "summary"} == set(codes[0])
    assert "validation_min" in {c["code"] for c in codes}
```

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` (green) and `mise exec python@3.13 -- python -m pytest tests/admin/test_agent_contracts.py -q` (green).
- [ ] Update `docs/framework.md:3596-3605` — the `migrate status` example gains the `--json` form and the exit-code semantics. Fill in the **Machine-readable CLI output** table in `docs/observability.md`: which commands take `--json`, conventions 1 and 2 restated, and the `zigbase migrate status || zigbase migrate` gate idiom. Rebuild: `cd site && npm run build`.

- [ ] Write `changelog.d/cli-json-output.md`:

```markdown
### Features

- `zigbase version --json` and `zigbase migrate status --json` emit exactly one JSON object on stdout (prose and warnings go to stderr), for scripts and agents that would otherwise parse the human report.

### Changed

- `zigbase migrate status` now exits **1** when any migration is pending or orphaned, and 0 otherwise, so it can gate a deploy: `zigbase migrate status || zigbase migrate`. It previously always exited 0. The JSON form carries the same signal as `ok`.
```

- [ ] Commit: `git commit -am "feat(cli): --json output for version and migrate status"`

---

### Task 10: `GET /api/meta` — capability discovery

**Files:**
- Create: `src/api/meta.zig`
- Modify: `src/app.zig` (mirror `gates` onto the runtime `App`, beside `collections_frozen` at :198-203), `src/framework.zig` (set `.gates = opts.gates` where the `App` literal is built — grep `collections_frozen = ` in the App construction sites, framework.zig:1600 and :3250 region), `src/server.zig` (one route-table entry + one handler thunk), `src/root.zig` (test-block entry)
- Modify: `docs/api.md` (a new `## Meta` section before `## Health` at :1416), `docs/observability.md` (fill in Capability discovery), `tests/admin/test_agent_contracts.py`
- Create: `changelog.d/api-meta.md`

**Interfaces:**
- Consumes: `ctx.app.gates` (new mirror), `app.collections_frozen`, `app.max_upload_size` (app.zig:55), `app.features_public_route` (app.zig:149), `build_options.{version, commit, postgres, s3, vector, dev_mode}`
- Produces: `pub fn handle(ctx: *http.RequestCtx) !http.Response`

**Why a new endpoint** — see design decision D6. `/api/health` is a liveness probe hit on a tight interval and must stay cheap; `/api/state` is the *per-subject, DB-backed* flag projection (`src/api/state.zig` takes a pooled reader and resolves sticky experiments). `/api/meta` is process-constant build-and-config facts with no DB access and no subject. `/api/meta` cross-links to the others through its `endpoints` object rather than duplicating them.

**Security invariant** (state it in the module doc comment): every field is a fact an unauthenticated client can already establish by probing. Each capability bool corresponds to a route group that already answers 404 or 200 anonymously; `collectionsFrozen` is already readable from the 403 at `src/api/collections.zig:63-69`; `maxUploadSize` is already discoverable by uploading; `endpoints.state` is the public feature-state mount, public by design. **Never** add a config value, filesystem path, host, connection string, or credential. Follow `src/api/health.zig`'s precedent, whose doc comment carries the same rule.

**Response shape** (key order is contract):

```json
{"zigbase":"0.12.0","commit":"087ca67","api":1,
 "capabilities":{"admin":true,"analytics":true,"collectionsFrozen":false,"devMode":false,
   "magicLink":true,"mailUnsubscribe":true,"mailWebhook":true,"oauth2":true,"postgres":false,
   "s3":false,"senders":true,"tenancy":true,"vector":false,"webauthn":true},
 "endpoints":{"health":"/api/health","state":"/api/state","realtimeSse":"/api/realtime/sse"},
 "limits":{"maxUploadSize":52428800}}
```

`api` is the meta-contract version, starting at `1`; bump it only if a field is removed or changes meaning (adding fields is not a bump). `endpoints.state` is `null` when the feature-state route is disabled and carries the custom path when remapped — genuinely undiscoverable otherwise.

**Keys here are `camelCase`, deliberately** (convention 7): this is the REST plane, where `GET /api/health` already ships `sqliteVec` and the whole records API is camelCase. The `snake_case` rule applies to CLI JSON only — do not "fix" these to match `version --json`.

**Steps:**

- [ ] Mirror the gates onto the runtime `App` — `src/app.zig`, beside `collections_frozen`:

```zig
    /// Comptime route gates (server.Gates), mirrored onto the runtime App so
    /// `GET /api/meta` can report which optional route groups this binary carries.
    /// A plain struct of bools — no fn pointers — so it does not affect the gating
    /// invariant (`scripts/check-gating.sh`) or Zig's lazy analysis.
    gates: @import("server.zig").Gates = .{},
```

Set `.gates = opts.gates,` in both places the `App` literal is constructed in `src/framework.zig` (the serve path and the `bootApp` test path — find them with `grep -n "collections_frozen = " src/framework.zig`).

- [ ] Write `src/api/meta.zig` with the handler and its tests. Follow `src/api/health.zig`'s pure-handler test style (no live app needed for the defaults):

```zig
const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const build_options = @import("build_options");

/// The meta-contract version. Bump ONLY when a field is removed or changes meaning;
/// adding a field is backwards-compatible and does not bump it.
pub const api_version: u32 = 1;

/// GET /api/meta -> 200, the capability probe.
///
/// PUBLIC and UNAUTHENTICATED, and deliberately so: every field here is a fact an
/// anonymous client can already establish by probing. Each capability bool corresponds
/// to a route group that already answers 404 or 200 without a token; `collectionsFrozen`
/// is already readable from the 403 that the runtime DDL endpoints return; `maxUploadSize`
/// is already discoverable by uploading. This endpoint saves an agent from probing —
/// it does not disclose anything probing would not.
///
/// NEVER add a config value, filesystem path, hostname, connection string, or credential
/// here. Same rule as `api/health.zig`.
///
/// This is NOT `/api/health` (a liveness probe on a tight interval, kept small) and NOT
/// `/api/state` (the per-subject, DB-backed feature-flag projection). It touches no
/// database and is constant for the process lifetime.
pub fn handle(ctx: *http.RequestCtx) !http.Response {
    const app = ctx.app orelse return .{ .status = 500, .body = "{}" };
    const g = app.gates;
    const body = try std.json.Stringify.valueAlloc(ctx.allocator.a, .{
        .zigbase = build_options.version,
        .commit = build_options.commit,
        .api = api_version,
        .capabilities = .{
            .admin = g.admin,
            .analytics = g.analytics,
            .collectionsFrozen = app.collections_frozen,
            .devMode = build_options.dev_mode,
            .magicLink = g.magic_link,
            .mailUnsubscribe = g.mail_unsubscribe,
            .mailWebhook = g.mail_webhook,
            .oauth2 = g.oauth2,
            .postgres = build_options.postgres,
            .s3 = build_options.s3,
            .senders = g.senders,
            .tenancy = g.tenancy,
            .vector = build_options.vector,
            .webauthn = g.webauthn,
        },
        .endpoints = .{
            .health = "/api/health",
            .state = app.features_public_route,
            .realtimeSse = "/api/realtime/sse",
        },
        .limits = .{ .maxUploadSize = app.max_upload_size },
    }, .{});
    return .{ .status = 200, .body = body };
}

test "meta reports the default gates, the frozen flag, and the state mount" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = app_mod.App{ .allocator = arena.allocator(), .io = std.testing.io, .pool = undefined };
    var ctx = http.RequestCtx{
        .method = .GET,
        .path = "/api/meta",
        .allocator = RequestArena.from(&arena),
        .app = &app,
    };
    const resp = try handle(&ctx);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, resp.body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(build_options.version, root.get("zigbase").?.string);
    try std.testing.expectEqual(@as(i64, api_version), root.get("api").?.integer);
    const caps = root.get("capabilities").?.object;
    try std.testing.expectEqual(true, caps.get("admin").?.bool);
    try std.testing.expectEqual(false, caps.get("collectionsFrozen").?.bool);
    try std.testing.expectEqualStrings("/api/state", root.get("endpoints").?.object.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 50 << 20), root.get("limits").?.object.get("maxUploadSize").?.integer);
}

test "meta tracks collections_frozen and a disabled/remapped state route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = app_mod.App{ .allocator = arena.allocator(), .io = std.testing.io, .pool = undefined };
    app.collections_frozen = true;
    app.features_public_route = null;
    app.gates = .{ .webauthn = false, .oauth2 = false };
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/meta", .allocator = RequestArena.from(&arena), .app = &app };

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, (try handle(&ctx)).body, .{});
    defer parsed.deinit();
    const caps = parsed.value.object.get("capabilities").?.object;
    // The whole point of the endpoint: frozen mode is a boolean, not a 403 message.
    try std.testing.expectEqual(true, caps.get("collectionsFrozen").?.bool);
    try std.testing.expectEqual(false, caps.get("webauthn").?.bool);
    try std.testing.expectEqual(false, caps.get("oauth2").?.bool);
    try std.testing.expectEqual(std.json.Value.null, parsed.value.object.get("endpoints").?.object.get("state").?);
}

test "meta never leaks a config value, path, or secret" {
    // Guard rail: if someone adds a field carrying deployment config, this fails.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = app_mod.App{ .allocator = arena.allocator(), .io = std.testing.io, .pool = undefined };
    app.jwt_secret = "super-secret-value";
    app.data_dir = "/srv/private/zb_data";
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/meta", .allocator = RequestArena.from(&arena), .app = &app };
    const body = (try handle(&ctx)).body;
    try std.testing.expect(std.mem.indexOf(u8, body, "super-secret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/srv/private") == null);
}
```

Check `src/app.zig` for the real field names used in that last test (grep `jwt_secret` and `data_dir` in `src/app.zig`) and use whatever it actually declares; if a field does not exist on `App`, drop that assertion rather than inventing one.

- [ ] Register the route and the file. In `src/server.zig`, add the thunk beside `healthHandler` (:42-44) and one entry in the base route table (:107-162), directly after the `/api/health` line so the two read together:

```zig
fn metaHandler(ctx: *http.RequestCtx) anyerror!http.Response {
    return meta.handle(ctx);
}
```

```zig
                .{ .method = .GET, .pattern = "/api/meta", .handler = metaHandler },
```

plus `const meta = @import("api/meta.zig");` in the import block. In `src/root.zig`'s test block add `_ = @import("api/meta.zig");`.

- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — the three new tests pass.

- [ ] Add the end-to-end test to `tests/admin/test_agent_contracts.py`, including the discriminating check that frozen mode is now readable without provoking a 403:

```python
def test_api_meta_is_public_and_reports_capabilities(logged_server):
    status, body = logged_server.get("/api/meta")
    assert status == 200, body  # no Authorization header — the endpoint is public
    doc = json.loads(body)
    assert list(doc) == ["zigbase", "commit", "api", "capabilities", "endpoints", "limits"]
    assert doc["api"] == 1
    assert doc["capabilities"]["collectionsFrozen"] is False
    assert doc["endpoints"]["state"] == "/api/state"
    assert doc["limits"]["maxUploadSize"] > 0
    # It must never carry deployment config.
    for leak in ("jwt", "secret", "data_dir", "dataDir", "password"):
        assert leak not in body.lower(), f"/api/meta leaked {leak}: {body}"


def test_api_meta_agrees_with_health_on_version(logged_server):
    meta = json.loads(logged_server.get("/api/meta")[1])
    health = json.loads(logged_server.get("/api/health")[1])
    # One source of truth (build_options) feeds both; a mismatch means one drifted.
    assert meta["zigbase"] == health["versions"]["zigbase"]
    assert meta["commit"] == health["versions"]["commit"]
```

- [ ] Run `mise exec python@3.13 -- python -m pytest tests/admin/test_agent_contracts.py -q` — green.

- [ ] Document it. Add a `## Meta` section to `docs/api.md` immediately before `## Health` (:1416): the full response with every capability key explained, the `api` versioning rule, the security note (only probe-discoverable facts), and — the headline — *"To find out whether runtime schema changes are possible, read `capabilities.collectionsFrozen`; never string-match the 403."* Cross-link `## Health` and `## Feature state (public)` so the three-endpoint split is explicit. Fill in the **Capability discovery** section of `docs/observability.md` with the same split and a one-line curl example. Rebuild: `cd site && npm run build`.

- [ ] Write `changelog.d/api-meta.md`:

```markdown
### Features

- **`GET /api/meta`** — a public, unauthenticated capability probe reporting the running version and commit, which optional route groups this binary carries (admin, OAuth2, WebAuthn, magic link, tenancy, analytics, senders, mail webhook/unsubscribe), which build flags are on (Postgres, S3, vector, dev mode), whether collection metadata is frozen, where the public feature-state route is mounted, and the upload size limit. Tools no longer have to infer frozen mode by string-matching a 403. It exposes only facts an anonymous client could already establish by probing — never a config value, path, or credential — and it is deliberately separate from `/api/health` (liveness) and `/api/state` (per-subject feature flags).
```

- [ ] Commit: `git commit -am "feat(api): GET /api/meta capability probe"`

---

### Task 11: Examples, README, and full-suite verification

**Files:**
- Modify: `examples/blog/src/main.zig`, `examples/golfsim/src/main.zig`, `examples/plugins/src/main.zig` (opt into `std_options`), `README.md` (CLI/commands section), `docs/framework.md` (the consumer opt-in)
- Create: `changelog.d/examples-std-options.md`

**Steps:**

- [ ] Opt each example into structured logging — one line above `pub fn main` in all three `examples/*/src/main.zig`, matching what `src/main.zig` gained in Task 4:

```zig
/// Structured logging: without this line the binary keeps Zig's default logger and
/// --log-format / --log-level have no effect. Every ZigBase consumer needs it in its
/// own root, because `std_options` is resolved from the root source file.
pub const std_options = zigbase.std_options;
```

The examples are the teaching surface — an example that silently ignores `--log-format` teaches the wrong thing.

- [ ] Document the opt-in in `docs/framework.md` next to the other `main.zig` boilerplate (grep for `runCli(init)`), stating plainly that omitting it means the logging flags do nothing.

- [ ] Build all three examples the way CI does — the `examples/plugins` frontend must be built before its Zig build:

```sh
cd examples/blog    && mise exec zig@0.16.0 -- zig build
cd examples/golfsim && mise exec zig@0.16.0 -- zig build
cd examples/plugins/frontend && npm ci && npm run build
cd examples/plugins && mise exec zig@0.16.0 -- zig build
```

- [ ] Confirm the example frontends still read errors correctly. They read `err?.message` only (`examples/golfsim/frontend/src/lib/api.ts:85,101,166`, `examples/blog/frontend/src/lib/api.ts:55`, `examples/plugins/frontend/src/lib/api.ts:19,63,86`), which the unified envelope still provides — but golfsim is the typed-route example, so **verify by running it**, not by reading: start it, trigger a typed-route failure, and confirm the UI shows the message. Note `examples/golfsim/frontend/src/lib/api.ts:103` does `msg.includes('not verified')` — that is an envelope-A auth route whose message text is unchanged, so it still works; leave it, but flag it in the PR description as message-text coupling that a future task should replace with a `code` check.

- [ ] Add the two new commands to `README.md`'s command list (grep for `superuser create` in README to find it):

```markdown
- `zigbase explain-code [CODE] [--json]` — explain a frozen API error code, or list them all.
```

and, wherever README describes the API surface, a line pointing at `GET /api/meta` for capability discovery.

- [ ] Run the gating check CI runs: `./scripts/check-gating.sh`. It must pass — this plan registers no conditional fn pointers (`/api/meta` is unconditional like `/api/health`, and `App.gates` is a struct of bools).

- [ ] **Full unit suite:** `mise exec zig@0.16.0 -- zig build test --summary all`. Record the `Build Summary: N/N tests passed` line; N must exceed the pre-SP-1 baseline by the number of tests this plan added, with **zero** failures. Ignore the spurious `failed command: …` line.

- [ ] **Full browser suite:** `mise exec python@3.13 -- python -m pytest tests/admin -q -n auto`. This is the gate that has repeatedly caught what `zig build test` missed — a green unit suite is not sufficient evidence. Run `tests/smtp` serially too if anything in this stream touched mail (it did not, but the auth-method envelope change is adjacent): `mise exec python@3.13 -- python -m pytest tests/smtp -q`.

- [ ] **SDK suites**, because Task 2 changed the wire even though research says no SDK reads `code`. Prove it rather than assume it — run each SDK's unit tests plus at least the TypeScript live-integration suite against a freshly built binary (the SDK jobs in `.github/workflows/ci.yml` show the exact env exports each needs):

```sh
cd clients/typescript && npm ci && npm test
```

If any SDK asserts on the envelope after all, fix the SDK in this stream — the spec calls envelope unification "a wire-breaking change that needs SDK updates in the same stream".

- [ ] **Site build:** `cd site && npm run build`. Confirm `site/src/content/docs/observability.md` was generated (and is gitignored — never commit or hand-edit it).

- [ ] Re-read every `changelog.d/` fragment added by this plan as one story: `error-code-ledger`, `error-envelope-unification`, `explain-code`, `structured-logging`, `env-fail-fast`, `logging-knobs`, `request-logging`, `silent-500-fix`, `cli-json-output`, `api-meta`, `examples-std-options`. Fold any fix or change that only corrects something introduced *within this same set* into the feature bullet that introduced it (the house consistency rule) — e.g. do not ship a `Fixes` bullet about the logging core if the logging core is itself new in this release.

- [ ] Write `changelog.d/examples-std-options.md`:

```markdown
### Internal

- The three example apps opt into structured logging (`pub const std_options = zigbase.std_options;`), so `--log-format` and `--log-level` work when running them.
```

- [ ] Commit: `git commit -am "chore(examples): opt into structured logging and document the consumer hook"`

- [ ] Run the `tell-a-git-story` skill over the branch before opening the PR, then open the PR with the sync checklist from `.github/pull_request_template.md` filled in, and monitor it with the `pr-monitor` skill until merge.

---

## Self-review notes (applied while writing)

**Spec coverage** against SP-1's five scope items (program spec §6/§9):

| scope item | tasks |
|---|---|
| Structured logging: request logs, levels, `--log-format=json`, a proper `logFn`/`std_options` story | 4 (core), 6 (knobs + docs), 7 (request logs), 11 (consumer opt-in) |
| …**fix the silent-500 hole** (server.zig:247 vs :712) | 8 — and it covers all **four** swallow sites, not only the one the spec names |
| Env-var fail-fast: name the variable and value; unknown `ZIGBASE_*` warns | 5 |
| Frozen error-code ledger; unify the two envelopes; `zigbase explain-code`; "match on code never message" | 1 (ledger), 2 (envelope — **three** shapes unified, not two), 3 (`explain-code`) |
| `--json` on CLI commands (`version`, `migrate status`, …) | 3 (`explain-code --json`), 9 (`version`, `migrate status`) |
| `/api/meta` exposing `collections_frozen` + capabilities, reconciled with `/api/state` | 10 |

**Placeholder scan.** No "TBD", no "similar to Task N", no "add appropriate error handling". The one place the plan does not spell out every literal — the 37 `info()` arms in Task 1 — is bounded by an exhaustive `switch` with no `else`, so the compiler enumerates what is missing; the plan supplies the table of summaries, two complete example arms, and the emitting-site map. The `known_vars` list in Task 5 is elided the same way, backed by a pytest that fails on any omission.

**Type and signature consistency across tasks.** `error_codes.Code`/`s`/`parse`/`forStatus` (T1) are consumed by T2 (`ApiError.code`, `withCode`), T3 (`explain-code`), and T9's tests. `ApiError{status, code, message, fields}` (T2) is consumed by T2's own `route_types.jsonError` and `ctx.jsonError`. `logging.{Format, min_level, request_logging, sink, RequestRecord, request, apply, preinstallFromEnv}` (T4) are consumed by T5's `Config` fields, T6's wiring, T7's `onRequest`, and T8's test. `config.{LoadDiag, LoadError, loadDiag, envBool, envEnum, known_vars, isKnown}` (T5) are consumed by T6's three new keys and `framework.loadCfg`. `App.gates` (T10) mirrors `server.Gates` (server.zig:51-63) and is set from `ServeOpts.gates` (framework.zig:1840). Every type named in a task is defined in this plan or already exists at a cited line.

**Cross-SP conflict resolved.** SP-3's plan flagged a casing disagreement and asked for convergence before either ships. SP-1 adopted SP-3's `snake_case` for CLI JSON (its zigapagos-lockfile argument is the stronger one) and kept `camelCase` for the REST plane, where `/api/health` already sets the precedent. Convention 7 records the split; Task 9's tests assert it; SP-3 needs no change.

**Ordering constraints.** T2 needs T1's enum. T3 needs T1. T6 needs both T4 (types) and T5 (the `envBool`/`envEnum`/diag machinery). T7 and T8 need T4. T9 and T10 are independent of the logging chain and can run in parallel with T4–T8. T11 is last.

**Risks carried forward.**
- Task 2 is the only irreversible wire change; its blast radius is enumerated line by line, but Task 11 still *runs* the SDK suites rather than trusting the research.
- `migrate status`'s new exit code is a behavior change with no in-repo caller, but a downstream user's deploy script could depend on the old always-0. It is a `Changed` entry, called out explicitly.
- `logFn` reserves 8 KiB of stack per log call (a 1 KiB message plus the 6× worst-case JSON escape expansion). With zap's four threads this is fine; if a future SP raises the thread count materially, revisit the buffer sizing rather than the truncation contract.

**Named follow-ups (deliberately out of SP-1 scope).**
- **A CI append-only guard for `src/error-codes.frozen` — and an honest statement of the gap it closes.** Task 1's five ledger tests all reason about the tree *as it stands*: they prove the enum and `[ACTIVE]` agree, that `[ACTIVE]` is sorted and duplicate-free, and that no enum field reuses a `[RETIRED]` name. None of them can see history, so **deleting a code from both the enum and `[ACTIVE]` in the same commit passes every test today** — precisely the silent-break the ledger exists to prevent. Closing it needs a check with a baseline: compare the `[ACTIVE]` set against `origin/main`'s and fail if any code disappeared without a matching `[RETIRED]` line, equivalent in intent to SP-3's `scripts/check-doctor-ledger.sh` but a **set-difference** variant rather than a positional/prefix one, because this ledger is alphabetically sorted and a new code legitimately lands anywhere in the file. Deferring it is a considered call, not an oversight: the guard is cross-cutting (SP-3 needs the same shape for check ids, SP-5 for whatever it freezes), so one shared script written once against two real ledgers beats two divergent ones — but until it exists, the ledger's append-only property rests on review, and that should be said out loud in the PR description.
- **Bespoke codes for the remaining ~200 `ApiError` sites.** Task 2 gives every site its generic per-status code and one bespoke code (`collections_frozen`) where an agent demonstrably needs it. Promoting more sites to specific codes is append-only by construction and belongs with whichever sub-project needs the distinction.
- **`examples/golfsim/frontend/src/lib/api.ts:103`** matches on message text (`msg.includes('not verified')`). Still correct after this stream, but it is exactly the coupling the new `code` field exists to remove; replace it when that auth path gets a bespoke code.
- **NDJSON *streaming* diagnostics.** Convention 3 is documented and the JSON log stream already satisfies it, but no command yet emits a progress stream. SP-3's `doctor` and SP-5's data pump are the first real producers.
- **SDK exposure of the new fields.** All four SDKs already surface `status`, `message`, and `data`; none surfaces the top-level `code`. Adding `ZigbaseException.code` is a small, additive, four-SDK change — worth doing, but it is SDK-stream work, not contracts-core work, and nothing in SP-1 depends on it.
