//! Generic multi-queue / worker / job engine — runtime types (0.9.0, PR2).
//!
//! ZigBase ships a single background-job engine that powers arbitrary consumer
//! jobs (`ctx.enqueue(.queue, .kind, payload)` / `App.enqueue`) AND the built-in
//! mail (#141) and webhook (#144) job kinds (registered by their own PRs onto the
//! same engine via `.jobs`).
//!
//! This file holds the RUNTIME value types (lowered from the comptime `.queues` /
//! `.workers` / `.jobs` config by `queue/config.zig`) plus the pure backoff math.
//! The two backends live in `queue/durable.zig` (DB-backed, at-least-once) and
//! `queue/memory.zig` (in-process, at-most-once across restart). The comptime
//! lowering + loud `@compileError`s live in `queue/config.zig`.
//!
//! `JobHandler` names `*Ctx`, so this file imports `ctx.zig` (a mutual import, like
//! `events.zig`); `app.zig` therefore stores the lowered `Registry` type-erased
//! (`app.queues: ?*const anyopaque`, mirroring `auth_methods`) to avoid an import
//! cycle.

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;

/// Where a queue's jobs are stored/run. `memory` = in-process (lost on restart,
/// at-most-once); `durable` = persisted to `_queue_jobs` and drained by a poller
/// (survives restart, at-least-once).
pub const Backend = enum { memory, durable };

/// Relative draining priority. The ordinal IS the stored `priority` INT, and the
/// durable claim query is `ORDER BY priority ASC, run_at ASC` — so `high` (0)
/// drains before `normal` (1) before `low` (2). A worker bound to several queues
/// thus drains them in strict priority order in one indexed query.
pub const Priority = enum(u8) { high = 0, normal = 1, low = 2 };

/// Retry-delay growth for a failed-but-retryable job.
pub const Backoff = enum { fixed, exponential };

/// Per-queue retry policy. `max_attempts` is the TOTAL number of attempts (1 = no
/// retry); exhausting it makes the failure terminal (status `failed` + `.onError`).
pub const RetryPolicy = struct {
    max_attempts: u16 = 5,
    backoff: Backoff = .exponential,
    base_ms: u32 = 1000,
    max_ms: u32 = 300_000,
    jitter: bool = true,
};

/// Sustained per-queue delivery ceiling (durable only). `per_second` is BOTH the
/// refill rate and the bucket capacity, so the maximum burst is one second's worth
/// of tokens. The bucket is in-process, per queue name, shared by every worker
/// draining that queue — authoritative because the scheduler is single-process
/// (documented). Memory queues cannot be rated (loud @compileError at lowering).
pub const Rate = struct { per_second: u16 };

/// One declared queue (lowered from a `.queues` entry, or the synthesized `.default`).
pub const QueueDef = struct {
    name: []const u8,
    backend: Backend = .memory,
    priority: Priority = .normal,
    retry: RetryPolicy = .{},
    /// Reclaim threshold (durable only): a `claimed` row whose `claimed_at` is older
    /// than this many seconds is reset to `pending` (a crashed worker stranded it — OR
    /// a handler that legitimately runs this long is presumed dead and replayed). Set
    /// this to comfortably EXCEED this queue's LONGEST job runtime to avoid
    /// double-dispatch. Must be >= 1.
    visibility_timeout_s: i64 = 300,
    /// GC threshold (durable only): `done`/`failed` rows older than this many seconds
    /// are deleted by the `_queue_gc` sweep. Default 7 days.
    done_ttl_s: i64 = 7 * 24 * 3600,
    /// Sustained per-queue claim-rate ceiling (durable only). See `Rate`.
    rate: ?Rate = null,
};

/// One declared worker (lowered from a `.workers` entry, or the implicit
/// all-queues worker). `queues` is the set of queue NAMES this worker drains, in
/// strict priority order.
///
/// `concurrency` is the per-poll-cycle BATCH SIZE: how many ready jobs this worker
/// claims and then processes **serially** within one cycle. It is NOT a count of
/// parallel handler threads — true parallelism comes from declaring MULTIPLE workers
/// (each is its own scheduler job and runs on its own pool thread). Raise it to lift
/// throughput per cycle; add workers to run handlers concurrently.
pub const WorkerDef = struct {
    name: []const u8,
    queues: []const []const u8,
    concurrency: u8 = 1,
};

/// A registered job-kind handler. `payload` is the JSON text produced by
/// `ctx.enqueue`; the handler deserializes it. Errors are retried per the queue's
/// `RetryPolicy` and become terminal (`.onError`) once attempts are exhausted.
pub const JobHandler = *const fn (ctx: *Ctx, payload: []const u8) anyerror!void;

/// kind → handler binding (lowered from a `.jobs` entry).
pub const JobReg = struct {
    kind: []const u8,
    handler: JobHandler,
};

/// The lowered registry threaded (type-erased) onto `app.queues`. Static lifetime
/// (a comptime-lowered const), so `queueByName`/`jobByKind` return borrowed slices.
pub const Registry = struct {
    queues: []const QueueDef = &.{},
    workers: []const WorkerDef = &.{},
    jobs: []const JobReg = &.{},

    pub fn queueByName(self: Registry, name: []const u8) ?QueueDef {
        for (self.queues) |q| if (std.mem.eql(u8, q.name, name)) return q;
        return null;
    }

    pub fn jobByKind(self: Registry, kind: []const u8) ?JobReg {
        for (self.jobs) |j| if (std.mem.eql(u8, j.kind, kind)) return j;
        return null;
    }

    /// True when any declared queue uses the durable backend (gates the poller +
    /// GC jobs and the `_queue_jobs` usage; pure-memory apps install nothing).
    pub fn hasDurable(self: Registry) bool {
        for (self.queues) |q| if (q.backend == .durable) return true;
        return false;
    }

    /// True when `worker` drains at least one durable queue (so it needs a poller).
    pub fn workerHasDurable(self: Registry, worker: WorkerDef) bool {
        for (worker.queues) |qn| {
            if (self.queueByName(qn)) |q| if (q.backend == .durable) return true;
        }
        return false;
    }
};

/// Type-erased accessor for the registry pointed to by `app.queues` (stored as
/// `?*const anyopaque` to avoid an app.zig→queue→ctx→app import cycle).
pub fn registryFromApp(app: anytype) ?*const Registry {
    const opaque_ptr = app.queues orelse return null;
    return @ptrCast(@alignCast(opaque_ptr));
}

/// Pure backoff delay (milliseconds) for the `attempt`-th failure (1-based: the
/// first failure is attempt 1). `fixed` returns `base_ms`; `exponential` returns
/// `base_ms * 2^(attempt-1)`. Both are capped at `max_ms`. When `jitter` is set,
/// the result is "equal jitter" — half the computed delay plus a random share of
/// the other half, i.e. in `[delay/2, delay]` — using `rand` as the entropy. With
/// jitter off the result is exactly the (capped) computed delay.
pub fn backoffMs(policy: RetryPolicy, attempt: u32, rand: u64) u32 {
    const a = if (attempt == 0) 1 else attempt;
    var delay: u64 = policy.base_ms;
    if (policy.backoff == .exponential) {
        var i: u32 = 1;
        while (i < a) : (i += 1) {
            delay *|= 2; // saturating: never overflows
            if (delay >= policy.max_ms) {
                delay = policy.max_ms;
                break;
            }
        }
    }
    if (delay > policy.max_ms) delay = policy.max_ms;
    if (!policy.jitter) return @intCast(delay);
    const half = delay / 2;
    const span = delay - half; // half (or half+1 when delay is odd)
    const extra = if (span == 0) 0 else rand % (span + 1);
    return @intCast(half + extra);
}

const testing = std.testing;

test "backoffMs exponential without jitter doubles and caps" {
    const p = RetryPolicy{ .backoff = .exponential, .base_ms = 100, .max_ms = 1000, .jitter = false };
    try testing.expectEqual(@as(u32, 100), backoffMs(p, 1, 0)); // 100*2^0
    try testing.expectEqual(@as(u32, 200), backoffMs(p, 2, 0)); // 100*2^1
    try testing.expectEqual(@as(u32, 400), backoffMs(p, 3, 0)); // 100*2^2
    try testing.expectEqual(@as(u32, 800), backoffMs(p, 4, 0)); // 100*2^3
    try testing.expectEqual(@as(u32, 1000), backoffMs(p, 5, 0)); // capped (would be 1600)
    try testing.expectEqual(@as(u32, 1000), backoffMs(p, 50, 0)); // still capped (no overflow)
}

test "backoffMs fixed without jitter is constant and capped" {
    const p = RetryPolicy{ .backoff = .fixed, .base_ms = 250, .max_ms = 1000, .jitter = false };
    try testing.expectEqual(@as(u32, 250), backoffMs(p, 1, 0));
    try testing.expectEqual(@as(u32, 250), backoffMs(p, 9, 0));
    const capped = RetryPolicy{ .backoff = .fixed, .base_ms = 5000, .max_ms = 1000, .jitter = false };
    try testing.expectEqual(@as(u32, 1000), backoffMs(capped, 1, 0));
}

test "backoffMs jitter stays within [delay/2, delay] bounds" {
    const p = RetryPolicy{ .backoff = .exponential, .base_ms = 1000, .max_ms = 1_000_000, .jitter = true };
    // attempt 3 -> computed delay 4000; jitter result must be in [2000, 4000].
    var seed: u64 = 0;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407; // LCG
        const got = backoffMs(p, 3, seed);
        try testing.expect(got >= 2000);
        try testing.expect(got <= 4000);
    }
}

test "Registry queueByName / jobByKind / hasDurable" {
    const reg = Registry{
        .queues = &.{
            .{ .name = "default", .backend = .memory },
            .{ .name = "emails", .backend = .durable, .priority = .high },
        },
        .jobs = &.{},
    };
    try testing.expect(reg.queueByName("emails") != null);
    try testing.expectEqual(Priority.high, reg.queueByName("emails").?.priority);
    try testing.expect(reg.queueByName("missing") == null);
    try testing.expect(reg.hasDurable());

    const mem_only = Registry{ .queues = &.{.{ .name = "default", .backend = .memory }} };
    try testing.expect(!mem_only.hasDurable());
}
