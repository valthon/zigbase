//! Durable queue backend (#137 PR2): jobs persisted to `_queue_jobs` and drained by
//! a per-worker poller. At-least-once — a crash after a side effect but before the
//! row is marked `done` replays the job (consumers tolerate replays; the webhook
//! idempotency key is the antidote). The pure DB ops here operate on the WRITER and
//! are deadlock-safe to compose: the poller claims under the writer, RELEASES it,
//! dispatches the handler (which may take the writer itself), then re-acquires it to
//! record the outcome.

const std = @import("std");
const db = @import("../db.zig");
const clock = @import("../clock.zig");
const id = @import("../id.zig");
const events = @import("../events.zig");
const queue = @import("queue.zig");
const App = @import("../app.zig").App;
const Ctx = @import("../ctx.zig").Ctx;

const QueueDef = queue.QueueDef;
const WorkerDef = queue.WorkerDef;
const Registry = queue.Registry;

/// Bound on a single GC / reclaim batch so a large backlog never holds the writer
/// for one long statement (mirrors `features_resolver.assignment_gc_batch`).
pub const gc_batch: usize = 1000;

/// Insert a `pending` durable job. `run_at` is the earliest unix-second the job may be
/// claimed (pass `clock.nowUnix(io)` for immediate). The writer must be held by the caller.
pub fn enqueue(w: *db.Db, io: std.Io, def: QueueDef, kind: []const u8, payload: []const u8, run_at: i64) !void {
    const jid = id.collectionId(io);
    var st = try w.prepare(
        \\INSERT INTO "_queue_jobs"
        \\  ("id","queue","kind","payload","priority","max_attempts","run_at","status","created")
        \\ VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'pending', datetime('now'));
    );
    defer st.finalize();
    try st.bindText(1, &jid);
    try st.bindText(2, def.name);
    try st.bindText(3, kind);
    try st.bindText(4, payload);
    try st.bindInt(5, @intFromEnum(def.priority));
    try st.bindInt(6, @intCast(def.retry.max_attempts));
    try st.bindInt(7, run_at);
    _ = try st.step();
}

/// A claimed (now in-flight) durable job. All slices are owned by `arena`.
pub const Claimed = struct {
    id: []const u8,
    queue: []const u8,
    kind: []const u8,
    payload: []const u8,
    attempts: i64,
    max_attempts: i64,
};

/// Atomically claim up to `limit` ready rows for `queue_names`, ORDER BY priority,run_at —
/// so higher-priority queues drain first (strict priority). Marks each row `claimed`
/// (claimed_at=now, claimed_by=worker) and RETURNs it. The writer must be held by the caller.
/// Returns an empty slice when nothing is ready.
pub fn claimBatch(
    arena: std.mem.Allocator,
    w: *db.Db,
    queue_names: []const []const u8,
    worker_name: []const u8,
    limit: usize,
    now: i64,
) ![]Claimed {
    if (queue_names.len == 0 or limit == 0) return &.{};

    // Build the IN (?,?,…) list dynamically; queue names are BOUND params (no injection).
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(arena);
    try sql.appendSlice(arena,
        \\UPDATE "_queue_jobs" SET "status"='claimed', "claimed_at"=?1, "claimed_by"=?2
        \\ WHERE "id" IN (
        \\   SELECT "id" FROM "_queue_jobs"
        \\    WHERE "status"='pending' AND "run_at" <= ?3 AND "queue" IN (
    );
    var pidx: usize = 4;
    for (queue_names, 0..) |_, i| {
        const frag = try std.fmt.allocPrint(arena, "{s}?{d}", .{ if (i == 0) "" else ",", pidx });
        try sql.appendSlice(arena, frag);
        pidx += 1;
    }
    const tail = try std.fmt.allocPrint(arena, ") ORDER BY \"priority\" ASC, \"run_at\" ASC LIMIT ?{d})", .{pidx});
    try sql.appendSlice(arena, tail);
    try sql.appendSlice(arena, " RETURNING \"id\",\"queue\",\"kind\",\"payload\",\"attempts\",\"max_attempts\";");
    const sql_z = try arena.dupeZ(u8, sql.items);

    var st = try w.prepare(sql_z);
    defer st.finalize();
    try st.bindInt(1, now);
    try st.bindText(2, worker_name);
    try st.bindInt(3, now);
    for (queue_names, 0..) |qn, i| try st.bindText(@intCast(4 + i), qn);
    try st.bindInt(@intCast(pidx), @intCast(limit));

    var out: std.ArrayList(Claimed) = .empty;
    while (try st.step()) {
        try out.append(arena, .{
            .id = try arena.dupe(u8, st.columnText(0)),
            .queue = try arena.dupe(u8, st.columnText(1)),
            .kind = try arena.dupe(u8, st.columnText(2)),
            .payload = try arena.dupe(u8, st.columnText(3)),
            .attempts = st.columnInt(4),
            .max_attempts = st.columnInt(5),
        });
    }
    return out.toOwnedSlice(arena);
}

/// Mark a claimed job `done` (success). Writer held by caller.
pub fn markDone(w: *db.Db, job_id: []const u8) !void {
    var st = try w.prepare("UPDATE \"_queue_jobs\" SET \"status\"='done', \"claimed_at\"=NULL, \"last_error\"='' WHERE \"id\"=?1;");
    defer st.finalize();
    try st.bindText(1, job_id);
    _ = try st.step();
}

/// Re-queue a retryable failure: bump attempts, push `run_at` out by the backoff,
/// clear the claim, record the error. Writer held by caller.
pub fn markRetry(w: *db.Db, job_id: []const u8, new_attempts: i64, run_at: i64, last_error: []const u8) !void {
    var st = try w.prepare(
        \\UPDATE "_queue_jobs"
        \\ SET "status"='pending', "attempts"=?2, "run_at"=?3, "claimed_at"=NULL, "claimed_by"='', "last_error"=?4
        \\ WHERE "id"=?1;
    );
    defer st.finalize();
    try st.bindText(1, job_id);
    try st.bindInt(2, new_attempts);
    try st.bindInt(3, run_at);
    try st.bindText(4, last_error);
    _ = try st.step();
}

/// Mark a job terminally `failed` (attempts exhausted, or an unknown kind). Writer held by caller.
pub fn markFailed(w: *db.Db, job_id: []const u8, new_attempts: i64, last_error: []const u8) !void {
    var st = try w.prepare("UPDATE \"_queue_jobs\" SET \"status\"='failed', \"attempts\"=?2, \"claimed_at\"=NULL, \"last_error\"=?3 WHERE \"id\"=?1;");
    defer st.finalize();
    try st.bindText(1, job_id);
    try st.bindInt(2, new_attempts);
    try st.bindText(3, last_error);
    _ = try st.step();
}

/// Reclaim sweep for ONE queue: any `claimed` row of `queue_name` whose `claimed_at` is
/// older than `visibility_timeout_s` (relative to `now`) is reset to `pending` so a crashed
/// worker (or a handler that overran its timeout) doesn't strand it. The threshold is
/// per-queue (`QueueDef.visibility_timeout_s`). Returns the number reclaimed. Writer held by caller.
pub fn reclaimStale(w: *db.Db, queue_name: []const u8, now: i64, visibility_timeout_s: i64) !usize {
    const cutoff = now - visibility_timeout_s;
    var st = try w.prepare(
        \\UPDATE "_queue_jobs" SET "status"='pending', "claimed_at"=NULL, "claimed_by"=''
        \\ WHERE "status"='claimed' AND "queue"=?1 AND "claimed_at" IS NOT NULL AND "claimed_at" <= ?2
        \\ RETURNING "id";
    );
    defer st.finalize();
    try st.bindText(1, queue_name);
    try st.bindInt(2, cutoff);
    var n: usize = 0;
    while (try st.step()) n += 1;
    return n;
}

/// GC sweep for ONE queue: delete `done`/`failed` rows of `queue_name` whose `created` is
/// older than `ttl_s` seconds, in bounded batches (mirrors `features_resolver.gcExpiredAssignments`).
/// The TTL is per-queue (`QueueDef.done_ttl_s`). Returns rows deleted. Writer held by caller.
pub fn gcDoneJobs(w: *db.Db, queue_name: []const u8, ttl_s: i64) !usize {
    var buf: [32]u8 = undefined;
    const modifier = std.fmt.bufPrint(&buf, "-{d} seconds", .{ttl_s}) catch unreachable;
    var total: usize = 0;
    while (true) {
        var st = try w.prepare(comptime std.fmt.comptimePrint(
            \\DELETE FROM "_queue_jobs"
            \\ WHERE rowid IN (
            \\   SELECT rowid FROM "_queue_jobs"
            \\    WHERE "status" IN ('done','failed') AND "queue"=?1
            \\      AND strftime('%Y-%m-%dT%H:%M:%SZ', "created") IS NOT NULL
            \\      AND strftime('%Y-%m-%dT%H:%M:%SZ', "created") <= strftime('%Y-%m-%dT%H:%M:%SZ','now',?2)
            \\    LIMIT {d}
            \\ )
            \\ RETURNING "id";
        , .{gc_batch}));
        defer st.finalize();
        try st.bindText(1, queue_name);
        try st.bindText(2, modifier);
        var batch: usize = 0;
        while (try st.step()) batch += 1;
        total += batch;
        if (batch < gc_batch) break;
    }
    return total;
}

/// Run ONE poll cycle for `worker`: reclaim stale rows, claim a batch of its durable
/// queues' ready jobs, dispatch each to its kind handler (OUTSIDE the writer lock so the
/// handler may take the writer), then record each outcome (done / retry / terminal). A
/// terminal failure fires `.onError` (phase `.job`). Returns the number of jobs processed.
pub fn pollOnce(app: *App, reg: *const Registry, worker: WorkerDef) !usize {
    const io = app.io;
    const now = clock.nowUnix(io);

    // Restrict to this worker's DURABLE queues (memory queues are not polled).
    var poll_arena = std.heap.ArenaAllocator.init(app.allocator);
    defer poll_arena.deinit();
    const pa = poll_arena.allocator();

    var durable_qs: std.ArrayList([]const u8) = .empty;
    for (worker.queues) |qn| {
        if (reg.queueByName(qn)) |q| if (q.backend == .durable) try durable_qs.append(pa, qn);
    }
    if (durable_qs.items.len == 0) return 0;

    const claimed = blk: {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();
        // Reclaim each durable queue with ITS OWN visibility timeout before claiming.
        for (durable_qs.items) |qn| {
            const vt = if (reg.queueByName(qn)) |q| q.visibility_timeout_s else 300;
            _ = reclaimStale(w, qn, now, vt) catch |e|
                std.log.warn("queue '{s}' reclaim sweep failed: {s}", .{ qn, @errorName(e) });
        }
        break :blk try claimBatch(pa, w, durable_qs.items, worker.name, worker.concurrency, now);
    };

    for (claimed) |job| {
        const reg_job = reg.jobByKind(job.kind);
        // Dispatch with the writer RELEASED (the handler may acquire it).
        var run_err: ?anyerror = null;
        if (reg_job) |rj| {
            var arena = std.heap.ArenaAllocator.init(app.allocator);
            defer arena.deinit();
            var cx = Ctx{ .app = app, .arena = arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
            defer cx.deinit();
            rj.handler(&cx, job.payload) catch |e| {
                run_err = e;
            };
        } else {
            run_err = error.UnknownJobKind;
        }

        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();
        if (run_err) |e| {
            const new_attempts = job.attempts + 1;
            const terminal = (reg_job == null) or (new_attempts >= job.max_attempts);
            if (terminal) {
                try markFailed(w, job.id, new_attempts, @errorName(e));
                var err_ev = events.ErrorEvent{ .app = app, .ctx = null, .err = e, .phase = .job, .message = @errorName(e) };
                events.dispatchError(app, app.dispatch, &err_ev);
            } else {
                const policy = if (reg.queueByName(job.queue)) |q| q.retry else queue.RetryPolicy{};
                const delay_ms = queue.backoffMs(policy, @intCast(new_attempts), randomU64(io));
                const run_at = now + @as(i64, @intCast(delay_ms / 1000));
                try markRetry(w, job.id, new_attempts, run_at, @errorName(e));
            }
        } else {
            try markDone(w, job.id);
        }
    }
    return claimed.len;
}

fn randomU64(io: std.Io) u64 {
    var b: [8]u8 = undefined;
    @import("../entropy.zig").fill(io, &b);
    return std.mem.readInt(u64, &b, .little);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const collections = @import("../collections.zig");
const schema = @import("../schema.zig");
const migrations = @import("../migrations.zig");
const sentry = @import("../sentry.zig");

fn noopSink(_: []const u8) void {}

fn countStatus(d: *db.Db, status: []const u8) !i64 {
    var st = try d.prepare("SELECT COUNT(*) FROM \"_queue_jobs\" WHERE \"status\"=?1;");
    defer st.finalize();
    try st.bindText(1, status);
    _ = try st.step();
    return st.columnInt(0);
}

test "durable enqueue + claimBatch claims ready pending rows and marks them claimed" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const io = testing.io;

    const def = QueueDef{ .name = "default", .backend = .durable };
    try enqueue(&d, io, def, "mail", "{\"a\":1}", clock.nowUnix(io));
    try enqueue(&d, io, def, "mail", "{\"a\":2}", clock.nowUnix(io));
    // A future row must NOT be claimed yet.
    try enqueue(&d, io, def, "mail", "{\"a\":3}", clock.nowUnix(io) + 3600);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const claimed = try claimBatch(arena.allocator(), &d, &.{"default"}, "w1", 10, clock.nowUnix(io));
    try testing.expectEqual(@as(usize, 2), claimed.len);
    try testing.expectEqual(@as(i64, 2), try countStatus(&d, "claimed"));
    try testing.expectEqual(@as(i64, 1), try countStatus(&d, "pending"));
    try testing.expectEqualStrings("mail", claimed[0].kind);
}

test "durable claimBatch drains queues in strict priority order" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const io = testing.io;
    const now = clock.nowUnix(io);

    try enqueue(&d, io, .{ .name = "low", .backend = .durable, .priority = .low }, "k", "lo", now);
    try enqueue(&d, io, .{ .name = "norm", .backend = .durable, .priority = .normal }, "k", "no", now);
    try enqueue(&d, io, .{ .name = "high", .backend = .durable, .priority = .high }, "k", "hi", now);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const qs: []const []const u8 = &.{ "low", "norm", "high" };
    // Claim one at a time: priority decides which comes first regardless of insert order.
    const c1 = try claimBatch(arena.allocator(), &d, qs, "w", 1, now);
    try testing.expectEqualStrings("hi", c1[0].payload);
    const c2 = try claimBatch(arena.allocator(), &d, qs, "w", 1, now);
    try testing.expectEqualStrings("no", c2[0].payload);
    const c3 = try claimBatch(arena.allocator(), &d, qs, "w", 1, now);
    try testing.expectEqualStrings("lo", c3[0].payload);
}

test "durable reclaimStale honors the per-queue timeout and queue scope" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const now: i64 = 1_000_000;

    // Stale + fresh claims on 'default'; a same-age stale claim on a DIFFERENT queue.
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"run_at\",\"status\",\"claimed_at\",\"created\") VALUES ('stale','default','k',5,0,'claimed',900000,datetime('now'));");
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"run_at\",\"status\",\"claimed_at\",\"created\") VALUES ('fresh','default','k',5,0,'claimed',999990,datetime('now'));");
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"run_at\",\"status\",\"claimed_at\",\"created\") VALUES ('other','slow','k',5,0,'claimed',900000,datetime('now'));");

    // Reclaim 'default' with a 300s timeout (cutoff 999700): only 'stale' qualifies; the
    // other-queue row is untouched (queue scope) and 'fresh' is too young (timeout honored).
    const reclaimed = try reclaimStale(&d, "default", now, 300);
    try testing.expectEqual(@as(usize, 1), reclaimed);
    try testing.expectEqual(@as(i64, 1), try countStatus(&d, "pending")); // stale only
    try testing.expectEqual(@as(i64, 2), try countStatus(&d, "claimed")); // fresh + other

    // A LONGER per-queue timeout (200000s -> cutoff 800000) would NOT reclaim 'stale'.
    try d.exec("UPDATE \"_queue_jobs\" SET \"status\"='claimed', \"claimed_at\"=900000 WHERE id='stale';");
    try testing.expectEqual(@as(usize, 0), try reclaimStale(&d, "default", now, 200000));
}

test "durable markRetry / markFailed update attempts + state" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const io = testing.io;
    try enqueue(&d, io, .{ .name = "default", .backend = .durable }, "k", "p", clock.nowUnix(io));
    var idst = try d.prepare("SELECT id FROM \"_queue_jobs\" LIMIT 1;");
    _ = try idst.step();
    const jid = try testing.allocator.dupe(u8, idst.columnText(0));
    defer testing.allocator.free(jid);
    idst.finalize();

    try markRetry(&d, jid, 1, 12345, "boom");
    {
        var st = try d.prepare("SELECT status, attempts, run_at, claimed_at, last_error FROM \"_queue_jobs\" WHERE id=?1;");
        defer st.finalize();
        try st.bindText(1, jid);
        _ = try st.step();
        try testing.expectEqualStrings("pending", st.columnText(0));
        try testing.expectEqual(@as(i64, 1), st.columnInt(1));
        try testing.expectEqual(@as(i64, 12345), st.columnInt(2));
        try testing.expect(st.isNull(3));
        try testing.expectEqualStrings("boom", st.columnText(4));
    }
    try markFailed(&d, jid, 5, "dead");
    try testing.expectEqual(@as(i64, 1), try countStatus(&d, "failed"));
}

test "durable gcDoneJobs reaps old done/failed rows, keeps fresh + pending" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    // Old done + old failed (created a year ago) -> reaped; fresh done + pending -> kept.
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('a','q','k',5,'done',strftime('%Y-%m-%dT%H:%M:%SZ','now','-400 days'));");
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('b','q','k',5,'failed',strftime('%Y-%m-%dT%H:%M:%SZ','now','-400 days'));");
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('c','q','k',5,'done',datetime('now'));");
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('d','q','k',5,'pending',datetime('now'));");

    const deleted = try gcDoneJobs(&d, "q", 30 * 24 * 3600); // 30-day TTL
    try testing.expectEqual(@as(usize, 2), deleted);
    var st = try d.prepare("SELECT COUNT(*) FROM \"_queue_jobs\";");
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 2), st.columnInt(0));
}

// --- Integration: pollOnce over a real pool ---------------------------------

const PollTestEnv = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,
    arena: std.heap.ArenaAllocator,
    app: App,

    fn init() !*PollTestEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(PollTestEnv);
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
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
        }
        env.app = App{ .allocator = env.arena.allocator(), .io = std.testing.io, .pool = &env.pool };
        return env;
    }
    fn deinit(env: *PollTestEnv) void {
        const ga = std.testing.allocator;
        env.arena.deinit();
        env.pool.deinit();
        ga.free(env.db_path);
        env.tmp.cleanup();
        ga.destroy(env);
    }
};

// Test handlers driven by process-wide counters (each test resets them first).
var th_runs: usize = 0;
var th_fail_until: usize = 0; // fail while th_runs <= this
var th_err_count: usize = 0;

fn okHandler(ctx: *Ctx, payload: []const u8) anyerror!void {
    _ = ctx;
    _ = payload;
    th_runs += 1;
}
fn flakyHandler(ctx: *Ctx, payload: []const u8) anyerror!void {
    _ = ctx;
    _ = payload;
    th_runs += 1;
    if (th_runs <= th_fail_until) return error.Flaky;
}
fn onErr(ev: *events.ErrorEvent) void {
    _ = ev;
    th_err_count += 1;
}

test "pollOnce: claim -> dispatch -> done (success)" {
    const env = try PollTestEnv.init();
    defer env.deinit();
    th_runs = 0;
    const reg = Registry{
        .queues = &.{.{ .name = "default", .backend = .durable }},
        .jobs = &.{.{ .kind = "ok", .handler = okHandler }},
    };
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try enqueue(w, env.app.io, reg.queues[0], "ok", "{}", clock.nowUnix(env.app.io));
    }
    const worker = WorkerDef{ .name = "w1", .queues = &.{"default"}, .concurrency = 5 };
    const n = try pollOnce(&env.app, &reg, worker);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 1), th_runs);
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try testing.expectEqual(@as(i64, 1), try countStatus(w, "done"));
    }
}

test "pollOnce honors a CONFIGURED per-queue visibility timeout (reclaims stale, keeps fresh)" {
    const env = try PollTestEnv.init();
    defer env.deinit();
    th_runs = 0;
    // Queue configured with a 10s visibility timeout (the substantive config gap).
    const reg = Registry{
        .queues = &.{.{ .name = "default", .backend = .durable, .visibility_timeout_s = 10 }},
        .jobs = &.{.{ .kind = "ok", .handler = okHandler }},
    };
    const now = clock.nowUnix(env.app.io);
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        // A stale claim (aged 20s > 10s timeout) and a fresh one (aged 5s < timeout).
        var s1 = try w.prepare("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"run_at\",\"status\",\"claimed_at\",\"created\") VALUES ('stale','default','ok',5,0,'claimed',?1,datetime('now'));");
        try s1.bindInt(1, now - 20);
        _ = try s1.step();
        s1.finalize();
        var s2 = try w.prepare("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"run_at\",\"status\",\"claimed_at\",\"created\") VALUES ('fresh','default','ok',5,0,'claimed',?1,datetime('now'));");
        try s2.bindInt(1, now - 5);
        _ = try s2.step();
        s2.finalize();
    }
    const worker = WorkerDef{ .name = "w1", .queues = &.{"default"}, .concurrency = 5 };
    _ = try pollOnce(&env.app, &reg, worker);
    // The stale row was reclaimed -> claimed -> dispatched -> done; the fresh row is untouched.
    try testing.expectEqual(@as(usize, 1), th_runs);
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try testing.expectEqual(@as(i64, 1), try countStatus(w, "done")); // stale
        try testing.expectEqual(@as(i64, 1), try countStatus(w, "claimed")); // fresh, still held
    }
}

test "pollOnce: retry then terminal failure fires .onError" {
    const env = try PollTestEnv.init();
    defer env.deinit();
    th_runs = 0;
    th_err_count = 0;
    th_fail_until = 100; // always fail
    sentry.log_sink = noopSink; // swallow the intentional terminal-failure log
    defer sentry.log_sink = null;
    var dispatch = events.Dispatch{ .on_error = onErr };
    env.app.dispatch = &dispatch;
    const reg = Registry{
        .queues = &.{.{ .name = "default", .backend = .durable, .retry = .{ .max_attempts = 2, .base_ms = 0, .jitter = false } }},
        .jobs = &.{.{ .kind = "flaky", .handler = flakyHandler }},
    };
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try enqueue(w, env.app.io, reg.queues[0], "flaky", "{}", clock.nowUnix(env.app.io));
    }
    const worker = WorkerDef{ .name = "w1", .queues = &.{"default"}, .concurrency = 5 };

    // First poll: attempt 1 fails -> retry (still pending, base_ms 0 -> run_at now).
    _ = try pollOnce(&env.app, &reg, worker);
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try testing.expectEqual(@as(i64, 1), try countStatus(w, "pending"));
    }
    try testing.expectEqual(@as(usize, 0), th_err_count);

    // Second poll: attempt 2 fails -> terminal (max_attempts=2) -> failed + onError.
    _ = try pollOnce(&env.app, &reg, worker);
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try testing.expectEqual(@as(i64, 1), try countStatus(w, "failed"));
    }
    try testing.expectEqual(@as(usize, 2), th_runs);
    try testing.expectEqual(@as(usize, 1), th_err_count);
}
