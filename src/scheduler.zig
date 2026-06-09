const std = @import("std");
const schedule = @import("schedule.zig");
const events = @import("events.zig");
const App = @import("app.zig").App;

/// A registered job after comptime assembly. `run` is a uniform wrapper returning
/// `?schedule.Reactive`: `null` for cron/interval jobs (next fire computed from `schedule`),
/// or the handler's returned `Reactive` for reactive jobs.
pub const RuntimeJob = struct {
    name: []const u8,
    schedule: schedule.Schedule,
    run: *const fn (ev: *events.JobEvent) anyerror!?schedule.Reactive,
};

/// `@compileError` on any job spec missing a required field (`.name`/`.schedule`/
/// `.handler`), mirroring `events.validateRouteSpecs`. The handler type differs by
/// mode (reactive returns `Reactive`, others `void`), so it is not hard-asserted here.
fn validateJobSpecs(comptime specs: anytype) void {
    inline for (std.meta.fields(@TypeOf(specs))) |f| {
        const s = @field(specs, f.name);
        if (!@hasField(@TypeOf(s), "name")) @compileError("job spec is missing '.name' (expected .{ .name = \"...\", .schedule = ..., .handler = fn })");
        if (!@hasField(@TypeOf(s), "schedule")) @compileError("job spec is missing '.schedule' (expected .{ .name = \"...\", .schedule = ..., .handler = fn })");
        if (!@hasField(@TypeOf(s), "handler")) @compileError("job spec is missing '.handler' (expected .{ .name = \"...\", .schedule = ..., .handler = fn })");
    }
}

/// Assemble a comptime tuple of job specs `.{ .name, .schedule, .handler }` into a runtime
/// table. For `.reactive` schedules the handler must be `fn(*JobEvent) anyerror!Reactive`;
/// otherwise `fn(*JobEvent) anyerror!void`. Both are unified to `anyerror!?Reactive` via a
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
                    fn run(ev: *events.JobEvent) anyerror!?schedule.Reactive {
                        if (reactive) {
                            return try handler(ev);
                        } else {
                            try handler(ev);
                            return null;
                        }
                    }
                };
                t[i] = .{ .name = s.name, .schedule = sched, .run = Wrap.run };
            }
            break :blk t;
        };
    };
    return &Holder.table;
}

pub const JobState = struct {
    status: enum { idle, running, stopped },
    next_fire: i64, // unix seconds; meaningful when status == .idle
};

/// Pure decision: append the indices of jobs that are `.idle` AND due (`next_fire <= now`)
/// to `out`, marking each `.running` (single-flight). Returns the filled slice of `out`.
/// Capping at out.len is a safety bound; callers pass out.len >= state.len.
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

/// Apply a job's completion to its state. `reactive_result` is non-null ONLY for reactive
/// jobs (the handler's return). For cron/interval, next_fire is recomputed from `sched`;
/// if there is no future fire (e.g. an impossible cron), the job is retired (`.stopped`).
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
    s.next_fire = schedule.nextFire(sched, now) orelse {
        s.status = .stopped;
        return;
    };
    s.status = .idle;
}

test "buildJobs assembles cron/interval/reactive into a uniform table" {
    const H = struct {
        fn cleanup(ev: *events.JobEvent) anyerror!void {
            _ = ev;
        }
        fn backoff(ev: *events.JobEvent) anyerror!schedule.Reactive {
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
    const r2 = try jobs[2].run(&ev);
    try std.testing.expect(r2 != null and r2.?.after.minutes == 5);
    const r0 = try jobs[0].run(&ev);
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
