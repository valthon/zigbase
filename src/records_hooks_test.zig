const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const events = @import("events.zig");
const request = @import("request.zig");
const sentry = @import("sentry.zig");
const App = @import("app.zig").App;
const records_api = @import("api/records.zig");

const Hooks = struct {
    fn stampTitle(ev: *events.RecordEvent) anyerror!void {
        // Mutations that grow the record's map MUST allocate with the request-scoped
        // arena (ev.arena) — the same allocator that owns ev.record — not app.allocator.
        try ev.record.object.put(ev.arena, "title", .{ .string = "stamped" });
    }
    fn boom(ev: *events.RecordEvent) anyerror!void {
        _ = ev;
        return error.HookRejected;
    }
    var calls: usize = 0;
    fn counter(ev: *events.RecordEvent) anyerror!void {
        _ = ev;
        calls += 1;
    }
};

/// Open a memory DB with a `posts` collection (single text field `title`).
/// `setup_arena` owns the transient allocations made while creating the collection.
fn setupDb(conn: *db.Db, setup_arena: *std.heap.ArenaAllocator) !void {
    conn.* = try db.Db.openMemory();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrations.run(conn);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
    };
    _ = try collections.create(setup_arena.allocator(), std.testing.io, conn, .{ .id = "", .name = "posts", .fields = &fields });
}

test "emitRecord before_create mutation is visible on the record" {
    var conn: db.Db = undefined;
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    try setupDb(&conn, &setup_arena);
    defer conn.close();

    const dispatch = events.Dispatch{
        .record = events.buildRecordDispatcher(.{ .posts = .{ .beforeCreate = Hooks.stampTitle } }),
    };
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined, .dispatch = &dispatch };

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "title", .{ .string = "orig" });
    var value: std.json.Value = .{ .object = obj };
    var rctx = request.RequestContext{ .method = "POST" };

    // The record map is allocated with std.testing.allocator, so the arena argument
    // is the same allocator — mirroring production where the request arena owns the record.
    try records_api.emitRecord(&app, &rctx, std.testing.allocator, &conn, "posts", &value, .before_create);
    try std.testing.expectEqualStrings("stamped", value.object.get("title").?.string);
}

test "emitRecord before_create hook error propagates" {
    var conn: db.Db = undefined;
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    try setupDb(&conn, &setup_arena);
    defer conn.close();

    const dispatch = events.Dispatch{
        .record = events.buildRecordDispatcher(.{ .posts = .{ .beforeCreate = Hooks.boom } }),
    };
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined, .dispatch = &dispatch };

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    var value: std.json.Value = .{ .object = obj };
    var rctx = request.RequestContext{ .method = "POST" };

    try std.testing.expectError(error.HookRejected, records_api.emitRecord(&app, &rctx, std.testing.allocator, &conn, "posts", &value, .before_create));
}

test "emitRecord after_create swallows hook errors" {
    var conn: db.Db = undefined;
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    try setupDb(&conn, &setup_arena);
    defer conn.close();

    const dispatch = events.Dispatch{
        .record = events.buildRecordDispatcher(.{ .posts = .{ .afterCreate = Hooks.boom } }),
    };
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined, .dispatch = &dispatch };
    app.sentry_dsn = "";
    // Route the log-mode backstop into a no-op so the swallowed error does not
    // emit a real std.log.err (which the test runner would count as a failure).
    const Sink = struct {
        fn noop(_: []const u8) void {}
    };
    sentry.log_sink = Sink.noop;
    defer sentry.log_sink = null;

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    var value: std.json.Value = .{ .object = obj };
    var rctx = request.RequestContext{ .method = "POST" };

    // after_create routes the error to dispatchError + swallows; no error returned.
    try records_api.emitRecord(&app, &rctx, std.testing.allocator, &conn, "posts", &value, .after_create);
}

test "emitRecord before_create skips a non-object body without firing the hook" {
    var conn: db.Db = undefined;
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    try setupDb(&conn, &setup_arena);
    defer conn.close();

    const dispatch = events.Dispatch{
        .record = events.buildRecordDispatcher(.{ .posts = .{ .beforeCreate = Hooks.counter } }),
    };
    var app = App{ .allocator = std.testing.allocator, .io = std.testing.io, .pool = undefined, .dispatch = &dispatch };

    Hooks.calls = 0;
    // A non-object JSON body (here an integer) must short-circuit before the hook runs,
    // so a hook's `ev.record.object` access can't panic on untrusted input.
    var value: std.json.Value = .{ .integer = 42 };
    var rctx = request.RequestContext{ .method = "POST" };

    try records_api.emitRecord(&app, &rctx, std.testing.allocator, &conn, "posts", &value, .before_create);
    try std.testing.expectEqual(@as(usize, 0), Hooks.calls);
}
