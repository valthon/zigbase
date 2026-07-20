//! Non-blocking error-report delivery (#244 stage 2). `events.dispatchError` no longer
//! calls `app.reporter.report(...)` inline on the erroring thread — a `SentryReporter` does
//! a synchronous HTTPS POST, which would BLOCK whatever thread just swallowed an error
//! (an HTTP worker, the scheduler, a queue worker). Instead it enqueues a `"report"` job on
//! the MEMORY queue; this handler runs on a pool worker and performs the actual POST there.
//!
//! ## Always memory, best-effort
//! Delivery always uses the in-process memory backend regardless of the app's declared
//! queues: it must never touch the DB writer (an error report during a write must not
//! contend for the single writer) and never block. With no memory pool installed
//! (unit tests / CLI), `queue_memory.enqueue` runs the handler INLINE, synchronously —
//! deterministic for tests. Reporting is best-effort: a full ring or a serialize failure
//! is logged and dropped, never retried into oblivion and never surfaced to a caller.
//!
//! ## INFINITE-LOOP GUARD (critical)
//! A `"report"` job that FAILED terminally would route through the memory queue's
//! `runWithRetry` → `dispatchError(phase = .job)` → which would enqueue ANOTHER `"report"`
//! job → an unbounded thread/stack storm. The guard: **`jobHandler` NEVER returns an
//! error.** It swallows every failure (bad payload, delivery error, missing reporter) into
//! a single `std.log.warn`. Because the handler always reports success to `runWithRetry`,
//! the queue never invokes `dispatchError` for a report job, so the recursion can never
//! start. (This also means report delivery is single-attempt — intentional: retrying an
//! error report risks amplifying a backend outage, and the report is best-effort anyway.)

const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const reporter = @import("reporter.zig");
const report_log = @import("log.zig");
const App = @import("../app.zig").App;
const Ctx = @import("../ctx.zig").Ctx;
const queue = @import("../queue/queue.zig");
const queue_memory = @import("../queue/memory.zig");

const Report = reporter.Report;

/// Reserved job kind for queued error-report delivery. Registered UNCONDITIONALLY in
/// `framework.zig` (a reporter is always wired) and reserved so a consumer `.jobs` entry
/// can never collide with it.
pub const job_kind = "report";

/// The always-memory, single-attempt queue definition report delivery rides on. Not a
/// declared queue — reports bypass the registry so they can never land on a durable
/// (DB-writer) backend. `max_attempts = 1`: the handler swallows failures anyway (see the
/// loop guard), so a retry policy would be dead config.
const report_queue_def = queue.QueueDef{
    .name = "__report",
    .backend = .memory,
    .retry = .{ .max_attempts = 1, .base_ms = 0, .jitter = false },
};

/// Enqueue `r` for non-blocking delivery on the memory queue. Serializes the `Report` to
/// JSON (owned by `queue_memory.enqueue`, which dupes it), then returns immediately (or, with
/// no pool, runs the handler inline). Best-effort: a serialize/enqueue failure is logged and
/// the report dropped — this is the terminal error backstop, so it must not itself throw.
pub fn enqueueReport(app: *App, r: Report) void {
    const payload = std.json.Stringify.valueAlloc(app.allocator, r, .{}) catch |e| {
        std.log.warn("error report: failed to serialize report ({s}); dropping", .{@errorName(e)});
        return;
    };
    defer app.allocator.free(payload);
    queue_memory.enqueue(app, report_queue_def, jobHandler, payload) catch |e| {
        // error.QueueFull (overloaded) or OOM — drop the report (bounded, best-effort).
        std.log.warn("error report: enqueue failed ({s}); dropping", .{@errorName(e)});
    };
}

/// Built-in `"report"` job handler: deserialize the `Report` payload and deliver it through
/// `app.reporter` on THIS (worker) thread, so the blocking POST happens off the erroring
/// thread. NEVER returns an error — see the module doc's loop guard. All failure paths log
/// and complete so the queue treats the job as done and never re-reports.
pub fn jobHandler(ctx: *Ctx, payload: []const u8) anyerror!void {
    deliver(ctx, payload) catch |e| {
        // GUARD: swallow + log. Propagating here would route to dispatchError(phase=.job)
        // → enqueue another "report" job → infinite loop. Best-effort delivery ends here.
        std.log.warn("error report delivery failed: {s}", .{@errorName(e)});
    };
}

/// The fallible core: parse the payload and POST via the reporter. Its errors are caught
/// (and only logged) by `jobHandler` — they never reach the queue's failure path.
fn deliver(ctx: *Ctx, payload: []const u8) !void {
    const parsed = try std.json.parseFromSlice(Report, ctx.arena.a, payload, .{ .ignore_unknown_fields = true });
    const rep = ctx.app.reporter orelse {
        // No reporter wired (un-booted app) — fall back to the log backstop.
        report_log.emit(parsed.value);
        return;
    };
    try rep.report(ctx.app.io, ctx.arena.a, parsed.value);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const testcapture = @import("../testcapture.zig");
const report_sentry = @import("sentry.zig");

const test_dsn = "https://pub@o1.ingest.sentry.io/42";

const JobEnv = struct {
    arena: std.heap.ArenaAllocator,
    app: App,

    fn init() JobEnv {
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .app = App{ .allocator = testing.allocator, .io = testing.io, .pool = undefined },
        };
    }
    fn ctx(self: *JobEnv) Ctx {
        return Ctx{ .app = &self.app, .arena = RequestArena.from(&self.arena), .rctx = .{}, .request = null, .bound_conn = null };
    }
    fn deinit(self: *JobEnv) void {
        self.arena.deinit();
    }
};

test "report jobHandler: malformed payload is swallowed (no throw, no retry)" {
    // Loop-guard property at the unit level: a bad payload must NOT propagate (that would
    // route to dispatchError(.job) and recurse). No reporter needed.
    report_log.log_sink = struct {
        fn s(_: []const u8) void {}
    }.s;
    defer report_log.log_sink = null;
    var env = JobEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    try jobHandler(&cx, "{ not json"); // returns ok despite the parse error
}

test "report jobHandler: no reporter wired falls back to the log backstop (no throw)" {
    const Sink = struct {
        var got: usize = 0;
        fn s(_: []const u8) void {
            got += 1;
        }
    };
    Sink.got = 0;
    report_log.log_sink = Sink.s;
    defer report_log.log_sink = null;

    var env = JobEnv.init();
    defer env.deinit();
    env.app.reporter = null; // un-booted app
    var cx = env.ctx();
    const payload = try std.json.Stringify.valueAlloc(env.arena.allocator(), Report{ .message = "boom", .err_name = "error.Boom", .phase = "request" }, .{});
    try jobHandler(&cx, payload);
    try testing.expectEqual(@as(usize, 1), Sink.got); // logged via the backstop
}

test "enqueueReport (no pool) delivers inline and POSTs the Sentry envelope" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("ingest.sentry.io", .{ .status = 200 });

    // A SentryReporter wired onto the app; NO memory pool → enqueue runs the report job
    // INLINE (deterministic), so the POST happens before enqueueReport returns.
    var sr = try report_sentry.SentryReporter.create(testing.allocator, testing.io, .{ .sentry_dsn = test_dsn });
    defer sr.deinit();
    var iface = sr.interface();
    var env = JobEnv.init();
    defer env.deinit();
    env.app.reporter = &iface;

    enqueueReport(&env.app, .{ .message = "kaboom", .err_name = "error.Boom", .phase = "request" });
    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());
    try testing.expect(std.mem.indexOf(u8, testcapture.http.requestAt(0).?.url, "/envelope/") != null);
}

test "LOOP GUARD: a FAILING report delivery does not recurse — exactly one attempt" {
    // The critical correctness test (#244 stage 2 §B). With `block_unmocked = true` and no
    // mock for the Sentry URL, the POST fails (error.TransportFailed). The report job
    // handler MUST swallow that failure — if it propagated, the memory queue's runWithRetry
    // would route it to dispatchError(phase=.job), which would enqueue ANOTHER report job,
    // and so on forever. We assert exactly ONE POST attempt was made and the call returned
    // (a runaway would blow the stack / spin, never reaching the assertion).
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true); // block unmocked → the Sentry POST fails

    var sr = try report_sentry.SentryReporter.create(testing.allocator, testing.io, .{ .sentry_dsn = test_dsn });
    defer sr.deinit();
    var iface = sr.interface();
    var env = JobEnv.init();
    defer env.deinit();
    env.app.reporter = &iface;

    enqueueReport(&env.app, .{ .message = "loopy", .err_name = "error.Boom", .phase = "request" });
    // Exactly one attempt — the failed delivery was swallowed, not re-reported.
    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());
}
