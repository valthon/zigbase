const std = @import("std");

/// A single error report handed to a `Reporter` backend. Built from an `ErrorEvent`
/// at the swallow-point (`events.dispatchError`): `message` is the human-readable
/// summary, `err_name` is `@errorName(ev.err)`, `phase` is the `ErrorPhase` tag name
/// (request/job/cron/webhook/after_hook/…). `level` defaults to "error".
pub const Report = struct {
    message: []const u8,
    err_name: []const u8 = "",
    phase: []const u8,
    level: []const u8 = "error",
};

/// Pluggable, backend-agnostic error reporter. Mirrors the `Mailer`/`Storage` vtable
/// pattern: a `*anyopaque` ctx plus a vtable with a single `report`.
///
/// This is a swappable plugin: a consumer supplies their own backend by implementing a
/// type with a `report` fn matching `VTable.report` and exposing an `interface` helper
/// that returns a `Reporter{ .ptr = self, .vtable = &vt }`. ZigBase ships two:
/// `LogReporter` (logs the report; the default when no Sentry DSN is configured,
/// preserving the pre-plugin log-only backstop) and `SentryReporter` (POSTs a Sentry
/// envelope). The reporter is the terminal backstop for every framework-swallowed error,
/// so `report` returning an error is itself swallowed (logged) by `dispatchError`.
pub const Reporter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        report: *const fn (ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, r: Report) anyerror!void,
    };

    pub fn report(self: Reporter, io: std.Io, alloc: std.mem.Allocator, r: Report) anyerror!void {
        return self.vtable.report(self.ptr, io, alloc, r);
    }
};
