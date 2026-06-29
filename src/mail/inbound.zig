//! Inbound bounce/complaint webhook ingestion (#154). `POST /api/mail/webhooks/:provider` receives
//! delivery-event payloads from SES/Postmark, maps them to normalized suppression events
//! (`suppression.parseProvider`), and upserts a `_suppressions` row per hard bounce / complaint.
//!
//! This MIRRORS the outbound webhook signing pattern (`src/webhook.zig`): the operator configures a
//! shared secret (`.mail = .{ .webhook_secret = "…" }`) and the sender computes
//! `hex(HMAC-SHA256(secret, "<timestamp>.<body>"))` into `X-Signature` (timestamp in
//! `X-Webhook-Timestamp`). We RECOMPUTE it and compare CONSTANT-TIME (`crypto.timingSafeEql`) — a
//! wrong/missing signature is REJECTED (401), fail closed. When no secret is configured the route is
//! DISABLED (404): ingestion is strictly opt-in, so an app that never sets it up exposes nothing.
//!
//! SECURITY:
//!   * Constant-time signature compare — no byte-position timing oracle on the secret.
//!   * The signed string binds the timestamp, so a body cannot be swapped under a captured signature.
//!   * All DB writes are parameter-bound; the recipient address from the payload is bound, never
//!     interpolated.

const std = @import("std");
const http = @import("../http.zig");
const db = @import("../db.zig");
const crypto = @import("../crypto.zig");
const webhook = @import("../webhook.zig");
const suppression = @import("suppression.zig");
const ApiError = @import("../api/error.zig").ApiError;

pub const sig_header = "x-signature";
pub const ts_header = "x-webhook-timestamp";
/// Optional header scoping the suppression to a single account (else a GLOBAL suppression).
pub const account_header = "x-account-id";

/// Recompute the expected signature and compare it CONSTANT-TIME to `provided`. Returns false on any
/// mismatch / empty input — fail closed. Public so it can be unit-tested directly.
pub fn verifySignature(alloc: std.mem.Allocator, secret: []const u8, timestamp: []const u8, body: []const u8, provided: []const u8) bool {
    if (secret.len == 0 or provided.len == 0 or timestamp.len == 0) return false;
    const expected = webhook.signBody(alloc, secret, timestamp, body) catch return false;
    defer alloc.free(expected);
    return crypto.timingSafeEql(expected, provided);
}

/// Parse `body` for `provider` and upsert a suppression row per normalized event (scoped to
/// `account`, or global when `account` is ""). On a `writer` connection. Returns the number of
/// suppressions written. A malformed payload propagates `error.SyntaxError`.
pub fn ingest(io: std.Io, alloc: std.mem.Allocator, w: *db.Db, provider: suppression.Provider, account: []const u8, body: []const u8, source: []const u8) !usize {
    const events = try suppression.parseProvider(alloc, provider, body);
    for (events) |ev| {
        try suppression.upsert(io, w, account, ev.email, ev.reason, source);
    }
    return events.len;
}

/// `POST /api/mail/webhooks/:provider` route handler. Verifies the shared-secret signature, maps the
/// provider payload, and upserts suppressions. 404 when the subsystem is not configured or the
/// provider is unknown; 401 on a bad signature; 400 on malformed JSON; 200 with a written-count
/// otherwise.
pub fn webhook_handler(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator);
    const secret = app.mail.webhook_secret;
    // Ingestion is opt-in: no secret → the route does not exist.
    if (secret.len == 0) return ApiError.notFound().toResponse(ctx.allocator);

    const provider_name = ctx.param("provider") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const provider: suppression.Provider = if (std.mem.eql(u8, provider_name, "ses"))
        .ses
    else if (std.mem.eql(u8, provider_name, "postmark"))
        .postmark
    else
        return ApiError.notFound().toResponse(ctx.allocator);

    // Verify the shared-secret signature (constant-time). Fail closed on any mismatch.
    const sig = ctx.header(sig_header) orelse "";
    const ts = ctx.header(ts_header) orelse "";
    if (!verifySignature(ctx.allocator, secret, ts, ctx.body, sig)) {
        return (ApiError{ .status = 401, .message = "Invalid webhook signature." }).toResponse(ctx.allocator);
    }

    const account = ctx.header(account_header) orelse "";

    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const n = ingest(app.io, ctx.allocator, w, provider, account, ctx.body, provider_name) catch |e| switch (e) {
        error.SyntaxError, error.UnexpectedEndOfInput => return (ApiError.badRequest("Malformed webhook payload.")).toResponse(ctx.allocator),
        else => return e,
    };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(ctx.allocator, "suppressed", .{ .integer = @intCast(n) });
    return .{
        .status = 200,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = obj }, .{}),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const migrations = @import("../migrations.zig");
const App = @import("../app.zig").App;

test "verifySignature accepts a correct HMAC and rejects tampering (constant-time)" {
    const a = testing.allocator;
    const secret = "topsecret";
    const ts = "1700000000";
    const body =
        \\{"notificationType":"Bounce"}
    ;
    const good = try webhook.signBody(a, secret, ts, body);
    defer a.free(good);
    try testing.expect(verifySignature(a, secret, ts, body, good));
    // Wrong secret, wrong body, wrong ts, empty sig → all rejected.
    try testing.expect(!verifySignature(a, "other", ts, body, good));
    try testing.expect(!verifySignature(a, secret, ts, "{\"x\":1}", good));
    try testing.expect(!verifySignature(a, secret, "1700000001", body, good));
    try testing.expect(!verifySignature(a, secret, ts, body, ""));
    try testing.expect(!verifySignature(a, "", ts, body, good));
}

test "ingest maps an SES permanent bounce into a suppression row" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\{"notificationType":"Bounce","bounce":{"bounceType":"Permanent","bouncedRecipients":[{"emailAddress":"bad@x.io"}]}}
    ;
    const n = try ingest(testing.io, a, &d, .ses, "acc1", body, "ses");
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(try suppression.isSuppressed(&d, "acc1", "bad@x.io"));
}

test "webhook_handler rejects an invalid signature (401, fail closed)" {
    // No pool is touched on the rejection path, so an undefined pool is safe here. ctx.allocator is
    // an arena (mirrors production) so the response body is reclaimed (no leak).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var app = App{ .allocator = testing.allocator, .io = testing.io, .pool = undefined, .mail = .{ .webhook_secret = "shh" } };
    const headers = [_]http.Param{
        .{ .key = sig_header, .value = "deadbeef" }, // not the real signature
        .{ .key = ts_header, .value = "1700000000" },
    };
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/api/mail/webhooks/ses",
        .allocator = arena.allocator(),
        .app = &app,
        .body = "{\"notificationType\":\"Bounce\"}",
        .params = &.{.{ .key = "provider", .value = "ses" }},
        .headers = &headers,
    };
    const res = try webhook_handler(&ctx);
    try testing.expectEqual(@as(u16, 401), res.status);
}

test "webhook_handler 404s when no secret is configured (ingestion opt-in)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var app = App{ .allocator = testing.allocator, .io = testing.io, .pool = undefined, .mail = .{} };
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/api/mail/webhooks/ses",
        .allocator = arena.allocator(),
        .app = &app,
        .params = &.{.{ .key = "provider", .value = "ses" }},
    };
    const res = try webhook_handler(&ctx);
    try testing.expectEqual(@as(u16, 404), res.status);
}
