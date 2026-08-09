# SP-5 Migration Machinery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-08
**Program:** [ZigBase AI-Agents Program](../specs/2026-08-08-ai-agents-program-design.md) — sub-project SP-5, machinery half.
**Baseline:** main @ 087ca67 (v0.12.0)

**Goal:** Build the deterministic tooling the migration skill family drives: a declarative
schema document (`zigbase schema dump/apply`), a scaled + orderable NDJSON data pump
(`zigbase import` hardening + a manifest runner), legacy-password-hash import with
transparent rehash-to-argon2id on login, and a standalone parity-replay harness. The
PocketBase SKILL itself, the `pb_schema.json` → schema-document converter, and eval
scenario 2 are **out of scope** — they are the named follow-up that this machinery must be
sufficient for (see §"PocketBase sufficiency checklist").

**Architecture:** Four independent surfaces sharing one rule — *never a second
implementation of something the engine already does*.

1. **Schema document** (`src/schema_doc.zig`) is a thin canonical wrapper over the
   serializers the engine already persists with (`schema.fieldsToJson` /
   `indexesToJson` / `optionsToJson`), parsed back through `schema.parseCollectionInput`
   — literally the same parse the REST `POST /api/collections` handler uses. The diff
   (`src/schema_diff.zig`) is pure and side-effect-free; apply executes it through
   `collections.create` / `collections.update` / `collections.delete`, the exact functions
   `src/api/collections.zig` calls.
2. **Data pump** keeps `src/import.zig`'s existing streaming/batching contract and adds the
   three things a real migration needs that it lacks: survivable errors, progress, and
   multi-collection ordering with deferred cyclic relations (`src/import_manifest.zig`).
3. **Legacy auth** stores the source hash in the existing `passwordHash` column under an
   explicit `$zblegacy$<alg>$` tag, verified against a hardcoded algorithm allowlist and
   rewritten to argon2id on the first successful login. No new column, no new C dependency
   (`std.crypto.pwhash.bcrypt` ships in Zig 0.16.0).
4. **Parity replay** is a stdlib-only Python tool under `tools/`, not a server subcommand,
   because it must run against the *old* backend too.

**Tech Stack:** Zig 0.16.0 (pinned via mise), SQLite (vendored), Python 3.13 stdlib (the
replay tool + the pytest e2e suite), no new dependencies of any kind.

---

## Coordination notes (parallel sub-projects)

- **SP-1 (error-envelope unification, `--json` CLI conventions)** runs in parallel. This
  plan adds two new `cli.zig` `Command` arms and two new `HelpTopic` variants — expect
  textual conflicts in `src/cli.zig` and `src/framework.zig`'s `printUsage`. Resolve by
  taking both; the arms are independent.
- `schema apply` **must not fork the collections validation path.** It calls
  `collections.create/update/delete` and reuses `api/collections.zig`'s
  `prepareOAuthConfig` (promoted to `pub` in Task 4). When SP-1 changes the error envelope,
  the CLI inherits it because the CLI reads `collections.last_errors`, not a rendered body.
- **SP-3 (`doctor`)** should grow a check for "auth records still carrying a `$zblegacy$`
  hash" once Task 9 lands. That check is *not* in this plan, and — verified against SP-3's
  plan — it is *not* among SP-3's eight frozen check ids either (`jwt-secret-persisted`,
  `public-rules-enumerated`, `insecure-cookies-off`, `host-binding`,
  `trust-proxy-consistency`, `mailer-configured`, `migrations-applied`,
  `data-dir-writable`), so there is no double-claim. Adding it later is a pure append to
  `src/doctor_ids.txt`, which `scripts/check-doctor-ledger.sh` permits. This plan only
  guarantees the value is trivially countable (`WHERE passwordHash LIKE '$zblegacy$%'`).
- **SP-2 (`npx zigbase init`) ships a *different* schema file today, deliberately.** Its
  box scaffold emits `schema/collections.json` as a bare **array of
  `POST /api/collections` bodies** plus a `curl`+`jq` `scripts/apply-schema.sh`, because
  `zigbase schema apply` does not exist yet and SP-2 has a test banning forward references
  to unshipped commands. That is correct for SP-2 and is **not** something to "fix" from
  this side. But two shipped schema-file formats for one concept is a real end-state
  inconsistency: once this plan lands, file/execute the convergence (SP-2 follow-up 7) —
  box mode emits the Task 1 document and calls `zigbase schema apply`.

## Shared output conventions (SP-1 owns; this plan follows)

- **One JSON object on stdout** for status-like commands (`schema dump`, `schema apply`,
  `import` summary, `replay` summary). Human/progress/log text goes to **stderr** so
  `json.loads(proc.stdout)` never needs stripping.
- **NDJSON for streams and findings** (import error log, replay findings) — one object per
  line, written to a `--*-log` / `--out` file path. This file-based variant is explicitly
  sanctioned by SP-1 convention 1 alongside SP-3's `doctor`, which streams findings on
  stdout terminated by one `"summary":true` object. Both are legal; a command picks one.
- **Two planes, two casings — `snake_case` for CLI JSON, `camelCase` for file formats that
  mirror REST/engine payloads** (SP-1 convention 7, settled program-wide; do not
  re-litigate). Concretely:
  - **`camelCase` (unchanged):** the schema document (`zigbaseSchema`, `listRule`,
    `targetCollectionId`, `maxSelect`, …) — it is byte-identical to what the engine
    persists and to what `POST /api/collections` accepts, so any other casing would
    require a translation layer that D1 exists to avoid. Same for the import manifest
    (`upsertKey`) and the replay capture/findings (`bodySubset`), which are hand-authored
    alongside REST bodies. The `zigbase*` version discriminators are single compound
    tokens and stay as written.
  - **`snake_case` (this is a change from the samples below):** every key this plan emits
    on **stdout**. Specifically `dryRun` → `dry_run`, `errorLog` → `error_log`,
    `baseUrl` → `base_url`, `deferredRelations` → `deferred_relations`. Apply these
    renames wherever they appear in the tasks below, including the pytest assertions.
- **Frozen ids, append-only.** Change kinds, finding codes, and document version integers
  are contract; message text is not. Never renumber or repurpose.
- **Stable field order** in every emitted object (insertion order; `std.json.ObjectMap` is
  a `StringArrayHashMap`, so insertion order *is* emission order).
- **Exit codes, program-wide.** These four are now restated verbatim as SP-1 convention 2,
  so they are one contract covering every sub-project's commands, not a SP-5-local scheme:
  - `0` — success, or the thing being reported is OK (including a dry-run whose findings
    need no judgment).
  - `1` — the command failed **or** reported a not-OK condition the caller must act on:
    bad input, a **usage error** (a bad flag already exits 1 today via the parser's
    returned error), a refused operation, an I/O or DB error — and by the same rule,
    SP-1's `migrate status` with anything pending and SP-3's `doctor` with an `error`
    finding.
  - `2` — the command **ran correctly and found a condition requiring judgment**
    (`schema apply --dry-run` found destructive changes; `replay` found parity failures).
  - `3` — the command completed but **lost data or skipped work**
    (`import --continue-on-error` skipped at least one row).
  Rationale for a distinct `2`: an agent must be able to branch on "safe to proceed" vs
  "escalate" vs "the tool broke" without parsing prose. Folding "destructive changes
  pending" into `1` makes a refused apply indistinguishable from a corrupt file. Note the
  corollary: `2` is **never** a usage error — SP-1's draft convention originally spent `2`
  that way and has been corrected to fold usage errors into `1`.

---

## Global Constraints

- Zig version is **0.16.0 exactly**, invoked as `mise exec zig@0.16.0 -- zig`. Another
  0.16.x may not work.
- `zig build test` prints a spurious `failed command: …` line even on success. **The
  authoritative signal is the `Build Summary: N/N tests passed` line** (always use
  `--summary all`).
- A new `src/*.zig` file's tests **do not run** until it is added to the
  `test { _ = @import("…"); }` block in `src/root.zig`. Every task that creates a
  `src/*.zig` file registers it there in the same task.
- Run `mise exec zig@0.16.0 -- zig fmt <files>` before every commit touching Zig.
- **Never edit `CHANGELOG.md`.** Add `changelog.d/<slug>.md` fragments with `### <Section>`
  headings (Breaking / Features / Fixes / Changed / Performance / Deprecated / Removed /
  Security / Internal). This plan adds four fragments (Task 14).
- **Docs sync is mandatory** (see `.github/pull_request_template.md`). This plan creates
  **one new canonical doc, `docs/migration-tools.md`**, registered in
  `site/scripts/docs-registry.json` as `{"canonical":"docs/migration-tools.md",
  "mirror":"migration-tools.md","frontmatter":{"title":"Migration tools","description":
  "…","order":10,"group":"guides"}}`. `guides` order **3** looks vacant, but **SP-2
  (`docs/testing.md`) and SP-3 (`docs/serve.md`) each independently claimed it too**;
  de-conflicted program-wide as SP-2 → 3, SP-3 → 9, SP-5 → 10. Registering the doc takes
  **four coordinated edits**, not one, or it silently never publishes — and SP-2 Task 14
  adds `tests/admin/test_docs_parity.py` assertions that fail the build on any being
  missed: (1) the registry entry above; (2) `'migration-tools'` added to the hardcoded
  `PUBLISHED` set in `site/scripts/gen-docs-mirror.mjs`; (3)
  `src/content/docs/migration-tools.md` under the generated block in `site/.gitignore`;
  (4) `{ slug: 'migration-tools', label: 'Migration tools' }` in the `guides` group of
  `site/src/config/sidebar.ts`. **Never hand-edit
  `site/src/content/docs/*` mirrors** — they are gitignored generated artifacts. Also
  update `README.md`'s `## CLI` fenced block + the prose list of `runCli` commands, and
  `src/framework.zig`'s `printUsage` `COMMANDS:` block. Build the site (`cd site && npm run
  build`) once in Task 14.
- **`tests/admin/test_docs_parity.py` must stay green.** It scans every
  `"ZIGBASE_[A-Z0-9_]+"` string literal under `src/**/*.zig` and requires each to appear in
  `README.md` **and** inside `printUsage`'s `ENVIRONMENT VARIABLES:` … `EXAMPLES:` window.
  **This plan deliberately adds no new `ZIGBASE_*` env var** — every new knob is a flag, so
  the parity test needs no allowlist edit. New `ZIGBASE_TEST_*_BINARY` overrides live only
  in Python/CI and are never scanned.
- **Allocator/ownership contracts** (`NO_SLOP.md` §2.1, CLAUDE.md): default is contract 1
  (self-freeing) / contract 2 (owned result freed by the caller). New library functions
  returning graphs follow `collections.list`'s contract exactly — *every element owns its
  strings, the caller frees each element then the slice*. Internal scratch goes on a child
  `std.heap.ArenaAllocator`. **Trace every error/OOM path between an allocation and its
  ownership handoff before committing** — this is the single defect class review keeps
  catching here.
- Hook record mutations must allocate with `ev.arena.a`, never `ev.app.allocator`. (No
  task here adds hooks, but Task 11 touches request-path code: use `ctx.allocator.a`.)
- **NO_SLOP bar:** explicit allocators, guaranteed `defer`/`errdefer`, errors as values, no
  hidden control flow, disciplined comptime. Judge code properties, never authorship.
  Style/naming is deliberately un-enforced — do not flag it.
- **Security constraints for the legacy-hash work are non-negotiable.** They are restated
  in full in Task 9 and must appear verbatim in `docs/migration-tools.md`:
  1. **Explicit algorithm allowlist.** Only `bcrypt` is accepted, matched against a
     hardcoded list from the *tag*, never inferred from the hash's own prefix.
  2. **No downgrade path.** Only the offline `zigbase import --legacy-hashes` seam ever
     writes a `$zblegacy$` value. Login rehash only ever writes argon2id. The REST/records
     path keeps stripping `passwordHash` via `auth.isServerManagedField`, so no HTTP
     request can install a legacy hash.
  3. **Rehash only on a successful verification**, in the same request, before the
     response is written.
  4. **Import requires operator-level access** — it is an offline CLI command needing the
     data directory on local disk. **This plan adds no REST seam for legacy hashes.** If
     one is ever added it must go through `requireSuperuser`.
  5. **Constant-time comparison parity is preserved.** Zig's `bcrypt.strVerify` compares
     with `mem.eql`, which is exactly what the argon2 path already in production does
     (`std/crypto/argon2.zig:573`). The legacy path introduces **no new timing property**.
     One residual is accepted and documented: bcrypt (cost 10, ~60 ms) and argon2id
     (t=2, m=64 MiB) have different verify costs, so response timing can distinguish a
     *not-yet-migrated* account from a migrated one. It cannot distinguish an existing from
     a non-existent account — `crypto.dummyVerify` still covers the unknown-identity path.
  6. **`_superusers` never accepts a legacy hash.** Superuser accounts are created by
     `zigbase superuser create` with a real password; there is no migration story for them
     and they are the highest-value target.

---

## Settled design decisions (do not re-litigate during execution)

**D1 — Document format.** A single JSON object, `{"zigbaseSchema": 1, "collections": [...]}`.
Each collection element is `{name, type, fields, indexes, listRule, viewRule, createRule,
updateRule, deleteRule, options}` where `fields` / `indexes` / `options` are byte-identical
to what the engine already persists in `_collections` (produced by `schema.fieldsToJson`,
`schema.indexesToJson`, `schema.optionsToJson(alloc, c, true)`). No new serializer exists.

**D2 — Collection `id` is omitted from the document; field `id` is kept.** Collection ids
are instance-local (randomly generated by `collections.create`) and `parseCollectionInput`
ignores them anyway, so emitting one would make documents non-portable and produce phantom
diffs across environments. Collections are matched **by name**. Field **stable ids are
load-bearing** — `ddl.rebuildPlan` matches old/new columns by `of.id == nf.id` to preserve
data through a SQLite table rebuild, and `collections.create/update` preserve any non-empty
supplied id. Dropping them would make every apply look like "drop every column, add every
column": total data loss. A field with `"id": ""` is correctly read as brand-new.

**D3 — Relation targets are emitted as the target collection's *name*.**
`collections.resolveRelations` (`src/collections.zig:94` — note it is a private `fn`, not
`pub`) already accepts an id *or* a name (`collections.get` is
`WHERE id = ?1 OR name = ?1`) and normalizes to the name before DDL, so this needs no
new resolution machinery and makes the document portable. Self-references emit the
collection's own name.

**D4 — System collections and system fields are excluded.** There are **nine** `system = 1`
collections seeded by `src/migrations.zig`, not eight — `_superusers`, `_accounts`,
`_memberships`, **`_invitations`**, `_sender_identities`, `_suppressions`, `_events`,
`_mail_batches`, `_mail_batch_recipients` — and they are owned by migrations, not by
consumers. Filter on the `system` flag, never on a hardcoded name list, so a tenth cannot
leak into a dump. Auth system fields (`email`, `username`, `passwordHash`, `tokenKey`, `verified`,
`token_epoch`) are excluded because `schema.injectAuthFields` re-adds them on every
create/update and `parseCollectionInput` drops them on input — emitting them would be
round-trip noise.

**D5 — OAuth client secrets are redacted (`""`) in the dump**, matching REST. Apply reuses
`api/collections.zig`'s `prepareOAuthConfig` empty-secret-preserves-stored semantics rather
than inventing a second rule, so a dump→apply cycle never blanks a live secret. The
document is therefore **not** a backup of secrets, and says so in its docs.

**D6 — Apply is scoped to the collections named in the document.** Live collections absent
from the document are reported as `untracked` and left alone; `--prune` (which additionally
requires `--allow-destructive`) deletes them. A partial one-collection document must never
be able to nuke a database.

**D7 — Cyclic relation graphs are applied in two passes.** Collections are created in
topological order (`provision.topoOrder` at `src/provision.zig:1543`, promoted from `fn`
to `pub`); for a cycle, back-edge relation fields are omitted on create and added by a
follow-up `collections.update`. This is what a human does by hand over REST today;
automating it is ~30 lines given the plan already exists.

**Verified caveat that Task 3 must handle:** `topoOrder` today **does not detect or report
cycles** — its visitor is `if (vis[i] != 0) return; // done or on-stack (cycle): skip`, so
recursion terminates but a cyclic graph yields an arbitrary order with no error. It
therefore cannot tell the caller *which* edges are back-edges. `schema_diff.orderWithCycles`
must do its own cycle detection (a three-colour DFS distinguishing on-stack from finished)
and emit the back-edge set; promoting `topoOrder` alone is not sufficient. It also matches
relations by `t.name == r.targetCollectionId`, i.e. by name — consistent with D3.

**D8 — Import preserves source record ids; there is no id-mapping table.**
`records.isPlausibleRecordId` (`src/records.zig:150`) accepts any 1–255-byte id of
non-space printable ASCII (it rejects `ch <= ' '` and `ch >= 127`, so 0x21–0x7E), and PocketBase ids are
15-char lowercase base36 — the *same* shape ZigBase generates. Single relations store the
target's bare id string; multi relations store a JSON array of id strings. Preserving ids
therefore makes every cross-reference survive with **zero rewriting**. A mapping table
would require a full-graph pre-pass plus rewriting every relation value in every row, and
would need source-side knowledge of which fields are relations. Ids are per-table primary
keys, so cross-collection collisions do not exist. What ordering *does* require is that
referenced collections load first (single relations carry a real SQLite FK) — that is what
Task 7's manifest runner provides.

**D9 — Legacy hash storage: `$zblegacy$<alg>$<original-hash>` in the existing
`passwordHash` TEXT column.** Rejected alternatives: a bare `$2b$…` value (any future code
that pattern-matches `$2` would silently accept it; a raw bcrypt string arriving by
accident must fail closed, and it does — no verifier matches an untagged value), and a
separate column (a migration on every auth collection, plus a second thing to keep in sync
and to forget to clear). The tag makes the allowlist explicit rather than inferred, needs
no schema change, works identically on every auth collection, and is trivially auditable:
`SELECT count(*) FROM users WHERE passwordHash LIKE '$zblegacy$%'`.

**D10 — Replay is a standalone stdlib-only Python tool (`tools/replay/zb_replay.py`), not
`zigbase replay`.** The migration agent must run it against the **old** backend (PocketBase,
Rails, Express) to record expectations and against the new ZigBase to verify — a subcommand
only exists where a ZigBase binary is installed. It would also add an arbitrary-URL HTTP
client to every production binary, against the repo's lean-default-build doctrine
(optional subsystems must be comptime-gated). A script has zero binary cost, is hackable
mid-migration, and matches Python 3.13 already being pinned in `mise.toml` for the test
suite. `scripts/` is repo maintenance (CI/release); `tools/` is new and holds things a
*consumer* runs.

**D11 — Capture format is purpose-built NDJSON, not HAR.** HAR is one giant non-streamable
JSON object of browser network-log fields (timings, cache, cookie objects) with no notion
of an *expectation*; it would need a converter either way. NDJSON is streamable, diffable
in git, hand-authorable by an agent from a route inventory, and appends cleanly. A HAR
importer is a named follow-up, not v1.

**D12 — Replay compares by recursive subset, not equality.** Every key present in the
expectation must be present and equal in the response; arrays compare element-wise up to
the expectation's length; volatile keys (`id`, `created`, `updated`, `token`,
`collectionId`, `collectionName`, plus `--volatile` additions) are stripped at record time
so they never appear in an expectation. Equality matching would fail on every generated id
and timestamp, and a tool that cries wolf gets ignored — which would make the "unattended
migration" claim dishonest.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `src/schema_doc.zig` (create) | Canonical schema-document dump + parse |
| `src/schema_diff.zig` (create) | Pure live-vs-document plan, destructive classification, cycle back-edges |
| `src/import_manifest.zig` (create) | Multi-collection import ordering + deferred cyclic relation patch |
| `src/cli.zig` (modify) | `schema dump` / `schema apply` args; new `import` flags; help topics |
| `src/framework.zig` (modify) | `schemaDumpImpl` / `schemaApplyImpl`; import impl changes; usage text |
| `src/import.zig` (modify) | `--dry-run`, continue-on-error, progress, legacy-hash seam |
| `src/crypto.zig` (modify) | Legacy tag parse/wrap + bcrypt verification |
| `src/api/collections.zig` (modify) | `prepareOAuthConfig` promoted to `pub` |
| `src/api/auth.zig` (modify) | Rehash-on-login (password login + `oldPassword` verify) |
| `src/auth/methods/password.zig` (modify) | Rehash-on-login (auth-method path) |
| `src/root.zig` (modify) | Register the three new files for test discovery |
| `fixtures/import/main.zig` (modify) | Add a relation graph (`authors`/`posts`, self-relation) for the manifest + legacy e2e |
| `tools/replay/zb_replay.py` (create) | Record/replay parity harness |
| `tools/replay/README.md` (create) | Capture format + tool usage |
| `tests/admin/test_schema_cli.py` (create) | `schema dump`/`apply` e2e |
| `tests/admin/test_import_manifest.py` (create) | Manifest + hardening e2e |
| `tests/admin/test_legacy_auth.py` (create) | Legacy-hash import + rehash-on-login e2e |
| `tests/tools/test_replay.py` (create) | Replay tool unit tests |
| `docs/migration-tools.md` (create) | Canonical docs for all four surfaces |
| `site/scripts/docs-registry.json` (modify) | Register the new doc |
| `README.md` (modify) | CLI block + command list |
| `.github/workflows/ci.yml` (modify) | Run `tests/tools` in the `browser` job |
| `changelog.d/*.md` (create ×4) | Fragments |

**No new fixture binary is needed.** `schema dump`/`apply` operate on runtime-created
collections, so the stock `binary` fixture suffices; the manifest and legacy-credential
e2e reuse `import-fixture`, which already has an auth collection and (after Task 8) a
relation graph. That keeps `build.zig` and the CI artifact list untouched.

---

### Task 1: The canonical schema document (`src/schema_doc.zig`)

**Files:**
- Create: `src/schema_doc.zig`
- Modify: `src/root.zig` (register it in the `test {}` block)

**Interfaces:**
- Consumes: `schema.Collection`, `schema.fieldsToJson`, `schema.indexesToJson`,
  `schema.optionsToJson`, `schema.parseCollectionInput`, `schema.isSystemFieldName`,
  `collections.list`, `db.Db`.
- Produces:
```zig
/// Frozen document-format version. Append-only: bump ONLY on a breaking shape change,
/// and teach `parse` to accept both.
pub const doc_version: u32 = 1;

pub const DocError = error{ UnsupportedVersion, InvalidDocument } ||
    collections.EngineError || std.mem.Allocator.Error;

/// Serialize every non-system collection to the canonical document. Owned result on
/// `alloc` (2-space indented, trailing newline); caller frees.
pub fn dump(alloc: std.mem.Allocator, w: *db.Db) DocError![]u8;

/// Parse a document into collections, in document order. Ownership matches
/// `collections.list`: every element owns its strings — free each with `.deinit(alloc)`,
/// then `alloc.free` the slice (or call `freeCollections`).
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) DocError![]schema.Collection;

/// Free a slice returned by `parse` (or by `collections.list`).
pub fn freeCollections(alloc: std.mem.Allocator, cols: []schema.Collection) void;
```

- [ ] **Step 1: Write the failing tests**

Create `src/schema_doc.zig` containing only the imports and the tests:

```zig
const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");

test "dump emits a versioned document, sorted by name, without system collections" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.applyAll(a, &conn);

    const zebra = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "zebra",
        .fields = &.{.{ .id = "", .name = "title", .options = .{ .text = .{} } }},
    });
    defer zebra.deinit(a);
    const alpha = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "alpha",
        .fields = &.{.{ .id = "", .name = "body", .options = .{ .text = .{} } }},
    });
    defer alpha.deinit(a);

    const doc = try dump(a, &conn);
    defer a.free(doc);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, doc, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("zigbaseSchema").?.integer);
    const cols = parsed.value.object.get("collections").?.array;
    // Exactly the two user collections, name-sorted; `_superusers` (system) is absent.
    try std.testing.expectEqual(@as(usize, 2), cols.items.len);
    try std.testing.expectEqualStrings("alpha", cols.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("zebra", cols.items[1].object.get("name").?.string);
    // Collection ids are omitted (instance-local); field ids are kept (rebuild-load-bearing).
    try std.testing.expect(cols.items[0].object.get("id") == null);
    const f0 = cols.items[0].object.get("fields").?.array.items[0];
    try std.testing.expectEqual(@as(usize, 8), f0.object.get("id").?.string.len);
}

test "dump omits auth system fields but keeps user fields" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.applyAll(a, &conn);

    const users = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{.{ .id = "", .name = "nick", .options = .{ .text = .{} } }},
    });
    defer users.deinit(a);

    const doc = try dump(a, &conn);
    defer a.free(doc);
    // The physical table carries email/passwordHash/tokenKey/verified; the DOCUMENT must not.
    try std.testing.expect(std.mem.indexOf(u8, doc, "passwordHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"verified\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "nick") != null);
}

test "dump rewrites relation targets from id to the target collection's name" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.applyAll(a, &conn);

    const authors = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "authors",
        .fields = &.{.{ .id = "", .name = "nom", .options = .{ .text = .{} } }},
    });
    defer authors.deinit(a);
    const posts = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "posts",
        .fields = &.{.{ .id = "", .name = "author", .options = .{ .relation = .{ .targetCollectionId = authors.id } } }},
    });
    defer posts.deinit(a);

    const doc = try dump(a, &conn);
    defer a.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"targetCollectionId\": \"authors\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, authors.id) == null);
}

test "parse round-trips a dumped document" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.applyAll(a, &conn);

    const posts = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "posts",
        .viewRule = "@public",
        .fields = &.{
            .{ .id = "", .name = "title", .required = true, .options = .{ .text = .{ .max = 120 } } },
            .{ .id = "", .name = "views", .options = .{ .number = .{ .mode = .int } } },
        },
        .indexes = &.{.{ .name = "idx_posts_title", .fields = &.{"title"}, .unique = true }},
    });
    defer posts.deinit(a);

    const doc = try dump(a, &conn);
    defer a.free(doc);

    const cols = try parse(a, doc);
    defer freeCollections(a, cols);

    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqualStrings("posts", cols[0].name);
    try std.testing.expectEqualStrings("@public", cols[0].viewRule.?);
    try std.testing.expectEqual(@as(usize, 2), cols[0].fields.len);
    try std.testing.expectEqualStrings("title", cols[0].fields[0].name);
    try std.testing.expect(cols[0].fields[0].required);
    try std.testing.expectEqual(@as(?u32, 120), cols[0].fields[0].options.text.max);
    // The stable field id survives the round trip — this is what preserves data on apply.
    try std.testing.expectEqual(@as(usize, 8), cols[0].fields[0].id.len);
    try std.testing.expectEqual(@as(usize, 1), cols[0].indexes.len);
    try std.testing.expectEqualStrings("idx_posts_title", cols[0].indexes[0].name);
}

test "parse rejects a missing or future version and a non-object root" {
    const a = std.testing.allocator;
    try std.testing.expectError(DocError.InvalidDocument, parse(a, "[]"));
    try std.testing.expectError(DocError.InvalidDocument, parse(a, "{\"collections\":[]}"));
    try std.testing.expectError(DocError.UnsupportedVersion, parse(a, "{\"zigbaseSchema\":99,\"collections\":[]}"));
    try std.testing.expectError(DocError.InvalidDocument, parse(a, "{\"zigbaseSchema\":1}"));
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig test src/schema_doc.zig`
Expected: FAIL — `use of undeclared identifier 'dump'`.

- [ ] **Step 3: Write the implementation**

Insert above the tests in `src/schema_doc.zig`:

```zig
/// Frozen document-format version. Append-only: bump ONLY on a breaking shape change,
/// and teach `parse` to accept both.
pub const doc_version: u32 = 1;

pub const DocError = error{ UnsupportedVersion, InvalidDocument } ||
    collections.EngineError || std.mem.Allocator.Error;

/// Free a slice returned by `parse` (or by `collections.list`): every element owns its
/// strings, and the backing slice is owned too.
pub fn freeCollections(alloc: std.mem.Allocator, cols: []schema.Collection) void {
    for (cols) |c| c.deinit(alloc);
    alloc.free(cols);
}

fn lessByName(_: void, a: schema.Collection, b: schema.Collection) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Strip the fields the engine re-injects on every create/update (`injectAuthFields`) and
/// that `parseCollectionInput` drops on input — emitting them would be round-trip noise.
/// Relation targets are rewritten id -> target NAME so the document is instance-portable
/// (`collections.resolveRelations` accepts either form).
fn documentFields(sa: std.mem.Allocator, c: schema.Collection, all: []const schema.Collection) ![]schema.Field {
    var out: std.ArrayList(schema.Field) = .empty;
    for (c.fields) |f| {
        if (schema.isSystemFieldName(f.name)) continue;
        var nf = f;
        if (f.options == .relation) {
            var r = f.options.relation;
            r.targetCollectionId = targetName(r.targetCollectionId, c, all);
            nf.options = .{ .relation = r };
        }
        try out.append(sa, nf);
    }
    return out.toOwnedSlice(sa);
}

/// Map a relation's stored `targetCollectionId` to a collection NAME. The stored value may
/// already BE a name (the comptime path stores ids, the REST path stores whatever the
/// client sent), so fall through unchanged when no id matches.
fn targetName(target: []const u8, self: schema.Collection, all: []const schema.Collection) []const u8 {
    if (std.mem.eql(u8, target, self.id)) return self.name;
    for (all) |c| if (std.mem.eql(u8, c.id, target)) return c.name;
    return target;
}

fn optStr(v: ?[]const u8) std.json.Value {
    return if (v) |s| .{ .string = s } else .null;
}

/// Serialize every non-system collection to the canonical document.
pub fn dump(alloc: std.mem.Allocator, w: *db.Db) DocError![]u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // `list` returns fully-owned collections on `sa`; the arena reclaims them wholesale, so
    // no per-element deinit is needed (and none is correct — deinit on an arena is a no-op).
    const all = try collections.list(sa, w);

    var kept: std.ArrayList(schema.Collection) = .empty;
    // System collections (`_superusers`, `_accounts`, …) are owned by the engine's
    // migrations, not by consumers, and are never part of a schema document.
    for (all) |c| if (!c.system) try kept.append(sa, c);
    // Deterministic order: `collections.list` orders by `created` (second-resolution text),
    // which ties for same-second creations. Sort by name so the document diffs cleanly.
    std.sort.pdq(schema.Collection, kept.items, {}, lessByName);

    var arr: std.json.Array = .init(sa);
    for (kept.items) |c| {
        var o: std.json.ObjectMap = .empty;
        try o.put(sa, "name", .{ .string = c.name });
        try o.put(sa, "type", .{ .string = @tagName(c.type) });

        const fields_json = try schema.fieldsToJson(sa, try documentFields(sa, c, all));
        try o.put(sa, "fields", try std.json.parseFromSliceLeaky(std.json.Value, sa, fields_json, .{}));

        const idx_json = try schema.indexesToJson(sa, c.indexes);
        try o.put(sa, "indexes", try std.json.parseFromSliceLeaky(std.json.Value, sa, idx_json, .{}));

        try o.put(sa, "listRule", optStr(c.listRule));
        try o.put(sa, "viewRule", optStr(c.viewRule));
        try o.put(sa, "createRule", optStr(c.createRule));
        try o.put(sa, "updateRule", optStr(c.updateRule));
        try o.put(sa, "deleteRule", optStr(c.deleteRule));

        // redact = true: OAuth client secrets are NEVER written to a schema document.
        // `schema apply` reuses the REST rule (an empty secret preserves the stored one).
        const opts_json = try schema.optionsToJson(sa, c, true);
        try o.put(sa, "options", try std.json.parseFromSliceLeaky(std.json.Value, sa, opts_json, .{}));

        try arr.append(.{ .object = o });
    }

    var root: std.json.ObjectMap = .empty;
    try root.put(sa, "zigbaseSchema", .{ .integer = @intCast(doc_version) });
    try root.put(sa, "collections", .{ .array = arr });

    const body = try std.json.Stringify.valueAlloc(sa, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 });
    // A trailing newline so the file is a well-formed text file and `git diff` is clean.
    return std.fmt.allocPrint(alloc, "{s}\n", .{body});
}

/// Parse a document into collections, in document order. Each element is parsed by
/// `schema.parseCollectionInput` — the SAME parse the REST `POST /api/collections` handler
/// uses, so a document can never mean something the API would not.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) DocError![]schema.Collection {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, sa, bytes, .{}) catch return DocError.InvalidDocument;
    if (root != .object) return DocError.InvalidDocument;

    const ver = root.object.get("zigbaseSchema") orelse return DocError.InvalidDocument;
    if (ver != .integer) return DocError.InvalidDocument;
    if (ver.integer != @as(i64, @intCast(doc_version))) return DocError.UnsupportedVersion;

    const list = root.object.get("collections") orelse return DocError.InvalidDocument;
    if (list != .array) return DocError.InvalidDocument;

    var out: std.ArrayList(schema.Collection) = .empty;
    // Every element already appended owns its strings on `alloc`; free them all (plus the
    // backing buffer) if a later element fails, so `parse` is leak-correct under a raw
    // allocator on EVERY error path, not just the happy one.
    errdefer {
        for (out.items) |c| c.deinit(alloc);
        out.deinit(alloc);
    }
    for (list.array.items) |el| {
        if (el != .object) return DocError.InvalidDocument;
        const one = try std.json.Stringify.valueAlloc(sa, el, .{});
        const col = schema.parseCollectionInput(alloc, one) catch return DocError.InvalidDocument;
        // `col` is fully owned the moment parse succeeds: an OOM inside `append` must not
        // lose it.
        errdefer col.deinit(alloc);
        try out.append(alloc, col);
    }
    return out.toOwnedSlice(alloc);
}
```

- [ ] **Step 4: Register the file for test discovery**

In `src/root.zig`, inside the `test { … }` block, immediately after
`_ = @import("schema_dump.zig");`, add:

```zig
    _ = @import("schema_doc.zig");
```

- [ ] **Step 5: Run it to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: PASS — `Build Summary: N/N tests passed`, N up by 5.

Note on the test `std.Io` value: `std.Io.mock` **does not exist** in Zig 0.16.0 — the
repo-wide idiom is `std.testing.io` (`std/testing.zig:35`, valid only under `builtin.is_test`),
which is what `src/collections.zig`'s own in-memory tests pass to `collections.create`
(`src/collections.zig:379` and following). Do not invent a new one.

- [ ] **Step 6: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/schema_doc.zig src/root.zig
git add src/schema_doc.zig src/root.zig
git commit -m "Add the canonical schema-document format

A dump/parse pair over the serializers the engine already persists with, so
there is no second schema serializer to keep in sync. Collection ids are
omitted (instance-local) and collections match by name; stable field ids are
kept because ddl.rebuildPlan matches columns by id to preserve data through a
rebuild. Relation targets emit as names, which resolveRelations already accepts."
```

---

### Task 2: `zigbase schema dump --json [--out FILE]`

**Files:**
- Modify: `src/cli.zig` (`SchemaAction`, `SchemaArgs`, `Command.schema`, `HelpTopic.schema`)
- Modify: `src/framework.zig` (`schemaDumpImpl`, dispatch, `printSchemaUsage`, `COMMANDS:` line)

**Interfaces:**
- Consumes: `schema_doc.dump`, `loadCfg`, `openPoolSelect` (the exact pattern in
  `migrateDumpImpl`, `src/framework.zig:2459`).
- CLI contract: `zigbase schema dump [--json] [--out FILE] [--data-dir PATH]` writes the
  document to stdout, or to `FILE` (parent dirs created). `--json` is accepted and ignored
  (JSON is the only format) — it must be **accepted, not rejected**, because agents will
  pass it by habit. Exit `0` on success, `1` on failure.
- Produces in `src/cli.zig`:
```zig
pub const SchemaAction = enum { dump, apply };

pub const SchemaArgs = struct {
    data_dir: ?[]const u8 = null,
    action: SchemaAction = .dump,
    /// `--out <path>` for `dump`; null = stdout. Not accepted by `apply`.
    out: ?[]const u8 = null,
    /// Accepted-and-ignored (JSON is the only format); reserved for CLI symmetry.
    json: bool = false,
    /// Positional document path for `apply` (required there, rejected on `dump`).
    file: ?[]const u8 = null,
    /// `apply --dry-run`: compute + print the plan, change nothing.
    dry_run: bool = false,
    /// `apply --allow-destructive`: permit drop/retype/delete changes.
    allow_destructive: bool = false,
    /// `apply --prune`: also delete live collections absent from the document.
    /// Requires `--allow-destructive`.
    prune: bool = false,
};
```

- [ ] **Step 1: Write the failing parser tests**

Append to `src/cli.zig`'s tests, after the `import` tests and before
`test "unknown command errors"`:

```zig
test "schema dump parses --out/--json/--data-dir" {
    const cmd = try parse(&.{ "schema", "dump", "--json", "--out", "db/schema.json", "--data-dir", "/tmp/zb" }, .{});
    try std.testing.expect(std.meta.activeTag(cmd) == .schema);
    try std.testing.expectEqual(SchemaAction.dump, cmd.schema.action);
    try std.testing.expect(cmd.schema.json);
    try std.testing.expectEqualStrings("db/schema.json", cmd.schema.out.?);
    try std.testing.expectEqualStrings("/tmp/zb", cmd.schema.data_dir.?);
}

test "schema defaults to dump and rejects a positional file on dump" {
    const bare = try parse(&.{"schema"}, .{});
    try std.testing.expectEqual(SchemaAction.dump, bare.schema.action);
    try std.testing.expectEqual(@as(?[]const u8, null), bare.schema.out);
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "schema", "dump", "s.json" }, .{}));
}

test "schema apply parses the positional document + its flags" {
    const cmd = try parse(&.{ "schema", "apply", "schema.json", "--dry-run", "--allow-destructive", "--prune" }, .{});
    try std.testing.expectEqual(SchemaAction.apply, cmd.schema.action);
    try std.testing.expectEqualStrings("schema.json", cmd.schema.file.?);
    try std.testing.expect(cmd.schema.dry_run);
    try std.testing.expect(cmd.schema.allow_destructive);
    try std.testing.expect(cmd.schema.prune);
}

test "schema rejects a second positional, cross-action flags, and a bad subcommand" {
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "schema", "apply", "a.json", "b.json" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "schema", "dump", "--dry-run" }, .{}));
    try std.testing.expectError(ParseError.UnknownFlag, parse(&.{ "schema", "apply", "a.json", "--out", "x" }, .{}));
    try std.testing.expectError(ParseError.UnknownCommand, parse(&.{ "schema", "frobnicate" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "schema", "dump", "--out" }, .{}));
}

test "schema --help routes to its help topic" {
    try std.testing.expectEqual(HelpTopic.schema, (try parse(&.{ "schema", "--help" }, .{})).help);
    try std.testing.expectEqual(HelpTopic.schema, (try parse(&.{ "schema", "apply", "-h" }, .{})).help);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -20`
Expected: FAIL — `use of undeclared identifier 'SchemaAction'`.

- [ ] **Step 3: Write the parser**

In `src/cli.zig`, add the types after `ImportArgs` and before `HelpTopic`:

```zig
/// `schema`: the declarative-schema surface. `dump` writes the canonical JSON document for
/// every non-system collection; `apply` diffs a document against the live schema and
/// executes the difference through the same engine path the REST collections API uses.
pub const SchemaAction = enum { dump, apply };

pub const SchemaArgs = struct {
    data_dir: ?[]const u8 = null,
    action: SchemaAction = .dump,
    out: ?[]const u8 = null,
    json: bool = false,
    file: ?[]const u8 = null,
    dry_run: bool = false,
    allow_destructive: bool = false,
    prune: bool = false,
};
```

Extend `HelpTopic` and `Command`:

```zig
pub const HelpTopic = enum { top, serve, migrate, superuser_create, typegen, rewrap, migrate_db, vapid_keygen, import, schema };
```
```zig
    import: ImportArgs,
    schema: SchemaArgs,
```

Insert the parse arm in `parse`, immediately before the `if (std.mem.eql(u8, args[0], "import"))` block:

```zig
    if (std.mem.eql(u8, args[0], "schema")) {
        var sa = SchemaArgs{};
        var i: usize = 1;
        // Optional leading subcommand: `schema dump` (the default) or `schema apply <file>`.
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
            if (std.mem.eql(u8, args[i], "dump")) {
                sa.action = .dump;
                i += 1;
            } else if (std.mem.eql(u8, args[i], "apply")) {
                sa.action = .apply;
                i += 1;
            } else return ParseError.UnknownCommand;
        }
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) {
                return .{ .help = .schema };
            } else if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.data_dir = args[i];
            } else if (std.mem.eql(u8, a, "--json")) {
                sa.json = true;
            } else if (sa.action == .dump and std.mem.eql(u8, a, "--out")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.out = args[i];
            } else if (sa.action == .apply and std.mem.eql(u8, a, "--dry-run")) {
                sa.dry_run = true;
            } else if (sa.action == .apply and std.mem.eql(u8, a, "--allow-destructive")) {
                sa.allow_destructive = true;
            } else if (sa.action == .apply and std.mem.eql(u8, a, "--prune")) {
                sa.prune = true;
            } else if (!std.mem.startsWith(u8, a, "-")) {
                // Positional document path — `apply` only, exactly one.
                if (sa.action != .apply or sa.file != null) return ParseError.BadValue;
                sa.file = a;
            } else return ParseError.UnknownFlag;
        }
        return .{ .schema = sa };
    }
```

- [ ] **Step 4: Wire the dispatch, the implementation, and the help text**

In `src/framework.zig`, add the module import next to the other `const … = @import(…)` lines:

```zig
const schema_doc = @import("schema_doc.zig");
```

Add the help arm inside `runCliImpl`'s `.help => |topic| switch (topic)`:

```zig
            .schema => printSchemaUsage(init.io, std.Io.File.stdout()),
```

Add the command arm in the same `switch (cmd)`, after the `.import` arm. (`schemaApplyImpl`
does not exist yet — Task 4 adds it. To keep this task's tree compiling, wire only `.dump`
now and make `.apply` a temporary `return error.NotImplemented`; Task 4 replaces that line.)

```zig
        .schema => |sa| switch (sa.action) {
            .dump => try schemaDumpImpl(allocator, init.io, init.environ_map, sa),
            .apply => return error.NotImplemented, // Task 4 wires schemaApplyImpl here
        },
```

Add the implementation next to `migrateDumpImpl`:

```zig
/// `zigbase schema dump [--json] [--out <file>]`: write the canonical JSON schema document
/// for every non-system collection. Mirrors `migrateDumpImpl`'s read-only pool-open. Unlike
/// `migrate dump` (a dialect-native structure.sql snapshot of the PHYSICAL database), this
/// is the LOGICAL collection model — the artifact `schema apply` consumes.
fn schemaDumpImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, sa: cli.SchemaArgs) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = sa.data_dir });
    var pool = try openPoolSelect(allocator, io, cfg, .{}, environ);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();

    const doc = try schema_doc.dump(allocator, w);
    defer allocator.free(doc);

    if (sa.out) |path| {
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = doc });
        // Progress goes to stderr so stdout stays a clean JSON channel.
        std.log.info("schema document written to {s} ({d} bytes)", .{ path, doc.len });
    } else {
        var buf: [4096]u8 = undefined;
        var wr = std.Io.File.stdout().writer(io, &buf);
        try wr.interface.writeAll(doc);
        try wr.interface.flush();
    }
}
```

Add the usage printer next to `printMigrateUsage`:

```zig
fn printSchemaUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase schema — declarative schema: dump the live collection model, apply a document.
        \\
        \\USAGE:
        \\  zigbase schema dump  [--json] [--out FILE] [--data-dir PATH]
        \\  zigbase schema apply <schema.json> [--dry-run] [--allow-destructive] [--prune]
        \\                       [--data-dir PATH]
        \\
        \\DUMP:
        \\  Writes a canonical JSON document describing every NON-SYSTEM collection: fields
        \\  (with their stable ids), indexes, access rules, and collection options. It is
        \\  deterministic (collections name-sorted, stable key order) so it diffs cleanly in
        \\  git. Collection ids are omitted (they are instance-local) and OAuth client secrets
        \\  are REDACTED — the document is not a secrets backup. Output goes to stdout unless
        \\  --out is given.
        \\
        \\APPLY:
        \\  Diffs the document against the live schema and executes the difference through the
        \\  same validation + DDL path as the REST collections API. Only collections named in
        \\  the document are touched; live collections absent from it are reported as
        \\  "untracked" and left alone (--prune deletes them instead). Refused when the app
        \\  sets `.collections_frozen`.
        \\
        \\  --dry-run             Print the plan and change nothing.
        \\  --allow-destructive   Permit drops and retypes (refused otherwise).
        \\  --prune               Delete live collections absent from the document.
        \\                        Requires --allow-destructive.
        \\
        \\EXIT CODES:
        \\  0  success, or --dry-run with no destructive changes
        \\  1  the command failed (bad document, refused operation, DB error)
        \\  2  --dry-run found DESTRUCTIVE changes (needs --allow-destructive)
        \\
        \\EXAMPLES:
        \\  zigbase schema dump --out db/schema.json --data-dir ./zb_data
        \\  zigbase schema apply db/schema.json --dry-run
        \\  zigbase schema apply db/schema.json --allow-destructive
        \\
    , .{});
}
```

Add one line to `printUsage`'s `COMMANDS:` block, immediately after the `import` line:

```
        \\  schema              Dump the collection model as JSON, or apply a schema document.
```

- [ ] **Step 5: Run the tests**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: PASS — N up by 5.

- [ ] **Step 6: Verify the dump end-to-end by hand**

```bash
mise exec zig@0.16.0 -- zig build
rm -rf /tmp/zbsd && ./zig-out/bin/zigbase migrate --data-dir /tmp/zbsd
./zig-out/bin/zigbase schema dump --json --data-dir /tmp/zbsd
```
Expected: a single JSON object on stdout beginning `{\n  "zigbaseSchema": 1,` with
`"collections": []` (a stock binary declares no consumer collections, and `_superusers` is
system). Then confirm stdout carries **only** JSON:
```bash
./zig-out/bin/zigbase schema dump --data-dir /tmp/zbsd 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["zigbaseSchema"])'
```
Expected: `1`.

- [ ] **Step 7: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/cli.zig src/framework.zig
git add src/cli.zig src/framework.zig
git commit -m "Add \`zigbase schema dump\` for the canonical schema document

Mirrors \`migrate dump\`'s pool-open but emits the LOGICAL collection model
(what \`schema apply\` consumes) rather than a physical structure.sql. The JSON
document is the only thing on stdout; progress goes to stderr."
```

---

### Task 3: The schema diff (`src/schema_diff.zig`)

Pure and side-effect-free: it takes two collection slices and returns a plan. No `db.Db`,
no I/O, no allocation escaping the returned plan's arena. This is what makes `--dry-run`
free and what keeps the apply implementation small enough to read.

**Files:**
- Create: `src/schema_diff.zig`
- Modify: `src/root.zig` (register it in the `test {}` block)

**Interfaces:**
- Consumes: `schema.Collection`, `schema.Field`, `schema.fieldsToJson`,
  `schema.optionsToJson`, `schema.indexesToJson`, `Field.storageClass`, `Field.fieldType`.
- Produces:
```zig
/// Frozen change identifiers. The tag NAME is the wire value (`@tagName`); it is
/// append-only — never rename or repurpose an existing one.
pub const ChangeKind = enum {
    create_collection,
    add_field,
    modify_field,
    rename_field,
    add_index,
    drop_index,
    modify_rules,
    modify_options,
    /// Destructive from here down.
    retype_field,
    drop_field,
    drop_collection,
};

pub fn isDestructive(k: ChangeKind) bool;

pub const Change = struct {
    kind: ChangeKind,
    collection: []const u8,
    field: ?[]const u8 = null,
    /// Human context (e.g. "text -> number"). NOT a contract; match on `kind`.
    detail: []const u8 = "",
};

/// A relation field that must be omitted at create time and added by a follow-up update,
/// because its collection participates in a relation cycle.
pub const Deferred = struct { collection: []const u8, field: []const u8 };

pub const Plan = struct {
    changes: []const Change,
    /// Live non-system collections the document does not mention (left alone unless --prune).
    untracked: []const []const u8,
    deferred: []const Deferred,
    /// Indices into the `doc` slice, in dependency (creation) order.
    order: []const usize,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Plan) void;
    pub fn hasDestructive(self: Plan) bool;
    pub fn isDeferred(self: Plan, collection: []const u8, field: []const u8) bool;
};

pub const Options = struct { prune: bool = false };

/// Compute the plan. `live` is `collections.list` filtered to non-system entries; `doc` is
/// `schema_doc.parse`'s output. Collections match by NAME (see D2), fields by stable id
/// when both are non-empty, else by name.
pub fn compute(
    alloc: std.mem.Allocator,
    live: []const schema.Collection,
    doc: []const schema.Collection,
    opts: Options,
) !Plan;

/// Return `c` with the named fields removed (borrowed strings, fields array on `sa`).
/// Used to break relation cycles on the first create pass.
pub fn withoutFields(sa: std.mem.Allocator, c: schema.Collection, drop: []const []const u8) !schema.Collection;
```

Note the File-Structure correction this task makes: **`src/provision.zig`,
`src/dumpload.zig` and `src/collections.zig` are NOT modified.** `provision.topoOrder`
silently skips cycle edges without reporting which ones they were, and the apply path needs
exactly that information, so the ordering is implemented here (≈40 lines) and reused by
Task 7's manifest runner rather than promoting two private functions that would still need
a wrapper.

- [ ] **Step 1: Write the failing tests**

Create `src/schema_diff.zig` with only the imports and tests:

```zig
const std = @import("std");
const schema = @import("schema.zig");

fn textField(id: []const u8, name: []const u8) schema.Field {
    return .{ .id = id, .name = name, .options = .{ .text = .{} } };
}

fn relField(id: []const u8, name: []const u8, target: []const u8) schema.Field {
    return .{ .id = id, .name = name, .options = .{ .relation = .{ .targetCollectionId = target } } };
}

fn col(name: []const u8, fields: []const schema.Field) schema.Collection {
    return .{ .id = "", .name = name, .fields = fields };
}

test "an unchanged schema produces an empty plan" {
    const a = std.testing.allocator;
    const live = [_]schema.Collection{col("posts", &.{textField("aaaaaaaa", "title")})};
    const doc = [_]schema.Collection{col("posts", &.{textField("aaaaaaaa", "title")})};
    var p = try compute(a, &live, &doc, .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.changes.len);
    try std.testing.expectEqual(@as(usize, 0), p.untracked.len);
    try std.testing.expect(!p.hasDestructive());
}

test "a new collection and a new field are non-destructive" {
    const a = std.testing.allocator;
    const live = [_]schema.Collection{col("posts", &.{textField("aaaaaaaa", "title")})};
    const doc = [_]schema.Collection{
        col("posts", &.{ textField("aaaaaaaa", "title"), textField("", "body") }),
        col("tags", &.{textField("cccccccc", "label")}),
    };
    var p = try compute(a, &live, &doc, .{});
    defer p.deinit();
    try std.testing.expect(!p.hasDestructive());
    var saw_add_field = false;
    var saw_create = false;
    for (p.changes) |c| {
        if (c.kind == .add_field and std.mem.eql(u8, c.field.?, "body")) saw_add_field = true;
        if (c.kind == .create_collection and std.mem.eql(u8, c.collection, "tags")) saw_create = true;
    }
    try std.testing.expect(saw_add_field and saw_create);
}

test "a retype and a dropped field are destructive; a rename is not" {
    const a = std.testing.allocator;
    const live = [_]schema.Collection{col("posts", &.{
        textField("aaaaaaaa", "views"),
        textField("bbbbbbbb", "title"),
        textField("cccccccc", "gone"),
    })};
    const doc = [_]schema.Collection{col("posts", &.{
        .{ .id = "aaaaaaaa", .name = "views", .options = .{ .number = .{ .mode = .int } } },
        textField("bbbbbbbb", "headline"), // same stable id, new name => rename
    })};
    var p = try compute(a, &live, &doc, .{});
    defer p.deinit();
    try std.testing.expect(p.hasDestructive());

    var kinds = std.EnumSet(ChangeKind).initEmpty();
    for (p.changes) |c| kinds.insert(c.kind);
    try std.testing.expect(kinds.contains(.retype_field));
    try std.testing.expect(kinds.contains(.drop_field));
    try std.testing.expect(kinds.contains(.rename_field));
    try std.testing.expect(!isDestructive(.rename_field));
}

test "a live collection absent from the document is untracked, or a drop under --prune" {
    const a = std.testing.allocator;
    const live = [_]schema.Collection{
        col("posts", &.{textField("aaaaaaaa", "title")}),
        col("legacy", &.{textField("dddddddd", "junk")}),
    };
    const doc = [_]schema.Collection{col("posts", &.{textField("aaaaaaaa", "title")})};

    var keep = try compute(a, &live, &doc, .{});
    defer keep.deinit();
    try std.testing.expectEqual(@as(usize, 0), keep.changes.len);
    try std.testing.expectEqual(@as(usize, 1), keep.untracked.len);
    try std.testing.expectEqualStrings("legacy", keep.untracked[0]);
    try std.testing.expect(!keep.hasDestructive());

    var pruned = try compute(a, &live, &doc, .{ .prune = true });
    defer pruned.deinit();
    try std.testing.expectEqual(@as(usize, 1), pruned.changes.len);
    try std.testing.expectEqual(ChangeKind.drop_collection, pruned.changes[0].kind);
    try std.testing.expect(pruned.hasDestructive());
}

test "rules and options changes are reported; null and empty rules are the same value" {
    const a = std.testing.allocator;
    var live_c = col("posts", &.{textField("aaaaaaaa", "title")});
    live_c.listRule = null;
    var doc_c = col("posts", &.{textField("aaaaaaaa", "title")});
    doc_c.listRule = ""; // blank and null both mean Locked — not a change
    {
        var p = try compute(a, &.{live_c}, &.{doc_c}, .{});
        defer p.deinit();
        try std.testing.expectEqual(@as(usize, 0), p.changes.len);
    }
    doc_c.listRule = "@public";
    var p = try compute(a, &.{live_c}, &.{doc_c}, .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.changes.len);
    try std.testing.expectEqual(ChangeKind.modify_rules, p.changes[0].kind);
}

test "creation order puts relation targets first" {
    const a = std.testing.allocator;
    const doc = [_]schema.Collection{
        col("posts", &.{relField("aaaaaaaa", "author", "authors")}),
        col("authors", &.{textField("bbbbbbbb", "nom")}),
    };
    var p = try compute(a, &.{}, &doc, .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.order.len);
    try std.testing.expectEqual(@as(usize, 1), p.order[0]); // authors
    try std.testing.expectEqual(@as(usize, 0), p.order[1]); // posts
    try std.testing.expectEqual(@as(usize, 0), p.deferred.len);
}

test "a relation cycle reports a deferred back edge; a self-relation does not" {
    const a = std.testing.allocator;
    const cyc = [_]schema.Collection{
        col("a", &.{relField("aaaaaaaa", "toB", "b")}),
        col("b", &.{relField("bbbbbbbb", "toA", "a")}),
    };
    var p = try compute(a, &.{}, &cyc, .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.order.len);
    try std.testing.expectEqual(@as(usize, 1), p.deferred.len);
    try std.testing.expect(p.isDeferred(p.deferred[0].collection, p.deferred[0].field));

    // A self-relation is fine: the FK targets the very table being created.
    const selfrel = [_]schema.Collection{col("tree", &.{relField("cccccccc", "parent", "tree")})};
    var q = try compute(a, &.{}, &selfrel, .{});
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 0), q.deferred.len);
}

test "withoutFields removes exactly the named fields" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const c = col("a", &.{ textField("1", "keep"), relField("2", "drop", "b"), textField("3", "also") });
    const trimmed = try withoutFields(arena.allocator(), c, &.{"drop"});
    try std.testing.expectEqual(@as(usize, 2), trimmed.fields.len);
    try std.testing.expectEqualStrings("keep", trimmed.fields[0].name);
    try std.testing.expectEqualStrings("also", trimmed.fields[1].name);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig test src/schema_diff.zig`
Expected: FAIL — `use of undeclared identifier 'compute'`.

- [ ] **Step 3: Write the implementation**

Insert above the tests in `src/schema_diff.zig`:

```zig
/// Frozen change identifiers. The tag NAME is the wire value; append-only.
pub const ChangeKind = enum {
    create_collection,
    add_field,
    modify_field,
    rename_field,
    add_index,
    drop_index,
    modify_rules,
    modify_options,
    // Destructive from here down.
    retype_field,
    drop_field,
    drop_collection,
};

pub fn isDestructive(k: ChangeKind) bool {
    return switch (k) {
        .retype_field, .drop_field, .drop_collection => true,
        else => false,
    };
}

pub const Change = struct {
    kind: ChangeKind,
    collection: []const u8,
    field: ?[]const u8 = null,
    /// Human context. NOT a contract — match on `kind`.
    detail: []const u8 = "",
};

pub const Deferred = struct { collection: []const u8, field: []const u8 };

pub const Plan = struct {
    changes: []const Change,
    untracked: []const []const u8,
    deferred: []const Deferred,
    order: []const usize,
    /// Owns every string and slice above. One arena, one free.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }

    pub fn hasDestructive(self: Plan) bool {
        for (self.changes) |c| if (isDestructive(c.kind)) return true;
        return false;
    }

    pub fn isDeferred(self: Plan, collection: []const u8, field: []const u8) bool {
        for (self.deferred) |d| {
            if (std.mem.eql(u8, d.collection, collection) and std.mem.eql(u8, d.field, field)) return true;
        }
        return false;
    }
};

pub const Options = struct { prune: bool = false };

/// Return `c` with the named fields removed. Strings are borrowed from `c`; only the
/// fields array is allocated (on `sa`).
pub fn withoutFields(sa: std.mem.Allocator, c: schema.Collection, drop: []const []const u8) !schema.Collection {
    var kept: std.ArrayList(schema.Field) = .empty;
    outer: for (c.fields) |f| {
        for (drop) |d| if (std.mem.eql(u8, f.name, d)) continue :outer;
        try kept.append(sa, f);
    }
    var out = c;
    out.fields = try kept.toOwnedSlice(sa);
    return out;
}

fn findByName(cols: []const schema.Collection, name: []const u8) ?schema.Collection {
    for (cols) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

fn indexByName(cols: []const schema.Collection, name: []const u8) ?usize {
    for (cols, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) return i;
    return null;
}

/// Fields match by stable id when both sides carry one (that is what `ddl.rebuildPlan`
/// matches on), else by name — so a hand-written document with `"id": ""` still lines up
/// with the live column instead of reading as drop+add.
fn matchField(fields: []const schema.Field, want: schema.Field) ?schema.Field {
    if (want.id.len > 0) {
        for (fields) |f| if (f.id.len > 0 and std.mem.eql(u8, f.id, want.id)) return f;
    }
    for (fields) |f| if (std.mem.eql(u8, f.name, want.name)) return f;
    return null;
}

/// Structural equality by serialization: compare each field through the SAME serializer the
/// engine persists with. A hand-written 12-arm comparator would silently miss every option
/// added later; this cannot.
fn fieldEql(sa: std.mem.Allocator, x: schema.Field, y: schema.Field) !bool {
    const a = try schema.fieldsToJson(sa, &.{x});
    const b = try schema.fieldsToJson(sa, &.{y});
    return std.mem.eql(u8, a, b);
}

/// A blank rule — `null` OR `""` — both mean Locked (superusers only), so they are the
/// same value and must not produce a phantom change.
fn ruleEql(x: ?[]const u8, y: ?[]const u8) bool {
    const xs = x orelse "";
    const ys = y orelse "";
    return std.mem.eql(u8, xs, ys);
}

fn rulesEql(x: schema.Collection, y: schema.Collection) bool {
    return ruleEql(x.listRule, y.listRule) and ruleEql(x.viewRule, y.viewRule) and
        ruleEql(x.createRule, y.createRule) and ruleEql(x.updateRule, y.updateRule) and
        ruleEql(x.deleteRule, y.deleteRule);
}

fn hasIndex(idx: []const schema.Index, name: []const u8) bool {
    for (idx) |i| if (std.mem.eql(u8, i.name, name)) return true;
    return false;
}

/// Emit each collection only after every collection it points at, and report the relation
/// edges that had to be broken to make that possible (true cycles only — a self-relation's
/// FK targets the table being created, so it is never a back edge).
fn orderWithCycles(
    sa: std.mem.Allocator,
    cols: []const schema.Collection,
    order: *std.ArrayList(usize),
    back: *std.ArrayList(Deferred),
) !void {
    const state = try sa.alloc(u8, cols.len); // 0 = unseen, 1 = on stack, 2 = done
    @memset(state, 0);

    const W = struct {
        fn visit(
            all: []const schema.Collection,
            st: []u8,
            ord: *std.ArrayList(usize),
            bk: *std.ArrayList(Deferred),
            a: std.mem.Allocator,
            i: usize,
        ) !void {
            if (st[i] != 0) return;
            st[i] = 1;
            for (all[i].fields) |f| {
                if (f.options != .relation) continue;
                const target = f.options.relation.targetCollectionId;
                if (std.mem.eql(u8, target, all[i].name)) continue; // self-relation: not an edge
                const j = indexByName(all, target) orelse continue; // target lives outside the doc
                if (st[j] == 1) {
                    // Back edge into a collection still on the stack: a real cycle.
                    try bk.append(a, .{ .collection = all[i].name, .field = f.name });
                    continue;
                }
                try visit(all, st, ord, bk, a, j);
            }
            st[i] = 2;
            try ord.append(a, i);
        }
    };
    for (0..cols.len) |i| try W.visit(cols, state, order, back, sa, i);
}

/// Compute the plan. `live` must already be filtered to non-system collections.
pub fn compute(
    alloc: std.mem.Allocator,
    live: []const schema.Collection,
    doc: []const schema.Collection,
    opts: Options,
) !Plan {
    var arena = std.heap.ArenaAllocator.init(alloc);
    // The plan OWNS this arena on success; on any error below it must not leak.
    errdefer arena.deinit();
    const sa = arena.allocator();

    var changes: std.ArrayList(Change) = .empty;
    var untracked: std.ArrayList([]const u8) = .empty;
    var deferred: std.ArrayList(Deferred) = .empty;
    var order: std.ArrayList(usize) = .empty;

    for (doc) |want| {
        const have = findByName(live, want.name) orelse {
            try changes.append(sa, .{ .kind = .create_collection, .collection = want.name });
            continue;
        };

        for (want.fields) |wf| {
            const hf = matchField(have.fields, wf) orelse {
                try changes.append(sa, .{ .kind = .add_field, .collection = want.name, .field = wf.name });
                continue;
            };
            if (hf.fieldType() != wf.fieldType() or hf.storageClass() != wf.storageClass()) {
                try changes.append(sa, .{
                    .kind = .retype_field,
                    .collection = want.name,
                    .field = wf.name,
                    .detail = try std.fmt.allocPrint(sa, "{s} -> {s}", .{ @tagName(hf.fieldType()), @tagName(wf.fieldType()) }),
                });
                continue;
            }
            if (!std.mem.eql(u8, hf.name, wf.name)) {
                try changes.append(sa, .{
                    .kind = .rename_field,
                    .collection = want.name,
                    .field = wf.name,
                    .detail = try std.fmt.allocPrint(sa, "{s} -> {s}", .{ hf.name, wf.name }),
                });
                continue;
            }
            if (!try fieldEql(sa, hf, wf)) {
                try changes.append(sa, .{ .kind = .modify_field, .collection = want.name, .field = wf.name });
            }
        }

        // A live field the document omits is a DROP (silent data loss on rebuild).
        for (have.fields) |hf| {
            if (schema.isSystemFieldName(hf.name)) continue; // re-injected by the engine
            if (matchField(want.fields, hf) == null) {
                try changes.append(sa, .{ .kind = .drop_field, .collection = want.name, .field = hf.name });
            }
        }

        for (want.indexes) |wi| {
            if (!hasIndex(have.indexes, wi.name))
                try changes.append(sa, .{ .kind = .add_index, .collection = want.name, .detail = wi.name });
        }
        for (have.indexes) |hi| {
            if (!hasIndex(want.indexes, hi.name))
                try changes.append(sa, .{ .kind = .drop_index, .collection = want.name, .detail = hi.name });
        }

        if (!rulesEql(have, want))
            try changes.append(sa, .{ .kind = .modify_rules, .collection = want.name });

        // Both sides redacted, so a redacted OAuth secret can never look like a change.
        const have_opts = try schema.optionsToJson(sa, have, true);
        const want_opts = try schema.optionsToJson(sa, want, true);
        if (!std.mem.eql(u8, have_opts, want_opts))
            try changes.append(sa, .{ .kind = .modify_options, .collection = want.name });
    }

    for (live) |l| {
        if (findByName(doc, l.name) != null) continue;
        if (opts.prune) {
            try changes.append(sa, .{ .kind = .drop_collection, .collection = try sa.dupe(u8, l.name) });
        } else {
            try untracked.append(sa, try sa.dupe(u8, l.name));
        }
    }

    try orderWithCycles(sa, doc, &order, &deferred);

    return .{
        .changes = try changes.toOwnedSlice(sa),
        .untracked = try untracked.toOwnedSlice(sa),
        .deferred = try deferred.toOwnedSlice(sa),
        .order = try order.toOwnedSlice(sa),
        .arena = arena,
    };
}
```

**Lifetime note the implementer must honor:** `Change.collection` / `.field` borrow from
the caller's `live` / `doc` slices except where explicitly `sa.dupe`d (the `untracked` and
`drop_collection` names, which come from `live` and must survive it). The apply
implementation in Task 4 keeps `live` and `doc` alive for the whole apply, so borrowing is
correct there. Do not "tidy" this by duping everything — but do not shorten either slice's
lifetime.

- [ ] **Step 4: Register the file for test discovery**

In `src/root.zig`'s `test { … }` block, after `_ = @import("schema_doc.zig");`:

```zig
    _ = @import("schema_diff.zig");
```

- [ ] **Step 5: Run it to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: PASS — N up by 8.

- [ ] **Step 6: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/schema_diff.zig src/root.zig
git add src/schema_diff.zig src/root.zig
git commit -m "Add the pure live-vs-document schema diff

Fields compare through the engine's own serializer rather than a hand-written
per-type comparator, so an option added later cannot silently stop being
diffed. Blank and null rules compare equal (both mean Locked). Creation order
is topological and reports the relation back-edges a cycle forces us to defer."
```

---

### Task 4: `zigbase schema apply FILE [--dry-run] [--allow-destructive] [--prune]`

**Files:**
- Modify: `src/api/collections.zig` (promote `prepareOAuthConfig` to `pub`)
- Modify: `src/framework.zig` (`schemaApplyImpl`, `applyPlanJson`, replace the Task 2
  `error.NotImplemented` arm)

**Interfaces:**
- Consumes: `schema_doc.parse`, `schema_diff.compute` / `.withoutFields` / `.isDeferred`,
  `collections.list` / `.create` / `.update` / `.delete` / `.last_errors`,
  `schema.hasEncryptedField`, `db.poolFieldCipher`, `bootApp`,
  `collections_api.prepareOAuthConfig`.
- Produces the stdout contract — **one JSON object**, whether dry-run or not:
```json
{
  "zigbaseSchemaApply": 1,
  "dry_run": true,
  "allowDestructive": false,
  "destructive": true,
  "changes": [
    {"kind": "add_field", "collection": "posts", "field": "body", "detail": ""},
    {"kind": "retype_field", "collection": "posts", "field": "views", "detail": "text -> number"}
  ],
  "untracked": ["legacy"],
  "deferred_relations": [{"collection": "a", "field": "toB"}],
  "applied": [],
  "applyOrder": ["authors", "posts"]
}
```
  `applied` lists the collection names actually written (empty on a dry run). `kind` values
  are `@tagName(schema_diff.ChangeKind)` and are frozen.
- Produces in `src/api/collections.zig` (signature unchanged, visibility only):
```zig
/// Merge OAuth2 provider config from `def` with any stored secrets in `existing`: an
/// EMPTY incoming clientSecret preserves the stored one (secrets are redacted on read, so
/// a read-modify-write round trip must not blank them). Shared by the REST handlers and
/// `zigbase schema apply` so both obey one rule.
pub fn prepareOAuthConfig(ctx: *http.RequestCtx, def: *schema.Collection, existing: ?schema.Collection) !?http.Response
```

**Blocking design note the implementer must handle:** `prepareOAuthConfig` currently takes
a `*http.RequestCtx` (it uses the ctx only for its allocator and to build an error
response). A CLI has no `RequestCtx`. **Refactor it into two functions in the same file** —
a ctx-free core the CLI calls, and the existing ctx wrapper the handlers keep calling — so
there is still exactly one implementation of the rule:

```zig
pub const OAuthPrepError = error{ InvalidProviderConfig } || std.mem.Allocator.Error;

/// The rule, with no HTTP dependency. Mutates `def.options.auth.oauth2` in place using
/// `alloc`. Callers that have a request context should use `prepareOAuthConfig`.
pub fn mergeOAuthConfig(alloc: std.mem.Allocator, def: *schema.Collection, existing: ?schema.Collection) OAuthPrepError!void { … }

/// HTTP wrapper: on a config error, render the 400 the handlers already return.
pub fn prepareOAuthConfig(ctx: *http.RequestCtx, def: *schema.Collection, existing: ?schema.Collection) !?http.Response {
    mergeOAuthConfig(ctx.allocator.a, def, existing) catch |e| switch (e) {
        error.InvalidProviderConfig => return try ApiError.badRequest("Invalid OAuth2 provider configuration.").toResponse(ctx.allocator.a),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return null;
}
```

Move the existing body into `mergeOAuthConfig` verbatim, replacing each early
`return try ApiError…toResponse(…)` with `return error.InvalidProviderConfig`, and each
`ctx.allocator.a` with `alloc`. Re-run the existing `src/api/collections.zig` tests
unchanged — they must still pass with no edits, which is the proof the refactor was
behaviour-preserving.

- [ ] **Step 1: Refactor `prepareOAuthConfig` and prove nothing changed**

Make the split above. Then run:
`mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: PASS with the **same** test count as before the refactor (no test was added or
removed). If any `api/collections.zig` test needed editing, the refactor changed behaviour
— revert and redo.

- [ ] **Step 2: Commit the refactor on its own**

```bash
mise exec zig@0.16.0 -- zig fmt src/api/collections.zig
git add src/api/collections.zig
git commit -m "Split the OAuth secret-preserving merge out of the HTTP wrapper

\`schema apply\` needs the same empty-secret-preserves-stored rule the REST
handlers use, but has no RequestCtx. Extract the rule; the handlers keep
calling the wrapper. No behaviour change — the existing tests are untouched."
```

- [ ] **Step 3: Write the apply implementation**

In `src/framework.zig`, add next to `schemaDumpImpl`:

```zig
/// `zigbase schema apply <schema.json> [--dry-run] [--allow-destructive] [--prune]`.
///
/// Boots the FULL application offline via `bootApp` (migrations + comptime provisioning +
/// field-cipher stamping) so the live schema it diffs against is the one `serve` would see,
/// then executes the difference through `collections.create/update/delete` — the exact
/// functions `src/api/collections.zig` calls. There is no second DDL implementation.
///
/// Refused when the app sets `.collections_frozen`: frozen means this deployment's schema is
/// owned by the comptime `.collections` + `.migrations`, and a CLI write would silently
/// diverge from that source at the next boot (provisioning would fight it).
///
/// NOT atomic across collections — `collections.create`/`update` each open their own
/// transaction and cannot join an outer one. Each collection is therefore all-or-nothing on
/// its own, and the emitted `applied` list names exactly which ones landed before a failure.
fn schemaApplyImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    sa_args: cli.SchemaArgs,
    dispatch: *const events.Dispatch,
    jobs: []const scheduler.RuntimeJob,
    pool_size: usize,
    schema_collections: []const schema.Collection,
    schema_migrations: []const provision.Migration,
    comptime opts: ServeOpts,
) !void {
    const file = sa_args.file orelse {
        std.log.err("schema apply: a <schema.json> path is required", .{});
        return error.MissingSchemaFile;
    };
    if (sa_args.prune and !sa_args.allow_destructive) {
        std.log.err("schema apply: --prune deletes collections and requires --allow-destructive", .{});
        return error.DestructiveRefused;
    }

    const cfg = try loadCfg(environ, .{ .data_dir = sa_args.data_dir });
    const holder = try bootApp(allocator, io, cfg, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts, environ);
    defer holder.deinit();

    if (holder.app.collections_frozen) {
        std.log.err("schema apply: collections are frozen (`.collections_frozen`); change the comptime `.collections` / add a `.migrations` entry and redeploy", .{});
        return error.CollectionsFrozen;
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, a, file, 64 << 20) catch |e| {
        std.log.err("schema apply: cannot read '{s}': {s}", .{ file, @errorName(e) });
        return e;
    };
    const doc = schema_doc.parse(a, bytes) catch |e| {
        std.log.err("schema apply: '{s}' is not a valid schema document: {s}", .{ file, @errorName(e) });
        return e;
    };

    const w = holder.pool.acquireWriter();
    defer holder.pool.releaseWriter();

    const all_live = try collections.list(a, w);
    var live: std.ArrayList(schema.Collection) = .empty;
    for (all_live) |c| if (!c.system) try live.append(a, c);

    var plan = try schema_diff.compute(allocator, live.items, doc, .{ .prune = sa_args.prune });
    defer plan.deinit();

    // A dry run reports and stops. Exit 2 (not 1) when destructive changes are present: the
    // command SUCCEEDED, it just found something a human or an agent must decide about.
    if (sa_args.dry_run) {
        try emitApplyJson(allocator, io, plan, doc, sa_args, &.{});
        if (plan.hasDestructive()) {
            std.log.warn("schema apply --dry-run: {d} destructive change(s); re-run with --allow-destructive to execute", .{countDestructive(plan)});
            std.process.exit(2);
        }
        return;
    }

    if (plan.hasDestructive() and !sa_args.allow_destructive) {
        try emitApplyJson(allocator, io, plan, doc, sa_args, &.{});
        std.log.err("schema apply: {d} destructive change(s) refused; pass --allow-destructive to execute them", .{countDestructive(plan)});
        return error.DestructiveRefused;
    }

    var applied: std.ArrayList([]const u8) = .empty;
    // Report what DID land even when a later collection fails, so a partial apply is
    // diagnosable rather than mysterious.
    errdefer emitApplyJson(allocator, io, plan, doc, sa_args, applied.items) catch {};

    // Pass 1 — creates and updates, in dependency order, with cycle back-edges omitted.
    for (plan.order) |idx| {
        const want = doc[idx];
        var def = want;

        // Break relation cycles: create without the back-edge field, add it in pass 2.
        var deferred_here: std.ArrayList([]const u8) = .empty;
        for (want.fields) |f| {
            if (f.options == .relation and plan.isDeferred(want.name, f.name))
                try deferred_here.append(a, f.name);
        }
        const existing = try collections.get(a, w, want.name);
        if (deferred_here.items.len > 0 and existing == null)
            def = try schema_diff.withoutFields(a, want, deferred_here.items);

        if (schema.hasEncryptedField(def) and db.poolFieldCipher(holder.pool) == null) {
            std.log.err("schema apply: collection '{s}' declares an encrypted field but ZIGBASE_FIELD_KEY is unset", .{def.name});
            return error.FieldKeyRequired;
        }
        // One rule for OAuth secrets, shared with the REST handlers: an empty incoming
        // secret preserves the stored one (the document redacts them).
        try collections_api.mergeOAuthConfig(a, &def, existing);

        if (existing) |_| {
            _ = collections.update(a, holder.app.io, w, want.name, def) catch |e| return reportCollectionError(allocator, want.name, e);
        } else {
            _ = collections.create(a, holder.app.io, w, def) catch |e| return reportCollectionError(allocator, want.name, e);
        }
        try applied.append(a, want.name);
    }

    // Pass 2 — add the relation fields held back to break a cycle. Every target now exists.
    if (plan.deferred.len > 0) {
        for (plan.order) |idx| {
            const want = doc[idx];
            var any = false;
            for (want.fields) |f| {
                if (f.options == .relation and plan.isDeferred(want.name, f.name)) any = true;
            }
            if (!any) continue;
            var def = want;
            try collections_api.mergeOAuthConfig(a, &def, try collections.get(a, w, want.name));
            _ = collections.update(a, holder.app.io, w, want.name, def) catch |e| return reportCollectionError(allocator, want.name, e);
        }
    }

    // Pass 3 — prune, last, so a dropped collection can never be a live relation target of
    // something still being created (`collections.delete` refuses that anyway, with Conflict).
    for (plan.changes) |c| {
        if (c.kind != .drop_collection) continue;
        collections.delete(a, w, c.collection) catch |e| return reportCollectionError(allocator, c.collection, e);
        try applied.append(a, c.collection);
    }

    holder.app.col_cache.invalidate();
    try emitApplyJson(allocator, io, plan, doc, sa_args, applied.items);
    std.log.info("schema apply: {d} change(s) across {d} collection(s)", .{ plan.changes.len, applied.items.len });
}

fn countDestructive(plan: schema_diff.Plan) usize {
    var n: usize = 0;
    for (plan.changes) |c| if (schema_diff.isDestructive(c.kind)) {
        n += 1;
    };
    return n;
}

/// Present a `collections.create/update/delete` failure, surfacing the engine's own
/// field-level validation details (the same `last_errors` the REST layer renders) instead
/// of a bare error name. The slice is owned on `alloc`; free it here.
fn reportCollectionError(alloc: std.mem.Allocator, name: []const u8, e: anyerror) anyerror {
    if (e == error.Validation) {
        if (collections.last_errors) |errs| {
            defer {
                alloc.free(errs);
                collections.last_errors = null;
            }
            for (errs) |ve|
                std.log.err("schema apply: collection '{s}' field '{s}': {s} ({s})", .{ name, ve.field, ve.message, ve.code });
            return e;
        }
    }
    std.log.err("schema apply: collection '{s}' failed: {s}", .{ name, @errorName(e) });
    return e;
}

/// The single JSON object on stdout. Emitted for dry runs, successful applies, and partial
/// applies alike, so an agent parses exactly one shape.
fn emitApplyJson(
    alloc: std.mem.Allocator,
    io: std.Io,
    plan: schema_diff.Plan,
    doc: []const schema.Collection,
    args: cli.SchemaArgs,
    applied: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var changes: std.json.Array = .init(a);
    for (plan.changes) |c| {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "kind", .{ .string = @tagName(c.kind) });
        try o.put(a, "collection", .{ .string = c.collection });
        try o.put(a, "field", if (c.field) |f| .{ .string = f } else .null);
        try o.put(a, "detail", .{ .string = c.detail });
        try changes.append(.{ .object = o });
    }
    var untracked: std.json.Array = .init(a);
    for (plan.untracked) |u| try untracked.append(.{ .string = u });
    var deferred: std.json.Array = .init(a);
    for (plan.deferred) |d| {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "collection", .{ .string = d.collection });
        try o.put(a, "field", .{ .string = d.field });
        try deferred.append(.{ .object = o });
    }
    var applied_arr: std.json.Array = .init(a);
    for (applied) |n| try applied_arr.append(.{ .string = n });
    var order_arr: std.json.Array = .init(a);
    for (plan.order) |i| try order_arr.append(.{ .string = doc[i].name });

    var root: std.json.ObjectMap = .empty;
    try root.put(a, "zigbaseSchemaApply", .{ .integer = 1 });
    try root.put(a, "dry_run", .{ .bool = args.dry_run });
    try root.put(a, "allowDestructive", .{ .bool = args.allow_destructive });
    try root.put(a, "destructive", .{ .bool = plan.hasDestructive() });
    try root.put(a, "changes", .{ .array = changes });
    try root.put(a, "untracked", .{ .array = untracked });
    try root.put(a, "deferred_relations", .{ .array = deferred });
    try root.put(a, "applied", .{ .array = applied_arr });
    try root.put(a, "applyOrder", .{ .array = order_arr });

    const body = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});
    var buf: [4096]u8 = undefined;
    var wr = std.Io.File.stdout().writer(io, &buf);
    try wr.interface.writeAll(body);
    try wr.interface.writeAll("\n");
    // Flush BEFORE any std.process.exit — an unflushed buffer is a silently empty stdout.
    try wr.interface.flush();
}
```

Add the imports `schema_diff` and `collections_api` at the top of `src/framework.zig` if
they are not already present:

```zig
const schema_diff = @import("schema_diff.zig");
const collections_api = @import("api/collections.zig");
```

Replace the Task 2 placeholder arm with the real call:

```zig
            .apply => try schemaApplyImpl(allocator, init.io, init.environ_map, sa, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts),
```

- [ ] **Step 4: Build and check the by-hand behaviours**

```bash
mise exec zig@0.16.0 -- zig fmt src/framework.zig
mise exec zig@0.16.0 -- zig build
rm -rf /tmp/zbap && ./zig-out/bin/zigbase migrate --data-dir /tmp/zbap
cat > /tmp/zbap-schema.json <<'JSON'
{
  "zigbaseSchema": 1,
  "collections": [
    {
      "name": "authors",
      "type": "base",
      "fields": [{"id": "", "name": "nom", "type": "text", "required": true}],
      "indexes": [],
      "listRule": "@public", "viewRule": "@public",
      "createRule": null, "updateRule": null, "deleteRule": null,
      "options": {}
    },
    {
      "name": "posts",
      "type": "base",
      "fields": [
        {"id": "", "name": "title", "type": "text"},
        {"id": "", "name": "author", "type": "relation", "options": {"targetCollectionId": "authors", "maxSelect": 1}}
      ],
      "indexes": [],
      "listRule": null, "viewRule": null, "createRule": null, "updateRule": null, "deleteRule": null,
      "options": {}
    }
  ]
}
JSON
./zig-out/bin/zigbase schema apply /tmp/zbap-schema.json --dry-run --data-dir /tmp/zbap; echo "exit=$?"
```
Expected: a JSON object with `"dry_run": true`, two `create_collection` changes,
`"destructive": false`, `"applyOrder": ["authors","posts"]`, and `exit=0`.

```bash
./zig-out/bin/zigbase schema apply /tmp/zbap-schema.json --data-dir /tmp/zbap; echo "exit=$?"
./zig-out/bin/zigbase schema dump --data-dir /tmp/zbap 2>/dev/null > /tmp/zbap-dump1.json
./zig-out/bin/zigbase schema apply /tmp/zbap-dump1.json --dry-run --data-dir /tmp/zbap
```
Expected: the apply exits 0 with `"applied": ["authors","posts"]`; the round-trip dry run
prints `"changes": []` — **the no-op round-trip property**. Then check the destructive path:

```bash
python3 - <<'PY'
import json
d = json.load(open("/tmp/zbap-dump1.json"))
for c in d["collections"]:
    if c["name"] == "posts":
        c["fields"] = [f for f in c["fields"] if f["name"] != "title"]
json.dump(d, open("/tmp/zbap-drop.json", "w"))
PY
./zig-out/bin/zigbase schema apply /tmp/zbap-drop.json --dry-run --data-dir /tmp/zbap; echo "exit=$?"
./zig-out/bin/zigbase schema apply /tmp/zbap-drop.json --data-dir /tmp/zbap; echo "exit=$?"
```
Expected: dry run prints a `drop_field` change with `"destructive": true` and `exit=2`; the
real apply refuses with `exit=1` and an error naming `--allow-destructive`.

- [ ] **Step 5: Commit**

```bash
git add src/framework.zig
git commit -m "Add \`zigbase schema apply\` over the REST collections engine path

Diffs a schema document against the live schema and executes the difference
through collections.create/update/delete — the same functions the REST
handlers call, so there is no second DDL implementation and no second set of
validation rules. Destructive changes are refused without --allow-destructive;
--dry-run exits 2 when it finds them so an agent can branch without parsing
prose. Relation cycles are created in two passes. Refused under
.collections_frozen, where the comptime schema owns the database."
```

---

### Task 5: `schema dump`/`apply` end-to-end tests

The Zig unit tests cover the document and the diff; only an e2e proves the CLI boots, the
DDL really ran, and the data survived a rebuild. A green `zig build test` has repeatedly
hidden regressions the `browser` CI job then caught.

**Files:**
- Create: `tests/admin/test_schema_cli.py`

**Interfaces:**
- Consumes the stock `binary` session fixture from `tests/admin/conftest.py`
  (`ZIGBASE_TEST_BINARY` override, already exported by CI) — **no new fixture binary is
  needed**, because `schema apply` creates the collections the test needs at runtime.
- Consumes the CLI contracts frozen in Tasks 2 and 4.

- [ ] **Step 1: Write the tests**

Create `tests/admin/test_schema_cli.py`:

```python
"""End-to-end coverage for `zigbase schema dump` / `zigbase schema apply`.

Drives the REAL CLI against a REAL data dir: a genuine boot (migrations + provisioning),
then verifies the resulting physical schema by opening the SQLite file directly. No browser
needed — subprocess + sqlite3 + json only.

The load-bearing property is the ROUND TRIP: dump -> apply must be a no-op. If it is not,
every migration built on this machinery drifts.
"""
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import tempfile

import pytest


@pytest.fixture()
def data_dir():
    d = tempfile.mkdtemp(prefix="zb_schema_cli_")
    yield d
    shutil.rmtree(d, ignore_errors=True)


def run(binary, data, *args):
    return subprocess.run(
        [binary, *args, "--data-dir", data],
        env={**os.environ, "ZIGBASE_DATA_DIR": data},
        capture_output=True,
        text=True,
    )


def write_doc(data, name, doc):
    p = os.path.join(data, name)
    pathlib.Path(p).write_text(json.dumps(doc))
    return p


def field(name, ftype="text", **kw):
    f = {"id": "", "name": name, "type": ftype}
    f.update(kw)
    return f


def collection(name, fields, **kw):
    c = {
        "name": name, "type": "base", "fields": fields, "indexes": [],
        "listRule": None, "viewRule": None, "createRule": None,
        "updateRule": None, "deleteRule": None, "options": {},
    }
    c.update(kw)
    return c


def doc(*cols):
    return {"zigbaseSchema": 1, "collections": list(cols)}


def columns(data, table):
    con = sqlite3.connect(os.path.join(data, "data.db"))
    try:
        return [r[1] for r in con.execute(f'PRAGMA table_info("{table}")').fetchall()]
    finally:
        con.close()


def test_apply_creates_collections_in_relation_order(binary, data_dir):
    """`posts` references `authors`, but is listed first: apply must still order the
    creates so the FK target exists."""
    path = write_doc(data_dir, "s.json", doc(
        collection("posts", [
            field("title"),
            field("author", "relation", options={"targetCollectionId": "authors", "maxSelect": 1}),
        ]),
        collection("authors", [field("nom", required=True)]),
    ))
    r = run(binary, data_dir, "schema", "apply", path)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["applyOrder"] == ["authors", "posts"]
    assert sorted(out["applied"]) == ["authors", "posts"]
    assert out["destructive"] is False
    assert "author" in columns(data_dir, "posts")
    assert "nom" in columns(data_dir, "authors")


def test_dump_then_apply_is_a_no_op(binary, data_dir):
    """The round-trip property. Also proves the dumped document is re-appliable at all."""
    path = write_doc(data_dir, "s.json", doc(
        collection("authors", [field("nom")]),
        collection("posts", [
            field("title", required=True),
            field("views", "number", options={"mode": "int"}),
            field("author", "relation", options={"targetCollectionId": "authors", "maxSelect": 1}),
        ], viewRule="@public"),
    ))
    assert run(binary, data_dir, "schema", "apply", path).returncode == 0

    d1 = run(binary, data_dir, "schema", "dump", "--json")
    assert d1.returncode == 0, d1.stderr
    dumped = os.path.join(data_dir, "dump1.json")
    pathlib.Path(dumped).write_text(d1.stdout)

    dry = run(binary, data_dir, "schema", "apply", dumped, "--dry-run")
    assert dry.returncode == 0, dry.stderr
    assert json.loads(dry.stdout)["changes"] == [], dry.stdout

    # Applying it for real changes nothing, and a second dump is byte-identical.
    assert run(binary, data_dir, "schema", "apply", dumped).returncode == 0
    d2 = run(binary, data_dir, "schema", "dump", "--json")
    assert d2.stdout == d1.stdout


def test_additive_apply_preserves_existing_rows(binary, data_dir):
    """Adding a field rebuilds the SQLite table; the data must survive (stable field ids)."""
    v1 = write_doc(data_dir, "v1.json", doc(collection("notes", [field("body")])))
    assert run(binary, data_dir, "schema", "apply", v1).returncode == 0

    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    con.execute('INSERT INTO "notes" ("id","created","updated","body") VALUES (?,?,?,?)',
                ("note00000000001", "2026-01-01 00:00:00", "2026-01-01 00:00:00", "keep me"))
    con.commit()
    con.close()

    dumped = os.path.join(data_dir, "v1dump.json")
    pathlib.Path(dumped).write_text(run(binary, data_dir, "schema", "dump").stdout)
    d = json.loads(pathlib.Path(dumped).read_text())
    d["collections"][0]["fields"].append(field("pinned", "bool"))
    pathlib.Path(dumped).write_text(json.dumps(d))

    r = run(binary, data_dir, "schema", "apply", dumped)
    assert r.returncode == 0, r.stderr
    assert [c["kind"] for c in json.loads(r.stdout)["changes"]] == ["add_field"]

    con = sqlite3.connect(os.path.join(data_dir, "data.db"))
    try:
        rows = con.execute('SELECT id, body FROM "notes"').fetchall()
    finally:
        con.close()
    assert rows == [("note00000000001", "keep me")]
    assert "pinned" in columns(data_dir, "notes")


def test_destructive_changes_need_the_flag_and_dry_run_exits_2(binary, data_dir):
    v1 = write_doc(data_dir, "v1.json", doc(collection("notes", [field("body"), field("scrap")])))
    assert run(binary, data_dir, "schema", "apply", v1).returncode == 0

    dumped = os.path.join(data_dir, "d.json")
    pathlib.Path(dumped).write_text(run(binary, data_dir, "schema", "dump").stdout)
    d = json.loads(pathlib.Path(dumped).read_text())
    d["collections"][0]["fields"] = [f for f in d["collections"][0]["fields"] if f["name"] != "scrap"]
    pathlib.Path(dumped).write_text(json.dumps(d))

    dry = run(binary, data_dir, "schema", "apply", dumped, "--dry-run")
    assert dry.returncode == 2, dry.stdout + dry.stderr
    out = json.loads(dry.stdout)
    assert out["destructive"] is True
    assert out["applied"] == []
    assert [c["kind"] for c in out["changes"]] == ["drop_field"]
    assert "scrap" in columns(data_dir, "notes")  # dry run changed nothing

    refused = run(binary, data_dir, "schema", "apply", dumped)
    assert refused.returncode == 1
    assert "--allow-destructive" in refused.stderr
    assert "scrap" in columns(data_dir, "notes")

    allowed = run(binary, data_dir, "schema", "apply", dumped, "--allow-destructive")
    assert allowed.returncode == 0, allowed.stderr
    assert "scrap" not in columns(data_dir, "notes")


def test_untracked_collections_are_left_alone_unless_pruned(binary, data_dir):
    both = write_doc(data_dir, "both.json", doc(
        collection("keepme", [field("a")]), collection("dropme", [field("b")])))
    assert run(binary, data_dir, "schema", "apply", both).returncode == 0

    partial = write_doc(data_dir, "partial.json", doc(collection("keepme", [field("a")])))
    r = run(binary, data_dir, "schema", "apply", partial)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["untracked"] == ["dropme"]
    assert out["changes"] == []
    assert columns(data_dir, "dropme")  # still there

    assert run(binary, data_dir, "schema", "apply", partial, "--prune").returncode == 1
    pruned = run(binary, data_dir, "schema", "apply", partial, "--prune", "--allow-destructive")
    assert pruned.returncode == 0, pruned.stderr
    assert [c["kind"] for c in json.loads(pruned.stdout)["changes"]] == ["drop_collection"]
    assert columns(data_dir, "dropme") == []


def test_apply_rejects_a_bad_document_and_reports_validation_details(binary, data_dir):
    bad = os.path.join(data_dir, "bad.json")
    pathlib.Path(bad).write_text('{"collections": []}')  # no version
    r = run(binary, data_dir, "schema", "apply", bad)
    assert r.returncode == 1
    assert "InvalidDocument" in r.stderr

    # A structurally valid document the ENGINE rejects: an invalid identifier.
    invalid = write_doc(data_dir, "inv.json", doc(collection("9bad", [field("x")])))
    r2 = run(binary, data_dir, "schema", "apply", invalid)
    assert r2.returncode == 1
    assert "validation_invalid_name" in r2.stderr, r2.stderr


def test_stdout_is_only_json(binary, data_dir):
    """Every emitted stdout must parse as exactly one JSON object — logs live on stderr."""
    path = write_doc(data_dir, "s.json", doc(collection("t", [field("x")])))
    for args in (("schema", "apply", path, "--dry-run"), ("schema", "apply", path), ("schema", "dump")):
        r = run(binary, data_dir, *args)
        assert r.returncode == 0, r.stderr
        json.loads(r.stdout)  # raises if anything else leaked onto stdout
```

- [ ] **Step 2: Run them**

```bash
mise exec zig@0.16.0 -- zig build
ZIGBASE_TEST_BINARY=$PWD/zig-out/bin/zigbase \
  mise exec python@3.13 -- python -m pytest tests/admin/test_schema_cli.py -q
```
Expected: `7 passed`.

If `test_apply_rejects_a_bad_document_and_reports_validation_details` fails on the
`validation_invalid_name` assertion, check `reportCollectionError` is actually reading
`collections.last_errors` before it is cleared — that is the intended failure mode, not a
test bug.

- [ ] **Step 3: Run the whole browser suite to catch collateral damage**

```bash
mise exec python@3.13 -- python -m pytest tests/admin -q -n auto
```
Expected: all pass. `test_docs_parity.py` must be green — this task adds no `ZIGBASE_*`
literal, so it should be unaffected; if it fails, a stray env var was introduced.

- [ ] **Step 4: Commit**

```bash
git add tests/admin/test_schema_cli.py
git commit -m "Cover \`schema dump\`/\`apply\` end-to-end

The unit tests prove the document and the diff; only the e2e proves the DDL
really ran and the rows survived the rebuild. Pins the round-trip no-op, the
data-preserving additive apply, the exit-2 destructive dry run, untracked-vs-
prune, and that stdout is nothing but JSON."
```

---

### Task 6: Scaled-import hardening — dry run, survivable errors, progress, JSON summary

**What the existing loader already does well** (verified in `src/import.zig`; do not
"improve" these): it streams with `std.Io.Reader.takeDelimiter` into a 1 MiB line buffer
(never slurps the file), resets a per-row arena with `.retain_capacity` so peak memory is
bounded by the largest single record rather than the file, and commits in batches of 500
with correct `batch_open` bookkeeping so a failure rolls back only the in-flight batch. It
also already preserves source ids by default (`Options.preserve_ids = true`), which is what
makes D8 work.

**What it lacks for a real migration**, and what this task adds:
1. **Survivable errors.** One bad row out of 500,000 currently aborts a 40-minute import.
2. **A dry run.** Rehearsing an import must be possible without writing.
3. **Progress.** A long import is otherwise a black box to an agent.
4. **A machine-readable summary**, and an exit code that does not call a lossy import
   "success".

**Files:**
- Modify: `src/import.zig`
- Modify: `src/cli.zig` (`ImportArgs` flags + parser + tests)
- Modify: `src/framework.zig` (`importImpl`, `printImportUsage`)

**Interfaces:**
- Produces in `src/import.zig` (additive — existing callers keep compiling):
```zig
pub const Options = struct {
    collection: []const u8,
    upsert_key: ?[]const u8 = null,
    batch_size: usize = 500,
    preserve_ids: bool = true,
    /// Validate and execute every row, then ROLL BACK each batch instead of committing.
    /// Nothing is written. Note: because nothing commits, an `--upsert-key` lookup never
    /// sees rows created earlier in the same dry run — a dry run reports what a FRESH
    /// import would do.
    dry_run: bool = false,
    /// Record the failure and keep going instead of aborting. Each row is wrapped in a
    /// SAVEPOINT so a failed row leaves the in-flight batch intact.
    continue_on_error: bool = false,
    /// NDJSON sink for per-row failures: one object per line,
    /// `{"line":N,"code":"Validation","detail":"title: … (validation_required)"}`.
    error_log: ?*std.Io.Writer = null,
    /// Write a human progress line to `progress` every N rows (0 = off).
    progress_every: usize = 0,
    progress: ?*std.Io.Writer = null,
};

pub const Report = struct {
    created: usize = 0,
    updated: usize = 0,
    /// Rows that failed and were skipped (only ever non-zero under `continue_on_error`).
    failed: usize = 0,
    total: usize = 0,
};
```
- Produces the CLI contract: `--dry-run`, `--continue-on-error`, `--error-log FILE`,
  `--progress N`, `--json`. Exit `0` when `failed == 0`, **`3` when `failed > 0`** (the
  import completed but lost rows — an agent must not read that as success), `1` on a fatal
  failure.
- `--json` stdout object:
```json
{"zigbaseImport":1,"collection":"posts","dry_run":false,"created":1200,"updated":0,"failed":3,"total":1200,"error_log":"errs.ndjson"}
```

- [ ] **Step 1: Write the failing tests**

Append to `src/import.zig`'s test section:

```zig
test "import: dry run validates every row and writes nothing" {
    var app = try testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    try seedPosts(&w);

    const rep = try runNdjson(&app, &w,
        \\{"title":"a"}
        \\{"title":"b"}
        \\
    , .{ .collection = "posts", .dry_run = true });
    try std.testing.expectEqual(@as(usize, 2), rep.created);
    try std.testing.expectEqual(@as(usize, 0), rep.failed);

    var st = try w.prepare("SELECT count(*) FROM \"posts\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0)); // nothing committed
}

test "import: dry run still fails fast on a bad row" {
    var app = try testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    try seedPosts(&w);
    try std.testing.expectError(ImportError.MalformedJson, runNdjson(&app, &w,
        \\{"title":"a"}
        \\not json
        \\
    , .{ .collection = "posts", .dry_run = true }));
}

test "import: continue-on-error skips bad rows, keeps good ones, and logs NDJSON findings" {
    var app = try testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    try seedPosts(&w);

    var buf: [4096]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buf);

    const rep = try runNdjson(&app, &w,
        \\{"title":"good1"}
        \\not json
        \\{"title":"good2"}
        \\{"nope":"missing required title"}
        \\{"title":"good3"}
        \\
    , .{ .collection = "posts", .continue_on_error = true, .error_log = &sink });

    try std.testing.expectEqual(@as(usize, 3), rep.created);
    try std.testing.expectEqual(@as(usize, 2), rep.failed);
    try std.testing.expectEqual(@as(usize, 3), rep.total);

    var st = try w.prepare("SELECT count(*) FROM \"posts\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 3), st.columnInt(0)); // the good rows COMMITTED

    const findings = sink.buffered();
    var lines = std.mem.tokenizeScalar(u8, findings, '\n');
    const first = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, first, "\"line\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "MalformedJson") != null);
    const second = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, second, "\"line\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "validation_required") != null);
    try std.testing.expect(lines.next() == null);
}

test "import: continue-on-error rolls back only the failing row, not its batch" {
    var app = try testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    try seedPosts(&w);

    // batch_size 10 keeps all five rows in ONE transaction: proof the savepoint (not the
    // batch boundary) is what isolates the failure.
    const rep = try runNdjson(&app, &w,
        \\{"id":"dupdupdupdup001","title":"first"}
        \\{"id":"dupdupdupdup001","title":"duplicate id"}
        \\{"title":"after the failure"}
        \\
    , .{ .collection = "posts", .batch_size = 10, .continue_on_error = true });
    try std.testing.expectEqual(@as(usize, 2), rep.created);
    try std.testing.expectEqual(@as(usize, 1), rep.failed);
}

test "import: progress lines are emitted every N rows" {
    var app = try testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    try seedPosts(&w);

    var buf: [1024]u8 = undefined;
    var sink = std.Io.Writer.fixed(&buf);
    _ = try runNdjson(&app, &w,
        \\{"title":"1"}
        \\{"title":"2"}
        \\{"title":"3"}
        \\{"title":"4"}
        \\{"title":"5"}
        \\
    , .{ .collection = "posts", .progress_every = 2, .progress = &sink });
    // Rows 2 and 4 tick; the final total is reported by the CLI, not here.
    var lines = std.mem.tokenizeScalar(u8, sink.buffered(), '\n');
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "4") != null);
    try std.testing.expect(lines.next() == null);
}

test "import: 20k rows stay leak-free and memory-bounded" {
    // Scale guard. `std.testing.allocator` fails the test on any leak, and the per-row arena
    // is reset with .retain_capacity, so a per-row allocation that escaped the arena would
    // show up here as unbounded growth or a leak — neither is visible at 3 rows.
    var app = try testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    try seedPosts(&w);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    for (0..20_000) |i|
        try body.print(std.testing.allocator, "{{\"title\":\"row {d}\"}}\n", .{i});

    var reader = std.Io.Reader.fixed(body.items);
    const rep = try run(&app, &w, app.io, &reader, .{ .collection = "posts", .batch_size = 1000 });
    try std.testing.expectEqual(@as(usize, 20_000), rep.created);
}
```

`runNdjson`'s helper signature must gain an options parameter. Change it from
`fn runNdjson(app: *App, w: *db.Db, ndjson: []const u8) !Report` to:

```zig
fn runNdjson(app: *App, w: *db.Db, ndjson: []const u8, opts: Options) !Report {
    var reader = std.Io.Reader.fixed(ndjson);
    return run(app, w, app.io, &reader, opts);
}
```
and update the existing call sites, which currently pass a collection name — mechanical.

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -20`
Expected: FAIL — `no field named 'dry_run' in struct 'import.Options'`.

- [ ] **Step 3: Implement**

In `src/import.zig`:

Extend `Options` and `Report` exactly as spelled in **Interfaces** above.

Add the two helpers:

```zig
/// Write one NDJSON finding. Never fails the import: a full or broken sink loses the
/// finding, not the data — the counters in the Report remain authoritative.
fn logFinding(opts: Options, line_no: usize, code: []const u8, detail: []const u8) void {
    const sink = opts.error_log orelse return;
    sink.print(
        "{{\"line\":{d},\"code\":\"{s}\",\"detail\":\"{f}\"}}\n",
        .{ line_no, code, std.json.fmt(detail, .{}) },
    ) catch {};
}

fn tickProgress(opts: Options, seen: usize) void {
    if (opts.progress_every == 0) return;
    if (seen % opts.progress_every != 0) return;
    const sink = opts.progress orelse return;
    sink.print("import: {d} rows read\n", .{seen}) catch {};
    sink.flush() catch {};
}
```

Note: `std.json.fmt(detail, .{})` JSON-escapes the detail so a quote or newline in a
validation message cannot corrupt the NDJSON line. If that helper's name differs in
0.16.0, use `std.json.Stringify.valueAlloc` on a `.{ .string = detail }` into the row arena
instead — but escape it one way or the other; do not interpolate raw.

In `run`, replace each `try w.commit()` at a batch boundary and at the end with:

```zig
fn closeBatch(w: *db.Db, opts: Options) !void {
    // A dry run executes everything and throws it away, so validation, defaults, the
    // encryption envelope and the auth transforms are all exercised for real.
    if (opts.dry_run) try w.rollback() else try w.commit();
}
```

Wrap the per-row work so a failure under `continue_on_error` rolls back only that row.
Replace the existing row body (the `parseFromSliceLeaky` / `importRow` block) with:

```zig
        // SAVEPOINT isolates one row inside the open batch transaction, so a bad row does
        // not cost the good rows already in it. Portable spelling (SQLite + Postgres).
        // Only paid when continue_on_error is set.
        if (opts.continue_on_error) try w.exec("SAVEPOINT zb_row;");

        const outcome = importOneRow(app, w, io, a, col, line, opts, &lookups) catch |e| {
            last_error_line = line_no;
            last_error_detail = captureDetail(e);
            if (!opts.continue_on_error) {
                logFinding(opts, line_no, @errorName(e), last_error_detail);
                return e;
            }
            w.exec("ROLLBACK TO SAVEPOINT zb_row;") catch |re| return re;
            w.exec("RELEASE SAVEPOINT zb_row;") catch |re| return re;
            logFinding(opts, line_no, @errorName(e), last_error_detail);
            report.failed += 1;
            tickProgress(opts, line_no);
            continue;
        };
        if (opts.continue_on_error) try w.exec("RELEASE SAVEPOINT zb_row;");
        switch (outcome) {
            .created => report.created += 1,
            .updated => report.updated += 1,
        }
        report.total += 1;
        in_batch += 1;
        tickProgress(opts, line_no);
```

where `importOneRow` is the existing parse + `importRow` pair lifted into one function so
both failure kinds (`MalformedJson` / `RowNotObject` and the engine errors) take the same
path:

```zig
/// Parse one NDJSON line and import it. Split out of `run` so the malformed-JSON and the
/// engine-error paths share one savepoint/finding/counter treatment.
fn importOneRow(
    app: *App,
    w: *db.Db,
    io: std.Io,
    a: std.mem.Allocator,
    col: schema.Collection,
    line: []const u8,
    opts: Options,
    lookups: *Lookups,
) !Outcome {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch
        return ImportError.MalformedJson;
    if (parsed != .object) return ImportError.RowNotObject;
    return importRow(app, w, io, a, col, parsed, opts, lookups);
}

/// Capture the failing field detail while `records.last_errors` is still valid — it points
/// into the row arena, which this row's scope is about to reset.
fn captureDetail(e: anyerror) []const u8 {
    if (e != error.Validation) return "";
    const errs = records.last_errors orelse return "";
    if (errs.len == 0) return "";
    const ve = errs[0];
    return std.fmt.bufPrint(&last_error_detail_buf, "{s}: {s} ({s})", .{ ve.field, ve.message, ve.code }) catch "";
}
```

- [ ] **Step 4: Run the Zig tests**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: PASS — N up by 6, **and every pre-existing `import.zig` test still passing**
(they pin the fail-fast default, which `continue_on_error = false` must preserve exactly).

- [ ] **Step 5: Wire the CLI flags**

In `src/cli.zig`, extend `ImportArgs`:

```zig
    /// Validate + execute every row, then roll back. Writes nothing.
    dry_run: bool = false,
    /// Skip failing rows instead of aborting; the exit code becomes 3 if any were skipped.
    continue_on_error: bool = false,
    /// NDJSON file for per-row failures.
    error_log: ?[]const u8 = null,
    /// Progress line every N rows to stderr (0 = off).
    progress: usize = 0,
    /// Emit the summary as one JSON object on stdout.
    json: bool = false,
```

Add the parse arms inside the existing `import` block, before the positional branch:

```zig
            } else if (std.mem.eql(u8, a, "--dry-run")) {
                ia.dry_run = true;
            } else if (std.mem.eql(u8, a, "--continue-on-error")) {
                ia.continue_on_error = true;
            } else if (std.mem.eql(u8, a, "--error-log")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ia.error_log = args[i];
            } else if (std.mem.eql(u8, a, "--progress")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ia.progress = std.fmt.parseInt(usize, args[i], 10) catch return ParseError.BadValue;
            } else if (std.mem.eql(u8, a, "--json")) {
                ia.json = true;
```

Add the parser test:

```zig
test "import parses the hardening flags" {
    const cmd = try parse(&.{
        "import", "--collection", "posts", "--dry-run", "--continue-on-error",
        "--error-log", "errs.ndjson", "--progress", "1000", "--json", "in.ndjson",
    }, .{});
    try std.testing.expect(cmd.import.dry_run);
    try std.testing.expect(cmd.import.continue_on_error);
    try std.testing.expectEqualStrings("errs.ndjson", cmd.import.error_log.?);
    try std.testing.expectEqual(@as(usize, 1000), cmd.import.progress);
    try std.testing.expect(cmd.import.json);
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "import", "--error-log" }, .{}));
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "import", "--progress", "x", "f" }, .{}));
}
```

- [ ] **Step 6: Wire `importImpl`**

In `src/framework.zig`'s `importImpl`, build the writers, pass the options, and choose the
exit code:

```zig
    // Findings sink: created/truncated up front so a re-run never appends to a stale log.
    var err_file: ?std.Io.File = null;
    defer if (err_file) |f| f.close(io);
    var err_buf: [8192]u8 = undefined;
    var err_writer: ?std.Io.File.Writer = null;
    if (ia.error_log) |path| {
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        err_file = f;
        err_writer = f.writer(io, &err_buf);
    }
    var prog_buf: [256]u8 = undefined;
    var prog_writer = std.Io.File.stderr().writer(io, &prog_buf);

    const run_opts = import_mod.Options{
        .collection = collection,
        .upsert_key = ia.upsert_key,
        .batch_size = ia.batch_size,
        .dry_run = ia.dry_run,
        .continue_on_error = ia.continue_on_error,
        .error_log = if (err_writer) |*ew| &ew.interface else null,
        .progress_every = ia.progress,
        .progress = if (ia.progress > 0) &prog_writer.interface else null,
    };
```

After the run, flush the findings file, then report:

```zig
    if (err_writer) |*ew| try ew.interface.flush();

    if (ia.json) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var root: std.json.ObjectMap = .empty;
        try root.put(a, "zigbaseImport", .{ .integer = 1 });
        try root.put(a, "collection", .{ .string = collection });
        try root.put(a, "dry_run", .{ .bool = ia.dry_run });
        try root.put(a, "created", .{ .integer = @intCast(report.created) });
        try root.put(a, "updated", .{ .integer = @intCast(report.updated) });
        try root.put(a, "failed", .{ .integer = @intCast(report.failed) });
        try root.put(a, "total", .{ .integer = @intCast(report.total) });
        try root.put(a, "error_log", if (ia.error_log) |p| .{ .string = p } else .null);
        const body = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});
        var out_buf: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &out_buf);
        try out.interface.writeAll(body);
        try out.interface.writeAll("\n");
        try out.interface.flush();
    }
    std.log.info("import {s}: {d} created, {d} updated, {d} failed, {d} total (collection '{s}')", .{
        if (ia.dry_run) "dry-run complete (nothing written)" else "complete",
        report.created, report.updated, report.failed, report.total, collection,
    });
    // A lossy import is NOT a success. Exit 3 so an agent cannot mistake it for one.
    if (report.failed > 0) std.process.exit(3);
```

Extend `printImportUsage`'s `FLAGS:` block with:

```
  --dry-run          Validate + execute every row, then roll back. Writes nothing.
                     (An --upsert-key lookup sees no rows created in the same dry run.)
  --continue-on-error  Skip a failing row instead of aborting. Exit code becomes 3 if any
                     row was skipped — a lossy import is never reported as success.
  --error-log FILE   NDJSON sink for per-row failures: {"line":N,"code":…,"detail":…}.
  --progress N       Print a progress line to stderr every N rows (0 = off).
  --json             Print the summary as one JSON object on stdout.
```
and add to its `EXIT CODES:` (add the block if absent):
```
  0  every row imported
  1  the import failed (fatal error; batches committed before it persist)
  3  the import completed but skipped rows (--continue-on-error)
```

- [ ] **Step 7: Verify by hand**

```bash
mise exec zig@0.16.0 -- zig fmt src/import.zig src/cli.zig src/framework.zig
mise exec zig@0.16.0 -- zig build import-fixture
rm -rf /tmp/zbimp && mkdir -p /tmp/zbimp
printf '{"code":"A","note":"ok"}\nnot json\n{"code":"B","note":"ok"}\n' > /tmp/zbimp/in.ndjson
export ZIGBASE_FIELD_KEY=an-operator-supplied-field-key-32b
./zig-out/bin/import-fixture import --collection vault --data-dir /tmp/zbimp \
    --continue-on-error --error-log /tmp/zbimp/errs.ndjson --json /tmp/zbimp/in.ndjson
echo "exit=$?"
cat /tmp/zbimp/errs.ndjson
```
Expected: stdout is one JSON object with `"created":2,"failed":1`; `exit=3`;
`errs.ndjson` holds one line naming `"line":2` and `MalformedJson`.

```bash
rm -rf /tmp/zbimp2 && mkdir -p /tmp/zbimp2
printf '{"code":"A"}\n{"code":"B"}\n' > /tmp/zbimp2/in.ndjson
./zig-out/bin/import-fixture import --collection vault --data-dir /tmp/zbimp2 --dry-run --json /tmp/zbimp2/in.ndjson
sqlite3 /tmp/zbimp2/data.db 'select count(*) from vault'
```
Expected: `"dry_run":true,"created":2` on stdout, and the table count is `0`.

- [ ] **Step 8: Commit**

```bash
git add src/import.zig src/cli.zig src/framework.zig
git commit -m "Harden the NDJSON import for migration-scale data

Adds a dry run (execute then roll back), per-row SAVEPOINT isolation behind
--continue-on-error so one bad row out of half a million does not abort a
40-minute import, an NDJSON findings log, progress ticks, and a --json
summary. A lossy import exits 3, never 0, so an agent cannot read skipped
rows as success. The fail-fast default is unchanged and still pinned."
```

---

### Task 7: Multi-collection import with deferred relations (`src/import_manifest.zig`)

**Why this exists.** Single relations carry a real SQLite foreign key
(`ddl.createTableSql` emits `FOREIGN KEY … REFERENCES`), and `records.validateFieldValue`
additionally runs an existence `SELECT` for every relation element, single or multi. So a
migration's files must load in dependency order — and two shapes cannot be ordered at all:

- a **relation cycle** between collections (`a.toB` → `b`, `b.toA` → `a`), and
- a **self-relation** (`comments.parent` → `comments`), where row 1 may reference row 5
  *inside the same file*.

Both are ordinary in real data (PocketBase apps use self-relations constantly). The runner
handles them by **deferring the offending relation values**: phase 1 imports every row with
those keys stripped, phase 2 patches them in by record id.

**Files:**
- Create: `src/import_manifest.zig`
- Modify: `src/schema_diff.zig` (promote `orderWithCycles` to `pub`)
- Modify: `src/root.zig` (register the new file)

**Interfaces:**
- Consumes: `schema_diff.orderWithCycles`, `import.run`, `import.Options`,
  `collections.list`, `records.updateInTxn`, `db.Db`.
- `src/schema_diff.zig` change (visibility + doc only):
```zig
/// Emit each collection only after every collection it points at, and report the relation
/// edges that had to be broken. Public because the data pump needs the same ordering and
/// the same back-edge list that the DDL pump does.
pub fn orderWithCycles(
    sa: std.mem.Allocator,
    cols: []const schema.Collection,
    order: *std.ArrayList(usize),
    back: *std.ArrayList(Deferred),
) !void
```
- Produces:
```zig
/// Frozen manifest-format version.
pub const manifest_version: u32 = 1;

pub const Entry = struct {
    collection: []const u8,
    /// NDJSON path, relative to the manifest file's directory unless absolute.
    file: []const u8,
    upsert_key: ?[]const u8 = null,
};

/// Owns every string. `deinit` frees the whole thing.
pub const Manifest = struct {
    entries: []const Entry,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Manifest) void;
};

pub const ManifestError = error{ InvalidManifest, UnsupportedVersion, UnknownCollection, DeferredRowMissingId } ||
    import.ImportError || collections.EngineError || std.mem.Allocator.Error;

pub fn parseManifest(alloc: std.mem.Allocator, bytes: []const u8) ManifestError!Manifest;

/// The (collection, field) relation values that must be stripped on load and patched
/// afterwards: every cross-collection cycle back-edge PLUS every self-relation.
/// Result lives on `sa`.
pub fn deferralSet(
    sa: std.mem.Allocator,
    live: []const schema.Collection,
    entries: []const Entry,
) ![]const schema_diff.Deferred;

/// Manifest entry indices in load order (dependency order, restricted to the collections
/// the manifest actually names). Result lives on `sa`.
pub fn loadOrder(
    sa: std.mem.Allocator,
    live: []const schema.Collection,
    entries: []const Entry,
) ![]const usize;

pub const EntryReport = struct {
    collection: []const u8,
    created: usize,
    updated: usize,
    failed: usize,
};

pub const Report = struct {
    entries: []const EntryReport,
    /// Rows whose deferred relation values were patched in phase 2.
    patched: usize = 0,
    failed: usize = 0,
};

pub const RunOptions = struct {
    /// Directory that relative `file` paths resolve against (the manifest's own directory).
    base_dir: []const u8,
    /// Forwarded verbatim to every `import.run`, minus `collection` / `upsert_key`,
    /// which come from the manifest entry.
    import: import.Options,
};

/// Load every file in dependency order, then patch the deferred relation values.
/// Owned result on `alloc`; free `Report.entries`.
pub fn run(
    app: *import.App,
    w: *db.Db,
    io: std.Io,
    alloc: std.mem.Allocator,
    manifest: Manifest,
    opts: RunOptions,
) ManifestError!Report;
```

- [ ] **Step 1: Promote `orderWithCycles`**

In `src/schema_diff.zig`, change `fn orderWithCycles` to `pub fn orderWithCycles` and
replace its doc comment with the one in **Interfaces** above. Also make `indexByName` `pub`
— `deferralSet` needs it.

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: PASS, unchanged count.

- [ ] **Step 2: Write the failing tests**

Create `src/import_manifest.zig` with only the imports and tests:

```zig
const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const schema_diff = @import("schema_diff.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const records = @import("records.zig");
const import = @import("import.zig");

fn relField(name: []const u8, target: []const u8, max: u32) schema.Field {
    return .{ .id = "", .name = name, .options = .{ .relation = .{ .targetCollectionId = target, .maxSelect = max } } };
}

test "parseManifest reads entries and rejects a bad document" {
    const a = std.testing.allocator;
    var m = try parseManifest(a,
        \\{"zigbaseImportManifest":1,"collections":[
        \\  {"collection":"authors","file":"authors.ndjson"},
        \\  {"collection":"posts","file":"posts.ndjson","upsertKey":"slug"}
        \\]}
    );
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 2), m.entries.len);
    try std.testing.expectEqualStrings("authors", m.entries[0].collection);
    try std.testing.expectEqual(@as(?[]const u8, null), m.entries[0].upsert_key);
    try std.testing.expectEqualStrings("slug", m.entries[1].upsert_key.?);

    try std.testing.expectError(ManifestError.InvalidManifest, parseManifest(a, "[]"));
    try std.testing.expectError(ManifestError.UnsupportedVersion, parseManifest(a,
        \\{"zigbaseImportManifest":7,"collections":[]}
    ));
    try std.testing.expectError(ManifestError.InvalidManifest, parseManifest(a,
        \\{"zigbaseImportManifest":1,"collections":[{"collection":"a"}]}
    ));
}

test "loadOrder puts relation targets before their referrers" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sa = arena.allocator();

    const live = [_]schema.Collection{
        .{ .id = "c1", .name = "posts", .fields = &.{relField("author", "authors", 1)} },
        .{ .id = "c2", .name = "authors", .fields = &.{} },
    };
    const entries = [_]Entry{
        .{ .collection = "posts", .file = "p.ndjson" },
        .{ .collection = "authors", .file = "a.ndjson" },
    };
    const order = try loadOrder(sa, &live, &entries);
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expectEqual(@as(usize, 1), order[0]); // authors first
    try std.testing.expectEqual(@as(usize, 0), order[1]);
}

test "deferralSet covers cycle back-edges AND self-relations" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sa = arena.allocator();

    const live = [_]schema.Collection{
        .{ .id = "c1", .name = "a", .fields = &.{relField("toB", "b", 1)} },
        .{ .id = "c2", .name = "b", .fields = &.{relField("toA", "a", 1)} },
        .{ .id = "c3", .name = "tree", .fields = &.{relField("parent", "tree", 1)} },
    };
    const entries = [_]Entry{
        .{ .collection = "a", .file = "a.ndjson" },
        .{ .collection = "b", .file = "b.ndjson" },
        .{ .collection = "tree", .file = "t.ndjson" },
    };
    const set = try deferralSet(sa, &live, &entries);
    // One cycle back-edge plus the self-relation.
    try std.testing.expectEqual(@as(usize, 2), set.len);
    var saw_self = false;
    for (set) |d| if (std.mem.eql(u8, d.collection, "tree") and std.mem.eql(u8, d.field, "parent")) {
        saw_self = true;
    };
    try std.testing.expect(saw_self);
}

test "a self-relation loads in any row order and is patched afterwards" {
    const a = std.testing.allocator;
    var app = try import.testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();

    const tree = try collections.create(a, app.io, &w, .{
        .id = "",
        .name = "tree",
        .fields = &.{
            .{ .id = "", .name = "label", .options = .{ .text = .{} } },
            relField("parent", "tree", 1),
        },
    });
    defer tree.deinit(a);

    // The CHILD comes first and references a parent that does not exist yet: without
    // deferral this is a foreign-key / validation_not_found failure.
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(.{ .sub_path = "tree.ndjson", .data =
        \\{"id":"treechild00001","label":"child","parent":"treeroot000001"}
        \\{"id":"treeroot000001","label":"root","parent":null}
        \\
    });
    const base = try dir.dir.realpathAlloc(a, ".");
    defer a.free(base);

    var m = try parseManifest(a,
        \\{"zigbaseImportManifest":1,"collections":[{"collection":"tree","file":"tree.ndjson"}]}
    );
    defer m.deinit();

    const rep = try run(&app, &w, app.io, a, m, .{ .base_dir = base, .import = .{ .collection = "" } });
    defer a.free(rep.entries);
    try std.testing.expectEqual(@as(usize, 2), rep.entries[0].created);
    try std.testing.expectEqual(@as(usize, 1), rep.patched); // only the child had a parent

    var st = try w.prepare("SELECT \"parent\" FROM \"tree\" WHERE \"id\"='treechild00001';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("treeroot000001", st.columnText(0));
}
```

`import.testApp` and `import.Options` must be reachable from another module: promote
`testApp` in `src/import.zig` to `pub fn testApp()`. If the tmpDir/realpath spellings differ
in 0.16.0, copy the exact idiom from an existing test that writes a temp file
(`grep -rn "tmpDir" src/ | head -3`).

- [ ] **Step 3: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig test src/import_manifest.zig`
Expected: FAIL — `use of undeclared identifier 'parseManifest'`.

- [ ] **Step 4: Implement**

Insert above the tests in `src/import_manifest.zig`:

```zig
pub const manifest_version: u32 = 1;

pub const Entry = struct {
    collection: []const u8,
    file: []const u8,
    upsert_key: ?[]const u8 = null,
};

pub const Manifest = struct {
    entries: []const Entry,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }
};

pub const ManifestError = error{ InvalidManifest, UnsupportedVersion, UnknownCollection, DeferredRowMissingId } ||
    import.ImportError || collections.EngineError || std.mem.Allocator.Error;

pub fn parseManifest(alloc: std.mem.Allocator, bytes: []const u8) ManifestError!Manifest {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit(); // the Manifest owns it only on success
    const sa = arena.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, sa, bytes, .{}) catch return ManifestError.InvalidManifest;
    if (root != .object) return ManifestError.InvalidManifest;
    const ver = root.object.get("zigbaseImportManifest") orelse return ManifestError.InvalidManifest;
    if (ver != .integer) return ManifestError.InvalidManifest;
    if (ver.integer != @as(i64, @intCast(manifest_version))) return ManifestError.UnsupportedVersion;
    const list = root.object.get("collections") orelse return ManifestError.InvalidManifest;
    if (list != .array) return ManifestError.InvalidManifest;

    var out: std.ArrayList(Entry) = .empty;
    for (list.array.items) |el| {
        if (el != .object) return ManifestError.InvalidManifest;
        const c = el.object.get("collection") orelse return ManifestError.InvalidManifest;
        const f = el.object.get("file") orelse return ManifestError.InvalidManifest;
        if (c != .string or f != .string) return ManifestError.InvalidManifest;
        var e = Entry{ .collection = try sa.dupe(u8, c.string), .file = try sa.dupe(u8, f.string) };
        if (el.object.get("upsertKey")) |k| {
            if (k == .string) e.upsert_key = try sa.dupe(u8, k.string);
        }
        try out.append(sa, e);
    }
    return .{ .entries = try out.toOwnedSlice(sa), .arena = arena };
}

/// The live collections named by the manifest, in manifest order.
fn manifestCollections(sa: std.mem.Allocator, live: []const schema.Collection, entries: []const Entry) ![]schema.Collection {
    const out = try sa.alloc(schema.Collection, entries.len);
    for (entries, 0..) |e, i| {
        const idx = schema_diff.indexByName(live, e.collection) orelse return ManifestError.UnknownCollection;
        out[i] = live[idx];
    }
    return out;
}

pub fn loadOrder(sa: std.mem.Allocator, live: []const schema.Collection, entries: []const Entry) ![]const usize {
    const cols = try manifestCollections(sa, live, entries);
    var order: std.ArrayList(usize) = .empty;
    var back: std.ArrayList(schema_diff.Deferred) = .empty;
    try schema_diff.orderWithCycles(sa, cols, &order, &back);
    return order.toOwnedSlice(sa);
}

pub fn deferralSet(sa: std.mem.Allocator, live: []const schema.Collection, entries: []const Entry) ![]const schema_diff.Deferred {
    const cols = try manifestCollections(sa, live, entries);
    var order: std.ArrayList(usize) = .empty;
    var out: std.ArrayList(schema_diff.Deferred) = .empty;
    // Cross-collection cycle back-edges, from the same routine the DDL pump uses.
    try schema_diff.orderWithCycles(sa, cols, &order, &out);
    // Plus every self-relation. `orderWithCycles` deliberately skips these (a table's own
    // FK is satisfiable at CREATE time), but the DATA pump cannot order rows within one
    // file, so a self-relation must be deferred too.
    for (cols) |c| {
        for (c.fields) |f| {
            if (f.options != .relation) continue;
            if (!std.mem.eql(u8, f.options.relation.targetCollectionId, c.name)) continue;
            try out.append(sa, .{ .collection = c.name, .field = f.name });
        }
    }
    return out.toOwnedSlice(sa);
}

fn isDeferredField(set: []const schema_diff.Deferred, collection: []const u8, field: []const u8) bool {
    for (set) |d| {
        if (std.mem.eql(u8, d.collection, collection) and std.mem.eql(u8, d.field, field)) return true;
    }
    return false;
}

pub const EntryReport = struct { collection: []const u8, created: usize, updated: usize, failed: usize };
pub const Report = struct { entries: []const EntryReport, patched: usize = 0, failed: usize = 0 };
pub const RunOptions = struct { base_dir: []const u8, import: import.Options };

/// Load every file in dependency order, then patch the deferred relation values.
pub fn run(
    app: *import.App,
    w: *db.Db,
    io: std.Io,
    alloc: std.mem.Allocator,
    manifest: Manifest,
    opts: RunOptions,
) ManifestError!Report {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const all_live = try collections.list(sa, w);
    const order = try loadOrder(sa, all_live, manifest.entries);
    const deferred = try deferralSet(sa, all_live, manifest.entries);

    var reports = try alloc.alloc(EntryReport, manifest.entries.len);
    // The caller owns `reports` only once we return it; free it on every error path.
    errdefer alloc.free(reports);

    var total_failed: usize = 0;
    var line_buf = try sa.alloc(u8, 1 << 20);

    // Phase 1 — load, with deferred relation keys stripped from every row.
    for (order) |i| {
        const e = manifest.entries[i];
        const path = try resolvePath(sa, opts.base_dir, e.file);
        var o = opts.import;
        o.collection = e.collection;
        o.upsert_key = e.upsert_key;
        o.strip_fields = try strippedFor(sa, deferred, e.collection);

        const f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        var fr = f.readerStreaming(io, line_buf);
        const rep = try import.run(app, w, io, &fr.interface, o);
        reports[i] = .{ .collection = e.collection, .created = rep.created, .updated = rep.updated, .failed = rep.failed };
        total_failed += rep.failed;
    }

    // Phase 2 — patch the deferred values, now that every target row exists.
    var patched: usize = 0;
    for (order) |i| {
        const e = manifest.entries[i];
        const strip = try strippedFor(sa, deferred, e.collection);
        if (strip.len == 0) continue;
        patched += try patchDeferred(app, w, io, sa, opts, e, strip, line_buf);
    }

    return .{ .entries = reports, .patched = patched, .failed = total_failed };
}

fn resolvePath(sa: std.mem.Allocator, base: []const u8, file: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(file)) return file;
    return std.fs.path.join(sa, &.{ base, file });
}

fn strippedFor(sa: std.mem.Allocator, set: []const schema_diff.Deferred, collection: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (set) |d| if (std.mem.eql(u8, d.collection, collection)) try out.append(sa, d.field);
    return out.toOwnedSlice(sa);
}

/// Re-read the file and issue one update per row carrying a deferred value. Requires the
/// row to carry its own `id` — without one there is nothing to patch, since the record's
/// generated id is not knowable from the file. Rows with no deferred value are skipped.
fn patchDeferred(
    app: *import.App,
    w: *db.Db,
    io: std.Io,
    sa: std.mem.Allocator,
    opts: RunOptions,
    e: Entry,
    strip: []const []const u8,
    line_buf: []u8,
) ManifestError!usize {
    _ = app;
    const path = try resolvePath(sa, opts.base_dir, e.file);
    const col = (try collections.get(sa, w, e.collection)) orelse return ManifestError.UnknownCollection;

    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var fr = f.readerStreaming(io, line_buf);

    var row_arena = std.heap.ArenaAllocator.init(sa);
    defer row_arena.deinit();

    var n: usize = 0;
    try w.begin();
    errdefer w.rollback() catch {};
    while (true) {
        const maybe = try fr.interface.takeDelimiter('\n');
        const raw = maybe orelse break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        _ = row_arena.reset(.retain_capacity);
        const a = row_arena.allocator();

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (parsed != .object) continue;

        var patch: std.json.ObjectMap = .empty;
        for (strip) |field| {
            const v = parsed.object.get(field) orelse continue;
            if (v == .null) continue;
            try patch.put(a, field, v);
        }
        if (patch.count() == 0) continue;

        const idv = parsed.object.get("id") orelse return ManifestError.DeferredRowMissingId;
        if (idv != .string or idv.string.len == 0) return ManifestError.DeferredRowMissingId;

        _ = try records.updateInTxn(a, w, col, idv.string, .{ .object = patch });
        n += 1;
    }
    if (opts.import.dry_run) try w.rollback() else try w.commit();
    return n;
}
```

This introduces **one new `import.Options` field** that Task 6 did not add — add it now in
`src/import.zig` alongside the others, and honor it in `importRow` by skipping those keys
when building the record data:

```zig
    /// Field names to drop from every row before importing. The manifest runner uses this
    /// to hold back relation values it will patch in a second pass.
    strip_fields: []const []const u8 = &.{},
```

- [ ] **Step 5: Register and run**

Add to `src/root.zig`'s `test { … }` block:

```zig
    _ = @import("import_manifest.zig");
```

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: PASS — N up by 4.

Add one `import.zig` test for the new option while you are there:

```zig
test "import: strip_fields drops the named keys before the engine sees them" {
    var app = try testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    try seedPosts(&w);
    const rep = try runNdjson(&app, &w,
        \\{"title":"t","body":"dropped"}
        \\
    , .{ .collection = "posts", .strip_fields = &.{"body"} });
    try std.testing.expectEqual(@as(usize, 1), rep.created);
    var st = try w.prepare("SELECT \"body\" FROM \"posts\";");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(usize, 0), st.columnText(0).len);
}
```
(If `seedPosts`'s `posts` collection has no `body` field, add one there — it is a test
fixture, and Task 6's tests already depend on `title` being required.)

- [ ] **Step 6: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/import_manifest.zig src/import.zig src/schema_diff.zig src/root.zig
git add src/import_manifest.zig src/import.zig src/schema_diff.zig src/root.zig
git commit -m "Load a whole dataset in relation order, deferring the values that cannot be

Single relations carry a real FK and every relation element is existence-checked,
so files must load target-first. Two shapes cannot be ordered at all — a
cross-collection cycle, and a self-relation where row 1 points at row 5 in the
same file. Both are deferred: phase 1 loads with those keys stripped, phase 2
patches them by record id. Reuses the DDL pump's ordering routine rather than a
second topological sort."
```

---

### Task 8: `zigbase import --manifest FILE` and its end-to-end test

**Files:**
- Modify: `src/cli.zig` (`ImportArgs.manifest` + parser + test)
- Modify: `src/framework.zig` (`importImpl` manifest branch, `printImportUsage`)
- Create: `tests/admin/test_import_manifest.py`

**Interfaces:**
- CLI contract: `zigbase import --manifest FILE [--dry-run] [--continue-on-error]
  [--error-log F] [--progress N] [--json] [--data-dir PATH]`. `--manifest` is **mutually
  exclusive** with `--collection`, `--upsert-key` and the positional file (those come from
  the manifest); passing both is a parse error.
- `--json` summary object for a manifest run:
```json
{"zigbaseImport":1,"manifest":"m.json","dry_run":false,"patched":4,"failed":0,
 "collections":[{"collection":"authors","created":2,"updated":0,"failed":0},
                {"collection":"posts","created":3,"updated":0,"failed":0}]}
```
- Exit codes as Task 6: `0` clean, `3` if any row was skipped, `1` fatal.

- [ ] **Step 1: Parser**

In `src/cli.zig`, add to `ImportArgs`:

```zig
    /// Multi-collection manifest path. Mutually exclusive with --collection/--upsert-key
    /// and the positional file, which it supplies instead.
    manifest: ?[]const u8 = null,
```

Add the flag arm inside the `import` block:

```zig
            } else if (std.mem.eql(u8, a, "--manifest")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ia.manifest = args[i];
```

and, immediately before `return .{ .import = ia };`, the exclusivity check:

```zig
        // --manifest supplies the collection, the upsert key and the file; combining them
        // would leave two sources of truth for the same thing.
        if (ia.manifest != null and (ia.collection != null or ia.upsert_key != null or ia.file != null))
            return ParseError.BadValue;
```

Test:

```zig
test "import --manifest parses and excludes the single-collection flags" {
    const cmd = try parse(&.{ "import", "--manifest", "m.json", "--json" }, .{});
    try std.testing.expectEqualStrings("m.json", cmd.import.manifest.?);
    try std.testing.expect(cmd.import.json);
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "import", "--manifest", "m.json", "--collection", "x" }, .{}));
    try std.testing.expectError(ParseError.BadValue, parse(&.{ "import", "--manifest", "m.json", "f.ndjson" }, .{}));
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "import", "--manifest" }, .{}));
}
```

- [ ] **Step 2: Wire `importImpl`**

At the top of `importImpl`, branch before the existing `--collection` requirement:

```zig
    if (ia.manifest) |mpath| return importManifestImpl(allocator, io, environ, ia, mpath, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts);
```

Add the sibling implementation (it repeats `importImpl`'s boot + writer-acquire + sink
setup, then delegates):

```zig
/// `zigbase import --manifest <m.json>`: load several collections in relation order,
/// deferring the values that cannot be ordered (cycles, self-relations). Relative `file`
/// paths in the manifest resolve against the MANIFEST's directory, not the cwd, so a
/// migration bundle is relocatable.
fn importManifestImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    ia: cli.ImportArgs,
    mpath: []const u8,
    dispatch: *const events.Dispatch,
    jobs: []const scheduler.RuntimeJob,
    pool_size: usize,
    schema_collections: []const schema.Collection,
    schema_migrations: []const provision.Migration,
    comptime opts: ServeOpts,
) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = ia.data_dir });
    const holder = try bootApp(allocator, io, cfg, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts, environ);
    defer holder.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, a, mpath, 8 << 20) catch |e| {
        std.log.err("import: cannot read manifest '{s}': {s}", .{ mpath, @errorName(e) });
        return e;
    };
    var manifest = import_manifest.parseManifest(a, bytes) catch |e| {
        std.log.err("import: '{s}' is not a valid import manifest: {s}", .{ mpath, @errorName(e) });
        return e;
    };
    defer manifest.deinit();

    const base_dir = std.fs.path.dirname(mpath) orelse ".";

    // Same sinks as the single-collection path (Task 6).
    var err_file: ?std.Io.File = null;
    defer if (err_file) |f| f.close(io);
    var err_buf: [8192]u8 = undefined;
    var err_writer: ?std.Io.File.Writer = null;
    if (ia.error_log) |path| {
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        err_file = f;
        err_writer = f.writer(io, &err_buf);
    }
    var prog_buf: [256]u8 = undefined;
    var prog_writer = std.Io.File.stderr().writer(io, &prog_buf);

    const w = holder.pool.acquireWriter();
    defer holder.pool.releaseWriter();

    const report = import_manifest.run(&holder.app, w, io, allocator, manifest, .{
        .base_dir = base_dir,
        .import = .{
            .collection = "", // supplied per entry
            .batch_size = ia.batch_size,
            .dry_run = ia.dry_run,
            .continue_on_error = ia.continue_on_error,
            .error_log = if (err_writer) |*ew| &ew.interface else null,
            .progress_every = ia.progress,
            .progress = if (ia.progress > 0) &prog_writer.interface else null,
        },
    }) catch |e| {
        std.log.err("import manifest '{s}' failed: {s}", .{ mpath, @errorName(e) });
        return e;
    };
    defer allocator.free(report.entries);
    if (err_writer) |*ew| try ew.interface.flush();

    if (ia.json) {
        var cols: std.json.Array = .init(a);
        for (report.entries) |er| {
            var o: std.json.ObjectMap = .empty;
            try o.put(a, "collection", .{ .string = er.collection });
            try o.put(a, "created", .{ .integer = @intCast(er.created) });
            try o.put(a, "updated", .{ .integer = @intCast(er.updated) });
            try o.put(a, "failed", .{ .integer = @intCast(er.failed) });
            try cols.append(.{ .object = o });
        }
        var root: std.json.ObjectMap = .empty;
        try root.put(a, "zigbaseImport", .{ .integer = 1 });
        try root.put(a, "manifest", .{ .string = mpath });
        try root.put(a, "dry_run", .{ .bool = ia.dry_run });
        try root.put(a, "patched", .{ .integer = @intCast(report.patched) });
        try root.put(a, "failed", .{ .integer = @intCast(report.failed) });
        try root.put(a, "collections", .{ .array = cols });
        const body = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});
        var out_buf: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &out_buf);
        try out.interface.writeAll(body);
        try out.interface.writeAll("\n");
        try out.interface.flush();
    }
    std.log.info("import manifest complete: {d} collection(s), {d} deferred relation(s) patched, {d} failed", .{
        report.entries.len, report.patched, report.failed,
    });
    if (report.failed > 0) std.process.exit(3);
}
```

Add `const import_manifest = @import("import_manifest.zig");` to `src/framework.zig`'s
imports, and extend `printImportUsage` with:

```
  --manifest FILE    Load several collections in relation order from a manifest:
                     {"zigbaseImportManifest":1,"collections":[
                       {"collection":"authors","file":"authors.ndjson"},
                       {"collection":"posts","file":"posts.ndjson","upsertKey":"slug"}]}
                     File paths resolve against the MANIFEST's directory. Relation cycles
                     and self-relations are loaded with the offending values stripped and
                     patched afterwards by record id (those rows must carry their own id).
                     Excludes --collection/--upsert-key and the positional file.
```

- [ ] **Step 3: Extend the import fixture with a relation graph**

`fixtures/import/main.zig` has no relation field, so nothing there can exercise the runner.
Add two collections to its `.collections` (keep `members` and `vault` untouched — existing
tests depend on them):

```zig
        // Relation graph for the manifest e2e: `posts.author` -> `authors`, plus a
        // self-relation on `authors.mentor` so the deferred-patch path is exercised.
        .authors = .{
            .fields = .{
                .{ .name = "nom", .type = .text, .required = true },
                .{ .name = "mentor", .type = .relation, .collection = "authors" },
            },
            .rules = .{ .list = "@public", .view = "@public" },
        },
        .posts = .{
            .fields = .{
                .{ .name = "title", .type = .text, .required = true },
                .{ .name = "author", .type = .relation, .collection = "authors" },
            },
            .rules = .{ .list = "@public", .view = "@public" },
        },
```
Use the exact comptime relation-field spelling this repo uses — check
`grep -n "type = .relation" -A 2 fixtures/dating/schema.zig | head -20` and copy it; do not
guess the key name for the target collection.

- [ ] **Step 4: Write the e2e**

Create `tests/admin/test_import_manifest.py`:

```python
"""End-to-end coverage for `zigbase import --manifest` and the Task 6 hardening flags.

Uses the `import-fixture` binary (fixtures/import/main.zig), which declares the relation
graph `posts.author -> authors` plus the self-relation `authors.mentor -> authors`.
"""
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import tempfile

import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]
FIELD_KEY = "an-operator-supplied-field-key-32b"


@pytest.fixture(scope="session")
def import_binary():
    override = os.environ.get("ZIGBASE_TEST_IMPORT_BINARY")
    if override:
        if not pathlib.Path(override).exists():
            raise FileNotFoundError(f"ZIGBASE_TEST_IMPORT_BINARY={override} does not exist")
        return override
    subprocess.run(ZIG + ["build", "import-fixture"], cwd=REPO, check=True)
    path = REPO / "zig-out" / "bin" / "import-fixture"
    assert path.exists(), f"import-fixture not built at {path}"
    return str(path)


@pytest.fixture()
def data_dir():
    d = tempfile.mkdtemp(prefix="zb_manifest_")
    yield d
    shutil.rmtree(d, ignore_errors=True)


def env(data):
    return {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_FIELD_KEY": FIELD_KEY}


def write(data, name, text):
    p = os.path.join(data, name)
    pathlib.Path(p).write_text(text)
    return p


def query(data, sql):
    con = sqlite3.connect(os.path.join(data, "data.db"))
    try:
        return con.execute(sql).fetchall()
    finally:
        con.close()


def test_manifest_loads_out_of_order_files_and_patches_deferred_relations(import_binary, data_dir):
    # `posts` is listed FIRST and references `authors`; `authors.mentor` is a self-relation
    # whose child row appears BEFORE its mentor. Neither can load naively.
    write(data_dir, "posts.ndjson",
          '{"id":"post0000000001","title":"Hello","author":"author00000001"}\n')
    write(data_dir, "authors.ndjson",
          '{"id":"author00000001","nom":"Ada","mentor":"author00000002"}\n'
          '{"id":"author00000002","nom":"Grace","mentor":null}\n')
    manifest = write(data_dir, "m.json", json.dumps({
        "zigbaseImportManifest": 1,
        "collections": [
            {"collection": "posts", "file": "posts.ndjson"},
            {"collection": "authors", "file": "authors.ndjson"},
        ],
    }))

    r = subprocess.run([import_binary, "import", "--manifest", manifest, "--json",
                        "--data-dir", data_dir], env=env(data_dir), capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["failed"] == 0
    assert out["patched"] == 1  # only Ada carried a mentor
    by_col = {c["collection"]: c for c in out["collections"]}
    assert by_col["authors"]["created"] == 2
    assert by_col["posts"]["created"] == 1

    assert query(data_dir, 'SELECT author FROM posts') == [("author00000001",)]
    assert query(data_dir, 'SELECT mentor FROM authors WHERE id="author00000001"') == [("author00000002",)]


def test_manifest_dry_run_writes_nothing(import_binary, data_dir):
    write(data_dir, "authors.ndjson", '{"id":"author00000001","nom":"Ada"}\n')
    manifest = write(data_dir, "m.json", json.dumps({
        "zigbaseImportManifest": 1,
        "collections": [{"collection": "authors", "file": "authors.ndjson"}],
    }))
    r = subprocess.run([import_binary, "import", "--manifest", manifest, "--dry-run", "--json",
                        "--data-dir", data_dir], env=env(data_dir), capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout)["dry_run"] is True
    assert query(data_dir, "SELECT count(*) FROM authors") == [(0,)]


def test_continue_on_error_exits_3_and_writes_findings(import_binary, data_dir):
    src = write(data_dir, "vault.ndjson",
                '{"code":"A"}\nnot json\n{"code":"B"}\n{"nope":"missing required code"}\n')
    log = os.path.join(data_dir, "errs.ndjson")
    r = subprocess.run([import_binary, "import", "--collection", "vault", "--data-dir", data_dir,
                        "--continue-on-error", "--error-log", log, "--json", src],
                       env=env(data_dir), capture_output=True, text=True)
    assert r.returncode == 3, r.stderr
    out = json.loads(r.stdout)
    assert (out["created"], out["failed"]) == (2, 2)
    findings = [json.loads(l) for l in pathlib.Path(log).read_text().splitlines() if l.strip()]
    assert [f["line"] for f in findings] == [2, 4]
    assert findings[0]["code"] == "MalformedJson"
    assert query(data_dir, "SELECT count(*) FROM vault") == [(2,)]


def test_manifest_rejects_a_bad_document_and_an_unknown_collection(import_binary, data_dir):
    bad = write(data_dir, "bad.json", '{"collections":[]}')
    r = subprocess.run([import_binary, "import", "--manifest", bad, "--data-dir", data_dir],
                       env=env(data_dir), capture_output=True, text=True)
    assert r.returncode == 1 and "InvalidManifest" in r.stderr

    write(data_dir, "x.ndjson", "{}\n")
    unknown = write(data_dir, "u.json", json.dumps({
        "zigbaseImportManifest": 1,
        "collections": [{"collection": "nosuch", "file": "x.ndjson"}],
    }))
    r2 = subprocess.run([import_binary, "import", "--manifest", unknown, "--data-dir", data_dir],
                        env=env(data_dir), capture_output=True, text=True)
    assert r2.returncode == 1 and "UnknownCollection" in r2.stderr
```

- [ ] **Step 5: Run**

```bash
mise exec zig@0.16.0 -- zig fmt src/cli.zig src/framework.zig
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"
mise exec zig@0.16.0 -- zig build import-fixture
ZIGBASE_TEST_IMPORT_BINARY=$PWD/zig-out/bin/import-fixture \
  mise exec python@3.13 -- python -m pytest tests/admin/test_import_manifest.py tests/admin/test_import.py -q
```
Expected: `10 passed` — the four new tests plus the six pre-existing `test_import.py` tests,
which must still pass unchanged (the fixture gained collections but lost none).

- [ ] **Step 6: Commit**

```bash
git add src/cli.zig src/framework.zig fixtures/import/main.zig tests/admin/test_import_manifest.py
git commit -m "Add \`zigbase import --manifest\` for whole-dataset loads

One command loads every collection in relation order and patches the values
that cannot be ordered. Manifest paths resolve against the manifest's own
directory so a migration bundle is relocatable. The import fixture gains a
relation graph with a self-relation, which is what the deferred-patch path
needs to be exercised end to end."
```

---

### Task 9: Tagged legacy hashes and bcrypt verification (`src/crypto.zig`)

**Dependency finding (verified, no flag needed): `std.crypto.pwhash.bcrypt` ships in Zig
0.16.0** (`lib/std/crypto/bcrypt.zig`, exposed at `lib/std/crypto.zig:190`). **No new C
dependency is required.** Three landmines in it are load-bearing and must be handled
exactly as specified below — miss any one and PocketBase hashes silently never verify:

1. **`bcrypt.strVerify` only accepts `$2b$`.** `CryptFormatHasher.verify` recomputes the
   whole 60-byte string with a hardcoded `b` version byte
   (`crypt_format.strHashInternal`, `bcrypt.zig:624-645`) and then compares the **full
   string** with `mem.eql`. A stored `$2a$10$…` therefore mismatches at byte 2 and returns
   `PasswordVerificationFailed` **even for the correct password**. PocketBase uses Go's
   `golang.org/x/crypto/bcrypt`, which emits `$2a$`. **The version byte must be normalized
   to `b` before verifying.**
2. **`silently_truncate_password` has no default and the OWASP preset gets it wrong for
   this job.** With `false` (the `Params.owasp` value), a password over 72 bytes is
   HMAC-SHA512 pre-hashed instead of truncated — which is *not* what PHP, Go, Node or
   Python bcrypt do. Verifying a foreign hash requires **`silently_truncate_password =
   true`**, or every user with a long password is locked out.
3. **Strict framing.** `str.len` must be exactly 60, `str[3]` and `str[6]` must be `$`, and
   the cost is a fixed two-digit field (`$2b$4$…` is `InvalidEncoding`).

**`$2x$` is deliberately rejected.** `$2a`/`$2b`/`$2y` denote the same KDF for the
passwords every modern implementation produces (they record length-overflow and
8-bit-character bug fixes that correct implementations do not exhibit), so normalizing them
to `b` is sound. `$2x$` marks the *preserved-buggy* crypt_blowfish sign-extension
behaviour, which Zig does not reproduce — verifying it here would silently fail for any
password containing a high-bit byte. Refusing it loudly is the honest outcome.

**Files:**
- Modify: `src/crypto.zig`

**Interfaces:**
- Produces:
```zig
/// Marker for an imported, not-yet-upgraded credential: `$zblegacy$<alg>$<original-hash>`.
/// Stored in the ordinary `passwordHash` column. An UNTAGGED foreign hash is never
/// accepted — no verifier matches it, so it fails closed.
pub const legacy_prefix = "$zblegacy$";

/// The complete algorithm allowlist. Append-only, and only after a security review.
pub const legacy_algorithms = [_][]const u8{"bcrypt"};

pub const LegacyError = error{ UnsupportedAlgorithm, MalformedLegacyHash };

pub const LegacyHash = struct { algorithm: []const u8, hash: []const u8 };

pub fn isLegacyHash(stored: []const u8) bool;

/// Split a tagged value. Borrows from `stored`.
pub fn parseLegacy(stored: []const u8) LegacyError!LegacyHash;

/// Validate `algorithm` against the allowlist AND `hash` against that algorithm's format,
/// then build the tagged value. Owned result on `alloc`.
pub fn wrapLegacy(alloc: std.mem.Allocator, algorithm: []const u8, hash: []const u8) (LegacyError || std.mem.Allocator.Error)![]u8;

/// Verify a password against a TAGGED legacy hash. Returns false — never an error — on any
/// mismatch, unknown algorithm or malformed hash, matching `verifyPassword`'s contract so
/// no caller can accidentally treat "broken hash" as "authenticated".
pub fn verifyLegacy(stored: []const u8, password: []const u8) bool;
```

- [ ] **Step 1: Write the failing tests**

Append to `src/crypto.zig`'s tests:

```zig
test "legacy tag round-trips and rejects everything outside the allowlist" {
    const a = std.testing.allocator;
    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";

    const tagged = try wrapLegacy(a, "bcrypt", bc);
    defer a.free(tagged);
    try std.testing.expectEqualStrings("$zblegacy$bcrypt$" ++ bc, tagged);
    try std.testing.expect(isLegacyHash(tagged));
    try std.testing.expect(!isLegacyHash(dummy_password_hash)); // an argon2 PHC is not legacy

    const parsed = try parseLegacy(tagged);
    try std.testing.expectEqualStrings("bcrypt", parsed.algorithm);
    try std.testing.expectEqualStrings(bc, parsed.hash);

    // Allowlist: only what is on it, by TAG, never inferred from the hash itself.
    try std.testing.expectError(LegacyError.UnsupportedAlgorithm, wrapLegacy(a, "md5", bc));
    try std.testing.expectError(LegacyError.UnsupportedAlgorithm, wrapLegacy(a, "scrypt", bc));
    try std.testing.expectError(LegacyError.UnsupportedAlgorithm, wrapLegacy(a, "", bc));
    // Format: wrong length, wrong framing, single-digit cost, and the buggy $2x variant.
    try std.testing.expectError(LegacyError.MalformedLegacyHash, wrapLegacy(a, "bcrypt", "$2a$10$short"));
    try std.testing.expectError(LegacyError.MalformedLegacyHash, wrapLegacy(a, "bcrypt", bc[0..59]));
    try std.testing.expectError(LegacyError.MalformedLegacyHash, wrapLegacy(a, "bcrypt", "$2x$" ++ bc[4..]));
    try std.testing.expectError(LegacyError.MalformedLegacyHash, wrapLegacy(a, "bcrypt", "$argon2id$v=19$m=8,t=1,p=1$aaaa$bbbb"));
    try std.testing.expectError(LegacyError.MalformedLegacyHash, parseLegacy("$zblegacy$bcrypt"));
    try std.testing.expectError(LegacyError.UnsupportedAlgorithm, parseLegacy("$zblegacy$md5$x"));
}

test "verifyLegacy accepts $2a/$2b/$2y bcrypt hashes of the same password" {
    // "abc" hashed at cost 4 by a reference implementation, presented under each version
    // byte. All three denote the same KDF; Zig's strVerify only accepts `b`, so the
    // implementation must normalize. Regenerate with:
    //   python3 -c 'import bcrypt;print(bcrypt.hashpw(b"abc",bcrypt.gensalt(4)).decode())'
    const b2b = "$2b$04$LlIFuLM6RC2FI4t5B5wgVOmU/dqGb4L7VUnl1DHV3Q4jSJ0AVMHU2";
    const a = std.testing.allocator;
    inline for (.{ "a", "b", "y" }) |ver| {
        var buf: [60]u8 = undefined;
        @memcpy(&buf, b2b);
        buf[2] = ver[0];
        const tagged = try wrapLegacy(a, "bcrypt", &buf);
        defer a.free(tagged);
        try std.testing.expect(verifyLegacy(tagged, "abc"));
        try std.testing.expect(!verifyLegacy(tagged, "abd"));
        try std.testing.expect(!verifyLegacy(tagged, ""));
    }
}

test "verifyLegacy truncates at 72 bytes the way every other bcrypt does" {
    // Reference implementations ignore bytes past 72. Zig's default instead HMAC-pre-hashes
    // a long password, which would lock out any user whose password exceeds 72 bytes.
    const a = std.testing.allocator;
    const base = "x" ** 72;
    const long = base ++ "IGNORED-BY-EVERY-OTHER-BCRYPT";
    const h = try bcryptHashForTest(a, base); // helper below
    defer a.free(h);
    const tagged = try wrapLegacy(a, "bcrypt", h);
    defer a.free(tagged);
    try std.testing.expect(verifyLegacy(tagged, base));
    try std.testing.expect(verifyLegacy(tagged, long));
}

test "verifyLegacy fails closed on garbage, and verifyPassword never accepts a legacy value" {
    const a = std.testing.allocator;
    try std.testing.expect(!verifyLegacy("$zblegacy$bcrypt$not-a-hash", "abc"));
    try std.testing.expect(!verifyLegacy("$zblegacy$md5$whatever", "abc"));
    try std.testing.expect(!verifyLegacy("not tagged at all", "abc"));
    // The argon2 verifier must never authenticate a tagged legacy value, so a caller that
    // forgets to branch fails CLOSED rather than open.
    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
    const tagged = try wrapLegacy(a, "bcrypt", bc);
    defer a.free(tagged);
    try std.testing.expect(!verifyPassword(std.testing.io, a, tagged, "abc"));
    try std.testing.expect(!verifyPassword(std.testing.io, a, bc, "abc"));
}
```

Add the test helper (test-only, kept private):

```zig
/// Produce a cost-4 bcrypt hash in the 60-char crypt format — test scaffolding only, so the
/// truncation test does not depend on a hardcoded vector.
fn bcryptHashForTest(alloc: std.mem.Allocator, password: []const u8) ![]u8 {
    var buf: [bcrypt.hash_length]u8 = undefined;
    const s = try bcrypt.strHash(password, .{
        .params = .{ .rounds_log = 4, .silently_truncate_password = true },
        .encoding = .crypt,
    }, &buf, std.testing.io);
    return alloc.dupe(u8, s);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -20`
Expected: FAIL — `use of undeclared identifier 'wrapLegacy'`.

- [ ] **Step 3: Implement**

Add near the top of `src/crypto.zig`, beside `const argon2 = std.crypto.pwhash.argon2;`:

```zig
const bcrypt = std.crypto.pwhash.bcrypt;
```

Add the implementation:

```zig
// ---------------------------------------------------------------------------
// Legacy (imported) password hashes.
//
// A credential migrated from another backend is stored in the ordinary `passwordHash`
// column, tagged: `$zblegacy$<alg>$<original-hash>`. The tag — not the hash's own prefix —
// selects the verifier, so an untagged foreign hash matches nothing and fails CLOSED.
// The ONLY writer of a tagged value is the offline `zigbase import --legacy-hashes` seam;
// the login path replaces it with argon2id on the first successful verification and never
// writes one back. See docs/migration-tools.md.
// ---------------------------------------------------------------------------

pub const legacy_prefix = "$zblegacy$";

/// The complete algorithm allowlist. Append-only, and only after a security review.
pub const legacy_algorithms = [_][]const u8{"bcrypt"};

pub const LegacyError = error{ UnsupportedAlgorithm, MalformedLegacyHash };

pub const LegacyHash = struct { algorithm: []const u8, hash: []const u8 };

pub fn isLegacyHash(stored: []const u8) bool {
    return std.mem.startsWith(u8, stored, legacy_prefix);
}

fn isAllowedAlgorithm(alg: []const u8) bool {
    for (legacy_algorithms) |a| if (std.mem.eql(u8, a, alg)) return true;
    return false;
}

/// A bcrypt crypt-format hash: exactly 60 bytes, `$2<v>$<cc>$<22-char salt><31-char hash>`.
/// `$2x$` is REFUSED: it marks the deliberately-preserved crypt_blowfish 8-bit bug, which
/// this implementation does not reproduce, so accepting it would silently fail to verify
/// any password containing a high-bit byte.
fn isBcryptHash(h: []const u8) bool {
    if (h.len != bcrypt.hash_length) return false; // 60
    if (h[0] != '$' or h[1] != '2' or h[3] != '$' or h[6] != '$') return false;
    switch (h[2]) {
        'a', 'b', 'y' => {},
        else => return false,
    }
    if (!std.ascii.isDigit(h[4]) or !std.ascii.isDigit(h[5])) return false;
    return true;
}

pub fn parseLegacy(stored: []const u8) LegacyError!LegacyHash {
    if (!isLegacyHash(stored)) return LegacyError.MalformedLegacyHash;
    const rest = stored[legacy_prefix.len..];
    const sep = std.mem.indexOfScalar(u8, rest, '$') orelse return LegacyError.MalformedLegacyHash;
    const alg = rest[0..sep];
    const hash = rest[sep + 1 ..];
    if (!isAllowedAlgorithm(alg)) return LegacyError.UnsupportedAlgorithm;
    if (hash.len == 0) return LegacyError.MalformedLegacyHash;
    return .{ .algorithm = alg, .hash = hash };
}

pub fn wrapLegacy(alloc: std.mem.Allocator, algorithm: []const u8, hash: []const u8) (LegacyError || std.mem.Allocator.Error)![]u8 {
    if (!isAllowedAlgorithm(algorithm)) return LegacyError.UnsupportedAlgorithm;
    // Validate the hash against the algorithm at IMPORT time, so a malformed credential is
    // rejected while an operator is watching rather than at some user's next login.
    if (std.mem.eql(u8, algorithm, "bcrypt") and !isBcryptHash(hash)) return LegacyError.MalformedLegacyHash;
    return std.fmt.allocPrint(alloc, "{s}{s}${s}", .{ legacy_prefix, algorithm, hash });
}

pub fn verifyLegacy(stored: []const u8, password: []const u8) bool {
    const parsed = parseLegacy(stored) catch return false;
    if (!std.mem.eql(u8, parsed.algorithm, "bcrypt")) return false;
    if (!isBcryptHash(parsed.hash)) return false;

    // `bcrypt.strVerify` recomputes the whole 60-byte string with a hardcoded `b` version
    // byte and compares it in full, so a stored `$2a$`/`$2y$` mismatches at byte 2 even for
    // the RIGHT password. `$2a`/`$2b`/`$2y` denote the same KDF here, so normalize to `b`.
    var buf: [bcrypt.hash_length]u8 = undefined;
    @memcpy(&buf, parsed.hash);
    buf[2] = 'b';

    // `silently_truncate_password = true` matches every mainstream implementation (PHP, Go,
    // Node, Python), which ignore bytes past 72. The Zig default pre-hashes instead, which
    // would lock out every user with a password longer than that.
    bcrypt.strVerify(&buf, password, .{ .silently_truncate_password = true }) catch return false;
    return true;
}
```

**Timing note to carry into the code review, stated once here:** `bcrypt.strVerify`'s final
comparison is `mem.eql`, which is exactly what the argon2 path already in production uses
(`std/crypto/argon2.zig:573`). This introduces **no new timing property**. The one accepted
residual is that bcrypt and argon2id have different verify costs, so response timing can
distinguish a not-yet-migrated account from a migrated one; it cannot distinguish an
existing account from a non-existent one, because `dummyVerify` still covers the
unknown-identity path.

- [ ] **Step 4: Run it to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: PASS — N up by 4.

If `verifyLegacy accepts $2a/$2b/$2y…` fails on all three versions, the hardcoded vector is
wrong for `"abc"` — regenerate it with the command in the comment rather than weakening the
test. If it fails on `$2a`/`$2y` only, the version normalization is missing.

- [ ] **Step 5: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/crypto.zig
git add src/crypto.zig
git commit -m "Add tagged legacy password hashes with bcrypt verification

Imported credentials are stored as \$zblegacy\$<alg>\$<hash> in the ordinary
passwordHash column: the TAG selects the verifier against a hardcoded
allowlist, so an untagged foreign hash matches nothing and fails closed.
bcrypt comes from Zig 0.16 std — no new dependency — but needs two fixes to
be usable: std only accepts \$2b\$ (PocketBase emits \$2a\$, so the version
byte is normalized) and defaults to HMAC-pre-hashing long passwords instead
of truncating at 72 like every other implementation. \$2x\$ is refused."
```

---

### Task 10: `zigbase import --legacy-hashes bcrypt`

The records REST API can never install a legacy hash: `auth.isServerManagedField`
(`src/auth.zig:32-40`) strips `passwordHash` and `verified` from every client payload, and
that strip **stays**. The import seam is therefore a distinct, offline, operator-only path.

**Files:**
- Modify: `src/import.zig`
- Modify: `src/cli.zig` (`ImportArgs.legacy_hashes` + parser + test)
- Modify: `src/framework.zig` (forward the option, extend `printImportUsage`)

**Interfaces:**
- Produces in `src/import.zig`:
```zig
    /// Enable the legacy-credential seam for this run, tagging each row's `passwordHash`
    /// with this algorithm. Only values in `crypto.legacy_algorithms` are accepted.
    /// Requires an auth collection; refuses `_superusers`.
    legacy_hash_algorithm: ?[]const u8 = null,
```
  and the new members of `ImportError`:
```zig
    LegacyRequiresAuthCollection,
    LegacySuperuserRefused,
    LegacyRowMissingId,
    LegacyHashConflict,
```
- CLI contract: `--legacy-hashes <alg>` (currently only `bcrypt`). Under it, each NDJSON row
  may carry `"passwordHash"` (the **source** hash verbatim, e.g. `$2a$10$…`) and
  `"verified"`; both are otherwise ignored by every path. Each row **must** carry its own
  `"id"`.

**Why the row must carry an `id`:** the tagged hash is written by a follow-up `UPDATE`
inside the same transaction, which needs the record's primary key. Requiring the source id
(rather than reading back a generated one) keeps the seam independent of the create path's
return shape, and every real export has ids — the same requirement Task 7's deferred-relation
patch already imposes.

**Why `verified` is carried too:** a migration that silently unverifies every existing user
is not a migration — it mails a verification demand to the entire user base on cutover day.
It is honored **only** under `--legacy-hashes`, i.e. only on the operator-only offline path.

- [ ] **Step 1: Write the failing tests**

Append to `src/import.zig`'s tests:

```zig
test "import: --legacy-hashes stores a tagged hash, honors verified, and never stores plaintext" {
    const a = std.testing.allocator;
    var app = try testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();

    const members = try collections.create(a, app.io, &w, .{
        .id = "", .name = "members", .type = .auth,
        .fields = &.{.{ .id = "", .name = "nom", .options = .{ .text = .{} } }},
    });
    defer members.deinit(a);

    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
    const rep = try runNdjson(&app, &w,
        "{\"id\":\"member000000001\",\"email\":\"ada@example.com\",\"nom\":\"Ada\"," ++
            "\"passwordHash\":\"" ++ bc ++ "\",\"verified\":true}\n",
        .{ .collection = "members", .legacy_hash_algorithm = "bcrypt" });
    try std.testing.expectEqual(@as(usize, 1), rep.created);

    var st = try w.prepare("SELECT \"passwordHash\", \"verified\", \"tokenKey\" FROM \"members\" WHERE \"id\"='member000000001';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("$zblegacy$bcrypt$" ++ bc, st.columnText(0));
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(1)); // verified carried over
    try std.testing.expect(st.columnText(2).len > 0); // tokenKey still provisioned
}

test "import: --legacy-hashes refuses a base collection, _superusers, an id-less row, and a bad hash" {
    const a = std.testing.allocator;
    var app = try testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    try seedPosts(&w);

    const bc = "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
    // A base collection has no credentials to import into.
    try std.testing.expectError(ImportError.LegacyRequiresAuthCollection, runNdjson(&app, &w,
        "{\"id\":\"x00000000000001\",\"title\":\"t\"}\n",
        .{ .collection = "posts", .legacy_hash_algorithm = "bcrypt" }));

    const members = try collections.create(a, app.io, &w, .{
        .id = "", .name = "members", .type = .auth, .fields = &.{},
    });
    defer members.deinit(a);

    // No id: nothing to key the credential UPDATE on.
    try std.testing.expectError(ImportError.LegacyRowMissingId, runNdjson(&app, &w,
        "{\"email\":\"a@b.c\",\"passwordHash\":\"" ++ bc ++ "\"}\n",
        .{ .collection = "members", .legacy_hash_algorithm = "bcrypt" }));
    // Plaintext AND a source hash in one row: ambiguous, so refused rather than guessed.
    try std.testing.expectError(ImportError.LegacyHashConflict, runNdjson(&app, &w,
        "{\"id\":\"m00000000000001\",\"email\":\"a@b.c\",\"password\":\"plaintext1\",\"passwordHash\":\"" ++ bc ++ "\"}\n",
        .{ .collection = "members", .legacy_hash_algorithm = "bcrypt" }));
    // A malformed or non-allowlisted hash is caught at IMPORT time, not at some login.
    try std.testing.expectError(crypto.LegacyError.MalformedLegacyHash, runNdjson(&app, &w,
        "{\"id\":\"m00000000000002\",\"email\":\"c@d.e\",\"passwordHash\":\"nope\"}\n",
        .{ .collection = "members", .legacy_hash_algorithm = "bcrypt" }));
    try std.testing.expectError(crypto.LegacyError.UnsupportedAlgorithm, runNdjson(&app, &w,
        "{\"id\":\"m00000000000003\",\"email\":\"e@f.g\",\"passwordHash\":\"" ++ bc ++ "\"}\n",
        .{ .collection = "members", .legacy_hash_algorithm = "md5" }));
    // The highest-value target is never importable.
    try std.testing.expectError(ImportError.LegacySuperuserRefused, runNdjson(&app, &w,
        "{\"id\":\"s00000000000001\",\"email\":\"root@x.io\",\"passwordHash\":\"" ++ bc ++ "\"}\n",
        .{ .collection = "_superusers", .legacy_hash_algorithm = "bcrypt" }));
}

test "import: WITHOUT --legacy-hashes a passwordHash in the row is silently ignored" {
    // The pre-existing strip must not weaken: an ordinary import can never install a
    // credential, no matter what the file claims.
    const a = std.testing.allocator;
    var app = try testApp();
    defer app.deinit();
    var w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const members = try collections.create(a, app.io, &w, .{
        .id = "", .name = "members", .type = .auth, .fields = &.{},
    });
    defer members.deinit(a);

    _ = try runNdjson(&app, &w,
        "{\"id\":\"m00000000000009\",\"email\":\"a@b.c\",\"passwordHash\":\"$2a$10$whatever\",\"verified\":true}\n",
        .{ .collection = "members" });
    var st = try w.prepare("SELECT \"passwordHash\", \"verified\" FROM \"members\" WHERE \"id\"='m00000000000009';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(usize, 0), st.columnText(0).len);
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(1));
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -20`
Expected: FAIL — `no field named 'legacy_hash_algorithm'`.

- [ ] **Step 3: Implement**

Add the option and the error-set members listed in **Interfaces**. In `prep` (the run
setup), validate the mode once, before any row is read — a misconfigured run must fail
before it writes anything:

```zig
    if (opts.legacy_hash_algorithm) |alg| {
        // The superuser table is created by `zigbase superuser create` with a real password;
        // there is no migration story for it, and it is the highest-value target.
        if (std.mem.eql(u8, opts.collection, "_superusers")) return ImportError.LegacySuperuserRefused;
        if (col.type != .auth) return ImportError.LegacyRequiresAuthCollection;
        // Fail on an unknown algorithm here rather than per row.
        if (!blk: {
            for (crypto.legacy_algorithms) |a| if (std.mem.eql(u8, a, alg)) break :blk true;
            break :blk false;
        }) return crypto.LegacyError.UnsupportedAlgorithm;
    }
```

In `importRow`, after the successful create (the `.created` branch only — an upsert
*update* has no create-time credential provisioning to complete), apply the credential:

```zig
/// Install an imported credential. Runs INSIDE the row's transaction, right after the
/// record is created, so the row and its credential commit or roll back together.
///
/// This is the ONLY writer of a `$zblegacy$` value anywhere in the codebase. The HTTP path
/// cannot reach it: `auth.isServerManagedField` strips `passwordHash`/`verified` from every
/// client payload, and that strip is unchanged.
fn applyLegacyCredential(
    w: *db.Db,
    a: std.mem.Allocator,
    col: schema.Collection,
    data: std.json.Value,
    algorithm: []const u8,
) !void {
    const idv = data.object.get("id") orelse return ImportError.LegacyRowMissingId;
    if (idv != .string or idv.string.len == 0) return ImportError.LegacyRowMissingId;
    if (data.object.get("password") != null and data.object.get("passwordHash") != null)
        return ImportError.LegacyHashConflict;

    var tagged: ?[]const u8 = null;
    if (data.object.get("passwordHash")) |hv| {
        if (hv != .string or hv.string.len == 0) return crypto.LegacyError.MalformedLegacyHash;
        // Validates the algorithm allowlist AND the hash format; a bad credential is
        // rejected while an operator is watching, not at some user's next login.
        tagged = try crypto.wrapLegacy(a, algorithm, hv.string);
    }
    var verified: ?bool = null;
    if (data.object.get("verified")) |vv| {
        if (vv == .bool) verified = vv.bool;
    }
    if (tagged == null and verified == null) return;

    // `col.name` came from `_collections` and passed `schema.isValidIdentifier` on creation;
    // re-check before interpolating, per the repo's identifier discipline.
    if (!schema.isValidIdentifier(col.name)) return ImportError.InvalidCollectionName;
    const sql = try std.fmt.allocPrintSentinel(a,
        "UPDATE \"{s}\" SET \"passwordHash\" = COALESCE(?2, \"passwordHash\"), \"verified\" = COALESCE(?3, \"verified\") WHERE \"id\" = ?1;",
        .{col.name}, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, idv.string);
    if (tagged) |t| try st.bindText(2, t) else try st.bindNull(2);
    if (verified) |v| try st.bindInt(3, if (v) 1 else 0) else try st.bindNull(3);
    _ = try st.step();
}
```

Call it from `importRow`'s create branch:

```zig
    if (opts.legacy_hash_algorithm) |alg| try applyLegacyCredential(w, a, col, data, alg);
```

Add `const crypto = @import("crypto.zig");` to `src/import.zig` if absent, and add
`crypto.LegacyError` to whatever error set `run` declares (or let it infer).

- [ ] **Step 4: CLI flag**

`src/cli.zig` — add to `ImportArgs`:
```zig
    /// Import source password hashes tagged with this algorithm (currently `bcrypt` only).
    legacy_hashes: ?[]const u8 = null,
```
the parse arm:
```zig
            } else if (std.mem.eql(u8, a, "--legacy-hashes")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ia.legacy_hashes = args[i];
```
and the test:
```zig
test "import --legacy-hashes parses and requires a value" {
    const cmd = try parse(&.{ "import", "--collection", "users", "--legacy-hashes", "bcrypt", "u.ndjson" }, .{});
    try std.testing.expectEqualStrings("bcrypt", cmd.import.legacy_hashes.?);
    try std.testing.expectError(ParseError.MissingValue, parse(&.{ "import", "--legacy-hashes" }, .{}));
}
```

`src/framework.zig` — forward it in **both** `run_opts` constructions (`importImpl` and
`importManifestImpl`): `.legacy_hash_algorithm = ia.legacy_hashes,`. Extend
`printImportUsage`:

```
  --legacy-hashes ALG  Import each row's `passwordHash` as a SOURCE hash produced by ALG
                     (currently: bcrypt) instead of ignoring it. The value is stored tagged
                     as $zblegacy$ALG$<hash> and is replaced with argon2id on the user's
                     first successful login. Requires an auth collection, refuses
                     _superusers, and requires every row to carry its own `id`. Under this
                     flag a row's `verified` flag is carried over too. A row carrying BOTH
                     `password` and `passwordHash` is refused.
```

- [ ] **Step 5: Run and commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/import.zig src/cli.zig src/framework.zig
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"
```
Expected: PASS — N up by 4.

```bash
git add src/import.zig src/cli.zig src/framework.zig
git commit -m "Import source password hashes behind an explicit --legacy-hashes flag

The only writer of a tagged legacy credential, and offline-only: the HTTP path
still strips passwordHash/verified from every client payload. Refuses a base
collection, refuses _superusers outright, validates the algorithm and the hash
format at import time rather than at some user's next login, and requires each
row's own id. Carries `verified` over so a cutover does not mail a
verification demand to the entire user base."
```

---

### Task 11: Transparent rehash to argon2id on successful login

**Files:**
- Modify: `src/api/auth.zig` (the shared helper + `authWithPassword`)
- Modify: `src/auth/methods/password.zig` (the auth-method login path)
- Modify: `src/api/records.zig` (the `oldPassword` verify on a password change)

**All three verify sites must be updated.** `authWithPassword` and
`PasswordMethod.completeImpl` are independent login paths — updating only one leaves
`/api/collections/:col/auth/password/complete` logins never upgrading. `records.zig`'s
`oldPassword` check must at minimum *accept* a legacy hash, or an imported user cannot
change their own password.

**Interfaces:**
- Produces in `src/api/auth.zig`:
```zig
/// Verify `password` against the stored value, and — when that value is a TAGGED legacy
/// hash and the verification SUCCEEDS — replace it with a fresh argon2id hash before
/// returning. Returns whether the password was correct; an upgrade failure is logged and
/// swallowed, because a transient write problem must never turn a valid login into a
/// rejected one.
///
/// The upgrade is the ONLY write on the login path and takes the writer for the duration of
/// a single UPDATE — never across the argon2 verify, which stays on the reader.
pub fn verifyPasswordUpgrading(
    app: *app_mod.App,
    alloc: std.mem.Allocator,
    table: []const u8,
    rid: []const u8,
    stored: []const u8,
    password: []const u8,
) bool;
```

- [ ] **Step 1: Write the failing tests**

Append to `src/api/auth.zig`'s tests:

```zig
test "verifyPasswordUpgrading verifies a legacy hash and rewrites it as argon2id" {
    const a = std.testing.allocator;
    var h = try testAppWithAuthCollection(a); // existing helper in this file's tests
    defer h.deinit();

    const bc = "$2b$04$LlIFuLM6RC2FI4t5B5wgVOmU/dqGb4L7VUnl1DHV3Q4jSJ0AVMHU2"; // "abc"
    const tagged = try crypto.wrapLegacy(a, "bcrypt", bc);
    defer a.free(tagged);
    try seedAuthRecord(&h, "users", "user00000000001", "ada@example.com", tagged);

    // Wrong password: no upgrade, no write.
    try std.testing.expect(!verifyPasswordUpgrading(&h.app, a, "users", "user00000000001", tagged, "wrong"));
    try std.testing.expectEqualStrings(tagged, (try readHash(a, &h, "users", "user00000000001")).?);

    // Right password: verified AND upgraded, in place.
    try std.testing.expect(verifyPasswordUpgrading(&h.app, a, "users", "user00000000001", tagged, "abc"));
    const after = (try readHash(a, &h, "users", "user00000000001")).?;
    defer a.free(after);
    try std.testing.expect(std.mem.startsWith(u8, after, "$argon2"));
    try std.testing.expect(!crypto.isLegacyHash(after));

    // The upgraded hash verifies the same password, and the legacy value is never restored.
    try std.testing.expect(verifyPasswordUpgrading(&h.app, a, "users", "user00000000001", after, "abc"));
    const twice = (try readHash(a, &h, "users", "user00000000001")).?;
    defer a.free(twice);
    try std.testing.expectEqualStrings(after, twice);
}

test "verifyPasswordUpgrading leaves an argon2 hash untouched" {
    const a = std.testing.allocator;
    var h = try testAppWithAuthCollection(a);
    defer h.deinit();
    const phc = try crypto.hashPassword(h.app.io, a, "hunter22");
    defer a.free(phc);
    try seedAuthRecord(&h, "users", "user00000000002", "grace@example.com", phc);

    try std.testing.expect(verifyPasswordUpgrading(&h.app, a, "users", "user00000000002", phc, "hunter22"));
    const after = (try readHash(a, &h, "users", "user00000000002")).?;
    defer a.free(after);
    try std.testing.expectEqualStrings(phc, after); // byte-identical: no pointless rehash
}
```

`testAppWithAuthCollection`, `seedAuthRecord` and `readHash` may not exist under those
names — reuse whatever `src/api/auth.zig`'s existing tests already use to stand up an app
with an auth collection and seed a row (`grep -n "^fn \|^test " src/api/auth.zig | head -40`).
Do not add a second harness.

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -20`
Expected: FAIL — `use of undeclared identifier 'verifyPasswordUpgrading'`.

- [ ] **Step 3: Implement the helper**

Add to `src/api/auth.zig`, next to `passwordHashFor`:

```zig
pub fn verifyPasswordUpgrading(
    app: *app_mod.App,
    alloc: std.mem.Allocator,
    table: []const u8,
    rid: []const u8,
    stored: []const u8,
    password: []const u8,
) bool {
    if (!crypto.isLegacyHash(stored)) return crypto.verifyPassword(app.io, alloc, stored, password);
    if (!crypto.verifyLegacy(stored, password)) return false;

    // Verified. Upgrade to argon2id — best effort: a failed write must never turn a valid
    // login into a rejected one, so every error below is logged and swallowed. The user
    // simply stays on the legacy hash until their next login.
    upgradeHash(app, alloc, table, rid, stored, password) catch |e|
        std.log.warn("legacy password upgrade failed for {s}/{s}: {s}", .{ table, rid, @errorName(e) });
    return true;
}

fn upgradeHash(
    app: *app_mod.App,
    alloc: std.mem.Allocator,
    table: []const u8,
    rid: []const u8,
    stored: []const u8,
    password: []const u8,
) !void {
    // Every collection name came from `_collections` and passed validation on creation;
    // re-check before interpolating, per the repo's identifier discipline.
    if (!schema.isValidIdentifier(table)) return error.InvalidIdentifier;
    const phc = try crypto.hashPassword(app.io, alloc, password);
    defer alloc.free(phc);
    const sql = try std.fmt.allocPrintSentinel(alloc,
        "UPDATE \"{s}\" SET \"passwordHash\" = ?1 WHERE \"id\" = ?2 AND \"passwordHash\" = ?3;",
        .{table}, 0);
    defer alloc.free(sql);

    // The writer is held for ONE statement — never across the (deliberately slow) verify
    // above, which ran on a pooled reader so it could not serialize all writes.
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, phc);
    try st.bindText(2, rid);
    // Guarding on the OLD value makes the upgrade idempotent under concurrency: two
    // simultaneous logins cannot both write, and a password change that landed in between
    // is not clobbered by this stale rehash.
    try st.bindText(3, stored);
    _ = try st.step();
}
```

- [ ] **Step 4: Route all three verify sites through it**

In `src/api/auth.zig`'s `authWithPassword`, replace

```zig
    if (!crypto.verifyPassword(app.io, ctx.allocator.a, phc, password))
```
with
```zig
    if (!verifyPasswordUpgrading(app, ctx.allocator.a, col.name, rid, phc, password))
```

In `src/auth/methods/password.zig`'s `completeImpl`, replace the
`crypto.verifyPassword(...)` call the same way, using `ac`'s app handle and the collection
name already in scope.

In `src/api/records.zig`'s `oldPassword` check, replace it the same way. (The record is
about to be rewritten with a fresh argon2 hash anyway, so the upgrade there is redundant —
but routing through one helper means a legacy hash is *accepted*, which is the part that
matters, and leaves exactly one verify implementation.)

**Adjust the writer-acquisition invariant test.** `src/api/auth.zig` carries a test pinning
"hook-free epoch mode performs zero writer acquisitions" on the login path. That remains
true for an argon2 hash and is now *false* for a legacy one. Do not delete the test — add a
legacy-specific carve-out: keep the existing assertion for the argon2 case and add a
sibling asserting **exactly one** writer acquisition for a legacy-hash login, which is the
property worth pinning (the upgrade must not accidentally become per-request).

- [ ] **Step 5: Run**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: PASS — N up by 2 (plus the carve-out test), with **every** pre-existing auth test
still green.

- [ ] **Step 6: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/api/auth.zig src/auth/methods/password.zig src/api/records.zig
git add src/api/auth.zig src/auth/methods/password.zig src/api/records.zig
git commit -m "Upgrade an imported credential to argon2id on first successful login

One helper behind all three password-verify sites, so the auth-method login
path and the oldPassword check cannot drift from the main one. The upgrade
runs only after a SUCCESSFUL verify, holds the writer for a single UPDATE
(never across the argon2 work, which stays on a reader), and guards on the old
value so concurrent logins cannot both write or clobber an interleaved
password change. A failed upgrade is logged and swallowed: a transient write
problem must never reject a valid login."
```

---

### Task 12: Legacy-credential end-to-end (import → login → upgraded)

The unit tests prove the pieces; only an e2e proves an imported user can actually log in to
a running server and that the stored credential really changed on disk. **No new fixture
binary is needed** — `fixtures/import/main.zig` already declares the auth collection
`members` with public rules.

**Files:**
- Create: `tests/admin/test_legacy_auth.py`

- [ ] **Step 1: Write the test**

Create `tests/admin/test_legacy_auth.py`:

```python
"""End-to-end: import a bcrypt credential, log in with it, and confirm the stored hash was
transparently upgraded to argon2id.

The bcrypt vector is generated at test time rather than hardcoded, so the test proves
interoperability with a REAL foreign implementation rather than with itself. Regenerate the
fallback with:
    python3 -c 'import bcrypt; print(bcrypt.hashpw(b"migrated-secret", bcrypt.gensalt(4, prefix=b"2a")).decode())'
"""
import json
import os
import pathlib
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]
FIELD_KEY = "an-operator-supplied-field-key-32b"
PASSWORD = "migrated-secret"

# A $2a$ (Go/PocketBase-style) bcrypt hash of PASSWORD at cost 4. Used when the `bcrypt`
# package is unavailable; the $2a$ version byte is the point — std only accepts $2b$, so a
# missing normalization fails here.
FALLBACK_2A = "$2a$04$eOxJ8v0pRz2p1mS0aVQ4wOa7SdT6y6Qw4hEqYVfFCk0m0hZ2sVQZK"


def bcrypt_hash():
    try:
        import bcrypt  # noqa: PLC0415
        return bcrypt.hashpw(PASSWORD.encode(), bcrypt.gensalt(4, prefix=b"2a")).decode()
    except ImportError:
        return FALLBACK_2A


@pytest.fixture(scope="session")
def import_binary():
    override = os.environ.get("ZIGBASE_TEST_IMPORT_BINARY")
    if override:
        if not pathlib.Path(override).exists():
            raise FileNotFoundError(f"ZIGBASE_TEST_IMPORT_BINARY={override} does not exist")
        return override
    subprocess.run(ZIG + ["build", "import-fixture"], cwd=REPO, check=True)
    return str(REPO / "zig-out" / "bin" / "import-fixture")


@pytest.fixture()
def data_dir():
    d = tempfile.mkdtemp(prefix="zb_legacy_auth_")
    yield d
    shutil.rmtree(d, ignore_errors=True)


def env(data):
    return {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_FIELD_KEY": FIELD_KEY}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def serve(binary, data):
    port = free_port()
    log_path = os.path.join(data, "serve.log")
    with open(log_path, "wb") as log:
        proc = subprocess.Popen([binary, "serve", "--insecure-cookies", "--http-port", str(port)],
                                env=env(data), stdout=log, stderr=subprocess.STDOUT)
    for _ in range(50):
        if proc.poll() is not None:
            break
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return proc, f"http://127.0.0.1:{port}"
        except OSError:
            time.sleep(0.1)
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait(timeout=5)
    pytest.fail(f"serve never became reachable:\n{pathlib.Path(log_path).read_text(errors='replace')}")


def login(base, identity, password):
    req = urllib.request.Request(
        f"{base}/api/collections/members/auth-with-password", method="POST",
        data=json.dumps({"identity": identity, "password": password}).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def stored_hash(data):
    con = sqlite3.connect(os.path.join(data, "data.db"))
    try:
        return con.execute('SELECT passwordHash FROM members WHERE id="member000000001"').fetchone()[0]
    finally:
        con.close()


def test_imported_bcrypt_user_logs_in_and_is_upgraded(import_binary, data_dir):
    src = bcrypt_hash()
    assert src.startswith("$2a$"), "the vector must be $2a$ — that is what this test exists to prove"

    nd = os.path.join(data_dir, "members.ndjson")
    pathlib.Path(nd).write_text(json.dumps({
        "id": "member000000001", "email": "ada@example.com", "name": "Ada",
        "passwordHash": src, "verified": True,
    }) + "\n")

    r = subprocess.run([import_binary, "import", "--collection", "members", "--data-dir", data_dir,
                        "--legacy-hashes", "bcrypt", "--json", nd],
                       env=env(data_dir), capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout)["created"] == 1

    # At rest: tagged, and the plaintext appears nowhere.
    before = stored_hash(data_dir)
    assert before == f"$zblegacy$bcrypt${src}"
    assert PASSWORD not in before

    proc, base = serve(import_binary, data_dir)
    try:
        # The wrong password must not upgrade anything.
        status, _ = login(base, "ada@example.com", "not-the-password")
        assert status == 400
        assert stored_hash(data_dir) == before

        status, body = login(base, "ada@example.com", PASSWORD)
        assert status == 200, body
        assert body["token"]

        after = stored_hash(data_dir)
        assert after.startswith("$argon2"), after
        assert not after.startswith("$zblegacy$")
        assert PASSWORD not in after

        # The upgraded credential still works, and nothing rewrites it back.
        status2, _ = login(base, "ada@example.com", PASSWORD)
        assert status2 == 200
        assert stored_hash(data_dir) == after
    finally:
        proc.terminate()
        proc.wait(timeout=5)
```

- [ ] **Step 2: Run**

```bash
mise exec zig@0.16.0 -- zig build import-fixture
ZIGBASE_TEST_IMPORT_BINARY=$PWD/zig-out/bin/import-fixture \
  mise exec python@3.13 -- python -m pytest tests/admin/test_legacy_auth.py -q
```
Expected: `1 passed`.

A failure at `status == 200` with the stored hash unchanged means the `$2a$` → `$2b$`
normalization from Task 9 is missing or is not reached from the login path. A failure at
`after.startswith("$argon2")` with a 200 login means `verifyPasswordUpgrading` verified but
the upgrade write did not land — check the `AND "passwordHash" = ?3` guard is comparing the
value actually read.

- [ ] **Step 3: Commit**

```bash
git add tests/admin/test_legacy_auth.py
git commit -m "Cover the imported-credential login end to end

Generates a real \$2a\$ bcrypt vector rather than asserting against our own
output, so the test proves interoperability with a foreign implementation.
Pins that a wrong password upgrades nothing, that a right one both
authenticates and rewrites the stored hash to argon2id, and that the legacy
value is never restored afterwards."
```

---

### Task 13: The parity-replay harness (`tools/replay/zb_replay.py`)

Recorded-replay is what makes "unattended migration" a claim rather than a demo. It runs
against the **old** backend to record expectations and the **new** one to verify them, so
it is a standalone stdlib-only tool, not a `zigbase` subcommand (decision D10).

**Files:**
- Create: `tools/replay/zb_replay.py`
- Create: `tools/replay/README.md`
- Create: `tests/tools/test_replay.py`
- Modify: `.github/workflows/ci.yml` (run `tests/tools` in the `browser` job)

**Interfaces — the capture format** (NDJSON, one case per line; decision D11):
```json
{"id":"posts-list","method":"GET","path":"/api/collections/posts/records",
 "query":{"perPage":"5","sort":"-created"},"headers":{"Authorization":"Bearer {{token}}"},
 "body":null,"expect":{"status":200,"bodySubset":{"items":[{"title":"Hello"}]}}}
```
| Key | Meaning |
|---|---|
| `id` | Stable, unique case identifier. Required. Findings key off it. |
| `method`, `path` | Required. `path` is appended to `--base-url`. |
| `query` | Object of string → string. Optional. |
| `headers` | Only the headers that matter. `{{name}}` placeholders resolve from `--var`. |
| `body` | JSON value or `null`. Sent as `application/json` when non-null. |
| `expect.status` | Exact match. |
| `expect.bodySubset` | Recursive **subset** of the response body (decision D12). |

**Interfaces — the CLI:**
```
zb_replay.py record --base-url URL --requests requests.ndjson --out capture.ndjson
                    [--var NAME=VALUE ...] [--volatile KEY ...]
zb_replay.py replay --base-url URL capture.ndjson [--out findings.ndjson]
                    [--var NAME=VALUE ...]
```
- `record` runs each request against the OLD backend and fills in `expect` from what came
  back, stripping volatile keys so ids and timestamps never become expectations.
- `replay` runs them against the NEW backend and diffs.
- **Findings** are NDJSON to `--out` (default `findings.ndjson`); the **summary** is one
  JSON object on stdout. They never share a channel.
```json
{"id":"posts-list","result":"fail","status":{"expected":200,"actual":404},
 "diff":[{"path":"items.0.title","expected":"Hello","actual":null}]}
```
```json
{"zigbaseReplay":1,"base_url":"http://localhost:8090","total":42,"passed":40,"failed":2,"errors":0,"findings":"findings.ndjson"}
```
- **Exit codes:** `0` all passed; `2` at least one case failed (the program-wide "ran
  correctly, found something needing judgment"); `1` tool error (unreadable capture,
  unreachable host).

Default volatile keys, stripped at record time: `id`, `created`, `updated`, `token`,
`collectionId`, `collectionName`, `expand`, plus anything passed with `--volatile`.

- [ ] **Step 1: Write the failing tests**

Create `tests/tools/test_replay.py`:

```python
"""Unit tests for the parity-replay harness. Pure functions only — no network."""
import importlib.util
import json
import pathlib

import pytest

SPEC = pathlib.Path(__file__).resolve().parents[2] / "tools" / "replay" / "zb_replay.py"
spec = importlib.util.spec_from_file_location("zb_replay", SPEC)
zr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zr)


def test_subset_matches_extra_keys_but_not_missing_or_different():
    assert zr.diff_subset({"a": 1}, {"a": 1, "b": 2}) == []
    assert zr.diff_subset({}, {"a": 1}) == []
    assert zr.diff_subset({"a": 1}, {"a": 2}) == [{"path": "a", "expected": 1, "actual": 2}]
    assert zr.diff_subset({"a": 1}, {"b": 1}) == [{"path": "a", "expected": 1, "actual": None}]


def test_subset_recurses_into_objects_and_arrays():
    exp = {"items": [{"title": "x"}, {"title": "y"}]}
    assert zr.diff_subset(exp, {"items": [{"title": "x", "id": "1"}, {"title": "y", "id": "2"}]}) == []
    d = zr.diff_subset(exp, {"items": [{"title": "x"}, {"title": "ZZ"}]})
    assert d == [{"path": "items.1.title", "expected": "y", "actual": "ZZ"}]


def test_a_shorter_actual_array_is_a_failure_but_a_longer_one_is_not():
    assert zr.diff_subset({"i": [1, 2]}, {"i": [1, 2, 3]}) == []
    d = zr.diff_subset({"i": [1, 2]}, {"i": [1]})
    assert d == [{"path": "i.1", "expected": 2, "actual": None}]


def test_volatile_keys_are_stripped_recursively():
    got = zr.strip_volatile(
        {"id": "x", "title": "t", "items": [{"id": "y", "created": "now", "n": 1}]},
        zr.DEFAULT_VOLATILE,
    )
    assert got == {"title": "t", "items": [{"n": 1}]}


def test_placeholders_resolve_from_vars_and_an_unknown_one_raises():
    assert zr.substitute("Bearer {{token}}", {"token": "abc"}) == "Bearer abc"
    assert zr.substitute({"h": "{{a}}/{{b}}"}, {"a": "1", "b": "2"}) == {"h": "1/2"}
    with pytest.raises(zr.ReplayError):
        zr.substitute("{{missing}}", {})


def test_parse_capture_rejects_a_case_without_an_id_or_with_a_duplicate(tmp_path):
    p = tmp_path / "c.ndjson"
    p.write_text(json.dumps({"method": "GET", "path": "/x"}) + "\n")
    with pytest.raises(zr.ReplayError):
        zr.load_capture(str(p))
    p.write_text("\n".join([
        json.dumps({"id": "a", "method": "GET", "path": "/x"}),
        json.dumps({"id": "a", "method": "GET", "path": "/y"}),
    ]) + "\n")
    with pytest.raises(zr.ReplayError):
        zr.load_capture(str(p))


def test_compare_builds_a_finding_with_status_and_body_differences():
    case = {"id": "c1", "expect": {"status": 200, "bodySubset": {"a": 1}}}
    ok = zr.compare(case, 200, {"a": 1, "b": 9})
    assert ok["result"] == "pass" and ok["diff"] == []
    bad = zr.compare(case, 404, {"a": 2})
    assert bad["result"] == "fail"
    assert bad["status"] == {"expected": 200, "actual": 404}
    assert bad["diff"] == [{"path": "a", "expected": 1, "actual": 2}]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec python@3.13 -- python -m pytest tests/tools/test_replay.py -q`
Expected: FAIL — the module file does not exist.

- [ ] **Step 3: Write the tool**

Create `tools/replay/zb_replay.py` (stdlib only — `urllib`, `json`, `argparse`; no
`requests`/`httpx`, so it runs anywhere Python 3 does):

```python
#!/usr/bin/env python3
"""Parity-replay harness for ZigBase migrations.

Record a backend's HTTP behaviour, replay it against its replacement, diff the results.
Deliberately source-agnostic: `record` never assumes the old backend is ZigBase, which is
the whole point — you record PocketBase/Rails/Express and replay ZigBase.

Comparison is a recursive SUBSET match, not equality: every key in the expectation must be
present and equal in the response, extra keys are fine, and volatile keys (ids, timestamps,
tokens) are stripped when recording so they never become expectations. A tool that fails on
every generated id gets ignored, and an ignored parity check makes the migration claim
dishonest.
"""
import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

CAPTURE_VERSION = 1
DEFAULT_VOLATILE = ["id", "created", "updated", "token", "collectionId", "collectionName", "expand"]


class ReplayError(Exception):
    """A tool-level problem: a malformed capture, an unresolvable placeholder, a dead host."""


def substitute(value, variables):
    """Resolve {{name}} placeholders in strings, recursively through dicts and lists."""
    if isinstance(value, str):
        out = value
        while "{{" in out:
            start = out.index("{{")
            end = out.find("}}", start)
            if end < 0:
                break
            name = out[start + 2:end]
            if name not in variables:
                raise ReplayError(f"unresolved placeholder {{{{{name}}}}} — pass --var {name}=VALUE")
            out = out[:start] + variables[name] + out[end + 2:]
        return out
    if isinstance(value, dict):
        return {k: substitute(v, variables) for k, v in value.items()}
    if isinstance(value, list):
        return [substitute(v, variables) for v in value]
    return value


def strip_volatile(value, keys):
    """Remove volatile keys everywhere in a JSON value, so they never become expectations."""
    if isinstance(value, dict):
        return {k: strip_volatile(v, keys) for k, v in value.items() if k not in keys}
    if isinstance(value, list):
        return [strip_volatile(v, keys) for v in value]
    return value


def diff_subset(expected, actual, path=""):
    """Every key in `expected` must be present and equal in `actual`. Extra keys are fine;
    arrays compare element-wise up to the expectation's length."""
    out = []
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [{"path": path or ".", "expected": expected, "actual": actual}]
        for k, v in expected.items():
            sub = f"{path}.{k}" if path else k
            out.extend(diff_subset(v, actual.get(k), sub))
        return out
    if isinstance(expected, list):
        if not isinstance(actual, list):
            return [{"path": path or ".", "expected": expected, "actual": actual}]
        for i, v in enumerate(expected):
            sub = f"{path}.{i}" if path else str(i)
            out.extend(diff_subset(v, actual[i] if i < len(actual) else None, sub))
        return out
    if expected != actual:
        out.append({"path": path or ".", "expected": expected, "actual": actual})
    return out


def load_capture(path):
    """Read an NDJSON capture. Ids must be present and unique — findings key off them."""
    cases, seen = [], set()
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        raise ReplayError(f"cannot read {path}: {e}") from e
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            case = json.loads(line)
        except json.JSONDecodeError as e:
            raise ReplayError(f"{path}:{n}: not JSON: {e}") from e
        cid = case.get("id")
        if not cid:
            raise ReplayError(f"{path}:{n}: every case needs a unique \"id\"")
        if cid in seen:
            raise ReplayError(f"{path}:{n}: duplicate case id {cid!r}")
        if not case.get("method") or not case.get("path"):
            raise ReplayError(f"{path}:{n}: case {cid!r} needs \"method\" and \"path\"")
        seen.add(cid)
        cases.append(case)
    return cases


def send(base_url, case, variables, timeout):
    """Issue one case. Returns (status, parsed-body-or-raw-text)."""
    case = substitute(case, variables)
    url = base_url.rstrip("/") + case["path"]
    if case.get("query"):
        url += "?" + urllib.parse.urlencode(case["query"])
    data = None
    headers = dict(case.get("headers") or {})
    if case.get("body") is not None:
        data = json.dumps(case["body"]).encode()
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, method=case["method"], data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw, status = r.read().decode(errors="replace"), r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read().decode(errors="replace"), e.code
    except OSError as e:
        raise ReplayError(f"{case['id']}: {url}: {e}") from e
    try:
        return status, json.loads(raw) if raw else None
    except json.JSONDecodeError:
        return status, raw


def compare(case, status, body):
    expect = case.get("expect") or {}
    finding = {"id": case["id"], "result": "pass", "diff": []}
    if expect.get("status") is not None and expect["status"] != status:
        finding["status"] = {"expected": expect["status"], "actual": status}
        finding["result"] = "fail"
    if expect.get("bodySubset") is not None:
        d = diff_subset(expect["bodySubset"], body)
        if d:
            finding["diff"] = d
            finding["result"] = "fail"
    return finding


def parse_vars(pairs):
    out = {}
    for p in pairs or []:
        if "=" not in p:
            raise ReplayError(f"--var expects NAME=VALUE, got {p!r}")
        k, v = p.split("=", 1)
        out[k] = v
    return out


def cmd_record(args):
    variables = parse_vars(args.var)
    volatile = DEFAULT_VOLATILE + (args.volatile or [])
    cases = load_capture(args.requests)
    with open(args.out, "w", encoding="utf-8") as out:
        for case in cases:
            status, body = send(args.base_url, case, variables, args.timeout)
            case["expect"] = {"status": status, "bodySubset": strip_volatile(body, volatile)}
            out.write(json.dumps(case) + "\n")
    summary = {"zigbaseReplay": CAPTURE_VERSION, "mode": "record", "base_url": args.base_url,
               "recorded": len(cases), "capture": args.out}
    print(json.dumps(summary))
    return 0


def cmd_replay(args):
    variables = parse_vars(args.var)
    cases = load_capture(args.capture)
    passed = failed = errors = 0
    with open(args.out, "w", encoding="utf-8") as out:
        for case in cases:
            try:
                status, body = send(args.base_url, case, variables, args.timeout)
            except ReplayError as e:
                errors += 1
                out.write(json.dumps({"id": case["id"], "result": "error", "message": str(e)}) + "\n")
                continue
            finding = compare(case, status, body)
            if finding["result"] == "pass":
                passed += 1
            else:
                failed += 1
            out.write(json.dumps(finding) + "\n")
    summary = {"zigbaseReplay": CAPTURE_VERSION, "mode": "replay", "base_url": args.base_url,
               "total": len(cases), "passed": passed, "failed": failed, "errors": errors,
               "findings": args.out}
    print(json.dumps(summary))
    # 2 = ran correctly, found something needing judgment. 1 is reserved for tool failure.
    return 2 if (failed or errors) else 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="zb_replay.py", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    rec = sub.add_parser("record", help="run requests against the OLD backend and record expectations")
    rec.add_argument("--base-url", required=True)
    rec.add_argument("--requests", required=True)
    rec.add_argument("--out", default="capture.ndjson")
    rec.add_argument("--var", action="append")
    rec.add_argument("--volatile", action="append")
    rec.add_argument("--timeout", type=float, default=30.0)
    rec.set_defaults(fn=cmd_record)

    rep = sub.add_parser("replay", help="replay a capture against the NEW backend and diff")
    rep.add_argument("capture")
    rep.add_argument("--base-url", required=True)
    rep.add_argument("--out", default="findings.ndjson")
    rep.add_argument("--var", action="append")
    rep.add_argument("--timeout", type=float, default=30.0)
    rep.set_defaults(fn=cmd_replay)

    args = p.parse_args(argv)
    try:
        return args.fn(args)
    except ReplayError as e:
        print(f"zb_replay: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Write the tool README**

Create `tools/replay/README.md` with: the two commands, the capture-line schema table above,
the subset-matching rule, the volatile-key list, the exit codes, and a worked
record-then-replay example. Keep it short and point at `docs/migration-tools.md` for the
migration workflow context.

- [ ] **Step 5: Run the tests**

```bash
mise exec python@3.13 -- python -m pytest tests/tools/test_replay.py -q
```
Expected: `7 passed`.

- [ ] **Step 6: Prove it end-to-end against a live server by hand**

```bash
mise exec zig@0.16.0 -- zig build
rm -rf /tmp/zbrep && ./zig-out/bin/zigbase superuser create --email a@b.c --password adminpassword --data-dir /tmp/zbrep
./zig-out/bin/zigbase serve --insecure-cookies --http-port 8099 --data-dir /tmp/zbrep &
sleep 2
printf '{"id":"health","method":"GET","path":"/api/health"}\n' > /tmp/zbrep/reqs.ndjson
python3 tools/replay/zb_replay.py record --base-url http://127.0.0.1:8099 \
    --requests /tmp/zbrep/reqs.ndjson --out /tmp/zbrep/cap.ndjson
python3 tools/replay/zb_replay.py replay /tmp/zbrep/cap.ndjson \
    --base-url http://127.0.0.1:8099 --out /tmp/zbrep/find.ndjson; echo "exit=$?"
python3 tools/replay/zb_replay.py replay /tmp/zbrep/cap.ndjson \
    --base-url http://127.0.0.1:8099/nope --out /tmp/zbrep/find2.ndjson; echo "exit=$?"
kill %1
```
Expected: the self-replay reports `"failed":0` with `exit=0`; the wrong-base-URL replay
reports a failure with `exit=2`. Confirm the findings file is NDJSON and the summary is a
single JSON object on stdout.

- [ ] **Step 7: Wire it into CI**

In `.github/workflows/ci.yml`'s `browser` job, after the `tests/admin` step:

```yaml
      - name: Replay-harness unit tests
        run: mise exec python@3.13 -- python -m pytest tests/tools -q
```

- [ ] **Step 8: Commit**

```bash
git add tools/replay/zb_replay.py tools/replay/README.md tests/tools/test_replay.py .github/workflows/ci.yml
git commit -m "Add the parity-replay harness

A standalone stdlib-only tool rather than a zigbase subcommand: it has to run
against the OLD backend to record expectations, and baking an arbitrary-URL
HTTP client into every production binary is the wrong trade. Matching is a
recursive subset with volatile keys stripped at record time — equality
matching would fail on every generated id, and a parity check nobody trusts
makes the unattended-migration claim dishonest. Exit 2 on parity failures,
1 only for tool errors."
```

---

### Task 14: Documentation, site registry, README, changelog fragments

Docs sync is mandatory here (CLAUDE.md, `.github/pull_request_template.md`), and this
change adds two CLI commands, seven flags, three document formats and a new tool — none of
which is discoverable without it.

**Files:**
- Create: `docs/migration-tools.md`
- Modify: `site/scripts/docs-registry.json`, `site/scripts/gen-docs-mirror.mjs` (`PUBLISHED`), `site/.gitignore`, `site/src/config/sidebar.ts` (the four-edit publish rule), `README.md`, `KNOWN_LIMITATIONS.md`
- Create: `changelog.d/schema-declarative.md`, `changelog.d/import-scale.md`,
  `changelog.d/legacy-password-import.md`, `changelog.d/parity-replay.md`

- [ ] **Step 1: Write `docs/migration-tools.md`**

Required sections, in order:

1. **What this is** — the four surfaces and the migration skeleton they serve
   (inventory → schema transplant → data pump → auth migration → endpoint parity map →
   replay verification → cutover), naming which stage each tool covers and which stages are
   the skill's judgment work.
2. **Declarative schema** — the document format with a complete annotated example; the
   rules that `dump` applies (non-system collections only, system fields omitted, collection
   ids omitted, relation targets by name, OAuth secrets redacted, name-sorted); the `apply`
   semantics (matched by name, fields by stable id, scoped to named collections,
   `untracked` vs `--prune`, two-pass relation cycles, refused under `.collections_frozen`,
   non-atomic across collections); the exit-code table; and the round-trip guarantee.
   **State plainly that the document is not a secrets backup.**
3. **Data pump** — the NDJSON row shape, id preservation and why (D8), the manifest format,
   ordering and deferred relations (and the "deferred rows must carry an `id`" requirement),
   `--dry-run`, `--continue-on-error` + the findings NDJSON, `--progress`, `--json`, and the
   exit-code table including **3 = completed but skipped rows**.
4. **Legacy password import** — the workflow, the `$zblegacy$<alg>$<hash>` format, the
   `bcrypt` allowlist, `$2a`/`$2b`/`$2y` accepted and **`$2x` refused with the reason**, the
   72-byte truncation behaviour, `verified` carry-over, and the upgrade-on-login mechanic.
   Then a **Security constraints** subsection reproducing all six constraints from this
   plan's Global Constraints **verbatim**, including the accepted timing residual. Add the
   operator query for progress:
   `SELECT count(*) FROM users WHERE passwordHash LIKE '$zblegacy$%'`.
5. **Parity replay** — capture format table, subset-matching rule, volatile keys, the two
   commands, findings/summary channels, exit codes, and a worked
   record-old → replay-new example.
6. **Worked end-to-end migration** — a single copy-pasteable sequence:
   `schema apply --dry-run` → `schema apply` → `import --manifest --dry-run` →
   `import --manifest` → `import --legacy-hashes bcrypt` → `zb_replay.py replay` →
   `schema dump` (to commit the resulting schema).
7. **Limitations** — the list in "Out of scope and follow-ups" below, so a reader is not
   surprised by them mid-migration.

- [ ] **Step 2: Register the doc in the site**

Add to `site/scripts/docs-registry.json`, keeping the file's existing ordering style:

```json
  {
    "canonical": "docs/migration-tools.md",
    "mirror": "migration-tools.md",
    "frontmatter": {
      "title": "Migration tools",
      "description": "Declarative schema dump/apply, scaled NDJSON import with relation ordering, legacy password-hash import with rehash-on-login, and the parity-replay harness.",
      "order": 3,
      "group": "guides"
    }
  },
```
`guides` order 3 is currently vacant (recipes 1, framework 2, typescript-sdk 4), so no other
entry needs renumbering. **Never hand-edit `site/src/content/docs/migration-tools.md`** —
it is generated.

Build the site to confirm the mirror generates:
```bash
cd site && npm install --no-audit --no-fund && npm run build
```
Expected: a successful build with `site/src/content/docs/migration-tools.md` present
afterwards (and gitignored).

- [ ] **Step 3: Update `README.md`**

In the `## CLI` fenced block, add after the `migrate-db` line:
```
zigbase schema [dump [--json] [--out FILE] | apply FILE [--dry-run] [--allow-destructive] [--prune]] [--data-dir PATH]
```
and replace the `import` line with:
```
zigbase import [--collection NAME [--upsert-key FIELD] <file.ndjson> | --manifest FILE]
               [--legacy-hashes ALG] [--dry-run] [--continue-on-error] [--error-log FILE]
               [--progress N] [--batch-size N] [--json] [--data-dir PATH]
```
In the prose list of `runCli` commands (currently "`migrate-db`, `import`,
`superuser create`, `rewrap`, `vapid-keygen`, `version`, and `help`"), insert `schema`
after `import`. Add a short paragraph after the existing `import` paragraph:

> `schema` is the declarative half: `schema dump` writes the canonical JSON collection
> model and `schema apply` executes the difference between a document and the live schema
> through the same path the REST collections API uses. Together with `import --manifest`
> and `import --legacy-hashes` they are the machinery behind
> [docs/migration-tools.md](docs/migration-tools.md).

**No README env-var table row is added** — this plan introduces no `ZIGBASE_*` variable, so
`tests/admin/test_docs_parity.py` needs nothing.

- [ ] **Step 4: Record the limitations**

Add to `KNOWN_LIMITATIONS.md`, under the schema/migrations section:

- `schema apply` is not atomic across collections (each `collections.create`/`update` opens
  its own transaction); the emitted `applied` list names what landed before a failure.
- `schema apply` does not validate access-rule **expression syntax** — neither does the REST
  API; a malformed rule fails closed at evaluation time (500). Exercise every rule once via
  the replay harness before cutover.
- Collection **rename** is not supported by the engine (`collections.update` preserves the
  stored name), so a renamed collection in a document reads as create + untracked.
- Deferred relation values (cycles, self-relations) require the source row to carry its own
  `id`.

- [ ] **Step 5: Write the changelog fragments**

`changelog.d/schema-declarative.md`:
```markdown
### Features
- `zigbase schema dump [--json] [--out FILE]` writes a canonical, deterministic JSON document of every non-system collection — fields with their stable ids, indexes, access rules and options — that diffs cleanly in git. OAuth client secrets are redacted, so it is not a secrets backup.
- `zigbase schema apply FILE [--dry-run] [--allow-destructive] [--prune]` executes the difference between a document and the live schema through the same validation and DDL path as the REST collections API. `dump` → `apply` is a no-op. Destructive changes (drops, retypes) are refused without `--allow-destructive`; `--dry-run` exits 2 when it finds them. Collections absent from the document are left alone unless `--prune`. Refused under `.collections_frozen`.
```

`changelog.d/import-scale.md`:
```markdown
### Features
- `zigbase import --manifest FILE` loads several collections in relation-dependency order from one manifest, deferring and then patching the relation values that cannot be ordered (cross-collection cycles and self-relations).
- `zigbase import` gains `--dry-run` (execute then roll back), `--continue-on-error` with `--error-log FILE` (NDJSON findings; per-row SAVEPOINT isolation so one bad row cannot abort a long import), `--progress N`, and `--json` for a machine-readable summary.

### Changed
- An import that skipped rows under `--continue-on-error` now exits **3**, not 0 — a lossy import is never reported as success.
```

`changelog.d/legacy-password-import.md`:
```markdown
### Features
- `zigbase import --legacy-hashes bcrypt` imports users with their existing bcrypt password hashes, stored tagged as `$zblegacy$bcrypt$<hash>`. On the user's first successful login the credential is verified against the source hash and transparently rewritten as argon2id. `$2a$`, `$2b$` and `$2y$` hashes are accepted (`$2x$` is refused — its deliberately-buggy 8-bit handling is not reproduced here). Requires an auth collection, refuses `_superusers`, and carries each row's `verified` flag over so a cutover does not mail a verification demand to the whole user base.

### Security
- Legacy credentials are only ever installable through the offline CLI import: the HTTP path continues to strip `passwordHash` and `verified` from every client payload, so no request can install one. The algorithm allowlist is matched against the explicit tag, never inferred from a hash's own prefix, so an untagged foreign hash matches no verifier and fails closed. Nothing ever writes a legacy hash back after an upgrade.
```

`changelog.d/parity-replay.md`:
```markdown
### Features
- Added `tools/replay/zb_replay.py`, a dependency-free parity-replay harness: record a backend's HTTP behaviour, replay it against its replacement, and diff. Matching is a recursive subset with volatile keys (ids, timestamps, tokens) stripped at record time. Findings are NDJSON, the summary is one JSON object on stdout, and a parity failure exits 2.

### Internal
- New end-to-end suites `tests/admin/test_schema_cli.py`, `tests/admin/test_import_manifest.py`, `tests/admin/test_legacy_auth.py` and `tests/tools/test_replay.py`; `tests/tools` runs in the `browser` CI job.
```

- [ ] **Step 6: Commit**

```bash
git add docs/migration-tools.md site/scripts/docs-registry.json README.md KNOWN_LIMITATIONS.md changelog.d/
git commit -m "Document the migration machinery

New canonical docs/migration-tools.md registered in the site docs registry,
plus the README CLI block, the known limitations this machinery genuinely has,
and the changelog fragments. No new env var, so the docs-parity guard is
unaffected."
```

---

### Task 15: Full verification

- [ ] **Step 1: Formatting and the full Zig suite**

```bash
mise exec zig@0.16.0 -- zig fmt --check src/ build.zig
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -5
```
Expected: `zig fmt --check` prints nothing; the summary line reads
`Build Summary: N/N tests passed` with **0 failed**. Ignore any `failed command: …` line —
the summary is authoritative.

- [ ] **Step 2: Build everything CI builds**

```bash
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build import-fixture
mise exec zig@0.16.0 -- zig build dating-server
mise exec zig@0.16.0 -- zig build auth2-server
mise exec zig@0.16.0 -- zig build features-fixture
mise exec zig@0.16.0 -- zig build minimal-server
mise exec zig@0.16.0 -- zig build full-fixture
for e in blog golfsim plugins; do
  ( cd examples/$e && mise exec zig@0.16.0 -- zig build ) || echo "FAILED: $e"
done
```
Expected: every build succeeds. (`examples/plugins` needs its frontend built first —
`cd examples/plugins/frontend && npm install && npm run build` — if `frontend/dist` is
absent.)

- [ ] **Step 3: The gating and allocator ratchets**

```bash
./scripts/check-gating.sh
./scripts/check-allocator-contracts.sh
```
Expected: both pass. If the allocator ratchet reports new masked tests, fix the ownership
rather than extending `scripts/allocator-allowlist.txt`.

- [ ] **Step 4: The whole browser suite in parallel**

```bash
mise exec python@3.13 -- python -m pytest tests/admin -q -n auto
mise exec python@3.13 -- python -m pytest tests/tools -q
mise exec python@3.13 -- python -m pytest tests/smtp -q
```
Expected: all pass. `tests/admin/test_docs_parity.py` in particular must be green.
A green `zig build test` does **not** imply this — run it.

- [ ] **Step 5: Re-verify the four headline behaviours by hand**

```bash
# 1. schema round trip is a no-op
rm -rf /tmp/zbv && ./zig-out/bin/zigbase migrate --data-dir /tmp/zbv
./zig-out/bin/zigbase schema dump --data-dir /tmp/zbv 2>/dev/null > /tmp/zbv/s.json
./zig-out/bin/zigbase schema apply /tmp/zbv/s.json --dry-run --data-dir /tmp/zbv \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["changes"]==[], d; print("round-trip OK")'

# 2. a lossy import exits 3
export ZIGBASE_FIELD_KEY=an-operator-supplied-field-key-32b
rm -rf /tmp/zbv2 && mkdir -p /tmp/zbv2
printf '{"code":"A"}\nnot json\n' > /tmp/zbv2/in.ndjson
./zig-out/bin/import-fixture import --collection vault --data-dir /tmp/zbv2 \
  --continue-on-error --json /tmp/zbv2/in.ndjson; test $? -eq 3 && echo "exit-3 OK"

# 3. an untagged bcrypt hash never authenticates (fails closed)
#    covered by the crypto unit test; confirm it ran:
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -c "Build Summary"

# 4. replay exits 2 on a parity failure
python3 tools/replay/zb_replay.py replay /dev/null --base-url http://127.0.0.1:1 \
  --out /tmp/zbv-find.ndjson; echo "empty capture exit=$? (expect 0)"
```

- [ ] **Step 6: Prepare the branch and open the PR**

Run the `tell-a-git-story` skill over the branch before publishing — this is a large,
multi-concern change and the commit sequence above is deliberately one concern per commit;
confirm it still reads that way after any fixups.

Then open the PR, complete the sync checklist in
`.github/pull_request_template.md`, and **explicitly request a security review of the
legacy-hash work** (program design §10 calls for one). Monitor it with the `pr-monitor`
skill until merged.

---

## PocketBase sufficiency checklist

The PocketBase migration skill is a named follow-up, not part of this plan. This section is
the proof that the machinery above is **sufficient** for it: every skeleton stage maps to a
tool this plan builds or a feature that already exists.

| Skeleton stage | Covered by | Status |
|---|---|---|
| **Inventory source** | The skill reads `pb_schema.json` + `pb_data/data.db` and emits this plan's two documents. The *target* formats — `{"zigbaseSchema":1,…}` (Task 1) and `{"zigbaseImportManifest":1,…}` (Task 7) — are frozen here, so the converter has a fixed contract to write against. | **Follow-up** (converter), contract frozen here |
| **Schema transplant** | `zigbase schema apply --dry-run` then `schema apply` (Tasks 2, 4) | **This plan** |
| **Data pump** | `zigbase import --manifest` with relation ordering + deferred cycles/self-relations (Tasks 6–8) | **This plan** |
| **Auth / user migration** | `zigbase import --legacy-hashes bcrypt` + rehash-on-login (Tasks 9–11) | **This plan** |
| **Endpoint parity map** | Judgment work: the skill maps PocketBase routes onto ZigBase collections/rules/custom routes | **Skill** (by design — §5 of the program design) |
| **Replay verification** | `tools/replay/zb_replay.py record` against PocketBase, `replay` against ZigBase (Task 13) | **This plan** |
| **Cutover checklist** | SP-3's `zigbase doctor --production`, plus `schema apply --dry-run` returning no changes as the "schema is settled" gate | **SP-3 + this plan** |

**Representability — can the machinery express a PocketBase app faithfully?**

- **Field types.** PocketBase's types (`text`, `number`, `bool`, `email`, `url`, `editor`,
  `date`, `select`, `json`, `file`, `relation`, `autodate`) map **1:1** onto
  `schema.FieldType`, which has exactly the same twelve variants. No type is unrepresentable.
- **Record ids.** PocketBase ids are 15-character lowercase alphanumerics — the **same
  shape** `id.collectionId` generates, and comfortably inside
  `records.isPlausibleRecordId`'s bounds. Preserving them (D8) is therefore safe and makes
  every cross-reference survive untouched.
- **Relation values.** PocketBase stores a single relation as a bare id and a multi relation
  as a JSON array of ids — byte-for-byte what `values.zig` writes for ZigBase relations. No
  transformation is needed on the data pump.
- **Passwords.** PocketBase hashes with Go's `golang.org/x/crypto/bcrypt`, which emits
  `$2a$`. Task 9's version normalization is what makes those hashes verify at all; without
  it, every imported PocketBase user would be locked out. This is the single most important
  detail in the whole plan.
- **System collections.** PocketBase's `_pb_users_auth_` and internal tables are excluded by
  the same rule that excludes ZigBase's own system collections (D4).
- **Access rules.** Both sides are expression strings, but the **grammars differ** —
  translating them is skill work, not machinery. The machinery's obligation is only to carry
  rule strings verbatim (it does) and to surface a rejected collection loudly (it does, via
  `collections.last_errors`). See the rule-syntax limitation below.

**What the skill still needs that is not here:** the `pb_schema.json` → schema-document
converter, the `pb_data` → NDJSON extractor, the rule-expression translation table, and the
eval scenario. All are named follow-ups gated on SP-4's skill infrastructure.

---

## Out of scope and follow-ups

- **The PocketBase SKILL, the `pb_schema.json` converter, and eval scenario 2** — the named
  follow-up this plan exists to enable, gated on SP-4.
- **Access-rule expression validation at apply time.** `schema apply` does not parse rule
  expressions, and neither does the REST API — `rules.compileGuard` needs a live connection
  *and* a request context, so a static check is a design question, not a line of code. A
  bad rule fails **closed** (500) at evaluation time. Mitigation available today: the
  replay harness exercises every rule cheaply, and the docs tell you to. A
  `zigbase schema check-rules` validator is the right follow-up.
- **Collection rename.** The engine does not support it (`collections.update` preserves the
  stored name); a rename reads as create + untracked. Fixing it is an engine change with its
  own data-migration semantics, not a schema-document concern.
- **Additional legacy hash algorithms** (scrypt, PBKDF2, Django's `pbkdf2_sha256`, Rails'
  bcrypt-with-pepper). The allowlist is deliberately one entry; each addition needs its own
  security review. Rails and Laravel both use bcrypt, so `bcrypt` already covers the next
  two sources on the roadmap.
- **A REST seam for legacy hashes.** Deliberately absent (Global Constraint 4).
- **HAR import for the replay harness** — a converter, not a redesign.
- **OpenAPI export** — listed in the program design's contracts lane under SP-5 but split
  out: it serves ecosystem tooling and parity *documentation*, shares no code with anything
  here, and the design doc itself flags its fidelity as needing careful scoping (§10). It
  gets its own spec.
- **`doctor` check for remaining legacy hashes** — SP-3 owns `doctor`; this plan only
  guarantees the value is countable with one `LIKE '$zblegacy$%'` query.

---

## Self-review

Performed against the task brief before publication; findings folded into the text above.

**Scope coverage.** All four brief items are covered: declarative schema (Tasks 1–5),
scaled import + relation resolution (Tasks 6–8), legacy-password-hash import (Tasks 9–12),
parity replay (Task 13). The requested decisions are all made and justified: document
format (D1–D5), id preservation (D8, with the mapping-table alternative rejected on
stated grounds), hash storage format plus the bcrypt availability finding (D9 + Task 9 —
`std.crypto.pwhash.bcrypt` exists in Zig 0.16.0, **no new C dependency**), and the replay
tool's shape (D10–D12). The PocketBase sufficiency checklist is present and stage-by-stage.
All six security constraints appear in Global Constraints and are re-stated in Task 9 and
in the docs task.

**Placeholder scan.** No `TODO`, no "similar to Task N", no elided function body. Three
places deliberately instruct the implementer to *check an existing idiom before copying*
rather than inventing one (the `std.Io` value passed to `collections.create`; the comptime
relation-field key in the fixtures; the auth-test harness helper names). These are named
`grep` commands with an explicit "do not invent a new one", not placeholders — the
alternative would be specifying an identifier I could not verify, which is worse.

**Signature consistency.** Every type referenced across tasks is defined in one:
`schema_doc.{doc_version, DocError, dump, parse, freeCollections}` (Task 1);
`schema_diff.{ChangeKind, isDestructive, Change, Deferred, Plan, Options, compute,
withoutFields, orderWithCycles, indexByName}` (Tasks 3, 7); `cli.{SchemaAction, SchemaArgs}`
(Task 2) and the `ImportArgs` additions (Tasks 6, 8, 10); `import.{Options, Report,
ImportError, App, testApp, run}` (Tasks 6, 7, 10); `import_manifest.{manifest_version,
Entry, Manifest, ManifestError, parseManifest, deferralSet, loadOrder, EntryReport, Report,
RunOptions, run}` (Task 7); `crypto.{legacy_prefix, legacy_algorithms, LegacyError,
LegacyHash, isLegacyHash, parseLegacy, wrapLegacy, verifyLegacy}` (Task 9);
`api/collections.{mergeOAuthConfig, prepareOAuthConfig, OAuthPrepError}` (Task 4);
`api/auth.verifyPasswordUpgrading` (Task 11); `zb_replay.{diff_subset, strip_volatile,
substitute, load_capture, compare, ReplayError, DEFAULT_VOLATILE}` (Task 13).

**Corrections made during review, worth flagging to the implementer:**
1. `provision.topoOrder` was going to be promoted to `pub` and reused. It silently skips
   cycle edges without reporting them, and both the DDL and data pumps need exactly that
   list — so the ordering lives in `schema_diff.orderWithCycles` and `provision.zig` /
   `dumpload.zig` / `collections.zig` are untouched. The File Structure table reflects this.
2. Two new fixture binaries were planned; neither is needed. `schema` tests use the stock
   binary, and the manifest and legacy tests extend `fixtures/import`. `build.zig` and the
   CI artifact list stay untouched.
3. `prepareOAuthConfig` takes a `*http.RequestCtx` that a CLI cannot supply. Task 4 splits
   it rather than duplicating the secret-preservation rule, and pins the refactor with
   "the existing tests must pass unedited".
4. Task 10 originally read the created record's id back from `records.createInTxnOpts`,
   whose return shape I could not verify. It now **requires** the source row to carry an
   `id` — true of every real export, already required by Task 7's deferred patch, and it
   removes the unverified dependency.

**Known residual risks.** Three spellings depend on Zig 0.16.0 std details the implementer
must confirm against the vendored lib rather than trust here:
`std.json.fmt` (Task 6's finding escaper — an alternative is given inline),
`std.Io.Reader`/`File.Writer` construction in the new CLI paths (copy `importImpl`'s exact
idiom), and `std.testing.tmpDir` + `realpathAlloc` in Task 7's test. Each is flagged at its
use site with what to copy instead.
