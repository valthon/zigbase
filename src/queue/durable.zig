//! Durable queue backend (#137 PR2): jobs persisted to `_queue_jobs` and drained by
//! a per-worker poller. At-least-once — a crash after a side effect but before the
//! row is marked `done` replays the job (consumers tolerate replays; the webhook
//! idempotency key is the antidote). The pure DB ops here operate on the WRITER and
//! are deadlock-safe to compose: the poller claims under the writer, RELEASES it,
//! dispatches the handler (which may take the writer itself), then re-acquires it to
//! record the outcome.

const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
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

/// All callers pass bounded engine-owned SQL literals (under 1 KiB). Lowering
/// uses caller-buffer scratch, not a hidden heap allocator; prepare copies the
/// statement before this stack buffer expires. Dynamic claim SQL uses its own
/// explicitly allocated scratch below instead.
fn prepareStatic(w: *db.Db, sql: [:0]const u8) !db.Stmt {
    if (db.dbDialect(w).kind == .sqlite) return w.prepare(sql);
    var buf: [8192]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buf);
    return w.prepare(try @import("../sql/param_sink.zig").lowerStmtZ(scratch.allocator(), db.dbDialect(w), sql));
}

/// Bound on a single GC / reclaim batch so a large backlog never holds the writer
/// for one long statement (mirrors `features_resolver.assignment_gc_batch`).
pub const gc_batch: usize = 1000;

/// Insert a `pending` durable job and return its generated id. `run_at` is the earliest
/// unix-second the job may be claimed (pass `clock.nowUnix(io)` for immediate; a future
/// value is the SCHEDULING primitive — `claimBatch` only claims `run_at <= now`, indexed).
/// The writer must be held by the caller.
pub fn enqueue(w: *db.Db, io: std.Io, def: QueueDef, kind: []const u8, payload: []const u8, run_at: i64) ![15]u8 {
    const jid = id.collectionId(io);
    var st = try prepareStatic(w,
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

/// A claimed (now in-flight) durable job. Its four string slices are OWNED (each duped on the
/// allocator `claimBatch` was given); free a `[]Claimed` result via `freeClaimed`.
pub const Claimed = struct {
    id: []const u8,
    queue: []const u8,
    kind: []const u8,
    payload: []const u8,
    attempts: i64,
    max_attempts: i64,
    generation: i64,

    /// Free this claim's four owned string slices (NOT the containing slice — see `freeClaimed`).
    fn deinit(self: Claimed, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.queue);
        alloc.free(self.kind);
        alloc.free(self.payload);
    }
};

/// Free a `claimBatch` result: each `Claimed`'s owned strings, then the backing slice. Contract-2 —
/// production drivers (`pollOnce`) pass a poll arena that reclaims wholesale, but a direct caller
/// (and the leak-checked tests) frees the graph honestly with this.
pub fn freeClaimed(alloc: std.mem.Allocator, claimed: []Claimed) void {
    for (claimed) |c| c.deinit(alloc);
    alloc.free(claimed);
}

/// Dupe one claimed row's owned strings off `alloc`, with per-field cleanup so a mid-dupe OOM frees
/// the earlier fields (nothing is appended yet on failure).
fn claimOne(alloc: std.mem.Allocator, st: *db.Stmt) !Claimed {
    const cid = try alloc.dupe(u8, st.columnText(0));
    errdefer alloc.free(cid);
    const cqueue = try alloc.dupe(u8, st.columnText(1));
    errdefer alloc.free(cqueue);
    const ckind = try alloc.dupe(u8, st.columnText(2));
    errdefer alloc.free(ckind);
    const cpayload = try alloc.dupe(u8, st.columnText(3));
    errdefer alloc.free(cpayload);
    return .{
        .id = cid,
        .queue = cqueue,
        .kind = ckind,
        .payload = cpayload,
        .attempts = st.columnInt(4),
        .max_attempts = st.columnInt(5),
        .generation = st.columnInt(6),
    };
}

/// Atomically claim up to `limit` ready rows for `queue_names`, ORDER BY priority,run_at —
/// so higher-priority queues drain first (strict priority). Marks each row `claimed`
/// (claimed_at=now, claimed_by=worker) and RETURNs it. The writer must be held by the caller.
/// Returns an empty slice when nothing is ready.
pub fn claimBatch(
    alloc: std.mem.Allocator,
    w: *db.Db,
    queue_names: []const []const u8,
    worker_name: []const u8,
    limit: usize,
    now: i64,
) ![]Claimed {
    if (queue_names.len == 0 or limit == 0) return &.{};

    // The dynamic `IN (?,?,…)` SQL is one-shot scratch — only the claimed rows escape. Build it on a
    // function-local arena so the SQL text/builder never leak onto `alloc` (queue names are BOUND
    // params, no injection).
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(sa,
        \\UPDATE "_queue_jobs" SET "status"='claimed', "claimed_at"=?1, "claimed_by"=?2, "claim_generation"="claim_generation"+1
        \\ WHERE "id" IN (
        \\   SELECT "id" FROM "_queue_jobs"
        \\    WHERE "status"='pending' AND "run_at" <= ?3 AND "queue" IN (
    );
    var numbuf: [20]u8 = undefined;
    var pidx: usize = 4;
    for (queue_names, 0..) |_, i| {
        if (i != 0) try sql.append(sa, ',');
        try sql.append(sa, '?');
        try sql.appendSlice(sa, std.fmt.bufPrint(&numbuf, "{d}", .{pidx}) catch unreachable);
        pidx += 1;
    }
    try sql.appendSlice(sa, ") ORDER BY \"priority\" ASC, \"run_at\" ASC LIMIT ?");
    try sql.appendSlice(sa, std.fmt.bufPrint(&numbuf, "{d}", .{pidx}) catch unreachable);
    // Lock candidates before UPDATE on PostgreSQL: another instance must skip
    // these rows, not wait and subsequently overwrite their claim. SQLite's
    // single writer already makes this statement atomic.
    if (db.dbDialect(w).kind == .postgres) try sql.appendSlice(sa, " FOR UPDATE SKIP LOCKED");
    try sql.appendSlice(sa, ") RETURNING \"id\",\"queue\",\"kind\",\"payload\",\"attempts\",\"max_attempts\",\"claim_generation\";");
    const sql_z = try sa.dupeZ(u8, sql.items);

    var st = try w.prepare(try @import("../sql/param_sink.zig").lowerStmtZ(sa, db.dbDialect(w), sql_z));
    defer st.finalize();
    try st.bindInt(1, now);
    try st.bindText(2, worker_name);
    try st.bindInt(3, now);
    for (queue_names, 0..) |qn, i| try st.bindText(@intCast(4 + i), qn);
    try st.bindInt(@intCast(pidx), @intCast(limit));

    // The claimed rows escape on `alloc` (contract-2, freed via `freeClaimed`). On any error mid-scan
    // the rows already built are freed — a raw allocator must not leak them (production's arena would).
    var out: std.ArrayList(Claimed) = .empty;
    errdefer {
        for (out.items) |c| c.deinit(alloc);
        out.deinit(alloc);
    }
    while (try st.step()) {
        const c = try claimOne(alloc, &st);
        out.append(alloc, c) catch |e| {
            c.deinit(alloc); // not yet appended — free before the errdefer sweeps the rest
            return e;
        };
    }
    return out.toOwnedSlice(alloc);
}

/// Claim a rated queue in one transaction with its shared rate window. The caller
/// holds the writer, but MUST NOT already be in a transaction. Only actual claims
/// spend capacity; errors roll back both the claims and their rate charge. The
/// returned graph has the same owned-result contract as claimBatch.
pub fn claimRateLimited(alloc: std.mem.Allocator, w: *db.Db, name: []const u8, worker: []const u8, per_second: u16, limit: usize, now: i64) ![]Claimed {
    if (limit == 0 or per_second == 0) return &.{};
    try w.beginImmediate();
    errdefer w.rollback() catch |e| std.log.err("queue rate claim rollback failed: {s}", .{@errorName(e)});
    {
        var st = try prepareStatic(w, "INSERT INTO \"_queue_rates\" (\"queue\",\"window_s\",\"used\") VALUES (?1,?2,0) ON CONFLICT (\"queue\") DO NOTHING;");
        defer st.finalize();
        try st.bindText(1, name);
        try st.bindInt(2, now);
        _ = try st.step();
    }
    var window: i64 = undefined;
    var used: i64 = undefined;
    {
        const sql = "SELECT \"window_s\",\"used\" FROM \"_queue_rates\" WHERE \"queue\"=?1";
        var st = try prepareStatic(w, if (db.dbDialect(w).kind == .postgres) sql ++ " FOR UPDATE;" else sql ++ ";");
        defer st.finalize();
        try st.bindText(1, name);
        if (!try st.step()) return error.MissingRateWindow;
        window = st.columnInt(0);
        used = st.columnInt(1);
    }
    // A backwards clock never refills; a changed configured ceiling applies to
    // the capacity remaining after claims already charged in this second.
    if (now > window) {
        window = now;
        used = 0;
    }
    const remaining: usize = @intCast(@max(0, @as(i64, per_second) - used));
    if (remaining == 0) {
        try w.commit();
        return &.{};
    }
    const claimed = try claimBatch(alloc, w, &.{name}, worker, @min(limit, remaining), now);
    errdefer freeClaimed(alloc, claimed);
    // No claim spends capacity. Do not persist a window rollover just because
    // an idle worker polled: the next claimant recomputes it from the clock.
    if (claimed.len == 0) {
        try w.commit();
        return claimed;
    }
    {
        var st = try prepareStatic(w, "UPDATE \"_queue_rates\" SET \"window_s\"=?2,\"used\"=?3 WHERE \"queue\"=?1;");
        defer st.finalize();
        try st.bindText(1, name);
        try st.bindInt(2, window);
        try st.bindInt(3, used + @as(i64, @intCast(claimed.len)));
        _ = try st.step();
    }
    try w.commit();
    return claimed;
}

const Outcome = enum { done, retry, failed };

/// A visibility timeout can expire while the old handler is still executing.
/// Its completion must not overwrite a newer attempt (even on the same named
/// worker or in the same second). The monotonically incremented claim generation
/// fences all three outcomes. A reclaimed but not re-claimed attempt may finish;
/// terminal states (including cancellation after reclaim) remain terminal.
/// False means ownership was lost or the row is terminal, not success.
fn finishClaim(w: *db.Db, job: Claimed, outcome: Outcome, attempts: i64, run_at: i64, last_error: []const u8) !bool {
    var st = try prepareStatic(w,
        \\UPDATE "_queue_jobs" SET "status"=?3, "attempts"=?4, "run_at"=?5,
        \\ "last_error"=?6, "claimed_at"=NULL, "claimed_by"=''
        \\ WHERE "id"=?1 AND "claim_generation"=?2 AND "status" IN ('claimed','pending');
    );
    defer st.finalize();
    try st.bindText(1, job.id);
    try st.bindInt(2, job.generation);
    try st.bindText(3, if (outcome == .retry) "pending" else @tagName(outcome));
    try st.bindInt(4, attempts);
    try st.bindInt(5, run_at);
    try st.bindText(6, last_error);
    _ = try st.step();
    return w.changesCount() != 0;
}

/// Cancel a still-PENDING durable job. Returns true when the row transitioned
/// pending→canceled; false when nothing matched (already claimed/done/failed/
/// canceled, or unknown id — it ran or is running). NO-MATCH IS DETECTED AS
/// `changes() == 0`, NEVER as "success == 1": sqlite3_changes also counts rows
/// touched by triggers (e.g. FTS5), so equality-with-1 false-positives on tables
/// with triggers. `claimBatch` only claims 'pending', so no claim-path change.
pub fn cancelJob(w: *db.Db, job_id: []const u8) !bool {
    var st = try prepareStatic(w,
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
    var st = try prepareStatic(w,
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
        const sqlite_sql = comptime std.fmt.comptimePrint(
            \\DELETE FROM "_queue_jobs"
            \\ WHERE rowid IN (
            \\   SELECT rowid FROM "_queue_jobs"
            \\    WHERE "status" IN ('done','failed','canceled') AND "queue"=?1
            \\      AND "created" <= datetime('now', ?2)
            \\    LIMIT {d}
            \\ )
            \\ RETURNING "id";
        , .{gc_batch});
        const postgres_sql = comptime std.fmt.comptimePrint(
            \\DELETE FROM "_queue_jobs" WHERE "id" IN (
            \\ SELECT "id" FROM "_queue_jobs" WHERE "status" IN ('done','failed','canceled') AND "queue"=?1
            \\ AND "created" <= to_char((now() - (?2 * INTERVAL '1 second')) AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')
            \\ LIMIT {d} FOR UPDATE SKIP LOCKED) RETURNING "id";
        , .{gc_batch});
        const pg = db.dbDialect(w).kind == .postgres;
        var st = try prepareStatic(w, if (pg) postgres_sql else sqlite_sql);
        defer st.finalize();
        try st.bindText(1, queue_name);
        if (pg) try st.bindInt(2, ttl_s) else try st.bindText(2, modifier);
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
            const c = try claimRateLimited(pa, w, q.name, worker.name, q.rate.?.per_second, remaining, now);
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
            var cx = Ctx{ .app = app, .arena = RequestArena.from(&arena), .rctx = .{}, .request = null, .bound_conn = null };
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
                if (!try finishClaim(w, job, .failed, new_attempts, now, @errorName(e))) continue;
                var err_ev = events.ErrorEvent{ .app = app, .ctx = null, .err = e, .phase = .job, .message = @errorName(e) };
                events.dispatchError(app, app.dispatch, &err_ev);
            } else {
                const policy = if (reg.queueByName(job.queue)) |q| q.retry else queue.RetryPolicy{};
                const delay_ms = queue.backoffMs(policy, @intCast(new_attempts), randomU64(io));
                // Round ms→s UP so a sub-second backoff (e.g. base_ms=500) still waits >=1s
                // rather than truncating to an immediate retry. (delay_ms==0 stays 0.)
                const run_at = now + @as(i64, @intCast((delay_ms + 999) / 1000));
                _ = try finishClaim(w, job, .retry, new_attempts, run_at, @errorName(e));
            }
        } else {
            _ = try finishClaim(w, job, .done, job.attempts, now, "");
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
    var st = try prepareStatic(d, "SELECT COUNT(*) FROM \"_queue_jobs\" WHERE \"status\"=?1;");
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

    // claimBatch returns an owned graph (contract-2), freed via freeClaimed — so it runs under the
    // raw leak-detecting allocator.
    const a = testing.allocator;
    const claimed = try claimBatch(a, &d, &.{"default"}, "w1", 10, clock.nowUnix(io));
    defer freeClaimed(a, claimed);
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

    const a = testing.allocator;
    const qs: []const []const u8 = &.{ "low", "norm", "high" };
    // Claim one at a time: priority decides which comes first regardless of insert order.
    const c1 = try claimBatch(a, &d, qs, "w", 1, now);
    defer freeClaimed(a, c1);
    try testing.expectEqualStrings("hi", c1[0].payload);
    const c2 = try claimBatch(a, &d, qs, "w", 1, now);
    defer freeClaimed(a, c2);
    try testing.expectEqualStrings("no", c2[0].payload);
    const c3 = try claimBatch(a, &d, qs, "w", 1, now);
    defer freeClaimed(a, c3);
    try testing.expectEqualStrings("lo", c3[0].payload);
}

test "shared rate window charges actual claims, respects changed limits and backwards clocks" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = testing.allocator;
    const empty = try claimRateLimited(a, &d, "rated", "a", 3, 10, 100);
    defer freeClaimed(a, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    for (0..6) |_| _ = try enqueue(&d, testing.io, .{ .name = "rated", .backend = .durable }, "k", "{}", 0);
    const first = try claimRateLimited(a, &d, "rated", "a", 3, 2, 100);
    defer freeClaimed(a, first);
    try testing.expectEqual(@as(usize, 2), first.len);
    const lowered = try claimRateLimited(a, &d, "rated", "b", 1, 10, 100);
    defer freeClaimed(a, lowered);
    try testing.expectEqual(@as(usize, 0), lowered.len);
    const remainder = try claimRateLimited(a, &d, "rated", "b", 3, 10, 99);
    defer freeClaimed(a, remainder);
    try testing.expectEqual(@as(usize, 1), remainder.len);
    const drained = try claimRateLimited(a, &d, "rated", "a", 3, 10, 100);
    defer freeClaimed(a, drained);
    try testing.expectEqual(@as(usize, 0), drained.len);
    const refilled = try claimRateLimited(a, &d, "rated", "b", 3, 10, 101);
    defer freeClaimed(a, refilled);
    try testing.expectEqual(@as(usize, 3), refilled.len);
}

test "shared rate claim rolls back job mutations and budget on allocation failure" {
    const Probe = struct {
        fn run(a: std.mem.Allocator) !void {
            var d = try db.Db.openMemory();
            defer d.close();
            try migrations.run(&d);
            _ = try enqueue(&d, testing.io, .{ .name = "rated", .backend = .durable }, "k", "{}", 0);
            const claimed = claimRateLimited(a, &d, "rated", "a", 1, 10, 100) catch |e| {
                try testing.expectEqual(@as(i64, 1), try countStatus(&d, "pending"));
                // A fresh allocator must still be able to claim the entire budget
                // after failures both before and after UPDATE RETURNING ran.
                const retried = try claimRateLimited(testing.allocator, &d, "rated", "b", 1, 10, 100);
                defer freeClaimed(testing.allocator, retried);
                try testing.expectEqual(@as(usize, 1), retried.len);
                return e;
            };
            defer freeClaimed(a, claimed);
            try testing.expectEqual(@as(usize, 1), claimed.len);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Probe.run, .{});
}

test "idle and exhausted rated polls never update the rate row" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = testing.allocator;
    const first = try claimRateLimited(a, &d, "rated", "a", 1, 1, 100);
    defer freeClaimed(a, first);
    try d.exec("CREATE TRIGGER reject_idle_rate_write BEFORE UPDATE ON _queue_rates BEGIN SELECT RAISE(ABORT, 'unexpected idle rate write'); END;");
    const rollover = try claimRateLimited(a, &d, "rated", "a", 1, 1, 101);
    defer freeClaimed(a, rollover);
    try testing.expectEqual(@as(usize, 0), rollover.len);
    try d.exec("DROP TRIGGER reject_idle_rate_write;");
    _ = try enqueue(&d, testing.io, .{ .name = "rated", .backend = .durable }, "k", "{}", 0);
    const claimed = try claimRateLimited(a, &d, "rated", "a", 1, 1, 101);
    defer freeClaimed(a, claimed);
    try testing.expectEqual(@as(usize, 1), claimed.len);
    try d.exec("CREATE TRIGGER reject_exhausted_rate_write BEFORE UPDATE ON _queue_rates BEGIN SELECT RAISE(ABORT, 'unexpected exhausted rate write'); END;");
    const exhausted = try claimRateLimited(a, &d, "rated", "a", 1, 1, 101);
    defer freeClaimed(a, exhausted);
    try testing.expectEqual(@as(usize, 0), exhausted.len);
}

test "reclaimed attempts may finish before re-claim but never override cancellation" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    inline for (.{ Outcome.done, Outcome.retry, Outcome.failed }) |outcome| {
        _ = try enqueue(&d, testing.io, .{ .name = "q", .backend = .durable }, "k", "{}", 0);
        const jobs = try claimBatch(testing.allocator, &d, &.{"q"}, "worker", 1, 100);
        defer freeClaimed(testing.allocator, jobs);
        try testing.expectEqual(@as(usize, 1), try reclaimStale(&d, "q", 101, 1));
        try testing.expect(try finishClaim(&d, jobs[0], outcome, 1, 200, "late"));
        try d.exec("DELETE FROM _queue_jobs;");
        const id_cancel = try enqueue(&d, testing.io, .{ .name = "q", .backend = .durable }, "k", "{}", 0);
        const canceled = try claimBatch(testing.allocator, &d, &.{"q"}, "worker", 1, 100);
        defer freeClaimed(testing.allocator, canceled);
        _ = try reclaimStale(&d, "q", 101, 1);
        try testing.expect(try cancelJob(&d, &id_cancel));
        try testing.expect(!try finishClaim(&d, canceled[0], outcome, 1, 200, "late"));
        try testing.expectEqual(@as(i64, 1), try countStatus(&d, "canceled"));
        try d.exec("DELETE FROM _queue_jobs;");
    }
}

test "expired queue attempts cannot overwrite a newer claim with any outcome" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    _ = try enqueue(&d, testing.io, .{ .name = "q", .backend = .durable }, "k", "{}", 0);
    const first = try claimBatch(testing.allocator, &d, &.{"q"}, "same-worker", 1, 100);
    defer freeClaimed(testing.allocator, first);
    try testing.expectEqual(@as(usize, 1), try reclaimStale(&d, "q", 101, 1));
    const second = try claimBatch(testing.allocator, &d, &.{"q"}, "same-worker", 1, 101);
    defer freeClaimed(testing.allocator, second);
    try testing.expect(second[0].generation > first[0].generation);
    inline for (.{ Outcome.done, Outcome.retry, Outcome.failed }) |outcome| {
        try testing.expect(!try finishClaim(&d, first[0], outcome, 1, 102, "stale"));
        try testing.expectEqual(@as(i64, 1), try countStatus(&d, "claimed"));
    }
    try testing.expect(try finishClaim(&d, second[0], .done, 0, 102, ""));
    try testing.expectEqual(@as(i64, 1), try countStatus(&d, "done"));
    try testing.expect(!try finishClaim(&d, second[0], .retry, 1, 103, "duplicate"));
}

// Two independent connections, isolated from other live suites. No arena: all
// connection allocations remain visible to the test allocator's leak detector.
const PgQueueTest = struct {
    first: db.Db,
    second: db.Db,
    name: [15]u8,

    fn init() !PgQueueTest {
        if (!@import("build_options").postgres) return error.SkipZigTest;
        const url = @import("../backend/postgres/tests.zig").testUrl();
        var first = db.Db.openPostgres(testing.allocator, testing.io, url) catch |e| switch (e) {
            error.OpenFailed => return error.SkipZigTest,
            else => return e,
        };
        errdefer first.close();
        var second = try db.Db.openPostgres(testing.allocator, testing.io, url);
        errdefer second.close();
        const name = id.collectionId(testing.io);
        var buf: [128]u8 = undefined;
        try first.exec(try std.fmt.bufPrintZ(&buf, "CREATE SCHEMA \"zbq_{s}\";", .{name}));
        errdefer first.exec(std.fmt.bufPrintZ(&buf, "DROP SCHEMA \"zbq_{s}\" CASCADE;", .{name}) catch unreachable) catch |e|
            std.log.err("queue test schema cleanup failed: {s}", .{@errorName(e)});
        const path = try std.fmt.bufPrintZ(&buf, "SET search_path TO \"zbq_{s}\";", .{name});
        try first.exec(path);
        try second.exec(path);
        try migrations.run(&first);
        return .{ .first = first, .second = second, .name = name };
    }

    fn deinit(self: *PgQueueTest) void {
        self.second.close();
        var buf: [128]u8 = undefined;
        self.first.exec(std.fmt.bufPrintZ(&buf, "DROP SCHEMA \"zbq_{s}\" CASCADE;", .{self.name}) catch unreachable) catch |e|
            std.log.err("queue test schema cleanup failed: {s}", .{@errorName(e)});
        self.first.close();
    }
};

test "pg durable claims skip another connection's uncommitted claims" {
    if (!@import("build_options").postgres) return error.SkipZigTest;
    var env = try PgQueueTest.init();
    defer env.deinit();
    for (0..2) |_| _ = try enqueue(&env.first, testing.io, .{ .name = "q", .backend = .durable }, "k", "{}", 0);
    try env.first.beginImmediate();
    defer env.first.rollback() catch |e| std.log.err("test rollback failed: {s}", .{@errorName(e)});
    const first = try claimBatch(testing.allocator, &env.first, &.{"q"}, "a", 1, 100);
    defer freeClaimed(testing.allocator, first);
    // Without SKIP LOCKED this times out trying to overwrite the first claim.
    try env.second.exec("SET lock_timeout = '250ms';");
    const second = try claimBatch(testing.allocator, &env.second, &.{"q"}, "b", 2, 100);
    defer freeClaimed(testing.allocator, second);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expect(!std.mem.eql(u8, first[0].id, second[0].id));
}

test "pg concurrent rated claimers share one database rate ceiling" {
    if (!@import("build_options").postgres) return error.SkipZigTest;
    var env = try PgQueueTest.init();
    defer env.deinit();
    for (0..10) |_| _ = try enqueue(&env.first, testing.io, .{ .name = "q", .backend = .durable }, "k", "{}", 0);
    const Runner = struct {
        conn: *db.Db,
        start: *std.atomic.Value(bool),
        claimed: []Claimed = &.{},
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.claimed = claimRateLimited(testing.allocator, self.conn, "q", "worker", 3, 10, 100) catch |e| {
                self.err = e;
                return;
            };
        }
    };
    var start = std.atomic.Value(bool).init(false);
    var one = Runner{ .conn = &env.first, .start = &start };
    var two = Runner{ .conn = &env.second, .start = &start };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&one});
    start.store(true, .release);
    two.run();
    thread.join();
    defer freeClaimed(testing.allocator, one.claimed);
    defer freeClaimed(testing.allocator, two.claimed);
    if (one.err) |e| return e;
    if (two.err) |e| return e;
    try testing.expectEqual(@as(usize, 3), one.claimed.len + two.claimed.len);
    try testing.expectEqual(@as(i64, 3), try countStatus(&env.first, "claimed"));
}

test "pg durable reclaim, fenced completion, cancellation and GC use backend-correct SQL" {
    if (!@import("build_options").postgres) return error.SkipZigTest;
    var env = try PgQueueTest.init();
    defer env.deinit();
    const q = QueueDef{ .name = "q", .backend = .durable };
    _ = try enqueue(&env.first, testing.io, q, "k", "{}", 0);
    const first = try claimBatch(testing.allocator, &env.first, &.{"q"}, "a", 1, 100);
    defer freeClaimed(testing.allocator, first);
    try testing.expectEqual(@as(usize, 1), try reclaimStale(&env.second, "q", 101, 1));
    const second = try claimBatch(testing.allocator, &env.second, &.{"q"}, "b", 1, 101);
    defer freeClaimed(testing.allocator, second);
    try testing.expect(!try finishClaim(&env.first, first[0], .done, 0, 101, ""));
    try testing.expect(try finishClaim(&env.second, second[0], .retry, 1, 102, "retry"));
    const third = try claimBatch(testing.allocator, &env.first, &.{"q"}, "a", 1, 102);
    defer freeClaimed(testing.allocator, third);
    try testing.expect(try finishClaim(&env.first, third[0], .failed, 2, 102, "failed"));
    const canceled = try enqueue(&env.second, testing.io, q, "k", "{}", 0);
    try testing.expect(try cancelJob(&env.second, &canceled));
    try testing.expect(!try cancelJob(&env.second, &canceled));
    _ = try enqueue(&env.first, testing.io, q, "k", "{}", 0);
    const late = try claimBatch(testing.allocator, &env.first, &.{"q"}, "a", 1, 103);
    defer freeClaimed(testing.allocator, late);
    _ = try reclaimStale(&env.second, "q", 104, 1);
    try testing.expect(try finishClaim(&env.first, late[0], .done, 0, 104, ""));
    const cancel_late = try enqueue(&env.first, testing.io, q, "k", "{}", 0);
    const interrupted = try claimBatch(testing.allocator, &env.first, &.{"q"}, "a", 1, 105);
    defer freeClaimed(testing.allocator, interrupted);
    _ = try reclaimStale(&env.second, "q", 106, 1);
    try testing.expect(try cancelJob(&env.second, &cancel_late));
    try testing.expect(!try finishClaim(&env.first, interrupted[0], .retry, 1, 107, ""));
    try testing.expectEqual(@as(usize, 4), try gcDoneJobs(&env.first, "q", 0));
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

test "durable fenced retry and failure update attempts and state" {
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

    const first = try claimBatch(testing.allocator, &d, &.{"default"}, "w", 1, clock.nowUnix(io));
    defer freeClaimed(testing.allocator, first);
    try testing.expect(try finishClaim(&d, first[0], .retry, 1, 12345, "boom"));
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
    const second = try claimBatch(testing.allocator, &d, &.{"default"}, "w", 1, 12345);
    defer freeClaimed(testing.allocator, second);
    try testing.expect(try finishClaim(&d, second[0], .failed, 5, 12345, "dead"));
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
    const a = testing.allocator;
    // Before due: nothing claimable. At/after due: claimed.
    const before = try claimBatch(a, &d, &.{"default"}, "w", 10, 1_999_999);
    defer freeClaimed(a, before);
    try testing.expectEqual(@as(usize, 0), before.len);
    const after = try claimBatch(a, &d, &.{"default"}, "w", 10, 2_000_000);
    defer freeClaimed(a, after);
    try testing.expectEqual(@as(usize, 1), after.len);
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
    const a = testing.allocator;
    const claimed = try claimBatch(a, &d, &.{"default"}, "w", 10, clock.nowUnix(io) + 7200);
    defer freeClaimed(a, claimed);
    try testing.expectEqual(@as(usize, 0), claimed.len);
}

test "gcDoneJobs reaps old canceled rows" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('c1','q','k',5,'canceled',datetime('now','-400 days'));");
    try d.exec("INSERT INTO \"_queue_jobs\" (\"id\",\"queue\",\"kind\",\"max_attempts\",\"status\",\"created\") VALUES ('c2','q','k',5,'canceled',datetime('now'));");
    try testing.expectEqual(@as(usize, 1), try gcDoneJobs(&d, "q", 30 * 24 * 3600)); // old canceled reaped, fresh kept
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
