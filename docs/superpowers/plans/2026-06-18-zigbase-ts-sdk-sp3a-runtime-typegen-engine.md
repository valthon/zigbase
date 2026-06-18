# SP3a — Runtime-Introspection Typegen Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an all-Zig `zigbase typegen` engine that reads a running/deployed instance's actual schema (offline from the data dir, or remotely over HTTP) and emits the *same* typed `zbase.gen.ts` as SP2's comptime generator — by feeding the existing `gen_client.generate` from runtime-acquired collections instead of comptime types.

**Architecture:** Two schema-acquisition adapters (`acquire_datadir.zig` reads the `_collections` SQLite table; `acquire_http.zig` reads `GET /api/collections`) both converge — via a shared `acquire.zig` normalization core — on `[]schema.Collection`, which is handed to the **untouched** `gen_client.generate(cols, &.{}, …)`. Empty routes ⇒ no `rpc.*`. A new `typegen` CLI subcommand (wired into `framework.zig`/`cli.zig`, gated by a comptime `ServeOpts.enable_typegen` field) drives it. Correctness is anchored by an in-memory Zig equivalence test proving the runtime path reproduces the comptime collection surface byte-for-byte, plus a committed dating runtime golden with a `--check` staleness gate.

**Tech Stack:** Zig 0.16 (run ONLY via `mise exec zig@0.16.0 -- zig …`), SQLite (`src/db.zig`), `std.http.Client`, the existing `src/codegen/*` emitter and `src/schema.zig` parsers.

## Global Constraints

- **Zig 0.16 only.** Every Zig command in this plan is `mise exec zig@0.16.0 -- zig …`. Plain `zig` is 0.15.2 and WILL fail.
- **`zig build test` success signal:** exit code 0 and no `error:`/`panic:`/assertion lines. A trailing `failed command: …` line on otherwise-passing runs is BENIGN (build-runner artifact) — judge by exit 0 + absence of real error lines.
- **Reuse the emitter untouched.** Do NOT edit `emit.zig`, `ts_type.zig`, `identifiers.zig`, `guards.zig`, or `gen_client.generate`'s body. SP3a only *calls* them. (You may add one `pub` to `gen_client.authCollectionName` OR compute it inline — this plan computes it inline to avoid touching gen_client.)
- **No `rpc.*`.** Always pass `&.{}` as the `routes` argument. SP3a never introspects routes.
- **Auth-field strip:** the server stores injected `schema.authSystemFields()` (email, username, passwordHash[hidden], tokenKey[hidden], verified) in `_collections.schema`, but the emitter re-synthesizes the visible ones. The adapter MUST strip every field whose name matches an `authSystemFields()` entry from `type == .auth` collections, leaving only user-defined fields — so `generate` synthesizes exactly once. Reference `schema.authSystemFields()` directly (do not hardcode the list).
- **Deterministic ordering:** `provision.applySpecs` inserts collections in topological order, not declaration order. The data-dir read MUST `ORDER BY name`; the HTTP adapter MUST sort by name. The equivalence test sorts the comptime baseline by name too.
- **Gate is comptime config**, not a `-D` flag: a `ServeOpts.enable_typegen: bool = false` field. The `typegen` handler branch in `runCliImpl` is guarded by `if (opts.enable_typegen)` (comptime-known ⇒ dead-code-eliminated when false). The dating fixture sets `.enable_typegen = true`; all other apps keep the default false and must still build.
- **Scope = SP3a only.** EXCLUDE: npm `@zigbase/typegen` wrapper, CI prebuilt binaries, and the TypeScript live-e2e (all SP3b). The HTTP adapter's *network* path (`acquire`) is delivered but its live round-trip is validated in SP3b; SP3a unit-tests its pure parse.
- **Docs sync:** any doc change in `docs/*.md` must be mirrored in `site/src/content/docs/*.md`.

---

### Task 1: Shared acquisition core (`acquire.zig`)

Source-agnostic normalization: raw JSON strings → `schema.Collection`, with auth-field stripping and name-sort. Both adapters depend on this, guaranteeing they converge on identical collections.

**Files:**
- Create: `src/codegen/acquire.zig`
- Test: same file (Zig `test` blocks)

**Interfaces:**
- Consumes: `schema.fieldsFromJson(alloc, s) ![]Field`, `schema.indexesFromJson(alloc, s) ![]Index`, `schema.optionsFromJson(alloc, s) !CollectionOptions`, `schema.authSystemFields() []const Field`, `schema.CollectionType`, `schema.Collection`, `schema.Field`.
- Produces: `pub const RawRow = struct { name, type_str, schema_json, indexes_json, options_json: []const u8 }`; `pub fn buildCollection(alloc, row: RawRow) !schema.Collection`; `pub fn sortByName(cols: []schema.Collection) void`; `pub fn isAuthSystemField(name: []const u8) bool`.

- [ ] **Step 1: Write the failing tests**

Append to `src/codegen/acquire.zig` (create the file with these tests + imports first):

```zig
const std = @import("std");
const schema = @import("../schema.zig");

test "buildCollection: base collection keeps user fields and parses types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const row = RawRow{
        .name = "posts",
        .type_str = "base",
        .schema_json =
        \\[{"id":"f1","name":"title","type":"text","options":{}},
        \\ {"id":"f2","name":"views","type":"number","options":{"mode":"int"}}]
        ,
        .indexes_json = "[]",
        .options_json = "{}",
    };
    const c = try buildCollection(a, row);
    try std.testing.expectEqualStrings("posts", c.name);
    try std.testing.expectEqual(schema.CollectionType.base, c.type);
    try std.testing.expectEqual(@as(usize, 2), c.fields.len);
    try std.testing.expectEqualStrings("title", c.fields[0].name);
    try std.testing.expectEqual(schema.FieldType.text, c.fields[0].fieldType());
    try std.testing.expectEqual(schema.FieldType.number, c.fields[1].fieldType());
}

test "buildCollection: auth collection strips injected system fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Simulates a stored auth schema: server-injected system fields + one user field.
    const row = RawRow{
        .name = "users",
        .type_str = "auth",
        .schema_json =
        \\[{"id":"_email","name":"email","type":"email","options":{}},
        \\ {"id":"_username","name":"username","type":"text","options":{}},
        \\ {"id":"_pwhash","name":"passwordHash","type":"text","options":{}},
        \\ {"id":"_tokkey","name":"tokenKey","type":"text","options":{}},
        \\ {"id":"_verified","name":"verified","type":"bool","options":{}},
        \\ {"id":"u1","name":"displayName","type":"text","options":{}}]
        ,
        .indexes_json = "[]",
        .options_json = "{}",
    };
    const c = try buildCollection(a, row);
    try std.testing.expectEqual(schema.CollectionType.auth, c.type);
    // Only the user field survives; all five authSystemFields() names are stripped.
    try std.testing.expectEqual(@as(usize, 1), c.fields.len);
    try std.testing.expectEqualStrings("displayName", c.fields[0].name);
}

test "sortByName orders collections by name" {
    var cols = [_]schema.Collection{
        .{ .id = "", .name = "zebra", .fields = &.{} },
        .{ .id = "", .name = "alpha", .fields = &.{} },
    };
    sortByName(&cols);
    try std.testing.expectEqualStrings("alpha", cols[0].name);
    try std.testing.expectEqualStrings("zebra", cols[1].name);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE "acquire|RawRow|buildCollection|error:" | head`
Expected: FAIL — `RawRow`/`buildCollection`/`sortByName` are undefined.

- [ ] **Step 3: Implement the core**

Add to `src/codegen/acquire.zig` (above the tests):

```zig
/// Source-agnostic representation of one `_collections` row / one
/// `GET /api/collections` array element. Both acquisition adapters populate
/// this and call buildCollection, so the paths converge on identical values.
pub const RawRow = struct {
    name: []const u8,
    type_str: []const u8, // "base" | "auth" | "view"
    schema_json: []const u8, // JSON array of field objects
    indexes_json: []const u8, // JSON array of index objects ("[]" if none)
    options_json: []const u8, // JSON object ("{}" if none)
};

/// True if `name` is one of the framework's injected auth system fields. The
/// server stores these in an auth collection's schema, but the emitter
/// re-synthesizes the visible ones — so the adapter strips them back to the
/// user-defined set. Referencing authSystemFields() keeps this in lockstep
/// with the framework if the injected set ever changes.
pub fn isAuthSystemField(name: []const u8) bool {
    for (schema.authSystemFields()) |f| {
        if (std.mem.eql(u8, name, f.name)) return true;
    }
    return false;
}

/// Build a schema.Collection from raw JSON strings using the engine's own
/// parsers. Rules and collection-level options are intentionally left at their
/// defaults: src/codegen/* never reads them, so they do not affect output.
pub fn buildCollection(alloc: std.mem.Allocator, row: RawRow) !schema.Collection {
    const ctype = std.meta.stringToEnum(schema.CollectionType, row.type_str) orelse .base;
    const all_fields = try schema.fieldsFromJson(alloc, row.schema_json);
    const indexes = try schema.indexesFromJson(alloc, row.indexes_json);
    const options = try schema.optionsFromJson(alloc, row.options_json);

    const fields: []const schema.Field = if (ctype == .auth) blk: {
        var kept: std.ArrayList(schema.Field) = .empty;
        for (all_fields) |f| {
            if (!isAuthSystemField(f.name)) try kept.append(alloc, f);
        }
        break :blk try kept.toOwnedSlice(alloc);
    } else all_fields;

    return .{
        .id = "",
        .name = try alloc.dupe(u8, row.name),
        .type = ctype,
        .fields = fields,
        .indexes = indexes,
        .options = options,
    };
}

fn lessByName(_: void, a: schema.Collection, b: schema.Collection) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Sort by name for output determinism independent of provisioning order
/// (provision.applySpecs inserts in topological order, not declaration order).
pub fn sortByName(cols: []schema.Collection) void {
    std.mem.sort(schema.Collection, cols, {}, lessByName);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE "error:|panic:" ; echo "exit=$?"`
Expected: exit 0 from the build (the grep finds nothing; a benign trailing `failed command:` line is fine). Confirm the three new tests are included by the suite.

- [ ] **Step 5: Register the file's tests** if the repo aggregates tests explicitly. Inspect how `src/codegen/gen_client.zig`'s tests are pulled into `zig build test` (look for a `test { _ = @import("…"); }` aggregator or the test step's root in `build.zig`) and add `_ = @import("acquire.zig");` (or the analogous reference) in the same place if required. If `zig build test` already ran the Step-4 tests, no registration is needed.

- [ ] **Step 6: Commit**

```bash
git add src/codegen/acquire.zig
git commit -m "feat(typegen): shared schema-acquisition core (auth-strip, name-sort)"
```

---

### Task 2: Data-dir adapter (`acquire_datadir.zig`)

Read the `_collections` table from a data dir's SQLite db into `[]schema.Collection`.

**Files:**
- Create: `src/codegen/acquire_datadir.zig`
- Test: same file

**Interfaces:**
- Consumes: `acquire.RawRow`, `acquire.buildCollection`, `acquire.sortByName`; `db.Db` (`open`, `openMemory`, `prepare`, `close`), `db.Stmt` (`step`, `columnText`, `columnInt`, `finalize`); for tests: `migrations.run(*db.Db)`, `provision.applySpecs(alloc, io, *db.Db, []const schema.Collection)`.
- Produces: `pub fn acquireFromDb(alloc, w: *db.Db) ![]schema.Collection`; `pub fn acquire(alloc, data_dir: []const u8) ![]schema.Collection`.

- [ ] **Step 1: Write the failing test**

Create `src/codegen/acquire_datadir.zig` with imports + this test:

```zig
const std = @import("std");
const schema = @import("../schema.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const provision = @import("../provision.zig");
const acquire = @import("acquire.zig");

test "acquireFromDb returns user collections (sorted, system excluded, auth stripped)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    const specs = [_]schema.Collection{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{
            .{ .id = "", .name = "displayName", .options = .{ .text = .{} } },
        } },
        .{ .id = "", .name = "articles", .fields = &.{
            .{ .id = "", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "", .name = "views", .options = .{ .number = .{ .mode = .int } } },
        } },
    };
    try provision.applySpecs(a, std.testing.io, &d, &specs);

    const cols = try acquireFromDb(a, &d);
    // _superusers (system) excluded; only the two user collections, name-sorted.
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("articles", cols[0].name);
    try std.testing.expectEqualStrings("users", cols[1].name);
    // Auth system fields stripped: users has only displayName.
    try std.testing.expectEqual(@as(usize, 1), cols[1].fields.len);
    try std.testing.expectEqualStrings("displayName", cols[1].fields[0].name);
    // Number mode preserved through the round-trip.
    try std.testing.expectEqual(schema.FieldType.number, cols[0].fields[1].fieldType());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE "acquireFromDb|error:" | head`
Expected: FAIL — `acquireFromDb` undefined.

- [ ] **Step 3: Implement the adapter**

Add to `src/codegen/acquire_datadir.zig` (above the test):

```zig
/// Read all user (non-system) collections from an open db handle's
/// `_collections` table, name-sorted. The schema/indexes/options columns are
/// JSON text the engine wrote via fieldsToJson/indexesToJson/optionsToJson, so
/// they parse back through acquire.buildCollection.
pub fn acquireFromDb(alloc: std.mem.Allocator, w: *db.Db) ![]schema.Collection {
    var st = try w.prepare(
        \\SELECT name, type, schema, indexes, options
        \\ FROM "_collections" WHERE system = 0 ORDER BY name;
    );
    defer st.finalize();

    var list: std.ArrayList(schema.Collection) = .empty;
    while (try st.step()) {
        const row = acquire.RawRow{
            .name = try alloc.dupe(u8, st.columnText(0)),
            .type_str = try alloc.dupe(u8, st.columnText(1)),
            .schema_json = try alloc.dupe(u8, st.columnText(2)),
            .indexes_json = try alloc.dupe(u8, st.columnText(3)),
            .options_json = try alloc.dupe(u8, st.columnText(4)),
        };
        try list.append(alloc, try acquire.buildCollection(alloc, row));
    }
    const cols = try list.toOwnedSlice(alloc);
    acquire.sortByName(cols); // ORDER BY name already sorts, but keep adapters symmetric.
    return cols;
}

/// Open `<data_dir>/data.db` and acquire its collections. Errors if the data
/// dir has no provisioned `_collections` (start the server once first).
pub fn acquire(alloc: std.mem.Allocator, data_dir: []const u8) ![]schema.Collection {
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}/data.db", .{data_dir}, 0);
    var w = db.Db.open(path) catch |e| {
        std.log.err("typegen: cannot open '{s}': {s}", .{ path, @errorName(e) });
        return error.DataDirOpenFailed;
    };
    defer w.close();
    return acquireFromDb(alloc, &w) catch |e| {
        std.log.err("typegen: cannot read _collections from '{s}': {s} (has the server provisioned this data dir?)", .{ path, @errorName(e) });
        return error.DataDirReadFailed;
    };
}
```

> Note: `st.columnText` returns a view into SQLite-owned memory valid only until the next `step`; each column is `dupe`d into `alloc` immediately, as above.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE "error:|panic:" ; echo done`
Expected: no error/panic lines; the new test passes.

- [ ] **Step 5: Register tests** (same check as Task 1 Step 5, for `acquire_datadir.zig`).

- [ ] **Step 6: Commit**

```bash
git add src/codegen/acquire_datadir.zig
git commit -m "feat(typegen): data-dir adapter reads _collections into []Collection"
```

---

### Task 3: typegen_cli core (data-dir) + the equivalence test

Add the CLI orchestrator's core (data-dir → generate → write/`--check`) and the killer test proving the runtime path reproduces the comptime collection surface byte-for-byte.

**Files:**
- Create: `src/codegen/typegen_cli.zig`
- Test: same file (equivalence + a check-helper test)

**Interfaces:**
- Consumes: `acquire_datadir.acquireFromDb`/`acquire`, `acquire.sortByName`, `gen_client.generate(alloc, cols, comptime routes, in_repo, auth_collection, client_name, api_prefix) ![]const u8`, `events.RouteMeta`, `std.Io` file APIs.
- Produces: `pub const Options = struct { data_dir, url: ?[]const u8, out, api_prefix, client_name: []const u8, check, in_repo: bool, admin_email, admin_password: ?[]const u8 }`; `pub fn run(alloc, io: std.Io, opts: Options) !void`; `pub fn authCollectionName(cols) []const u8`; `pub fn checkOrWrite(io, out_path, text, check) !void`.

- [ ] **Step 1: Write the failing tests**

Create `src/codegen/typegen_cli.zig` with imports + tests:

```zig
const std = @import("std");
const schema = @import("../schema.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const provision = @import("../provision.zig");
const events = @import("../events.zig");
const gen_client = @import("gen_client.zig");
const acquire = @import("acquire.zig");
const acquire_datadir = @import("acquire_datadir.zig");

test "equivalence: data-dir runtime path reproduces the comptime collection surface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A representative app: auth + base + relation + number-mode + select + file.
    const specs = [_]schema.Collection{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{
            .{ .id = "", .name = "displayName", .options = .{ .text = .{} } },
        } },
        .{ .id = "", .name = "posts", .fields = &.{
            .{ .id = "", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "", .name = "rank", .options = .{ .number = .{ .mode = .int } } },
            .{ .id = "", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users" } } },
        } },
    };

    // Runtime path: provision -> read back -> sort.
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    try provision.applySpecs(a, std.testing.io, &d, &specs);
    const rt_cols = try acquire_datadir.acquireFromDb(a, &d);

    // Comptime baseline: the same user-field specs, name-sorted.
    const ct_cols = try a.dupe(schema.Collection, &specs);
    acquire.sortByName(ct_cols);

    const rt = try gen_client.generate(a, rt_cols, &.{}, true, authCollectionName(rt_cols), "ZbClient", "/api");
    const ct = try gen_client.generate(a, ct_cols, &.{}, true, authCollectionName(ct_cols), "ZbClient", "/api");
    try std.testing.expectEqualStrings(ct, rt);
}

test "checkOrWrite: matching content passes, drift errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const dir = try std.fmt.allocPrint(a, "zig-cache/typegen-test-{d}", .{std.testing.random_seed});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/out.ts", .{dir});

    try checkOrWrite(io, path, "hello", false); // writes
    try checkOrWrite(io, path, "hello", true); // matches -> ok
    try std.testing.expectError(error.Stale, checkOrWrite(io, path, "changed", true));
}
```

> `std.testing.random_seed` gives a per-run unique suffix without `Math.random`/`Date.now`. If it is unavailable in this toolchain, substitute a fixed subdir name unique to this test file.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE "authCollectionName|checkOrWrite|error:" | head`
Expected: FAIL — `authCollectionName`/`checkOrWrite`/`run` undefined.

- [ ] **Step 3: Implement typegen_cli core**

Add to `src/codegen/typegen_cli.zig` (above the tests):

```zig
pub const Options = struct {
    data_dir: ?[]const u8 = null,
    url: ?[]const u8 = null,
    out: []const u8,
    api_prefix: []const u8 = "/api",
    client_name: []const u8 = "ZbClient",
    check: bool = false,
    in_repo: bool = false,
    admin_email: ?[]const u8 = null,
    admin_password: ?[]const u8 = null,
};

/// First auth collection's name (mirrors gen_client's private helper; computed
/// inline so gen_client stays untouched).
pub fn authCollectionName(cols: []const schema.Collection) []const u8 {
    for (cols) |c| if (c.type == .auth) return c.name;
    return "";
}

/// Write `text` to `out_path`, or (when check) compare and error on drift.
pub fn checkOrWrite(io: std.Io, out_path: []const u8, text: []const u8, check: bool) !void {
    if (check) {
        const existing = std.Io.Dir.cwd().readFileAlloc(io, out_path, std.heap.page_allocator, .limited(64 * 1024 * 1024)) catch |e| {
            std.log.err("typegen --check: cannot read '{s}': {s}", .{ out_path, @errorName(e) });
            return error.CheckReadFailed;
        };
        defer std.heap.page_allocator.free(existing);
        if (!std.mem.eql(u8, existing, text)) {
            std.log.err("typegen --check: '{s}' is STALE — re-run typegen to regenerate.", .{out_path});
            return error.Stale;
        }
        return;
    }
    if (std.fs.path.dirname(out_path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = text });
    std.log.info("typegen: wrote {s} ({d} bytes)", .{ out_path, text.len });
}

/// Orchestrate: acquire collections from the selected source, generate the
/// client, then write or check.
pub fn run(alloc: std.mem.Allocator, io: std.Io, opts: Options) !void {
    if ((opts.data_dir == null) == (opts.url == null)) {
        std.log.err("typegen: pass exactly one of --data-dir or --url", .{});
        return error.BadSource;
    }
    const cols = if (opts.data_dir) |dir|
        try acquire_datadir.acquire(alloc, dir)
    else
        try acquireHttp(alloc, io, opts); // implemented in Task 4

    const text = gen_client.generate(alloc, cols, &.{}, opts.in_repo, authCollectionName(cols), opts.client_name, opts.api_prefix) catch |e| {
        std.log.err("typegen: code generation failed: {s}", .{@errorName(e)});
        return e;
    };
    try checkOrWrite(io, opts.out, text, opts.check);
}
```

For Task 3, add a temporary stub so the file compiles before Task 4 lands the HTTP path:

```zig
fn acquireHttp(alloc: std.mem.Allocator, io: std.Io, opts: Options) ![]schema.Collection {
    _ = alloc;
    _ = io;
    _ = opts;
    return error.UrlSourceNotYetImplemented; // replaced in Task 4
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE "error:|panic:" ; echo done`
Expected: no error/panic lines. The equivalence test passing is the core proof that the runtime path == comptime collection surface byte-for-byte.

> If the equivalence test fails on first run, the diff localizes the gap (most likely the auth-strip set or a field-option round-trip). Fix the adapter/core — NOT the emitter — until byte-equal.

- [ ] **Step 5: Register tests** (as Task 1 Step 5, for `typegen_cli.zig`).

- [ ] **Step 6: Commit**

```bash
git add src/codegen/typegen_cli.zig
git commit -m "feat(typegen): cli core (data-dir+generate+check) + comptime/runtime equivalence test"
```

---

### Task 4: HTTP adapter (`acquire_http.zig`) + wire it into typegen_cli

Add the remote path: superuser auth → `GET /api/collections` → parse. SP3a unit-tests the pure parse; the live round-trip is SP3b.

**Files:**
- Create: `src/codegen/acquire_http.zig`
- Modify: `src/codegen/typegen_cli.zig` (replace the `acquireHttp` stub with a call into the new module)
- Test: `src/codegen/acquire_http.zig`

**Interfaces:**
- Consumes: `acquire.RawRow`, `acquire.buildCollection`, `acquire.sortByName`, `std.http.Client`, `std.json`.
- Produces: `pub fn parseCollections(alloc, json_bytes: []const u8) ![]schema.Collection`; `pub fn acquire(alloc, io: std.Io, origin, email, password: []const u8) ![]schema.Collection`.

- [ ] **Step 1: Write the failing test**

Create `src/codegen/acquire_http.zig` with imports + this test:

```zig
const std = @import("std");
const schema = @import("../schema.zig");
const acquire = @import("acquire.zig");

test "parseCollections: parses /api/collections array, strips auth fields, sorts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Shape mirrors collectionToJson output: fields under "schema", visible-only.
    const body =
        \\[
        \\ {"id":"c2","name":"posts","type":"base","system":false,
        \\  "schema":[{"id":"f1","name":"title","type":"text","options":{}}],
        \\  "indexes":[],"options":{}},
        \\ {"id":"c1","name":"users","type":"auth","system":false,
        \\  "schema":[{"id":"_email","name":"email","type":"email","options":{}},
        \\            {"id":"u1","name":"displayName","type":"text","options":{}}],
        \\  "indexes":[],"options":{}}
        \\]
    ;
    const cols = try parseCollections(a, body);
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("posts", cols[0].name); // name-sorted
    try std.testing.expectEqualStrings("users", cols[1].name);
    // Auth "email" stripped; only displayName remains.
    try std.testing.expectEqual(@as(usize, 1), cols[1].fields.len);
    try std.testing.expectEqualStrings("displayName", cols[1].fields[0].name);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE "parseCollections|error:" | head`
Expected: FAIL — `parseCollections` undefined.

- [ ] **Step 3: Implement the HTTP adapter**

Add to `src/codegen/acquire_http.zig` (above the test):

```zig
/// Parse a `GET /api/collections` JSON array into user collections. The
/// endpoint serializes fields under the "schema" key (collectionToJson shape);
/// nested arrays/objects are re-stringified to feed acquire.buildCollection,
/// which uses the same parsers as the data-dir path — so both converge.
pub fn parseCollections(alloc: std.mem.Allocator, json_bytes: []const u8) ![]schema.Collection {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidSchema;

    var list: std.ArrayList(schema.Collection) = .empty;
    for (parsed.value.array.items) |item| {
        if (item != .object) return error.InvalidSchema;
        const obj = item.object;
        // Skip system collections (e.g. _superusers) to match the comptime surface.
        if (obj.get("system")) |sv| {
            if (sv == .bool and sv.bool) continue;
        }
        const name = (objStr(obj, "name")) orelse return error.InvalidSchema;
        const type_str = objStr(obj, "type") orelse "base";
        const schema_json = try valueToJson(alloc, obj.get("schema"));
        const indexes_json = try valueToJson(alloc, obj.get("indexes"));
        const options_json = try valueToJson(alloc, obj.get("options"));
        try list.append(alloc, try acquire.buildCollection(alloc, .{
            .name = name,
            .type_str = type_str,
            .schema_json = schema_json,
            .indexes_json = indexes_json,
            .options_json = options_json,
        }));
    }
    const cols = try list.toOwnedSlice(alloc);
    acquire.sortByName(cols);
    return cols;
}

fn objStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Stringify a nested JSON value (array/object) back to text for the *FromJson
/// parsers. Missing values default to the empty array/object the parsers accept.
fn valueToJson(alloc: std.mem.Allocator, v: ?std.json.Value) ![]const u8 {
    const val = v orelse return "[]";
    if (val == .null) return "[]";
    return std.json.Stringify.valueAlloc(alloc, val, .{});
}

/// Authenticate as superuser then GET /api/collections. Network round-trip is
/// validated by SP3b's live e2e; SP3a unit-tests parseCollections.
pub fn acquire(alloc: std.mem.Allocator, io: std.Io, origin: []const u8, email: []const u8, password: []const u8) ![]schema.Collection {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();

    // 1) superuser auth-with-password -> token
    const auth_url = try std.fmt.allocPrint(alloc, "{s}/api/collections/_superusers/auth-with-password", .{origin});
    const auth_body = try std.fmt.allocPrint(alloc, "{{\"identity\":\"{s}\",\"password\":\"{s}\"}}", .{ email, password });
    const auth_resp = try fetch(alloc, &client, .POST, auth_url, &.{.{ .name = "content-type", .value = "application/json" }}, auth_body);
    if (auth_resp.status != 200) {
        std.log.err("typegen: superuser auth failed (HTTP {d})", .{auth_resp.status});
        return error.AuthFailed;
    }
    const token = try extractToken(alloc, auth_resp.body);

    // 2) GET /api/collections with the bearer token
    const cols_url = try std.fmt.allocPrint(alloc, "{s}/api/collections", .{origin});
    const bearer = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    const cols_resp = try fetch(alloc, &client, .GET, cols_url, &.{.{ .name = "authorization", .value = bearer }}, null);
    if (cols_resp.status != 200) {
        std.log.err("typegen: GET /api/collections failed (HTTP {d})", .{cols_resp.status});
        return error.CollectionsFetchFailed;
    }
    return parseCollections(alloc, cols_resp.body);
}

const Resp = struct { status: u16, body: []const u8 };

fn fetch(alloc: std.mem.Allocator, client: *std.http.Client, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) !Resp {
    const buf = try alloc.alloc(u8, 8 << 20); // 8 MiB cap for a schema dump
    var fw = std.Io.Writer.fixed(buf);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .extra_headers = headers,
        .response_writer = &fw,
    });
    return .{ .status = @intFromEnum(res.status), .body = fw.buffered() };
}

fn extractToken(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.AuthFailed;
    const tv = parsed.value.object.get("token") orelse return error.AuthFailed;
    if (tv != .string) return error.AuthFailed;
    return alloc.dupe(u8, tv.string);
}
```

> Verify the exact `std.http.Client.fetch` option names and `std.http.Header`/`std.http.Method` spellings against `src/oauth/client.zig:90-118`, which already uses this API in this toolchain; mirror it precisely.

- [ ] **Step 4: Wire into typegen_cli**

In `src/codegen/typegen_cli.zig`, add the import and replace the Task-3 stub:

```zig
const acquire_http = @import("acquire_http.zig");
```

```zig
fn acquireHttp(alloc: std.mem.Allocator, io: std.Io, opts: Options) ![]schema.Collection {
    const email = opts.admin_email orelse {
        std.log.err("typegen: --url requires --admin-email", .{});
        return error.MissingAdminEmail;
    };
    const password = opts.admin_password orelse {
        std.log.err("typegen: --url requires --admin-password", .{});
        return error.MissingAdminPassword;
    };
    return acquire_http.acquire(alloc, io, opts.url.?, email, password);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE "error:|panic:" ; echo done`
Expected: no error/panic lines; `parseCollections` test passes and the project builds with the HTTP path wired.

- [ ] **Step 6: Register tests** (as Task 1 Step 5, for `acquire_http.zig`).

- [ ] **Step 7: Commit**

```bash
git add src/codegen/acquire_http.zig src/codegen/typegen_cli.zig
git commit -m "feat(typegen): http adapter (superuser auth + GET /api/collections) + parse test"
```

---

### Task 5: Wire the `typegen` subcommand + comptime gate + dating enablement

Expose `typegen` as a CLI subcommand, gated by `ServeOpts.enable_typegen`, and turn it on for the dating fixture.

**Files:**
- Modify: `src/cli.zig` (add `Command.typegen`, `TypegenArgs`, parse, `HelpTopic.typegen`)
- Modify: `src/framework.zig` (`ServeOpts.enable_typegen`; `.typegen` arm in `runCliImpl` switch; `typegenImpl`; `printTypegenUsage`)
- Modify: `fixtures/dating/schema.zig` (`.enable_typegen = true`)
- Test: `src/cli.zig` (parse matrix); `src/codegen/typegen_cli.zig` already covers `run` validation + `checkOrWrite`

**Interfaces:**
- Consumes: `typegen_cli.Options`, `typegen_cli.run`.
- Produces: `cli.Command.typegen: TypegenArgs`; `TypegenArgs { data_dir, url, out, api_prefix, client_name, admin_email, admin_password: ?[]const u8, check: bool }`.

- [ ] **Step 1: Write the failing test** (in `src/cli.zig`, alongside existing parse tests)

```zig
test "parse typegen: data-dir + out + flags" {
    const args = [_][]const u8{ "typegen", "--data-dir", "./zb_data", "--out", "c.ts", "--client-name", "Api", "--check" };
    const cmd = try parse(&args, .{ .serve_static = true });
    try std.testing.expect(cmd == .typegen);
    try std.testing.expectEqualStrings("./zb_data", cmd.typegen.data_dir.?);
    try std.testing.expectEqualStrings("c.ts", cmd.typegen.out.?);
    try std.testing.expectEqualStrings("Api", cmd.typegen.client_name);
    try std.testing.expect(cmd.typegen.check);
}

test "parse typegen: url + admin creds" {
    const args = [_][]const u8{ "typegen", "--url", "http://x", "--admin-email", "a@b.c", "--admin-password", "pw", "--out", "c.ts" };
    const cmd = try parse(&args, .{ .serve_static = true });
    try std.testing.expectEqualStrings("http://x", cmd.typegen.url.?);
    try std.testing.expectEqualStrings("a@b.c", cmd.typegen.admin_email.?);
}

test "parse typegen: missing flag value errors" {
    const args = [_][]const u8{ "typegen", "--out" };
    try std.testing.expectError(ParseError.MissingValue, parse(&args, .{ .serve_static = true }));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE "typegen|error:" | head`
Expected: FAIL — `Command.typegen`/`TypegenArgs` undefined.

- [ ] **Step 3: Add `TypegenArgs` + `Command.typegen` + parse** (in `src/cli.zig`)

Add the struct near the other arg structs:

```zig
pub const TypegenArgs = struct {
    data_dir: ?[]const u8 = null,
    url: ?[]const u8 = null,
    out: ?[]const u8 = null,
    api_prefix: []const u8 = "/api",
    client_name: []const u8 = "ZbClient",
    admin_email: ?[]const u8 = null,
    admin_password: ?[]const u8 = null,
    check: bool = false,
};
```

Add to the `Command` union:

```zig
    typegen: TypegenArgs,
```

Add to `HelpTopic`:

```zig
    typegen,
```

Add a parse branch (mirror the `migrate`/`superuser` branches; place before the final `serve` block):

```zig
    if (std.mem.eql(u8, args[0], "typegen")) {
        var ta = TypegenArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (isHelpFlag(a)) return .{ .help = .typegen };
            if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.data_dir = args[i];
            } else if (std.mem.eql(u8, a, "--url")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.url = args[i];
            } else if (std.mem.eql(u8, a, "--out")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.out = args[i];
            } else if (std.mem.eql(u8, a, "--api-prefix")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.api_prefix = args[i];
            } else if (std.mem.eql(u8, a, "--client-name")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.client_name = args[i];
            } else if (std.mem.eql(u8, a, "--admin-email")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.admin_email = args[i];
            } else if (std.mem.eql(u8, a, "--admin-password")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                ta.admin_password = args[i];
            } else if (std.mem.eql(u8, a, "--check")) {
                ta.check = true;
            } else return ParseError.UnknownFlag;
        }
        return .{ .typegen = ta };
    }
```

- [ ] **Step 4: Run parse tests to verify they pass**

Run: `mise exec zig@0.16.0 -- zig build test 2>&1 | grep -iE "error:|panic:" ; echo done`
Expected: no error/panic lines; the three parse tests pass.

- [ ] **Step 5: Add the gate field + handler** (in `src/framework.zig`)

Add to `ServeOpts`:

```zig
    /// When true, compiles the `typegen` CLI subcommand into the binary.
    /// Off by default so production builds carry no codegen.
    enable_typegen: bool = false,
```

Add the import near the other codegen imports:

```zig
const typegen_cli = @import("codegen/typegen_cli.zig");
```

Add the `.typegen` arm to the `runCliImpl` switch (the `if (opts.enable_typegen)` condition is comptime-known, so the disabled build never analyzes `typegenImpl`):

```zig
        .typegen => |ta| {
            if (opts.enable_typegen) {
                try typegenImpl(init, ta);
            } else {
                std.log.err("typegen: this binary was not built with .enable_typegen = true", .{});
                return;
            }
        },
```

Add the help arm (in the `.help` switch):

```zig
            .typegen => printTypegenUsage(),
```

Add the impl + usage helpers:

```zig
fn typegenImpl(init: std.process.Init, ta: cli.TypegenArgs) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = ta.out orelse {
        std.log.err("typegen: --out <path> is required", .{});
        return error.MissingOut;
    };
    try typegen_cli.run(a, init.io, .{
        .data_dir = ta.data_dir,
        .url = ta.url,
        .out = out,
        .api_prefix = ta.api_prefix,
        .client_name = ta.client_name,
        .check = ta.check,
        .in_repo = init.environ_map.contains("ZBASE_INREPO"),
        .admin_email = ta.admin_email,
        .admin_password = ta.admin_password,
    });
}

fn printTypegenUsage() void {
    std.debug.print(
        \\Usage: <app> typegen (--data-dir <path> | --url <origin>) --out <file>
        \\                     [--api-prefix <prefix>] [--client-name <name>] [--check]
        \\                     [--admin-email <e> --admin-password <p>]   (with --url)
        \\
        \\Generates a typed TypeScript client from a running instance's schema.
        \\
    , .{});
}
```

- [ ] **Step 6: Enable for the dating fixture** (in `fixtures/dating/schema.zig`)

In the `zigbase.App(.{ … })` literal, add the field:

```zig
    .enable_typegen = true,
```

- [ ] **Step 7: Build everything (incl. the disabled-gate path)**

Run: `mise exec zig@0.16.0 -- zig build dating-server 2>&1 | grep -iE "error:" ; echo dating-ok`
Run: `mise exec zig@0.16.0 -- zig build 2>&1 | grep -iE "error:" ; echo lib-ok`
Expected: no `error:` lines. The default-false gate (library + golfsim/blog servers) must still build; dating-server builds with the subcommand.

- [ ] **Step 8: Manual smoke (optional but recommended)**

```bash
mise exec zig@0.16.0 -- zig build dating-server
D=$(mktemp -d)
./zig-out/bin/dating-server superuser create --email a@b.c --password test-password-123 --data-dir "$D"
# provision happens on serve; start briefly then stop, or rely on the golden tool in Task 6.
./zig-out/bin/dating-server typegen --data-dir "$D" --out /tmp/out.ts || echo "expected: needs provisioned dir"
```

(The data dir is only provisioned after a `serve`; this smoke just confirms the subcommand dispatches and errors cleanly on an unprovisioned dir. The golden tool in Task 6 provisions in-process.)

- [ ] **Step 9: Commit**

```bash
git add src/cli.zig src/framework.zig fixtures/dating/schema.zig
git commit -m "feat(typegen): wire gated typegen subcommand; enable for dating fixture"
```

---

### Task 6: Dating runtime golden + build steps + `--check` gate + CI

Commit a runtime-generated dating client and a staleness gate, produced by an in-process build tool that provisions the dating app, reads it back through the data-dir adapter, and generates — exercising the real runtime path.

**Files:**
- Create: `src/codegen/gen_runtime_main.zig`
- Create: `clients/typescript/test/codegen/dating/zbase.runtime.gen.ts` (generated, committed)
- Modify: `build.zig` (add `gen-dating-runtime-client` + `gen-dating-runtime-client-check` steps)
- Modify: the CI workflow that runs `gen-dating-client-check` (add the runtime check)

**Interfaces:**
- Consumes: `app.App.collections` (the dating fixture, imported as the `app` module — same wiring as `gen_main.zig`), `db`, `migrations`, `provision`, `acquire_datadir.acquireFromDb`, `gen_client.generate`, `typegen_cli.{authCollectionName, checkOrWrite}`.

- [ ] **Step 1: Implement the golden generator tool** (`src/codegen/gen_runtime_main.zig`)

```zig
//! Build-time tool: provision the `app` fixture's collections into a temp
//! in-memory db, read them back through the runtime data-dir adapter, and
//! generate/check the runtime golden. Proves the committed runtime client is
//! a true product of the data-dir acquisition path (not a hand copy).
const std = @import("std");
const zigbase = @import("zigbase");
const app = @import("app");

const schema = zigbase.schema;
const db = zigbase.db;
const migrations = zigbase.migrations;
const provision = zigbase.provision;
const gen_client = zigbase.codegen.gen_client;
const acquire_datadir = zigbase.codegen.acquire_datadir;
const typegen_cli = zigbase.codegen.typegen_cli;

const Args = struct { out: ?[]const u8 = null, check: bool = false, api_prefix: []const u8 = "/api" };

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const argv = try init.minimal.args.toSlice(a);
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= argv.len) return error.MissingOut;
            args.out = argv[i];
        } else if (std.mem.eql(u8, arg, "--api-prefix")) {
            i += 1;
            if (i >= argv.len) return error.MissingApiPrefix;
            args.api_prefix = argv[i];
        } else if (std.mem.eql(u8, arg, "--check")) {
            args.check = true;
        }
    }
    const out = args.out orelse return error.MissingOut;

    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    try provision.applySpecs(a, init.io, &d, app.App.collections);
    const cols = try acquire_datadir.acquireFromDb(a, &d);

    const in_repo = init.environ_map.contains("ZBASE_INREPO");
    const text = try gen_client.generate(a, cols, &.{}, in_repo, typegen_cli.authCollectionName(cols), "ZbClient", args.api_prefix);
    try typegen_cli.checkOrWrite(init.io, out, text, args.check);
}
```

> `zigbase` must re-export `db`, `migrations`, `provision`, `schema`, and `codegen.{gen_client, acquire_datadir, typegen_cli}`. Check `src/root.zig` (or the module's root) for the existing `codegen` namespace and add any missing re-exports (`acquire_datadir`, `typegen_cli`) next to the existing `gen_client` export.

- [ ] **Step 2: Add build steps** (`build.zig`, mirroring the `gen-dating-client` block)

```zig
    // Runtime-introspection golden: provision the dating app in-memory, read it
    // back via the data-dir adapter, and generate. Needs libc/sqlite (provision).
    const gen_rt_mod = b.createModule(.{
        .root_source_file = b.path("src/codegen/gen_runtime_main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    gen_rt_mod.addImport("zigbase", zigbase_mod);
    gen_rt_mod.addImport("app", dating_app_mod);
    const gen_rt_exe = b.addExecutable(.{ .name = "zbase-gen-runtime-client", .root_module = gen_rt_mod });

    const rt_out = "clients/typescript/test/codegen/dating/zbase.runtime.gen.ts";
    const gen_rt_run = b.addRunArtifact(gen_rt_exe);
    gen_rt_run.setEnvironmentVariable("ZBASE_INREPO", "1");
    gen_rt_run.addArgs(&.{ "--out", rt_out, "--api-prefix", "/api" });
    const gen_rt_step = b.step("gen-dating-runtime-client", "Generate the dating runtime-introspection client golden");
    gen_rt_step.dependOn(&gen_rt_run.step);

    const rt_check_run = b.addRunArtifact(gen_rt_exe);
    rt_check_run.setEnvironmentVariable("ZBASE_INREPO", "1");
    rt_check_run.addArgs(&.{ "--out", rt_out, "--api-prefix", "/api", "--check" });
    const rt_check_step = b.step("gen-dating-runtime-client-check", "Fail if the dating runtime client golden is stale");
    rt_check_step.dependOn(&rt_check_run.step);
```

> `dating_app_mod` and `zigbase_mod` already exist in `build.zig` (used by `gen-dating-client`). If `dating_app_mod` lacks `link_libc`, provisioning needs sqlite at link time — the `gen_rt_mod` itself sets `.link_libc = true`, which is what links sqlite for the tool; confirm the build succeeds and add `link_libc` to `gen_rt_mod` (done above).

- [ ] **Step 3: Generate the golden**

Run: `mise exec zig@0.16.0 -- zig build gen-dating-runtime-client`
Expected: writes `clients/typescript/test/codegen/dating/zbase.runtime.gen.ts`. Open it: it must start with `// generated by zigbase — do not edit`, import from the in-repo `../../../src/...` paths (because `ZBASE_INREPO=1`), contain the collection/where/meta/service/realtime/files surface, and contain **no `rpc:` section**.

- [ ] **Step 4: Verify the golden typechecks**

Run: `cd clients/typescript && npx tsc --noEmit 2>&1 | grep -iE "runtime.gen|error TS" | head ; cd ../..`
Expected: no `error TS…` referencing `zbase.runtime.gen.ts`. (The TS project already typechecks the sibling `zbase.gen.ts`; the runtime golden joins the same dir.)

- [ ] **Step 5: One-time equivalence-to-comptime confirmation**

Confirm the runtime golden equals the committed comptime client minus its rpc blocks and ordering. This is a manual sanity check (the automated proof is Task 3's equivalence test on a representative schema):

Run: `diff <(grep -vE '  rpc:|    rpc:' clients/typescript/test/codegen/dating/zbase.gen.ts) clients/typescript/test/codegen/dating/zbase.runtime.gen.ts | head -40`
Expected: differences confined to (a) the rpc interface/factory blocks present only in the comptime client, and (b) collection ordering (runtime is name-sorted, comptime is declaration order). No differences in any record/where/meta/service body. If anything else differs, investigate the adapter before proceeding.

- [ ] **Step 6: Verify `--check` gate behavior**

Run: `mise exec zig@0.16.0 -- zig build gen-dating-runtime-client-check 2>&1 | grep -iE "STALE|error:" ; echo check-ok`
Expected: no STALE/error (golden is fresh). Then perturb: `printf '\n// drift' >> clients/typescript/test/codegen/dating/zbase.runtime.gen.ts`, re-run the check → expect a STALE error and non-zero exit. Restore with `mise exec zig@0.16.0 -- zig build gen-dating-runtime-client`.

- [ ] **Step 7: Wire CI**

Find the CI workflow step that runs `zig build gen-dating-client-check` (search `.github/workflows/` for `gen-dating-client-check`). Add a sibling invocation `zig build gen-dating-runtime-client-check` in the same job, after it. Keep the exact runner/zig-invocation style of the existing step.

- [ ] **Step 8: Commit**

```bash
git add src/codegen/gen_runtime_main.zig build.zig clients/typescript/test/codegen/dating/zbase.runtime.gen.ts src/root.zig .github/workflows
git commit -m "feat(typegen): dating runtime golden + gen/check build steps + CI gate"
```

(Adjust `src/root.zig` to the actual module-root path if different.)

---

### Task 7: Documentation sync

Document the runtime-introspection generator and the comptime gate, mirrored to `site/`.

**Files:**
- Modify: `docs/typescript-sdk.md` + `site/src/content/docs/typescript-sdk.md`
- Modify: `docs/framework.md` + `site/src/content/docs/framework.md`
- Modify: `clients/typescript/README.md`

- [ ] **Step 1: Add a "Runtime introspection (`zigbase typegen`)" subsection** to `docs/typescript-sdk.md` (and mirror verbatim into `site/src/content/docs/typescript-sdk.md`). Content to include:
  - When to use it: you consume a deployed ZigBase backend as a black box (no Zig source / no `build.zig` wiring) and don't define custom routes. If you have the source, prefer the comptime generator (it also emits typed `rpc.*`).
  - Two sources: `--data-dir <path>` (offline, reads the server's data dir directly; the dir must have been provisioned by a prior `serve`) and `--url <origin> --admin-email <e> --admin-password <p>` (reads `GET /api/collections`, which requires superuser auth).
  - Output: the same typed client (`db` / realtime / files), **without** `rpc.*`.
  - Example:
    ```bash
    myserver typegen --data-dir ./zb_data --out src/zbase.gen.ts
    # or, against a running instance:
    myserver typegen --url https://api.example.com --admin-email admin@x.io --admin-password '…' --out src/zbase.gen.ts
    ```
  - Note: the subcommand exists only in binaries built with `.enable_typegen = true`.

- [ ] **Step 2: Add a note to `docs/framework.md`** (and mirror into `site/src/content/docs/framework.md`): the `App(.{ … })` config accepts `.enable_typegen` (default `false`); when `true`, the binary gains the `typegen` subcommand. Recommend enabling it only for builds intended to generate clients.

- [ ] **Step 3: Add a short mention to `clients/typescript/README.md`**: a one-paragraph pointer to runtime introspection as an alternative to the comptime generator for black-box backends, linking to the typescript-sdk doc section.

- [ ] **Step 4: Verify mirror parity**

Run: `diff docs/typescript-sdk.md site/src/content/docs/typescript-sdk.md ; diff docs/framework.md site/src/content/docs/framework.md`
Expected: no differences for the sections you edited (front-matter-only diffs that already existed are acceptable — match the file's existing convention).

- [ ] **Step 5: Commit**

```bash
git add docs/typescript-sdk.md site/src/content/docs/typescript-sdk.md docs/framework.md site/src/content/docs/framework.md clients/typescript/README.md
git commit -m "docs(typegen): document runtime-introspection generator + enable_typegen gate"
```

---

## Self-Review

**Spec coverage:**
- Config gate (comptime `enable_typegen`, not `-D`) → Task 5. ✓
- `typegen` CLI subcommand in `framework.zig`/`cli.zig` → Task 5. ✓
- `typegen_cli.zig` (arg parsing/adapter selection/`--check`) → Tasks 3–5. ✓
- `acquire_datadir.zig` (`_collections` → `[]Collection`, system filter) → Task 2. ✓
- `acquire_http.zig` (superuser auth → `GET /api/collections` → parse) → Task 4. ✓
- Reuse `gen_client.generate(cols, &.{}, …)` untouched → Tasks 3/6 (auth name inline, no emitter edits). ✓
- Equivalence test (runtime == comptime collection surface) → Task 3 (representative schema, in-memory). Data-dir mode anchored; URL mode covered by Task 4's parse test (both adapters share `buildCollection`, so equal cols ⇒ equal output). ✓
- Committed runtime golden + `--check` staleness gate → Task 6. ✓
- Adapter/CLI unit tests + `--check` exit codes → Tasks 1–5. ✓
- Docs sync → Task 7. ✓
- Auth-field strip + name-sort determinism + system-collection filter → Tasks 1/2 (Global Constraints). ✓
- Excludes SP3b (npm wrapper, CI prebuilts, TS live e2e). ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code. Two explicit verification points are flagged (not placeholders): confirm `std.http.Client.fetch` option spelling against `src/oauth/client.zig`, and confirm the `codegen` namespace re-exports in the module root — both name a concrete existing reference to copy.

**Type consistency:** `acquire.RawRow`/`buildCollection`/`sortByName`/`isAuthSystemField`, `acquire_datadir.{acquireFromDb, acquire}`, `acquire_http.{parseCollections, acquire}`, `typegen_cli.{Options, run, authCollectionName, checkOrWrite}`, `cli.TypegenArgs`/`Command.typegen`, `ServeOpts.enable_typegen` are used consistently across tasks. `generate` is always called with the confirmed 7-arg signature and `&.{}` routes. The golden tool consumes `app.App.collections` and the same `acquireFromDb`/`generate`/`checkOrWrite` as the adapters.

**Known cross-task verification (for the executor):**
- The equivalence test (Task 3) is the forcing function for the auth-strip set (Task 1) and the field-option round-trip (Task 2). If it fails, fix the adapter/core, never the emitter.
- Task 5's `if (opts.enable_typegen)` must be comptime-known so disabled builds don't pull codegen — verify by building golfsim/blog (default-false) in Task 5 Step 7.
