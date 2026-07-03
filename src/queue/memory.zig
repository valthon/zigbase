//! Memory queue backend (#137 PR2; bounded pool since 0.10.0): jobs run in-process on a
//! small shared worker pool (spawned lazily on first use, DRAINED AND JOINED at shutdown)
//! with in-process backoff retry. AT-MOST-ONCE across restart — an enqueued memory job
//! lives only in RAM, so a crash drops it. The ring is bounded: when it is full, enqueue
//! returns error.QueueFull instead of blocking (a blocking policy could deadlock when a
//! handler enqueues from a pool worker) or spawning unbounded threads. `Pool.submitThunk`
//! also carries `app.submit` tasks on this same pool — `install()` wires it onto
//! `app.submit_fn`, and `App.submit` passes `self.memory_pool.?` (both landed together in
//! Task 4 so they can never be observed out of sync). A retrying job holds one worker for
//! the whole backoff — size retry policies accordingly; use a `durable` queue when a job
//! MUST survive a restart or for sustained high-volume work. Without an installed pool
//! (unit tests / CLI helpers) enqueue runs the job INLINE, synchronously — deterministic
//! for tests, and no code path spawns detached threads anymore.

const std = @import("std");
const queue = @import("queue.zig");
const events = @import("../events.zig");
const App = @import("../app.zig").App;
const Ctx = @import("../ctx.zig").Ctx;
const entropy = @import("../entropy.zig");
const scheduler_mod = @import("../scheduler.zig");

const QueueDef = queue.QueueDef;
const RetryPolicy = queue.RetryPolicy;

/// Outcome of a memory job's full attempt sequence.
pub const Outcome = enum { done, failed };

/// Run `handler(payload)` synchronously with in-process backoff retry up to
/// `policy.max_attempts`. Each attempt gets a fresh per-attempt arena + Ctx (no HTTP
/// request, anonymous identity — like a scheduler job). On the final failure the error
/// is reported via `.onError` (phase `.job`) and `.failed` is returned. Between attempts
/// it sleeps `backoffMs` (honoring the dev clock via `io.sleep`).
pub fn runWithRetry(app: *App, handler: queue.JobHandler, payload: []const u8, policy: RetryPolicy) Outcome {
    var attempt: u32 = 1;
    const max: u32 = if (policy.max_attempts == 0) 1 else policy.max_attempts;
    while (true) : (attempt += 1) {
        var arena = std.heap.ArenaAllocator.init(app.allocator);
        defer arena.deinit();
        var cx = Ctx{ .app = app, .arena = arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
        defer cx.deinit();
        if (handler(&cx, payload)) |_| {
            return .done;
        } else |e| {
            if (attempt >= max) {
                var err_ev = events.ErrorEvent{ .app = app, .ctx = null, .err = e, .phase = .job, .message = @errorName(e) };
                events.dispatchError(app, app.dispatch, &err_ev);
                return .failed;
            }
            const ms = queue.backoffMs(policy, attempt, randomU64(app.io));
            if (ms > 0) app.io.sleep(std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
        }
    }
}

/// One queued unit of pool work: a memory-queue job or an `app.submit` task. Heap-allocated
/// with app.allocator; owns its payload/name copies; freed by the worker after running.
const Task = struct {
    app: *App,
    kind: Kind,

    const Kind = union(enum) {
        job: struct { handler: queue.JobHandler, policy: RetryPolicy, payload: []u8 },
        submit: struct { name: []u8, task: events.JobTask },
    };

    fn run(self: *Task) void {
        defer self.destroy();
        switch (self.kind) {
            .job => |j| _ = runWithRetry(self.app, j.handler, j.payload, j.policy),
            .submit => |s| {
                var ev = events.JobEvent{ .app = self.app, .name = s.name };
                // Arena declared before cx so its deinit runs last (LIFO): cx.deinit only
                // releases a pooled reader; the arena owns ctx.records() results.
                var arena = std.heap.ArenaAllocator.init(self.app.allocator);
                defer arena.deinit();
                var cx = Ctx{ .app = self.app, .arena = arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
                defer cx.deinit();
                s.task(&cx, &ev) catch |e| {
                    var err_ev = events.ErrorEvent{ .app = self.app, .ctx = null, .err = e, .phase = .job, .message = @errorName(e) };
                    events.dispatchError(self.app, self.app.dispatch, &err_ev);
                };
            },
        }
    }

    fn destroy(self: *Task) void {
        const a = self.app.allocator;
        switch (self.kind) {
            .job => |j| a.free(j.payload),
            .submit => |s| a.free(s.name),
        }
        a.destroy(self);
    }
};

/// Bounded worker pool for memory-backend jobs + `app.submit` tasks. Reuses the
/// Scheduler's spinlock-ring pattern (scheduler.zig): all ring/started mutation under
/// `mutex`; workers poll the ring (20 ms idle sleep, matching the scheduler's cadence).
/// Threads spawn LAZILY on the first push (zero overhead when unused) and `stop()`
/// drains the ring and joins every worker (tasks queued before shutdown complete;
/// pushes after shutdown are rejected).
pub const Pool = struct {
    /// Ring capacity. Overflow returns error.QueueFull — reject-not-block, because a
    /// handler may enqueue from a pool worker (block-on-full would self-deadlock).
    pub const capacity = 256;
    /// Fixed worker count. Matches facil.io's 4 HTTP threads: a burst drains 4-wide
    /// without reserving idle threads for the common no-queue deployment (lazy spawn).
    pub const num_workers = 4;

    app: *App,
    ring: [capacity]*Task = undefined,
    head: usize = 0,
    len: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,
    started: bool = false, // guarded by mutex
    nworkers: usize = 0, // actually-spawned workers (== num_workers unless spawn failed)
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    workers: [num_workers]std.Thread = undefined,

    pub fn init(app: *App) Pool {
        return .{ .app = app };
    }

    /// Route this app's memory-queue jobs AND `app.submit` tasks through this pool. Call
    /// once, before serving; pair with `stop()` at shutdown. Sets both `app.memory_pool`
    /// (what `App.submit` dereferences as `self.memory_pool.?`) and `app.submit_fn`
    /// (`&submitThunk`) together, atomically from the caller's perspective — there is no
    /// window where one is set without the other, so `App.submit` never hands `submitThunk`
    /// a stale or mismatched pointer.
    pub fn install(self: *Pool, app: *App) void {
        app.memory_pool = self;
        app.submit_fn = &submitThunk;
    }

    /// Reject new pushes, let the workers DRAIN the remaining ring, join them, and
    /// uninstall from the app. Idempotent; safe when no worker was ever spawned. After this
    /// returns, `app.memory_pool` and `app.submit_fn` are null again, so any subsequent
    /// `enqueue(app, ...)` call falls back to running the job INLINE, synchronously (the
    /// same path unit tests/CLI use when no pool was ever installed) rather than being
    /// silently dropped, and `app.submit(...)` returns `error.SchedulerUnavailable`.
    pub fn stop(self: *Pool) void {
        self.shutdown.store(true, .release);
        self.lockPool();
        const n = if (self.started) self.nworkers else 0;
        self.started = false;
        self.unlockPool();
        for (self.workers[0..n]) |t| t.join();
        if (self.app.memory_pool == @as(?*anyopaque, @ptrCast(self))) {
            self.app.memory_pool = null;
            self.app.submit_fn = null;
        }
        // Final safety drain — NOT for a failed spawn (a spawn that returns 0 workers never
        // reaches `started = true`, so nothing is pushed against it). The real race this
        // guards: `push()` re-checks `shutdown` under the lock, so a caller can win that
        // lock in the narrow window between our `shutdown.store` becoming visible and our
        // taking the lock above, observe `shutdown == false`, and push a task AFTER we've
        // already snapshotted `n`/joined (or are about to join) every worker. No worker is
        // left polling to dequeue that task, so it would strand in the ring forever. This
        // second lock+drain after the join catches and frees any such straggler.
        self.lockPool();
        while (self.dequeue()) |t| t.destroy();
        self.unlockPool();
    }

    fn lockPool(self: *Pool) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlockPool(self: *Pool) void {
        self.mutex.unlock();
    }

    fn dequeue(self: *Pool) ?*Task { // caller holds lock
        if (self.len == 0) return null;
        const t = self.ring[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return t;
    }

    /// Queue `task` (ownership transfers on success). Lazily spawns the workers on the
    /// first push. error.QueueFull when the ring is full; error.ShuttingDown after stop().
    fn push(self: *Pool, task: *Task) !void {
        self.lockPool();
        errdefer self.unlockPool();
        if (self.shutdown.load(.acquire)) return error.ShuttingDown;
        if (!self.started) {
            // One-time spawn under the spinlock: slow (a few syscalls) but happens once.
            // 1 MiB stacks — same rationale + floor as the scheduler's threads.
            var spawned: usize = 0;
            for (self.workers[0..num_workers]) |*t| {
                t.* = std.Thread.spawn(
                    .{ .stack_size = scheduler_mod.min_job_stack_size },
                    workerLoop,
                    .{self},
                ) catch break;
                spawned += 1;
            }
            if (spawned == 0) return error.SystemResources;
            self.nworkers = spawned;
            self.started = true;
        }
        if (self.len == capacity) return error.QueueFull;
        self.ring[(self.head + self.len) % capacity] = task;
        self.len += 1;
        self.unlockPool();
    }

    fn workerLoop(self: *Pool) void {
        while (true) {
            self.lockPool();
            const maybe = self.dequeue();
            self.unlockPool();
            const task = maybe orelse {
                // Empty ring: exit ONLY on shutdown — this is what makes stop() a drain.
                if (self.shutdown.load(.acquire)) return;
                self.app.io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};
                continue;
            };
            task.run();
        }
    }

    /// `app.submit` entry point — matches `app.submit_fn`'s signature; `install()` wires it
    /// on. Copies `name` (the caller's slice may be request-arena-backed and dead before
    /// the task runs — the old detached-thread code captured it unsafely).
    pub fn submitThunk(ptr: *anyopaque, name: []const u8, task: events.JobTask) anyerror!void {
        const self: *Pool = @ptrCast(@alignCast(ptr));
        const t = try self.app.allocator.create(Task);
        errdefer self.app.allocator.destroy(t);
        const name_copy = try self.app.allocator.dupe(u8, name);
        errdefer self.app.allocator.free(name_copy);
        t.* = .{ .app = self.app, .kind = .{ .submit = .{ .name = name_copy, .task = task } } };
        try self.push(t);
    }
};

fn poolFrom(app: *App) ?*Pool {
    return @ptrCast(@alignCast(app.memory_pool orelse return null));
}

/// Enqueue a memory job. With an installed Pool (serving): copy `payload`, queue it on the
/// bounded worker ring, return immediately (error.QueueFull when the ring is full — reject,
/// never block). Without a pool (unit tests / CLI helpers): run the job INLINE, synchronously.
/// At-most-once across restart either way.
pub fn enqueue(app: *App, def: QueueDef, handler: queue.JobHandler, payload: []const u8) !void {
    if (poolFrom(app)) |p| {
        const t = try app.allocator.create(Task);
        errdefer app.allocator.destroy(t);
        const pcopy = try app.allocator.dupe(u8, payload);
        errdefer app.allocator.free(pcopy);
        t.* = .{ .app = app, .kind = .{ .job = .{ .handler = handler, .policy = def.retry, .payload = pcopy } } };
        return p.push(t);
    }
    _ = runWithRetry(app, handler, payload, def.retry);
}

fn randomU64(io: std.Io) u64 {
    var b: [8]u8 = undefined;
    entropy.fill(io, &b);
    return std.mem.readInt(u64, &b, .little);
}

// ---------------------------------------------------------------------------
// Tests — exercise the synchronous core (`runWithRetry`), the inline no-pool
// `enqueue` fallback, and the bounded worker `Pool` (push/drain/overflow/submit).
// ---------------------------------------------------------------------------

const testing = std.testing;
const db = @import("../db.zig");
const sentry = @import("../sentry.zig");

fn noopSink(_: []const u8) void {}

// `m_runs` is incremented by `okH`/`flakyH`, which the pool tests below run concurrently
// from up to `Pool.num_workers` worker threads — a plain `usize` here flaked (non-atomic
// RMW lost updates) 2/9 local suite runs. Use an atomic counter with `.monotonic`
// ordering (we only need a correct final count after `pool.stop()` joins every worker,
// not any inter-thread visibility of intermediate values).
var m_runs: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
// `m_fail_until`/`m_err` are only touched by the single-threaded, non-pool
// `runWithRetry` tests (no concurrent workers), so plain counters are fine.
var m_fail_until: usize = 0;
var m_err: usize = 0;

fn okH(ctx: *Ctx, payload: []const u8) anyerror!void {
    _ = ctx;
    _ = payload;
    _ = m_runs.fetchAdd(1, .monotonic);
}
fn flakyH(ctx: *Ctx, payload: []const u8) anyerror!void {
    _ = ctx;
    _ = payload;
    const n = m_runs.fetchAdd(1, .monotonic) + 1;
    if (n <= m_fail_until) return error.Flaky;
}
fn onErrM(ev: *events.ErrorEvent) void {
    _ = ev;
    m_err += 1;
}

fn testApp() App {
    return App{ .allocator = testing.allocator, .io = testing.io, .pool = undefined };
}

test "memory runWithRetry succeeds on first attempt" {
    m_runs.store(0, .monotonic);
    var app = testApp();
    const out = runWithRetry(&app, okH, "{}", .{ .max_attempts = 3, .base_ms = 0, .jitter = false });
    try testing.expectEqual(Outcome.done, out);
    try testing.expectEqual(@as(usize, 1), m_runs.load(.monotonic));
}

test "memory runWithRetry retries then succeeds" {
    m_runs.store(0, .monotonic);
    m_fail_until = 2; // first two attempts fail, third succeeds
    var app = testApp();
    const out = runWithRetry(&app, flakyH, "{}", .{ .max_attempts = 5, .base_ms = 0, .jitter = false });
    try testing.expectEqual(Outcome.done, out);
    try testing.expectEqual(@as(usize, 3), m_runs.load(.monotonic));
}

test "memory runWithRetry exhausts attempts -> failed + onError" {
    m_runs.store(0, .monotonic);
    m_err = 0;
    m_fail_until = 100; // always fail
    sentry.log_sink = noopSink; // swallow the intentional terminal-failure log
    defer sentry.log_sink = null;
    var app = testApp();
    var dispatch = events.Dispatch{ .on_error = onErrM };
    app.dispatch = &dispatch;
    const out = runWithRetry(&app, flakyH, "{}", .{ .max_attempts = 3, .base_ms = 0, .jitter = false });
    try testing.expectEqual(Outcome.failed, out);
    try testing.expectEqual(@as(usize, 3), m_runs.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), m_err);
}

var g_gate = std.atomic.Value(bool).init(false);
var g_blocked = std.atomic.Value(usize).init(0);

fn blockingH(ctx: *Ctx, payload: []const u8) anyerror!void {
    _ = payload;
    _ = g_blocked.fetchAdd(1, .monotonic);
    while (!g_gate.load(.acquire)) {
        ctx.app.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
}

test "pool runs enqueued jobs and stop() drains the ring + joins the workers" {
    m_runs.store(0, .monotonic);
    var app = testApp();
    var pool = Pool.init(&app);
    pool.install(&app);
    const def = QueueDef{ .name = "default", .backend = .memory, .retry = .{ .base_ms = 0, .jitter = false } };
    for (0..8) |_| try enqueue(&app, def, okH, "{}");
    pool.stop(); // drains + joins => deterministic, no spin-wait needed
    try testing.expectEqual(@as(usize, 8), m_runs.load(.monotonic));
    try testing.expect(app.memory_pool == null); // uninstalled
}

test "pool overflow: full ring rejects with error.QueueFull (burst does not spawn threads per job)" {
    m_runs.store(0, .monotonic);
    g_gate.store(false, .monotonic);
    g_blocked.store(0, .monotonic);
    var app = testApp();
    var pool = Pool.init(&app);
    pool.install(&app);
    const def = QueueDef{ .name = "default", .backend = .memory, .retry = .{ .max_attempts = 1, .base_ms = 0, .jitter = false } };
    // Occupy every worker with a gated job, deterministically.
    for (0..Pool.num_workers) |_| try enqueue(&app, def, blockingH, "{}");
    var spins: usize = 0;
    while (g_blocked.load(.acquire) < Pool.num_workers and spins < 2000) : (spins += 1) {
        app.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expectEqual(@as(usize, Pool.num_workers), g_blocked.load(.acquire));
    // Fill the ring exactly, then one more must be rejected — bounded, not thread-per-enqueue.
    for (0..Pool.capacity) |_| try enqueue(&app, def, okH, "{}");
    try testing.expectError(error.QueueFull, enqueue(&app, def, okH, "{}"));
    g_gate.store(true, .release);
    pool.stop(); // drain: all capacity fillers run
    try testing.expectEqual(@as(usize, Pool.capacity), m_runs.load(.monotonic));
}

test "submitThunk routes app.submit tasks through the pool (name copied, joined at stop)" {
    const S = struct {
        var ran = std.atomic.Value(bool).init(false);
        fn task(cx: *Ctx, ev: *events.JobEvent) anyerror!void {
            _ = cx;
            try testing.expectEqualStrings("reindex", ev.name);
            ran.store(true, .release);
        }
    };
    S.ran.store(false, .monotonic);
    var app = testApp();
    var pool = Pool.init(&app);
    pool.install(&app);
    // Pass an EPHEMERAL name buffer to prove submitThunk copies it.
    var name_buf: [7]u8 = undefined;
    @memcpy(&name_buf, "reindex");
    try Pool.submitThunk(@ptrCast(&pool), name_buf[0..], S.task);
    @memset(&name_buf, 'X');
    pool.stop();
    try testing.expect(S.ran.load(.acquire));
}

test "enqueue with no installed pool runs inline (unit-test/CLI fallback)" {
    m_runs.store(0, .monotonic);
    var app = testApp();
    const def = QueueDef{ .name = "default", .backend = .memory, .retry = .{ .base_ms = 0, .jitter = false } };
    try enqueue(&app, def, okH, "{}");
    try testing.expectEqual(@as(usize, 1), m_runs.load(.monotonic)); // ran synchronously, no thread
}

/// State for the worker-context-enqueue test: a job running ON a pool worker calls
/// `enqueue` again (into the same pool), records whether it returned `ok`/`error.QueueFull`
/// via `outer_result`, then signals `outer_done` — the test thread waits on that latch
/// (no sleep-as-sync) before asserting.
var outer_done = std.atomic.Value(bool).init(false);
var outer_result: WorkerEnqueueResult = .not_run;
const WorkerEnqueueResult = enum { not_run, ok, queue_full, other_error };

fn innerH(ctx: *Ctx, payload: []const u8) anyerror!void {
    _ = ctx;
    _ = payload;
}

/// Runs ON a pool worker: enqueues `innerH` back into the SAME app/pool and records
/// whether that inner `enqueue` call returned promptly rather than blocking.
fn outerH(ctx: *Ctx, payload: []const u8) anyerror!void {
    _ = payload;
    const def = QueueDef{ .name = "default", .backend = .memory, .retry = .{ .base_ms = 0, .jitter = false } };
    if (enqueue(ctx.app, def, innerH, "{}")) |_| {
        outer_result = .ok;
    } else |e| {
        outer_result = if (e == error.QueueFull) .queue_full else .other_error;
    }
    outer_done.store(true, .release);
}

test "enqueue from INSIDE a pool worker returns promptly (reject-not-block, no self-deadlock)" {
    outer_done.store(false, .monotonic);
    outer_result = .not_run;
    var app = testApp();
    var pool = Pool.init(&app);
    pool.install(&app);
    const def = QueueDef{ .name = "default", .backend = .memory, .retry = .{ .base_ms = 0, .jitter = false } };
    try enqueue(&app, def, outerH, "{}");
    // Wait on the latch outerH sets — deterministic, not a fixed sleep race. A bounded
    // spin cap guards against hanging the suite if the reject-not-block property regresses
    // (a self-deadlock would never set outer_done).
    var spins: usize = 0;
    while (!outer_done.load(.acquire) and spins < 5000) : (spins += 1) {
        app.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(outer_done.load(.acquire)); // did not self-deadlock
    try testing.expect(outer_result == .ok or outer_result == .queue_full); // rejected, not blocked
    pool.stop();
}
