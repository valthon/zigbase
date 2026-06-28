//! Memory queue backend (#137 PR2): jobs run in-process on a detached background
//! thread with in-process backoff retry. AT-MOST-ONCE across restart — an enqueued
//! memory job lives only in RAM, so a crash (or a shutdown before the detached thread
//! runs) drops it. Use a `durable` queue when a job MUST survive a restart. This
//! mirrors `App.submit`'s detached-thread model (the thread is not joined at
//! shutdown), and is the default backend so a queue "just works" with zero schema.

const std = @import("std");
const queue = @import("queue.zig");
const events = @import("../events.zig");
const App = @import("../app.zig").App;
const Ctx = @import("../ctx.zig").Ctx;
const entropy = @import("../entropy.zig");

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

const Job = struct {
    app: *App,
    handler: queue.JobHandler,
    policy: RetryPolicy,
    payload: []u8, // owned (app.allocator)

    fn run(self: *Job) void {
        defer {
            self.app.allocator.free(self.payload);
            self.app.allocator.destroy(self);
        }
        _ = runWithRetry(self.app, self.handler, self.payload, self.policy);
    }
};

/// Enqueue a memory job: copy `payload` and run it on a DETACHED background thread with
/// retry. Returns once the thread is spawned (never blocks the caller on the handler).
/// At-most-once: the job is lost on crash/shutdown before it completes.
pub fn enqueue(app: *App, def: QueueDef, handler: queue.JobHandler, payload: []const u8) !void {
    const job = try app.allocator.create(Job);
    errdefer app.allocator.destroy(job);
    job.* = .{
        .app = app,
        .handler = handler,
        .policy = def.retry,
        .payload = try app.allocator.dupe(u8, payload),
    };
    errdefer app.allocator.free(job.payload);
    const th = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, Job.run, .{job});
    th.detach();
}

fn randomU64(io: std.Io) u64 {
    var b: [8]u8 = undefined;
    entropy.fill(io, &b);
    return std.mem.readInt(u64, &b, .little);
}

// ---------------------------------------------------------------------------
// Tests — exercise the synchronous core (`runWithRetry`); the detached-thread
// `enqueue` is covered end-to-end via ctx.enqueue in ctx.zig.
// ---------------------------------------------------------------------------

const testing = std.testing;
const db = @import("../db.zig");
const sentry = @import("../sentry.zig");

fn noopSink(_: []const u8) void {}

var m_runs: usize = 0;
var m_fail_until: usize = 0;
var m_err: usize = 0;
var m_last_payload: []const u8 = "";

fn okH(ctx: *Ctx, payload: []const u8) anyerror!void {
    _ = ctx;
    m_runs += 1;
    m_last_payload = payload;
}
fn flakyH(ctx: *Ctx, payload: []const u8) anyerror!void {
    _ = ctx;
    _ = payload;
    m_runs += 1;
    if (m_runs <= m_fail_until) return error.Flaky;
}
fn onErrM(ev: *events.ErrorEvent) void {
    _ = ev;
    m_err += 1;
}

fn testApp() App {
    return App{ .allocator = testing.allocator, .io = testing.io, .pool = undefined };
}

test "memory runWithRetry succeeds on first attempt" {
    m_runs = 0;
    var app = testApp();
    const out = runWithRetry(&app, okH, "{}", .{ .max_attempts = 3, .base_ms = 0, .jitter = false });
    try testing.expectEqual(Outcome.done, out);
    try testing.expectEqual(@as(usize, 1), m_runs);
}

test "memory runWithRetry retries then succeeds" {
    m_runs = 0;
    m_fail_until = 2; // first two attempts fail, third succeeds
    var app = testApp();
    const out = runWithRetry(&app, flakyH, "{}", .{ .max_attempts = 5, .base_ms = 0, .jitter = false });
    try testing.expectEqual(Outcome.done, out);
    try testing.expectEqual(@as(usize, 3), m_runs);
}

test "memory runWithRetry exhausts attempts -> failed + onError" {
    m_runs = 0;
    m_err = 0;
    m_fail_until = 100; // always fail
    sentry.log_sink = noopSink; // swallow the intentional terminal-failure log
    defer sentry.log_sink = null;
    var app = testApp();
    var dispatch = events.Dispatch{ .on_error = onErrM };
    app.dispatch = &dispatch;
    const out = runWithRetry(&app, flakyH, "{}", .{ .max_attempts = 3, .base_ms = 0, .jitter = false });
    try testing.expectEqual(Outcome.failed, out);
    try testing.expectEqual(@as(usize, 3), m_runs);
    try testing.expectEqual(@as(usize, 1), m_err);
}
