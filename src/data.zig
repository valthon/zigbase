const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const records = @import("records.zig");
const migrations = @import("migrations.zig");
const App = @import("app.zig").App;

/// Connection-bound, curated record operations. Hooks, custom routes, and jobs
/// receive a `Data` rather than a raw connection. Ops run on the passed `conn`
/// using `app.allocator` (the gpa).
///
/// ATOMICITY (as shipped): NOT atomic for `before*` record hooks. The triggering
/// write opens its transaction inside records.createGuarded/updateGuarded, which run
/// AFTER the before-hook returns; so side-writes a hook issues via `ev.data` are
/// committed independently of (and before) the triggering write, and their results
/// are gpa-allocated rather than request-scoped. (A later plan will route these
/// through a request arena / a true shared transaction.)
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
