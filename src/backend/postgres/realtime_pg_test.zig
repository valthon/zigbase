//! Live realtime tests for the Postgres arm (issue #159, PR-6 core + PR-6b cross-instance).
//!
//! Two things are proven END-TO-END against a real PostgreSQL:
//!
//!   1. **PR-6 realtime authz parity.** `hub.shouldDeliver` — the per-subscriber delivery authz the
//!      WebSocket path runs in `onChannelMessage` — produces the SAME allow/deny decisions on
//!      Postgres as on SQLite for create/update (guarded SELECT against the live row, dialect-correct
//!      `$n`/`now()`) AND for delete (the pre-delete SNAPSHOT path, which evaluates the rule in a
//!      throwaway in-memory SQLite sandbox — `db.Db.openMemory()` is always the SQLite arm, so the
//!      delete-snapshot authz is backend-agnostic without any `:memory:` Postgres analog).
//!
//!   2. **PR-6b cross-instance LISTEN/NOTIFY.** A change `NOTIFY`'d on connection A is received by a
//!      listener on connection B (a second app instance sharing one database), decoded, and would be
//!      delivered to B's subscribers with B's authz applied. This is the capability that makes
//!      multi-instance Postgres realtime correct.
//!
//! They run only under `-Dpostgres=true` and require a reachable PostgreSQL; a connectivity/auth
//! failure SKIPS. Schema isolation mirrors `crud_tests.zig` (throwaway `CREATE SCHEMA` + search_path).

const std = @import("std");
const dbm = @import("../../db.zig");
const records = @import("../../records.zig");
const schema = @import("../../schema.zig");
const rules = @import("../../rules.zig");
const dialect_mod = @import("../../sql/dialect.zig");
const hub = @import("../../realtime/hub.zig");
const protocol = @import("../../realtime/protocol.zig");
const connection = @import("../../realtime/connection.zig");
const pg_bridge = @import("../../realtime/pg_bridge.zig");
const pgtests = @import("tests.zig");

const Dialect = dialect_mod.Dialect;
const Conn = connection.Conn;

fn openOrSkip(a: std.mem.Allocator, io: std.Io) !?dbm.Db {
    return dbm.Db.openPostgres(a, io, pgtests.testUrl()) catch |e| switch (e) {
        error.OpenFailed => null,
        else => e,
    };
}

var schema_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn enterTempSchema(a: std.mem.Allocator, d: *dbm.Db) ![:0]const u8 {
    const n = schema_counter.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(a, "zb_rt_{d}", .{n});
    try d.exec(try std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA \"{s}\";", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "SET search_path TO \"{s}\";", .{name}, 0));
    return std.fmt.allocPrintSentinel(a, "{s}", .{name}, 0);
}

fn dropTempSchema(a: std.mem.Allocator, d: *dbm.Db, name: []const u8) void {
    const sql = std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0) catch return;
    d.exec(sql) catch {};
}

fn provisionPg(a: std.mem.Allocator, d: *dbm.Db, col: schema.Collection) !void {
    const tc = Dialect.postgres.textCollate();
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(a, try std.fmt.allocPrint(a, "CREATE TABLE \"{s}\" (\"id\" TEXT{s} PRIMARY KEY, \"created\" TEXT{s}, \"updated\" TEXT{s}", .{ col.name, tc, tc, tc }));
    for (col.fields) |f| {
        const ty = Dialect.postgres.sqlType(f.storageClass());
        const collate = if (std.mem.eql(u8, ty, "TEXT")) tc else "";
        try sql.appendSlice(a, try std.fmt.allocPrint(a, ", \"{s}\" {s}{s}", .{ f.name, ty, collate }));
    }
    try sql.appendSlice(a, ");");
    try d.exec(try std.fmt.allocPrintSentinel(a, "{s}", .{sql.items}, 0));
}

fn authedConn(a: std.mem.Allocator, id: []const u8, is_super: bool) !Conn {
    var rec: std.json.ObjectMap = .empty;
    try rec.put(a, "id", .{ .string = id });
    var c = Conn{};
    c.setAuth(.{ .record = .{ .object = rec }, .is_superuser = is_super, .exp = 9999999999 });
    return c;
}

fn strVal(s: []const u8) std.json.Value {
    return .{ .string = s };
}

// ---- PR-6: realtime delivery authz parity on Postgres -----------------------

test "pg realtime: owner-scoped create/update delivery — only the owner is authorized" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const col = schema.Collection{
        .id = "c1",
        .name = "notes",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
        .viewRule = "owner = @request.auth.id",
    };
    try provisionPg(al, &d, col);

    var data: std.json.ObjectMap = .empty;
    try data.put(al, "owner", strVal("u1"));
    const rec = try records.create(al, io, &d, col, .{ .object = data });
    const rid = rec.object.get("id").?.string;

    var owner = try authedConn(al, "u1", false);
    var other = try authedConn(al, "u2", false);
    var anon = Conn{};

    // create/update authorize against the LIVE row via the dialect-correct guarded SELECT on PG.
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, col, &owner, 0, .create, rid, null, null));
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, col, &other, 0, .create, rid, null, null));
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, col, &anon, 0, .update, rid, null, null));
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, col, &owner, 0, .update, rid, null, null));
}

test "pg realtime: @public delivers to anyone; locked only to superusers" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const pub_col = schema.Collection{
        .id = "c2",
        .name = "posts",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
        .viewRule = rules.public_sentinel,
    };
    const locked_col = schema.Collection{
        .id = "c3",
        .name = "secrets",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
        .viewRule = null,
    };
    try provisionPg(al, &d, pub_col);
    try provisionPg(al, &d, locked_col);

    var pd: std.json.ObjectMap = .empty;
    try pd.put(al, "owner", strVal("u1"));
    const prec = try records.create(al, io, &d, pub_col, .{ .object = pd });
    const prid = prec.object.get("id").?.string;

    var anon = Conn{};
    var su = try authedConn(al, "admin", true);
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, pub_col, &anon, 0, .create, prid, null, null));
    // locked: anon denied, superuser allowed (id-only delete path, no row needed).
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, locked_col, &anon, 0, .delete, "GONE", null, null));
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, locked_col, &su, 0, .delete, "GONE", null, null));
}

test "pg realtime: owner-scoped DELETE authz uses the snapshot (no :memory: PG analog needed)" {
    // The deleted row is gone from Postgres, so delivery is authorized against the pre-delete
    // snapshot — evaluated in an in-memory SQLite sandbox (always the SQLite union arm). This is
    // the one historically SQLite-coupled spot; it works UNCHANGED with a live PG backend.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const col = schema.Collection{
        .id = "c4",
        .name = "notes",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
        .viewRule = "owner = @request.auth.id",
    };
    try provisionPg(al, &d, col); // table exists but the deleted row is NOT inserted

    var snap: std.json.ObjectMap = .empty;
    try snap.put(al, "id", strVal("GONE"));
    try snap.put(al, "owner", strVal("u1"));
    const snapshot: std.json.Value = .{ .object = snap };

    var owner = try authedConn(al, "u1", false);
    var other = try authedConn(al, "u2", false);
    try std.testing.expect(try hub.shouldDeliver(al, io, &d, col, &owner, 0, .delete, "GONE", null, snapshot));
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, col, &other, 0, .delete, "GONE", null, snapshot));
    // No snapshot -> conservative deny even for the would-be owner.
    try std.testing.expect(!try hub.shouldDeliver(al, io, &d, col, &owner, 0, .delete, "GONE", null, null));
}

// ---- PR-6b: cross-instance LISTEN/NOTIFY ------------------------------------

test "pg cross-instance: a NOTIFY on conn A is received + decoded by a listener on conn B" {
    // Simulate two app instances sharing one database: instance B LISTENs; instance A commits a
    // write and NOTIFYs; B receives the notification and decodes the {origin,collection,action,id}
    // payload that drives its local re-fetch + per-subscriber authz.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var conn_b = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn_b.close();
    var conn_a = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn_a.close();

    // B subscribes to the realtime channel.
    try dbm.dbListen(&conn_b, pg_bridge.channel);

    // A emits a create event for a different origin id (a remote instance).
    const payload = try pg_bridge.encode(al, "instanceA", "posts", .create, "REC42", null);
    try dbm.dbNotify(&conn_a, al, pg_bridge.channel, payload);

    // B receives it (blocking read on its dedicated listener connection).
    const note = (try dbm.dbWaitNotification(&conn_b, al)) orelse return error.@"no notification received";
    try std.testing.expectEqualStrings(pg_bridge.channel, note.channel);

    const ev = pg_bridge.decode(al, note.payload) orelse return error.@"decode failed";
    try std.testing.expectEqualStrings("instanceA", ev.origin);
    try std.testing.expectEqualStrings("posts", ev.collection);
    try std.testing.expectEqual(protocol.Action.create, ev.action);
    try std.testing.expectEqualStrings("REC42", ev.id);
    // The event's origin differs from THIS process's id, so the listener would NOT skip it.
    try std.testing.expect(!std.mem.eql(u8, ev.origin, pg_bridge.originId(io)));
}

test "pg cross-instance: a DELETE NOTIFY carries the snapshot so a remote instance can authz it" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var conn_b = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn_b.close();
    var conn_a = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer conn_a.close();

    try dbm.dbListen(&conn_b, pg_bridge.channel);

    var snap: std.json.ObjectMap = .empty;
    try snap.put(al, "id", strVal("DEL1"));
    try snap.put(al, "owner", strVal("u9"));
    const payload = try pg_bridge.encode(al, "instanceA", "notes", .delete, "DEL1", .{ .object = snap });
    try dbm.dbNotify(&conn_a, al, pg_bridge.channel, payload);

    const note = (try dbm.dbWaitNotification(&conn_b, al)) orelse return error.@"no notification received";
    const ev = pg_bridge.decode(al, note.payload) orelse return error.@"decode failed";
    try std.testing.expectEqual(protocol.Action.delete, ev.action);
    try std.testing.expect(ev.snapshot != null);

    // The remote instance authorizes the delete against the carried snapshot (in-memory SQLite
    // sandbox) — owner u9 is allowed, others denied — WITHOUT the row existing on this PG.
    const col = schema.Collection{
        .id = "c5",
        .name = "notes",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "owner", .options = .{ .text = .{} } }},
        .viewRule = "owner = @request.auth.id",
    };
    var owner = try authedConn(al, "u9", false);
    var other = try authedConn(al, "u8", false);
    try std.testing.expect(try hub.shouldDeliver(al, io, &conn_b, col, &owner, 0, .delete, ev.id, null, ev.snapshot));
    try std.testing.expect(!try hub.shouldDeliver(al, io, &conn_b, col, &other, 0, .delete, ev.id, null, ev.snapshot));
}
