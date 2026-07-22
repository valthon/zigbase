//! `ctx.push()` — the consumer-facing Web Push API (#223), mirroring `ctx.mail()` /
//! `ctx.webhook()`:
//!   * `send(sub, msg)`  — synchronous; returns the tri-state so the caller PRUNES its stored
//!                         subscription on `.gone`. This is the ONLY path that surfaces `.gone`
//!                         (a queued job can't reach back into the caller's DB row).
//!   * `enqueue(sub, msg, .{…})` — durable/background delivery via the built-in `"push"` job
//!                         kind; the handler re-delivers and, on `.gone`, simply STOPS retrying
//!                         a dead endpoint (it cannot prune the caller's row).
//!
//! The `"push"` job handler is registered onto the queue registry in `framework.zig` behind
//! the `enable_push_job` gate (only when `.push` is configured). Delivery never throws into
//! the triggering request: a dead/failing push is the tri-state, not an error.

const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const sender = @import("sender.zig");
const capture = @import("capture.zig");
const Ctx = @import("../ctx.zig").Ctx;

/// The reserved job kind under which durable push deliveries are enqueued.
pub const job_kind = "push";

pub const PushError = error{PushDeliveryFailed};

pub const Subscription = sender.PushSubscription;
pub const Message = sender.PushMessage;
pub const Result = sender.PushResult;

/// Options for `ctx.push().enqueue`. `queue` routes the "push" job to a declared queue
/// (`error.UnknownQueue` on a miss); the queue's own retry policy governs `.failed` retries.
pub const EnqueueOpts = struct {
    queue: []const u8 = "default",
};

/// The durable payload of a queued push delivery (the `"push"` job JSON).
pub const PushJob = struct {
    subscription: sender.PushSubscription,
    message: sender.PushMessage,
};

/// The `ctx.push()` namespace.
pub const PushApi = struct {
    ctx: *Ctx,

    pub const Subscription = sender.PushSubscription;
    pub const Message = sender.PushMessage;
    pub const Result = sender.PushResult;
    /// Re-export of the module-level `EnqueueOpts` so callers can name `ctx.push().EnqueueOpts`.
    pub const Opts = EnqueueOpts;

    /// Deliver `msg` to `sub` synchronously via the configured VAPID identity. Returns the
    /// tri-state: on `.gone` the caller MUST prune its stored subscription (404/410 = dead).
    /// When push is not configured (no VAPID keys), this is a network-free logging no-op that
    /// returns `.delivered`. Only an un-decodable subscription key surfaces as an `error`.
    pub fn send(self: PushApi, sub: sender.PushSubscription, msg: sender.PushMessage) sender.Error!sender.PushResult {
        capture.record(sub, msg);
        const cfg = self.ctx.app.push;
        if (!cfg.configured) {
            std.log.info("[push:noop] endpoint={s} title={s} (no VAPID keys configured; set ZIGBASE_VAPID_PUBLIC_KEY/_PRIVATE_KEY)", .{ sub.endpoint, msg.title });
            return .delivered;
        }
        return sender.deliver(self.ctx, cfg, sub, msg);
    }

    /// Enqueue a durable background push delivery via the built-in `"push"` job kind. The job
    /// re-delivers on the worker; `.failed` is retried by the queue with backoff, `.gone`
    /// stops retrying (a dead endpoint), `.delivered` completes. Requires a wired queue
    /// registry (`error.QueuesUnavailable`) and `.push` configured (`error.UnknownJobKind`).
    pub fn enqueue(self: PushApi, sub: sender.PushSubscription, msg: sender.PushMessage, opts: EnqueueOpts) !void {
        const job = PushJob{ .subscription = sub, .message = msg };
        return self.ctx.enqueueByName(opts.queue, job_kind, job);
    }
};

/// The built-in `"push"` job handler (registered by `framework.zig`). Re-delivers the queued
/// message and translates the tri-state into queue semantics:
///   * `.delivered` → complete.
///   * `.gone`      → complete (STOP retrying a dead endpoint; a queued job cannot prune the
///                    caller's DB row — the synchronous `ctx.push().send` path is how you
///                    learn `.gone` to prune).
///   * `.failed`    → `error.PushDeliveryFailed` so the queue retries with backoff.
/// An un-decodable subscription key is terminal (logged, no retry). When push is not
/// configured the handler is a network-free no-op (completes).
pub fn jobHandler(ctx: *Ctx, payload: []const u8) anyerror!void {
    // Self-contained parse: `parsed` owns its own arena (built over `ctx.app.allocator`, not
    // the request arena) and is freed here regardless of outcome — the job's
    // subscription/message fields are only read synchronously below, never retained past
    // this call, so there is no reason to make this function's own scratch outlive it.
    var parsed = std.json.parseFromSlice(PushJob, ctx.app.allocator, payload, .{ .ignore_unknown_fields = true }) catch {
        // A malformed payload is a programmer error, not a transient failure — drop it (no
        // retry). `warn`, not `err`: `std.log.err` on a path a passing test exercises fails
        // Zig's test runner (see the same note in ctx.enqueueByName / events.zig).
        std.log.warn("push job payload is not valid JSON; dropping (no retry)", .{});
        return;
    };
    defer parsed.deinit();
    const job = parsed.value;
    const cfg = ctx.app.push;
    if (!cfg.configured) {
        std.log.info("[push:noop] queued push for {s} dropped (no VAPID keys configured)", .{job.subscription.endpoint});
        return;
    }
    const res = sender.deliver(ctx, cfg, job.subscription, job.message) catch |e| switch (e) {
        error.InvalidSubscriptionKey => {
            std.log.warn("push job: subscription for {s} has a corrupt key; dropping (no retry)", .{job.subscription.endpoint});
            return; // terminal — retrying a bad key never succeeds
        },
        else => return e, // OOM etc. — let the queue decide
    };
    switch (res) {
        .delivered => {},
        .gone => std.log.info("push job: endpoint {s} is gone (404/410); stopping retries (prune it via the synchronous send path)", .{job.subscription.endpoint}),
        .failed => return error.PushDeliveryFailed, // transient — queue retries with backoff
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const App = @import("../app.zig").App;
const config = @import("config.zig");
const testcapture = @import("../testcapture.zig");

const test_p256dh = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4";
const test_auth = "BTBZMqHH6r4Tts7J_aSIgg";
const test_endpoint = "https://push.example.com/wpush/v1/sub-1";

const JobEnv = struct {
    app: App,

    fn init(push_cfg: config.Runtime) JobEnv {
        return .{ .app = App{ .allocator = testing.allocator, .io = testing.io, .pool = undefined, .push = push_cfg } };
    }
    // `forTest` (not a real arena): `jobHandler`/`deliver` must be correct under ANY
    // allocator, so running them on the leak-checked `std.testing.allocator` directly is a
    // strictly harsher, and more useful, exercise than masking them behind an arena.
    fn ctx(self: *JobEnv) Ctx {
        return Ctx{ .app = &self.app, .arena = RequestArena.forTest(testing.allocator), .rctx = .{}, .request = null, .bound_conn = null };
    }
};

fn configuredCfg(a: std.mem.Allocator) !config.Runtime {
    const kp = try config.generateKeypair(a, testing.io);
    // `resolve` copies the base64 bytes into `Runtime`'s fixed-size fields, so the keypair
    // buffers are scratch once it returns — free them (contract-1) to stay leak-clean.
    defer a.free(kp.public_b64);
    defer a.free(kp.private_b64);
    return config.resolve("mailto:ops@example.com", kp.public_b64, kp.private_b64);
}

fn jobPayload(a: std.mem.Allocator) ![]const u8 {
    const job = PushJob{
        .subscription = .{ .endpoint = test_endpoint, .p256dh = test_p256dh, .auth = test_auth },
        .message = .{ .title = "Hi", .body = "there" },
    };
    return std.json.Stringify.valueAlloc(a, job, .{});
}

test "jobHandler: .failed → error (queue retries)" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("push.example.com", .{ .status = 500 });

    var env = JobEnv.init(try configuredCfg(testing.allocator));
    var cx = env.ctx();
    const payload = try jobPayload(testing.allocator);
    defer testing.allocator.free(payload);
    try testing.expectError(error.PushDeliveryFailed, jobHandler(&cx, payload));
}

test "jobHandler: .gone → completes (no error, no retry)" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("push.example.com", .{ .status = 410 });

    var env = JobEnv.init(try configuredCfg(testing.allocator));
    var cx = env.ctx();
    const payload = try jobPayload(testing.allocator);
    defer testing.allocator.free(payload);
    try jobHandler(&cx, payload); // no error
}

test "jobHandler: unconfigured push is a network-free no-op" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true); // block unmocked — a network attempt would error

    var env = JobEnv.init(.{}); // configured = false
    var cx = env.ctx();
    const payload = try jobPayload(testing.allocator);
    defer testing.allocator.free(payload);
    try jobHandler(&cx, payload); // completes, no network
    try testing.expectEqual(@as(usize, 0), testcapture.http.requestCount());
}

test "jobHandler: malformed payload is dropped (no throw, no retry)" {
    var env = JobEnv.init(.{});
    var cx = env.ctx();
    try jobHandler(&cx, "{ not json");
}

test "PushApi.send: unconfigured is a no-op returning .delivered" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true);

    var env = JobEnv.init(.{});
    var cx = env.ctx();
    const api = PushApi{ .ctx = &cx };
    const res = try api.send(.{ .endpoint = test_endpoint, .p256dh = test_p256dh, .auth = test_auth }, .{ .title = "x" });
    try testing.expectEqual(Result.delivered, res);
    try testing.expectEqual(@as(usize, 0), testcapture.http.requestCount());
}
