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

/// Render the structured backstop log line for `r` into `buf`, returning the written slice.
/// DEDUPS the common `message == err_name` case (and handles empty fields) so the line never
/// reads `[job] HookRejected: HookRejected`:
///   - empty `err_name`             → `[phase] message`
///   - empty `message` OR == name   → `[phase] err_name`
///   - otherwise                    → `[phase] err_name: message`
/// A pathologically long line is truncated to `buf` (best-effort — this is a log line).
pub fn formatLine(buf: []u8, r: Report) []const u8 {
    const out = if (r.err_name.len == 0)
        std.fmt.bufPrint(buf, "[{s}] {s}", .{ r.phase, r.message })
    else if (r.message.len == 0 or std.mem.eql(u8, r.message, r.err_name))
        std.fmt.bufPrint(buf, "[{s}] {s}", .{ r.phase, r.err_name })
    else
        std.fmt.bufPrint(buf, "[{s}] {s}: {s}", .{ r.phase, r.err_name, r.message });
    return out catch buf; // NoSpaceLeft: return the (truncated) full buffer, best-effort.
}

/// Emit the structured backstop line for `r`. Honors `log_sink` in tests, else `std.log.err`.
/// This is the single "no reporter configured" log format; `dispatchError`'s null-reporter
/// fallback (un-booted test apps) also calls it so the format stays in one place.
pub fn emit(r: Report) void {
    var buf: [1024]u8 = undefined;
    const line = formatLine(&buf, r);
    if (log_sink) |sink| sink(line) else std.log.err("{s}", .{line});
}

/// Default error reporter: logs the report via `std.log.err` as a structured backstop line
/// (`[phase] err_name: message`, deduped — see `formatLine`). This is the default backstop
/// for an app with no Sentry DSN configured (dev/CI default).
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

test "LogReporter satisfies the Reporter interface and routes the formatted line through log_sink" {
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
    try std.testing.expectEqualStrings("[job] error.Boom: boom", H.seen);
}

test "formatLine: full case, dedup case, and empty-field cases" {
    var buf: [128]u8 = undefined;
    // Full: distinct message + err_name → "[phase] err_name: message".
    try std.testing.expectEqualStrings("[job] error.Boom: boom", formatLine(&buf, .{ .message = "boom", .err_name = "error.Boom", .phase = "job" }));
    // Dedup: message == err_name → no `[job] HookRejected: HookRejected` duplication.
    try std.testing.expectEqualStrings("[job] HookRejected", formatLine(&buf, .{ .message = "HookRejected", .err_name = "HookRejected", .phase = "job" }));
    // Empty message → just the phase + err_name.
    try std.testing.expectEqualStrings("[request] error.X", formatLine(&buf, .{ .message = "", .err_name = "error.X", .phase = "request" }));
    // Empty err_name → just the phase + message.
    try std.testing.expectEqualStrings("[app] widget failed", formatLine(&buf, .{ .message = "widget failed", .err_name = "", .phase = "app" }));
}
