# Extensibility — Scheduler & Job Pool (10c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let consumers register background jobs via comptime config in three scheduling modes — 5-field `cron`, `interval` presets/minutes, and `reactive` (return value drives next delay) — executed on a comptime-sized worker pool, with `app.submit(...)` to offload ad-hoc background work; default behavior (no jobs) unchanged.

**Architecture:** A single scheduler thread (`std.Thread.spawn`) owns a comptime-sized `[N]JobState` array and computes timing; when a job is due it submits to a shared, spinlock-guarded queue drained by `pool_size` worker threads. Per-job single-flight (a job never runs concurrently with itself). Reactive jobs' next fire is computed from the handler's returned delay on completion; cron/interval jobs' next fire is computed from the schedule. The pure pieces (cron parser / `nextFire` / the tick decision) are injectable-clock unit-tested; the threaded runtime is integration-tested.

**Tech Stack (validated against this Zig 0.16):** `std.Thread.spawn(.{}, fn, .{args})` + `.join()`; sleep via `io.sleep(std.Io.Duration.fromMilliseconds(n), .awake)` (`.awake` = monotonic clock); wall-clock unix-now via `std.Io.Timestamp.now(io, .real).nanoseconds` ÷ `std.time.ns_per_s`; `std.atomic.Value(bool)` for the shutdown flag; `std.atomic.Mutex` spinlock (as in `db.zig`) for the queue + state. The SQLite pool is `SQLITE_OPEN_FULLMUTEX` (thread-safe), so job DB access from worker threads is safe.

**Build/test rule (every task):** Run BOTH `mise exec zig@0.16.0 -- zig build` AND `mise exec zig@0.16.0 -- zig build test --summary all`. Baseline on branch `extensibility-framework`: **225 Zig tests**, binary EXIT 0, **11 Playwright tests**, `examples/blog` builds. All stay green; `App(.{})` (no jobs) must be byte-for-byte unchanged.

**Prerequisite:** 10a + 10b complete on this branch. Existing surfaces this builds on (verbatim):
- `framework.App(comptime cfg)`: comptime `dispatch` block validating cfg keys against 9 allowed (`hooks/onError/routes/onAuth/onFileServe/onFileUpload/onBootstrap/onBeforeServe/onBeforeTerminate`); `serveImpl(allocator, io, cfg, dispatch)` builds `app` (migrations already run), emits `on_bootstrap`/`on_before_serve`, then `try srv.listen();` (which calls `zap.start(...)` and blocks), with a `defer` `on_before_terminate`.
- `app.zig App`: has `allocator: std.mem.Allocator, io: std.Io, pool: *db.Pool, ... , dispatch: ?*const events.Dispatch`. (app.zig already inline-imports events.zig for the dispatch field — circular import with events.zig is fine in Zig.)
- `events.zig` is imported by app.zig and imports app.zig (circular OK). It holds the event/handler types.
- `db.Pool`: `acquireWriter()`/`releaseWriter()` (spinlock), `openReader() !db.Db`.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/schedule.zig` (NEW) | `Interval`, `Schedule`, `Reactive` types; `periodSeconds(Interval)`; a pure 5-field cron parser; `nextFire(Schedule, after_unix) ?i64`. No threads, no I/O — fully unit-tested with fixed timestamps. |
| `src/events.zig` (MOD) | Add `JobEvent { app: *App, name: []const u8 }` and `JobTask = *const fn(*JobEvent) anyerror!void` (shared by cron jobs and `app.submit`). |
| `src/scheduler.zig` (NEW) | `RuntimeJob`, `buildJobs(comptime specs)` comptime assembler (wraps void/reactive handlers into one `fn(*JobEvent) anyerror!?Reactive`); `JobState` + the pure `tick` decision (single-flight); the `Scheduler` runtime (scheduler thread + worker pool + queue + `start`/`stop` + `submit`). |
| `src/app.zig` (MOD) | Add `scheduler: ?*anyopaque` + `submit_fn` + `pub fn submit(...)` (type-erased to avoid an app→scheduler comptime cycle). |
| `src/framework.zig` (MOD) | Widen the cfg-key whitelist to add `cron` + `jobs`; `App(cfg)` exposes `pub const jobs` (built via `buildJobs`) + `pub const job_pool_size`; `serveImpl` starts the scheduler before `listen()` and stops it on shutdown. |
| `examples/blog/src/main.zig` (MOD) | Register one interval job (the consumer-facing scheduler example). |
| `src/root.zig` (MOD) | Re-export `schedule`/`JobEvent`; reference new files in the `test {}` block. |

---

## Task 1: `src/schedule.zig` — types, cron parser, `nextFire` (pure)

The testable core. No threads, no I/O. Heavy unit tests with fixed timestamps.

**Files:** Create `src/schedule.zig`; reference it in `src/root.zig` test block; Test: in `src/schedule.zig`.

- [ ] **Step 1: Write failing tests (interval + cron + reactive)**

Create `src/schedule.zig`:
```zig
const std = @import("std");

test "periodSeconds maps interval presets and minutes" {
    try std.testing.expectEqual(@as(i64, 3600), periodSeconds(.hourly));
    try std.testing.expectEqual(@as(i64, 86400), periodSeconds(.daily));
    try std.testing.expectEqual(@as(i64, 7 * 86400), periodSeconds(.weekly));
    try std.testing.expectEqual(@as(i64, 15 * 60), periodSeconds(.{ .minutes = 15 }));
}

test "nextFire interval = after + period" {
    try std.testing.expectEqual(@as(?i64, 1000 + 3600), nextFire(.{ .interval = .hourly }, 1000));
    try std.testing.expectEqual(@as(?i64, 1000 + 900), nextFire(.{ .interval = .{ .minutes = 15 } }, 1000));
}

test "nextFire reactive returns null (driven by the handler's return)" {
    try std.testing.expectEqual(@as(?i64, null), nextFire(.reactive, 1000));
}

test "nextFire cron: every minute" {
    // '* * * * *' -> the next whole minute strictly after `after`.
    // after = 1000s = 16m40s past epoch; next minute boundary strictly after = 1020 (17m).
    try std.testing.expectEqual(@as(?i64, 1020), nextFire(.{ .cron = "* * * * *" }, 1000));
}

test "cron field matching: lists, ranges, steps, wildcard" {
    try std.testing.expect(cronFieldMatches("*", 5, 0, 59));
    try std.testing.expect(cronFieldMatches("5", 5, 0, 59));
    try std.testing.expect(!cronFieldMatches("5", 6, 0, 59));
    try std.testing.expect(cronFieldMatches("1,5,9", 5, 0, 59));
    try std.testing.expect(cronFieldMatches("10-20", 15, 0, 59));
    try std.testing.expect(!cronFieldMatches("10-20", 21, 0, 59));
    try std.testing.expect(cronFieldMatches("*/15", 30, 0, 59));
    try std.testing.expect(!cronFieldMatches("*/15", 31, 0, 59));
}

test "nextFire cron: daily at 03:00 UTC" {
    // Pick an `after` just before a 03:00 boundary and assert the next fire is that 03:00.
    // 2021-01-01 02:59:00 UTC = 1609469940 ; next "0 3 * * *" = 2021-01-01 03:00:00 = 1609470000.
    try std.testing.expectEqual(@as(?i64, 1609470000), nextFire(.{ .cron = "0 3 * * *" }, 1609469940));
}
```

- [ ] **Step 2: Run → confirm FAIL**

First add `_ = @import("schedule.zig");` to `src/root.zig`'s `test {}` block (so these run). Run:
`mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -20`
Expected: FAIL — undefined symbols.

- [ ] **Step 3: Implement the types + parser + nextFire**

Prepend to `src/schedule.zig`:
```zig
pub const Interval = union(enum) { weekly, daily, hourly, minutes: u64 };
pub const Schedule = union(enum) { cron: []const u8, interval: Interval, reactive };
pub const Reactive = union(enum) { after: Interval, stop };

pub fn periodSeconds(iv: Interval) i64 {
    return switch (iv) {
        .weekly => 7 * 86400,
        .daily => 86400,
        .hourly => 3600,
        .minutes => |m| @as(i64, @intCast(m)) * 60,
    };
}

/// Does a single cron field (`min`..`max`) match `value`? Supports `*`, `a`, `a,b,c`,
/// `a-b`, and `*/n`. (Names like JAN/MON are NOT supported — numeric only.)
pub fn cronFieldMatches(field: []const u8, value: u32, min: u32, max: u32) bool {
    _ = min;
    _ = max;
    var it = std.mem.splitScalar(u8, field, ',');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "*")) return true;
        if (std.mem.startsWith(u8, part, "*/")) {
            const step = std.fmt.parseInt(u32, part[2..], 10) catch continue;
            if (step != 0 and value % step == 0) return true;
            continue;
        }
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const lo = std.fmt.parseInt(u32, part[0..dash], 10) catch continue;
            const hi = std.fmt.parseInt(u32, part[dash + 1 ..], 10) catch continue;
            if (value >= lo and value <= hi) return true;
            continue;
        }
        const n = std.fmt.parseInt(u32, part, 10) catch continue;
        if (n == value) return true;
    }
    return false;
}

/// UTC civil time decomposed from a unix timestamp (days/seconds since epoch).
const Civil = struct { minute: u32, hour: u32, dom: u32, month: u32, dow: u32 };

fn civilFromUnix(t: i64) Civil {
    const days = @divFloor(t, 86400);
    const secs_of_day = @as(u32, @intCast(t - days * 86400));
    const minute = (secs_of_day / 60) % 60;
    const hour = secs_of_day / 3600;
    // dow: 1970-01-01 was a Thursday (=4). 0=Sunday..6=Saturday.
    const dow = @as(u32, @intCast(@mod(days + 4, 7)));
    // civil date from days (Howard Hinnant's algorithm).
    var z = days + 719468;
    const era = @divFloor((if (z >= 0) z else z - 146096), 146097);
    const doe = @as(u64, @intCast(z - era * 146097));
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    _ = y;
    return .{ .minute = minute, .hour = hour, .dom = @intCast(d), .month = @intCast(m), .dow = dow };
}

fn cronMatchesAt(expr: []const u8, t: i64) bool {
    var it = std.mem.splitScalar(u8, expr, ' ');
    const f_min = it.next() orelse return false;
    const f_hour = it.next() orelse return false;
    const f_dom = it.next() orelse return false;
    const f_mon = it.next() orelse return false;
    const f_dow = it.next() orelse return false;
    if (it.next() != null) return false; // exactly 5 fields
    const c = civilFromUnix(t);
    return cronFieldMatches(f_min, c.minute, 0, 59) and
        cronFieldMatches(f_hour, c.hour, 0, 23) and
        cronFieldMatches(f_dom, c.dom, 1, 31) and
        cronFieldMatches(f_mon, c.month, 1, 12) and
        cronFieldMatches(f_dow, c.dow, 0, 6);
}

/// The next fire time strictly after `after_unix`:
/// - cron: the next whole minute (UTC) matching the expression, searched up to ~370 days; null if none/invalid.
/// - interval: `after_unix + periodSeconds`.
/// - reactive: null (the handler's returned delay drives the next fire).
pub fn nextFire(sched: Schedule, after_unix: i64) ?i64 {
    switch (sched) {
        .interval => |iv| return after_unix + periodSeconds(iv),
        .reactive => return null,
        .cron => |expr| {
            // Start at the next whole minute strictly after `after_unix`.
            var t = (@divFloor(after_unix, 60) + 1) * 60;
            const limit = t + 370 * 86400;
            while (t <= limit) : (t += 60) {
                if (cronMatchesAt(expr, t)) return t;
            }
            return null;
        },
    }
}
```
> The cron search is minute-by-minute up to ~370 days — simple and correct (worst case ~533k iterations of pure integer work, only run once per fire). The civil-date algorithm is Hinnant's well-known `days_from_civil` inverse. Adjust if a test value is off (verify the two cron timestamp tests with `date -u -d @<ts>`); the tests are the oracle.

- [ ] **Step 4: Run → all pass; count up from 225.** `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6`

- [ ] **Step 5: Build + commit**
```sh
mise exec zig@0.16.0 -- zig build
git add src/schedule.zig src/root.zig
git commit -m "feat(framework): schedule types + cron parser + nextFire (pure)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `JobEvent`/`JobTask` + `RuntimeJob` + `buildJobs` (comptime assembly)

Define the job event + the comptime assembler that wraps void (cron/interval) and reactive handlers into one uniform runtime signature, with `@compileError` validation.

**Files:** Modify `src/events.zig` (JobEvent/JobTask); Create `src/scheduler.zig` (RuntimeJob + buildJobs); reference scheduler.zig in root.zig test block; Test: in `src/scheduler.zig`.

- [ ] **Step 1: Add JobEvent/JobTask to events.zig**

In `src/events.zig` (near the other event types):
```zig
pub const JobEvent = struct { app: *App, name: []const u8 };
pub const JobTask = *const fn (ev: *JobEvent) anyerror!void;
```

- [ ] **Step 2: Write failing tests in src/scheduler.zig**
```zig
const std = @import("std");
const schedule = @import("schedule.zig");
const events = @import("events.zig");

test "buildJobs assembles cron/interval/reactive into a uniform table" {
    const H = struct {
        fn cleanup(ev: *events.JobEvent) anyerror!void { _ = ev; }
        fn backoff(ev: *events.JobEvent) anyerror!schedule.Reactive { _ = ev; return .{ .after = .{ .minutes = 5 } }; }
    };
    const jobs = buildJobs(.{
        .{ .name = "cleanup", .schedule = schedule.Schedule{ .cron = "0 3 * * *" }, .handler = H.cleanup },
        .{ .name = "poll", .schedule = schedule.Schedule{ .interval = .hourly }, .handler = H.cleanup },
        .{ .name = "backoff", .schedule = schedule.Schedule.reactive, .handler = H.backoff },
    });
    try std.testing.expectEqual(@as(usize, 3), jobs.len);
    try std.testing.expectEqualStrings("cleanup", jobs[0].name);
    try std.testing.expect(jobs[0].schedule == .cron);
    try std.testing.expect(jobs[2].schedule == .reactive);

    // The reactive job's wrapped run returns the handler's Reactive; non-reactive returns null.
    var app: events.JobEvent = .{ .app = undefined, .name = "x" };
    const r2 = try jobs[2].run(&app);
    try std.testing.expect(r2 != null and r2.?.after.minutes == 5);
    const r0 = try jobs[0].run(&app);
    try std.testing.expect(r0 == null);
}
```

- [ ] **Step 3: Run → FAIL** (add `_ = @import("scheduler.zig");` to root.zig test block first). `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -20`

- [ ] **Step 4: Implement RuntimeJob + buildJobs**

Prepend to `src/scheduler.zig`:
```zig
const App = @import("app.zig").App;

/// A registered job after comptime assembly. `run` is a uniform wrapper: it returns
/// `?schedule.Reactive` — `null` for cron/interval jobs (next fire from `schedule`),
/// or the handler's returned `Reactive` for reactive jobs.
pub const RuntimeJob = struct {
    name: []const u8,
    schedule: schedule.Schedule,
    run: *const fn (ev: *events.JobEvent) anyerror!?schedule.Reactive,
};

fn isReactive(comptime s: schedule.Schedule) bool {
    return s == .reactive;
}

/// Assemble a comptime tuple of job specs `.{ .name, .schedule, .handler }` into a
/// runtime table. For `.reactive` schedules the handler must be
/// `fn(*JobEvent) anyerror!schedule.Reactive`; otherwise `fn(*JobEvent) anyerror!void`.
/// The wrapper unifies both to `anyerror!?Reactive`.
pub fn buildJobs(comptime specs: anytype) []const RuntimeJob {
    comptime {
        const fields = std.meta.fields(@TypeOf(specs));
        var table: [fields.len]RuntimeJob = undefined;
        for (fields, 0..) |f, i| {
            const s = @field(specs, f.name);
            if (!@hasField(@TypeOf(s), "name")) @compileError("job spec missing '.name'");
            if (!@hasField(@TypeOf(s), "schedule")) @compileError("job spec missing '.schedule'");
            if (!@hasField(@TypeOf(s), "handler")) @compileError("job spec missing '.handler'");
            const sched: schedule.Schedule = s.schedule;
            const handler = s.handler;
            const reactive = isReactive(sched);
            const Wrap = struct {
                fn run(ev: *events.JobEvent) anyerror!?schedule.Reactive {
                    if (reactive) {
                        return try handler(ev);
                    } else {
                        try handler(ev);
                        return null;
                    }
                }
            };
            table[i] = .{ .name = s.name, .schedule = sched, .run = &Wrap.run };
        }
        const final = table;
        return &final;
    }
}
```
> The `buildJobs` static-lifetime return: if `const final = table; return &final;` errors with "function called at runtime cannot return value at comptime" (it did for `buildRoutes`), use the same `Holder` struct-namespace-const idiom that `events.buildRoutes` uses (read events.zig `buildRoutes` and mirror it). The per-job `Wrap` struct generates a distinct wrapper fn per spec at comptime (capturing `handler`/`reactive`), so each `run` calls the right handler. The tests are the oracle (3 jobs; reactive returns its Reactive, others null).

- [ ] **Step 5: Run → pass; count up. Build + commit**
```sh
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec zig@0.16.0 -- zig build
git add src/events.zig src/scheduler.zig src/root.zig
git commit -m "feat(framework): JobEvent + buildJobs comptime assembler (cron/interval/reactive)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `JobState` + the pure single-flight `tick` decision

The scheduling decision as a pure function: given per-job state + `now`, return which jobs to fire and the updated state — single-flight, drift-aware. No threads.

**Files:** Modify `src/scheduler.zig`; Test: in `src/scheduler.zig`.

- [ ] **Step 1: Write failing tests**
```zig
test "tick fires due idle jobs and marks them running (single-flight)" {
    // two interval jobs, both due at now=1000
    var st = [_]JobState{
        .{ .status = .idle, .next_fire = 1000 },
        .{ .status = .idle, .next_fire = 2000 },
    };
    var fire_buf: [8]usize = undefined;
    const fired = tick(&st, 1000, &fire_buf);
    try std.testing.expectEqual(@as(usize, 1), fired.len); // only job 0 is due
    try std.testing.expectEqual(@as(usize, 0), fired[0]);
    try std.testing.expect(st[0].status == .running); // marked running (single-flight)
    try std.testing.expect(st[1].status == .idle);
}

test "tick does not refire a job that is already running" {
    var st = [_]JobState{.{ .status = .running, .next_fire = 1000 }};
    var fire_buf: [8]usize = undefined;
    const fired = tick(&st, 5000, &fire_buf);
    try std.testing.expectEqual(@as(usize, 0), fired.len);
}

test "completeJob: cron/interval recomputes next_fire from schedule; reactive uses the returned delay; stop retires" {
    var s = JobState{ .status = .running, .next_fire = 1000 };
    completeJob(&s, .{ .interval = .hourly }, null, 1000);
    try std.testing.expect(s.status == .idle and s.next_fire == 1000 + 3600);

    var s2 = JobState{ .status = .running, .next_fire = 0 };
    completeJob(&s2, .reactive, .{ .after = .{ .minutes = 5 } }, 2000);
    try std.testing.expect(s2.status == .idle and s2.next_fire == 2000 + 300);

    var s3 = JobState{ .status = .running, .next_fire = 0 };
    completeJob(&s3, .reactive, .stop, 2000);
    try std.testing.expect(s3.status == .stopped);
}
```

- [ ] **Step 2: Run → FAIL.** `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -20`

- [ ] **Step 3: Implement JobState + tick + completeJob**

Add to `src/scheduler.zig`:
```zig
pub const JobState = struct {
    status: enum { idle, running, stopped },
    next_fire: i64, // unix seconds; meaningful when status == .idle
};

/// Pure decision: append the indices of jobs that are `.idle` AND due (`next_fire <= now`)
/// to `out`, marking each `.running` (single-flight). Returns the filled slice of `out`.
pub fn tick(state: []JobState, now: i64, out: []usize) []usize {
    var n: usize = 0;
    for (state, 0..) |*s, i| {
        if (s.status == .idle and s.next_fire <= now) {
            s.status = .running;
            if (n < out.len) {
                out[n] = i;
                n += 1;
            }
        }
    }
    return out[0..n];
}

/// Apply a job's completion to its state. `reactive_result` is non-null only for reactive
/// jobs (the handler's return). For cron/interval, next_fire is recomputed from `sched`.
pub fn completeJob(s: *JobState, sched: schedule.Schedule, reactive_result: ?schedule.Reactive, now: i64) void {
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
    // cron/interval: next fire from the schedule (strictly after now).
    s.next_fire = schedule.nextFire(sched, now) orelse {
        s.status = .stopped; // no future fire (e.g. invalid cron) -> retire
        return;
    };
    s.status = .idle;
}
```

- [ ] **Step 4: Run → pass. Build + commit**
```sh
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec zig@0.16.0 -- zig build
git add src/scheduler.zig
git commit -m "feat(framework): JobState single-flight tick + completeJob (pure)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: The `Scheduler` runtime (threads + pool + queue)

Spawn the scheduler thread + worker pool; a spinlock-guarded queue; `io.sleep` tick loop; clean `start`/`stop`. Integration-tested with real threads + a fast reactive job.

**Files:** Modify `src/scheduler.zig`; Test: in `src/scheduler.zig`.

- [ ] **Step 1: Write the failing integration test**
```zig
test "Scheduler runs a due reactive job then stops cleanly" {
    const Counter = struct {
        var n: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn run(ev: *events.JobEvent) anyerror!schedule.Reactive {
            _ = ev;
            _ = n.fetchAdd(1, .monotonic);
            return .stop; // run exactly once
        }
    };
    Counter.n.store(0, .monotonic);
    const jobs = buildJobs(.{
        .{ .name = "once", .schedule = schedule.Schedule.reactive, .handler = Counter.run },
    });
    var app = makeTestApp(); // minimal App with .io/.allocator set; see note
    var sched = try Scheduler.init(std.testing.allocator, &app, jobs, 2);
    defer sched.deinit();
    // reactive jobs start due immediately (next_fire = 0). Start, wait for the run, stop.
    try sched.start();
    // poll up to ~2s for the job to have run
    var waited: usize = 0;
    while (Counter.n.load(.monotonic) == 0 and waited < 200) : (waited += 1) {
        app.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    sched.stop();
    try std.testing.expectEqual(@as(u32, 1), Counter.n.load(.monotonic));
}
```
> `makeTestApp()`: construct a minimal `App` with `.allocator = std.testing.allocator`, `.io = std.testing.io`, `.pool = undefined` (the test job doesn't touch the DB). Mirror how other tests build a throwaway App (e.g. data.zig / records_hooks_test.zig). `std.testing.io` is the test Io value (validated to support `io.sleep` from a spawned thread). If `std.testing.io` does NOT support sleep in the test runner, inject the real io another way OR gate this test behind a build flag — but first TRY `std.testing.io`; the sleep-from-thread primitive was validated to work with the process Io.

- [ ] **Step 2: Run → FAIL** (Scheduler undefined). `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -20`

- [ ] **Step 3: Implement the Scheduler**

Add to `src/scheduler.zig`:
```zig
const Thread = std.Thread;

fn unixNow(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    app: *App,
    jobs: []const RuntimeJob,
    pool_size: usize,
    state: []JobState, // length == jobs.len
    // queue of job indices ready to run (capacity == jobs.len; a job is enqueued at most once due to single-flight)
    queue: []usize,
    q_head: usize = 0,
    q_len: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sched_thread: ?Thread = null,
    workers: []Thread = &.{},

    pub fn init(allocator: std.mem.Allocator, app: *App, jobs: []const RuntimeJob, pool_size: usize) !Scheduler {
        const state = try allocator.alloc(JobState, jobs.len);
        errdefer allocator.free(state);
        const now = unixNow(app.io);
        for (state, 0..) |*s, i| {
            // reactive jobs start immediately; cron/interval start at their first scheduled fire.
            s.* = .{ .status = .idle, .next_fire = schedule.nextFire(jobs[i].schedule, now) orelse now };
        }
        const queue = try allocator.alloc(usize, jobs.len);
        errdefer allocator.free(queue);
        return .{ .allocator = allocator, .app = app, .jobs = jobs, .pool_size = pool_size, .state = state, .queue = queue };
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

    fn enqueue(self: *Scheduler, idx: usize) void {
        // caller holds lock
        if (self.q_len < self.queue.len) {
            self.queue[(self.q_head + self.q_len) % self.queue.len] = idx;
            self.q_len += 1;
        }
    }
    fn dequeue(self: *Scheduler) ?usize {
        // caller holds lock
        if (self.q_len == 0) return null;
        const idx = self.queue[self.q_head];
        self.q_head = (self.q_head + 1) % self.queue.len;
        self.q_len -= 1;
        return idx;
    }

    pub fn start(self: *Scheduler) !void {
        // wire app.submit
        self.app.scheduler = self;
        self.app.submit_fn = &submitThunk;
        self.workers = try self.allocator.alloc(Thread, self.pool_size);
        var spawned: usize = 0;
        errdefer {
            self.shutdown.store(true, .release);
            for (self.workers[0..spawned]) |t| t.join();
        }
        for (self.workers) |*t| {
            t.* = try Thread.spawn(.{}, workerLoop, .{self});
            spawned += 1;
        }
        self.sched_thread = try Thread.spawn(.{}, schedulerLoop, .{self});
    }

    pub fn stop(self: *Scheduler) void {
        self.shutdown.store(true, .release);
        if (self.sched_thread) |t| t.join();
        self.sched_thread = null;
        for (self.workers) |t| t.join();
        self.app.scheduler = null;
        self.app.submit_fn = null;
    }

    fn schedulerLoop(self: *Scheduler) void {
        var fire_buf: [256]usize = undefined;
        while (!self.shutdown.load(.acquire)) {
            const now = unixNow(self.app.io);
            self.lock();
            const fired = tick(self.state, now, fire_buf[0..@min(fire_buf.len, self.state.len)]);
            for (fired) |idx| self.enqueue(idx);
            self.unlock();
            // tick ~ every 500ms (responsive shutdown; sub-minute cron granularity is fine)
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
            const result = job.run(&ev) catch |e| blk: {
                var err_ev = events.ErrorEvent{ .app = self.app, .ctx = null, .err = e, .phase = .cron, .message = @errorName(e) };
                events.dispatchError(self.app, self.app.dispatch, &err_ev);
                break :blk null; // treat as non-reactive completion -> reschedule per schedule
            };
            const now = unixNow(self.app.io);
            self.lock();
            completeJob(&self.state[idx], job.schedule, result, now);
            self.unlock();
        }
    }

    // ---- app.submit support (ad-hoc background tasks) ----
    fn submitThunk(ctx: *anyopaque, name: []const u8, task: events.JobTask) anyerror!void {
        const self: *Scheduler = @ptrCast(@alignCast(ctx));
        // Run the ad-hoc task on the pool by spawning a one-shot worker is overkill; instead
        // push onto a small ad-hoc queue drained by the same workers. For v0.1 simplicity,
        // run it inline on a freshly spawned detached thread bounded by the pool is avoided;
        // we enqueue a synthetic job. SIMPLEST correct approach: spawn a detached thread.
        const Holder = struct {
            fn go(a: *App, n: []const u8, t: events.JobTask) void {
                var ev = events.JobEvent{ .app = a, .name = n };
                t(&ev) catch |e| {
                    var err_ev = events.ErrorEvent{ .app = a, .ctx = null, .err = e, .phase = .job, .message = @errorName(e) };
                    events.dispatchError(a, a.dispatch, &err_ev);
                };
            }
        };
        const th = try Thread.spawn(.{}, Holder.go, .{ self.app, name, task });
        th.detach();
    }
};
```
> **`app.submit` simplification:** spawning a detached thread per `submit` is the simplest correct v0.1 implementation (no shared-queue lifetime concerns; bounded in practice by call rate). It does NOT honor `pool_size` for ad-hoc tasks — document that as a known v0.1 limitation (cron jobs DO use the bounded pool). If you prefer pool-bounded ad-hoc tasks, push onto the same `queue` with a side-list of `JobTask`s — but that complicates the index-based queue; the detached-thread form is acceptable and clearly documented.
> **The integration test** relies on reactive jobs being due at start (`nextFire(.reactive, now)` returns null → `orelse now`, so `next_fire = now`, immediately due). Confirm `init` sets that.

- [ ] **Step 4: Run the integration test + full suite + binary**
```sh
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -8
mise exec zig@0.16.0 -- zig build
```
Expected: the scheduler test passes (job ran once, clean stop); existing tests stay green. If `std.testing.io` can't sleep in the test runner, see Step 1's note — adapt the test to drive the loop deterministically or gate it, but keep the pure tests (Tasks 1–3) as the primary correctness proof.

- [ ] **Step 5: Commit**
```sh
git add src/scheduler.zig
git commit -m "feat(framework): Scheduler runtime (thread + worker pool + queue)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `app.submit` + framework wiring (cfg keys, start/stop)

Add the `App.submit` facade + scheduler fields; widen the cfg-key whitelist with `cron`/`jobs`; `App(cfg)` exposes the comptime job table + pool size; `serveImpl` starts/stops the scheduler around `listen()`.

**Files:** Modify `src/app.zig`, `src/framework.zig`; Test: in `src/framework.zig`.

- [ ] **Step 1: Add scheduler fields + submit to App**

In `src/app.zig` `App` struct, after `dispatch`:
```zig
    /// Set by the Scheduler at startup (type-erased to avoid an app->scheduler import cycle).
    scheduler: ?*anyopaque = null,
    submit_fn: ?*const fn (ctx: *anyopaque, name: []const u8, task: @import("events.zig").JobTask) anyerror!void = null,
```
And a method on `App`:
```zig
    /// Offload an ad-hoc background task onto the scheduler (runs off the request thread).
    /// Returns error.SchedulerUnavailable if no scheduler is running (e.g. CLI / tests).
    pub fn submit(self: *App, name: []const u8, task: @import("events.zig").JobTask) !void {
        const f = self.submit_fn orelse return error.SchedulerUnavailable;
        return f(self.scheduler.?, name, task);
    }
```

- [ ] **Step 2: Write a failing test (App(cfg) exposes jobs + pool size)**

Add to `src/framework.zig`:
```zig
test "App(cfg) exposes the comptime job table and pool size" {
    const H = struct { fn j(ev: *@import("events.zig").JobEvent) anyerror!void { _ = ev; } };
    const A = App(.{
        .jobs = .{ .pool_size = 3 },
        .cron = .{ .{ .name = "n", .schedule = @import("schedule.zig").Schedule{ .interval = .hourly }, .handler = H.j } },
    });
    try std.testing.expectEqual(@as(usize, 1), A.jobs.len);
    try std.testing.expectEqual(@as(usize, 3), A.job_pool_size);
    const B = App(.{});
    try std.testing.expectEqual(@as(usize, 0), B.jobs.len);
}
```

- [ ] **Step 3: Run → FAIL** (cfg-key guard rejects `cron`/`jobs`; jobs/job_pool_size undefined). `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | head -20`

- [ ] **Step 4: Extend App(cfg): whitelist + jobs + pool size**

In `src/framework.zig`, add imports `const scheduler = @import("scheduler.zig");` and (if needed) `const schedule = @import("schedule.zig");`. In the `dispatch` comptime block's `allowed` tuple (Task 4 of 10b derived the error message from it), add `"cron"` and `"jobs"`:
```zig
            const allowed = .{ "hooks", "onError", "routes", "onAuth", "onFileServe", "onFileUpload", "onBootstrap", "onBeforeServe", "onBeforeTerminate", "cron", "jobs" };
```
(The error message already derives from `allowed`, so it auto-updates.) Then in the returned struct, alongside `pub const dispatch`, add:
```zig
        pub const jobs: []const scheduler.RuntimeJob = if (@hasField(@TypeOf(cfg), "cron")) scheduler.buildJobs(cfg.cron) else &.{};
        pub const job_pool_size: usize = if (@hasField(@TypeOf(cfg), "jobs") and @hasField(@TypeOf(cfg.jobs), "pool_size")) cfg.jobs.pool_size else 2;
```
> `job_pool_size` defaults to 2. Validate `.jobs` only contains `pool_size` (optional: a `@compileError` on unknown `.jobs` subfields, mirroring the route/hook validators — nice-to-have).

- [ ] **Step 5: Start/stop the scheduler in serveImpl**

In `src/framework.zig` `runCliImpl`'s `.serve` arm, the call is `try serveImpl(allocator, init.io, cfg, dispatch)`. Thread the comptime `jobs`/`job_pool_size` through. Change `App(cfg).runCli` to call an impl that also passes jobs+pool. Simplest: give `serveImpl` two more params:
```zig
fn serveImpl(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, dispatch: *const events.Dispatch, jobs: []const scheduler.RuntimeJob, pool_size: usize) !void {
```
and in the returned `App(cfg)` struct, `runCli`/`run` pass `&dispatch, jobs, job_pool_size`:
```zig
        pub fn runCli(init: std.process.Init) !void { return runCliImpl(init, &dispatch, jobs, job_pool_size); }
        pub fn run(init: std.process.Init, cfg_runtime: config.Config) !void { return serveImpl(init.gpa, init.io, cfg_runtime, &dispatch, jobs, job_pool_size); }
```
`runCliImpl` gains `jobs`/`pool_size` params and forwards them to `serveImpl` in the `.serve` arm. In `serveImpl`, after `app` is built and AFTER the `on_bootstrap`/`on_before_serve` emits but BEFORE `try srv.listen();`, start the scheduler when there are jobs; stop it on return:
```zig
    var sched: ?scheduler.Scheduler = null;
    if (jobs.len > 0) {
        sched = try scheduler.Scheduler.init(allocator, &app, jobs, pool_size);
        try sched.?.start();
    }
    defer if (sched) |*s| {
        s.stop();
        s.deinit();
    };
    // ... existing on_before_terminate defer + srv.listen() ...
    try srv.listen();
```
> Order: scheduler starts after bootstrap (migrated DB), before listen. On listen return, the `defer` stops + joins the scheduler threads, then frees. Ensure the scheduler `defer` is registered AFTER `app` is constructed and BEFORE `srv.listen()`, and that it runs before `app`/`pool` go out of scope (defers run LIFO — place the scheduler defer so it runs before pool.deinit; since pool is `defer pool.deinit()` earlier, and scheduler defer is later, scheduler stops first — correct).

- [ ] **Step 6: Run tests + build + Playwright**
```sh
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec zig@0.16.0 -- zig build
mise exec python@3.13 -- python -m pytest tests/admin -q
```
Expected: new test passes; binary EXIT 0; 11 Playwright pass (App(.{}) ⇒ jobs.len==0 ⇒ no scheduler started ⇒ serve behavior identical).

- [ ] **Step 7: Commit**
```sh
git add src/app.zig src/framework.zig
git commit -m "feat(framework): app.submit + scheduler start/stop wired into App(cfg)/serveImpl

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Example interval job + scheduler smoke

Add a registered interval job to `examples/blog` (consumer-facing scheduler example) and confirm the example builds + runs.

**Files:** Modify `examples/blog/src/main.zig`; Test: build + a short run check (a true timed e2e is impractical; the build + a startup smoke is the proof, plus the pure scheduler tests in Tasks 1–4 carry correctness).

- [ ] **Step 1: Add a job to the example**

In `examples/blog/src/main.zig`, add a job handler + register it:
```zig
/// An interval job: logs a heartbeat every hour (demonstrates background scheduling).
fn heartbeat(ev: *zigbase.events.JobEvent) anyerror!void {
    std.log.info("blog heartbeat job '{s}' ran", .{ev.name});
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
        .routes = .{ .{ .method = .GET, .path = "/api/blog/ping", .handler = ping, .auth = .public } },
        .jobs = .{ .pool_size = 2 },
        .cron = .{ .{ .name = "heartbeat", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = heartbeat } },
    }).runCli(init);
}
```
> Requires `zigbase.events.JobEvent` and `zigbase.schedule` to be public. In `src/root.zig` add `pub const schedule = @import("schedule.zig");` and confirm `events` is exported (it is: `pub const events = @import("events.zig");`, so `zigbase.events.JobEvent` works). Rebuild the main repo (EXIT 0, tests pass) after adding the re-export.

- [ ] **Step 2: Build the example (packaging proof for jobs)**
```sh
cd /home/valthon/nothlav/zigbase/examples/blog && mise exec zig@0.16.0 -- zig build && ls zig-out/bin/blog && cd ../..
```
Expected: EXIT 0.

- [ ] **Step 3: Startup smoke (server comes up with a job registered)**

Extend `tests/admin/test_custom_route.py` (or add `tests/admin/test_scheduler.py`) with a test that starts the example binary (which now registers a job), GETs `/api/blog/ping` to confirm the server runs normally with the scheduler thread active, and shuts down cleanly. Mirror the existing `test_custom_route.py` structure (free port, temp data dir, non-default JWT, finally-cleanup). The assertion: server responds 200 (proving the scheduler thread doesn't block/crash startup) and the process terminates within the timeout (proving clean shutdown with the scheduler running).
```python
# tests/admin/test_scheduler.py — mirror test_custom_route.py's fixture pattern,
# assert GET /api/blog/ping == 200 {"pong":true} while a cron job is registered,
# and that proc.terminate()/wait completes (clean shutdown with the scheduler running).
```

- [ ] **Step 4: Run + commit**
```sh
cd /home/valthon/nothlav/zigbase
mise exec python@3.13 -- python -m pytest tests/admin -q   # 12 passed
git add examples/blog/src/main.zig src/root.zig tests/admin/test_scheduler.py
git commit -m "test(framework): example interval job + scheduler startup/shutdown smoke

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Final review pass

- [ ] **Step 1: Full green gate**
```sh
cd /home/valthon/nothlav/zigbase
mise exec zig@0.16.0 -- zig build
mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -6
mise exec python@3.13 -- python -m pytest tests/admin -q
cd examples/blog && mise exec zig@0.16.0 -- zig build && cd ../..
```

- [ ] **Step 2: Holistic review (fresh code-review subagent)**

Review the full 10c diff for: the null-jobs invariant (no cron ⇒ no scheduler thread started ⇒ serve identical; the 11 Playwright + 225 Zig prove it); **thread-safety** — the `[N]JobState` + queue are only mutated under the spinlock; `shutdown` is atomic; no data race on `state`/`queue`; single-flight holds (a job can't be enqueued twice); **clean shutdown** — `stop()` sets shutdown, joins the scheduler thread then all workers, no deadlock (workers waiting on an empty queue wake within 20ms and see shutdown), no use-after-free (scheduler stops + joins before `pool`/`app` deinit); **the cron parser** correctness (the two timestamp tests; UTC civil-date math); **reactive `.stop`** retires a job; **error handling** — a job that errors routes to the backstop (`phase=.cron`/`.job`) and is rescheduled (cron/interval) without crashing the worker; `app.submit` detached-thread limitation documented; DB access from workers is safe (FULLMUTEX pool). Confirm no secret leak via JobEvent (carries only app + name).

- [ ] **Step 3: Address findings, re-run the gate, then stop**

10c ends here. **Plan 10d** (v0.1 release engineering) is next; then merge the whole framework branch to `main`.

---

## Self-Review (plan author)

**Spec coverage (spec §4 scheduler):**
- Three modes (cron / interval presets+minutes / reactive-return-drives-next) → Tasks 1, 2. ✓
- Single scheduler thread + comptime-sized `[N]JobState` + no-double-fire → Tasks 3, 4. ✓
- Submits to a shared comptime-sized worker pool (`pool_size`) → Task 4. ✓
- `app.submit` reachable from routes/hooks → Tasks 4, 5 (detached-thread v0.1, documented). ✓
- Reactive return drives next fire; `.stop` retires → Tasks 2, 3. ✓
- Injectable clock for tests (pure `nextFire`/`tick`/`completeJob`) → Tasks 1, 3. ✓
- Errors → backstop (`phase=.cron`/`.job`); single-process/local-time scope (UTC) → Task 4 + documented. ✓
- Clean shutdown (scheduler + pool joined on terminate) → Tasks 4, 5. ✓

**Placeholder scan:** No "TBD"/"handle edge cases". Flagged adaptation points (the `buildJobs` static-lifetime idiom → mirror `events.buildRoutes`; `std.testing.io` sleep-in-test fallback; the `makeTestApp` helper → mirror existing throwaway-App tests) name the authoritative source + the invariant the tests pin.

**Type consistency:** `schedule.{Interval,Schedule,Reactive}`, `periodSeconds`, `cronFieldMatches`, `nextFire(Schedule,i64) ?i64`; `events.{JobEvent,JobTask}`; `scheduler.{RuntimeJob (name/schedule/run:fn(*JobEvent)!?Reactive), buildJobs, JobState (status idle/running/stopped, next_fire), tick, completeJob, Scheduler (init/start/stop/deinit/submit)}`; `App.{scheduler,submit_fn,submit}`; `App(cfg).{jobs, job_pool_size}`; `serveImpl(...,jobs,pool_size)`. Cron uses UTC. Consistent across Tasks 1–6.
