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

/// One reading of both scheduler clocks: `wall` is unix seconds (it can step when the
/// host clock is set), `mono_ms` is milliseconds on the boot clock (it never steps).
pub const Now = struct { wall: i64, mono_ms: i64 };

/// When an idle job is next due. A cron occurrence names a wall-clock minute, so it is a
/// `.wall` instant (unix seconds). Every other wait is a duration from a local event: an
/// interval or reactive `.after` from the last completion, a failure backoff, the
/// `.distributed` poll. Those are `.mono` deadlines (boot-clock milliseconds), so a wall
/// clock step neither stalls nor bunches them (#493).
pub const Due = union(enum) {
    wall: i64,
    mono: i64,

    fn reached(self: Due, now: Now) bool {
        return switch (self) {
            .wall => |t| t <= now.wall,
            .mono => |t| t <= now.mono_ms,
        };
    }
};

pub const JobState = struct {
    status: enum { idle, running, stopped },
    due: Due, // meaningful when status == .idle
    failures: u32 = 0, // consecutive handler failures; drives exponential backoff
    /// The wall-clock minute (unix seconds) of the cron occurrence that last fired. The
    /// next occurrence is always after it, so no minute runs twice whatever the wall
    /// clock does while the handler runs (see `completeJob`).
    last_cron: ?i64 = null,
};

/// A boot-clock deadline `seconds` after `now`, saturating rather than overflowing for an
/// absurd interval.
fn monoAfter(now: Now, seconds: i64) Due {
    return .{ .mono = now.mono_ms +| (seconds *| std.time.ms_per_s) };
}

/// The next due time a schedule itself implies after `now`: the next matching wall minute
/// for cron, one period on the boot clock for an interval, none for reactive.
fn scheduleDue(sched: schedule.Schedule, now: Now) ?Due {
    return switch (sched) {
        .cron => if (schedule.nextFire(sched, now.wall)) |t| .{ .wall = t } else null,
        .interval => |iv| monoAfter(now, schedule.periodSeconds(iv)),
        .reactive => null,
    };
}

/// Pure decision: append the indices of jobs that are `.idle` AND due to `out`, marking
/// each `.running` (single-flight). Returns the filled slice of `out`.
/// `out` may be shorter than `state`; due jobs beyond its capacity remain idle
/// and are eligible for the next tick.
pub fn tick(state: []JobState, now: Now, out: []usize) []usize {
    var n: usize = 0;
    for (state, 0..) |*s, i| {
        if (s.status == .idle and s.due.reached(now)) {
            if (n < out.len) {
                s.status = .running;
                switch (s.due) {
                    .wall => |minute| s.last_cron = minute,
                    .mono => {},
                }
                out[n] = i;
                n += 1;
            }
        }
    }
    return out[0..n];
}

test "tick leaves due jobs beyond the output capacity idle for the next tick" {
    var state = [_]JobState{
        .{ .status = .idle, .due = .{ .wall = 10 } },
        .{ .status = .idle, .due = .{ .mono = 10 } },
        .{ .status = .idle, .due = .{ .wall = 10 } },
    };
    var out: [1]usize = undefined;
    const now: Now = .{ .wall = 10, .mono_ms = 10 };
    try std.testing.expectEqualSlices(usize, &.{0}, tick(&state, now, &out));
    try std.testing.expect(state[1].status == .idle);
    try std.testing.expectEqualSlices(usize, &.{1}, tick(&state, now, &out));
    try std.testing.expectEqualSlices(usize, &.{2}, tick(&state, now, &out));
}

/// Apply a job's completion to its local state. `reactive_result` is non-null for
/// reactive jobs or distributed wrappers polling a database-owned schedule.
/// For ordinary cron/interval jobs, the due time is recomputed from `sched`;
/// if there is no future fire (e.g. an impossible cron), the job is retired (`.stopped`).
/// A cron job's next occurrence is the first matching minute after both the wall time it
/// completed at and the minute that last fired (`last_cron`): after a forward step it
/// does not replay the skipped minutes, and after a backward step, even one taken while
/// the handler ran, it does not repeat a minute it already ran.
pub fn completeJob(s: *JobState, sched: schedule.Schedule, reactive_result: ?schedule.Reactive, now: Now) void {
    s.failures = 0; // a successful completion resets the backoff counter
    if (reactive_result) |rr| {
        switch (rr) {
            .stop => {
                s.status = .stopped;
                return;
            },
            .after => |iv| {
                s.due = monoAfter(now, schedule.periodSeconds(iv));
                s.status = .idle;
                return;
            },
        }
    }
    const from: Now = if (s.last_cron) |minute| .{ .wall = @max(now.wall, minute), .mono_ms = now.mono_ms } else now;
    s.due = scheduleDue(sched, from) orelse {
        s.status = .stopped;
        return;
    };
    s.status = .idle;
}

/// How often an idle `.distributed` job re-reads its database-owned schedule.
const distributed_poll_s: i64 = 15;

fn completeRuntimeJob(s: *JobState, job: RuntimeJob, result: ?schedule.Reactive, now: Now) void {
    if (!job.distributed) return completeJob(s, job.schedule, result, now);
    // A `.distributed` job's cadence lives in the database, so `job.schedule` is never
    // read here and no wall-clock due time is produced: the wrapper answers `.stop`
    // (retire) or asks to be polled again (`.after`; a null answer means the same), and
    // the next poll is on the boot clock, never sooner than `distributed_poll_s`. No
    // public seconds-granularity schedule is needed for this internal poll.
    s.failures = 0;
    const delay_s: i64 = switch (result orelse schedule.Reactive{ .after = .{ .minutes = 0 } }) {
        .stop => {
            s.status = .stopped;
            return;
        },
        .after => |iv| schedule.periodSeconds(iv),
    };
    s.due = monoAfter(now, @max(delay_s, distributed_poll_s));
    s.status = .idle;
}

test "distributed idle polling is bounded and stopped jobs retire locally" {
    const H = struct {
        fn handler(_: *Ctx, _: *events.JobEvent) anyerror!void {}
    };
    const jobs = buildJobs(.{.{ .name = "poll", .schedule = schedule.Schedule{ .interval = .hourly }, .distributed = .{}, .handler = H.handler }});
    var state = JobState{ .status = .running, .due = .{ .mono = 0 } };
    completeRuntimeJob(&state, jobs[0], .{ .after = .{ .minutes = 0 } }, .{ .wall = 100, .mono_ms = 7_000 });
    try std.testing.expectEqual(Due{ .mono = 22_000 }, state.due);
    var out: [1]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), tick((&state)[0..1], .{ .wall = 114, .mono_ms = 21_999 }, &out).len);
    // The poll re-arm is on the boot clock: a backward wall step does not delay it.
    try std.testing.expectEqual(@as(usize, 1), tick((&state)[0..1], .{ .wall = 50, .mono_ms = 22_000 }, &out).len);
    completeRuntimeJob(&state, jobs[0], .stop, .{ .wall = 115, .mono_ms = 22_000 });
    try std.testing.expect(state.status == .stopped);

    // A distributed cron job never gets a local wall-clock due time: its next poll is
    // on the boot clock whatever the wrapper answers, never the next cron minute.
    const cron_jobs = buildJobs(.{.{ .name = "cron-poll", .schedule = schedule.Schedule{ .cron = "0 * * * *" }, .distributed = .{}, .handler = H.handler }});
    var cron_state = JobState{ .status = .running, .due = .{ .mono = 0 } };
    completeRuntimeJob(&cron_state, cron_jobs[0], null, .{ .wall = 3_590, .mono_ms = 1_000 });
    try std.testing.expectEqual(Due{ .mono = 16_000 }, cron_state.due);
    completeRuntimeJob(&cron_state, cron_jobs[0], .{ .after = .{ .minutes = 2 } }, .{ .wall = 3_600, .mono_ms = 16_000 });
    try std.testing.expectEqual(Due{ .mono = 136_000 }, cron_state.due);
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
pub fn completeJobError(s: *JobState, now: Now) void {
    s.failures +|= 1;
    s.due = monoAfter(now, retryDelay(s.failures));
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

/// The framework's scheduling wall clock — wall-clock seconds, honoring the dev-only
/// `ZIGBASE_FAKE_NOW` override (see `clock.zig`) so e2e suites can freeze cron math.
fn unixNow(io: std.Io) i64 {
    return clock.nowUnix(io);
}

/// Both scheduling clocks. `mono_ms` is the boot clock (`CLOCK_BOOTTIME` on Linux):
/// monotonic, counting suspended time where the OS can, never stepped and never frozen.
/// It measures the delays; `unixNow` places cron occurrences.
fn readNow(io: std.Io) Now {
    const boot = std.Io.Timestamp.now(io, .boot);
    return .{
        .wall = unixNow(io),
        .mono_ms = @intCast(@divTrunc(boot.nanoseconds, std.time.ns_per_ms)),
    };
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
        const now = readNow(app.io);
        const at_boot: Due = .{ .mono = now.mono_ms };
        for (state, 0..) |*s, i| {
            if (jobs[i].distributed) {
                s.* = .{ .status = .idle, .due = at_boot };
                continue;
            }
            const sched = jobs[i].schedule;
            if (scheduleDue(sched, now)) |due| {
                s.* = .{ .status = .idle, .due = due };
            } else switch (sched) {
                // Reactive jobs have no schedule-derived fire; they intentionally run once at
                // boot (their handler's returned `Reactive` drives every subsequent fire).
                .reactive => s.* = .{ .status = .idle, .due = at_boot },
                // A cron/interval with no future fire (e.g. an impossible cron like Feb 30)
                // must NOT be aliased onto the reactive boot-fire path — that would run the
                // handler at an arbitrary boot time and never on schedule. Retire it and log
                // why, so it isn't a silent no-op.
                else => {
                    std.log.warn("scheduler: job '{s}' has no future fire time (impossible schedule); retiring it without running", .{jobs[i].name});
                    s.* = .{ .status = .stopped, .due = at_boot };
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
            const now = readNow(self.app.io);
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
            const outcome = blk: {
                var measured: if (@import("build_options").query_workbench) @import("query_workbench.zig").Scope else void = undefined;
                if (comptime @import("build_options").query_workbench) {
                    measured = @import("query_workbench.zig").Scope.initJob(self.app.query_workbench, .scheduled_job, job.name);
                    measured.enter();
                }
                defer if (comptime @import("build_options").query_workbench) measured.leave();
                break :blk job.run(&cx, &ev) catch |err| {
                    if (comptime @import("build_options").query_workbench) measured.failed = true;
                    break :blk err;
                };
            };
            if (outcome) |result| {
                // SUCCESS: resume the normal schedule (resets the backoff counter).
                const now = readNow(self.app.io);
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
                const now = readNow(self.app.io);
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

fn at(wall: i64, mono_ms: i64) Now {
    return .{ .wall = wall, .mono_ms = mono_ms };
}

test "tick fires due idle jobs and marks them running (single-flight)" {
    var st = [_]JobState{
        .{ .status = .idle, .due = .{ .wall = 1000 } },
        .{ .status = .idle, .due = .{ .wall = 2000 } },
        .{ .status = .idle, .due = .{ .mono = 500 } },
        .{ .status = .idle, .due = .{ .mono = 501 } },
    };
    var fire_buf: [8]usize = undefined;
    const fired = tick(&st, at(1000, 500), &fire_buf);
    // Job 0's wall instant and job 2's boot-clock deadline are reached; 1 and 3 are not.
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, fired);
    try std.testing.expect(st[0].status == .running and st[2].status == .running);
    try std.testing.expect(st[1].status == .idle and st[3].status == .idle);
}

test "tick does not refire a job that is already running" {
    var st = [_]JobState{.{ .status = .running, .due = .{ .wall = 1000 } }};
    var fire_buf: [8]usize = undefined;
    const fired = tick(&st, at(5000, 5000), &fire_buf);
    try std.testing.expectEqual(@as(usize, 0), fired.len);
}

test "tick skips stopped jobs" {
    var st = [_]JobState{.{ .status = .stopped, .due = .{ .wall = 0 } }};
    var fire_buf: [8]usize = undefined;
    const fired = tick(&st, at(9999, 9999), &fire_buf);
    try std.testing.expectEqual(@as(usize, 0), fired.len);
}

test "completeJob: interval reschedules; reactive uses returned delay; stop retires; invalid cron retires" {
    var s = JobState{ .status = .running, .due = .{ .wall = 1000 } };
    completeJob(&s, .{ .interval = .hourly }, null, at(1000, 40_000));
    try std.testing.expect(s.status == .idle);
    try std.testing.expectEqual(Due{ .mono = 40_000 + 3_600_000 }, s.due);

    var s2 = JobState{ .status = .running, .due = .{ .wall = 0 } };
    completeJob(&s2, .reactive, .{ .after = .{ .minutes = 5 } }, at(2000, 70_000));
    try std.testing.expect(s2.status == .idle);
    try std.testing.expectEqual(Due{ .mono = 70_000 + 300_000 }, s2.due);

    var s3 = JobState{ .status = .running, .due = .{ .wall = 0 } };
    completeJob(&s3, .reactive, .stop, at(2000, 0));
    try std.testing.expect(s3.status == .stopped);

    // A cron occurrence is a wall-clock minute.
    var s5 = JobState{ .status = .running, .due = .{ .wall = 0 } };
    completeJob(&s5, .{ .cron = "* * * * *" }, null, at(1_000_030, 0));
    try std.testing.expectEqual(Due{ .wall = 1_000_080 }, s5.due);

    // An impossible cron has no next fire -> retire the job rather than spin.
    var s4 = JobState{ .status = .running, .due = .{ .wall = 0 } };
    completeJob(&s4, .{ .cron = "0 0 30 2 *" }, null, at(1609470000, 0)); // Feb 30 never occurs
    try std.testing.expect(s4.status == .stopped);
}

test "a backward wall-clock step does not stall interval, reactive or backoff jobs (#493)" {
    // Each job completes at wall 10_000 / boot 50_000 ms; the wall clock is then stepped
    // back 10 s while 500 ms of real time pass.
    const before = at(10_000, 50_000);
    const after_step = at(10_000 - 10, 50_500);
    var worker = JobState{ .status = .running, .due = .{ .wall = 0 } };
    completeJob(&worker, .reactive, .{ .after = .{ .minutes = 0 } }, before); // a durable worker's re-arm
    var interval = JobState{ .status = .running, .due = .{ .wall = 0 } };
    completeJob(&interval, .{ .interval = .{ .minutes = 1 } }, null, before);
    var backoff = JobState{ .status = .running, .due = .{ .wall = 0 } };
    completeJobError(&backoff, before);
    var st = [_]JobState{ worker, interval, backoff };
    var fire_buf: [8]usize = undefined;
    // The re-armed worker fires on the next tick despite the wall clock going back.
    try std.testing.expectEqualSlices(usize, &.{0}, tick(&st, after_step, &fire_buf));
    // The 1 s backoff and the 60 s interval fire after 1 s and 60 s of real time, not 10 s later.
    try std.testing.expectEqualSlices(usize, &.{2}, tick(&st, at(10_000 - 9, 51_000), &fire_buf));
    try std.testing.expectEqualSlices(usize, &.{}, tick(&st, at(10_000 + 49, 109_999), &fire_buf));
    try std.testing.expectEqualSlices(usize, &.{1}, tick(&st, at(10_000 + 50, 110_000), &fire_buf));
}

test "a forward wall-clock step neither fires interval jobs early nor bunches them (#493)" {
    var st = [_]JobState{
        .{ .status = .running, .due = .{ .wall = 0 } },
        .{ .status = .running, .due = .{ .wall = 0 } },
    };
    completeJob(&st[0], .{ .interval = .hourly }, null, at(10_000, 50_000));
    completeJob(&st[1], .reactive, .{ .after = .{ .minutes = 5 } }, at(10_000, 50_000));
    var fire_buf: [8]usize = undefined;
    // The wall clock jumps two hours ahead after one real second: nothing is due.
    try std.testing.expectEqual(@as(usize, 0), tick(&st, at(10_000 + 7_200, 51_000), &fire_buf).len);
    // Each fires once its own delay has really elapsed, once, and re-arms one period on.
    try std.testing.expectEqualSlices(usize, &.{1}, tick(&st, at(17_500, 350_000), &fire_buf));
    try std.testing.expectEqualSlices(usize, &.{0}, tick(&st, at(20_800, 3_650_000), &fire_buf));
    completeJob(&st[0], .{ .interval = .hourly }, null, at(20_800, 3_650_000));
    try std.testing.expectEqual(@as(usize, 0), tick(&st, at(20_800 + 86_400, 3_651_000), &fire_buf).len);
    try std.testing.expectEqual(Due{ .mono = 3_650_000 + 3_600_000 }, st[0].due);
}

test "cron across wall-clock steps: missed minutes fire once, a ran minute never repeats (#493)" {
    const every_minute = schedule.Schedule{ .cron = "* * * * *" };
    var st = [_]JobState{.{ .status = .idle, .due = .{ .wall = 60_060 } }};
    var fire_buf: [8]usize = undefined;
    // Forward step of ten minutes past the due minute: one late fire, not ten.
    try std.testing.expectEqualSlices(usize, &.{0}, tick(&st, at(60_660, 1_000), &fire_buf));
    completeJob(&st[0], every_minute, null, at(60_660, 1_100));
    // The next occurrence is the first minute after the stepped wall time.
    try std.testing.expectEqual(Due{ .wall = 60_720 }, st[0].due);
    try std.testing.expectEqual(@as(usize, 0), tick(&st, at(60_661, 1_500), &fire_buf).len);
    // It runs the 60_720 minute, then the wall clock steps back 10 s: that minute is
    // not run a second time; the job waits for the wall clock to reach 60_780.
    try std.testing.expectEqualSlices(usize, &.{0}, tick(&st, at(60_720, 60_000), &fire_buf));
    completeJob(&st[0], every_minute, null, at(60_720, 60_100));
    try std.testing.expectEqual(@as(usize, 0), tick(&st, at(60_710, 61_000), &fire_buf).len);
    try std.testing.expectEqual(@as(usize, 0), tick(&st, at(60_779, 130_000), &fire_buf).len);
    try std.testing.expectEqualSlices(usize, &.{0}, tick(&st, at(60_780, 131_000), &fire_buf));
    // The step can also land while the handler runs: the 60_780 minute fires, the clock
    // goes back 10 s, and the handler completes at 60_773. The next occurrence is still
    // 60_840, not 60_780 again.
    completeJob(&st[0], every_minute, null, at(60_773, 131_500));
    try std.testing.expectEqual(Due{ .wall = 60_840 }, st[0].due);
    try std.testing.expectEqual(@as(usize, 0), tick(&st, at(60_780, 138_000), &fire_buf).len);
    try std.testing.expectEqual(@as(usize, 0), tick(&st, at(60_839, 197_000), &fire_buf).len);
    try std.testing.expectEqualSlices(usize, &.{0}, tick(&st, at(60_840, 198_000), &fire_buf));
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
    var s = JobState{ .status = .running, .due = .{ .wall = 0 }, .failures = 0 };
    completeJobError(&s, at(1000, 0));
    try std.testing.expect(s.status == .idle and s.failures == 1);
    try std.testing.expectEqual(Due{ .mono = 1_000 }, s.due);
    completeJobError(&s, at(1000, 0));
    try std.testing.expect(s.failures == 2);
    try std.testing.expectEqual(Due{ .mono = 2_000 }, s.due);
    completeJobError(&s, at(1000, 0));
    try std.testing.expect(s.failures == 3);
    try std.testing.expectEqual(Due{ .mono = 4_000 }, s.due);
    // a subsequent SUCCESS resets failures and schedules normally
    completeJob(&s, .{ .interval = .hourly }, null, at(2000, 9_000));
    try std.testing.expect(s.status == .idle and s.failures == 0);
    try std.testing.expectEqual(Due{ .mono = 9_000 + 3_600_000 }, s.due);
}

test "reactive job that errors retries with backoff (not retired)" {
    var s = JobState{ .status = .running, .due = .{ .wall = 0 }, .failures = 0 };
    completeJobError(&s, at(5000, 8_000)); // an errored reactive job is NOT stopped; it backs off
    try std.testing.expect(s.status == .idle and s.failures == 1);
    try std.testing.expectEqual(Due{ .mono = 9_000 }, s.due);
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
        .{ .name = "hourly", .schedule = schedule.Schedule{ .interval = .hourly }, .handler = H.noop },
    });
    var app: App = undefined;
    app.io = std.testing.io;
    app.allocator = std.testing.allocator;
    const before = readNow(app.io);
    var sched = try Scheduler.initSized(std.testing.allocator, &app, jobs, 1, min_job_stack_size);
    defer sched.deinit();
    const now = readNow(app.io);
    try std.testing.expect(sched.state[0].status == .idle and sched.state[0].due.wall > now.wall);
    try std.testing.expect(sched.state[1].status == .idle and sched.state[1].due.reached(now));
    try std.testing.expect(sched.state[2].status == .stopped);
    // An interval's first fire is one period on the boot clock.
    const first = sched.state[3].due.mono;
    try std.testing.expect(first >= before.mono_ms + 3_600_000 and first <= now.mono_ms + 3_600_000);
}

test "Scheduler keeps re-arming a reactive job across a backward wall-clock step (#493)" {
    // The durable-worker shape: re-arm immediately, forever. Before #493 its due time was
    // a wall second, so stepping the clock back 10 s silenced it for 10 s.
    const Counter = struct {
        var n: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn run(ctx: *Ctx, ev: *events.JobEvent) anyerror!schedule.Reactive {
            _ = ctx;
            _ = ev;
            _ = n.fetchAdd(1, .monotonic);
            return .{ .after = .{ .minutes = 0 } };
        }
    };
    Counter.n.store(0, .monotonic);
    if (clock.frozenUnix() != null) return error.SkipZigTest; // a frozen wall clock cannot step
    defer clock.stepForTest(0);
    const jobs = buildJobs(.{
        .{ .name = "worker", .schedule = schedule.Schedule.reactive, .handler = Counter.run },
    });
    var app: App = undefined;
    app.io = std.testing.io;
    app.allocator = std.testing.allocator;
    app.pool = undefined;
    app.dispatch = null;
    app.scheduler = null;
    app.submit_fn = null;
    if (comptime @import("build_options").query_workbench) app.query_workbench = null;

    var sched = try Scheduler.init(std.testing.allocator, &app, jobs, 1);
    defer sched.deinit();
    try sched.start();
    defer sched.stop();
    var waited: usize = 0;
    while (Counter.n.load(.monotonic) == 0 and waited < 300) : (waited += 1) {
        app.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(Counter.n.load(.monotonic) > 0);
    // Step the clock while holding the scheduler lock with the job idle, i.e. after its
    // completion read the clock and set its due time, and before the loop's next tick.
    // Before #493 that due time was the pre-step wall second, which the stepped clock
    // does not reach for 10 s.
    var at_step: u32 = 0;
    waited = 0;
    while (waited < 300) : (waited += 1) {
        sched.lock();
        const idle = sched.state[0].status == .idle;
        if (idle) {
            clock.stepForTest(-10);
            at_step = Counter.n.load(.monotonic);
        }
        sched.unlock();
        if (idle) break;
        app.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(at_step > 0);
    // The loop ticks every 500 ms; allow three seconds (well under the 10 s step) for two
    // more runs.
    waited = 0;
    while (Counter.n.load(.monotonic) < at_step + 2 and waited < 300) : (waited += 1) {
        app.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(Counter.n.load(.monotonic) >= at_step + 2);
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
    if (comptime @import("build_options").query_workbench) app.query_workbench = null;

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
    if (comptime @import("build_options").query_workbench) app.query_workbench = null;

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
