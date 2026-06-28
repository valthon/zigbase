//! Framework-owned outbound mail for `ctx.mail()` (#141). This is the single place
//! a consumer's application mail is built and delivered, so the security-critical
//! parts — CRLF/header-injection rejection and recipient address validation — live
//! HERE and a consumer never has to (and must not) re-roll them.
//!
//! `send` validates a `MailMessage`, lowers it to a `mail.Email`, and delivers it
//! through the configured `app.mailer` (the same vtable + dev-only `testcapture.mail`
//! seam every other send routes through), falling back to a log line when no mailer
//! is wired (tests/CLI) — mirroring `api/auth.deliverToken`. The actual RFC822 /
//! `multipart/alternative` bytes are produced by `mail.buildMessage` (shared with the
//! SMTP/Command backends), so HTML mail works uniformly across every backend.
//!
//! `jobHandler` is the built-in `"mail"` queue job kind: it deserializes the JSON
//! payload `ctx.mail().enqueue` enqueued back into a `MailMessage` and calls the same
//! `send`. It is registered onto the queue registry in `framework.zig`.

const std = @import("std");
const mailer = @import("mailer.zig");
const App = @import("../app.zig").App;
const Ctx = @import("../ctx.zig").Ctx;

const Email = mailer.Email;

/// A consumer-facing outbound message (`ctx.mail().send` / `.enqueue`). Exactly one
/// of `text`/`html` is required (both may be set for a `multipart/alternative` mail).
/// `to`/`reply_to` are validated as addresses and all header fields are CRLF-checked
/// by `send`/`validate` before any byte reaches a backend.
pub const MailMessage = struct {
    to: []const u8,
    subject: []const u8,
    text: ?[]const u8 = null,
    html: ?[]const u8 = null,
    reply_to: ?[]const u8 = null,
};

pub const MailError = error{
    /// `to`/`subject`/`reply_to` carried a CR, LF, NUL, or other ASCII control char
    /// (a header/command-injection vector). Same class as `mailer.HeaderError`.
    HeaderInjection,
    /// `to` (or `reply_to`) is not a syntactically valid email address.
    InvalidAddress,
    /// Neither `text` nor `html` was provided (an empty message has nothing to send).
    EmptyBody,
};

/// Reject control chars (CR/LF/NUL and the rest of 0x00–0x1F + 0x7F) — the same
/// header-injection backstop `mailer.buildMessage` applies, surfaced here so a bad
/// `MailMessage` is rejected up front (before a job is even enqueued).
fn checkHeader(s: []const u8) MailError!void {
    for (s) |c| if (c < 32 or c == 127) return error.HeaderInjection;
}

/// Pragmatic RFC5321-ish address check: a single `local@domain`, no whitespace or
/// control chars, a non-empty local part, and a domain with at least one dot and
/// non-empty labels. This is a backstop against malformed/spoofed recipients, not a
/// full RFC5322 parser (display-name forms like `Name <a@b.com>` are intentionally
/// rejected — pass a bare address). `checkHeader` must pass first (no control chars).
fn validateAddress(addr: []const u8) MailError!void {
    try checkHeader(addr);
    if (addr.len == 0 or addr.len > 254) return error.InvalidAddress;
    const at = std.mem.indexOfScalar(u8, addr, '@') orelse return error.InvalidAddress;
    const local = addr[0..at];
    const domain = addr[at + 1 ..];
    if (local.len == 0 or domain.len == 0) return error.InvalidAddress;
    // Exactly one '@'.
    if (std.mem.indexOfScalarPos(u8, addr, at + 1, '@') != null) return error.InvalidAddress;
    // No spaces anywhere; the domain needs a dot and non-empty, non-leading/trailing labels.
    for (addr) |c| if (c == ' ' or c == '\t') return error.InvalidAddress;
    if (domain[0] == '.' or domain[domain.len - 1] == '.') return error.InvalidAddress;
    if (std.mem.indexOfScalar(u8, domain, '.') == null) return error.InvalidAddress;
    if (std.mem.indexOf(u8, domain, "..") != null) return error.InvalidAddress;
    return;
}

/// Validate every field of `msg` (addresses + header injection + non-empty body).
/// Pure — no I/O — so it can guard `enqueue` before a job is persisted.
pub fn validate(msg: MailMessage) MailError!void {
    if (msg.text == null and msg.html == null) return error.EmptyBody;
    try validateAddress(msg.to);
    try checkHeader(msg.subject);
    if (msg.reply_to) |rt| try validateAddress(rt);
}

/// Lower a validated `MailMessage` to a `mail.Email` (the backend wire type).
fn toEmail(msg: MailMessage) Email {
    return .{
        .to = msg.to,
        .subject = msg.subject,
        .text_body = msg.text orelse "",
        .html_body = msg.html,
        .reply_to = msg.reply_to,
    };
}

/// Build + deliver `msg` synchronously via the configured `app.mailer`. Validates
/// first (CRLF + address), then routes through `Mailer.send` — the one vtable seam
/// that also feeds the dev-only `testcapture.mail` outbox, so consumer mail is
/// assertable in tests exactly like the framework's own auth mail. When no mailer is
/// wired (tests/CLI), it logs a fallback line (mirroring `api/auth.deliverToken`).
/// A real backend failure propagates so it is never silently dropped.
pub fn send(app: *App, alloc: std.mem.Allocator, msg: MailMessage) !void {
    try validate(msg);
    const email = toEmail(msg);
    if (app.mailer) |m| {
        try m.send(app.io, alloc, email);
    } else {
        std.log.info("[mail:fallback] to={s} subject={s}", .{ email.to, email.subject });
    }
}

/// Built-in `"mail"` queue job kind (#141). Deserializes the JSON payload that
/// `ctx.mail().enqueue` produced back into a `MailMessage` and delivers it via `send`.
/// A malformed payload or a delivery failure is returned so the queue's retry/terminal
/// policy applies (durable) or the in-process retry runs (memory).
pub fn jobHandler(ctx: *Ctx, payload: []const u8) anyerror!void {
    const parsed = try std.json.parseFromSlice(MailMessage, ctx.arena, payload, .{ .ignore_unknown_fields = true });
    // `parsed` borrows the ctx arena; no explicit deinit needed (arena owns it).
    try send(ctx.app, ctx.arena, parsed.value);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "validate accepts a plain address and rejects malformed ones" {
    try validate(.{ .to = "user@example.com", .subject = "Hi", .text = "body" });
    try validate(.{ .to = "a.b+c@sub.example.co.uk", .subject = "Hi", .html = "<b>x</b>" });

    try testing.expectError(error.EmptyBody, validate(.{ .to = "user@example.com", .subject = "Hi" }));
    try testing.expectError(error.InvalidAddress, validate(.{ .to = "no-at-sign", .subject = "s", .text = "b" }));
    try testing.expectError(error.InvalidAddress, validate(.{ .to = "@example.com", .subject = "s", .text = "b" }));
    try testing.expectError(error.InvalidAddress, validate(.{ .to = "user@", .subject = "s", .text = "b" }));
    try testing.expectError(error.InvalidAddress, validate(.{ .to = "user@localhost", .subject = "s", .text = "b" }));
    try testing.expectError(error.InvalidAddress, validate(.{ .to = "a@b@example.com", .subject = "s", .text = "b" }));
    try testing.expectError(error.InvalidAddress, validate(.{ .to = "a b@example.com", .subject = "s", .text = "b" }));
    try testing.expectError(error.InvalidAddress, validate(.{ .to = "a@.example.com", .subject = "s", .text = "b" }));
    try testing.expectError(error.InvalidAddress, validate(.{ .to = "Name <a@b.com>", .subject = "s", .text = "b" }));
}

test "validate rejects CRLF/control-char header injection in to/subject/reply_to" {
    // CRLF in the recipient (would inject a Bcc / extra RCPT TO).
    try testing.expectError(error.HeaderInjection, validate(.{ .to = "victim@x.io\r\nBcc: spam@evil.com", .subject = "s", .text = "b" }));
    // Newline in the subject (would inject an arbitrary header).
    try testing.expectError(error.HeaderInjection, validate(.{ .to = "user@example.com", .subject = "Hi\nX-Injected: yes", .text = "b" }));
    // CRLF in reply_to.
    try testing.expectError(error.HeaderInjection, validate(.{ .to = "user@example.com", .subject = "s", .text = "b", .reply_to = "ok@x.io\r\nEvil: 1" }));
    // A NUL is rejected too.
    try testing.expectError(error.HeaderInjection, validate(.{ .to = "user@example.com", .subject = "Hi\x00", .text = "b" }));
}

test "toEmail maps text/html/reply_to onto the backend Email" {
    const e = toEmail(.{ .to = "u@x.io", .subject = "s", .text = "t", .html = "<b>h</b>", .reply_to = "r@x.io" });
    try testing.expectEqualStrings("u@x.io", e.to);
    try testing.expectEqualStrings("t", e.text_body);
    try testing.expectEqualStrings("<b>h</b>", e.html_body.?);
    try testing.expectEqualStrings("r@x.io", e.reply_to.?);
    // html-absent maps to a null html_body; text-absent maps to an empty text_body.
    const e2 = toEmail(.{ .to = "u@x.io", .subject = "s", .html = "<b>h</b>" });
    try testing.expect(e2.html_body != null);
    try testing.expectEqualStrings("", e2.text_body);
}
