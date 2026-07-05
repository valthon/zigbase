//! Framework-owned outbound SMS for `ctx.sms()` (#224), the SMS analog of `mail/send.zig`. This is
//! the single place a consumer's application SMS is normalized and delivered, so the
//! security-critical part — framework-owned E.164 normalization/rejection — lives HERE and a
//! consumer never has to (and must not) re-roll it.
//!
//! `send` normalizes an `SmsMessage` (E.164 `to`/`from`, non-empty body), lowers it to a
//! `sender.Sms`, and delivers it through the configured `app.sms_sender` (the SmsSender vtable),
//! falling back to a log line when no sender is wired (tests/CLI). The normalization runs BEFORE a
//! byte reaches a provider OR a durable queue row: `enqueue` normalizes first, so a bad number
//! fails fast at the call site and never persists.
//!
//! `jobHandler` is the built-in `"sms"` queue job kind: it deserializes the JSON payload
//! `ctx.sms().enqueue` enqueued back into an `SmsMessage` and delivers it via the same `send`.
//! It is registered onto the queue registry in `framework.zig` (gated on `enable_sms_job`).

const std = @import("std");
const sender = @import("sender.zig");
const e164 = @import("e164.zig");
const App = @import("../app.zig").App;
const Ctx = @import("../ctx.zig").Ctx;

const Sms = sender.Sms;

/// A consumer-facing outbound message (`ctx.sms().send` / `.enqueue`). `to` (and the optional
/// per-message `from` sender override) are E.164-normalized by `normalize` before any byte reaches
/// a backend or a durable row; `body` must be non-empty.
pub const SmsMessage = struct {
    to: []const u8,
    body: []const u8,
    /// Optional per-message sender number override. `null` keeps the backend's configured `from`.
    from: ?[]const u8 = null,
};

pub const SmsError = error{
    /// `to` (or `from`) is not a valid phone number (see `e164.normalizeE164`).
    InvalidPhoneNumber,
    /// `body` was empty (an empty text has nothing to send).
    EmptyBody,
};

/// Normalize + validate `msg` against `region`, returning a NEW `SmsMessage` whose `to`/`from`
/// are canonical E.164 (allocated on `alloc`). Pure of network I/O — this is what both `send` and
/// `enqueue` run first, so a malformed number is rejected up front (before a job is persisted).
pub fn normalize(alloc: std.mem.Allocator, msg: SmsMessage, region: e164.Region) (SmsError || std.mem.Allocator.Error)!SmsMessage {
    if (msg.body.len == 0) return error.EmptyBody;
    const to = e164.normalizeE164(alloc, msg.to, .{ .default_region = region }) catch |e| switch (e) {
        error.InvalidPhoneNumber => return error.InvalidPhoneNumber,
        else => |x| return x,
    };
    // If the optional `from` normalization fails, `to`'s allocation must not leak (an arena
    // caller frees wholesale, but a direct allocator caller relies on this).
    errdefer alloc.free(to);
    const from: ?[]const u8 = if (msg.from) |f|
        (e164.normalizeE164(alloc, f, .{ .default_region = region }) catch |e| switch (e) {
            error.InvalidPhoneNumber => return error.InvalidPhoneNumber,
            else => |x| return x,
        })
    else
        null;
    return .{ .to = to, .body = msg.body, .from = from };
}

/// Lower a normalized `SmsMessage` to a `sender.Sms` (the backend wire type).
fn toSms(msg: SmsMessage) Sms {
    return .{ .to = msg.to, .body = msg.body, .from = msg.from };
}

/// Normalize + deliver `msg` synchronously via the configured `app.sms_sender`. When no sender is
/// wired (tests/CLI), logs a fallback line (mirroring `mail.send`). A real backend failure
/// propagates so it is never silently dropped.
pub fn send(app: *App, alloc: std.mem.Allocator, msg: SmsMessage) !void {
    const normalized = try normalize(alloc, msg, app.sms.default_region);
    // `normalize` allocates `to` (and `from` when set) on `alloc`; free them so `send` doesn't
    // leak when called with a general-purpose allocator (not only a request arena). `body` is the
    // caller's slice, not owned here.
    defer alloc.free(normalized.to);
    defer if (normalized.from) |f| alloc.free(f);
    const wire = toSms(normalized);
    if (app.sms_sender) |s| {
        try s.send(app.io, alloc, wire);
    } else {
        std.log.info("[sms:fallback] to={s} body={s}", .{ wire.to, wire.body });
    }
}

/// Built-in `"sms"` queue job kind (#224). Deserializes the JSON payload that `ctx.sms().enqueue`
/// produced back into an `SmsMessage` and delivers it via `send`. A malformed payload or a delivery
/// failure is returned so the queue's retry/terminal policy applies.
pub fn jobHandler(ctx: *Ctx, payload: []const u8) anyerror!void {
    const parsed = try std.json.parseFromSlice(SmsMessage, ctx.arena, payload, .{ .ignore_unknown_fields = true });
    try send(ctx.app, ctx.arena, parsed.value);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "normalize canonicalizes to/from and requires a body" {
    const a = testing.allocator;
    const n = try normalize(a, .{ .to = "555-123-4567", .body = "hi", .from = "(555) 000-0000" }, .us);
    defer a.free(n.to);
    defer if (n.from) |f| a.free(f);
    try testing.expectEqualStrings("+15551234567", n.to);
    try testing.expectEqualStrings("+15550000000", n.from.?);
    try testing.expectEqualStrings("hi", n.body);

    try testing.expectError(error.EmptyBody, normalize(a, .{ .to = "+15551234567", .body = "" }, .us));
    try testing.expectError(error.InvalidPhoneNumber, normalize(a, .{ .to = "not-a-number", .body = "hi" }, .us));
    try testing.expectError(error.InvalidPhoneNumber, normalize(a, .{ .to = "+15551234567", .body = "hi", .from = "abc" }, .us));
}

test "send with no sender wired is a network-free log fallback (bad number still rejected first)" {
    // `send` allocates the normalized number on its allocator; production passes the ctx arena
    // (freed wholesale), so use an arena here to mirror that lifetime.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = App{ .allocator = a, .io = testing.io, .pool = undefined };
    // No sms_sender → log fallback; a valid message succeeds with no network.
    try send(&app, a, .{ .to = "+15551234567", .body = "hi" });
    // A bad number is rejected before any delivery.
    try testing.expectError(error.InvalidPhoneNumber, send(&app, a, .{ .to = "555-CALL", .body = "hi" }));
}

const CaptureSms = @import("capture.zig").CaptureSms;

test "send delivers through the configured sender with a normalized number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap = CaptureSms.init(testing.allocator);
    defer cap.deinit();
    var iface = cap.sender();
    var app = App{ .allocator = a, .io = testing.io, .pool = undefined, .sms_sender = &iface };
    try send(&app, a, .{ .to = "555-123-4567", .body = "Reminder: 10:00" });
    try testing.expectEqual(@as(usize, 1), cap.count());
    const last = cap.last().?;
    try testing.expectEqualStrings("+15551234567", last.to); // normalized before the backend saw it
    try testing.expectEqualStrings("Reminder: 10:00", last.body);
}

test "jobHandler round-trips a JSON payload into a delivered message" {
    const a = testing.allocator;
    var cap = CaptureSms.init(a);
    defer cap.deinit();
    var iface = cap.sender();
    var app = App{ .allocator = a, .io = testing.io, .pool = undefined, .sms_sender = &iface };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var ctx = Ctx{ .app = &app, .arena = arena.allocator() };
    // The payload is what serializePayload(SmsMessage) would produce.
    try jobHandler(&ctx, "{\"to\":\"+15551234567\",\"body\":\"queued hello\"}");
    try testing.expectEqual(@as(usize, 1), cap.count());
    try testing.expectEqualStrings("+15551234567", cap.last().?.to);
    try testing.expectEqualStrings("queued hello", cap.last().?.body);
}
