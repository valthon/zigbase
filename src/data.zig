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
/// using `app.allocator` (the gpa).
///
/// ATOMICITY: on the HTTP write path (`api/records.zig` create/update/delete),
/// `before*` record hooks now run INSIDE the triggering write's transaction. The
/// handler opens `BEGIN IMMEDIATE` before the before-hook, performs the row
/// write + access-rule guard, and only then commits; a before-hook error (or a
/// denied guard) rolls the WHOLE transaction back — so a side-write a hook issues
/// via `ev.data` / `ev.caps().records()` commits atomically with the triggering
/// write and is discarded on abort (fail closed). NOTE: ops issued through a `Data`
/// still allocate their returned record on the gpa (app.allocator), not a request
/// arena; hooks that keep a side-write's result should copy what they need.
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

    pub fn findById(self: Data, col_name: []const u8, id: []const u8) !?std.json.Value {
        const col = (try collections.get(self.app.allocator, self.conn, col_name)) orelse return null;
        return records.get(self.app.allocator, self.conn, col, id);
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
        const col = (try collections.get(self.app.allocator, self.conn, col_name)) orelse return error.UnknownCollection;
        if (col.type != .auth) return records.create(self.app.allocator, self.io, self.conn, col, value);
        // Surface the same error as the non-auth path (records.create) for a non-object
        // value, rather than applyProvision's misleading PasswordTooShort.
        if (value != .object) return error.NotObject;
        const prepped = try auth.applyProvision(self.io, self.app.allocator, value, col.options.auth.minPasswordLength);
        // applyProvision allocates duped keys + cred strings; records.create only reads
        // `prepped` (it returns a freshly-allocated record), so we own and free it here.
        defer auth.freeProvisioned(self.app.allocator, prepped);
        return records.create(self.app.allocator, self.io, self.conn, col, prepped);
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
    const d = Data{ .app = &app, .conn = &conn, .io = io };

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
    const d = Data{ .app = &app, .conn = &conn, .io = io };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "title", .{ .string = "hello" });
    try std.testing.expectError(error.UnknownCollection, d.create("nope", .{ .object = obj }));

    // findById intentionally collapses unknown-collection and missing-record to null.
    try std.testing.expect((try d.findById("nope", "x")) == null);
}
