# ZigBase SP2 Plan 2b: Collections REST + Foundation Refactors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the collections engine over an (unprotected) REST API by enacting the Foundation forward-looking refactors: an `App` context threaded through `RequestCtx`, a real path-param router, an extended JSON error envelope, request/response (de)serialization for collections, and `serve`/`migrate` CLI wiring.

**Architecture:** `zap → server.onRequest (build RequestCtx{app}) → router.dispatch (captures :params) → pure handler → collections engine → db`. Handlers stay pure `(*RequestCtx)->Response`; `server.zig` remains the only zap-aware module. Built on Plan 2a's engine (`collections.zig`, `schema.zig`, etc.).

**Tech Stack:** Zig 0.16.0 (mise), zap, the 2a engine, `std.json`.

---

## Toolchain (read once)
Run zig via the pinned toolchain from repo root: `mise exec zig@0.16.0 -- zig <args>`. Do NOT use `mise -C`.

## Verified 0.16 facts (grounding)
- `std.ArrayList(T)` is unmanaged: `var x: std.ArrayList(T) = .empty;`, `try x.append(alloc, v)`, `x.toOwnedSlice(alloc)`.
- `std.json`: `parseFromSlice(std.json.Value, alloc, s, .{})` → `.value` tree; `Value = union(enum){ null,bool,integer:i64,float:f64,number_string:[]const u8,string:[]const u8,array,object }`; `ObjectMap` is unmanaged (`var o: std.json.ObjectMap = .empty; try o.put(alloc, k, v);`); `Array` is managed (`var a = std.json.Array.init(alloc); try a.append(v);`); serialize with `std.json.Stringify.valueAlloc(alloc, value, .{})`.
- `std.mem.splitScalar(u8, s, '/')` returns an iterator with `.next() ?[]const u8`.
- zap (confirmed working): handler `fn(zap.Request) !void`; `r.setStatus(zap.http.StatusCode)` tags include `.ok,.created,.no_content,.bad_request,.not_found,.conflict,.unprocessable_entity,.internal_server_error`; `r.methodAsEnum()`, `r.setContentType(.JSON)`, `r.sendBody`.
- Engine (2a) API: `collections.create(alloc, io, *db.Db, def) EngineError!Collection`, `get(alloc,*db.Db,idOrName) !?Collection`, `list(alloc,*db.Db) ![]Collection`, `update(alloc, io, *db.Db, idOrName, def) !Collection`, `delete(alloc,*db.Db,idOrName) !void`; `EngineError` includes `Validation,NotFound,Conflict`; `collections.last_errors: ?[]const schema.ValidationError` holds details after `error.Validation`.
- `db.Pool`: `acquireWriter() *db.Db` (locks), `releaseWriter()`, `openReader()`. Engine ops use the writer.
- 35 tests currently pass on branch `collections-engine`.

## File Structure
| File | Change |
|---|---|
| `src/api/error.zig` | extend `ApiError` with field-level `data` + constructors (`badRequest`,`conflict`,`validation`) |
| `src/app.zig` | NEW — `App{ allocator, io, pool }` |
| `src/http.zig` | `RequestCtx` gains `app: ?*App`, `params`, `param()`; add `Param` |
| `src/router.zig` | NEW — `Route`, `matchPath`, `dispatch` |
| `src/schema.zig` | add `parseCollectionInput`, `collectionToJson` |
| `src/api/collections.zig` | NEW — REST handlers (unprotected) |
| `src/server.zig` | hold `app`; route table; dispatch via router; extend `setZapStatus` |
| `src/cli.zig` | add `migrate` command |
| `src/main.zig` | build `App`, run migrations on `serve`, handle `migrate` |

---

## Task 1: Extend the error envelope

**Files:** Modify `src/api/error.zig`.

- [ ] **Step 1: Replace the body of `src/api/error.zig` with:**

```zig
const std = @import("std");
const http = @import("../http.zig");

pub const FieldError = struct { field: []const u8, code: []const u8, message: []const u8 };

/// A renderable API error. Envelope: {code, message, data:{<field>:{code,message}}}.
pub const ApiError = struct {
    status: u16,
    message: []const u8,
    fields: []const FieldError = &.{},

    pub fn notFound() ApiError {
        return .{ .status = 404, .message = "Not found." };
    }
    pub fn internal() ApiError {
        return .{ .status = 500, .message = "Something went wrong." };
    }
    pub fn badRequest(message: []const u8) ApiError {
        return .{ .status = 400, .message = message };
    }
    pub fn conflict(message: []const u8) ApiError {
        return .{ .status = 409, .message = message };
    }
    pub fn validation(fields: []const FieldError) ApiError {
        return .{ .status = 400, .message = "Failed to validate the request.", .fields = fields };
    }

    pub fn renderBody(self: ApiError, alloc: std.mem.Allocator) ![]u8 {
        var data: std.json.ObjectMap = .empty;
        for (self.fields) |fe| {
            var fo: std.json.ObjectMap = .empty;
            try fo.put(alloc, "code", .{ .string = fe.code });
            try fo.put(alloc, "message", .{ .string = fe.message });
            try data.put(alloc, fe.field, .{ .object = fo });
        }
        var root: std.json.ObjectMap = .empty;
        try root.put(alloc, "code", .{ .integer = @intCast(self.status) });
        try root.put(alloc, "message", .{ .string = self.message });
        try root.put(alloc, "data", .{ .object = data });
        return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
    }

    pub fn toResponse(self: ApiError, alloc: std.mem.Allocator) !http.Response {
        return .{ .status = self.status, .body = try self.renderBody(alloc) };
    }
};

test "renders empty-data envelope" {
    const body = try ApiError.notFound().renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}",
        body,
    );
}

test "renders validation field errors" {
    const fields = [_]FieldError{.{ .field = "name", .code = "validation_invalid_name", .message = "Invalid." }};
    const body = try ApiError.validation(&fields).renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"code\":400,\"message\":\"Failed to validate the request.\",\"data\":{\"name\":{\"code\":\"validation_invalid_name\",\"message\":\"Invalid.\"}}}",
        body,
    );
}
```

- [ ] **Step 2: Run** `mise exec zig@0.16.0 -- zig build test`. Expect PASS. If `std.json.ObjectMap`/`Value` serialization orders keys differently (it preserves insertion order, so the expected strings should match), capture the actual output from the failing assertion and reconcile — the key insertion order above (code, message, data) is intentional.

- [ ] **Step 3: Commit**
```bash
git add src/api/error.zig
git commit -m "feat(api): error envelope with field-level validation data"
```

---

## Task 2: `App` context + `RequestCtx` extension

**Files:** Create `src/app.zig`; Modify `src/http.zig`; Modify `src/main.zig` (aggregate).

- [ ] **Step 1: Create `src/app.zig`**

```zig
const std = @import("std");
const db = @import("db.zig");

/// Shared request-handling state. `io` supplies entropy for id generation;
/// `pool` is the SQLite connection pool. Config/auth are added in later sub-projects.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *db.Pool,
};
```

- [ ] **Step 2: Replace `src/http.zig` with:**

```zig
const std = @import("std");
const App = @import("app.zig").App;

pub const Method = enum { GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD, UNKNOWN };

pub const Param = struct { key: []const u8, value: []const u8 };

pub const RequestCtx = struct {
    method: Method,
    path: []const u8,
    query: []const u8 = "",
    body: []const u8 = "",
    allocator: std.mem.Allocator,
    /// Present for real requests; null in pure-handler unit tests that don't need the DB.
    app: ?*App = null,
    /// Path params captured by the router (e.g. ":id").
    params: []const Param = &.{},

    pub fn param(self: *const RequestCtx, name: []const u8) ?[]const u8 {
        for (self.params) |p| {
            if (std.mem.eql(u8, p.key, name)) return p.value;
        }
        return null;
    }
};

pub const Response = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    body: []const u8, // allocated in the request arena
};

pub const Handler = *const fn (ctx: *RequestCtx) anyerror!Response;

test "param lookup" {
    const params = [_]Param{ .{ .key = "id", .value = "abc" }, .{ .key = "x", .value = "y" } };
    var ctx = RequestCtx{ .method = .GET, .path = "/", .allocator = std.testing.allocator, .params = &params };
    try std.testing.expectEqualStrings("abc", ctx.param("id").?);
    try std.testing.expect(ctx.param("missing") == null);
}
```

- [ ] **Step 3: Aggregate** — add `_ = @import("app.zig");` to the `test {}` block in `src/main.zig`. (`http.zig` has no module-level import line in main's aggregator; its `param` test runs because `server.zig`/others import it — but add `_ = @import("http.zig");` to be safe.)

- [ ] **Step 4: Run** `mise exec zig@0.16.0 -- zig build test`. This WILL fail to compile `src/server.zig` and `src/api/health.zig` if they construct `RequestCtx` without the new optional fields — but both new fields have defaults (`app = null`, `params = &.{}`), so existing construction sites still compile. Confirm PASS. If `server.zig`'s `route` test or health test breaks, it's because of a non-defaulted field — verify both new fields have defaults.

- [ ] **Step 5: Commit**
```bash
git add src/app.zig src/http.zig src/main.zig
git commit -m "feat(http): App context and RequestCtx params"
```

---

## Task 3: `router.zig`

**Files:** Create `src/router.zig`; Modify `src/main.zig` (aggregate).

- [ ] **Step 1: Write tests first** in `src/router.zig`:

```zig
const std = @import("std");
const http = @import("http.zig");

test "matchPath: literal match yields empty params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = (try matchPath(arena.allocator(), "/api/collections", "/api/collections")).?;
    try std.testing.expectEqual(@as(usize, 0), p.len);
}

test "matchPath: captures a param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = (try matchPath(arena.allocator(), "/api/collections/:idOrName", "/api/collections/posts")).?;
    try std.testing.expectEqual(@as(usize, 1), p.len);
    try std.testing.expectEqualStrings("idOrName", p[0].key);
    try std.testing.expectEqualStrings("posts", p[0].value);
}

test "matchPath: literal mismatch and length mismatch return null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try matchPath(arena.allocator(), "/api/collections", "/api/users")) == null);
    try std.testing.expect((try matchPath(arena.allocator(), "/api/collections/:id", "/api/collections")) == null);
}
```

- [ ] **Step 2: Implement** in `src/router.zig`:

```zig
pub const Route = struct { method: http.Method, pattern: []const u8, handler: http.Handler };

/// Match `pattern` (with `:name` capture segments) against `path`, splitting on '/'.
/// Returns captured params (possibly empty) on match, or null on mismatch.
pub fn matchPath(alloc: std.mem.Allocator, pattern: []const u8, path: []const u8) !?[]http.Param {
    var params: std.ArrayList(http.Param) = .empty;
    errdefer params.deinit(alloc);
    var pit = std.mem.splitScalar(u8, pattern, '/');
    var sit = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const pseg = pit.next();
        const sseg = sit.next();
        if (pseg == null and sseg == null) break;
        if (pseg == null or sseg == null) return null;
        if (pseg.?.len > 0 and pseg.?[0] == ':') {
            try params.append(alloc, .{ .key = pseg.?[1..], .value = sseg.? });
        } else if (!std.mem.eql(u8, pseg.?, sseg.?)) {
            return null;
        }
    }
    return try params.toOwnedSlice(alloc);
}

/// Find the first matching route (method + path), fill ctx.params, and invoke the handler.
/// Returns a 404 envelope when nothing matches.
pub fn dispatch(routes: []const Route, ctx: *http.RequestCtx) anyerror!http.Response {
    const ApiError = @import("api/error.zig").ApiError;
    for (routes) |rt| {
        if (rt.method != ctx.method) continue;
        if (try matchPath(ctx.allocator, rt.pattern, ctx.path)) |params| {
            ctx.params = params;
            return rt.handler(ctx);
        }
    }
    return ApiError.notFound().toResponse(ctx.allocator);
}

fn dummyHandler(ctx: *http.RequestCtx) anyerror!http.Response {
    return .{ .status = 200, .body = ctx.param("idOrName") orelse "none" };
}

test "dispatch routes to handler with params, else 404" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const routes = [_]Route{.{ .method = .GET, .pattern = "/api/collections/:idOrName", .handler = dummyHandler }};
    var ctx = http.RequestCtx{ .method = .GET, .path = "/api/collections/posts", .allocator = arena.allocator() };
    const r = try dispatch(&routes, &ctx);
    try std.testing.expectEqualStrings("posts", r.body);
    var ctx2 = http.RequestCtx{ .method = .GET, .path = "/nope", .allocator = arena.allocator() };
    const r2 = try dispatch(&routes, &ctx2);
    try std.testing.expectEqual(@as(u16, 404), r2.status);
}
```

- [ ] **Step 3: Aggregate** — add `_ = @import("router.zig");` to `src/main.zig` `test {}`. Run tests (expect PASS).

- [ ] **Step 4: Commit**
```bash
git add src/router.zig src/main.zig
git commit -m "feat(router): segment matcher with path params"
```

---

## Task 4: Collection request/response JSON

**Files:** Modify `src/schema.zig`.

Reuse the existing `fieldsToJson`/`fieldsFromJson`/`indexesToJson`/`indexesFromJson` (round-tripping sub-values through them avoids duplicating the per-type option logic).

- [ ] **Step 1: Write tests first** in `src/schema.zig`:

```zig
test "parseCollectionInput then collectionToJson round-trips the essentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\{"name":"posts","fields":[
        \\  {"id":"f1","name":"title","required":true,"type":"text","options":{}},
        \\  {"id":"f2","name":"price","type":"number","options":{"mode":"fixed","scale":2}}
        \\]}
    ;
    const col = try parseCollectionInput(a, input);
    try std.testing.expectEqualStrings("posts", col.name);
    try std.testing.expectEqual(CollectionType.base, col.type);
    try std.testing.expectEqual(@as(usize, 2), col.fields.len);
    try std.testing.expectEqualStrings("", col.id); // create assigns the id

    var full = col;
    full.id = "abc123def456ghi";
    full.created = "2026-01-01 00:00:00";
    full.updated = "2026-01-01 00:00:00";
    const out = try collectionToJson(a, full);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"abc123def456ghi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"schema\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\"") != null);
}
```

- [ ] **Step 2: Implement** in `src/schema.zig`:

```zig
/// Parse a request body into a Collection (id left empty; create/update assign it).
/// Body shape: {name, type?, fields:[...], indexes?:[...], listRule?, ...rules}.
pub fn parseCollectionInput(alloc: std.mem.Allocator, s: []const u8) !Collection {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
    const obj = parsed.value;
    if (obj != .object) return error.InvalidSchema;

    const name = try alloc.dupe(u8, (objGetStr(obj, "name")) orelse return error.InvalidSchema);
    const ctype = std.meta.stringToEnum(CollectionType, objGetStr(obj, "type") orelse "base") orelse .base;

    const fields = if (obj.object.get("fields")) |fv| blk: {
        const fs = try std.json.Stringify.valueAlloc(alloc, fv, .{});
        break :blk try fieldsFromJson(alloc, fs);
    } else &[_]Field{};

    const indexes = if (obj.object.get("indexes")) |iv| blk: {
        const is = try std.json.Stringify.valueAlloc(alloc, iv, .{});
        break :blk try indexesFromJson(alloc, is);
    } else &[_]Index{};

    return .{
        .id = "",
        .name = name,
        .type = ctype,
        .fields = fields,
        .indexes = indexes,
        .listRule = try dupOptStr(alloc, objGetStr(obj, "listRule")),
        .viewRule = try dupOptStr(alloc, objGetStr(obj, "viewRule")),
        .createRule = try dupOptStr(alloc, objGetStr(obj, "createRule")),
        .updateRule = try dupOptStr(alloc, objGetStr(obj, "updateRule")),
        .deleteRule = try dupOptStr(alloc, objGetStr(obj, "deleteRule")),
    };
}

/// Serialize a Collection to its API JSON shape.
pub fn collectionToJson(alloc: std.mem.Allocator, c: Collection) ![]u8 {
    var root: std.json.ObjectMap = .empty;
    try root.put(alloc, "id", .{ .string = c.id });
    try root.put(alloc, "name", .{ .string = c.name });
    try root.put(alloc, "type", .{ .string = @tagName(c.type) });
    try root.put(alloc, "system", .{ .bool = c.system });
    // embed fields/indexes arrays by reparsing their JSON into Value trees
    const fields_str = try fieldsToJson(alloc, c.fields);
    try root.put(alloc, "schema", (try std.json.parseFromSlice(std.json.Value, alloc, fields_str, .{})).value);
    const idx_str = try indexesToJson(alloc, c.indexes);
    try root.put(alloc, "indexes", (try std.json.parseFromSlice(std.json.Value, alloc, idx_str, .{})).value);
    try root.put(alloc, "listRule", optStrValue(c.listRule));
    try root.put(alloc, "viewRule", optStrValue(c.viewRule));
    try root.put(alloc, "createRule", optStrValue(c.createRule));
    try root.put(alloc, "updateRule", optStrValue(c.updateRule));
    try root.put(alloc, "deleteRule", optStrValue(c.deleteRule));
    try root.put(alloc, "created", .{ .string = c.created });
    try root.put(alloc, "updated", .{ .string = c.updated });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
}

fn optStrValue(v: ?[]const u8) std.json.Value {
    return if (v) |s| .{ .string = s } else .null;
}
fn dupOptStr(alloc: std.mem.Allocator, v: ?[]const u8) !?[]const u8 {
    return if (v) |s| try alloc.dupe(u8, s) else null;
}
```

Implementation guidance:
- `objGetStr(obj, key) ?[]const u8` — you likely already have a helper from Task 4 of 2a (the field parser). If not, add one: returns the `.string` payload of `obj.object.get(key)` if present and a string, else null.
- The reparse-to-embed trick keeps the existing `fieldsToJson`/`indexesToJson` as the single source of truth for field serialization; the round-trip cost is negligible at collection-management frequency.
- Memory: `alloc` is the request arena; don't call `parsed.deinit()` (arena frees everything). Strings retained from the body are duped (`name`, rules).

- [ ] **Step 3: Run** `mise exec zig@0.16.0 -- zig build test` until the round-trip test passes. Commit:
```bash
git add src/schema.zig
git commit -m "feat(schema): collection request parse + response serialize"
```

---

## Task 5: Collection REST handlers

**Files:** Create `src/api/collections.zig`; Modify `src/main.zig` (aggregate).

- [ ] **Step 1: Write the handler tests first** in `src/api/collections.zig` (they build a temp `App` over a real `Pool`):

```zig
const std = @import("std");
const http = @import("../http.zig");
const app_mod = @import("../app.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    pool: db.Pool,
    app: app_mod.App,

    fn init() !*TestEnv {
        const env = try std.testing.allocator.create(TestEnv);
        env.tmp = std.testing.tmpDir(.{});
        const dir = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir}, 0);
        defer std.testing.allocator.free(path);
        env.pool = try db.Pool.init(std.testing.allocator, path);
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
        }
        env.app = .{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = &env.pool };
        return env;
    }
    fn deinit(env: *TestEnv) void {
        env.pool.deinit();
        env.tmp.cleanup();
        std.testing.allocator.destroy(env);
    }
};

fn ctxFor(env: *TestEnv, arena: std.mem.Allocator, method: http.Method, path: []const u8, body: []const u8, params: []const http.Param) http.RequestCtx {
    return .{ .method = method, .path = path, .body = body, .allocator = arena, .app = &env.app, .params = params };
}

test "create then get then list a collection over handlers" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body =
        \\{"name":"posts","fields":[{"id":"","name":"title","type":"text","options":{}}]}
    ;
    var cctx = ctxFor(env, a, .POST, "/api/collections", body, &.{});
    const cres = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 201), cres.status);
    try std.testing.expect(std.mem.indexOf(u8, cres.body, "\"name\":\"posts\"") != null);

    var gctx = ctxFor(env, a, .GET, "/api/collections/posts", "", &.{.{ .key = "idOrName", .value = "posts" }});
    const gres = try get(&gctx);
    try std.testing.expectEqual(@as(u16, 200), gres.status);

    var lctx = ctxFor(env, a, .GET, "/api/collections", "", &.{});
    const lres = try list(&lctx);
    try std.testing.expectEqual(@as(u16, 200), lres.status);
    try std.testing.expect(std.mem.indexOf(u8, lres.body, "\"posts\"") != null);
}

test "create with invalid name returns 400 with field errors" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cctx = ctxFor(env, arena.allocator(), .POST, "/api/collections", "{\"name\":\"1bad\",\"fields\":[]}", &.{});
    const res = try create(&cctx);
    try std.testing.expectEqual(@as(u16, 400), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "validation_invalid_name") != null);
}
```

- [ ] **Step 2: Implement** `src/api/collections.zig`:

```zig
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const ApiError = @import("error.zig").ApiError;

// TODO(SP5): all handlers below must require a superuser once auth lands.

fn validationResponse(ctx: *http.RequestCtx) !http.Response {
    const verrs = collections.last_errors orelse &[_]schema.ValidationError{};
    const fes = try ctx.allocator.alloc(ApiError.FieldError, verrs.len);
    for (verrs, 0..) |e, i| fes[i] = .{ .field = e.field, .code = e.code, .message = e.message };
    return ApiError.validation(fes).toResponse(ctx.allocator);
}

pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const cols = try collections.list(ctx.allocator, w);
    var arr: std.json.Array = std.json.Array.init(ctx.allocator);
    for (cols) |c| {
        const cj = try schema.collectionToJson(ctx.allocator, c);
        try arr.append((try std.json.parseFromSlice(std.json.Value, ctx.allocator, cj, .{})).value);
    }
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .array = arr }, .{});
    return .{ .status = 200, .body = body };
}

pub fn create(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const def = schema.parseCollectionInput(ctx.allocator, ctx.body) catch
        return ApiError.badRequest("Invalid request body.").toResponse(ctx.allocator);
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const created = collections.create(ctx.allocator, app.io, w, def) catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.Conflict => return ApiError.conflict("Collection already exists.").toResponse(ctx.allocator),
        else => return e,
    };
    return .{ .status = 201, .body = try schema.collectionToJson(ctx.allocator, created) };
}

pub fn get(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const key = ctx.param("idOrName") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try collections.get(ctx.allocator, w, key)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    return .{ .status = 200, .body = try schema.collectionToJson(ctx.allocator, col) };
}

pub fn update(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const key = ctx.param("idOrName") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const def = schema.parseCollectionInput(ctx.allocator, ctx.body) catch
        return ApiError.badRequest("Invalid request body.").toResponse(ctx.allocator);
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const updated = collections.update(ctx.allocator, app.io, w, key, def) catch |e| switch (e) {
        error.NotFound => return ApiError.notFound().toResponse(ctx.allocator),
        error.Validation => return validationResponse(ctx),
        error.Conflict => return ApiError.conflict("Conflict.").toResponse(ctx.allocator),
        else => return e,
    };
    return .{ .status = 200, .body = try schema.collectionToJson(ctx.allocator, updated) };
}

pub fn delete(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const key = ctx.param("idOrName") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    collections.delete(ctx.allocator, w, key) catch |e| switch (e) {
        error.NotFound => return ApiError.notFound().toResponse(ctx.allocator),
        error.Conflict => return ApiError.conflict("Collection is referenced by a relation.").toResponse(ctx.allocator),
        else => return e,
    };
    return .{ .status = 204, .body = "" };
}
```

- [ ] **Step 3: Aggregate** — add `_ = @import("api/collections.zig");` to `src/main.zig` `test {}`. Run `mise exec zig@0.16.0 -- zig build test` until the handler tests pass. (If `std.testing.TmpDir`/`tmpDir` field access differs, mirror the working pattern already used in `src/db.zig`'s pool test.)

- [ ] **Step 4: Commit**
```bash
git add src/api/collections.zig src/main.zig
git commit -m "feat(api): collections REST handlers"
```

---

## Task 6: Wire it together — server, CLI, main, smoke test

**Files:** Modify `src/server.zig`, `src/cli.zig`, `src/main.zig`.

- [ ] **Step 1: `cli.zig` — add the `migrate` command.** In `Command`, add `migrate` to the union:
```zig
pub const Command = union(enum) {
    help,
    serve: ServeArgs,
    migrate: ServeArgs, // reuses serve args (needs --data-dir)
};
```
In `parse`, after the `help` checks and before the `serve` check, handle migrate:
```zig
    if (std.mem.eql(u8, args[0], "migrate")) {
        // reuse the serve-flag loop by parsing into ServeArgs
        var sa = ServeArgs{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--data-dir")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                sa.data_dir = args[i];
            } else return ParseError.UnknownFlag;
        }
        return .{ .migrate = sa };
    }
```
Add a test:
```zig
test "migrate command parses --data-dir" {
    const cmd = try parse(&.{ "migrate", "--data-dir", "/tmp/zb" });
    try std.testing.expectEqualStrings("/tmp/zb", cmd.migrate.data_dir.?);
}
```

- [ ] **Step 2: Replace `src/server.zig` with the App + router version:**

```zig
const std = @import("std");
const zap = @import("zap");
const http = @import("http.zig");
const app_mod = @import("app.zig");
const router = @import("router.zig");
const health = @import("api/health.zig");
const collections_api = @import("api/collections.zig");
const ApiError = @import("api/error.zig").ApiError;

fn healthHandler(ctx: *http.RequestCtx) anyerror!http.Response {
    return health.handle(ctx);
}

const routes = [_]router.Route{
    .{ .method = .GET, .pattern = "/api/health", .handler = healthHandler },
    .{ .method = .GET, .pattern = "/api/collections", .handler = collections_api.list },
    .{ .method = .POST, .pattern = "/api/collections", .handler = collections_api.create },
    .{ .method = .GET, .pattern = "/api/collections/:idOrName", .handler = collections_api.get },
    .{ .method = .PATCH, .pattern = "/api/collections/:idOrName", .handler = collections_api.update },
    .{ .method = .DELETE, .pattern = "/api/collections/:idOrName", .handler = collections_api.delete },
};

pub const Server = struct {
    app: *app_mod.App,
    host: [:0]const u8,
    port: u16,

    /// Single-process (workers=1) makes this global safe across zap's threads.
    var instance: ?*Server = null;

    pub fn listen(self: *Server) !void {
        instance = self;
        var listener = zap.HttpListener.init(.{ .port = self.port, .on_request = onRequest, .log = false });
        try listener.listen();
        std.log.info("zigbase listening on http://{s}:{d}", .{ self.host, self.port });
        zap.start(.{ .threads = 4, .workers = 1 });
    }
};

fn methodFromZap(r: zap.Request) http.Method {
    return switch (r.methodAsEnum()) {
        .GET => .GET, .POST => .POST, .PUT => .PUT, .PATCH => .PATCH,
        .DELETE => .DELETE, .OPTIONS => .OPTIONS, .HEAD => .HEAD, else => .UNKNOWN,
    };
}

fn setZapStatus(r: zap.Request, status: u16) void {
    const code: zap.http.StatusCode = switch (status) {
        200 => .ok,
        201 => .created,
        204 => .no_content,
        400 => .bad_request,
        404 => .not_found,
        409 => .conflict,
        422 => .unprocessable_entity,
        else => .internal_server_error,
    };
    r.setStatus(code);
}

fn onRequest(r: zap.Request) !void {
    const self = Server.instance.?;
    var arena = std.heap.ArenaAllocator.init(self.app.allocator);
    defer arena.deinit();
    var ctx = http.RequestCtx{
        .method = methodFromZap(r),
        .path = r.path orelse "/",
        .query = r.query orelse "",
        .body = r.body orelse "",
        .allocator = arena.allocator(),
        .app = self.app,
    };
    const resp = router.dispatch(&routes, &ctx) catch
        ApiError.internal().toResponse(arena.allocator()) catch {
            setZapStatus(r, 500);
            r.setContentType(.JSON) catch {};
            r.sendBody("{\"code\":500,\"message\":\"Something went wrong.\",\"data\":{}}") catch {};
            return;
        };
    setZapStatus(r, resp.status);
    r.setContentType(.JSON) catch {};
    r.sendBody(resp.body) catch {};
}
```

- [ ] **Step 3: Update `src/main.zig`** — build `App`, run migrations on serve, handle `migrate`. Replace `runServe` and add `runMigrate`; update the `switch`:

```zig
const app_mod = @import("app.zig");
const migrations = @import("migrations.zig");
// ... existing imports ...

    switch (cmd) {
        .help => printUsage(),
        .serve => |sa| try runServe(allocator, init.io, sa),
        .migrate => |sa| try runMigrate(allocator, init.io, sa),
    }
```
```zig
fn openPool(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !db.Pool {
    std.Io.Dir.cwd().createDirPath(io, cfg.data_dir) catch {};
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/data.db", .{cfg.data_dir}, 0);
    defer allocator.free(db_path);
    return db.Pool.init(allocator, db_path);
}

fn loadCfg(sa: cli.ServeArgs) !config.Config {
    var cfg = try config.Config.load(&config.envGetter);
    if (sa.http_host) |v| cfg.http_host = v;
    if (sa.http_port) |v| cfg.http_port = v;
    if (sa.data_dir) |v| cfg.data_dir = v;
    return cfg;
}

fn runMigrate(allocator: std.mem.Allocator, io: std.Io, sa: cli.ServeArgs) !void {
    const cfg = try loadCfg(sa);
    var pool = try openPool(allocator, io, cfg);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.run(w);
    std.log.info("migrations applied", .{});
}

fn runServe(allocator: std.mem.Allocator, io: std.Io, sa: cli.ServeArgs) !void {
    const cfg = try loadCfg(sa);
    var pool = try openPool(allocator, io, cfg);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
    }
    var app = app_mod.App{ .allocator = allocator, .io = io, .pool = &pool };
    const host_z = try allocator.dupeZ(u8, cfg.http_host);
    defer allocator.free(host_z);
    var srv = server.Server{ .app = &app, .host = host_z, .port = cfg.http_port };
    try srv.listen();
}
```
(Remove the old `runServe` body. Keep the `test {}` aggregator and add `_ = @import("api/collections.zig");` if not already present from Task 5.)

- [ ] **Step 4: Build & run the unit suite.** `mise exec zig@0.16.0 -- zig build && mise exec zig@0.16.0 -- zig build test`. Expect a clean build and all tests passing.

- [ ] **Step 5: Manual smoke test (the lifecycle).**
```bash
rm -rf ./zb_data
mise exec zig@0.16.0 -- zig build
./zig-out/bin/zigbase serve --http-port 8096 --data-dir ./zb_data &
SP=$!; sleep 1
echo "--- create ---"
curl -s -i -X POST http://127.0.0.1:8096/api/collections \
  -H 'content-type: application/json' \
  -d '{"name":"posts","fields":[{"id":"","name":"title","type":"text","options":{}},{"id":"","name":"price","type":"number","options":{"mode":"fixed","scale":2}}]}'
echo; echo "--- list ---"; curl -s http://127.0.0.1:8096/api/collections
echo; echo "--- get ---"; curl -s http://127.0.0.1:8096/api/collections/posts
echo; echo "--- patch (add a field) ---"
curl -s -X PATCH http://127.0.0.1:8096/api/collections/posts \
  -H 'content-type: application/json' \
  -d '{"name":"posts","fields":[{"id":"","name":"title","type":"text","options":{}},{"id":"","name":"views","type":"number","options":{"mode":"int"}}]}'
echo; echo "--- delete ---"; curl -s -i -X DELETE http://127.0.0.1:8096/api/collections/posts
echo; echo "--- invalid create (400) ---"
curl -s -i -X POST http://127.0.0.1:8096/api/collections -H 'content-type: application/json' -d '{"name":"1bad","fields":[]}'
kill $SP 2>/dev/null
```
Expected: create → `201` with the collection JSON (note: the PATCH here uses fresh `id:""` fields, so `title` is treated as a NEW field — a real client would resend existing field ids; that's fine for the smoke test, it exercises the rebuild). list/get → 200; delete → 204; invalid create → 400 with `validation_invalid_name` in `data.name`. Confirm `./zb_data/data.db` has a `posts` table after create (before delete). **Always kill the server.**

- [ ] **Step 6: Commit**
```bash
git add src/server.zig src/cli.zig src/main.zig
git commit -m "feat: wire collections REST, router, App, and migrate command"
```

---

## Self-Review (completed by plan author)

**Spec coverage (SP2 design §7 + the deferred-from-2a items):**
- error envelope w/ field `data` + constructors → Task 1 ✓
- `App` + `RequestCtx{app,params}` → Task 2 ✓
- router with path params → Task 3 ✓
- collection request parse + response serialize → Task 4 ✓
- REST handlers (list/create/get/update/delete, unprotected w/ TODO(SP5)) → Task 5 ✓
- `setZapStatus` extension (201/204/400/404/409/422) → Task 6 ✓
- `server.zig` App+router wiring, run migrations on serve, `migrate` CLI command → Task 6 ✓
- `Stmt` column helpers, id generator → already delivered in 2a ✓
- manual smoke for full lifecycle → Task 6 ✓

**Type consistency:** `App{allocator,io,pool}`; `http.RequestCtx{...,app:?*App,params,param()}`, `http.Param`, `http.Handler`; `router.Route{method,pattern,handler}`, `matchPath`, `dispatch`; `schema.parseCollectionInput`/`collectionToJson`; `ApiError{status,message,fields}` + `FieldError` + constructors; engine calls `collections.create/get/list/update/delete` with the `(alloc[, io], *db.Db, ...)` signatures from 2a; `collections.last_errors` consumed in `validationResponse`. All consistent.

**Placeholder scan:** Tasks 1-3, 5, 6 contain complete code. Task 4 gives complete code with two small helper references (`objGetStr`, and reuse of 2a's field parser) flagged with explicit guidance. No vague "add error handling" steps; every error path maps to a concrete `ApiError` constructor + status.

**Notes:** Handlers use the writer connection for all collection ops (admin-frequency, simplest correct choice; reader-pool optimization deferred). The PATCH smoke example resends fields with empty ids (treated as new) — documented; real clients resend existing field ids to preserve data, which the 2a engine + rebuild already supports and is unit-tested.
