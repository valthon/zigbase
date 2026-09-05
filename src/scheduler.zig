const std = @import("std");
const RequestArena = @import("request_arena.zig").RequestArena;
const schedule = @import("schedule.zig");
const events = @import("events.zig");
const clock = @import("clock.zig");
const App = @import("app.zig").App;
const Ctx = @import("ctx.zig").Ctx;

/// A registered job after comptime assembly. `run` is a uniform wrapper returning
/// `?schedule.Reactive`: `null` for cron/interval jobs (next fire computed from `schedule`),
/// or the handler's returned `Reactive` for reactive jobs. Distributed wrappers
/// return a reactive result; the dispatcher bounds their polling to 15 seconds.
pub const RuntimeJob = struct {
    name: []const u8,
    schedule: schedule.Schedule,
    run: *const fn (ctx: *Ctx, ev: *events.JobEvent) anyerror!?schedule.Reactive,
    distributed: bool = false,
};

/// `@compileError` on a malformed job spec, mirroring `events.validateRouteSpecs`: a missing
/// required field (`.name`/`.schedule`/`.handler`), an unknown key (a typo that would be
/// silently dropped), or a malformed `.cron` grammar (which would otherwise make the job
/// boot-fire and silently retire). The handler type differs by mode (reactive returns
/// `Reactive`, others `void`), so it is not hard-asserted here.
fn validateJobSpecs(comptime specs: anytype) void {
    inline for (std.meta.fields(@TypeOf(specs))) |f| {
        const s = @field(specs, f.name);
        if (!@hasField(@TypeOf(s), "name")) @compileError("job spec is missing '.name' (expected .{ .name = \"...\", .schedule = ..., .handler = fn })");
        if (!@hasField(@TypeOf(s), "schedule")) @compileError("job spec is missing '.schedule' (expected .{ .name = \"...\", .schedule = ..., .handler = fn })");
        if (!@hasField(@TypeOf(s), "handler")) @compileError("job spec is missing '.handler' (expected .{ .name = \"...\", .schedule = ..., .handler = fn })");
        // Fail loud on a typo'd key (only .name/.schedule/.handler are read) so a misspelling
        // isn't silently dropped, mirroring the unknown-key gates on collections/fields/routes.
        inline for (std.meta.fields(@TypeOf(s))) |sf| {
            comptime var ok = false;
            inline for ([_][]const u8{ "name", "schedule", "handler", "distributed" }) |a| {
                if (comptime std.mem.eql(u8, sf.name, a)) ok = true;
            }
            if (!ok) @compileError("job spec '" ++ s.name ++ "': unknown key '." ++ sf.name ++
                "' (recognized keys: .name, .schedule, .handler, .distributed)");
        }
        // Validate a comptime-known cron grammar so a malformed expression (wrong field
        // count, a full day name, a trailing space) fails at build time instead of silently
        // firing at every boot and never on schedule (see schedule.validateCron).
        const sched: schedule.Schedule = s.schedule;
        if (sched == .cron) schedule.validateCron(sched.cron, "job spec '" ++ s.name ++ "'");
        if (sched == .interval and sched.interval == .minutes and sched.interval.minutes == 0) @compileError("scheduled minute intervals must be positive");
        if (@hasField(@TypeOf(s), "distributed")) {
            if (sched == .reactive) @compileError("distributed jobs require a cron or interval schedule");
            if (s.name.len == 0 or s.name.len > 200 or s.name[0] == '_') @compileError("distributed job names must contain 1..200 bytes and not start with '_'");
            _ = @import("scheduler_coordination.zig").lowerConfig(s.distributed);
            if (sched == .interval and (sched.interval == .minutes and (sched.interval.minutes == 0 or sched.interval.minutes > 525600))) @compileError("distributed minute intervals must be between 1 and 525600");
        }
    }
    inline for (std.meta.fields(@TypeOf(specs)), 0..) |f, i| {
        inline for (std.meta.fields(@TypeOf(specs))[0..i]) |prior| {
            const current = @field(specs, f.name);
            const previous = @field(specs, prior.name);
            if ((@hasField(@TypeOf(current), "distributed") or @hasField(@TypeOf(previous), "distributed")) and std.mem.eql(u8, current.name, previous.name)) @compileError("distributed job names must be unique");
        }
    }
}

/// Assemble a comptime tuple of job specs `.{ .name, .schedule, .handler }` into a runtime
/// table. For `.reactive` schedules the handler must be `fn(*Ctx, *JobEvent) anyerror!Reactive`;
/// otherwise `fn(*Ctx, *JobEvent) anyerror!void`. Both are unified to `anyerror!?Reactive` via a
/// per-spec wrapper struct (each spec gets its own `Wrap` type, hence its own `run` fn ptr).
pub fn buildJobs(comptime specs: anytype) []const RuntimeJob {
    comptime validateJobSpecs(specs);
    const fields = std.meta.fields(@TypeOf(specs));
    // A struct-namespace const has static lifetime, so &Holder.table is a valid []const
    // returnable at runtime (a plain comptime local is not).
    const Holder = struct {
        const table: [fields.len]RuntimeJob = blk: {
            var t: [fields.len]RuntimeJob = undefined;
            for (fields, 0..) |f, i| {
                const s = @field(specs, f.name);
                const sched: schedule.Schedule = s.schedule;
                const reactive = sched == .reactive;
                const handler = s.handler;
                const Wrap = struct {
                    fn run(ctx: *Ctx, ev: *events.JobEvent) anyerror!?schedule.Reactive {
                        if (@hasField(@TypeOf(s), "distributed")) {
                            const status = try @import("scheduler_coordination.zig").run(ctx, ev, sched, comptime @import("scheduler_coordination.zig").lowerConfig(s.distributed), handler);
                            if (status == .stopped) return .stop;
                            return .{ .after = .{ .minutes = 0 } };
                        } else if (reactive) {
                            return try handler(ctx, ev);
                        } else {
                            try handler(ctx, ev);
                            return null;
                        }
                    }
                };
                t[i] = .{ .name = s.name, .schedule = sched, .run = Wrap.run, .distributed = @hasField(@TypeOf(s), "distributed") };
            }
            break :blk t;
        };
    };
    return &Holder.table;
}

/// Combine two comptime-assembled job tables into one static-lifetime slice. Used to
/// append the framework's own internal jobs (e.g. the `_ttl_gc` sweep) after the
/// consumer's `.cron`-derived table. Like `buildJobs`, the result is returned via a
/// struct-namespace const so it has static lifetime (a plain comptime local would not).
pub fn concatJobs(comptime a: []const RuntimeJob, comptime b: []const RuntimeJob) []const RuntimeJob {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    const Holder = struct {
        const table: [a.len + b.len]RuntimeJob = blk: {
            var t: [a.len + b.len]RuntimeJob = undefined;
            for (a, 0..) |j, i| t[i] = j;
            for (b, 0..) |j, i| t[a.len + i] = j;
            break :blk t;
        };
    };
    return &Holder.table;
}

pub const JobState = struct {
    status: enum { idle, running, stopped },
    next_fire: i64, // unix seconds; meaningful when status == .idle
    failures: u32 = 0, // consecutive handler failures; drives exponential backoff
};

/// Pure decision: append the indices of jobs that are `.idle` AND due (`next_fire <= now`)
/// to `out`, marking each `.running` (single-flight). Returns the filled slice of `out`.
/// `out` may be shorter than `state`; due jobs beyond its capacity remain idle
/// and are eligible for the next tick.
pub fn tick(state: []JobState, now: i64, out: []usize) []usize {
    var n: usize = 0;
    for (state, 0..) |*s, i| {
        if (s.status == .idle and s.next_fire <= now) {
            if (n < out.len) {
                s.status = .running;
                out[n] = i;
                n += 1;
            }
        }
    }
    return out[0..n];
}

test "tick leaves due jobs beyond the output capacity idle for the next tick" {
    var state = [_]JobState{
        .{ .status = .idle, .next_fire = 10 },
        .{ .status = .idle, .next_fire = 10 },
        .{ .status = .idle, .next_fire = 10 },
    };
    var out: [1]usize = undefined;
    try std.testing.expectEqualSlices(usize, &.{0}, tick(&state, 10, &out));
    try std.testing.expect(state[1].status == .idle);
    try std.testing.expectEqualSlices(usize, &.{1}, tick(&state, 10, &out));
    try std.testing.expectEqualSlices(usize, &.{2}, tick(&state, 10, &out));
}

/// Apply a job's completion to its local state. `reactive_result` is non-null for
/// reactive jobs or distributed wrappers polling a database-owned schedule.
/// For ordinary cron/interval jobs, next_fire is recomputed from `sched`;
/// if there is no future fire (e.g. an impossible cron), the job is retired (`.stopped`).
pub fn completeJob(s: *JobState, sched: schedule.Schedule, reactive_result: ?schedule.Reactive, now: i64) void {
    s.failures = 0; // a successful completion resets the backoff counter
    if (reactive_result) |rr| {
        switch (rr) {
            .stop => {
                s.status = .stopped;
                return;
            },
            .after => |iv| {
                s.next_fire = now + schedule.periodSeconds(iv);
                s.status = .idle;
                return;
            },
        }
    }
    s.next_fire = schedule.nextFire(sched, now) orelse {
        s.status = .stopped;
        return;
    };
    s.status = .idle;
}

fn completeRuntimeJob(s: *JobState, job: RuntimeJob, result: ?schedule.Reactive, now: i64) void {
    completeJob(s, job.schedule, result, now);
    // No public seconds-granularity schedule is needed for this internal poll.
    if (job.distributed and s.status == .idle) s.next_fire = @max(s.next_fire, now + 15);
}

test "distributed idle polling is bounded and stopped jobs retire locally" {
    const H = struct {
        fn handler(_: *Ctx, _: *events.JobEvent) anyerror!void {}
    };
    const jobs = buildJobs(.{.{ .name = "poll", .schedule = schedule.Schedule{ .interval = .hourly }, .distributed = .{}, .handler = H.handler }});
    var state = JobState{ .status = .running, .next_fire = 0 };
    completeRuntimeJob(&state, jobs[0], .{ .after = .{ .minutes = 0 } }, 100);
    try std.testing.expectEqual(@as(i64, 115), state.next_fire);
    var out: [1]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), tick((&state)[0..1], 114, &out).len);
    completeRuntimeJob(&state, jobs[0], .stop, 115);
    try std.testing.expect(state.status == .stopped);
}

/// Exponential backoff delay (seconds) for the Nth consecutive failure: 1, 2, 4, 8, ...
/// capped at 1 hour. `failures` is >= 1.
pub fn retryDelay(failures: u32) i64 {
    const cap: i64 = 3600;
    if (failures == 0) return 1;
    var d: i64 = 1;
    var i: u32 = 1;
    while (i < failures) : (i += 1) {
        d *= 2;
        if (d >= cap) return cap;
    }
    return @min(d, cap);
}

/// Apply a job-handler FAILURE to its state: report-count++, retry after exponential
/// backoff. The job is NOT retired (it keeps retrying with growing, capped delay); each
/// failure is reported separately by the worker via dispatchError.
pub fn completeJobError(s: *JobState, now: i64) void {
    s.failures += 1;
    s.next_fire = now + retryDelay(s.failures);
    s.status = .idle;
}

const Thread = std.Thread;

/// Per-thread stack size (bytes) for the scheduler's spawned threads (the tick thread and
/// each job-pool worker). `std.Thread`'s default is 16 MiB EACH, so the default pool
/// reserves ~48 MiB of address space for stacks that the scheduler/job handlers never come
/// close to using. 1 MiB is generous for cron/job handlers (they heap-allocate; argon2/DB
/// work lives off-stack) while cutting the reserved footprint by ~15x per thread.
/// Overridable per-deploy via the `.pools.stack_size` comptime lever (threaded through
/// `Scheduler.init`), which RAISES the stack for unusually deep handlers — the default
/// already minimizes the footprint.
pub const default_job_stack_size: usize = 1 << 20; // 1 MiB

/// Hard floor the `.pools.stack_size` lever is clamped up to. The OS's effective minimum
/// thread stack is `PTHREAD_STACK_MIN` PLUS the binary's static-TLS block, which is
/// binary-dependent: in the full ZigBase binary (SQLite + zap linked) it exceeds 256 KiB,
/// so `pthread_create` returns EINVAL below it — a hard `unreachable` abort, not a catchable
/// error. 1 MiB is proven safe across the test and server binaries, so a too-small request
/// is clamped up to it rather than allowed to crash the process at startup.
pub const min_job_stack_size: usize = 1 << 20; // 1 MiB

/// The framework's scheduling clock — wall-clock seconds, honoring the dev-only
/// `ZIGBASE_FAKE_NOW` override (see `clock.zig`) so e2e suites can freeze next-fire math.
fn unixNow(io: std.Io) i64 {
    return clock.nowUnix(io);
}

/// Threaded scheduler runtime: a scheduler thread ticks the `JobState` table on a fixed
/// cadence, enqueuing due jobs into a spinlock-guarded ring queue; a worker pool drains the
/// queue and runs handlers. All `state`/`queue`/`q_*` mutation happens under `mutex`;
/// `shutdown` is atomic. `start()` spawns threads; `stop()` joins them cleanly (no deadlock);
/// `stop()` MUST be called before `deinit()` (deinit frees state/queue/workers).
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    app: *App,
    jobs: []const RuntimeJob,
    pool_size: usize,
    stack_size: usize = default_job_stack_size,
    state: []JobState,
    queue: []usize,
    q_head: usize = 0,
    q_len: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sched_thread: ?Thread = null,
    workers: []Thread = &.{},

    /// Open a scheduler with the default per-thread stack size. Thin wrapper over
    /// `initSized` kept for the call sites (tests/serve) that don't tune the stack.
    pub fn init(allocator: std.mem.Allocator, app: *App, jobs: []const RuntimeJob, pool_size: usize) !Scheduler {
        return initSized(allocator, app, jobs, pool_size, default_job_stack_size);
    }

    /// Open a scheduler, spawning the tick/worker/submit threads with `stack_size`-byte
    /// stacks instead of `std.Thread`'s 16 MiB default — far less reserved address space per
    /// thread, same scheduling behavior. `stack_size` is clamped UP to `min_job_stack_size`
    /// (a too-small value would EINVAL-abort `pthread_create` in the full binary), so the
    /// lever can only raise the stack above the 1 MiB default, never below the safe floor.
    pub fn initSized(allocator: std.mem.Allocator, app: *App, jobs: []const RuntimeJob, pool_size: usize, stack_size: usize) !Scheduler {
        const state = try allocator.alloc(JobState, jobs.len);
        errdefer allocator.free(state);
        const now = unixNow(app.io);
        for (state, 0..) |*s, i| {
            if (jobs[i].distributed) {
                s.* = .{ .status = .idle, .next_fire = now };
                continue;
            }
            const sched = jobs[i].schedule;
            if (schedule.nextFire(sched, now)) |nf| {
                s.* = .{ .status = .idle, .next_fire = nf };
            } else switch (sched) {
                // Reactive jobs have no schedule-derived fire; they intentionally run once at
                // boot (their handler's returned `Reactive` drives every subsequent fire).
                .reactive => s.* = .{ .status = .idle, .next_fire = now },
                // A cron/interval with no future fire (e.g. an impossible cron like Feb 30)
                // must NOT be aliased onto the reactive boot-fire path — that would run the
                // handler at an arbitrary boot time and never on schedule. Retire it and log
                // why, so it isn't a silent no-op.
                else => {
                    std.log.warn("scheduler: job '{s}' has no future fire time (impossible schedule); retiring it without running", .{jobs[i].name});
                    s.* = .{ .status = .stopped, .next_fire = now };
                },
            }
        }
        const queue = try allocator.alloc(usize, jobs.len);
        return .{ .allocator = allocator, .app = app, .jobs = jobs, .pool_size = pool_size, .stack_size = @max(stack_size, min_job_stack_size), .state = state, .queue = queue };
    }

    pub fn deinit(self: *Scheduler) void {
        self.allocator.free(self.state);
        self.allocator.free(self.queue);
        if (self.workers.len > 0) self.allocator.free(self.workers);
    }

    fn lock(self: *Scheduler) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Scheduler) void {
        self.mutex.unlock();
    }

    fn enqueue(self: *Scheduler, idx: usize) void { // caller holds lock
        if (self.q_len < self.queue.len) {
            self.queue[(self.q_head + self.q_len) % self.queue.len] = idx;
            self.q_len += 1;
        }
    }
    fn dequeue(self: *Scheduler) ?usize { // caller holds lock
        if (self.q_len == 0) return null;
        const idx = self.queue[self.q_head];
        self.q_head = (self.q_head + 1) % self.queue.len;
        self.q_len -= 1;
        return idx;
    }

    pub fn start(self: *Scheduler) !void {
        self.app.scheduler = self;
        self.workers = try self.allocator.alloc(Thread, self.pool_size);
        var spawned: usize = 0;
        errdefer {
            self.shutdown.store(true, .release);
            for (self.workers[0..spawned]) |t| t.join();
        }
        for (self.workers) |*t| {
            t.* = try Thread.spawn(.{ .stack_size = self.stack_size }, workerLoop, .{self});
            spawned += 1;
        }
        self.sched_thread = try Thread.spawn(.{ .stack_size = self.stack_size }, schedulerLoop, .{self});
    }

    pub fn stop(self: *Scheduler) void {
        self.shutdown.store(true, .release);
        if (self.sched_thread) |t| t.join();
        self.sched_thread = null;
        for (self.workers) |t| t.join();
        self.app.scheduler = null;
    }

    fn schedulerLoop(self: *Scheduler) void {
        var fire_buf: [256]usize = undefined;
        while (!self.shutdown.load(.acquire)) {
            const now = unixNow(self.app.io);
            self.lock();
            const cap = @min(fire_buf.len, self.state.len);
            const fired = tick(self.state, now, fire_buf[0..cap]);
            for (fired) |idx| self.enqueue(idx);
            self.unlock();
            self.app.io.sleep(std.Io.Duration.fromMilliseconds(500), .awake) catch {};
        }
    }

    fn workerLoop(self: *Scheduler) void {
        while (true) {
            self.lock();
            const maybe = self.dequeue();
            self.unlock();
            const idx = maybe orelse {
                if (self.shutdown.load(.acquire)) return;
                self.app.io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};
                continue;
            };
            const job = self.jobs[idx];
            var ev = events.JobEvent{ .app = self.app, .name = job.name };
            // Build a per-invocation Ctx: jobs have no HTTP request and no auth
            // (anonymous rctx); reads/writes go through ctx.records(), which lazily
            // acquires from the pool. A per-invocation arena owns the results
            // ctx.records() allocates so they're freed when the job returns (no
            // GPA leak). Declared before cx so arena.deinit runs AFTER cx.deinit
            // (LIFO): cx.deinit only releases the pooled reader, arena frees results.
            var arena = std.heap.ArenaAllocator.init(self.app.allocator);
            defer arena.deinit();
            var cx = Ctx{ .app = self.app, .arena = RequestArena.from(&arena), .rctx = .{}, .request = null, .bound_conn = null };
            defer cx.deinit();
            if (job.run(&cx, &ev)) |result| {
                // SUCCESS: resume the normal schedule (resets the backoff counter).
                const now = unixNow(self.app.io);
                self.lock();
                completeRuntimeJob(&self.state[idx], job, result, now);
                const retired_no_fire = result == null and self.state[idx].status == .stopped;
                self.unlock();
                // A cron/interval job (result == null) that completeJob retired has no further
                // fire time — surface it instead of letting the job vanish silently. A reactive
                // `.stop` (result != null) is an intentional retirement and stays quiet.
                if (retired_no_fire)
                    std.log.warn("scheduler: job '{s}' completed with no future fire time; retired (status=stopped)", .{job.name});
            } else |e| {
                // FAILURE: report this failure, then retry with exponential backoff.
                var err_ev = events.ErrorEvent{ .app = self.app, .ctx = null, .err = e, .phase = .cron, .message = @errorName(e) };
                events.dispatchError(self.app, self.app.dispatch, &err_ev);
                const now = unixNow(self.app.io);
                self.lock();
                completeJobError(&self.state[idx], now);
                self.unlock();
            }
        }
    }
};

test "concatJobs combines two job tables (lengths + names from both halves)" {
    const H = struct {
        fn noop(ctx: *Ctx, ev: *events.JobEvent) anyerror!void {
            _ = ctx;
            _ = ev;
        }
    };
    const a = comptime buildJobs(.{
        .{ .name = "user_a", .schedule = schedule.Schedule{ .cron = "0 3 * * *" }, .handler = H.noop },
        .{ .name = "user_b", .schedule = schedule.Schedule{ .interval = .hourly }, .handler = H.noop },
    });
    const b = comptime buildJobs(.{
        .{ .name = "_ttl_gc", .schedule = schedule.Schedule{ .interval = .{ .minutes = 5 } }, .handler = H.noop },
    });
    const both = comptime concatJobs(a, b);
    try std.testing.expectEqual(@as(usize, 3), both.len);
    try std.testing.expectEqualStrings("user_a", both[0].name);
    try std.testing.expectEqualStrings("user_b", both[1].name);
    try std.testing.expectEqualStrings("_ttl_gc", both[2].name);
    // an empty second half is a no-op identity
    const just_a = comptime concatJobs(a, &.{});
    try std.testing.expectEqual(@as(usize, 2), just_a.len);
    try std.testing.expectEqualStrings("user_a", just_a[0].name);
}

test "buildJobs assembles cron/interval/reactive into a uniform table" {
    const H = struct {
        fn cleanup(ctx: *Ctx, ev: *events.JobEvent) anyerror!void {
            _ = ctx;
            _ = ev;
        }
        fn backoff(ctx: *Ctx, ev: *events.JobEvent) anyerror!schedule.Reactive {
            _ = ctx;
            _ = ev;
            return .{ .after = .{ .minutes = 5 } };
        }
    };
    const jobs = buildJobs(.{
        .{ .name = "cleanup", .schedule = schedule.Schedule{ .cron = "0 3 * * *" }, .handler = H.cleanup },
        .{ .name = "poll", .schedule = schedule.Schedule{ .interval = .hourly }, .handler = H.cleanup },
        .{ .name = "backoff", .schedule = schedule.Schedule.reactive, .handler = H.backoff },
    });
    try std.testing.expectEqual(@as(usize, 3), jobs.len);
    try std.testing.expectEqualStrings("cleanup", jobs[0].name);
    try std.testing.expect(jobs[0].schedule == .cron);
    try std.testing.expect(jobs[1].schedule == .interval);
    try std.testing.expect(jobs[2].schedule == .reactive);

    // The wrapped run returns ?Reactive: reactive job returns the handler's Reactive; others null.
    var ev = events.JobEvent{ .app = undefined, .name = "x" };
    var cx = Ctx{ .app = undefined, .arena = RequestArena.forTest(std.testing.allocator), .rctx = .{}, .request = null, .bound_conn = null };
    defer cx.deinit();
    const r2 = try jobs[2].run(&cx, &ev);
    try std.testing.expect(r2 != null and r2.?.after.minutes == 5);
    const r0 = try jobs[0].run(&cx, &ev);
    try std.testing.expect(r0 == null);
}

test "tick fires due idle jobs and marks them running (single-flight)" {
    var st = [_]JobState{
        .{ .status = .idle, .next_fire = 1000 },
        .{ .status = .idle, .next_fire = 2000 },
    };
    var fire_buf: [8]usize = undefined;
    const fired = tick(&st, 1000, &fire_buf);
    try std.testing.expectEqual(@as(usize, 1), fired.len); // only job 0 is due (next_fire <= now)
    try std.testing.expectEqual(@as(usize, 0), fired[0]);
    try std.testing.expect(st[0].status == .running);
    try std.testing.expect(st[1].status == .idle);
}

test "tick does not refire a job that is already running" {
    var st = [_]JobState{.{ .status = .running, .next_fire = 1000 }};
    var fire_buf: [8]usize = undefined;
    const fired = tick(&st, 5000, &fire_buf);
    try std.testing.expectEqual(@as(usize, 0), fired.len);
}

test "tick skips stopped jobs" {
    var st = [_]JobState{.{ .status = .stopped, .next_fire = 0 }};
    var fire_buf: [8]usize = undefined;
    const fired = tick(&st, 9999, &fire_buf);
    try std.testing.expectEqual(@as(usize, 0), fired.len);
}

test "completeJob: interval reschedules; reactive uses returned delay; stop retires; invalid cron retires" {
    var s = JobState{ .status = .running, .next_fire = 1000 };
    completeJob(&s, .{ .interval = .hourly }, null, 1000);
    try std.testing.expect(s.status == .idle and s.next_fire == 1000 + 3600);

    var s2 = JobState{ .status = .running, .next_fire = 0 };
    completeJob(&s2, .reactive, .{ .after = .{ .minutes = 5 } }, 2000);
    try std.testing.expect(s2.status == .idle and s2.next_fire == 2000 + 300);

    var s3 = JobState{ .status = .running, .next_fire = 0 };
    completeJob(&s3, .reactive, .stop, 2000);
    try std.testing.expect(s3.status == .stopped);

    // An impossible cron has no next fire -> retire the job rather than spin.
    var s4 = JobState{ .status = .running, .next_fire = 0 };
    completeJob(&s4, .{ .cron = "0 0 30 2 *" }, null, 1609470000); // Feb 30 never occurs
    try std.testing.expect(s4.status == .stopped);
}

test "retryDelay is exponential, capped at 1h" {
    try std.testing.expectEqual(@as(i64, 1), retryDelay(1));
    try std.testing.expectEqual(@as(i64, 2), retryDelay(2));
    try std.testing.expectEqual(@as(i64, 4), retryDelay(3));
    try std.testing.expectEqual(@as(i64, 8), retryDelay(4));
    try std.testing.expectEqual(@as(i64, 3600), retryDelay(20)); // capped at 1h
    try std.testing.expectEqual(@as(i64, 3600), retryDelay(100)); // no overflow
}

test "completeJobError backs off and increments failures; success resets" {
    var s = JobState{ .status = .running, .next_fire = 0, .failures = 0 };
    completeJobError(&s, 1000);
    try std.testing.expect(s.status == .idle and s.failures == 1 and s.next_fire == 1000 + 1);
    completeJobError(&s, 1000);
    try std.testing.expect(s.failures == 2 and s.next_fire == 1000 + 2);
    completeJobError(&s, 1000);
    try std.testing.expect(s.failures == 3 and s.next_fire == 1000 + 4);
    // a subsequent SUCCESS resets failures and schedules normally
    completeJob(&s, .{ .interval = .hourly }, null, 2000);
    try std.testing.expect(s.status == .idle and s.failures == 0 and s.next_fire == 2000 + 3600);
}

test "reactive job that errors retries with backoff (not retired)" {
    var s = JobState{ .status = .running, .next_fire = 0, .failures = 0 };
    completeJobError(&s, 5000); // an errored reactive job is NOT stopped; it backs off
    try std.testing.expect(s.status == .idle and s.failures == 1 and s.next_fire == 5001);
}

test "initSized: valid cron schedules a future fire, reactive fires at boot, impossible cron is retired" {
    const H = struct {
        fn noop(ctx: *Ctx, ev: *events.JobEvent) anyerror!void {
            _ = ctx;
            _ = ev;
        }
        fn react(ctx: *Ctx, ev: *events.JobEvent) anyerror!schedule.Reactive {
            _ = ctx;
            _ = ev;
            return .stop;
        }
    };
    const jobs = buildJobs(.{
        .{ .name = "daily", .schedule = schedule.Schedule{ .cron = "0 3 * * *" }, .handler = H.noop },
        .{ .name = "boot", .schedule = schedule.Schedule.reactive, .handler = H.react },
        // Grammatically valid but impossible (Feb 30) — nextFire yields null; it must NOT be
        // aliased onto the reactive boot-fire path, it must be retired.
        .{ .name = "feb30", .schedule = schedule.Schedule{ .cron = "0 0 30 2 *" }, .handler = H.noop },
    });
    var app: App = undefined;
    app.io = std.testing.io;
    app.allocator = std.testing.allocator;
    var sched = try Scheduler.initSized(std.testing.allocator, &app, jobs, 1, min_job_stack_size);
    defer sched.deinit();
    const now = clock.nowUnix(app.io);
    try std.testing.expect(sched.state[0].status == .idle and sched.state[0].next_fire > now);
    try std.testing.expect(sched.state[1].status == .idle and sched.state[1].next_fire <= now);
    try std.testing.expect(sched.state[2].status == .stopped);
}

test "Scheduler runs a due reactive job then stops cleanly" {
    const Counter = struct {
        var n: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn run(ctx: *Ctx, ev: *events.JobEvent) anyerror!schedule.Reactive {
            _ = ctx;
            _ = ev;
            _ = n.fetchAdd(1, .monotonic);
            return .stop; // run exactly once
        }
    };
    Counter.n.store(0, .monotonic);
    const jobs = buildJobs(.{
        .{ .name = "once", .schedule = schedule.Schedule.reactive, .handler = Counter.run },
    });
    // Minimal App: only .io/.allocator are touched by the scheduler in this test (the job ignores the DB).
    var app: App = undefined;
    app.io = std.testing.io;
    app.allocator = std.testing.allocator;
    app.pool = undefined;
    app.dispatch = null;
    app.scheduler = null;
    app.submit_fn = null;

    var sched = try Scheduler.init(std.testing.allocator, &app, jobs, 2);
    defer sched.deinit();
    try sched.start();
    var waited: usize = 0;
    while (Counter.n.load(.monotonic) == 0 and waited < 300) : (waited += 1) {
        app.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    sched.stop();
    try std.testing.expectEqual(@as(u32, 1), Counter.n.load(.monotonic));
}

test "Scheduler initSized clamps a too-small stack to the safe floor and still runs the job" {
    const Counter = struct {
        var n: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn run(ctx: *Ctx, ev: *events.JobEvent) anyerror!schedule.Reactive {
            _ = ctx;
            _ = ev;
            // Touch a few KiB of stack so a too-small worker stack would fault here.
            var scratch: [4096]u8 = undefined;
            for (&scratch, 0..) |*b, i| b.* = @truncate(i);
            std.mem.doNotOptimizeAway(&scratch);
            _ = n.fetchAdd(1, .monotonic);
            return .stop;
        }
    };
    Counter.n.store(0, .monotonic);
    const jobs = buildJobs(.{
        .{ .name = "once", .schedule = schedule.Schedule.reactive, .handler = Counter.run },
    });
    var app: App = undefined;
    app.io = std.testing.io;
    app.allocator = std.testing.allocator;
    app.pool = undefined;
    app.dispatch = null;
    app.scheduler = null;
    app.submit_fn = null;

    // A below-floor request (256 KiB) is clamped UP to min_job_stack_size, so it can't
    // trigger a pthread EINVAL abort in the real binary; the job still runs on the threads.
    var sched = try Scheduler.initSized(std.testing.allocator, &app, jobs, 2, 256 << 10);
    defer sched.deinit();
    try std.testing.expectEqual(min_job_stack_size, sched.stack_size);
    try sched.start();
    var waited: usize = 0;
    while (Counter.n.load(.monotonic) == 0 and waited < 300) : (waited += 1) {
        app.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    sched.stop();
    try std.testing.expectEqual(@as(u32, 1), Counter.n.load(.monotonic));
}
