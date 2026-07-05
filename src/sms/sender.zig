//! Pluggable, backend-agnostic SMS sender (#224). Mirrors the `Mailer` vtable in
//! `mail/mailer.zig`: a `*anyopaque` ctx plus a vtable with a single `send`.
//!
//! This is a swappable plugin: a consumer supplies their own provider by implementing a
//! type with a `send` fn matching `VTable.send` and a `sender()` helper returning an
//! `SmsSender{ .ptr = self, .vtable = &vt }`. ZigBase ships `LogSmsSender` (the network-free
//! default — logs the message; used when no provider is configured, so dev/CI/tests need no
//! credentials) and `TwilioSender` (see `twilio.zig`).
//!
//! The `Sms` message here is the BACKEND wire type: `to`/`from` are already E.164-normalized
//! by `sms/send.zig` before a backend ever sees them (the framework owns that validation —
//! a provider trusts the numbers are canonical `+<digits>`).

const std = @import("std");

/// A single outbound text message. `from` is an optional per-message sender override
/// (`null` keeps the backend's configured sender number), mirroring `Email.from`.
pub const Sms = struct {
    to: []const u8,
    body: []const u8,
    from: ?[]const u8 = null,
};

/// Pluggable SMS sender vtable. `from` surfaces the backend's configured sender number
/// (additive, `""` default) purely so a test double / capture can record it; it is not
/// used on the delivery path (the message's own `from` override wins there).
pub const SmsSender = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    from: []const u8 = "",

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, sms: Sms) anyerror!void,
    };

    pub fn send(self: SmsSender, io: std.Io, alloc: std.mem.Allocator, sms: Sms) anyerror!void {
        return self.vtable.send(self.ptr, io, alloc, sms);
    }
};

/// Default backend: logs the message via `std.log.info` and performs NO network I/O. This is
/// the unconfigured default (no Twilio credentials), so dev/CI/tests deliver SMS as a log line
/// exactly the way `LogMailer` handles unconfigured mail.
pub const LogSmsSender = struct {
    pub fn init() LogSmsSender {
        return .{};
    }

    pub fn sender(self: *LogSmsSender) SmsSender {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = SmsSender.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, sms: Sms) anyerror!void {
        _ = ptr;
        _ = io;
        _ = alloc;
        std.log.info("[sms] to={s} from={s} body={s}", .{ sms.to, sms.from orelse "", sms.body });
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "LogSmsSender satisfies the SmsSender interface and send succeeds (no network)" {
    var ls = LogSmsSender.init();
    const s = ls.sender();
    try s.send(std.testing.io, std.testing.allocator, .{
        .to = "+15551234567",
        .body = "Reminder: tomorrow 10:00",
    });
}
