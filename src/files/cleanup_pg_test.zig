//! Live PostgreSQL proof that reference writes cannot cross storage deletion.
const std = @import("std");
const db = @import("../db.zig");
const Storage = @import("storage.zig").Storage;

const insert_reference = "INSERT INTO cleanup_lock_files (id, attachment) VALUES ('restored', 'old.txt');";

const Probe = struct {
    other: *db.Db,
    blocked: bool = false,

    fn remove(raw: *anyopaque, _: std.Io, _: []const u8, _: []const u8, _: []const u8) !void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        // An independent database connection executes while jobHandler holds its
        // lock across this callback. A finite server timeout avoids timing races.
        try std.testing.expectError(error.ExecFailed, self.other.exec(insert_reference));
        try std.testing.expect(std.mem.indexOf(u8, self.other.postgres.conn.last_error.items, "lock timeout") != null);
        self.blocked = true;
    }
    fn put(_: *anyopaque, _: std.Io, _: []const u8, _: []const u8, _: []const u8, _: []const u8) !void {
        return error.UnexpectedStorageCall;
    }
    fn fetch(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !?[]const u8 {
        return error.UnexpectedStorageCall;
    }
    fn removeRecord(_: *anyopaque, _: std.Io, _: []const u8, _: []const u8) !void {
        return error.UnexpectedStorageCall;
    }
    const vtable: Storage.VTable = .{ .put = put, .fetch = fetch, .delete = remove, .deleteRecord = removeRecord };
};

test "postgres cleanup holds a reference write lock through storage deletion" {
    if (!@import("build_options").postgres) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const url = std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    const target = try a.dupeZ(u8, url);
    defer a.free(target);
    var pool = try db.Pool.init(a, io, target);
    defer pool.deinit();
    var other = try db.Db.openPostgres(a, io, url);
    defer other.close();
    try other.exec("DROP SCHEMA IF EXISTS zb_cleanup_lock_probe CASCADE;");
    try other.exec("CREATE SCHEMA zb_cleanup_lock_probe;");
    defer other.exec("DROP SCHEMA zb_cleanup_lock_probe CASCADE;") catch |err| std.log.err("cleanup PG test teardown: {s}", .{@errorName(err)});
    try other.exec("SET search_path TO zb_cleanup_lock_probe;");
    try other.exec("SET lock_timeout = '100ms';");
    const col = blk: {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try w.exec("SET search_path TO zb_cleanup_lock_probe;");
        try @import("../migrations.zig").run(w);
        break :blk try @import("../collections.zig").create(a, io, w, .{
            .id = "",
            .name = "cleanup_lock_files",
            .fields = &.{.{ .id = "attach", .name = "attachment", .options = .{ .file = .{} } }},
        });
    };
    defer col.deinit(a);
    // The same statement is valid when cleanup is not holding the table lock.
    try other.exec(insert_reference);
    try other.exec("DELETE FROM cleanup_lock_files WHERE id='restored';");
    var probe = Probe{ .other = &other };
    var storage = Storage{ .ctx = &probe, .vtable = &Probe.vtable };
    var app = @import("../app.zig").App{ .allocator = a, .io = io, .pool = &pool, .storage = &storage };
    var backing: [128 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    // Request graph lives in this fixed-buffer arena for the one handler call.
    var ctx = @import("../ctx.zig").Ctx{ .app = &app, .arena = .{ .a = fba.allocator() } };
    const payload = try std.json.Stringify.valueAlloc(a, .{ .collection = col.name, .collection_id = col.id, .record = "restored", .filename = "old.txt" }, .{});
    defer a.free(payload);
    try @import("cleanup.zig").jobHandler(&ctx, payload);
    try std.testing.expect(probe.blocked);
    // Cleanup committed and released its lock: the exact reference write works.
    try other.exec(insert_reference);
    try other.exec("DELETE FROM cleanup_lock_files WHERE id='restored';");

    // A session configured with a long wait must still use cleanup's bounded
    // transaction-local wait, and the override must not leak into later users.
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try w.exec("SET lock_timeout = '5s';");
    }
    for ([_][:0]const u8{
        "LOCK TABLE cleanup_lock_files IN ACCESS EXCLUSIVE MODE;",
        "LOCK TABLE _collections IN ROW EXCLUSIVE MODE;",
    }) |blocker| {
        try other.begin();
        defer if (other.inTransaction()) other.rollback() catch |err| std.log.err("cleanup lock test rollback: {s}", .{@errorName(err)});
        try other.exec(blocker);
        probe.blocked = false;
        fba.reset();
        const started = std.Io.Timestamp.now(io, .awake);
        try std.testing.expectError(error.ExecFailed, @import("cleanup.zig").jobHandler(&ctx, payload));
        const elapsed_ms = @divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds - started.nanoseconds, std.time.ns_per_ms);
        // Broad headroom for loaded CI, still far below the 5s session setting.
        try std.testing.expect(elapsed_ms >= 200 and elapsed_ms < 4000);
        try std.testing.expect(!probe.blocked);
        try other.rollback();
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try std.testing.expect(!w.inTransaction());
        var setting = try w.prepare("SHOW lock_timeout;");
        defer setting.finalize();
        try std.testing.expect(try setting.step());
        try std.testing.expectEqualStrings("5s", setting.columnText(0));
    }

    // Model the DDL lock order: DDL owns the data table before writing metadata.
    // Observe cleanup waiting on the data table, then acquire metadata's write
    // lock from the DDL connection. A metadata-first cleanup would block that
    // acquisition and form the opposite-order cycle.
    const worker_pid = blk: {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        var pid = try w.prepare("SELECT pg_backend_pid();");
        defer pid.finalize();
        try std.testing.expect(try pid.step());
        break :blk pid.columnInt(0);
    };
    try other.begin();
    defer if (other.inTransaction()) other.rollback() catch |err| std.log.err("cleanup DDL test rollback: {s}", .{@errorName(err)});
    try other.exec("LOCK TABLE cleanup_lock_files IN ACCESS EXCLUSIVE MODE;");
    const Runner = struct {
        ctx: *@import("../ctx.zig").Ctx,
        payload: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            @import("cleanup.zig").jobHandler(self.ctx, self.payload) catch |err| {
                self.failure = err;
            };
        }
    };
    fba.reset();
    var runner = Runner{ .ctx = &ctx, .payload = payload };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    defer thread.join();
    var saw_wait = false;
    for (0..100) |_| {
        var waiting = try other.prepare("SELECT count(*) FROM pg_locks WHERE pid=$1 AND relation='cleanup_lock_files'::regclass AND NOT granted;");
        defer waiting.finalize();
        try waiting.bindInt(1, worker_pid);
        try std.testing.expect(try waiting.step());
        if (waiting.columnInt(0) > 0) {
            saw_wait = true;
            break;
        }
        if (runner.done.load(.acquire)) break;
        try other.exec("SELECT pg_sleep(0.005);");
    }
    try std.testing.expect(saw_wait);
    try other.exec("LOCK TABLE _collections IN ROW EXCLUSIVE MODE;");
    // Keep the DDL locks until cleanup times out; thread completion is bounded
    // by the production lock timeout (and a 5s fallback if it regresses).
    while (!runner.done.load(.acquire)) try other.exec("SELECT pg_sleep(0.005);");
    try std.testing.expectEqual(error.ExecFailed, runner.failure.?);
    try std.testing.expect(!probe.blocked);
    try other.rollback();
}
