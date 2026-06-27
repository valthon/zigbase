# Theme A2 — `ctx.tx()` Transactions + Atomic Before-Hooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit `ctx.tx(fn)` transaction scope for handlers, and fold `before`-record-hooks INTO the triggering write's transaction so a hook mutation/abort commits or rolls back atomically with the write.

**Architecture:** Add `BEGIN IMMEDIATE` to `db.Db`, then (1) give `Ctx` a `tx()` method that acquires the writer, begins an immediate transaction, runs a user callback against a `Tx` whose `records()` is bound to the transaction connection, and commits (auto-rollback on error; nesting rejected); and (2) restructure the record write flow in `src/api/records.zig` so the transaction opens *before* the before-hook, the before-hook runs on the in-transaction connection, the write executes, and commit happens after — with the before-hook able to abort the whole thing.

**Tech Stack:** Zig 0.16.0, vendored SQLite (WAL), `std.json`.

## Global Constraints

- Zig 0.16.0 exactly; authoritative test signal is `Build Summary: N/N tests passed` (`--summary all`).
- A new `src/*.zig` test is discovered only after it is added to the `test{}` block in `src/root.zig`.
- The pool writer is a single non-reentrant mutex (`db.zig` `acquireWriter`/`releaseWriter`): never acquire it while already holding it.
- Before-hook allocations that become part of `ev.record` MUST use the request arena.
- **Depends on Plan A1** (`src/ctx.zig` `Ctx`, `Records`, `bound_conn`, `connForRead`, `caps()`); execute A1 first.
- Never edit `CHANGELOG.md`; add a `changelog.d/<slug>.md` fragment.

---

## File Structure

- Modify `src/db.zig` — add `beginImmediate()`.
- Modify `src/ctx.zig` — add `Tx` type + `Ctx.tx()`; reject nesting.
- Modify `src/api/records.zig` — restructure `create`/`update`/`delete` so the before-hook runs inside the write transaction; before-hook errors roll back.
- Modify `src/records.zig` — expose a non-self-transacting write impl (or a `guard`-less variant) the new flow can call while it owns the transaction, and add a guarded `delete`.
- Create `changelog.d/ctx-transactions.md`.

**Interfaces produced:**

```zig
// src/db.zig
pub fn beginImmediate(self: *Db) DbError!void;       // exec("BEGIN IMMEDIATE;")

// src/ctx.zig
pub const Tx = struct {
    inner: Ctx,                                        // bound_conn = the txn connection
    pub fn records(self: *Tx) Ctx.Records;
};
pub fn tx(self: *Ctx, comptime T: type, f: *const fn (t: *Tx) anyerror!T) !T;  // error.NestedTransaction if already bound
```

---

## Task 1: `db.beginImmediate()`

**Files:**
- Modify: `src/db.zig` (near `begin`/`commit`/`rollback` at `db.zig:55-63`)

**Interfaces:**
- Consumes: `Db.exec`.
- Produces: `Db.beginImmediate`.

- [ ] **Step 1: Write the failing test**

Add near the existing db transaction tests:

```zig
test "beginImmediate starts a write transaction that can be committed" {
    var conn = try Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE t(x INTEGER);");
    try conn.beginImmediate();
    try conn.exec("INSERT INTO t(x) VALUES (1);");
    try conn.commit();
    // A second begin/commit proves the first fully closed.
    try conn.beginImmediate();
    try conn.commit();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `beginImmediate` undefined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub fn beginImmediate(self: *Db) DbError!void {
    return self.exec("BEGIN IMMEDIATE;");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/db.zig
git commit -m "feat(db): add beginImmediate() for write transactions"
```

---

## Task 2: `ctx.tx()` happy path — multiple writes commit atomically

**Files:**
- Modify: `src/ctx.zig`

**Interfaces:**
- Consumes: `beginImmediate`/`commit`/`rollback` (`src/db.zig`), `app.pool.acquireWriter`/`releaseWriter`, `Ctx`/`Records` (A1).
- Produces: `Tx`, `Ctx.tx`.

- [ ] **Step 1: Write the failing test**

```zig
test "ctx.tx commits all writes atomically" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();
    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    const Work = struct {
        a: std.mem.Allocator,
        fn run(t: *Tx) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(Tx.userdata)); // see note
            _ = self;
            var o1: std.json.ObjectMap = .empty;
            try o1.put(tx_alloc, "title", .{ .string = "one" });
            _ = try t.records().create("posts", .{ .object = o1 });
            var o2: std.json.ObjectMap = .empty;
            try o2.put(tx_alloc, "title", .{ .string = "two" });
            _ = try t.records().create("posts", .{ .object = o2 });
        }
    };
    _ = Work;
    // Simpler: use a file-scoped helper fn that reads the arena from t.inner.arena.
    try ctx.tx(void, txnTwoInserts);

    const page = try ctx.records().list("posts", .{});
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
}

fn txnTwoInserts(t: *Tx) anyerror!void {
    const a = t.inner.arena;
    var o1: std.json.ObjectMap = .empty;
    try o1.put(a, "title", .{ .string = "one" });
    _ = try t.records().create("posts", .{ .object = o1 });
    var o2: std.json.ObjectMap = .empty;
    try o2.put(a, "title", .{ .string = "two" });
    _ = try t.records().create("posts", .{ .object = o2 });
}
```

(Discard the `Work`/`userdata` sketch — the file-scoped `txnTwoInserts` taking `*Tx` and reading `t.inner.arena` is the real pattern; Zig has no capturing closures, so callbacks read state off `Tx`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `tx`/`Tx` undefined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub const Tx = struct {
    inner: Ctx,
    pub fn records(self: *Tx) Ctx.Records { return .{ .ctx = &self.inner }; }
};

pub fn tx(self: *Ctx, comptime T: type, f: *const fn (t: *Tx) anyerror!T) !T {
    if (self.bound_conn != null) return error.NestedTransaction;
    const conn = self.app.pool.acquireWriter();
    defer self.app.pool.releaseWriter();
    try conn.beginImmediate();
    var t = Tx{ .inner = .{ .app = self.app, .arena = self.arena, .rctx = self.rctx, .bound_conn = conn } };
    const result = f(&t) catch |e| {
        conn.rollback() catch {};
        return e;
    };
    try conn.commit();
    return result;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ctx.zig
git commit -m "feat(ctx): ctx.tx() atomic multi-write transaction scope"
```

---

## Task 3: `ctx.tx()` rollback on error + nesting rejected

**Files:**
- Modify: `src/ctx.zig`

**Interfaces:**
- Consumes: Task 2.
- Produces: rollback + `error.NestedTransaction` behavior (verified).

- [ ] **Step 1: Write the failing test**

```zig
fn txnInsertThenFail(t: *Tx) anyerror!void {
    const a = t.inner.arena;
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "title", .{ .string = "doomed" });
    _ = try t.records().create("posts", .{ .object = o });
    return error.Boom;
}
fn txnNested(t: *Tx) anyerror!void {
    // Attempting a tx inside a tx must be rejected.
    return t.inner.tx(void, txnInsertThenFail);
}

test "ctx.tx rolls back on error and rejects nesting" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();

    try std.testing.expectError(error.Boom, ctx.tx(void, txnInsertThenFail));
    const page = try ctx.records().list("posts", .{});
    try std.testing.expectEqual(@as(usize, 0), page.items.len); // rolled back

    try std.testing.expectError(error.NestedTransaction, ctx.tx(void, txnNested));
}
```

- [ ] **Step 2: Run test to verify it fails (or passes if Task 2 already covers it)**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: If Task 2's implementation already handles rollback+nesting, this PASSES immediately — that is acceptable (the test documents the contract). If it FAILS, fix in Step 3.

- [ ] **Step 3: Confirm/adjust implementation**

The Task 2 implementation already rolls back on a callback error and returns `error.NestedTransaction` when `bound_conn != null`. No change expected; if the nested call instead deadlocked or double-committed, the guard `if (self.bound_conn != null) return error.NestedTransaction;` is the fix — verify it is present and runs before any `acquireWriter`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ctx.zig
git commit -m "test(ctx): ctx.tx rollback-on-error and nested-tx rejection"
```

---

## Task 4: Non-self-transacting write impls + guarded `delete` in `records.zig`

**Files:**
- Modify: `src/records.zig`

**Interfaces:**
- Consumes: existing `createImpl`/`updateImpl` (`records.zig:513,900`), `delete` (`records.zig:958`).
- Produces: write entry points that do NOT open their own transaction (so the caller can own one spanning the before-hook), and a `deleteGuarded`. Existing `createGuarded`/`updateGuarded` remain for callers that still want self-contained transactions.

- [ ] **Step 1: Write the failing test**

```zig
test "createInTxn inserts without opening its own transaction" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrations.run(&conn);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const fields = [_]schema.Field{.{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } }};
    const col = try collections.create(a, io, &conn, .{ .id = "", .name = "posts", .fields = &fields });

    // Caller owns the transaction; createInTxn must participate, not nest.
    try conn.beginImmediate();
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "title", .{ .string = "x" });
    const rec = try createInTxn(a, io, &conn, col, .{ .object = o });
    try conn.rollback(); // caller rolls back -> row must be gone
    try std.testing.expect((try get(a, &conn, col, rec.object.get("id").?.string)) == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `createInTxn` undefined.

- [ ] **Step 3: Write minimal implementation**

Refactor `createImpl`/`updateImpl` so the transaction management (the `if (guard != null) try w.begin();` / `commit` at `records.zig:558,577,927,949`) is separated from the row work. Expose:

```zig
/// Insert a record on `w` WITHOUT opening a transaction. The caller must already
/// be inside one (or accept autocommit). Applies the same column/JSON handling as
/// createImpl but performs no begin/commit/guard.
pub fn createInTxn(alloc, io, w, col, data) RecordError!std.json.Value { ... }
pub fn updateInTxn(alloc, w, col, id, data) RecordError!?std.json.Value { ... }
pub fn deleteInTxn(alloc, w, col, id) RecordError!bool { ... }
```

Implement each by extracting the existing row logic from `createImpl`/`updateImpl`/`delete` minus the begin/commit/guard, and have the existing `createGuarded`/`updateGuarded` call the `InTxn` core between their own begin/guard/commit (DRY — one row-logic path). Also add `deleteGuarded` for symmetry. Match the exact column-binding/rowToObject logic currently in `createImpl` (`records.zig:563-575`) and `updateImpl` (`records.zig:932-948`).

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (and the pre-existing create/update/delete tests still pass — the refactor is behavior-preserving).

- [ ] **Step 5: Commit**

```bash
git add src/records.zig
git commit -m "refactor(records): split row-write core from transaction mgmt (createInTxn/updateInTxn/deleteInTxn)"
```

---

## Task 5: Fold before-hooks into the write transaction (`api/records.zig`)

**Files:**
- Modify: `src/api/records.zig` (`create` ~line 180, `update` ~line 237, `delete` ~line 301; `emitRecord` at lines 22-57)

**Interfaces:**
- Consumes: `createInTxn`/`updateInTxn`/`deleteInTxn` (Task 4), `beginImmediate`/`commit`/`rollback` (`db.zig`), `emitRecord` (constructs `RecordEvent` with `.data` bound to the writer conn).
- Produces: the new transactional ordering — begin → before-hook (in-txn) → write → access-rule guard → commit; after-hook post-commit; before-hook error → rollback, write fails closed.

- [ ] **Step 1: Write the failing test (browser/integration level)**

This atomicity is end-to-end. Add a Python admin/integration test that registers (via an example or a test fixture app) a `beforeCreate` hook which performs a side-write through `ev.caps().records().create(...)` and then returns an error; assert the HTTP create returns 4xx/5xx AND neither the primary row nor the hook's side-write row exists. (If no fixture app supports injecting a hook, add a Zig integration test in `src/api/records.zig` that drives `create()` with a stub dispatch whose before-hook side-writes then errors, asserting rollback of BOTH rows.)

```zig
test "before-hook side-write rolls back with the triggering write on hook error" {
    // Build an App whose dispatch.record is a before_create hook that:
    //   1) inserts a row into `audit` via a Data bound to ev.data.conn
    //   2) returns error.HookRejected
    // Drive api/records.create(...) and assert: returns an error/5xx, and BOTH
    // the `posts` row and the `audit` row are absent (single transaction rolled back).
    // (Harness mirrors the file-backed pool TestEnv used elsewhere.)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the Zig suite (and/or the pytest test). With today's ordering the side-write commits independently, so the `audit` row would survive — test FAILS.

- [ ] **Step 3: Write minimal implementation**

Restructure each write handler in `src/api/records.zig`. For `create()` (currently: `emitRecord(before)` at 212 → `records.create/createGuarded` at 215-224 → `emitRecord(after)` at 232):

```zig
// New ordering (create):
const w = ... acquire writer ...;
defer ... release writer ...;
try w.beginImmediate();
errdefer w.rollback() catch {};
// before-hook runs on the in-transaction connection:
try emitRecord(app, rctx, arena, col_name, &value, .before_create, w /* conn for ev.data */);
const rec = records.createInTxn(arena, app.io, w, col, value) catch |e| { /* rollback via errdefer */ return e; };
// access-rule guard (the former `guard`) evaluated here, still inside the txn:
if (!guardPasses(...)) { return error.Forbidden; } // errdefer rolls back
try w.commit();
// after-hook AFTER commit (side effects):
try emitRecord(app, rctx, arena, col_name, &rec, .after_create, w);
```

Mirror for `update()` and `delete()` (delete uses `deleteInTxn`). Ensure `emitRecord` binds `RecordEvent.data.conn` to `w` (the in-txn connection) so a hook's `ev.caps().records()` reuses it (A1 Task 8 already binds `caps()` to `ev.data.conn`). Keep the `before`-hook strictly before the row write so it can still mutate `value` before the INSERT; keep the access-rule guard inside the transaction so a denied write rolls back.

Document at the top of `src/data.zig` that the ATOMICITY caveat (lines 11-19) is now resolved for the HTTP write path: before-hooks ARE transactional with the triggering write.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Then the integration/pytest test.
Expected: PASS — both rows absent on hook error.

- [ ] **Step 5: Commit**

```bash
git add src/api/records.zig src/data.zig
git commit -m "feat(records): before-hooks run inside the write transaction (atomic abort)"
```

---

## Task 6: Regression + docs + changelog

**Files:**
- Modify: `docs/framework.md` + `site/src/content/` mirror (transactions + hook atomicity)
- Create: `changelog.d/ctx-transactions.md`

- [ ] **Step 1: Changelog fragment**

```markdown
### Features

- `ctx.tx(fn)` runs several record writes in one transaction — all commit, or all
  roll back on any returned error. Nesting is rejected (`error.NestedTransaction`).

### Fixes

- `before*` record hooks now run INSIDE the triggering write's transaction: a hook
  mutation and the write commit atomically, and a hook that returns an error rolls
  back the write (it now truly fails closed, including any side-writes the hook made
  through the capability object).
```

- [ ] **Step 2: Document + run full suites**

Add a "Transactions & hook atomicity" subsection to `docs/framework.md`; mirror to `site/`. Build site: `cd site && npm run build`.

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Run a representative records browser test: `mise exec python@3.13 -- python -m pytest tests/admin -q -k record` (or the closest existing records/admin tests).
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add docs/framework.md site/src/content changelog.d/ctx-transactions.md
git commit -m "docs(ctx): document ctx.tx + before-hook atomicity"
```

---

## Self-Review

**Spec coverage (transaction portion of Theme A spec §3):**
- `ctx.tx(fn)` BEGIN IMMEDIATE/COMMIT/auto-ROLLBACK → Tasks 1,2,3. ✓
- Nested tx disallowed (`error.NestedTransaction`) → Task 3. ✓
- before-hooks folded into the write transaction; abort rolls back; after-hooks post-commit → Tasks 4,5. ✓
- Writer never held across non-DB work — `ctx.tx` holds the writer only for the callback duration (no `http`/network inside the engine path); document that consumers should not perform long network calls inside `tx`. ✓ (note added in docs Task 6)

**Placeholder scan:** Task 2 explicitly discards the `Work`/`userdata` sketch in favor of the file-scoped `txnTwoInserts` callback; Task 5 Step 1 offers a concrete Zig integration test when no hook-injection fixture exists. No silent TODOs.

**Type consistency:** `Tx`/`tx`/`bound_conn`/`Records` names match A1. `createInTxn`/`updateInTxn`/`deleteInTxn` used identically in Tasks 4 and 5.

**Reconciliation note:** This plan assumes A1's `Ctx`/`Records`/`caps()` shapes as written. If A1 execution changes any of those names (e.g. the `records()` method form), update Tasks 2–5 accordingly before executing A2.
