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
//!
//! ENFORCEMENT BOUNDARY (#154 review M4): verified-sender + suppression enforcement is a POLICY of
//! this `ctx.mail()` / `mail.send` layer (`enforce` below), NOT a guarantee of the `Mailer.send`
//! vtable seam. A framework-internal caller that reaches for `app.mailer.?.send(...)` directly (or
//! a custom backend invoked out-of-band) BYPASSES verified-sender and suppression checks — only
//! header/CRLF rejection (which lives in every backend) still applies. Application code should send
//! through `ctx.mail()`; the direct seam is for the framework's own auth mail, which is a system
//! send (no account) that bypasses verified-sender enforcement by design anyway.

const std = @import("std");
const mailer = @import("mailer.zig");
const App = @import("../app.zig").App;
const Ctx = @import("../ctx.zig").Ctx;
const db = @import("../db.zig");
const senders = @import("senders.zig");
const suppression = @import("suppression.zig");

const Email = mailer.Email;

/// Gmail clips messages around ~102KB and hides the rest behind "[Message clipped]"
/// — which also hides the RFC 8058 unsubscribe footer if the template renders one.
/// Warn (never error) above a round 100KB so list templates get fixed at dev time.
pub const gmail_clip_warn_bytes: usize = 100 * 1024;

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
    /// Optional per-message From override (#154). `null` keeps the backend's configured sender, so
    /// existing callers are unchanged. When verified-sender enforcement is on AND `account` is set,
    /// this From must be a VERIFIED `_sender_identities` row for `account`.
    from: ?[]const u8 = null,
    /// Optional sending account (#154). `null`/empty = a system/superuser send (bypasses verified-
    /// sender enforcement). When set, it scopes the verified-sender + suppression checks to that
    /// account. `ctx.mail()` defaults this from the request's active account scope.
    account: ?[]const u8 = null,
    /// Optional one-click unsubscribe URL (#154 round 2), lowered onto `Email.list_unsubscribe`.
    /// Set by the framework's bulk item handler (or via `ctx.mail().unsubscribeUrl` for
    /// hand-rolled list mail). Transactional mail must NOT carry it.
    list_unsubscribe: ?[]const u8 = null,
    /// Optional file attachments (#219), lowered onto `Email.attachments`. `&.{}` (the default)
    /// keeps the message single-part / `multipart/alternative` exactly as before. Each attachment's
    /// `filename`/`content_type` is CRLF-checked by `validate`; the assembled size (base64-expanded)
    /// is bounded by `.mail.max_message_bytes` at both `send` and `enqueue` (`error.MailTooLarge`).
    attachments: []const mailer.Attachment = &.{},
};

pub const MailError = error{
    /// `to`/`subject`/`reply_to`/`from` carried a CR, LF, NUL, or other ASCII control char
    /// (a header/command-injection vector). Same class as `mailer.HeaderError`.
    HeaderInjection,
    /// `to` (or `reply_to`/`from`) is not a syntactically valid email address.
    InvalidAddress,
    /// Neither `text` nor `html` was provided (an empty message has nothing to send).
    EmptyBody,
    /// The assembled message (body + attachments at their base64-expanded size) would exceed the
    /// configured `.mail.max_message_bytes` cap (#219). Checked at both `send` and `enqueue`.
    MailTooLarge,
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
pub fn validateAddress(addr: []const u8) MailError!void {
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
    if (msg.from) |fr| try validateAddress(fr);
    if (msg.account) |acct| try checkHeader(acct);
    if (msg.list_unsubscribe) |lu| try checkHeader(lu);
    // Attachment metadata is header-bound (Content-Type / Content-Disposition) — CRLF-check it up
    // front so a bad attachment fails at the call site, before a job is ever persisted.
    for (msg.attachments) |att| {
        try checkHeader(att.filename);
        try checkHeader(att.content_type);
    }
}

/// Conservatively estimate the assembled on-the-wire message size in bytes: the subject, both body
/// parts, and every attachment at its BASE64-EXPANDED size (⌈len/3⌉·4) plus its header metadata.
/// Used to enforce `.mail.max_message_bytes`. An over-estimate is fine — the cap is a guardrail, not
/// an exact byte budget, and it must reject BEFORE a 13 MiB base64 blob is built or persisted.
fn estimatedSize(msg: MailMessage) usize {
    var n: usize = msg.subject.len;
    if (msg.text) |t| n += t.len;
    if (msg.html) |h| n += h.len;
    for (msg.attachments) |att| {
        n += att.filename.len + att.content_type.len + 128; // + a slack allowance for MIME headers
        n += (att.data.len / 3 + 1) * 4; // base64 expansion
    }
    return n;
}

/// Reject a message whose estimated assembled size exceeds `max_bytes` (#219). Pure — so it guards
/// both the synchronous `send` and `enqueue` before any bytes are built or a job is persisted.
pub fn checkSize(msg: MailMessage, max_bytes: usize) MailError!void {
    if (estimatedSize(msg) > max_bytes) return error.MailTooLarge;
}

/// Lower a validated `MailMessage` to a `mail.Email` (the backend wire type).
fn toEmail(msg: MailMessage) Email {
    return .{
        .to = msg.to,
        .subject = msg.subject,
        .text_body = msg.text orelse "",
        .html_body = msg.html,
        .reply_to = msg.reply_to,
        .from = msg.from,
        .list_unsubscribe = msg.list_unsubscribe,
        .attachments = msg.attachments,
    };
}

/// Fail-closed send-time enforcement (#154), run against a reader `conn` ONLY when the app has
/// opted into verified-sender and/or suppression enforcement (`app.mail.enforces()`). Both checks
/// are account-scoped:
///   * verified sender — when `require_verified_sender` is on and the send is account-scoped
///     (`account` non-empty), the From must be a verified identity for that account. A scoped send
///     with no explicit From is rejected (it would fall back to the global From, which is not the
///     account's verified identity). A send with NO account is a system/superuser send and bypasses.
///   * suppression — a send to a hard-bounced/complained recipient (for the account, or globally)
///     is blocked.
fn enforce(app: *App, alloc: std.mem.Allocator, conn: *db.Db, msg: MailMessage) !void {
    if (app.mail.require_verified_sender) {
        const acct = msg.account orelse "";
        if (acct.len > 0) {
            const from = msg.from orelse "";
            if (from.len == 0) return error.SenderNotVerified; // scoped send must declare a verified From
            try senders.assertVerified(alloc, conn, acct, from);
        }
    }
    if (app.mail.check_suppression) {
        try suppression.assertNotSuppressed(alloc, conn, msg.account orelse "", msg.to, .transactional);
    }
}

/// Build + deliver `msg` synchronously via the configured `app.mailer`. Validates
/// first (CRLF + address), then routes through `Mailer.send` — the one vtable seam
/// that also feeds the dev-only `testcapture.mail` outbox, so consumer mail is
/// assertable in tests exactly like the framework's own auth mail. When no mailer is
/// wired (tests/CLI), it logs a fallback line (mirroring `api/auth.deliverToken`).
/// A real backend failure propagates so it is never silently dropped.
pub fn send(app: *App, alloc: std.mem.Allocator, msg: MailMessage) !void {
    try validate(msg);
    try checkSize(msg, app.mail.max_message_bytes);
    if (msg.html) |h| {
        if (h.len > gmail_clip_warn_bytes) std.log.warn(
            "mail: html body to {s} is {d} bytes (>100KB); Gmail clips ~102KB — the message may be truncated for recipients",
            .{ msg.to, h.len },
        );
    }
    // Fail-closed enforcement (verified sender + suppression), only when the app opted in. The
    // default path (`enforces()==false`) acquires no reader and is byte-identical to pre-#154.
    if (app.mail.enforces()) {
        var r = try app.pool.acquireReader();
        defer app.pool.releaseReader(&r);
        try enforce(app, alloc, &r, msg);
    }
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
    const parsed = try std.json.parseFromSlice(MailMessage, ctx.arena.a, payload, .{ .ignore_unknown_fields = true });
    // `parsed` borrows the ctx arena; no explicit deinit needed (arena owns it).
    try send(ctx.app, ctx.arena.a, parsed.value);
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
    // CRLF in list_unsubscribe (would inject an extra header/field into the provider payload).
    try testing.expectError(error.HeaderInjection, validate(.{
        .to = "user@example.com",
        .subject = "s",
        .text = "b",
        .list_unsubscribe = "https://x/u?t=1\r\nBcc: spam@evil.com",
    }));
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

test "toEmail carries the per-message From override" {
    const e = toEmail(.{ .to = "u@x.io", .subject = "s", .text = "t", .from = "tenant@acct.com" });
    try testing.expectEqualStrings("tenant@acct.com", e.from.?);
}

test "toEmail maps list_unsubscribe onto the backend Email" {
    const e = toEmail(.{ .to = "u@x.io", .subject = "s", .text = "t", .list_unsubscribe = "https://app.example/u?t=1" });
    try testing.expectEqualStrings("https://app.example/u?t=1", e.list_unsubscribe.?);
    const e2 = toEmail(.{ .to = "u@x.io", .subject = "s", .text = "t" });
    try testing.expect(e2.list_unsubscribe == null);
}

// --- Send-time enforcement (fail-closed) ------------------------------------

const migrations = @import("../migrations.zig");

const EnforceEnv = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,
    app: App,

    fn init(mail_cfg: @import("config.zig").Runtime) !*EnforceEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(EnforceEnv);
        errdefer ga.destroy(env);
        env.tmp = std.testing.tmpDir(.{});
        errdefer env.tmp.cleanup();
        const dir_path = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
        defer ga.free(dir_path);
        env.db_path = try std.fmt.allocPrintSentinel(ga, "{s}/mail.db", .{dir_path}, 0);
        errdefer ga.free(env.db_path);
        env.pool = try db.Pool.init(ga, std.testing.io, env.db_path);
        errdefer env.pool.deinit();
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
        }
        env.app = App{ .allocator = ga, .io = std.testing.io, .pool = &env.pool, .mail = mail_cfg };
        return env;
    }
    fn writer(env: *EnforceEnv) *db.Db {
        return env.pool.acquireWriter();
    }
    fn deinit(env: *EnforceEnv) void {
        const ga = std.testing.allocator;
        env.pool.deinit();
        ga.free(env.db_path);
        env.tmp.cleanup();
        ga.destroy(env);
    }
};

test "send rejects an unverified sender when require_verified_sender is on (fail closed)" {
    var env = try EnforceEnv.init(.{ .require_verified_sender = true });
    defer env.deinit();
    // A tenant send (account + from) whose From is NOT a verified identity → rejected.
    try testing.expectError(error.SenderNotVerified, send(&env.app, std.testing.allocator, .{
        .to = "user@example.com",
        .subject = "Hi",
        .text = "body",
        .from = "from@acct.com",
        .account = "acc1",
    }));
    // A scoped send with no explicit From is also rejected (would fall back to the global From).
    try testing.expectError(error.SenderNotVerified, send(&env.app, std.testing.allocator, .{
        .to = "user@example.com",
        .subject = "Hi",
        .text = "body",
        .account = "acc1",
    }));

    // Verify the identity, then the same tenant send passes enforcement (no mailer wired → logs).
    {
        const w = env.writer();
        defer env.pool.releaseWriter();
        const req = try senders.requestVerification(std.testing.io, std.testing.allocator, w, "acc1", "from@acct.com");
        defer std.testing.allocator.free(req.id);
        defer std.testing.allocator.free(req.token);
        defer std.testing.allocator.free(req.email);
        try testing.expect(try senders.confirm(std.testing.allocator, w, "acc1", req.id, req.token));
    }
    try send(&env.app, std.testing.allocator, .{ .to = "user@example.com", .subject = "Hi", .text = "body", .from = "from@acct.com", .account = "acc1" });

    // A system send (no account) bypasses verified-sender enforcement entirely.
    try send(&env.app, std.testing.allocator, .{ .to = "user@example.com", .subject = "Hi", .text = "body" });
}

test "send blocks a suppressed recipient when check_suppression is on (fail closed)" {
    var env = try EnforceEnv.init(.{ .check_suppression = true });
    defer env.deinit();
    {
        const w = env.writer();
        defer env.pool.releaseWriter();
        try suppression.upsert(std.testing.io, std.testing.allocator, w, "acc1", "bounced@example.com", suppression.reason_hard_bounce, "ses");
    }
    // A send to the suppressed recipient (for the account) is blocked — even a differently-cased
    // spelling (I1 normalization: the suppression check is case-insensitive).
    try testing.expectError(error.RecipientSuppressed, send(&env.app, std.testing.allocator, .{
        .to = "Bounced@Example.com",
        .subject = "Hi",
        .text = "body",
        .account = "acc1",
    }));
    // A different recipient is fine (no mailer wired → log fallback, no error).
    try send(&env.app, std.testing.allocator, .{ .to = "ok@example.com", .subject = "Hi", .text = "body", .account = "acc1" });
}

test "validate rejects CRLF in an attachment filename/content_type (#219)" {
    try testing.expectError(error.HeaderInjection, validate(.{
        .to = "u@x.io",
        .subject = "s",
        .text = "b",
        .attachments = &.{.{ .filename = "evil\r\nX: 1", .content_type = "text/plain", .data = "x" }},
    }));
    try testing.expectError(error.HeaderInjection, validate(.{
        .to = "u@x.io",
        .subject = "s",
        .text = "b",
        .attachments = &.{.{ .filename = "ok.txt", .content_type = "text/plain\x00", .data = "x" }},
    }));
}

test "checkSize rejects an over-cap message and accepts one within the cap (#219)" {
    // 9 bytes of data → 12 base64 bytes + ~128 header slack + subject/body — well over a 10-byte cap.
    const big = MailMessage{ .to = "u@x.io", .subject = "s", .text = "b", .attachments = &.{.{ .filename = "a.bin", .content_type = "application/octet-stream", .data = "123456789" }} };
    try testing.expectError(error.MailTooLarge, checkSize(big, 10));
    // The default 10 MiB cap comfortably admits the same message.
    try checkSize(big, 10 * 1024 * 1024);
    // An attachment-free message under the cap is fine.
    try checkSize(.{ .to = "u@x.io", .subject = "s", .text = "b" }, 1024);
}

test "toEmail carries attachments onto the backend Email (#219)" {
    const e = toEmail(.{ .to = "u@x.io", .subject = "s", .text = "t", .attachments = &.{.{ .filename = "a.ics", .content_type = "text/calendar", .data = "X" }} });
    try testing.expectEqual(@as(usize, 1), e.attachments.len);
    try testing.expectEqualStrings("a.ics", e.attachments[0].filename);
    // Default: no attachments.
    const e2 = toEmail(.{ .to = "u@x.io", .subject = "s", .text = "t" });
    try testing.expectEqual(@as(usize, 0), e2.attachments.len);
}

test "MailMessage JSON round-trip preserves attachments as base64 in the queue payload (#219)" {
    const a = testing.allocator;
    const msg = MailMessage{
        .to = "user@example.com",
        .subject = "Invite",
        .text = "See attached.",
        .attachments = &.{.{ .filename = "invite.ics", .content_type = "text/calendar", .data = "BEGIN\x00\xffEND" }},
    };
    const json = try std.json.Stringify.valueAlloc(a, msg, .{});
    defer a.free(json);
    // The durable row carries base64, not raw binary.
    try testing.expect(std.mem.indexOf(u8, json, "\"data_b64\":\"") != null);

    const parsed = try std.json.parseFromSlice(MailMessage, a, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.attachments.len);
    try testing.expectEqualStrings("invite.ics", parsed.value.attachments[0].filename);
    try testing.expectEqualStrings("text/calendar", parsed.value.attachments[0].content_type);
    try testing.expectEqualStrings("BEGIN\x00\xffEND", parsed.value.attachments[0].data);
}

test "send rejects an over-cap message loudly (#219)" {
    var env = try EnforceEnv.init(.{ .max_message_bytes = 32 });
    defer env.deinit();
    try testing.expectError(error.MailTooLarge, send(&env.app, std.testing.allocator, .{
        .to = "user@example.com",
        .subject = "Invite",
        .text = "See attached.",
        .attachments = &.{.{ .filename = "invite.ics", .content_type = "text/calendar", .data = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n" }},
    }));
}

test "an oversized html body warns but still sends (never an error)" {
    const a = std.testing.allocator;
    const big = try a.alloc(u8, gmail_clip_warn_bytes + 1);
    defer a.free(big);
    @memset(big, 'x');
    var env = try EnforceEnv.init(.{});
    defer env.deinit();
    // No mailer wired → log-fallback path; the send must succeed despite the warning.
    try send(&env.app, a, .{ .to = "u@x.io", .subject = "big", .html = big });
}
