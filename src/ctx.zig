const std = @import("std");
const App = @import("app.zig").App;
const db = @import("db.zig");
const request = @import("request.zig");
const events = @import("events.zig");
const Data = @import("data.zig").Data;
const records_engine = @import("records.zig");
const migrations = @import("migrations.zig");
const collections = @import("collections.zig");
const schema = @import("schema.zig");
const expand_mod = @import("query/expand.zig");
const http_client = @import("http_client.zig");
const error_mod = @import("api/error.zig");
const http_mod = @import("http.zig");
const auth_helpers = @import("auth_helpers.zig");

pub const Ctx = struct {
    app: *App,
    arena: std.mem.Allocator,
    rctx: request.RequestContext = .{},
    /// Non-null inside a record hook: the hook's in-transaction connection. When set,
    /// ALL reads and writes use it (acquiring the pool writer here would deadlock).
    bound_conn: ?*db.Db = null,
    /// Lazily checked-out reader, cached for the Ctx lifetime (route/job context only).
    reader: ?events.ReaderData = null,
    /// Stashed error from ctx.fail/ctx.invalid; consumed by errorResponse(error.Handled).
    handled: ?error_mod.ApiError = null,
    /// The raw HTTP request context. Non-null for route handlers; null for job/hook contexts
    /// where there is no HTTP request. Required by `issueSession`.
    request: ?*http_mod.RequestCtx = null,

    /// The resolved identity of the authenticated principal for this request.
    /// `id` and `collection` are empty strings when no auth record is present
    /// (e.g. a superuser-only token with no associated record, or a job/hook ctx).
    pub const User = struct {
        id: []const u8,
        collection: []const u8,
        is_superuser: bool,
    };

    /// Derive the authenticated identity from the request context.
    /// Returns null for anonymous contexts (no auth record and not a superuser).
    pub fn user(self: *Ctx) ?User {
        if (!self.rctx.is_superuser and self.rctx.auth == null) return null;
        const id: []const u8 = blk: {
            const auth_val = self.rctx.auth orelse break :blk "";
            if (auth_val != .object) break :blk "";
            const id_field = auth_val.object.get("id") orelse break :blk "";
            break :blk switch (id_field) {
                .string => |s| s,
                else => "",
            };
        };
        return .{
            .id = id,
            .collection = "",
            .is_superuser = self.rctx.is_superuser,
        };
    }

    /// Mint a session for a known record via the audited seam (`.custom` method tag).
    /// Acquires the DB writer, calls `auth_helpers.issueSession`, releases the writer,
    /// and returns the signed JWT + 2 cookies.
    ///
    /// WARNING: this function acquires the pool writer internally. Do NOT call it while
    /// already holding the writer (e.g. inside `ctx.tx`, from a before-hook, or with a
    /// bound_conn set) — it would deadlock permanently. In those cases, call
    /// `zigbase.auth.issueSession(self.request.?, bound_conn, collection, record_id)`
    /// directly with the connection you already hold.
    ///
    /// NOTE: full session verbs (clearSession, refresh, revoke) arrive with Theme D.
    pub fn issueSession(self: *Ctx, collection: []const u8, record_id: []const u8) !auth_helpers.Issued {
        const conn = self.app.pool.acquireWriter();
        defer self.app.pool.releaseWriter();
        return auth_helpers.issueSession(self.request.?, conn, collection, record_id);
    }

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

    /// Returns a Records namespace bound to this Ctx for read operations.
    pub fn records(self: *Ctx) Records {
        return .{ .ctx = self };
    }

    /// Run `f` inside an IMMEDIATE transaction on the writer connection.
    /// All Records writes inside `f` reuse the bound connection — no deadlock.
    /// Returns error.NestedTransaction when called from an already-bound Ctx.
    pub fn tx(self: *Ctx, comptime T: type, f: *const fn (t: *Tx) anyerror!T) !T {
        if (self.bound_conn != null) return error.NestedTransaction;
        const conn = self.app.pool.acquireWriter();
        defer self.app.pool.releaseWriter();
        try conn.beginImmediate();
        var t = Tx{ .inner = .{ .app = self.app, .arena = self.arena, .rctx = self.rctx, .bound_conn = conn } };
        defer t.inner.deinit();
        const result = f(&t) catch |e| {
            conn.rollback() catch {};
            return e;
        };
        conn.commit() catch |e| {
            conn.rollback() catch {};
            return e;
        };
        return result;
    }

    /// Returns an outbound HTTP client bound to this Ctx's arena and the app's io.
    pub fn http(self: *Ctx) http_client.HttpClient {
        return .{ .alloc = self.arena, .io = self.app.io };
    }

    /// Sentinel error type returned by fail/invalid so callers can propagate.
    pub const FailError = error{Handled};

    /// Stash a custom status+message error and return error.Handled for propagation.
    pub fn fail(self: *Ctx, status: u16, message: []const u8) FailError {
        self.handled = .{ .status = status, .message = message };
        return error.Handled;
    }

    /// Stash a validation error (400 with field details) and return error.Handled.
    pub fn invalid(self: *Ctx, fields: []const error_mod.FieldError) FailError {
        self.handled = error_mod.ApiError.validation(fields);
        return error.Handled;
    }

    /// Map any error to an http.Response. error.Handled renders the stashed ApiError;
    /// known errors map to canonical status codes; anything else → 500 (no detail leaked).
    pub fn errorResponse(self: *Ctx, err: anyerror) http_mod.Response {
        const ae: error_mod.ApiError = switch (err) {
            error.Handled => self.handled orelse error_mod.ApiError.internal(),
            error.NotFound => error_mod.ApiError.notFound(),
            error.BadRequest => error_mod.ApiError.badRequest("Bad request."),
            error.Conflict => error_mod.ApiError.conflict("Conflict."),
            error.Forbidden => error_mod.ApiError.forbidden(),
            error.Unauthorized => error_mod.ApiError.unauthorized(),
            else => error_mod.ApiError.internal(),
        };
        return ae.toResponse(self.arena) catch
            error_mod.ApiError.internal().toResponse(self.arena) catch unreachable;
    }
};

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
        const data = try self.dataRead();
        var rec = (try data.findById(collection, id)) orelse return null;
        try self.applyExpand(collection, &rec, opts.expand);
        return rec;
    }

    pub fn list(self: Records, collection: []const u8, opts: ListOptions) !records_engine.ListResult {
        const q = records_engine.ListQuery{
            .filter = opts.filter,
            .sort = opts.sort,
            .page = opts.page,
            .perPage = opts.perPage,
            .limit = opts.limit,
            .cursor = opts.cursor,
            .rctx = &self.ctx.rctx,
            .io = self.ctx.app.io,
        };
        const result = try (try self.dataRead()).list(collection, q);
        if (opts.expand) |spec| if (spec.len > 0) {
            const conn = try self.ctx.connForRead();
            if (try collections.get(self.ctx.app.allocator, conn, collection)) |col| {
                for (result.items) |*item| {
                    try expand_mod.expand(self.ctx.app.allocator, conn, col, item, spec, 0, &self.ctx.rctx);
                }
            }
        };
        return result;
    }

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

    /// Resolve the collection and run expand on `rec` in-place.
    /// CRUD operations in Records bypass collection rules (matching Data behaviour);
    /// expand applies the *target* collection's viewRule under the Ctx identity.
    /// A job ctx with rctx = .{} gets the anonymous view.
    fn applyExpand(self: Records, collection: []const u8, rec: *std.json.Value, spec: ?[]const u8) !void {
        const s = spec orelse return;
        if (s.len == 0) return;
        const conn = try self.ctx.connForRead();
        const col = (try collections.get(self.ctx.app.allocator, conn, collection)) orelse return;
        try expand_mod.expand(self.ctx.app.allocator, conn, col, rec, s, 0, &self.ctx.rctx);
    }
};

/// A transaction scope: wraps an inner Ctx whose bound_conn is set so that
/// all Records writes inside the callback reuse the in-progress transaction.
pub const Tx = struct {
    inner: Ctx,

    pub fn records(self: *Tx) Records {
        return .{ .ctx = &self.inner };
    }
};

// ---------------------------------------------------------------------------
// Test harness (file-backed pool, posts collection) — matches TestEnv pattern
// from events.zig.
// ---------------------------------------------------------------------------

const CtxTestEnv = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,
    arena: std.heap.ArenaAllocator,
    app: App,

    fn init() !*CtxTestEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(CtxTestEnv);
        errdefer ga.destroy(env);

        env.tmp = std.testing.tmpDir(.{});
        errdefer env.tmp.cleanup();

        const dir_path = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
        defer ga.free(dir_path);
        env.db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
        errdefer ga.free(env.db_path);

        env.pool = try db.Pool.init(ga, std.testing.io, env.db_path);
        errdefer env.pool.deinit();

        env.arena = std.heap.ArenaAllocator.init(ga);
        errdefer env.arena.deinit();
        const a = env.arena.allocator();
        const io = std.testing.io;

        // Migrate + create a collection on the writer so create/findById work.
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try w.exec("PRAGMA foreign_keys=ON;");
            try migrations.run(w);
            const fields = [_]schema.Field{
                .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
            };
            _ = try collections.create(a, io, w, .{ .id = "", .name = "posts", .fields = &fields });
        }

        env.app = App{ .allocator = a, .io = io, .pool = &env.pool };
        return env;
    }

    /// Like init(), but also provisions an `authors` collection and a `posts.author`
    /// single-relation field so expand tests have something to resolve.
    fn initWithRelation() !*CtxTestEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(CtxTestEnv);
        errdefer ga.destroy(env);

        env.tmp = std.testing.tmpDir(.{});
        errdefer env.tmp.cleanup();

        const dir_path = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
        defer ga.free(dir_path);
        env.db_path = try std.fmt.allocPrintSentinel(ga, "{s}/test.db", .{dir_path}, 0);
        errdefer ga.free(env.db_path);

        env.pool = try db.Pool.init(ga, std.testing.io, env.db_path);
        errdefer env.pool.deinit();

        env.arena = std.heap.ArenaAllocator.init(ga);
        errdefer env.arena.deinit();
        const a = env.arena.allocator();
        const io = std.testing.io;

        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try w.exec("PRAGMA foreign_keys=ON;");
            try migrations.run(w);
            const author_fields = [_]schema.Field{
                .{ .id = "a1", .name = "name", .options = .{ .text = .{} } },
            };
            const authors = try collections.create(a, io, w, .{ .id = "", .name = "authors", .fields = &author_fields, .viewRule = "@public" });
            const post_fields = [_]schema.Field{
                .{ .id = "p1", .name = "title", .required = true, .options = .{ .text = .{} } },
                .{ .id = "p2", .name = "author", .options = .{ .relation = .{ .targetCollectionId = authors.id, .maxSelect = 1 } } },
            };
            _ = try collections.create(a, io, w, .{ .id = "", .name = "posts", .fields = &post_fields });
        }

        env.app = App{ .allocator = a, .io = io, .pool = &env.pool };
        return env;
    }

    fn deinit(env: *CtxTestEnv) void {
        const ga = std.testing.allocator;
        env.arena.deinit();
        env.pool.deinit();
        ga.free(env.db_path);
        env.tmp.cleanup();
        ga.destroy(env);
    }
};

test "ctx.user() reflects the resolved auth identity; anonymous is null" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var anon = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer anon.deinit();
    try std.testing.expect(anon.user() == null);
    // A superuser rctx yields a User with is_superuser=true.
    var su = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{ .is_superuser = true } };
    defer su.deinit();
    try std.testing.expect(su.user().?.is_superuser);
}

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

    const page = try ctx.records().list("posts", .{ .sort = "title" });
    try std.testing.expectEqual(@as(usize, 2), page.items.len);

    const one = (try ctx.records().get("posts", id, .{})).?;
    try std.testing.expectEqualStrings("alpha", one.object.get("title").?.string);
}

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

test "ctx.http() returns a client bound to the ctx arena and io" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var ctx = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer ctx.deinit();
    const client = ctx.http();
    // Assert the client is bound to the app's io (same userdata pointer).
    try std.testing.expect(client.io.userdata == env.app.io.userdata);
    // Assert two successive calls return clients with the same arena allocator pointer.
    const client2 = ctx.http();
    try std.testing.expect(client.alloc.ptr == client2.alloc.ptr);
    // Assert the allocator pointer matches the ctx's arena allocator.
    try std.testing.expect(client.alloc.ptr == ctx.arena.ptr);
}

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

test "ctx.records expand nests the related record under \"expand\"" {
    const env = try CtxTestEnv.initWithRelation();
    defer env.deinit();
    const a = env.arena.allocator();

    const post_id = blk: {
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

    const post = (try ctx.records().get("posts", post_id, .{ .expand = "author" })).?;
    const exp = post.object.get("expand").?.object;
    try std.testing.expectEqualStrings("Ada", exp.get("author").?.object.get("name").?.string);
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

test "ctx.tx commits all writes atomically" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    const a = env.arena.allocator();
    var ctx = Ctx{ .app = &env.app, .arena = a, .rctx = .{} };
    defer ctx.deinit();

    try ctx.tx(void, txnTwoInserts);

    const page = try ctx.records().list("posts", .{});
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
}

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
