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

// ── Per-queue rate throttling (#154 round 2) ─────────────────────────────
// Enforced HERE, at claim time: rated queues are claimed per-queue with
// `limit = min(worker's remaining concurrency, reserved tokens)`. Unclaimed ready
// jobs simply wait for the next ~500ms scheduler tick — no sleeping in the worker,
// no per-job pacing. Refill is INTEGER-SECOND on the framework clock (capacity ==
// per_second, so any new second refills to full): deterministic, ZIGBASE_FAKE_NOW-
// compatible, and equivalent to continuous refill at the tick granularity. The map
// is process-global (single-process scheduler ⇒ authoritative) and lazily populated
// ONLY for queues that set `.rate` — zero cost for unrated queues.

/// Pure token-bucket math (unit-tested directly; production drives it via
/// reserveTokens/refundTokens under the global mutex).
pub const TokenBucket = struct {
    capacity: u32,
    tokens: u32,
    last_s: i64,

    pub fn init(per_second: u16, now_s: i64) TokenBucket {
        return .{ .capacity = per_second, .tokens = per_second, .last_s = now_s };
    }

    fn refill(self: *TokenBucket, now_s: i64) void {
        if (now_s <= self.last_s) return; // clock went backwards / same second: no refill
        self.tokens = self.capacity; // capacity == per_second ⇒ any elapsed second refills to full
        self.last_s = now_s;
    }

    /// Reserve up to `want` tokens (decrementing). Returns the grant.
    pub fn reserve(self: *TokenBucket, now_s: i64, want: usize) usize {
        self.refill(now_s);
        const take: u32 = @intCast(@min(want, self.tokens));
        self.tokens -= take;
        return take;
    }

    /// Return unused reserved tokens (claim came up short), capped at capacity.
    pub fn refund(self: *TokenBucket, n: usize) void {
        self.tokens = @intCast(@min(@as(usize, self.capacity), self.tokens + n));
    }
};

fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

var rate_mutex: std.atomic.Mutex = .unlocked;
// page_allocator: process-lifetime map (a handful of tiny entries keyed by the
// registry's comptime-static queue names — no key dup, never freed in prod).
var rate_buckets: std.StringHashMapUnmanaged(TokenBucket) = .empty;

fn reserveTokens(name: []const u8, per_second: u16, now_s: i64, want: usize) usize {
    lockMutex(&rate_mutex);
    defer rate_mutex.unlock();
    const gop = rate_buckets.getOrPut(std.heap.page_allocator, name) catch return 0; // OOM: claim nothing this tick
    if (!gop.found_existing) gop.value_ptr.* = TokenBucket.init(per_second, now_s);
    return gop.value_ptr.reserve(now_s, want);
}

fn refundTokens(name: []const u8, n: usize) void {
    if (n == 0) return;
    lockMutex(&rate_mutex);
    defer rate_mutex.unlock();
    if (rate_buckets.getPtr(name)) |b| b.refund(n);
}

/// TEST-ONLY: drop all buckets so each test starts from a full burst.
pub fn resetRateBucketsForTest() void {
    if (!@import("builtin").is_test) @compileError("resetRateBucketsForTest is test-only");
    lockMutex(&rate_mutex);
    defer rate_mutex.unlock();
    rate_buckets.deinit(std.heap.page_allocator);
    rate_buckets = .empty;
}

/// Insert a `pending` durable job and return its generated id. `run_at` is the earliest
/// unix-second the job may be claimed (pass `clock.nowUnix(io)` for immediate; a future
/// value is the SCHEDULING primitive — `claimBatch` only claims `run_at <= now`, indexed).
/// The writer must be held by the caller.
pub fn enqueue(w: *db.Db, io: std.Io, def: QueueDef, kind: []const u8, payload: []const u8, run_at: i64) ![15]u8 {
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
    return jid;
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
    var numbuf: [20]u8 = undefined;
    var pidx: usize = 4;
    for (queue_names, 0..) |_, i| {
        if (i != 0) try sql.append(arena, ',');
        try sql.append(arena, '?');
        try sql.appendSlice(arena, std.fmt.bufPrint(&numbuf, "{d}", .{pidx}) catch unreachable);
        pidx += 1;
    }
    try sql.appendSlice(arena, ") ORDER BY \"priority\" ASC, \"run_at\" ASC LIMIT ?");
    try sql.appendSlice(arena, std.fmt.bufPrint(&numbuf, "{d}", .{pidx}) catch unreachable);
    try sql.appendSlice(arena, ") RETURNING \"id\",\"queue\",\"kind\",\"payload\",\"attempts\",\"max_attempts\";");
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

/// Cancel a still-PENDING durable job. Returns true when the row transitioned
/// pending→canceled; false when nothing matched (already claimed/done/failed/
/// canceled, or unknown id — it ran or is running). NO-MATCH IS DETECTED AS
/// `changes() == 0`, NEVER as "success == 1": sqlite3_changes also counts rows
/// touched by triggers (e.g. FTS5), so equality-with-1 false-positives on tables
/// with triggers. `claimBatch` only claims 'pending', so no claim-path change.
pub fn cancelJob(w: *db.Db, job_id: []const u8) !bool {
    var st = try w.prepare(
        \\UPDATE "_queue_jobs" SET "status"='canceled', "claimed_at"=NULL
        \\ WHERE "id"=?1 AND "status"='pending';
    );
    defer st.finalize();
    try st.bindText(1, job_id);
    _ = try st.step();
    return w.changesCount() != 0;
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

/// GC sweep for ONE queue: delete `done`/`failed`/`canceled` rows of `queue_name` whose `created`
/// is older than `ttl_s` seconds, in bounded batches (mirrors `features_resolver.gcExpiredAssignments`).
/// The TTL is per-queue (`QueueDef.done_ttl_s`). Returns rows deleted. Writer held by caller.
pub fn gcDoneJobs(w: *db.Db, queue_name: []const u8, ttl_s: i64) !usize {
    var buf: [32]u8 = undefined;
    const modifier = std.fmt.bufPrint(&buf, "-{d} seconds", .{ttl_s}) catch unreachable;
    var total: usize = 0;
    while (true) {
        // `created` is always written canonical via datetime('now'), so compare it DIRECTLY
        // against datetime('now', ?2) rather than wrapping both sides in strftime — keeping
        // the predicate sargable so the `(created)` index serves the scan instead of a full table scan.
        var st = try w.prepare(comptime std.fmt.comptimePrint(
            \\DELETE FROM "_queue_jobs"
            \\ WHERE rowid IN (
            \\   SELECT rowid FROM "_queue_jobs"
            \\    WHERE "status" IN ('done','failed','canceled') AND "queue"=?1
            \\      AND "created" <= datetime('now', ?2)
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

    var durable_qs: std.ArrayList([]const u8) = .empty; // unrated
    var rated_qs: std.ArrayList(QueueDef) = .empty;
    for (worker.queues) |qn| {
        if (reg.queueByName(qn)) |q| {
            if (q.backend != .durable) continue;
            if (q.rate == null) try durable_qs.append(pa, qn) else try rated_qs.append(pa, q);
        }
    }
    if (durable_qs.items.len == 0 and rated_qs.items.len == 0) return 0;

    var claimed_list: std.ArrayList(Claimed) = .empty;
    {
        const w = app.pool.acquireWriter();
        defer app.pool.releaseWriter();
        // Reclaim each durable queue with ITS OWN visibility timeout before claiming.
        for (durable_qs.items) |qn| {
            const vt = if (reg.queueByName(qn)) |q| q.visibility_timeout_s else 300;
            _ = reclaimStale(w, qn, now, vt) catch |e|
                std.log.warn("queue '{s}' reclaim sweep failed: {s}", .{ qn, @errorName(e) });
        }
        for (rated_qs.items) |q| {
            _ = reclaimStale(w, q.name, now, q.visibility_timeout_s) catch |e|
                std.log.warn("queue '{s}' reclaim sweep failed: {s}", .{ q.name, @errorName(e) });
        }
        var remaining: usize = worker.concurrency;
        if (durable_qs.items.len > 0 and remaining > 0) {
            const c = try claimBatch(pa, w, durable_qs.items, worker.name, remaining, now);
            try claimed_list.appendSlice(pa, c);
            remaining -= c.len;
        }
        for (rated_qs.items) |q| {
            if (remaining == 0) break;
            // Reserve-then-claim-then-refund is race-safe: tokens are decremented up
            // front, and only the shortfall (grant - actually claimed) is returned.
            const grant = reserveTokens(q.name, q.rate.?.per_second, now, remaining);
            if (grant == 0) continue;
            const c = try claimBatch(pa, w, &.{q.name}, worker.name, grant, now);
            if (c.len < grant) refundTokens(q.name, grant - c.len);
            try claimed_list.appendSlice(pa, c);
            remaining -= c.len;
        }
    }
    const claimed = claimed_list.items;

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
                // Round ms→s UP so a sub-second backoff (e.g. base_ms=500) still waits >=1s
                // rather than truncating to an immediate retry. (delay_ms==0 stays 0.)
                const run_at = now + @as(i64, @intCast((delay_ms + 999) / 1000));
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
const report_log = @import("../report/log.zig");

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
    _ = try enqueue(&d, io, def, "mail", "{\"a\":1}", clock.nowUnix(io));
    _ = try enqueue(&d, io, def, "mail", "{\"a\":2}", clock.nowUnix(io));
    // A future row must NOT be claimed yet.
    _ = try enqueue(&d, io, def, "mail", "{\"a\":3}", clock.nowUnix(io) + 3600);

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

    _ = try enqueue(&d, io, .{ .name = "low", .backend = .durable, .priority = .low }, "k", "lo", now);
    _ = try enqueue(&d, io, .{ .name = "norm", .backend = .durable, .priority = .normal }, "k", "no", now);
    _ = try enqueue(&d, io, .{ .name = "high", .backend = .durable, .priority = .high }, "k", "hi", now);

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
    _ = try enqueue(&d, io, .{ .name = "default", .backend = .durable }, "k", "p", clock.nowUnix(io));
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
    // `created` is canonical datetime('now') format, as durable.enqueue writes it.
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('a','q','k',5,'done',datetime('now','-400 days'));");
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('b','q','k',5,'failed',datetime('now','-400 days'));");
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('c','q','k',5,'done',datetime('now'));");
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('d','q','k',5,'pending',datetime('now'));");

    const deleted = try gcDoneJobs(&d, "q", 30 * 24 * 3600); // 30-day TTL
    try testing.expectEqual(@as(usize, 2), deleted);
    var st = try d.prepare("SELECT COUNT(*) FROM \"_queue_jobs\";");
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 2), st.columnInt(0));
}

test "enqueue returns the persisted job id; a future run_at is not claimed until due" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const io = testing.io;
    const def = QueueDef{ .name = "default", .backend = .durable };
    const jid = try enqueue(&d, io, def, "k", "{}", 2_000_000); // due at t=2M
    {
        var st = try d.prepare("SELECT \"status\" FROM \"_queue_jobs\" WHERE \"id\"=?1;");
        defer st.finalize();
        try st.bindText(1, &jid);
        try testing.expect(try st.step());
        try testing.expectEqualStrings("pending", st.columnText(0));
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Before due: nothing claimable. At/after due: claimed.
    try testing.expectEqual(@as(usize, 0), (try claimBatch(arena.allocator(), &d, &.{"default"}, "w", 10, 1_999_999)).len);
    try testing.expectEqual(@as(usize, 1), (try claimBatch(arena.allocator(), &d, &.{"default"}, "w", 10, 2_000_000)).len);
}

test "cancelJob: pending -> true; claimed/done/second-cancel -> false (changes()==0 no-match rule)" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const io = testing.io;
    const def = QueueDef{ .name = "default", .backend = .durable };
    const jid = try enqueue(&d, io, def, "k", "{}", clock.nowUnix(io) + 3600);
    try testing.expect(try cancelJob(&d, &jid)); // pending -> canceled
    try testing.expect(!try cancelJob(&d, &jid)); // already canceled -> no match
    try testing.expect(!try cancelJob(&d, "nonexistent-id!")); // unknown -> no match
    // A canceled job is invisible to the claim query.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try claimBatch(arena.allocator(), &d, &.{"default"}, "w", 10, clock.nowUnix(io) + 7200)).len);
}

test "gcDoneJobs reaps old canceled rows" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('c1','q','k',5,'canceled',datetime('now','-400 days'));");
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('c2','q','k',5,'canceled',datetime('now'));");
    try testing.expectEqual(@as(usize, 1), try gcDoneJobs(&d, "q", 30 * 24 * 3600)); // old canceled reaped, fresh kept
}

test "TokenBucket: full burst, drain, integer-second refill, refund cap" {
    var b = TokenBucket.init(3, 100);
    try testing.expectEqual(@as(usize, 3), b.reserve(100, 10)); // burst = 1s of tokens
    try testing.expectEqual(@as(usize, 0), b.reserve(100, 1)); // same second: empty
    try testing.expectEqual(@as(usize, 3), b.reserve(101, 5)); // new second: refilled to capacity
    b.refund(99);
    try testing.expectEqual(@as(u32, 3), b.tokens); // refund never exceeds capacity
    try testing.expectEqual(@as(usize, 2), b.reserve(50, 2)); // clock going BACKWARDS: no refill, but reserve still works
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
        _ = try enqueue(w, env.app.io, reg.queues[0], "ok", "{}", clock.nowUnix(env.app.io));
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
    report_log.log_sink = noopSink; // swallow the intentional terminal-failure log
    defer report_log.log_sink = null;
    var dispatch = events.Dispatch{ .on_error = onErr };
    env.app.dispatch = &dispatch;
    const reg = Registry{
        .queues = &.{.{ .name = "default", .backend = .durable, .retry = .{ .max_attempts = 2, .base_ms = 0, .jitter = false } }},
        .jobs = &.{.{ .kind = "flaky", .handler = flakyHandler }},
    };
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        _ = try enqueue(w, env.app.io, reg.queues[0], "flaky", "{}", clock.nowUnix(env.app.io));
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

test "pollOnce claims <= tokens on a rated queue while an unrated queue drains unthrottled" {
    // Needs `clock.setForTest` to freeze the token-bucket refill second deterministically;
    // that's a no-op on a `-Ddev-mode=false` build (see clock.zig), so this can't run there.
    if (!clock.enabled) return error.SkipZigTest;
    const env = try PollTestEnv.init();
    defer env.deinit();
    resetRateBucketsForTest();
    defer resetRateBucketsForTest();
    clock.setForTest(1_000_000);
    defer clock.resetForTest();
    th_runs = 0;
    const reg = Registry{
        .queues = &.{
            .{ .name = "fast", .backend = .durable },
            .{ .name = "slow", .backend = .durable, .rate = .{ .per_second = 2 } },
        },
        .jobs = &.{.{ .kind = "ok", .handler = okHandler }},
    };
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var i: usize = 0;
        while (i < 3) : (i += 1) _ = try enqueue(w, env.app.io, reg.queues[0], "ok", "{}", clock.nowUnix(env.app.io));
        i = 0;
        while (i < 5) : (i += 1) _ = try enqueue(w, env.app.io, reg.queues[1], "ok", "{}", clock.nowUnix(env.app.io));
    }
    const worker = WorkerDef{ .name = "w1", .queues = &.{ "fast", "slow" }, .concurrency = 10 };
    // Tick 1: all 3 unrated + only 2 rated (the 1s burst).
    try testing.expectEqual(@as(usize, 5), try pollOnce(&env.app, &reg, worker));
    // Tick 2, same frozen second: the bucket is empty — nothing more claimed.
    try testing.expectEqual(@as(usize, 0), try pollOnce(&env.app, &reg, worker));
    // Advance one second: 2 more.
    clock.setForTest(1_000_001);
    try testing.expectEqual(@as(usize, 2), try pollOnce(&env.app, &reg, worker));
    clock.setForTest(1_000_002);
    try testing.expectEqual(@as(usize, 1), try pollOnce(&env.app, &reg, worker));
    try testing.expectEqual(@as(usize, 8), th_runs);
}
