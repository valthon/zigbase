# Rails-Style Migrations — Piece A (DSL + Auto-Reversibility) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give consumer migrations a dialect-aware schema DSL and auto-reversibility — the forward + inverse machinery — so a `change(m)` migration can be applied and (later, Piece B) rolled back, with per-statement raw breakout and records-aware data transforms.

**Architecture:** Extend the consumer `provision.Migration` type with `change`/`down`/`transactional`; give `migrator.Migrator` a `direction` (forward/reverse) and a curated DSL op set where each op emits forward SQL (reusing `ddl.zig` generators) or its inverse based on `direction`; ops with no known inverse error in reverse mode. Piece A delivers the DSL + reverse machinery and the forward apply path; Pieces B (rollback/status CLI) and C (schema dump) are separate plans.

**Tech Stack:** Zig 0.16, SQLite + Postgres (via `-Dpostgres`), the existing `ddl.zig` dialect-aware SQL generators, `dialect.Dialect`.

## Global Constraints

- Zig 0.16.0 pinned via mise: build/test with `mise exec zig@0.16.0 -- zig build test --summary all` (authoritative signal: the `Build Summary: N/N tests passed` line — a spurious `failed command:` line prints even on success). Also `mise exec zig@0.16.0 -- zig build test -Dpostgres --summary all` for the Postgres path, and `mise exec zig@0.16.0 -- zig fmt --check src/` (CI runs fmt separately).
- Consumer migration type is `src/provision.zig`'s `Migration` (re-exported as `zigbase.Migration` via `src/root.zig:91`). The consumer Migrator is `src/migrator.zig`'s `Migrator`. Do NOT touch `src/migrations.zig` (the framework-internal system migrations + its own Migrator) — Piece A is consumer-facing only.
- Backward compatibility is MANDATORY: an existing `.migrations = .{ .{ .id = "…", .up = fn } }` (or a typed `&[_]zigbase.Migration{…}`) must apply byte-for-byte as today. Add a regression test.
- A new `src/*.zig` file's tests do NOT run until it is added to `src/root.zig`'s `test { _ = @import("…"); }` block.
- Portable SQL is written SQLite-flavor and lowered by the dialect (`m.execLowered`); genuinely divergent statements use `m.raw(.{ .sqlite, .postgres })` / the existing `m.rawFor(kind, sql)`.
- YAGNI: v1 op set only (createTable/dropTable, addColumn/dropColumn, renameColumn/renameTable, addIndex/dropIndex, addForeignKey). No "rollback to version" (Piece B), no schema dump (Piece C).

---

## File Structure

- `src/provision.zig` — extend `Migration` (add `change`/`down`/`transactional`); `runMigrations` forward-apply path handles `change` vs `up` and the `transactional` opt-out.
- `src/migrator.zig` — add `Migrator.direction`; the DSL op methods (forward + inverse); `raw(.{sqlite,postgres})`; a `notReversible` error helper; `records()`.
- `src/framework.zig` — the `.migrations` bare-tuple lowering (~line 1194 `provision_migrations`) learns the new fields + comptime-validates "exactly one of `change`/`up`; `down` needs a forward step".
- `src/root.zig` — no change (Migration already re-exported) unless a new file is added.
- Tests live inline in `provision.zig` / `migrator.zig` (the repo's convention).

---

### Task 1: Extend the consumer `Migration` type + comptime validation

**Files:**
- Modify: `src/provision.zig` (the `pub const Migration` at ~line 733)
- Modify: `src/framework.zig` (`provision_migrations` lowering ~line 1194 + the `migrationsCoerce` sibling ~line 279)
- Test: inline in `src/framework.zig` (comptime-resolution tests near the other `App(.{…})` tests)

**Interfaces:**
- Produces: `provision.Migration = struct { id: []const u8, change: ?*const fn(*Migrator) anyerror!void = null, up: ?*const fn(*Migrator) anyerror!void = null, down: ?*const fn(*Migrator) anyerror!void = null, transactional: bool = true }`. Consumed by Tasks 2–9 (the Migrator ops are called from within these fn pointers) and `runMigrations` (Task 9).

- [ ] **Step 1: Write the failing test** — a comptime test that an `App` with a `change`-style migration resolves, and that the tuple form still works.

```zig
test "migrations: change/up/transactional fields resolve (bare tuple + typed)" {
    const H = struct {
        fn ch(m: *migrator_mod.Migrator) anyerror!void { _ = m; }
    };
    // bare-tuple form with the new fields
    const A = App(.{ .migrations = .{ .{ .id = "0001_x", .change = H.ch } } });
    try std.testing.expectEqual(@as(usize, 1), A.provision_migrations.len);
    try std.testing.expect(A.provision_migrations[0].change != null);
    try std.testing.expect(A.provision_migrations[0].transactional); // default true
    // legacy up-only still lowers
    const B = App(.{ .migrations = .{ .{ .id = "0001_y", .up = H.ch } } });
    try std.testing.expect(B.provision_migrations[0].up != null);
    try std.testing.expect(B.provision_migrations[0].change == null);
}
```

- [ ] **Step 2: Run it, expect FAIL** — `mise exec zig@0.16.0 -- zig build test --summary all` fails (the tuple lowering doesn't know `.change`/`.transactional`).

- [ ] **Step 3: Implement** — (a) extend the struct in `provision.zig`:

```zig
pub const Migration = struct {
    id: []const u8,
    /// Auto-reversible forward change (Rails `change`). Applied with the Migrator in
    /// forward mode; Piece B rolls it back by re-running with direction = .reverse.
    change: ?*const fn (m: *Migrator) anyerror!void = null,
    /// Explicit forward step (use when the change isn't auto-reversible).
    up: ?*const fn (m: *Migrator) anyerror!void = null,
    /// Explicit reverse step for rollback (Piece B). Pairs with `up`, or overrides `change`.
    down: ?*const fn (m: *Migrator) anyerror!void = null,
    /// Per-migration transactional opt-out (default true) for DDL that can't run in a tx.
    transactional: bool = true,
};
```
(b) In `framework.zig`'s bare-tuple lowering, map the optional `.change`/`.up`/`.down`/`.transactional` tuple fields onto the struct (default the missing ones), and add the comptime guard:

```zig
// inside the per-entry lowering, after reading .id:
const has_change = @hasField(@TypeOf(entry), "change");
const has_up = @hasField(@TypeOf(entry), "up");
if (has_change == has_up) @compileError("migration '" ++ entry.id ++ "': set exactly one of .change or .up");
const has_down = @hasField(@TypeOf(entry), "down");
if (has_down and !has_up and !has_change) @compileError("migration '" ++ entry.id ++ "': .down needs a forward step");
```
(The typed-slice branch — `migrationsCoerce` — needs no lowering; the same validation should run over a typed slice too: add a comptime loop asserting exactly-one per entry.)

- [ ] **Step 4: Run tests, expect PASS.** Confirm `Build Summary: N/N tests passed` and `zig fmt --check src/` clean.

- [ ] **Step 5: Commit** — `feat(migrations): change/down/transactional on consumer Migration + validation`.

---

### Task 2: Migrator `direction` + `raw()` + `notReversible` helper

**Files:**
- Modify: `src/migrator.zig` (the `Migrator` struct ~line 32)
- Test: inline in `src/migrator.zig`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Migrator.direction: Direction` (`enum { forward, reverse }`, default `.forward`); `pub fn raw(self: *Migrator, per: struct { sqlite: [:0]const u8, postgres: [:0]const u8 }) db.DbError!void`; `fn notReversible(self: *Migrator, comptime op: []const u8) error{MigrationNotReversible}` (returns the error AND logs which op) — consumed by every DSL op in reverse mode (Tasks 3–8). NOTE: DSL ops widen the error set to include `error{MigrationNotReversible}`; the `up`/`change` fn pointer type is `anyerror!void` (Task 1), which already accommodates it.

- [ ] **Step 1: Write the failing test**

```zig
test "raw picks the dialect statement; direction defaults forward" {
    var d = try db.Db.openMemory();
    defer d.close();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = std.testing.allocator, .io = undefined };
    try std.testing.expectEqual(Migrator.Direction.forward, m.direction);
    try m.raw(.{ .sqlite = "CREATE TABLE t(a INTEGER);", .postgres = "CREATE TABLE t(a BIGINT);" });
    // table exists
    var st = try m.prepare("SELECT count(*) FROM t;");
    defer st.finalize();
    try std.testing.expect(try st.step());
}
```

- [ ] **Step 2: Run, expect FAIL** (`direction`/`raw` don't exist).

- [ ] **Step 3: Implement** — add to `migrator.zig`:

```zig
pub const Direction = enum { forward, reverse };
// ... in the struct:
direction: Direction = .forward,

/// A statement that genuinely diverges per backend; runs the arm for the active dialect.
pub fn raw(self: *Migrator, per: struct { sqlite: [:0]const u8, postgres: [:0]const u8 }) db.DbError!void {
    return switch (self.dialect.kind) {
        .sqlite => self.exec(per.sqlite),
        .postgres => self.exec(per.postgres),
    };
}

/// Reverse-mode guard: an op that cannot auto-invert calls this to fail loudly.
fn notReversible(self: *Migrator, comptime op: []const u8) error{MigrationNotReversible} {
    std.log.err("migration: `{s}` is not auto-reversible in a `change` migration; provide up/down", .{op});
    _ = self;
    return error.MigrationNotReversible;
}
```
(`raw`/`rawFor` are irreversible — a `change` using them and then being rolled back is a Piece-B concern; for symmetry, in reverse mode `raw` should call `notReversible("raw")`. Add that: if `self.direction == .reverse` return `self.notReversible("raw")`.)

- [ ] **Step 4: Run tests, expect PASS.** fmt clean.
- [ ] **Step 5: Commit** — `feat(migrator): direction + raw() + notReversible guard`.

---

### Task 3: DSL `createTable` / `dropTable` (the reversible-op template)

**Files:** Modify `src/migrator.zig`; test inline.

**Interfaces:**
- Consumes: `Migrator.direction`, `notReversible` (Task 2); `ddl.zig` column/table generation; `dialect.sqlType`.
- Produces: `pub fn createTable(self, name: []const u8, cols: []const Col) !void` and `pub fn dropTable(self, name: []const u8, opts: struct { was: ?[]const Col = null }) !void`, plus `pub const Col = struct { name: []const u8, type: ColType, null: bool = true, pk: bool = false, default: ?[]const u8 = null }` and `pub const ColType = enum { text, integer, real, boolean, blob, timestamp }`. `Col`/`ColType` are consumed by Tasks 4 (addColumn) and the `.was` reversibility args.

- [ ] **Step 1: Write failing tests** — forward creates, reverse drops; `dropTable` without `.was` errors in reverse.

```zig
test "createTable forward creates; reverse drops" {
    var d = try db.Db.openMemory();
    defer d.close();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = std.testing.allocator, .io = undefined };
    const cols = [_]Migrator.Col{ .{ .name = "id", .type = .integer, .pk = true, .null = false }, .{ .name = "title", .type = .text } };
    try m.createTable("posts", &cols);
    try std.testing.expect(try tableExists(&m, "posts"));
    m.direction = .reverse;
    try m.createTable("posts", &cols); // reverse-mode createTable == DROP TABLE
    try std.testing.expect(!try tableExists(&m, "posts"));
}
test "dropTable without .was is not reversible" {
    var d = try db.Db.openMemory();
    defer d.close();
    var m = Migrator{ .db = &d, .dialect = db.dbDialect(&d), .arena = std.testing.allocator, .io = undefined };
    m.direction = .reverse;
    try std.testing.expectError(error.MigrationNotReversible, m.dropTable("posts", .{}));
}
```
(Provide a small `tableExists` test helper in the file: a dialect-portable `SELECT` against `sqlite_master`/`information_schema` — or just `prepare("SELECT 1 FROM \"name\" LIMIT 0")` and treat a prepare error as "absent".)

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement** — `createTable` builds the `CREATE TABLE` from `cols` (map `ColType`→`dialect.sqlType`, quote idents via `dialect.quoteIdent`; reuse `ddl.columnDef` shape where it fits) and `execLowered`s it in forward mode; in reverse mode it emits `DROP TABLE IF EXISTS "name"`. `dropTable` is the mirror: forward = `DROP TABLE`; reverse = re-create from `opts.was` (error via `notReversible("dropTable")` when `was == null`). Keep the CREATE-building in one private helper both call.

- [ ] **Step 4: Run tests, expect PASS** on SQLite; add the same test body guarded for `-Dpostgres` (or rely on the existing PG test harness). fmt clean.
- [ ] **Step 5: Commit** — `feat(migrator): createTable/dropTable DSL (reversible template)`.

---

### Task 4: DSL `addColumn` / `dropColumn`

**Files:** Modify `src/migrator.zig`; test inline.

**Interfaces:**
- Consumes: `Col`/`ColType` (Task 3), `direction`, `notReversible`.
- Produces: `pub fn addColumn(self, table: []const u8, col: Col) !void`; `pub fn dropColumn(self, table: []const u8, name: []const u8, opts: struct { was: ?Col = null }) !void`.

- [ ] **Step 1: Failing tests** — addColumn forward adds / reverse drops; dropColumn reverse re-adds from `.was`, errors without it. (Model on Task 3's test shape; assert the column via `PRAGMA table_info`/`information_schema` or an `INSERT` that would fail if the column is absent.)
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** — forward `addColumn` = `ALTER TABLE "t" ADD COLUMN <coldef>` (build `<coldef>` with the same `ColType`→`sqlType` helper from Task 3); reverse = `ALTER TABLE "t" DROP COLUMN "name"`. `dropColumn`: forward = `DROP COLUMN`; reverse = re-`addColumn(table, opts.was.?)` or `notReversible("dropColumn")` when `was == null`. NOTE SQLite `DROP COLUMN` requires SQLite ≥ 3.35 (the vendored amalgamation supports it — confirm; if not, document the limitation).
- [ ] **Step 4: Run tests, expect PASS** (both dialects). fmt clean.
- [ ] **Step 5: Commit** — `feat(migrator): addColumn/dropColumn DSL`.

---

### Task 5: DSL `addIndex` / `dropIndex`

**Files:** Modify `src/migrator.zig`; test inline.

**Interfaces:**
- Consumes: `direction`, `notReversible`, `ddl.createIndexSql` shape.
- Produces: `pub fn addIndex(self, table: []const u8, columns: []const []const u8, opts: struct { name: ?[]const u8 = null, unique: bool = false }) !void`; `pub fn dropIndex(self, name: []const u8, opts: struct { was: ?struct { table: []const u8, columns: []const []const u8, unique: bool = false } = null }) !void`. Index name defaults to `idx_<table>_<col1>_<col2>` when `opts.name == null` (deterministic so the inverse can name it).

- [ ] **Step 1: Failing tests** — addIndex forward creates / reverse drops (by the same derived name); dropIndex reverse re-creates from `.was`, errors without it.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** — forward `addIndex` = `CREATE [UNIQUE] INDEX [IF NOT EXISTS] "<name>" ON "<table>" (…)` (reuse the `ddl.createIndexSql` generation pattern); reverse = `DROP INDEX [IF EXISTS] "<name>"` (Postgres/SQLite both accept `DROP INDEX name`). `dropIndex` mirrors with `.was`.
- [ ] **Step 4: Run tests, expect PASS** (both dialects). fmt clean.
- [ ] **Step 5: Commit** — `feat(migrator): addIndex/dropIndex DSL`.

---

### Task 6: DSL `renameColumn` / `renameTable` (self-inverse)

**Files:** Modify `src/migrator.zig`; test inline.

**Interfaces:**
- Consumes: `direction`.
- Produces: `pub fn renameTable(self, from: []const u8, to: []const u8) !void`; `pub fn renameColumn(self, table: []const u8, from: []const u8, to: []const u8) !void`. Both are auto-reversible with NO extra args (reverse just swaps from/to).

- [ ] **Step 1: Failing tests** — rename forward renames; reverse renames back. (Create a table, rename, assert new name resolves and old doesn't; flip direction, assert restored.)
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** — forward = `ALTER TABLE "from" RENAME TO "to"` / `ALTER TABLE "t" RENAME COLUMN "from" TO "to"`; reverse = the same with `from`/`to` swapped. (Both SQLite ≥ 3.25 and Postgres support `RENAME COLUMN`.)
- [ ] **Step 4: Run tests, expect PASS** (both dialects). fmt clean.
- [ ] **Step 5: Commit** — `feat(migrator): renameTable/renameColumn DSL (self-inverse)`.

---

### Task 7: DSL `addForeignKey`

**Files:** Modify `src/migrator.zig`; test inline.

**Interfaces:**
- Consumes: `direction`, `notReversible`, `ddl.addDeferrableFkSql` shape.
- Produces: `pub fn addForeignKey(self, table: []const u8, column: []const u8, ref_table: []const u8, opts: struct { ref_column: []const u8 = "id", on_delete_cascade: bool = false, name: ?[]const u8 = null }) !void`. FK constraint name defaults deterministically (`fk_<table>_<column>`) so the inverse can drop it.

- [ ] **Step 1: Failing tests** — forward adds the FK (an insert violating it fails); reverse drops it. On SQLite (no `ALTER TABLE ADD CONSTRAINT`), the op must use the dialect breakout: Postgres = `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY …`; SQLite = document that adding an FK to an existing table requires a table rebuild and, for v1, either (a) support it only on Postgres (`requireBackend(.postgres)` for the SQLite arm → clear error) or (b) reuse `ddl`'s rebuild path. DECIDE in Step 3 and note it; the test asserts the chosen behavior per dialect.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** — Postgres forward via `ddl.addDeferrableFkSql` (or a plain `ADD CONSTRAINT`), reverse = `DROP CONSTRAINT "<name>"`. SQLite: per the decision above (recommended v1: `requireBackend(.postgres)`-style guard with a documented limitation that SQLite FK-add needs a table rebuild — keep v1 lean; the DSL still works for the common Postgres case and the SQLite escape hatch is `m.raw`).
- [ ] **Step 4: Run tests, expect PASS** (both dialects, per the decided behavior). fmt clean.
- [ ] **Step 5: Commit** — `feat(migrator): addForeignKey DSL`.

---

### Task 8: `m.records()` — records-aware data transforms (#241)

**Files:** Modify `src/migrator.zig`; test inline.

**Interfaces:**
- Consumes: the records layer (`src/records.zig` / `src/data.zig`) — grep how `data.zig`/`records.zig` expose read/update on a `*db.Db`, and mirror the `Data` facade shape (`Data{ .app, .conn, .io, .alloc }` is used elsewhere; here there's no `app`, so expose the minimal read/update the transform needs against `self.db`).
- Produces: `pub fn records(self: *Migrator) RecordsMig` — a small facade with the operations a data migration needs (iterate a collection's rows, update a field). Data transforms are IRREVERSIBLE: in reverse mode `records()` (or its ops) call `notReversible("records")`, so a `change` doing data work must be paired with an explicit `down`.

- [ ] **Step 1: Failing test** — seed a row via SQL, run a migration that uses `m.records()` to transform a field, assert the transformed value; assert reverse-mode use errors.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** — the minimal records facade over `self.db` (reuse the existing records read/update primitives; do NOT reimplement encryption/coercion — route through the same functions `api/records.zig` uses so encrypted-field transforms are "real"). Guard reverse mode with `notReversible`.
- [ ] **Step 4: Run tests, expect PASS.** fmt clean.
- [ ] **Step 5: Commit** — `feat(migrator): records() data-transform facade (#241)`.

---

### Task 9: Wire `runMigrations` for `change` + `transactional` opt-out; backward-compat regression

**Files:** Modify `src/provision.zig` (`runMigrations` ~line 1090); test inline.

**Interfaces:**
- Consumes: the extended `Migration` (Task 1); `Migrator.direction` (Task 2).
- Produces: forward application of `change` (run with `direction = .forward`) or `up`; honors `.transactional == false` (run outside `begin/commit`). Piece B will add the reverse/rollback path — Piece A only applies forward.

- [ ] **Step 1: Failing tests** — (a) a `change`-based migration applies (its schema effect is present); (b) a `.transactional = false` migration applies without a wrapping tx (assert it ran; hard to assert "no tx" directly — assert behavior + that an in-migration `raw` DDL that can't run in a tx would still succeed); (c) **backward-compat**: a legacy `{ id, up }` migration applies exactly as before.
- [ ] **Step 2: Run, expect FAIL** (runMigrations only knows `.up`).
- [ ] **Step 3: Implement** — in the `runMigrations` loop, choose the forward fn: `const fwd = m.change orelse m.up.?;` set `mig.direction = .forward;`. If `m.transactional` wrap in `begin/…/commit` (today's code); else run `fwd(&mig)` + `recordMigration` directly (no tx). Keep the `errdefer w.rollback()` only on the transactional path.
- [ ] **Step 4: Run tests, expect PASS** on SQLite and `-Dpostgres`. fmt clean.
- [ ] **Step 5: Commit** — `feat(migrations): apply change-migrations + transactional opt-out`.

---

### Task 10: Docs + changelog

**Files:** Modify `docs/framework.md` (+ `site/src/content/docs/framework.md` mirror) migrations section; create `changelog.d/migrations-dsl.md`.

- [ ] **Step 1: Docs** — in the migrations section: the `Migration` shape (`change`/`up`/`down`/`transactional`), the DSL op reference (Tasks 3–8) with a `change` example, the auto-reversibility rule (reverse mode inverts; raw/records/no-`.was` drops are irreversible → use `up`/`down`), and the per-statement breakout (`exec`/`raw`/`rawFor`). Note rollback CLI is coming in Piece B. Apply the SAME edits to the site mirror.
- [ ] **Step 2: Changelog** — `changelog.d/migrations-dsl.md`:
```
### Features
- Migrations gain a dialect-aware schema DSL (`m.createTable`/`addColumn`/`addIndex`/`renameColumn`/`addForeignKey`, …) and auto-reversible `change` migrations: write the forward change once and it inverts for rollback. `up`/`down` remain for irreversible steps; a per-statement `m.raw(.{ .sqlite, .postgres })` breakout and records-aware `m.records()` data transforms (#241) round it out. Migrations stay transactional by default with a per-migration `.transactional = false` opt-out. (Rollback/status CLI + schema dump land next.)
```
- [ ] **Step 3: Verify** `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q` (no config-key added here, but keep docs in sync) and `zig fmt --check src/`.
- [ ] **Step 4: Commit** — `docs(migrations): DSL + auto-reversibility reference + changelog`.

---

## Notes for the executor
- The DSL ops share a `ColType→dialect.sqlType` mapping and ident-quoting (`dialect.quoteIdent`) — factor those into one private helper in `migrator.zig` (Task 3) and reuse (DRY).
- Every op is `if (self.direction == .reverse) { <inverse or notReversible> } else { <forward> }`. Keep that shape uniform.
- Reverse-mode application (running a whole `change` backward) is exercised by Piece B, but Task 3–8 tests each flip `m.direction = .reverse` and call the op directly to prove the inverse in isolation.
- Do NOT touch `src/migrations.zig`.
