const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const records = @import("records.zig");
const migrations = @import("migrations.zig");
const auth = @import("auth.zig");
const App = @import("app.zig").App;

/// Connection-bound, curated record operations. Hooks, custom routes, and jobs
/// receive a `Data` rather than a raw connection. Ops run on the passed `conn`
/// and allocate their returned results on `alloc` — the caller picks the lifetime:
///
/// - `ctx.records()` binds `alloc` to the per-request/per-invocation arena, so
///   results are freed automatically when the invocation ends (no manual cleanup).
/// - The lower-level `ev.writer()`/`ev.reader()` handle accessors (WriterData /
///   ReaderData) bind `alloc` to `app.allocator` (the gpa). Results from THAT
///   path are NOT arena-freed — callers must manage their lifetimes explicitly.
///
/// ATOMICITY: `before*` record hooks run INSIDE the triggering write's transaction
/// (folded in by the A2 change). The handler opens `BEGIN IMMEDIATE` before the
/// before-hook, performs the row write + access-rule guard, and commits only on
/// success; a before-hook error (or a denied guard) rolls the WHOLE transaction
/// back — so a side-write a hook issues via `ctx.records()` commits atomically with
/// the triggering write and is discarded on abort (fail closed).
///
/// Unknown-collection contract:
///   - `findById` returns `null` for BOTH an unknown collection and a missing
///     record — an intentional collapse that mirrors the HTTP layer returning 404
///     for either case.
///   - `create`, `update`, `delete`, and `list` return `error.UnknownCollection`
///     when the collection name does not resolve.
pub const Data = struct {
    app: *App,
    conn: *db.Db,
    io: std.Io,
    /// Allocator for returned results. Caller picks the lifetime (per-invocation
    /// arena on the ctx path; app.allocator for internal/test consumers).
    alloc: std.mem.Allocator,

    pub fn findById(self: Data, col_name: []const u8, id: []const u8) !?std.json.Value {
        const col = (try collections.get(self.alloc, self.conn, col_name)) orelse return null;
        return records.get(self.alloc, self.conn, col, id);
    }
    /// Create a record. On an **auth** collection this runs the same credential transforms
    /// the HTTP layer applies — the server generates a `tokenKey` (and forces
    /// `verified=false`), hashing `password` if one is supplied — so the row works with
    /// `auth.issueSession` / `auth.mintLinkToken` immediately. `password` is OPTIONAL, so a
    /// passwordless flow (magic-link signup) provisions a credential-less but usable row. A
    /// non-auth collection takes the plain insert path. (The lower-level engine
    /// `records.create` does NOT provision — use it directly only for raw import/migration.)
    /// Errors: `error.UnknownCollection` if the name doesn't resolve; `error.NotObject` if
    /// `value` isn't a JSON object; `error.PasswordTooShort` if a supplied password is too short.
    pub fn create(self: Data, col_name: []const u8, value: std.json.Value) !std.json.Value {
        const col = (try collections.get(self.alloc, self.conn, col_name)) orelse return error.UnknownCollection;
        if (col.type != .auth) return records.create(self.alloc, self.io, self.conn, col, value);
        // Surface the same error as the non-auth path (records.create) for a non-object
        // value, rather than applyProvision's misleading PasswordTooShort.
        if (value != .object) return error.NotObject;
        const prepped = try auth.applyProvision(self.io, self.alloc, value, col.options.auth.minPasswordLength);
        // applyProvision allocates duped keys + cred strings; records.create only reads
        // `prepped` (it returns a freshly-allocated record). Free on the SAME allocator
        // (a no-op on an arena, a real free on the gpa).
        defer auth.freeProvisioned(self.alloc, prepped);
        return records.create(self.alloc, self.io, self.conn, col, prepped);
    }
    pub fn update(self: Data, col_name: []const u8, id: []const u8, value: std.json.Value) !?std.json.Value {
        const col = (try collections.get(self.alloc, self.conn, col_name)) orelse return error.UnknownCollection;
        return records.update(self.alloc, self.conn, col, id, value);
    }
    pub fn delete(self: Data, col_name: []const u8, id: []const u8) !bool {
        const col = (try collections.get(self.alloc, self.conn, col_name)) orelse return error.UnknownCollection;
        return records.delete(self.alloc, self.conn, col, id);
    }
    pub fn list(self: Data, col_name: []const u8, q: records.ListQuery) !records.ListResult {
        const col = (try collections.get(self.alloc, self.conn, col_name)) orelse return error.UnknownCollection;
        return records.list(self.alloc, self.conn, col, q);
    }

    // -----------------------------------------------------------------------
    // Key→value/settings store (#87). Small, mutable, superuser-managed values
    // over the internal `_kv` table. Values are opaque TEXT — a caller wanting
    // structured data stringifies/parses JSON itself. Feature flags (#88) are a
    // typed bool view over this same store (see `Ctx.flag`).
    // -----------------------------------------------------------------------

    /// Fetch the value for `key`, or `null` if absent. The returned slice is duped
    /// onto `self.alloc` (the caller-chosen lifetime: the per-invocation arena on
    /// the ctx path) so it outlives the finalized statement.
    pub fn kvGet(self: Data, key: []const u8) !?[]const u8 {
        var st = try self.conn.prepare("SELECT value FROM \"_kv\" WHERE key = ?1;");
        defer st.finalize();
        try st.bindText(1, key);
        if (!(try st.step())) return null;
        return try self.alloc.dupe(u8, st.columnText(0));
    }

    /// Upsert `key`→`value`. Preserves the original `created` timestamp across updates
    /// and bumps `updated`.
    pub fn kvSet(self: Data, key: []const u8, value: []const u8) !void {
        var st = try self.conn.prepare(
            \\INSERT INTO "_kv"(key,value,created,updated)
            \\VALUES(?1,?2,datetime('now'),datetime('now'))
            \\ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated=datetime('now');
        );
        defer st.finalize();
        try st.bindText(1, key);
        try st.bindText(2, value);
        _ = try st.step();
    }

    /// Delete `key`. Returns whether a row existed.
    pub fn kvDelete(self: Data, key: []const u8) !bool {
        var st = try self.conn.prepare("DELETE FROM \"_kv\" WHERE key = ?1;");
        defer st.finalize();
        try st.bindText(1, key);
        _ = try st.step();
        return self.conn.changesCount() > 0;
    }

    /// One entry in the KV/settings store.
    pub const KvEntry = struct { key: []const u8, value: []const u8, created: []const u8, updated: []const u8 };

    /// List all KV/settings entries (ordered by key). Each field is duped onto
    /// `self.alloc`. Intended for the superuser settings admin surface.
    pub fn kvList(self: Data) ![]KvEntry {
        var out: std.ArrayList(KvEntry) = .empty;
        var st = try self.conn.prepare("SELECT key, value, created, updated FROM \"_kv\" ORDER BY key;");
        defer st.finalize();
        while (try st.step()) {
            try out.append(self.alloc, .{
                .key = try self.alloc.dupe(u8, st.columnText(0)),
                .value = try self.alloc.dupe(u8, st.columnText(1)),
                .created = try self.alloc.dupe(u8, st.columnText(2)),
                .updated = try self.alloc.dupe(u8, st.columnText(3)),
            });
        }
        return out.toOwnedSlice(self.alloc);
    }
};

test "Data kvSet/kvGet/kvDelete round-trip; upsert preserves created" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var app = App{ .allocator = a, .io = io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = io, .alloc = a };

    // Missing key -> null.
    try std.testing.expect((try d.kvGet("missing")) == null);

    // Set then get round-trips.
    try d.kvSet("greeting", "hello");
    try std.testing.expectEqualStrings("hello", (try d.kvGet("greeting")).?);

    // Capture created, then update and assert value changed but created preserved.
    var st = try conn.prepare("SELECT created, updated FROM \"_kv\" WHERE key='greeting';");
    try std.testing.expect((try st.step()));
    const created0 = try a.dupe(u8, st.columnText(0));
    st.finalize();

    try d.kvSet("greeting", "world");
    try std.testing.expectEqualStrings("world", (try d.kvGet("greeting")).?);
    var st2 = try conn.prepare("SELECT created FROM \"_kv\" WHERE key='greeting';");
    defer st2.finalize();
    try std.testing.expect((try st2.step()));
    try std.testing.expectEqualStrings(created0, st2.columnText(0)); // created unchanged

    // Delete reports existence, then absence.
    try std.testing.expect(try d.kvDelete("greeting"));
    try std.testing.expect((try d.kvGet("greeting")) == null);
    try std.testing.expect(!(try d.kvDelete("greeting")));
}

test "Data.kvList returns all entries ordered by key" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App{ .allocator = a, .io = std.testing.io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = std.testing.io, .alloc = a };

    try std.testing.expectEqual(@as(usize, 0), (try d.kvList()).len);
    try d.kvSet("b", "2");
    try d.kvSet("a", "1");
    const list = try d.kvList();
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("a", list[0].key);
    try std.testing.expectEqualStrings("1", list[0].value);
    try std.testing.expectEqualStrings("b", list[1].key);
}

test "Data.create then findById round-trips a record" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrations.run(&conn);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } },
    };
    _ = try collections.create(a, io, &conn, .{ .id = "", .name = "posts", .fields = &fields });

    var app = App{ .allocator = a, .io = io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = io, .alloc = a };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "title", .{ .string = "hello" });
    const created = try d.create("posts", .{ .object = obj });
    const id = created.object.get("id").?.string;

    const found = (try d.findById("posts", id)).?;
    try std.testing.expectEqualStrings("hello", found.object.get("title").?.string);
}

test "Data.create on an unknown collection errors; findById collapses to null" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrations.run(&conn);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var app = App{ .allocator = a, .io = io, .pool = undefined };
    const d = Data{ .app = &app, .conn = &conn, .io = io, .alloc = a };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "title", .{ .string = "hello" });
    try std.testing.expectError(error.UnknownCollection, d.create("nope", .{ .object = obj }));

    // findById intentionally collapses unknown-collection and missing-record to null.
    try std.testing.expect((try d.findById("nope", "x")) == null);
}
