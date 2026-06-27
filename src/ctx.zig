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

    /// Returns a Records namespace bound to this Ctx for read operations.
    pub fn records(self: *Ctx) Records {
        return .{ .ctx = self };
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
