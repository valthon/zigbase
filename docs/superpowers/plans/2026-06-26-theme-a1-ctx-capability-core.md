# Theme A1 — `Ctx` Capability Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a unified `Ctx` capability object that gives custom handlers/hooks/jobs first-class `records` (with `expand`), outbound `http`, and a standard error model — additively, with no signature break.

**Architecture:** A new `src/ctx.zig` module defines `Ctx`, a per-invocation capability surface holding `*App`, a request-scoped arena, an optional caller `RequestContext`, and a connection strategy (a *bound* connection when built inside a record hook's transaction, else lazy pool acquisition). It composes the existing engine (`data.zig`, `records.zig`, `query/expand.zig`, `api/error.zig`) rather than reimplementing it. A new `src/http_client.zig` generalizes the `std.http.Client` pattern already used by `oauth/client.zig` into a small consumer-facing client. `Ctx` is reachable from today's event types via an additive `caps()` accessor; the full ctx-first reshape is deferred to Plan A3.

**Tech Stack:** Zig 0.16.0, vendored SQLite, `std.http.Client` (TLS via `std.crypto.tls`), `std.json`.

## Global Constraints

- Zig 0.16.0 exactly (`mise exec zig@0.16.0 -- zig build ...`); another 0.16.x is not guaranteed to work.
- `zig build test` prints a spurious `failed command:` line even on success — the authoritative signal is the `Build Summary: N/N tests passed` line (use `--summary all`).
- A new `src/*.zig` file's tests do NOT run until the file is added to the `test { _ = @import("…"); }` block in `src/root.zig`.
- `root.zig` is both the public API surface and the unit-test root; any type a consumer must name is re-exported there.
- Hook record mutations and anything that becomes part of `ev.record` MUST allocate with the request arena, never `app.allocator`.
- The pool has ONE writer (mutex-guarded, non-reentrant): acquiring the writer while already holding it deadlocks permanently. Code built inside a record hook MUST reuse the hook's bound connection, never acquire the pool writer.
- Linux/macOS only.
- Never edit `CHANGELOG.md`; add a `changelog.d/<slug>.md` fragment instead.

---

## File Structure

- Create `src/ctx.zig` — the `Ctx` type and its `records`/`http`/error surface. One responsibility: the consumer capability object.
- Create `src/http_client.zig` — a general outbound HTTP client (`request`/`get`/`post`) returning `{ status, headers, body }`.
- Modify `src/root.zig` — re-export `Ctx` (and `HttpResponse`); add both new files to the test-import block.
- Modify `src/events.zig` — add a `caps()` accessor to `RouteEvent`, `RecordEvent`, `JobEvent`, `LifecycleEvent` that constructs a `Ctx`.
- Modify `changelog.d/` — add a fragment under `### Features`.

**Interfaces produced by this plan (names later plans/handlers rely on):**

```zig
// src/ctx.zig
pub const Ctx = struct {
    app: *App,
    arena: std.mem.Allocator,
    rctx: request.RequestContext,      // caller identity; default .{} (anonymous) in jobs
    bound_conn: ?*db.Db,               // non-null inside a record hook (its txn conn); reads+writes use it
    reader: ?events.ReaderData,        // lazily checked-out reader cache (route/job context only)

    pub const records: Records;        // namespace value (see Records below)
    pub fn http(self: *Ctx) HttpClient;
    pub fn fail(self: *Ctx, status: u16, message: []const u8) FailError;       // returns error.Handled after stashing
    pub fn invalid(self: *Ctx, fields: []const error_mod.FieldError) FailError;
    pub fn errorResponse(self: *Ctx, err: anyerror) http.Response;            // maps a returned error -> Response
    pub fn deinit(self: *Ctx) void;    // releases the cached reader if any

    pub const Records = struct {       // reached as ctx.records
        pub fn get(self: Records, collection: []const u8, id: []const u8, opts: GetOptions) !?std.json.Value;
        pub fn list(self: Records, collection: []const u8, opts: ListOptions) !records.ListResult;
        pub fn create(self: Records, collection: []const u8, value: std.json.Value) !std.json.Value;
        pub fn update(self: Records, collection: []const u8, id: []const u8, value: std.json.Value) !?std.json.Value;
        pub fn delete(self: Records, collection: []const u8, id: []const u8) !bool;
    };
    pub const GetOptions = struct { expand: ?[]const u8 = null };
    pub const ListOptions = struct {   // a thin superset of records.ListQuery + expand
        filter: ?[]const u8 = null, sort: ?[]const u8 = null,
        page: u32 = 1, perPage: u32 = 30, limit: ?u32 = null,
        cursor: ?[]const u8 = null, expand: ?[]const u8 = null,
    };
};

// src/http_client.zig
pub const HttpResponse = struct { status: u16, headers: []const Header, body: []const u8 };
pub const RequestOptions = struct {
    method: Method = .GET, url: []const u8,
    headers: []const Header = &.{}, body: ?[]const u8 = null,
    timeout_ms: u32 = 10_000, max_response_bytes: usize = 1 << 20,
};
pub const HttpClient = struct {
    pub fn request(self: HttpClient, opts: RequestOptions) !HttpResponse;
    pub fn get(self: HttpClient, url: []const u8) !HttpResponse;
    pub fn post(self: HttpClient, url: []const u8, opts: PostOptions) !HttpResponse;
};
```

---

## Task 1: Scaffold `src/ctx.zig` with the `Ctx` type and connection strategy

**Files:**
- Create: `src/ctx.zig`
- Modify: `src/root.zig` (test-import block + `pub const Ctx`)

**Interfaces:**
- Consumes: `App` (`src/app.zig`), `db.Db`/`db.Pool` (`src/db.zig`), `Data` + `ReaderData`/`WriterData` (`src/data.zig`, `src/events.zig`), `request.RequestContext` (`src/request.zig`).
- Produces: `Ctx` with `app`, `arena`, `rctx`, `bound_conn`, `reader`; private `acquireReaderConn()` / `withWriterConn()` helpers; `deinit()`.

- [ ] **Step 1: Write the failing test**

Add to the bottom of the new `src/ctx.zig`. Reuse the file-backed-pool `TestEnv` pattern from `src/events.zig` (a `posts` collection with a `title` text field). This test asserts a bound-conn `Ctx` uses exactly that connection and never touches the pool.

```zig
test "Ctx(bound) uses the bound connection and never acquires from the pool" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    var ctx = Ctx{
        .app = &env.app,
        .arena = env.arena.allocator(),
        .rctx = .{},
        .bound_conn = w,
        .reader = null,
    };
    defer ctx.deinit();

    // No reader is cached because bound_conn short-circuits acquisition.
    const conn = try ctx.connForRead();
    try std.testing.expect(conn == w);
    try std.testing.expect(ctx.reader == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `src/ctx.zig` not imported / `Ctx` undefined. (First add the import in Step 3 so it compiles to a real failure.)

- [ ] **Step 3: Write minimal implementation**

Create `src/ctx.zig` with the type, the connection strategy, and the `CtxTestEnv` harness (copy the `TestEnv` from `src/events.zig:736-788`, renaming to `CtxTestEnv`). Core:

```zig
const std = @import("std");
const App = @import("app.zig").App;
const db = @import("db.zig");
const request = @import("request.zig");
const events = @import("events.zig");
const Data = @import("data.zig").Data;

pub const Ctx = struct {
    app: *App,
    arena: std.mem.Allocator,
    rctx: request.RequestContext = .{},
    /// Non-null inside a record hook: the hook's in-transaction connection. When set,
    /// ALL reads and writes use it (acquiring the pool writer here would deadlock).
    bound_conn: ?*db.Db = null,
    /// Lazily checked-out reader, cached for the Ctx lifetime (route/job context only).
    reader: ?events.ReaderData = null,

    /// A connection suitable for reads. Bound conn wins; else lazily check out + cache a reader.
    pub fn connForRead(self: *Ctx) !*db.Db {
        if (self.bound_conn) |c| return c;
        if (self.reader == null) {
            self.reader = .{ .app = self.app, .pool = self.app.pool, .conn = try self.app.pool.acquireReader() };
        }
        return &self.reader.?.conn;
    }

    /// Release any cached reader. Call once (the accessor/handler frame owns this via defer).
    pub fn deinit(self: *Ctx) void {
        if (self.reader) |*r| {
            r.deinit();
            self.reader = null;
        }
    }
};
```

Re-export in `src/root.zig`: add `pub const Ctx = @import("ctx.zig").Ctx;` near the other re-exports, and add `_ = @import("ctx.zig");` to the `test { ... }` block.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (look for `Build Summary: N/N tests passed`).

- [ ] **Step 5: Commit**

```bash
git add src/ctx.zig src/root.zig
git commit -m "feat(ctx): scaffold Ctx capability object with connection strategy"
```

---

## Task 2: `ctx.records` reads — `get`, `list`, `findById` over a pooled/bound reader

**Files:**
- Modify: `src/ctx.zig`

**Interfaces:**
- Consumes: `connForRead()` (Task 1), `Data.findById`/`Data.list` (`src/data.zig:32,65`), `records.ListQuery`/`ListResult` (`src/records.zig`).
- Produces: `Ctx.Records` namespace with `get`/`list`; `Ctx.records` accessor; `ListOptions`/`GetOptions` (sans expand wiring, added in Task 3).

- [ ] **Step 1: Write the failing test**

```zig
test "ctx.records.list returns created rows; get fetches one by id" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    // Seed two rows directly on the writer.
    const id = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = env.app.io };
        var o1: std.json.ObjectMap = .empty;
        try o1.put(a, "title", .{ .string = "alpha" });
        const c1 = try d.create("posts", .{ .object = o1 });
        var o2: std.json.ObjectMap = .empty;
        try o2.put(a, "title", .{ .string = "beta" });
        _ = try d.create("posts", .{ .object = o2 });
        break :blk try a.dupe(u8, c1.object.get("id").?.string);
    };

    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    const page = try ctx.records.list("posts", .{ .sort = "title" });
    try std.testing.expectEqual(@as(usize, 2), page.items.len);

    const one = (try ctx.records.get("posts", id, .{})).?;
    try std.testing.expectEqualStrings("alpha", one.object.get("title").?.string);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `ctx.records` / `Records` undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `Ctx` in `src/ctx.zig`. Reads bind a `Data` to the read connection and delegate; expand is added in Task 3.

```zig
const records = @import("records.zig");

pub const GetOptions = struct { expand: ?[]const u8 = null };
pub const ListOptions = struct {
    filter: ?[]const u8 = null,
    sort: ?[]const u8 = null,
    page: u32 = 1,
    perPage: u32 = 30,
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    expand: ?[]const u8 = null,
};

pub const Records = struct {
    ctx: *Ctx,

    fn dataRead(self: Records) !Data {
        return .{ .app = self.ctx.app, .conn = try self.ctx.connForRead(), .io = self.ctx.app.io };
    }

    pub fn get(self: Records, collection: []const u8, id: []const u8, opts: GetOptions) !?std.json.Value {
        _ = opts; // expand wired in Task 3
        return (try self.dataRead()).findById(collection, id);
    }

    pub fn list(self: Records, collection: []const u8, opts: ListOptions) !records.ListResult {
        const q = records.ListQuery{
            .filter = opts.filter, .sort = opts.sort,
            .page = opts.page, .perPage = opts.perPage,
            .limit = opts.limit, .cursor = opts.cursor,
            .rctx = &self.ctx.rctx, .io = self.ctx.app.io,
        };
        return (try self.dataRead()).list(collection, q);
    }
};

// On Ctx itself:
pub fn recordsNs(self: *Ctx) Records { return .{ .ctx = self }; }
```

Expose as a field-like accessor. Since Zig has no computed properties, name the accessor `records` is impossible (collides with the imported module alias). Use the method `ctx.records()` by importing the engine module under a different alias:

```zig
const records_engine = @import("records.zig"); // rename the import
// ...and rename uses of `records.ListQuery`/`records.ListResult` to `records_engine.*`
pub fn records(self: *Ctx) Records { return .{ .ctx = self }; }
```

Update the test calls `ctx.records.list(...)` → `ctx.records().list(...)`. (The ergonomic `ctx.records.list` without parens is restored in Plan A3 when `Ctx` is passed by value with a precomputed namespace field; for A1 the method form is correct and non-throwaway.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ctx.zig
git commit -m "feat(ctx): ctx.records().get/list over pooled or bound reader"
```

---

## Task 3: `ctx.records` expand — wire the existing resolver into `get`/`list`

**Files:**
- Modify: `src/ctx.zig`

**Interfaces:**
- Consumes: `expand_mod.expand(alloc, conn, col, *rec, spec, depth, *rctx)` (`src/query/expand.zig:22`), `collections.get(alloc, conn, name)` (`src/collections.zig`).
- Produces: expand-aware `Records.get`/`Records.list`.

- [ ] **Step 1: Write the failing test**

Add a `relation` field so expand has something to resolve. Extend `CtxTestEnv` with an `authors` collection and a `posts.author` relation, or add inline in the test (preferred — keeps the harness generic):

```zig
test "ctx.records expand nests the related record under \"expand\"" {
    const env = try CtxTestEnv.initWithRelation(); // see Step 3
    defer env.deinit();
    const a = env.arena.allocator();

    const ids = blk: {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const d = Data{ .app = &env.app, .conn = w, .io = env.app.io };
        var ao: std.json.ObjectMap = .empty;
        try ao.put(a, "name", .{ .string = "Ada" });
        const author = try d.create("authors", .{ .object = ao });
        const aid = try a.dupe(u8, author.object.get("id").?.string);
        var po: std.json.ObjectMap = .empty;
        try po.put(a, "title", .{ .string = "p" });
        try po.put(a, "author", .{ .string = aid });
        const post = try d.create("posts", .{ .object = po });
        break :blk try a.dupe(u8, post.object.get("id").?.string);
    };

    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    const post = (try ctx.records().get("posts", ids, .{ .expand = "author" })).?;
    const exp = post.object.get("expand").?.object;
    try std.testing.expectEqualStrings("Ada", exp.get("author").?.object.get("name").?.string);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — no `expand` key on the returned record (and `initWithRelation` undefined).

- [ ] **Step 3: Write minimal implementation**

Add `initWithRelation` to `CtxTestEnv` (an `authors` collection with a `name` text field and a `posts.author` single-relation field — mirror the field-builder calls already used by `collections.create` in the harness, with `.options = .{ .relation = .{ .targetCollectionId = "authors", ... } }`). Then wire expand:

```zig
const expand_mod = @import("query/expand.zig");
const collections = @import("collections.zig");

fn applyExpand(self: Records, rec: *std.json.Value, spec: ?[]const u8) !void {
    const s = spec orelse return;
    if (s.len == 0) return;
    const conn = try self.ctx.connForRead();
    const col = (try collections.get(self.ctx.app.allocator, conn, /* collection */ undefined)) orelse return;
    try expand_mod.expand(self.ctx.app.allocator, conn, col, rec, s, 0, &self.ctx.rctx);
}
```

Thread the collection name through (resolve `col` from the collection name passed to `get`/`list`). In `get`, after fetching the record, run expand on the mutable value before returning. In `list`, iterate `result.items` and expand each (mirror `src/api/records.zig:418-419`). Expand uses `self.ctx.rctx`, so a route handler's expand honors the caller's view-rules exactly like the HTTP layer; a job (`rctx = .{}`) gets the anonymous view. (Document this: CRUD bypasses collection rules — matching today's `Data` — but expand applies the target's `viewRule` under the ctx identity.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ctx.zig
git commit -m "feat(ctx): expand/relations in ctx.records().get/list"
```

---

## Task 4: `ctx.records` writes — `create`, `update`, `delete`

**Files:**
- Modify: `src/ctx.zig`

**Interfaces:**
- Consumes: `Data.create`/`update`/`delete` (`src/data.zig:45,57,61`), `app.pool.acquireWriter()`/`releaseWriter()` (`src/db.zig`).
- Produces: `Records.create`/`update`/`delete`. Writes use `bound_conn` when set (record-hook context — no acquisition), else acquire the pool writer per-op and release immediately.

- [ ] **Step 1: Write the failing test**

```zig
test "ctx.records create/update/delete round-trips and releases the writer" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();

    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    var o: std.json.ObjectMap = .empty;
    try o.put(a, "title", .{ .string = "draft" });
    const created = try ctx.records().create("posts", .{ .object = o });
    const id = created.object.get("id").?.string;

    var u: std.json.ObjectMap = .empty;
    try u.put(a, "title", .{ .string = "published" });
    const updated = (try ctx.records().update("posts", id, .{ .object = u })).?;
    try std.testing.expectEqualStrings("published", updated.object.get("title").?.string);

    try std.testing.expect(try ctx.records().delete("posts", id));

    // Writer was released each time: re-acquiring directly must not deadlock.
    const w2 = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = w2;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `create`/`update`/`delete` undefined on `Records`.

- [ ] **Step 3: Write minimal implementation**

```zig
/// Run `f` with a Data bound to a write connection. Uses bound_conn (hook txn) when present —
/// NEVER acquiring the pool writer in that case (it would deadlock). Else acquires + releases.
fn withWrite(self: Records, comptime R: type, f: anytype) !R {
    if (self.ctx.bound_conn) |c| {
        const d = Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io };
        return f(d);
    }
    const c = self.ctx.app.pool.acquireWriter();
    defer self.ctx.app.pool.releaseWriter();
    const d = Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io };
    return f(d);
}

pub fn create(self: Records, collection: []const u8, value: std.json.Value) !std.json.Value {
    const Closure = struct {
        col: []const u8, val: std.json.Value,
        fn run(c: @This(), d: Data) !std.json.Value { return d.create(c.col, c.val); }
    };
    return self.withWrite(std.json.Value, struct {
        fn call(d: Data) !std.json.Value { return undefined; }
    }.call); // see note
}
```

NOTE on the closure shape: Zig has no capturing closures. Implement `create`/`update`/`delete` directly without the `withWrite` generic if the binding-vs-acquire branch is duplicated cleanly — duplication of a 4-line acquire/release is acceptable and clearer than a generic thunk. Concretely:

```zig
pub fn create(self: Records, collection: []const u8, value: std.json.Value) !std.json.Value {
    if (self.ctx.bound_conn) |c|
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io }).create(collection, value);
    const c = self.ctx.app.pool.acquireWriter();
    defer self.ctx.app.pool.releaseWriter();
    return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io }).create(collection, value);
}
pub fn update(self: Records, collection: []const u8, id: []const u8, value: std.json.Value) !?std.json.Value {
    if (self.ctx.bound_conn) |c|
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io }).update(collection, id, value);
    const c = self.ctx.app.pool.acquireWriter();
    defer self.ctx.app.pool.releaseWriter();
    return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io }).update(collection, id, value);
}
pub fn delete(self: Records, collection: []const u8, id: []const u8) !bool {
    if (self.ctx.bound_conn) |c|
        return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io }).delete(collection, id);
    const c = self.ctx.app.pool.acquireWriter();
    defer self.ctx.app.pool.releaseWriter();
    return (Data{ .app = self.ctx.app, .conn = c, .io = self.ctx.app.io }).delete(collection, id);
}
```

(Delete the speculative `withWrite` generic / `Closure` sketch above; the direct form is the implementation.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ctx.zig
git commit -m "feat(ctx): ctx.records().create/update/delete with bound-conn safety"
```

---

## Task 5: General outbound HTTP client (`src/http_client.zig`)

**Files:**
- Create: `src/http_client.zig`
- Modify: `src/root.zig` (test-import block + `pub const HttpResponse`)

**Interfaces:**
- Consumes: `std.http.Client` (the fetch pattern from `src/oauth/client.zig:92-118`), `std.Io`.
- Produces: `HttpClient`, `HttpResponse`, `Method`, `Header`, `RequestOptions`, `PostOptions`.

- [ ] **Step 1: Write the failing test**

Drive a real loopback request against a tiny in-test server, or — to avoid a server dependency in the unit suite — assert the request *builder* maps options to `std.http.Client.FetchOptions` correctly via a seam. Prefer the loopback server (the browser suite already exercises real HTTP; a unit-level loopback keeps this hermetic):

```zig
test "HttpClient.get returns status and body from a loopback server" {
    // Minimal loopback: bind :0, serve one fixed response, capture the port.
    // (Use std.net + std.http.Server; keep it to one request then close.)
    const server = try TestHttpServer.start("HELLO", 200);
    defer server.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const client = HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };
    const res = try client.get(try server.url(arena.allocator()));
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("HELLO", res.body);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `http_client.zig` not imported / `HttpClient` undefined.

- [ ] **Step 3: Write minimal implementation**

Generalize the `httpCall` fetch pattern (`src/oauth/client.zig:92-118`) — support all methods, return headers+body, honor `max_response_bytes` and `timeout_ms`:

```zig
const std = @import("std");

pub const Method = enum { GET, POST, PUT, PATCH, DELETE };
pub const Header = struct { name: []const u8, value: []const u8 };
pub const HttpResponse = struct { status: u16, headers: []const Header, body: []const u8 };
pub const RequestOptions = struct {
    method: Method = .GET,
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    timeout_ms: u32 = 10_000,
    max_response_bytes: usize = 1 << 20,
};
pub const PostOptions = struct { headers: []const Header = &.{}, body: ?[]const u8 = null };

pub const HttpClient = struct {
    alloc: std.mem.Allocator,
    io: std.Io,

    pub fn get(self: HttpClient, url: []const u8) !HttpResponse {
        return self.request(.{ .method = .GET, .url = url });
    }
    pub fn post(self: HttpClient, url: []const u8, opts: PostOptions) !HttpResponse {
        return self.request(.{ .method = .POST, .url = url, .headers = opts.headers, .body = opts.body });
    }
    pub fn request(self: HttpClient, opts: RequestOptions) !HttpResponse {
        var client = std.http.Client{ .allocator = self.alloc, .io = self.io };
        defer client.deinit();
        const extra = try self.alloc.alloc(std.http.Header, opts.headers.len);
        for (opts.headers, 0..) |h, i| extra[i] = .{ .name = h.name, .value = h.value };
        const resp_buf = try self.alloc.alloc(u8, opts.max_response_bytes);
        var fw = std.Io.Writer.fixed(resp_buf);
        const res = client.fetch(.{
            .location = .{ .url = opts.url },
            .method = switch (opts.method) { .GET => .GET, .POST => .POST, .PUT => .PUT, .PATCH => .PATCH, .DELETE => .DELETE },
            .payload = opts.body,
            .extra_headers = extra,
            .response_writer = &fw,
        }) catch |e| return switch (e) {
            error.WriteFailed => error.ResponseTooLarge,
            else => error.TransportFailed,
        };
        // TLS verification is on by default in std.http.Client; do not disable it.
        return .{ .status = @intFromEnum(res.status), .headers = &.{}, .body = fw.buffered() };
    }
};
```

(`timeout_ms` is carried in the options now; if `std.http.Client.fetch` in 0.16 does not expose a per-call timeout, document it on `RequestOptions` as best-effort and apply it when the API supports it — do NOT silently drop it without the doc-comment.) Add the `TestHttpServer` helper in the same file's test section. Re-export `HttpResponse` in `root.zig` and add `_ = @import("http_client.zig");` to the test block.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/http_client.zig src/root.zig
git commit -m "feat(http): general outbound HttpClient (get/post/request)"
```

---

## Task 6: Wire `ctx.http()` onto `Ctx`

**Files:**
- Modify: `src/ctx.zig`

**Interfaces:**
- Consumes: `HttpClient` (Task 5).
- Produces: `Ctx.http()`.

- [ ] **Step 1: Write the failing test**

```zig
test "ctx.http() returns a client bound to the ctx arena and io" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();
    const client = ctx.http();
    try std.testing.expect(client.io.userdata == env.app.io.userdata); // bound to app io
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `http` undefined on `Ctx`.

- [ ] **Step 3: Write minimal implementation**

```zig
const http_client = @import("http_client.zig");

pub fn http(self: *Ctx) http_client.HttpClient {
    return .{ .alloc = self.arena, .io = self.app.io };
}
```

(If `std.Io` has no `userdata` field to compare in the test, assert instead that two successive `ctx.http()` calls return clients with the same `alloc.ptr` — keep the assertion to an observable equality.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ctx.zig
git commit -m "feat(ctx): expose ctx.http() outbound client"
```

---

## Task 7: Error model — map errors to `ApiError` + `ctx.fail`/`ctx.invalid`

**Files:**
- Modify: `src/ctx.zig`
- Modify: `src/api/error.zig` (add `unauthorized`/`forbidden` constructors if missing)

**Interfaces:**
- Consumes: `ApiError` + `FieldError` + `toResponse` (`src/api/error.zig`).
- Produces: `Ctx.fail`/`Ctx.invalid` (stash an `ApiError` and return `error.Handled`), `Ctx.errorResponse(err)` mapping any error → `http.Response`, and the canonical error→status table.

- [ ] **Step 1: Write the failing test**

```zig
test "errorResponse maps known errors to status codes, unknown to 500" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u16, 404), ctx.errorResponse(error.NotFound).status);
    try std.testing.expectEqual(@as(u16, 403), ctx.errorResponse(error.Forbidden).status);
    try std.testing.expectEqual(@as(u16, 400), ctx.errorResponse(error.BadRequest).status);
    try std.testing.expectEqual(@as(u16, 409), ctx.errorResponse(error.Conflict).status);
    try std.testing.expectEqual(@as(u16, 500), ctx.errorResponse(error.SomethingWeird).status);

    // ctx.fail stashes a custom message that errorResponse(error.Handled) renders.
    const e = ctx.fail(422, "nope");
    try std.testing.expectError(error.Handled, @as(error{Handled}!void, e));
    const r = ctx.errorResponse(error.Handled);
    try std.testing.expectEqual(@as(u16, 422), r.status);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `errorResponse`/`fail`/`invalid` undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `Ctx`. `fail`/`invalid` stash an `ApiError` on the ctx and return `error.Handled`; `errorResponse` renders the stash for `error.Handled`, else maps via the table:

```zig
const error_mod = @import("api/error.zig");
const http = @import("http.zig");

handled: ?error_mod.ApiError = null,  // add to Ctx fields

pub const FailError = error{Handled};

pub fn fail(self: *Ctx, status: u16, message: []const u8) FailError {
    self.handled = .{ .status = status, .message = message };
    return error.Handled;
}
pub fn invalid(self: *Ctx, fields: []const error_mod.FieldError) FailError {
    self.handled = error_mod.ApiError.validation(fields);
    return error.Handled;
}
pub fn errorResponse(self: *Ctx, err: anyerror) http.Response {
    const ae: error_mod.ApiError = switch (err) {
        error.Handled => self.handled orelse error_mod.ApiError.internal(),
        error.NotFound => error_mod.ApiError.notFound(),
        error.BadRequest => error_mod.ApiError.badRequest("Bad request."),
        error.Conflict => error_mod.ApiError.conflict("Conflict."),
        error.Forbidden => .{ .status = 403, .message = "Forbidden." },
        error.Unauthorized => .{ .status = 401, .message = "Unauthorized." },
        else => error_mod.ApiError.internal(),  // details logged by the framework backstop, never leaked
    };
    return ae.toResponse(self.arena) catch error_mod.ApiError.internal().toResponse(self.arena) catch unreachable;
}
```

Add `forbidden`/`unauthorized` constructors to `src/api/error.zig` for symmetry (optional but tidy). The framework's existing error backstop continues to log details for the 500 path; `errorResponse` never includes internal detail in the body.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ctx.zig src/api/error.zig
git commit -m "feat(ctx): error->ApiError mapping with ctx.fail/ctx.invalid"
```

---

## Task 8: Reachability — `caps()` accessor on the event types

**Files:**
- Modify: `src/events.zig`

**Interfaces:**
- Consumes: `Ctx` (Task 1), `RouteEvent`/`RecordEvent`/`JobEvent`/`LifecycleEvent`.
- Produces: `RouteEvent.caps()`, `RecordEvent.caps()`, `JobEvent.caps()`, `LifecycleEvent.caps()` — each returns a `Ctx`. Record-hook `caps()` sets `bound_conn` to the hook's in-transaction connection; route/job set it null (lazy pool acquisition).

- [ ] **Step 1: Write the failing test**

```zig
test "RecordEvent.caps() binds to the hook's connection (no pool acquisition)" {
    const env = try TestEnv.init();
    defer env.deinit();
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();

    var rec: std.json.Value = .{ .object = .empty };
    var ev = RecordEvent{
        .app = &env.app, .ctx = &.{}, .data = .{ .app = &env.app, .conn = w, .io = env.app.io },
        .arena = env.arena.allocator(), .collection = "posts", .record = &rec, .phase = .before_create,
    };
    var ctx = ev.caps();
    defer ctx.deinit();
    try std.testing.expect(ctx.bound_conn == w);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `caps` undefined.

- [ ] **Step 3: Write minimal implementation**

In `src/events.zig`, add the accessor to each event. Import `Ctx` (`const Ctx = @import("ctx.zig").Ctx;`). For `RecordEvent`, bind to `ev.data.conn` and carry the caller rctx; for route, carry `ev.rctx` and use the request arena; for job/lifecycle, anonymous rctx + null bound conn.

```zig
// RecordEvent:
pub fn caps(ev: *RecordEvent) Ctx {
    return .{ .app = ev.app, .arena = ev.arena, .rctx = ev.ctx.*, .bound_conn = ev.data.conn };
}
// RouteEvent:
pub fn caps(ev: *RouteEvent) Ctx {
    return .{ .app = ev.app, .arena = ev.ctx.allocator, .rctx = ev.rctx, .bound_conn = null };
}
// JobEvent & LifecycleEvent:
pub fn caps(ev: *JobEvent) Ctx {
    return .{ .app = ev.app, .arena = ev.app.allocator, .rctx = .{}, .bound_conn = null };
}
```

(Confirm the field name for the route arena — `RouteEvent.ctx` is a `*http.RequestCtx` whose `.allocator` is the request arena; use it.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/events.zig
git commit -m "feat(ctx): caps() accessor on route/record/job/lifecycle events"
```

---

## Task 9: Docs + example + changelog fragment

**Files:**
- Modify: `docs/framework.md` (new "Handler capabilities (`ctx`)" section)
- Modify: `site/src/content/` mirror of the framework doc
- Modify: `examples/golfsim` — convert one hand-written raw-SQL handler to `ev.caps().records()`/`ev.caps().http()`
- Create: `changelog.d/ctx-capability-core.md`

**Interfaces:**
- Consumes: everything above.
- Produces: consumer-facing documentation + a working example exercising the surface.

- [ ] **Step 1: Add the changelog fragment**

Create `changelog.d/ctx-capability-core.md`:

```markdown
### Features

- Handler/hook/job capability object: `ev.caps()` returns a `Ctx` exposing
  `records()` (filtered/sorted/paginated list + get/create/update/delete, with
  `expand`/relations), an outbound `http()` client, and a standard error model
  (`ctx.fail`/`ctx.invalid`, error→status mapping over the existing `{code,message,data}`
  envelope). Custom handlers no longer need to drop to raw SQL or vendor an HTTP stack.
```

- [ ] **Step 2: Convert one golfsim handler + document it**

Replace one raw `conn.prepare(...)` list/get handler in `examples/golfsim` with `ev.caps().records().list(...)`. Add a "Handler capabilities" section to `docs/framework.md` with the list/get/create/expand/http/error snippets, and mirror it into `site/src/content/`. Verify the site builds: `cd site && npm run build`.

- [ ] **Step 3: Build the example + run unit suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Then build golfsim per its README.
Expected: `Build Summary: N/N tests passed`; golfsim builds.

- [ ] **Step 4: Run the browser suite spot-check**

The signature reshape is deferred to A3, so existing admin flows are unchanged; still run one admin test to confirm the new imports didn't break the server build:

Run: `mise exec python@3.13 -- python -m pytest tests/admin/test_schema.py -q`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add docs/framework.md site/src/content examples/golfsim changelog.d/ctx-capability-core.md
git commit -m "docs(ctx): document handler capability object + golfsim example"
```

---

## Self-Review

**Spec coverage (A1 portion of the Theme A spec):**
- §1 `Ctx` object → Tasks 1,6,7 (records/http/error slots present; mail/storage/realtime/auth deferred per spec non-goals). ✓
- §4 `ctx.records` + expand → Tasks 2,3,4. ✓
- §5 `ctx.http` → Tasks 5,6. ✓
- §6 error model (envelope `{code,message,data}`, mapping, `fail`/`invalid`) → Task 7. ✓ (spec said `status`; corrected to the real `code` key.)
- §2 uniform delivery / breaking reshape → **deferred to Plan A3** (additive `caps()` ships value now). ✓ (documented decomposition)
- §3 transactions + before-hook folding → **deferred to Plan A2**. ✓
- §7 remove public `Data` re-export → **deferred to Plan A3** (it is a breaking change bundled with the reshape). ✓
- §8 testing/docs → Task 9 + per-task unit tests. ✓

**Placeholder scan:** Task 4 contains an explicitly-labeled discarded sketch (the `withWrite` generic) followed by the real direct implementation — the step states to delete the sketch; no silent TODOs remain. Task 5 flags the `timeout_ms` best-effort caveat to document rather than silently drop. No "TBD"/"handle edge cases" placeholders.

**Type consistency:** `Ctx.records()` is a method returning `Records` throughout (Tasks 2–4); the engine module is aliased `records_engine` to avoid colliding with the `records()` method (Task 2). `caps()` (not `ctx()`/`capabilities()`) is the accessor name everywhere (Task 8). `HttpResponse`/`HttpClient`/`RequestOptions` names match between Task 5 and Task 6.

---

## Out of scope (subsequent plans, each gets its own writing-plans pass)

- **Plan A2 — transactions:** `ctx.tx(fn)` (BEGIN IMMEDIATE / COMMIT / auto-ROLLBACK, `error.NestedTransaction` on nesting); fold before-hooks into the write transaction so a hook abort rolls back the write; hooks' `caps()` already bind to the txn connection (Task 8), which A2 builds on. Touches `src/db.zig` write path, `records.createGuarded`/`updateGuarded`, and the hook dispatch in `src/framework.zig`.
- **Plan A3 — the breaking ctx-first reshape:** pass `Ctx` directly to handlers/hooks/jobs (retiring `caps()` and the scattered `reader()/writer()/data()` surface), align `src/route_types.zig` + `src/codegen/*` (the typed-route RPC surface), remove the public `Data` re-export from `root.zig`, and update all three examples + `docs/framework.md` + `site/` + a Breaking changelog fragment.
