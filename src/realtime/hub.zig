const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const rules = @import("../rules.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const migrations = @import("../migrations.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const Conn = connection.Conn;

pub const DeliverError = rules.RuleError;

/// Combine clauses with `&&`, each parenthesized: `(c1) && (c2)`.
fn combineClauses(alloc: std.mem.Allocator, clauses: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (clauses, 0..) |c, i| {
        if (i > 0) try out.appendSlice(alloc, " && ");
        try out.append(alloc, '(');
        try out.appendSlice(alloc, c);
        try out.append(alloc, ')');
    }
    return out.toOwnedSlice(alloc);
}

/// Decide whether `conn` should receive an event for record `record_id` in `col` at unix time `now`.
/// create/update: authorize via viewRule AND the optional subscription filter, in one guarded query.
/// delete: id-only/coarse — delivered unless the viewRule is locked (null) and the conn isn't superuser
/// (the row is gone, so per-record re-authorization isn't possible; no record body is sent on delete).
pub fn shouldDeliver(
    alloc: std.mem.Allocator,
    reader: *db.Db,
    col: schema.Collection,
    conn: *const Conn,
    now: i64,
    action: protocol.Action,
    record_id: []const u8,
    sub_filter: ?[]const u8,
) DeliverError!bool {
    const rctx = conn.requestContext(now);

    if (action == .delete) {
        return rules.decide(col.viewRule, &rctx) != .deny_locked;
    }

    var clauses: std.ArrayList([]const u8) = .empty;
    defer clauses.deinit(alloc);
    switch (rules.decide(col.viewRule, &rctx)) {
        .deny_locked => return false,
        .allow => {},
        .check => try clauses.append(alloc, col.viewRule.?),
    }
    if (sub_filter) |f| if (f.len > 0) try clauses.append(alloc, f);
    if (clauses.items.len == 0) return true;

    const combined = try combineClauses(alloc, clauses.items);
    return rules.matches(alloc, reader, col, record_id, combined, &rctx);
}

const TestDb = struct {
    d: db.Db,
    fn init() !TestDb {
        var d = try db.Db.openMemory();
        try migrations.run(&d);
        return .{ .d = d };
    }
    fn deinit(self: *TestDb) void {
        self.d.close();
    }
    fn mkColl(self: *TestDb, a: std.mem.Allocator, name: []const u8, view_rule: ?[]const u8) !schema.Collection {
        return collections.create(a, std.testing.io, &self.d, .{
            .id = "", .name = name,
            .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
            .listRule = "", .viewRule = view_rule, .createRule = "", .updateRule = "", .deleteRule = "",
        });
    }
    fn mkRec(self: *TestDb, a: std.mem.Allocator, col: schema.Collection, owner: []const u8) ![]const u8 {
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "owner", .{ .string = owner });
        const rec = try records.create(a, std.testing.io, &self.d, col, .{ .object = data });
        return rec.object.get("id").?.string;
    }
};

fn authedConn(a: std.mem.Allocator, id: []const u8, is_super: bool) !Conn {
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = id });
    var c = Conn{};
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = is_super, .exp = 9999999999 });
    return c;
}

test "public viewRule (\"\"): create delivered to anyone, no filter" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "posts", "");
    const rid = try tdb.mkRec(a, col, "u1");
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, null));
}

test "null viewRule: superuser-only" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "locked", null);
    const rid = try tdb.mkRec(a, col, "u1");
    var anon = Conn{};
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, null));
    var su = try authedConn(a, "admin", true);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &su, 0, .create, rid, null));
}

test "macro viewRule: only the owner receives the record" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    const rid = try tdb.mkRec(a, col, "u1");
    var owner = try authedConn(a, "u1", false);
    var other = try authedConn(a, "u2", false);
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &owner, 0, .update, rid, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &other, 0, .update, rid, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .update, rid, null));
}

test "subscription filter narrows within an authorized viewRule" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "items", "");
    const rid = try tdb.mkRec(a, col, "alice");
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, "owner = \"alice\""));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &anon, 0, .create, rid, "owner = \"bob\""));
}

test "delete is id-only/coarse: delivered unless locked" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pub_col = try tdb.mkColl(a, "p", "owner = @request.auth.id");
    const locked = try tdb.mkColl(a, "l", null);
    var anon = Conn{};
    try std.testing.expect(try shouldDeliver(a, &tdb.d, pub_col, &anon, 0, .delete, "GONE", null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, locked, &anon, 0, .delete, "GONE", null));
    var su = try authedConn(a, "admin", true);
    try std.testing.expect(try shouldDeliver(a, &tdb.d, locked, &su, 0, .delete, "GONE", null));
}

test "expired identity is treated as anonymous" {
    var tdb = try TestDb.init();
    defer tdb.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try tdb.mkColl(a, "notes", "owner = @request.auth.id");
    const rid = try tdb.mkRec(a, col, "u1");
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = "u1" });
    var c = Conn{};
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = false, .exp = 100 });
    try std.testing.expect(try shouldDeliver(a, &tdb.d, col, &c, 50, .update, rid, null));
    try std.testing.expect(!try shouldDeliver(a, &tdb.d, col, &c, 200, .update, rid, null));
}
