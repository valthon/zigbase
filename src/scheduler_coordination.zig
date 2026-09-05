//! Opt-in durable cron/interval ownership. SQL transactions protect dispatcher
//! state; they never surround application handlers or promise exactly-once effects.
const std = @import("std");
const db = @import("db.zig");
const schedule = @import("schedule.zig");
const clock = @import("clock.zig");
const scheduler = @import("scheduler.zig");

pub const Config = struct { lease_seconds: u32 = 300 };
pub fn lowerConfig(comptime value: anytype) Config {
    const fields = switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |s| s.fields,
        else => @compileError("distributed must be a configuration struct"),
    };
    inline for (fields) |field| {
        if (!std.mem.eql(u8, field.name, "lease_seconds")) @compileError("unknown distributed configuration field: " ++ field.name);
    }
    const lease: u32 = if (@hasField(@TypeOf(value), "lease_seconds")) value.lease_seconds else 300;
    if (lease == 0) @compileError("distributed lease_seconds must be positive");
    return .{ .lease_seconds = lease };
}
pub const Lease = struct { generation: i64, failures: u32, scheduled_at: i64 };

fn prepare(a: std.mem.Allocator, w: *db.Db, sql: [:0]const u8) !db.Stmt {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    return w.prepare(try @import("sql/param_sink.zig").lowerStmtZ(scratch.allocator(), db.dbDialect(w), sql));
}

/// Ownership decisions call this AFTER taking the schedule row lock; readiness
/// probes need no lock. PostgreSQL's transaction-start now() is unsuitable after
/// lock waits, and application clocks can differ by instance.
fn databaseNow(w: *db.Db) !i64 {
    if (clock.frozenUnix()) |now| return now;
    var st = try w.prepare(if (db.dbDialect(w).kind == .postgres)
        "SELECT floor(extract(epoch FROM clock_timestamp()))::bigint;"
    else
        "SELECT unixepoch('now');");
    defer st.finalize();
    if (!try st.step()) return error.MissingDatabaseClock;
    return st.columnInt(0);
}

pub fn definition(comptime sched: schedule.Schedule, comptime config: Config) []const u8 {
    _ = config; // Lease duration is per-claim policy, not persisted cadence identity.
    const cadence = comptime switch (sched) {
        .cron => |expr| "cron:" ++ expr,
        .interval => |iv| std.fmt.comptimePrint("interval:{d}", .{schedule.periodSeconds(iv)}),
        .reactive => @compileError("distributed jobs do not support reactive schedules"),
    };
    return cadence;
}

const Readiness = enum { ready, waiting, stopped };

/// Advisory read only: never owns the schedule. A ready result must still pass
/// claim's row-lock checks; concurrent completion/recovery can change the row.
fn readiness(a: std.mem.Allocator, r: *db.Db, name: []const u8, fingerprint: []const u8) !Readiness {
    var st = try prepare(a, r, "SELECT \"definition\",\"next_fire\",\"lease_until\",\"stopped\" FROM \"_scheduler_jobs\" WHERE \"name\"=?1;");
    defer st.finalize();
    try st.bindText(1, name);
    if (!try st.step()) return .ready;
    if (!std.mem.eql(u8, st.columnText(0), fingerprint)) return error.DistributedScheduleMismatch;
    if (st.columnInt(3) != 0) return .stopped;
    const now = try databaseNow(r);
    return if (st.columnInt(1) > now or st.columnInt(2) > now) .waiting else .ready;
}

/// Caller holds the local writer, outside any transaction. Returns a value-only
/// lease; all SQL scratch is self-freeing under any allocator.
pub fn claim(a: std.mem.Allocator, w: *db.Db, name: []const u8, fingerprint: []const u8, sched: schedule.Schedule, config: Config, owner: []const u8) !?Lease {
    try w.beginImmediate();
    errdefer w.rollback() catch |e| std.log.err("scheduler claim rollback failed: {s}", .{@errorName(e)});
    const exists = blk: {
        var st = try prepare(a, w, "SELECT 1 FROM \"_scheduler_jobs\" WHERE \"name\"=?1;");
        defer st.finalize();
        try st.bindText(1, name);
        break :blk try st.step();
    };
    // Compute a possibly expensive impossible-cron search only on registration,
    // never on every subsequent poll of an already stopped schedule.
    if (!exists) {
        const initial = schedule.nextFire(sched, try databaseNow(w));
        var st = try prepare(a, w, "INSERT INTO \"_scheduler_jobs\" (\"name\",\"definition\",\"next_fire\",\"occurrence_at\",\"stopped\") VALUES (?1,?2,?3,?3,?4) ON CONFLICT (\"name\") DO NOTHING;");
        defer st.finalize();
        try st.bindText(1, name);
        try st.bindText(2, fingerprint);
        try st.bindInt(3, initial orelse 0);
        try st.bindInt(4, if (initial == null) 1 else 0);
        _ = try st.step();
    }
    var next: i64 = undefined;
    var expires: i64 = undefined;
    var lease: Lease = undefined;
    var stopped: bool = undefined;
    {
        const sql = "SELECT \"definition\",\"next_fire\",\"stopped\",\"generation\",\"lease_until\",\"failures\",\"occurrence_at\" FROM \"_scheduler_jobs\" WHERE \"name\"=?1";
        var st = try prepare(a, w, if (db.dbDialect(w).kind == .postgres) sql ++ " FOR UPDATE;" else sql ++ ";");
        defer st.finalize();
        try st.bindText(1, name);
        if (!try st.step()) return error.MissingSchedule;
        if (!std.mem.eql(u8, st.columnText(0), fingerprint)) return error.DistributedScheduleMismatch;
        next = st.columnInt(1);
        stopped = st.columnInt(2) != 0;
        lease = .{ .generation = st.columnInt(3) + 1, .failures = @intCast(st.columnInt(5)), .scheduled_at = st.columnInt(6) };
        expires = st.columnInt(4);
    }
    const now = try databaseNow(w);
    if (stopped or next > now or expires > now) {
        try w.commit();
        return null;
    }
    {
        var st = try prepare(a, w, "UPDATE \"_scheduler_jobs\" SET \"owner\"=?2,\"generation\"=?3,\"lease_until\"=?4 WHERE \"name\"=?1;");
        defer st.finalize();
        try st.bindText(1, name);
        try st.bindText(2, owner);
        try st.bindInt(3, lease.generation);
        try st.bindInt(4, now + config.lease_seconds);
        _ = try st.step();
    }
    try w.commit();
    return lease;
}

/// Persist success/backoff only for the current owner, even after lease expiry
/// if no newer claim won. Stale completion returns
/// false, never advancing the newer owner's cadence or clearing its lease.
pub fn finish(a: std.mem.Allocator, w: *db.Db, name: []const u8, owner: []const u8, lease: Lease, sched: schedule.Schedule, failed: bool) !bool {
    try w.beginImmediate();
    errdefer w.rollback() catch |e| std.log.err("scheduler completion rollback failed: {s}", .{@errorName(e)});
    var valid: bool = undefined;
    {
        const sql = "SELECT \"owner\",\"generation\" FROM \"_scheduler_jobs\" WHERE \"name\"=?1";
        var st = try prepare(a, w, if (db.dbDialect(w).kind == .postgres) sql ++ " FOR UPDATE;" else sql ++ ";");
        defer st.finalize();
        try st.bindText(1, name);
        if (!try st.step()) return error.MissingSchedule;
        valid = std.mem.eql(u8, st.columnText(0), owner) and st.columnInt(1) == lease.generation;
    }
    const now = try databaseNow(w);
    if (!valid) {
        try w.commit();
        return false;
    }
    const failures = if (failed) lease.failures +| 1 else 0;
    const next: ?i64 = if (failed) now + scheduler.retryDelay(failures) else schedule.nextFire(sched, now);
    {
        var st = try prepare(a, w, "UPDATE \"_scheduler_jobs\" SET \"owner\"='',\"lease_until\"=0,\"next_fire\"=?2,\"stopped\"=?3,\"failures\"=?4,\"occurrence_at\"=CASE WHEN ?5=1 THEN \"occurrence_at\" ELSE ?2 END WHERE \"name\"=?1;");
        defer st.finalize();
        try st.bindText(1, name);
        try st.bindInt(2, next orelse 0);
        try st.bindInt(3, if (next == null) 1 else 0);
        try st.bindInt(4, failures);
        try st.bindInt(5, if (failed) 1 else 0);
        _ = try st.step();
    }
    try w.commit();
    return true;
}

/// Called only from a comptime-selected distributed job wrapper. No coordinator
/// function pointer is installed for default per-process jobs.
pub fn run(ctx: *@import("ctx.zig").Ctx, ev: *@import("events.zig").JobEvent, comptime sched: schedule.Schedule, comptime config: Config, comptime handler: fn (*@import("ctx.zig").Ctx, *@import("events.zig").JobEvent) anyerror!void) !Readiness {
    ev.scheduled_at = null;
    ev.generation = null;
    {
        var reader = try ctx.app.pool.acquireReader();
        defer ctx.app.pool.releaseReader(&reader);
        const status = try readiness(ctx.app.allocator, &reader, ev.name, comptime definition(sched, config));
        if (status != .ready) return status;
    }
    const owner = @import("id.zig").collectionId(ctx.app.io);
    const lease = blk: {
        const w = ctx.app.pool.acquireWriter();
        defer ctx.app.pool.releaseWriter();
        break :blk try claim(ctx.app.allocator, w, ev.name, comptime definition(sched, config), sched, config, &owner);
    } orelse return .waiting;
    ev.scheduled_at = lease.scheduled_at;
    ev.generation = lease.generation;
    var failure: ?anyerror = null;
    handler(ctx, ev) catch |e| {
        failure = e;
    };
    const finished = blk: {
        const w = ctx.app.pool.acquireWriter();
        defer ctx.app.pool.releaseWriter();
        break :blk finish(ctx.app.allocator, w, ev.name, &owner, lease, sched, failure != null) catch |e| {
            std.log.warn("distributed job '{s}' completion persistence failed: {s}", .{ ev.name, @errorName(e) });
            return failure orelse e;
        };
    };
    if (!finished) std.log.warn("distributed job '{s}' lost its lease; completion was fenced", .{ev.name});
    if (failure) |e| return e;
    return .waiting;
}

const testing = std.testing;
const test_schedule = schedule.Schedule{ .interval = .{ .minutes = 1 } };
const test_config = Config{ .lease_seconds = 10 };
const test_definition = definition(test_schedule, test_config);

fn exerciseRecovery(first: *db.Db, second: *db.Db) !void {
    if (!clock.enabled) return error.SkipZigTest;
    clock.setForTest(100);
    defer clock.resetForTest();
    const a = testing.allocator;
    try testing.expectEqual(@as(?Lease, null), try claim(a, first, "sweep", test_definition, test_schedule, test_config, "one"));
    clock.setForTest(160);
    const old = (try claim(a, first, "sweep", test_definition, test_schedule, test_config, "one")).?;
    try testing.expectEqual(@as(i64, 160), old.scheduled_at);
    try testing.expectEqual(@as(?Lease, null), try claim(a, second, "sweep", test_definition, test_schedule, test_config, "two"));
    // Crash/overrun: the persisted lease expires; another connection recovers
    // the SAME occurrence, not a new cadence and not an eagerly repeated boot job.
    clock.setForTest(170);
    const recovered = (try claim(a, second, "sweep", test_definition, test_schedule, test_config, "two")).?;
    try testing.expect(recovered.generation > old.generation);
    try testing.expectEqual(old.scheduled_at, recovered.scheduled_at);
    try testing.expect(!try finish(a, first, "sweep", "one", old, test_schedule, false));
    try testing.expect(!try finish(a, first, "sweep", "one", old, test_schedule, true));
    try testing.expect(try finish(a, second, "sweep", "two", recovered, test_schedule, true));
    try testing.expectEqual(@as(?Lease, null), try claim(a, first, "sweep", test_definition, test_schedule, test_config, "one"));
    clock.setForTest(171);
    const retry = (try claim(a, first, "sweep", test_definition, test_schedule, test_config, "one")).?;
    try testing.expectEqual(@as(u32, 1), retry.failures);
    try testing.expectEqual(old.scheduled_at, retry.scheduled_at);
    try testing.expect(try finish(a, first, "sweep", "one", retry, test_schedule, false));
    // Completion schedules next interval once. A newly joined instance observes it.
    clock.setForTest(230);
    try testing.expectEqual(@as(?Lease, null), try claim(a, second, "sweep", test_definition, test_schedule, test_config, "three"));
    clock.setForTest(231);
    const next = (try claim(a, second, "sweep", test_definition, test_schedule, test_config, "three")).?;
    try testing.expectEqual(@as(u32, 0), next.failures);
    try testing.expectEqual(@as(i64, 231), next.scheduled_at);
    try testing.expectError(error.DistributedScheduleMismatch, claim(a, first, "sweep", "different cadence", test_schedule, test_config, "one"));
    clock.setForTest(241);
    // A lease overrun without a newer claimant may still complete exactly once.
    try testing.expect(try finish(a, second, "sweep", "three", next, test_schedule, false));
    try testing.expect(!try finish(a, second, "sweep", "three", next, test_schedule, false));
    const tuned = Config{ .lease_seconds = 90 };
    try testing.expectEqualStrings(test_definition, definition(test_schedule, tuned));
    clock.setForTest(301);
    const tuned_lease = (try claim(a, first, "sweep", definition(test_schedule, tuned), test_schedule, tuned, "tuned")).?;
    clock.setForTest(312);
    try testing.expectEqual(@as(?Lease, null), try claim(a, second, "sweep", test_definition, test_schedule, test_config, "old-config"));
    try testing.expect(try finish(a, first, "sweep", "tuned", tuned_lease, test_schedule, false));
}

test "readiness uses read-only access for absent, waiting, due and stopped schedules" {
    if (!clock.enabled) return error.SkipZigTest;
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    clock.setForTest(100);
    defer clock.resetForTest();
    _ = try claim(testing.allocator, &d, "waiting", test_definition, test_schedule, test_config, "seed");
    try d.exec("INSERT INTO _scheduler_jobs (name,definition,next_fire,occurrence_at,stopped) VALUES ('stopped','interval:60',0,0,1);");
    try d.exec("PRAGMA query_only=ON;");
    try testing.expectEqual(Readiness.ready, try readiness(testing.allocator, &d, "absent", test_definition));
    try testing.expectEqual(Readiness.waiting, try readiness(testing.allocator, &d, "waiting", test_definition));
    try testing.expectEqual(Readiness.stopped, try readiness(testing.allocator, &d, "stopped", test_definition));
    try testing.expectError(error.DistributedScheduleMismatch, readiness(testing.allocator, &d, "waiting", "interval:120"));
    clock.setForTest(160);
    try testing.expectEqual(Readiness.ready, try readiness(testing.allocator, &d, "waiting", test_definition));
}

test "completion persistence failure preserves the original handler error" {
    if (!clock.enabled) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/jobs.db", .{dir}, 0);
    defer testing.allocator.free(path);
    var pool = try db.Pool.init(testing.allocator, testing.io, path);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try @import("migrations.zig").run(w);
    }
    var app = @import("app.zig").App{ .allocator = testing.allocator, .io = testing.io, .pool = &pool };
    var ctx = @import("ctx.zig").Ctx{ .app = &app, .arena = @import("request_arena.zig").RequestArena.forTest(testing.allocator), .rctx = .{}, .request = null, .bound_conn = null };
    defer ctx.deinit();
    const H = struct {
        fn handler(cx: *@import("ctx.zig").Ctx, _: *@import("events.zig").JobEvent) anyerror!void {
            const w = cx.app.pool.acquireWriter();
            defer cx.app.pool.releaseWriter();
            try w.exec("DROP TABLE _scheduler_jobs;");
            return error.OriginalHandlerFailure;
        }
    };
    var ev = @import("events.zig").JobEvent{ .app = &app, .name = "failing" };
    clock.setForTest(100);
    defer clock.resetForTest();
    _ = try run(&ctx, &ev, test_schedule, test_config, H.handler);
    clock.setForTest(160);
    try testing.expectError(error.OriginalHandlerFailure, run(&ctx, &ev, test_schedule, test_config, H.handler));
}

test "distributed scheduler recovery, backoff, persisted cadence and stale completion fencing" {
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    try exerciseRecovery(&d, &d);
}

test "distributed cron consumes one due occurrence and coalesces missed runs" {
    if (!clock.enabled) return error.SkipZigTest;
    var d = try db.Db.openMemory();
    defer d.close();
    try @import("migrations.zig").run(&d);
    const cron = schedule.Schedule{ .cron = "* * * * *" };
    const fingerprint = definition(cron, test_config);
    clock.setForTest(100);
    defer clock.resetForTest();
    try testing.expectEqual(@as(?Lease, null), try claim(testing.allocator, &d, "cron", fingerprint, cron, test_config, "one"));
    clock.setForTest(300);
    const lease = (try claim(testing.allocator, &d, "cron", fingerprint, cron, test_config, "one")).?;
    try testing.expectEqual(@as(i64, 120), lease.scheduled_at);
    try testing.expect(try finish(testing.allocator, &d, "cron", "one", lease, cron, false));
    try testing.expectEqual(@as(?Lease, null), try claim(testing.allocator, &d, "cron", fingerprint, cron, test_config, "two"));
    clock.setForTest(360);
    try testing.expect((try claim(testing.allocator, &d, "cron", fingerprint, cron, test_config, "two")) != null);
}

test "distributed wrappers are selected at comptime and retain declared schedules" {
    const H = struct {
        fn handler(_: *@import("ctx.zig").Ctx, _: *@import("events.zig").JobEvent) anyerror!void {}
    };
    const jobs = scheduler.buildJobs(.{
        .{ .name = "shared", .schedule = test_schedule, .distributed = .{ .lease_seconds = 10 }, .handler = H.handler },
        .{ .name = "local", .schedule = test_schedule, .handler = H.handler },
    });
    try testing.expect(jobs[0].distributed);
    try testing.expect(!jobs[1].distributed);
    try testing.expect(jobs[0].schedule == .interval);
}

test "distributed wrapper releases writer around handler and supplies stable occurrence identity" {
    if (!clock.enabled) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/jobs.db", .{dir}, 0);
    defer testing.allocator.free(path);
    var pool = try db.Pool.init(testing.allocator, testing.io, path);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try @import("migrations.zig").run(w);
        try w.exec("CREATE TABLE probe (occurrence BIGINT, generation BIGINT);");
    }
    var app: @import("app.zig").App = undefined;
    app.allocator = testing.allocator;
    app.io = testing.io;
    app.pool = &pool;
    var ctx = @import("ctx.zig").Ctx{ .app = &app, .arena = @import("request_arena.zig").RequestArena.forTest(testing.allocator), .rctx = .{}, .request = null, .bound_conn = null };
    defer ctx.deinit();
    const H = struct {
        fn handler(cx: *@import("ctx.zig").Ctx, ev: *@import("events.zig").JobEvent) anyerror!void {
            const w = cx.app.pool.acquireWriter();
            defer cx.app.pool.releaseWriter();
            var st = try w.prepare("INSERT INTO probe VALUES (?1,?2);");
            defer st.finalize();
            try st.bindInt(1, ev.scheduled_at.?);
            try st.bindInt(2, ev.generation.?);
            _ = try st.step();
        }
    };
    const jobs = scheduler.buildJobs(.{.{ .name = "wrapper", .schedule = test_schedule, .distributed = test_config, .handler = H.handler }});
    var ev = @import("events.zig").JobEvent{ .app = &app, .name = "wrapper" };
    clock.setForTest(100);
    defer clock.resetForTest();
    _ = try jobs[0].run(&ctx, &ev);
    clock.setForTest(160);
    _ = try jobs[0].run(&ctx, &ev);
    try testing.expect(ev.scheduled_at != null);
    _ = try jobs[0].run(&ctx, &ev);
    try testing.expectEqual(@as(?i64, null), ev.scheduled_at);
    try testing.expectEqual(@as(?i64, null), ev.generation);
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    var st = try w.prepare("SELECT COUNT(*), MIN(occurrence), MIN(generation) FROM probe;");
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 1), st.columnInt(0));
    try testing.expectEqual(@as(i64, 160), st.columnInt(1));
    try testing.expectEqual(@as(i64, 1), st.columnInt(2));
}

const PgEnv = struct {
    first: db.Db,
    second: db.Db,
    name: [15]u8,
    fn init() !PgEnv {
        if (!@import("build_options").postgres) return error.SkipZigTest;
        const url = @import("backend/postgres/tests.zig").testUrl();
        var first = db.Db.openPostgres(testing.allocator, testing.io, url) catch |e| switch (e) {
            error.OpenFailed => return error.SkipZigTest,
            else => return e,
        };
        errdefer first.close();
        var second = try db.Db.openPostgres(testing.allocator, testing.io, url);
        errdefer second.close();
        const name = @import("id.zig").collectionId(testing.io);
        var buf: [128]u8 = undefined;
        try first.exec(try std.fmt.bufPrintZ(&buf, "CREATE SCHEMA \"zbs_{s}\";", .{name}));
        errdefer first.exec(std.fmt.bufPrintZ(&buf, "DROP SCHEMA \"zbs_{s}\" CASCADE;", .{name}) catch unreachable) catch |e| std.log.err("scheduler test cleanup: {s}", .{@errorName(e)});
        const path = try std.fmt.bufPrintZ(&buf, "SET search_path TO \"zbs_{s}\";", .{name});
        try first.exec(path);
        try second.exec(path);
        try @import("migrations.zig").run(&first);
        return .{ .first = first, .second = second, .name = name };
    }
    fn deinit(self: *PgEnv) void {
        self.second.close();
        var buf: [128]u8 = undefined;
        self.first.exec(std.fmt.bufPrintZ(&buf, "DROP SCHEMA \"zbs_{s}\" CASCADE;", .{self.name}) catch unreachable) catch |e| std.log.err("scheduler test cleanup: {s}", .{@errorName(e)});
        self.first.close();
    }
};

test "pg distributed schedule recovers across instances and fences stale owners" {
    if (!@import("build_options").postgres) return error.SkipZigTest;
    var env = try PgEnv.init();
    defer env.deinit();
    try exerciseRecovery(&env.first, &env.second);
    clock.resetForTest();
    try testing.expect((try databaseNow(&env.first)) > 1_000_000);
}

test "pg concurrent schedulers claim a due occurrence only once" {
    if (!@import("build_options").postgres or !clock.enabled) return error.SkipZigTest;
    var env = try PgEnv.init();
    defer env.deinit();
    clock.setForTest(100);
    defer clock.resetForTest();
    _ = try claim(testing.allocator, &env.first, "sweep", test_definition, test_schedule, test_config, "seed");
    clock.setForTest(160);
    const Runner = struct {
        w: *db.Db,
        owner: []const u8,
        start: *std.atomic.Value(bool),
        result: ?Lease = null,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.result = claim(testing.allocator, self.w, "sweep", test_definition, test_schedule, test_config, self.owner) catch |e| {
                self.err = e;
                return;
            };
        }
    };
    var start = std.atomic.Value(bool).init(false);
    var one = Runner{ .w = &env.first, .owner = "one", .start = &start };
    var two = Runner{ .w = &env.second, .owner = "two", .start = &start };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&one});
    start.store(true, .release);
    two.run();
    thread.join();
    if (one.err) |e| return e;
    if (two.err) |e| return e;
    try testing.expect((one.result != null) != (two.result != null));
}
