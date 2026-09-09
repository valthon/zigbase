//! Explicit anonymous record-view caching. All store access is serialized by the
//! owning pool's writer mutex; never reuse the store with a different connection.
const std = @import("std");
const db = @import("db.zig");
const http = @import("http.zig");
const collections = @import("collections.zig");
const record_api = @import("api/records.zig");
const schema = @import("schema.zig");
const c = @import("c.zig").c;

pub const Config = struct {
    collections: []const []const u8 = &.{},
    max_entries: u16 = 64,
    max_body_bytes: u32 = 16384,
    ttl_ms: u32 = 1000,
};

pub fn resolve(comptime cfg: anytype) Config {
    if (!@hasField(@TypeOf(cfg), "public_response_cache")) return .{};
    if (!@import("build_options").public_response_cache) @compileError(".public_response_cache requires -Dpublic-response-cache=true");
    if (@typeInfo(@TypeOf(cfg.public_response_cache)) != .@"struct") @compileError(".public_response_cache must be a struct");
    var result: Config = .{};
    for (std.meta.fields(@TypeOf(cfg.public_response_cache))) |f| {
        if (!@hasField(Config, f.name)) @compileError("unknown .public_response_cache key: " ++ f.name);
        @field(result, f.name) = @field(cfg.public_response_cache, f.name);
    }
    if (result.max_entries == 0 or result.max_entries > 256 or result.max_body_bytes == 0 or result.max_body_bytes > 65536 or result.ttl_ms == 0 or result.ttl_ms > 60000)
        @compileError("public response cache requires 1..256 entries, 1..65536 body bytes and 1..60000 ttl_ms");
    if (result.collections.len > 64) @compileError("public response cache supports at most 64 collection names");
    for (result.collections) |name| if (!schema.isValidIdentifier(name) or name.len > 64)
        @compileError("public response cache collections must be valid identifiers of at most 64 bytes");
    return result;
}

const Stamp = struct {
    changes: i64,
    data: i64,
    pager_version: u32,

    fn read(conn: *db.Db) !Stamp {
        const handle = if (comptime @import("build_options").postgres) switch (conn.*) {
            .sqlite => |sqlite| sqlite.handle,
            .postgres => return error.PublicResponseCacheRequiresSqlite,
        } else conn.handle;
        // PRAGMA opens a read transaction, refreshing the pager's knowledge of
        // foreign commits. File-control alone only reads the cached pager version.
        const data = try scalar(conn, "PRAGMA data_version");
        var pager_version: c_uint = 0;
        if (c.sqlite3_file_control(handle, "main", c.SQLITE_FCNTL_DATA_VERSION, &pager_version) != c.SQLITE_OK)
            return error.MissingCacheGeneration;
        return .{ .changes = c.sqlite3_total_changes64(handle), .data = data, .pager_version = pager_version };
    }
    fn eql(a: Stamp, b: Stamp) bool {
        return std.meta.eql(a, b);
    }
};

fn scalar(conn: *db.Db, sql: [:0]const u8) !i64 {
    var st = try conn.prepare(sql);
    defer st.finalize();
    if (!try st.step()) return error.MissingCacheGeneration;
    return st.columnInt(0);
}

const Entry = struct {
    key: [256]u8 = undefined,
    key_len: u16 = 0,
    body: ?[]u8 = null,
    expires: i128 = 0,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    config: Config,
    entries: []Entry,
    stamp: ?Stamp = null,
    next: usize = 0,

    pub fn create(a: std.mem.Allocator, config: Config) !*Store {
        const self = try a.create(Store);
        errdefer a.destroy(self);
        const entries = try a.alloc(Entry, config.max_entries);
        @memset(entries, .{});
        self.* = .{ .allocator = a, .config = config, .entries = entries };
        return self;
    }
    pub fn destroy(self: *Store) void {
        self.clear();
        self.allocator.free(self.entries);
        self.allocator.destroy(self);
    }
    fn clear(self: *Store) void {
        for (self.entries) |*e| {
            if (e.body) |body| self.allocator.free(body);
            e.* = .{};
        }
        self.next = 0;
    }
    fn observe(self: *Store, stamp: Stamp) void {
        if (self.stamp == null or !self.stamp.?.eql(stamp)) self.clear();
        self.stamp = stamp;
    }
    /// Borrow under the writer mutex; invalidated by any store mutation.
    fn peek(self: *Store, key: []const u8, now: i128) ?[]const u8 {
        for (self.entries) |*e| if (e.body) |body| {
            if (now >= e.expires) {
                self.allocator.free(body);
                e.* = .{};
            } else if (std.mem.eql(u8, e.key[0..e.key_len], key)) return body;
        };
        return null;
    }
    fn put(self: *Store, key: []const u8, body: []const u8, now: i128) !void {
        if (key.len > 256 or body.len > self.config.max_body_bytes) return;
        const e = &self.entries[self.next];
        // Free before allocating: even a replacement never exceeds the configured bound.
        if (e.body) |old| self.allocator.free(old);
        e.* = .{};
        e.body = try self.allocator.dupe(u8, body);
        @memcpy(e.key[0..key.len], key);
        e.key_len = @intCast(key.len);
        e.expires = now + self.config.ttl_ms;
        self.next = (self.next + 1) % self.entries.len;
    }
};

fn eligible(col: schema.Collection) bool {
    return col.type == .base and col.options.ttl_field == null and col.options.tenant_field == null and col.options.abilities == null and
        std.mem.eql(u8, col.viewRule orelse "", "@public");
}

/// Returns null for unsupported requests, preserving their ordinary handler path.
/// Eligibility is read directly on fills and validated by the whole-database
/// generation on hits, never by the asynchronously refreshed schema cache.
pub fn view(ctx: *http.RequestCtx) !?http.Response {
    const app = ctx.app.?;
    const store = app.public_response_cache orelse return null;
    if (ctx.method != .GET or ctx.authorization.len != 0 or ctx.cookie_header.len != 0 or ctx.header("authorization") != null or ctx.header("cookie") != null or ctx.query.len != 0 or app.tenancy.enabled or ctx.path.len > 256) return null;
    const name = ctx.param("col") orelse return null;
    const rid = ctx.param("id") orelse return null;
    var allowed = false;
    for (store.config.collections) |configured| if (std.mem.eql(u8, configured, name)) {
        allowed = true;
        break;
    };
    if (!allowed) return null;
    const conn = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const before = try Stamp.read(conn);
    store.observe(before);
    const now = std.Io.Timestamp.now(app.io, .awake).toMilliseconds();
    if (store.peek(ctx.path, now)) |body| {
        // Another SQLite connection may commit even while our local writer mutex is held.
        if (before.eql(try Stamp.read(conn))) return .{ .status = 200, .body = try ctx.allocator.a.dupe(u8, body) };
        // Discard the borrow before clearing; stale hits allocate no response copy.
        store.clear();
        return try freshResponse(ctx, conn, name, rid);
    }
    const col = (try collections.get(ctx.allocator.a, conn, name)) orelse return try @import("api/error.zig").ApiError.notFound().toResponse(ctx.allocator.a);
    defer col.deinit(ctx.allocator.a);
    if (!std.mem.eql(u8, col.name, name) or !eligible(col)) return try record_api.viewResolved(ctx, conn, col, rid);
    const response = try record_api.viewResolved(ctx, conn, col, rid);
    const after = try Stamp.read(conn);
    if (!before.eql(after)) {
        store.observe(after);
        return try freshResponse(ctx, conn, name, rid);
    }
    if (response.status == 200) {
        const inserted_at = std.Io.Timestamp.now(app.io, .awake).toMilliseconds();
        try store.put(ctx.path, response.body, inserted_at);
    }
    return response;
}

fn freshResponse(ctx: *http.RequestCtx, conn: *db.Db, name: []const u8, rid: []const u8) !http.Response {
    const col = (try collections.get(ctx.allocator.a, conn, name)) orelse return try @import("api/error.zig").ApiError.notFound().toResponse(ctx.allocator.a);
    defer col.deinit(ctx.allocator.a);
    return record_api.viewResolved(ctx, conn, col, rid);
}

test "bounded cache expiry eviction oversized response and generation invalidation" {
    const a = std.testing.allocator;
    const s = try Store.create(a, .{ .max_entries = 1, .max_body_bytes = 4, .ttl_ms = 10 });
    defer s.destroy();
    const stamp: Stamp = .{ .changes = 1, .data = 1, .pager_version = 1 };
    s.observe(stamp);
    try s.put("one", "body", 100);
    const hit = s.peek("one", 109).?;
    try std.testing.expectEqualStrings("body", hit);
    try std.testing.expectEqual(@as(?[]const u8, null), s.peek("one", 110));
    try s.put("one", "body", 100);
    try s.put("two", "next", 100);
    try std.testing.expectEqual(@as(?[]const u8, null), s.peek("one", 101));
    try s.put("large", "12345", 100);
    try std.testing.expectEqual(@as(?[]const u8, null), s.peek("large", 101));
    s.observe(.{ .changes = 2, .data = 1, .pager_version = 1 });
    try std.testing.expectEqual(@as(?[]const u8, null), s.peek("two", 101));
}

test "generation observes raw writes rollback and DDL" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    const initial = try Stamp.read(&conn);
    try conn.exec("CREATE TABLE test_cache(id INTEGER)");
    const ddl = try Stamp.read(&conn);
    try std.testing.expect(!initial.eql(ddl));
    try conn.exec("BEGIN; INSERT INTO test_cache VALUES(1); ROLLBACK;");
    try std.testing.expect(!ddl.eql(try Stamp.read(&conn)));
}

test "eligibility excludes contextual authorization and time-dependent records" {
    var col: schema.Collection = .{ .id = "posts", .name = "posts", .fields = &.{}, .viewRule = "@public" };
    try std.testing.expect(eligible(col));
    col.type = .auth;
    try std.testing.expect(!eligible(col));
    col.type = .view;
    try std.testing.expect(!eligible(col));
    col.type = .base;
    col.options.ttl_field = "expires";
    try std.testing.expect(!eligible(col));
    col.options.ttl_field = null;
    col.options.tenant_field = "account";
    try std.testing.expect(!eligible(col));
    col.options.tenant_field = null;
    col.options.abilities = .{};
    try std.testing.expect(!eligible(col));
    col.options.abilities = null;
    for ([_]?[]const u8{ null, "", "@request.auth.id != ''" }) |rule| {
        col.viewRule = rule;
        try std.testing.expect(!eligible(col));
    }
}
