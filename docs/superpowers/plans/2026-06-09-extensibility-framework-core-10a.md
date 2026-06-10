# Extensibility Framework — Core (10a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ZigBase importable as a Zig dependency and extensible via comptime-registered **record lifecycle hooks**, with a stable `App` data facade and a unified error/Sentry event — without changing any existing behavior of the shipped binary.

**Architecture:** Introduce a public `zigbase` module (`src/root.zig`) carrying the SQLite C + zap graph transitively. A comptime `App(cfg)` builder turns a declarative config into a concrete app: it generates a record-event **dispatcher** (a plain `fn(*RecordEvent) anyerror!void`) from the comptime hook list and stores it, type-erased, on the runtime `app.App`. The records write path emits `before*` events inside the open transaction (mutate/abort) and `after*` events post-commit (side-effects, errors routed to the error event). Hook DB access goes through a connection-bound `Data` facade so before-hooks can do atomic side-writes on the held writer without re-acquiring the spinlock.

**Tech Stack:** Zig 0.16 (`mise exec zig@0.16.0 -- zig …`), vendored SQLite (C interop), zap (HTTP), `std.json`, `std.http.Client` (Sentry transport). Browser tests via `mise exec python@3.13 -- python -m pytest` (Playwright).

**Build/test rule (applies to every task):** Always run BOTH `mise exec zig@0.16.0 -- zig build` (the binary — catches errors in unreferenced `pub fn` bodies that `zig build test` skips) AND `mise exec zig@0.16.0 -- zig build test --summary all`. The existing suite is **209 Zig tests** + **10 Playwright tests**; they must stay green throughout (this plan is behavior-preserving for the shipped `App(.{})`).

---

## File Structure

| File | Responsibility |
|---|---|
| `src/root.zig` (NEW) | Public `zigbase` module entry: re-exports `App`, `Config`, event types, `Data`; `test`-references every internal file so the existing 209 tests stay discovered. |
| `src/data.zig` (NEW) | The `Data` facade: connection-bound, curated record operations (findById/create/update/delete/list). No SQLite/zap types in its public signatures. |
| `src/events.zig` (NEW) | Event payload structs (`RecordEvent`, `ErrorEvent`, phases), the comptime hook-config shape, and the runtime type-erased `Dispatch` stored on `App`. |
| `src/sentry.zig` (NEW) | Minimal Sentry envelope serializer + the default error backstop (Sentry-if-DSN-else-log). |
| `src/framework.zig` (NEW) | The comptime `App(comptime cfg: Cfg) type` builder: generates the record dispatcher from `cfg.hooks`, wires Config→Pool→runtime app→serve, and exposes `run`/`runCli`. |
| `src/app.zig` (MOD) | Add a `dispatch: ?*const events.Dispatch = null` field to the runtime `App` struct. |
| `src/api/records.zig` (MOD) | Emit `before*`/`after*` record events around the write transaction, before `broadcast`. |
| `src/main.zig` (MOD) | Slim to a thin consumer: `@import("zigbase").App(.{}).runCli(init)`. |
| `build.zig` (MOD) | `b.addModule("zigbase", …)` with SQLite C + zap attached; exe imports the module; tests reroot to the module. |
| `examples/blog/` (NEW) | Standalone consumer package (own `build.zig`/`build.zig.zon`) importing `zigbase`, registering one record hook. Proves the dependency path compiles. |

---

## Task 1: Expose the public `zigbase` module (restructure, no behavior change)

Make the whole library a named module rooted at `src/root.zig`, consumed by the executable. This is a pure restructure: the 209 Zig tests + binary + 10 Playwright tests must stay green.

**Files:**
- Create: `src/root.zig`
- Modify: `build.zig`
- Modify: `src/main.zig:1-13` (imports only)

- [ ] **Step 1: Create `src/root.zig` re-exporting the current public surface and referencing all internal files for tests**

`src/root.zig`:
```zig
const std = @import("std");

// ---- Public API (grows over this plan) -------------------------------------
pub const App = @import("app.zig").App; // runtime app context (the comptime App(cfg) builder is added in Task 6)
pub const Config = @import("config.zig").Config;
pub const Server = @import("server.zig").Server;
pub const http = @import("http.zig");

// ---- Test discovery --------------------------------------------------------
// The unit-test runner is rooted at THIS module (build.zig). Reference every
// internal file so its `test {}` blocks are analyzed and run (matches the
// pre-restructure behavior where main.zig's import graph reached them).
test {
    _ = @import("app.zig");
    _ = @import("config.zig");
    _ = @import("cli.zig");
    _ = @import("db.zig");
    _ = @import("http.zig");
    _ = @import("router.zig");
    _ = @import("request.zig");
    _ = @import("server.zig");
    _ = @import("schema.zig");
    _ = @import("collections.zig");
    _ = @import("records.zig");
    _ = @import("values.zig");
    _ = @import("ddl.zig");
    _ = @import("migrations.zig");
    _ = @import("rules.zig");
    _ = @import("crypto.zig");
    _ = @import("jwt.zig");
    _ = @import("auth.zig");
    _ = @import("id.zig");
    _ = @import("admin.zig");
    _ = @import("api/error.zig");
    _ = @import("api/health.zig");
    _ = @import("api/collections.zig");
    _ = @import("api/records.zig");
    _ = @import("api/auth.zig");
    _ = @import("api/oauth.zig");
    _ = @import("api/files.zig");
    _ = @import("oauth/secrets.zig");
    _ = @import("oauth/providers.zig");
    _ = @import("oauth/client.zig");
    _ = @import("query/params.zig");
    _ = @import("query/lexer.zig");
    _ = @import("query/parser.zig");
    _ = @import("query/joiner.zig");
    _ = @import("query/compiler.zig");
    _ = @import("query/sort.zig");
    _ = @import("query/expand.zig");
    _ = @import("realtime/protocol.zig");
    _ = @import("realtime/connection.zig");
    _ = @import("realtime/hub.zig");
    _ = @import("realtime/ws.zig");
    _ = @import("files/naming.zig");
    _ = @import("files/mime.zig");
    _ = @import("files/storage.zig");
    _ = @import("files/plan.zig");
    _ = @import("files/multipart.zig");
}
```

(If the file list drifts, run `ls src/**/*.zig` and reconcile — every internal `.zig` with a `test {}` block must be referenced.)

- [ ] **Step 2: Rewire `build.zig` to expose `zigbase` as a module and consume it from the exe**

Replace `build.zig` body (the `build` fn) with:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zap = b.dependency("zap", .{ .target = target, .optimize = optimize });

    // The public library module. Consumers `zig fetch` this and import "zigbase".
    const zigbase_mod = b.addModule("zigbase", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zigbase_mod.addIncludePath(b.path("vendor/sqlite"));
    zigbase_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
        },
    });
    zigbase_mod.addImport("zap", zap.module("zap"));

    // The shipped binary: a thin consumer of the library module.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zigbase", zigbase_mod);

    const exe = b.addExecutable(.{ .name = "zigbase", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zigbase");
    run_step.dependOn(&run_cmd.step);

    // Unit tests run against the library module (where all internal test{} live).
    const tests = b.addTest(.{ .root_module = zigbase_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
```

- [ ] **Step 3: Slim `src/main.zig` imports to consume the module**

`src/main.zig` currently `@import`s many internal files directly (e.g. `@import("server.zig")`, `@import("app.zig")`, `@import("cli.zig")`, etc.). Those internal files now live behind the `zigbase` module. For Task 1 the simplest correct move is to make `main.zig` pull everything it needs from the module. Change the import block at the top of `src/main.zig` from per-file imports to:
```zig
const std = @import("std");
const zigbase = @import("zigbase");

// Internal pieces main() still drives directly until Task 6 introduces App(cfg).runCli.
const app_mod = zigbase.@"internal".app;
const server = zigbase.@"internal".server;
const cli = zigbase.@"internal".cli;
const config = zigbase.@"internal".config;
const migrations = zigbase.@"internal".migrations;
const files_storage = zigbase.@"internal".files_storage;
const crypto = zigbase.@"internal".crypto;
const id_gen = zigbase.@"internal".id;
```

To support that, add an `internal` namespace to `src/root.zig` exposing the modules `main.zig` needs (this is a temporary bridge; Task 6 deletes most of `main.zig`'s direct use). Append to `src/root.zig` BEFORE the `test` block:
```zig
/// Internal modules the shipped binary's main() drives directly until the
/// comptime App(cfg) builder (Task 6) subsumes them. Not part of the stable API.
pub const @"internal" = struct {
    pub const app = @import("app.zig");
    pub const server = @import("server.zig");
    pub const cli = @import("cli.zig");
    pub const config = @import("config.zig");
    pub const migrations = @import("migrations.zig");
    pub const files_storage = @import("files/storage.zig");
    pub const crypto = @import("crypto.zig");
    pub const id = @import("id.zig");
};
```

Leave the bodies of `main()`, `runServe`, `runMigrate`, `runSuperuserCreate`, `printUsage`, `loadCfg`, `openPool` unchanged except that their references now resolve through these aliases (the alias names above match the existing `const` names in `main.zig`, so the function bodies need no edits).

- [ ] **Step 4: Build and run the full suite — expect green (no behavior change)**

Run:
```sh
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all
```
Expected: binary builds (EXIT 0); `209/209 tests passed`.

Then the Playwright suite:
```sh
cd /home/valthon/nothlav/zigbase && mise exec python@3.13 -- python -m pytest tests/admin -q
```
Expected: `10 passed`.

- [ ] **Step 5: Commit**

```sh
git add build.zig src/root.zig src/main.zig
git commit -m "refactor(framework): expose public zigbase module; binary consumes it

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: The `App` data facade (`Data`)

A connection-bound, curated record API. Hooks/routes/jobs use this instead of raw SQLite. Internally it wraps a `*db.Db` (the active connection) — that pointer is never exposed in a public signature.

**Files:**
- Create: `src/data.zig`
- Modify: `src/root.zig` (re-export `Data`)
- Test: in `src/data.zig` (`test {}` blocks, in-memory DB)

- [ ] **Step 1: Write the failing test**

Add to `src/data.zig`:
```zig
const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const records = @import("records.zig");
const migrations = @import("migrations.zig");

test "Data.create then findById round-trips a record" {
    const io = std.testing.io(); // Zig 0.16 test io
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrations.run(&conn);

    // Minimal collection: a single text field "title".
    try collections.createForTest(std.testing.allocator, &conn, "posts", &.{.{ .name = "title", .kind = .text }});

    const d = Data{ .app = undefined, .conn = &conn, .io = io };
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "title", .{ .string = "hello" });

    const created = try d.create("posts", .{ .object = obj });
    const id = created.object.get("id").?.string;

    const found = (try d.findById("posts", id)).?;
    try std.testing.expectEqualStrings("hello", found.object.get("title").?.string);
}
```
> Note: `collections.createForTest` is a helper you may need to add to `collections.zig` if no equivalent exists — check first; the existing test suite already creates collections in tests, so reuse that exact pattern (grep `test "` in `src/records.zig` for the established in-memory collection-creation idiom and mirror it). If a helper already exists, call it; do not invent a second one.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -30`
Expected: FAIL — `Data` undefined.

- [ ] **Step 3: Implement `Data`**

Prepend to `src/data.zig` (above the tests):
```zig
const App = @import("app.zig").App;

/// Connection-bound, curated record operations. Hooks, custom routes, and jobs
/// receive a `Data` rather than a raw connection. `conn` is the active connection:
/// for `before*` record hooks it is the in-transaction writer (so writes are
/// atomic with the triggering op); elsewhere it is a fresh acquired connection.
pub const Data = struct {
    app: *App,
    conn: *db.Db,
    io: std.Io,

    pub fn findById(self: Data, col_name: []const u8, id: []const u8) !?std.json.Value {
        const col = (try collections.get(self.app.allocator, self.conn, col_name)) orelse return null;
        return records.get(self.app.allocator, self.conn, col, id);
    }

    pub fn create(self: Data, col_name: []const u8, value: std.json.Value) !std.json.Value {
        const col = (try collections.get(self.app.allocator, self.conn, col_name)) orelse return error.UnknownCollection;
        return records.create(self.app.allocator, self.io, self.conn, col, value);
    }

    pub fn update(self: Data, col_name: []const u8, id: []const u8, value: std.json.Value) !?std.json.Value {
        const col = (try collections.get(self.app.allocator, self.conn, col_name)) orelse return error.UnknownCollection;
        return records.update(self.app.allocator, self.conn, col, id, value);
    }

    pub fn delete(self: Data, col_name: []const u8, id: []const u8) !bool {
        const col = (try collections.get(self.app.allocator, self.conn, col_name)) orelse return error.UnknownCollection;
        return records.delete(self.app.allocator, self.conn, col, id);
    }

    pub fn list(self: Data, col_name: []const u8, q: records.ListQuery) !records.ListResult {
        const col = (try collections.get(self.app.allocator, self.conn, col_name)) orelse return error.UnknownCollection;
        return records.list(self.app.allocator, self.conn, col, q);
    }
};
```
> Adjust `collections.get`'s exact signature to match `src/collections.zig` (the Explore map shows `collections.get(alloc, conn, name)`); the `records.*` signatures match the verbatim map (note `records.create` takes `io`, `records.update`/`get`/`delete`/`list` do not).

- [ ] **Step 4: Re-export from `src/root.zig`**

Add to the public API section of `src/root.zig`:
```zig
pub const Data = @import("data.zig").Data;
```
And add `_ = @import("data.zig");` to the `test {}` block.

- [ ] **Step 5: Run the test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -5`
Expected: PASS (test count = 209 + new).

- [ ] **Step 6: Build the binary (catches unreferenced-fn errors) and commit**

```sh
mise exec zig@0.16.0 -- zig build
git add src/data.zig src/root.zig src/collections.zig
git commit -m "feat(framework): connection-bound Data facade for record ops

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Event payloads + comptime hook config + the record dispatcher type

Define the record-event payload, the phase enum, the comptime hook-config shape, and the runtime type-erased `Dispatch` struct that the records path will call. The comptime→runtime generation of the dispatcher function lives here as a reusable `buildRecordDispatcher(comptime hooks)` so Task 6's `App(cfg)` just plugs it in.

**Files:**
- Create: `src/events.zig`
- Modify: `src/root.zig` (re-export event types)
- Test: in `src/events.zig`

- [ ] **Step 1: Write the failing test (dispatch ordering, wildcard-first, mutate, abort)**

Add to `src/events.zig`:
```zig
const std = @import("std");

test "record dispatcher fires wildcard then specific, in order, and mutations stick" {
    const Trace = struct {
        var seq: std.ArrayListUnmanaged([]const u8) = .empty;
        fn wild(ev: *RecordEvent) anyerror!void {
            try seq.append(std.testing.allocator, "wild");
            ev.record.object.putAssumeCapacity("touched", .{ .bool = true });
        }
        fn specific(ev: *RecordEvent) anyerror!void {
            try seq.append(std.testing.allocator, "specific");
            _ = ev;
        }
    };
    defer Trace.seq.deinit(std.testing.allocator);

    const hooks = .{
        .any = .{ .beforeCreate = Trace.wild },
        .posts = .{ .beforeCreate = Trace.specific },
    };
    const dispatch = buildRecordDispatcher(hooks);

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "touched", .{ .bool = false });
    var rec: std.json.Value = .{ .object = obj };
    var ev = RecordEvent{ .app = undefined, .ctx = undefined, .data = undefined, .collection = "posts", .record = &rec, .phase = .before_create };

    try dispatch(&ev);
    try std.testing.expectEqual(@as(usize, 2), Trace.seq.items.len);
    try std.testing.expectEqualStrings("wild", Trace.seq.items[0]);
    try std.testing.expectEqualStrings("specific", Trace.seq.items[1]);
    try std.testing.expect(rec.object.get("touched").?.bool == true);
}

test "before hook error aborts (propagates) and unrelated collection is skipped" {
    const H = struct {
        fn boom(ev: *RecordEvent) anyerror!void {
            _ = ev;
            return error.HookRejected;
        }
    };
    const dispatch = buildRecordDispatcher(.{ .posts = .{ .beforeCreate = H.boom } });

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    var rec: std.json.Value = .{ .object = obj };
    var ev = RecordEvent{ .app = undefined, .ctx = undefined, .data = undefined, .collection = "comments", .record = &rec, .phase = .before_create };
    try dispatch(&ev); // "comments" not registered -> no-op, no error

    ev.collection = "posts";
    try std.testing.expectError(error.HookRejected, dispatch(&ev));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -30`
Expected: FAIL — `RecordEvent`/`buildRecordDispatcher` undefined.

- [ ] **Step 3: Implement the payloads, phase enum, dispatcher builder, and `Dispatch`**

Prepend to `src/events.zig`:
```zig
const App = @import("app.zig").App;
const request = @import("request.zig");
const Data = @import("data.zig").Data;

pub const RecordPhase = enum {
    before_create, after_create,
    before_update, after_update,
    before_delete, after_delete,
};

pub const RecordEvent = struct {
    app: *App,
    ctx: *const request.RequestContext,
    data: Data,
    collection: []const u8,
    record: *std.json.Value, // mutable in before_*; the persisted record in after_*
    phase: RecordPhase,
};

pub const ErrorPhase = enum { request, before_hook, after_hook, cron, job, file_serve };

pub const ErrorEvent = struct {
    app: *App,
    ctx: ?*const request.RequestContext,
    err: anyerror,
    phase: ErrorPhase,
    message: []const u8,
};

pub const RecordHandler = *const fn (ev: *RecordEvent) anyerror!void;
pub const ErrorHandler = *const fn (ev: *ErrorEvent) void;

/// Runtime, type-erased dispatch surface stored on `App`. The comptime App(cfg)
/// builder fills these with generated functions; null = no subscribers.
pub const Dispatch = struct {
    record: ?RecordHandler = null,
    on_error: ?ErrorHandler = null,
    // routes + cron added in plan 10b
};

fn phaseField(comptime phase: RecordPhase) []const u8 {
    return switch (phase) {
        .before_create => "beforeCreate",
        .after_create => "afterCreate",
        .before_update => "beforeUpdate",
        .after_update => "afterUpdate",
        .before_delete => "beforeDelete",
        .after_delete => "afterDelete",
    };
}

/// Generate a record dispatcher from a comptime hook config of the shape:
///   .{ .any = .{ .beforeCreate = fn, ... }, .<collection> = .{ .afterUpdate = fn, ... } }
/// `any` (wildcard) handlers fire first, then the collection-specific handler
/// whose field name equals `ev.collection`. Handlers fire in declaration order.
pub fn buildRecordDispatcher(comptime hooks: anytype) RecordHandler {
    const Hooks = @TypeOf(hooks);
    const gen = struct {
        fn dispatch(ev: *RecordEvent) anyerror!void {
            inline for (.{ true, false }) |wildcard_pass| {
                inline for (std.meta.fields(Hooks)) |group| {
                    const is_wild = comptime std.mem.eql(u8, group.name, "any");
                    if (wildcard_pass != is_wild) continue;
                    if (!is_wild and !std.mem.eql(u8, ev.collection, group.name)) continue;
                    const group_val = @field(hooks, group.name);
                    switch (ev.phase) {
                        inline else => |p| {
                            const fname = comptime phaseField(p);
                            if (@hasField(@TypeOf(group_val), fname)) {
                                if (ev.phase == p) try @field(group_val, fname)(ev);
                            }
                        },
                    }
                }
            }
        }
    };
    return gen.dispatch;
}
```
> The `inline for (.{true,false})` gives the two passes (wildcard first). The `switch (ev.phase) { inline else => |p| … }` resolves the per-phase field name at comptime while matching the runtime phase. If the Zig compiler rejects `@hasField` on the anonymous-struct type, switch to `@hasField(@TypeOf(group_val), fname)` guarded by `comptime` — adjust during TDD until it compiles; the SEMANTICS the tests pin are: wildcard-first, declaration order, only the matching phase's handler runs, errors propagate.

- [ ] **Step 4: Re-export and reference for tests**

In `src/root.zig` public section:
```zig
pub const events = @import("events.zig");
pub const RecordEvent = events.RecordEvent;
pub const ErrorEvent = events.ErrorEvent;
```
And `_ = @import("events.zig");` in the `test {}` block.

- [ ] **Step 5: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 6: Build binary + commit**

```sh
mise exec zig@0.16.0 -- zig build
git add src/events.zig src/root.zig
git commit -m "feat(framework): record event payloads + comptime dispatcher builder

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Error event + Sentry-or-log backstop

A minimal Sentry envelope serializer (tested by building, not sending) and the backstop that runs after any consumer `onError` handler. Add `sentry_dsn` to `Config` + `App`.

**Files:**
- Create: `src/sentry.zig`
- Modify: `src/config.zig:3-14` (add `sentry_dsn`), `src/config.zig:17-31` (load it)
- Modify: `src/app.zig` (add `sentry_dsn` field)
- Modify: `src/events.zig` (add `dispatchError` that runs consumer handler then backstop)
- Test: in `src/sentry.zig` and `src/events.zig`

- [ ] **Step 1: Write the failing test for the envelope serializer**

Add to `src/sentry.zig`:
```zig
const std = @import("std");

test "buildEnvelope produces a valid Sentry envelope with the message" {
    const out = try buildEnvelope(std.testing.allocator,
        "https://pub@o1.ingest.sentry.io/42", "boom: error.HookRejected", "error");
    defer std.testing.allocator.free(out.body);
    // Envelope = header line, item header line, item payload line (3 newlines-separated JSON docs).
    var it = std.mem.splitScalar(u8, out.body, '\n');
    const hdr = it.next().?;
    try std.testing.expect(std.mem.indexOf(u8, hdr, "\"dsn\"") != null);
    _ = it.next().?; // item header
    const payload = it.next().?;
    try std.testing.expect(std.mem.indexOf(u8, payload, "boom: error.HookRejected") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"level\":\"error\"") != null);
    // Ingest URL derived from the DSN.
    try std.testing.expectEqualStrings("https://o1.ingest.sentry.io/api/42/envelope/", out.url);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -20`
Expected: FAIL — `buildEnvelope` undefined.

- [ ] **Step 3: Implement the serializer + the send + the backstop**

Prepend to `src/sentry.zig`:
```zig
const App = @import("app.zig").App;

pub const Envelope = struct { url: []const u8, auth_header: []const u8, body: []const u8 };

/// Parse a DSN `https://<pubkey>@<host>/<project>` into the envelope ingest URL.
fn ingestUrl(alloc: std.mem.Allocator, dsn: []const u8) ![]const u8 {
    const at = std.mem.indexOfScalar(u8, dsn, '@') orelse return error.BadDsn;
    const scheme_end = std.mem.indexOf(u8, dsn, "://") orelse return error.BadDsn;
    const scheme = dsn[0..scheme_end];
    const after_at = dsn[at + 1 ..]; // host/project
    const slash = std.mem.lastIndexOfScalar(u8, after_at, '/') orelse return error.BadDsn;
    const host = after_at[0..slash];
    const project = after_at[slash + 1 ..];
    return std.fmt.allocPrint(alloc, "{s}://{s}/api/{s}/envelope/", .{ scheme, host, project });
}

fn publicKey(dsn: []const u8) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, dsn, "://") orelse return error.BadDsn;
    const rest = dsn[scheme_end + 3 ..];
    const at = std.mem.indexOfScalar(u8, rest, '@') orelse return error.BadDsn;
    return rest[0..at];
}

pub fn buildEnvelope(alloc: std.mem.Allocator, dsn: []const u8, message: []const u8, level: []const u8) !Envelope {
    const url = try ingestUrl(alloc, dsn);
    const key = try publicKey(dsn);
    const header = try std.fmt.allocPrint(alloc, "{{\"dsn\":\"{s}\"}}", .{dsn});
    // event payload
    var payload_obj: std.json.ObjectMap = .empty;
    try payload_obj.put(alloc, "message", .{ .string = message });
    try payload_obj.put(alloc, "level", .{ .string = level });
    try payload_obj.put(alloc, "platform", .{ .string = "other" });
    const payload = try std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = payload_obj }, .{});
    const item_header = try std.fmt.allocPrint(alloc, "{{\"type\":\"event\",\"length\":{d}}}", .{payload.len});
    const body = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ header, item_header, payload });
    const auth_header = try std.fmt.allocPrint(alloc, "Sentry sentry_version=7, sentry_key={s}", .{key});
    return .{ .url = url, .auth_header = auth_header, .body = body };
}

/// The default error backstop: report to Sentry if a DSN is set, else log.
/// Always swallows — never propagates.
pub fn backstop(app: *App, message: []const u8) void {
    if (app.sentry_dsn.len == 0) {
        std.log.err("zigbase error: {s}", .{message});
        return;
    }
    report(app, message) catch |e| {
        std.log.err("zigbase error (sentry report failed: {s}): {s}", .{ @errorName(e), message });
    };
}

fn report(app: *App, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try buildEnvelope(a, app.sentry_dsn, message, "error");
    var client = std.http.Client{ .allocator = a, .io = app.io };
    defer client.deinit();
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    _ = client.fetch(.{
        .location = .{ .url = env.url },
        .method = .POST,
        .payload = env.body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-sentry-envelope" },
            .{ .name = "x-sentry-auth", .value = env.auth_header },
        },
        .response_writer = &sink.writer,
    }) catch {};
}
```
> The exact `std.http.Client.fetch` option names come from the OAuth client (`src/oauth/client.zig`'s `httpTransport`) — mirror that file's working 0.16 call shape verbatim rather than the sketch above if they differ. The unit test only exercises `buildEnvelope` (no network).

- [ ] **Step 4: Add `sentry_dsn` to Config, App, and the loader**

In `src/config.zig` `Config` struct, after `file_token_ttl_s`:
```zig
    sentry_dsn: []const u8 = "", // "" = log errors to stderr; set to enable Sentry reporting
```
In `Config.load`, before `return cfg;`:
```zig
    if (getter("ZIGBASE_SENTRY_DSN")) |v| cfg.sentry_dsn = v;
```
In `src/app.zig` `App` struct, after `file_token_ttl_s`:
```zig
    sentry_dsn: []const u8 = "",
```
In `src/main.zig` `runServe`'s `app_mod.App{ … }` literal, add:
```zig
        .sentry_dsn = cfg.sentry_dsn,
```

- [ ] **Step 5: Add `dispatchError` to events.zig (consumer-first, backstop-last)**

Add to `src/events.zig`:
```zig
const sentry = @import("sentry.zig");

/// Route a framework-caught error: run the consumer onError handler (if any),
/// then the built-in Sentry-or-log backstop. Never propagates.
pub fn dispatchError(app: *App, dispatch: ?*const Dispatch, ev: *ErrorEvent) void {
    if (dispatch) |d| {
        if (d.on_error) |h| h(ev);
    }
    sentry.backstop(app, ev.message);
}
```
Add a test in `src/events.zig`:
```zig
test "dispatchError runs consumer handler before the backstop" {
    const H = struct {
        var called: bool = false;
        fn onErr(ev: *ErrorEvent) void {
            _ = ev;
            called = true;
        }
    };
    H.called = false;
    var app: App = undefined;
    app.allocator = std.testing.allocator;
    app.sentry_dsn = ""; // backstop just logs
    var d = Dispatch{ .on_error = H.onErr };
    var ev = ErrorEvent{ .app = &app, .ctx = null, .err = error.Boom, .phase = .after_hook, .message = "x" };
    dispatchError(&app, &d, &ev);
    try std.testing.expect(H.called);
}
```

- [ ] **Step 6: Run tests + build + commit**

```sh
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -5
mise exec zig@0.16.0 -- zig build
git add src/sentry.zig src/config.zig src/app.zig src/events.zig src/main.zig
git commit -m "feat(framework): error event with consumer-first Sentry-or-log backstop

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Emit record lifecycle events from the write path

Wire `before*` (inside the tx, mutate/abort) and `after*` (post-commit, errors→backstop) into `src/api/records.zig` create/update/delete, before `broadcast`. The dispatcher is read from `app.dispatch`.

**Files:**
- Modify: `src/app.zig` (add `dispatch` field)
- Modify: `src/api/records.zig` (create/update/delete)
- Test: `tests/admin/test_hooks.py` (Playwright, behavioral) — see note on driving hooks below.

> **Why Playwright here:** before/after-hook behavior is only observable through a configured app with real collections + HTTP. The cleanest behavioral proof is the example app (Task 7) exercised end-to-end. For this task, add the emit calls and pin them with a Zig integration test that builds a tiny in-process dispatcher and an in-memory DB, OR defer the behavioral assertion to Task 7's example test. This plan uses a focused Zig integration test (no HTTP) to keep Task 5 self-contained, then Task 7 adds the e2e.

- [ ] **Step 1: Add `dispatch` to the runtime `App`**

In `src/app.zig` `App` struct, after `storage`:
```zig
    /// Type-erased event dispatch built by the comptime App(cfg) builder; null = no subscribers.
    dispatch: ?*const @import("events.zig").Dispatch = null,
```

- [ ] **Step 2: Write the failing integration test (before-hook mutates + aborts; after-hook fires)**

Create `src/records_hooks_test.zig` and reference it from `root.zig`'s `test {}` block (`_ = @import("records_hooks_test.zig");`). Content:
```zig
const std = @import("std");
const db = @import("db.zig");
const app_mod = @import("app.zig");
const events = @import("events.zig");
const records = @import("records.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const request = @import("request.zig");

// These tests call the SAME emit helper the API path uses, so they pin the
// before-mutate / before-abort / after-fire contract without spinning up HTTP.
test "emitRecord before_create mutation is visible to the subsequent insert" {
    const H = struct {
        fn stampTitle(ev: *events.RecordEvent) anyerror!void {
            try ev.record.object.put(ev.app.allocator, "title", .{ .string = "stamped" });
        }
    };
    var dispatch = events.Dispatch{ .record = events.buildRecordDispatcher(.{ .posts = .{ .beforeCreate = H.stampTitle } }) };
    // ... build app + in-memory db + "posts" collection (mirror Data test setup) ...
    // call emitRecord(app, &rctx, conn, "posts", &value, .before_create)
    // assert value.object.get("title").?.string == "stamped"
    _ = &dispatch;
}
```
> Fill in the app/db/collection setup by mirroring Task 2's `Data` test. The assertion: after `emitRecord(..., .before_create)`, the JSON value carries the hook's mutation. Add a second test that a `before_create` hook returning `error.X` makes `emitRecord` return that error.

- [ ] **Step 3: Add the `emitRecord` helper and call it from create/update/delete**

Add to `src/api/records.zig` (near the top, after imports):
```zig
const events = @import("../events.zig");

/// Fire a record lifecycle event. `before_*` errors propagate (caller rolls back);
/// `after_*` errors are routed to the error backstop and swallowed.
fn emitRecord(
    app: *app_mod.App,
    rctx: *const request.RequestContext,
    conn: *db.Db,
    col_name: []const u8,
    value: *std.json.Value,
    phase: events.RecordPhase,
) !void {
    const d = app.dispatch orelse return;
    const handler = d.record orelse return;
    var ev = events.RecordEvent{
        .app = app,
        .ctx = rctx,
        .data = .{ .app = app, .conn = conn, .io = app.io },
        .collection = col_name,
        .record = value,
        .phase = phase,
    };
    const is_before = switch (phase) {
        .before_create, .before_update, .before_delete => true,
        else => false,
    };
    if (is_before) {
        try handler(&ev);
    } else {
        handler(&ev) catch |e| {
            var err_ev = events.ErrorEvent{ .app = app, .ctx = rctx, .err = e, .phase = .after_hook, .message = @errorName(e) };
            events.dispatchError(app, app.dispatch, &err_ev);
        };
    }
}
```
> `app_mod`, `db`, `request` are already imported in `api/records.zig` (the Explore map shows them in use). Confirm the import alias names and reuse them.

In `create` (around the existing `buildContext`/`records.create` block): after `rctx` is built and `data2` is prepared, but BEFORE the `records.create`/`createGuarded` call, add:
```zig
    var mutable = data2;
    try emitRecord(app, &rctx, w, col.name, &mutable, .before_create);
```
and pass `mutable` instead of `data2` into `records.create`/`createGuarded`. Wrap the `before` emit error into the existing `catch |e| switch (e)` mapping by adding an arm: a hook error surfaces as `error.HookRejected` → return `ApiError.badRequest("Request rejected by a hook.")` (or reuse the validation response). After the successful insert + `writeUploads`, and BEFORE `realtime_ws.broadcast`, add:
```zig
    {
        var rec_mut = rec;
        try emitRecord(app, &rctx, w, col.name, &rec_mut, .after_create);
    }
```
Apply the symmetric changes to `update` (`.before_update` before the update call on the parsed body; `.after_update` after success, before broadcast) and `delete` (`.before_delete` before `records.delete` — pass the loaded record if available, else an object with just `id`; `.after_delete` after success, before broadcast). For delete, load the record first (`records.get`) so the hook sees it; if already loaded for the broadcast path, reuse it.

> Keep all emits INSIDE the `acquireWriter`/`releaseWriter` scope so `before_*` runs in the same writer (atomic) and `after_*` runs after the guard's `commit()` but while the writer is still held — that's fine because `after` hooks use the same `Data`/connection and the realtime broadcast already runs there.

- [ ] **Step 4: Run the integration tests + full suite + binary**

```sh
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8
mise exec zig@0.16.0 -- zig build
mise exec python@3.13 -- python -m pytest tests/admin -q
```
Expected: new hook tests pass; existing 209 + 10 stay green (no dispatcher configured by default ⇒ emits are no-ops).

- [ ] **Step 5: Commit**

```sh
git add src/app.zig src/api/records.zig src/records_hooks_test.zig src/root.zig
git commit -m "feat(framework): emit record lifecycle events around the write path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: The comptime `App(cfg)` builder + `main.zig` refactor

Add `pub fn App(comptime cfg: Cfg) type` exposing `run(init)` / `runCli(init)`. It builds the `Dispatch` from `cfg.hooks` and threads it onto the runtime `app.App`, reusing the existing serve/migrate/superuser wiring. Then collapse `src/main.zig` to a thin consumer.

**Files:**
- Create: `src/framework.zig`
- Modify: `src/root.zig` (export `App` = the builder; keep the runtime struct as `Runtime`)
- Modify: `src/main.zig` (becomes thin)
- Test: existing suite stays green; add one Zig test that `App(.{ .hooks = … }).Dispatch` is non-null and `App(.{}).Dispatch` record handler is null.

- [ ] **Step 1: Resolve the `App` name**

The public builder must be `zigbase.App(...)` (a function). The runtime context struct is currently `app.App`. In `src/root.zig`, expose the runtime struct under a different public name and make `App` the builder:
```zig
pub const Runtime = @import("app.zig").App; // the runtime context (was publicly App)
pub const App = @import("framework.zig").App; // the comptime builder
```
Internal modules keep importing `@import("app.zig").App` directly — unaffected.

- [ ] **Step 2: Write the failing test**

Add to `src/framework.zig`:
```zig
const std = @import("std");

test "App(cfg) builds a record dispatcher only when hooks are present" {
    const Empty = App(.{});
    try std.testing.expect(Empty.dispatch.record == null);

    const H = struct {
        fn f(ev: *@import("events.zig").RecordEvent) anyerror!void {
            _ = ev;
        }
    };
    const WithHook = App(.{ .hooks = .{ .posts = .{ .afterCreate = H.f } } });
    try std.testing.expect(WithHook.dispatch.record != null);
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -20`
Expected: FAIL — `App` undefined in `framework.zig`.

- [ ] **Step 4: Implement the builder**

Prepend to `src/framework.zig`:
```zig
const app_mod = @import("app.zig");
const events = @import("events.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const server = @import("server.zig");
const migrations = @import("migrations.zig");
const files_storage = @import("files/storage.zig");

pub const Cfg = struct {
    hooks: ?type = null, // an anonymous struct literal value, not a type; see note
};

/// Comptime application builder. `cfg` is an anonymous struct with optional
/// `.hooks` (record hook groups). Returns a type exposing the prebuilt dispatch
/// and the CLI entry points.
pub fn App(comptime cfg: anytype) type {
    return struct {
        /// Prebuilt at comptime from cfg; stored onto the runtime app at startup.
        pub const dispatch: events.Dispatch = blk: {
            var d = events.Dispatch{};
            if (@hasField(@TypeOf(cfg), "hooks")) {
                d.record = events.buildRecordDispatcher(cfg.hooks);
            }
            if (@hasField(@TypeOf(cfg), "onError")) {
                d.on_error = cfg.onError;
            }
            break :blk d;
        };

        /// Parse argv and dispatch the CLI (serve / migrate / superuser create / help),
        /// wiring this app's `dispatch` into the runtime context for `serve`.
        pub fn runCli(init: std.process.Init) !void {
            return runCliImpl(init, &dispatch);
        }

        /// Start the HTTP server directly with an explicit config (no CLI parsing).
        pub fn run(init: std.process.Init, cfg_runtime: config.Config) !void {
            return serveImpl(init.gpa, init.io, cfg_runtime, &dispatch);
        }
    };
}
```
Then move the CLI/serve logic out of `main.zig` into `framework.zig` as `runCliImpl`, `serveImpl`, `migrateImpl`, `superuserCreateImpl`, `printUsage`, `loadCfg`, `openPool` — copied verbatim from the current `src/main.zig` bodies (they already exist and are tested by the Playwright suite), with two changes:
1. `serveImpl` accepts `dispatch: *const events.Dispatch` and sets `.dispatch = dispatch` on the `app_mod.App{ … }` literal.
2. `runCliImpl` threads `dispatch` through to `serveImpl` for the `.serve` arm.

> The `Cfg`/`@hasField(@TypeOf(cfg), "hooks")` handling above treats `cfg` as a VALUE (anonymous struct literal), not a type — `cfg.hooks` is itself an anonymous struct of hook groups. Use `@hasField(@TypeOf(cfg), "hooks")` to detect presence and `cfg.hooks` to read it. Delete the placeholder `Cfg` struct if the `anytype` value form is used (it is). Keep iterating until `App(.{})` and `App(.{ .hooks = … })` both compile.

- [ ] **Step 5: Collapse `src/main.zig`**

Replace the entire `src/main.zig` with:
```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// The shipped binary is the framework with no extensions registered.
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{}).runCli(init);
}
```
Remove the now-obsolete `@"internal"` bridge from `src/root.zig` (added in Task 1) since `main.zig` no longer needs it — UNLESS other consumers reference it; grep first. Keep `root.zig`'s public exports and `test {}` block.

- [ ] **Step 6: Run the full suite + binary + Playwright**

```sh
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec python@3.13 -- python -m pytest tests/admin -q
```
Expected: binary builds; `211+/… passed`; `10 passed`. The shipped binary behaves identically (empty dispatch ⇒ emits are no-ops).

- [ ] **Step 7: Commit**

```sh
git add src/framework.zig src/root.zig src/main.zig
git commit -m "feat(framework): comptime App(cfg) builder; binary is now App(.{})

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Example consumer app (`examples/blog`) — the packaging proof

A standalone package that depends on this repo and `@import("zigbase")`, registering a record hook. Building it proves the SQLite-C + zap graph travels through the module to a downstream consumer.

**Files:**
- Create: `examples/blog/build.zig.zon`
- Create: `examples/blog/build.zig`
- Create: `examples/blog/src/main.zig`
- Create: `examples/blog/README.md`

- [ ] **Step 1: Create the example's `build.zig.zon` (path dependency on the repo)**

`examples/blog/build.zig.zon`:
```zig
.{
    .name = .zigbase_blog_example,
    .version = "0.0.0",
    .fingerprint = 0x1a2b3c4d5e6f7081, // any stable random 64-bit value
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zigbase = .{ .path = "../.." },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```
> The README documents the real `zig fetch --save git+https://github.com/<owner>/zigbase` form; the example uses a `.path` dep so CI builds it against the working tree.

- [ ] **Step 2: Create the example's `build.zig`**

`examples/blog/build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
    exe_mod.addImport("zigbase", zigbase.module("zigbase"));

    const exe = b.addExecutable(.{ .name = "blog", .root_module = exe_mod });
    b.installArtifact(exe);
}
```

- [ ] **Step 3: Create the example app registering a record hook**

`examples/blog/src/main.zig`:
```zig
const std = @import("std");
const zigbase = @import("zigbase");

/// before_create on "posts": stamp a slug derived from the title if absent.
fn slugify(ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.object.get("slug") != null) return;
    const title = if (ev.record.object.get("title")) |t| switch (t) {
        .string => |s| s,
        else => return,
    } else return;
    const buf = try ev.app.allocator.alloc(u8, title.len);
    for (title, 0..) |ch, i| buf[i] = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '-';
    try ev.record.object.put(ev.app.allocator, "slug", .{ .string = buf });
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
    }).runCli(init);
}
```

- [ ] **Step 4: Create `examples/blog/README.md`**

`examples/blog/README.md`:
```markdown
# ZigBase example: blog

A minimal app built on ZigBase as a library. It registers a `before_create`
hook on the `posts` collection that derives a URL slug from the title.

## In your own project

\```sh
zig fetch --save git+https://github.com/<owner>/zigbase
\```

Then in `build.zig`:

\```zig
const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zigbase.module("zigbase"));
\```

## Build & run this example

\```sh
mise exec zig@0.16.0 -- zig build           # from examples/blog/
./zig-out/bin/blog superuser create --email you@example.com --password <pw> --data-dir ./data
./zig-out/bin/blog serve --data-dir ./data
\```
```

- [ ] **Step 5: Build the example against the working tree**

```sh
cd /home/valthon/nothlav/zigbase/examples/blog
mise exec zig@0.16.0 -- zig build
ls zig-out/bin/blog
```
Expected: builds (EXIT 0); `zig-out/bin/blog` exists. This is the packaging proof — the SQLite C + zap graph compiled transitively through the `zigbase` module.

- [ ] **Step 6: Add the example build to `.gitignore` and commit**

Append to `.gitignore`:
```
examples/*/zig-out/
examples/*/.zig-cache/
examples/*/data/
```
Commit:
```sh
cd /home/valthon/nothlav/zigbase
git add examples/blog .gitignore
git commit -m "test(framework): examples/blog consumer proves the dependency build graph

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Final review pass

- [ ] **Step 1: Full green gate**

```sh
cd /home/valthon/nothlav/zigbase
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec python@3.13 -- python -m pytest tests/admin -q
cd examples/blog && mise exec zig@0.16.0 -- zig build && cd ../..
```
Expected: binary green; all Zig tests pass; `10 passed`; example builds.

- [ ] **Step 2: Holistic review (dispatch this to a fresh code-review subagent)**

Review the full 10a diff (`git diff main..extensibility-framework -- ':!docs'`) for: the module-graph change (no double-compilation of internal files; tests still rooted correctly), the comptime dispatcher (wildcard-first + declaration order + only-matching-phase), the before/after transaction ordering (before inside tx & mutations reach the insert; after post-commit & swallowed), the `Data` facade never leaking raw `*db.Db` in a public signature, and the Sentry backstop never propagating. Confirm the shipped `App(.{})` is byte-for-byte behavior-identical (empty dispatch ⇒ no-op emits).

- [ ] **Step 3: Address any findings, re-run the gate, then stop**

10a ends here. Routes + scheduler/pool + auth/file/lifecycle events are **Plan 10b**; release engineering is **Plan 10c**. Do NOT merge to `main` until 10b lands (the framework branch carries both), unless directed otherwise.

---

## Self-Review (plan author)

**Spec coverage (§1–§2, §5 of the spec):**
- §1 architecture (event bus + App facade + comptime registration + single `zigbase` module + binary = `App(.{})`) → Tasks 1, 2, 3, 6. ✓
- §1 file layout (root/app/events/cron/framework) → cron is 10b; root/app/events/framework here. ✓
- §2 record events + before/after semantics + wildcard + ordering vs rules/broadcast → Tasks 3, 5. ✓
- §2 error event + Sentry-or-log backstop + consumer-first → Task 4. ✓
- §5 testing: injectable pieces + example consumer in CI → Tasks 2–7; CI workflow itself is 10c. ✓
- Auth/file/lifecycle events, custom routes, scheduler → **deferred to 10b** (explicitly, by design). ✓

**Placeholder scan:** No "TBD"/"handle edge cases". Two flagged adaptation points (the comptime `@hasField`/phase-switch shape in Task 3; the exact `std.http.Client.fetch` option names in Task 4) name the authoritative source to copy from and the invariant the tests pin — not vague placeholders.

**Type consistency:** `events.Dispatch{ record, on_error }`, `RecordEvent{ app, ctx, data, collection, record, phase }`, `RecordPhase` variants, `buildRecordDispatcher(hooks) RecordHandler`, `Data{ app, conn, io }`, `App.dispatch` field, and the `App(cfg)`/`Runtime` split are used consistently across Tasks 2–7. The runtime struct is `Runtime` publicly (Task 6) while internal code keeps `@import("app.zig").App`.
