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
