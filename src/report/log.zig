const std = @import("std");
const reporter = @import("reporter.zig");
const config = @import("../config.zig");
const Reporter = reporter.Reporter;
const Report = reporter.Report;

/// Test-only sink: when non-null, log-mode reporting routes the message here instead of
/// `std.log.err`. Production leaves this null (real logging). It exists because Zig's test
/// runner counts every `std.log.err` as a test failure, so a test exercising the swallowed
/// error backstop needs a way to observe/suppress it without logging. Shared by both the
/// `LogReporter` and `dispatchError`'s un-booted-app log fallback.
pub var log_sink: ?*const fn (message: []const u8) void = null;

/// Emit the log-mode backstop line for `r`. Honors `log_sink` in tests, else `std.log.err`.
/// This is the single "no reporter configured" log format; `dispatchError`'s null-reporter
/// fallback (un-booted test apps) also calls it so the format stays in one place.
pub fn emit(r: Report) void {
    if (log_sink) |sink| sink(r.message) else std.log.err("[{s}] {s}: {s}", .{ r.phase, r.err_name, r.message });
}

/// Default error reporter: logs the report via `std.log.err`. This preserves the pre-plugin
/// backstop behavior for an app with no Sentry DSN configured (dev/CI default).
pub const LogReporter = struct {
    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !LogReporter {
        _ = gpa;
        _ = io;
        _ = cfg;
        return .{};
    }

    pub fn interface(self: *LogReporter) Reporter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *LogReporter) void {
        _ = self;
    }

    const vtable = Reporter.VTable{ .report = report };

    fn report(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, r: Report) anyerror!void {
        _ = ptr;
        _ = io;
        _ = alloc;
        emit(r);
    }
};

test "LogReporter satisfies the Reporter interface and routes through log_sink" {
    const H = struct {
        var seen: []const u8 = "";
        fn sink(m: []const u8) void {
            seen = m;
        }
    };
    log_sink = H.sink;
    defer log_sink = null;

    var lr = try LogReporter.create(std.testing.allocator, std.testing.io, .{});
    defer lr.deinit();
    const rep = lr.interface();
    try rep.report(std.testing.io, std.testing.allocator, .{ .message = "boom", .err_name = "error.Boom", .phase = "job" });
    try std.testing.expectEqualStrings("boom", H.seen);
}
