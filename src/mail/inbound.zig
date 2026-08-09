//! Inbound bounce/complaint webhook ingestion (#154). `POST /api/mail/webhooks/:provider` receives
//! delivery-event payloads from SES/Postmark, maps them to normalized suppression events
//! (`suppression.parseProvider`), and upserts a `_suppressions` row per hard bounce / complaint.
//!
//! This MIRRORS the outbound webhook signing pattern (`src/webhook.zig`) but binds MORE context: the
//! operator configures a shared secret (`.mail = .{ .webhook_secret = "…" }`) and the sender computes
//! `hex(HMAC-SHA256(secret, "<timestamp>.<provider>.<account>.<body>"))` into `X-Signature`
//! (timestamp in `X-Webhook-Timestamp`, provider from the `:provider` path, account from the optional
//! `X-Account-Id` header). We RECOMPUTE it and compare CONSTANT-TIME (`crypto.timingSafeEql`) — a
//! wrong/missing signature is REJECTED (401), fail closed. When no secret is configured the route is
//! DISABLED (404): ingestion is strictly opt-in, so an app that never sets it up exposes nothing.
//! (NOTE: this is the MAIL inbound signed-string shape, defined locally here — it deliberately does
//! NOT change `src/webhook.zig`'s outbound `signBody`.)
//!
//! ATTRIBUTION / SCOPE — be honest about the semantics (review I2): a GENUINE provider webhook
//! (SES SNS / Postmark) CANNOT compute our HMAC and CANNOT add `X-Account-Id`, so it cannot reach
//! this endpoint authenticated and, even if relayed with account="", produces a GLOBAL suppression
//! (blocks the address for EVERY tenant). The per-account path is therefore for an OPERATOR-RUN
//! RELAY that receives the raw provider event, decides the owning account, injects `X-Account-Id`,
//! and signs `"<ts>.<provider>.<account>.<body>"`. Because the account is part of the signed string,
//! a replayer cannot redirect a captured event to another tenant by editing the header. Do not
//! assume per-tenant isolation from a raw provider webhook — only the signed relay provides it.
//!
//! SECURITY:
//!   * Constant-time signature compare — no byte-position timing oracle on the secret.
//!   * The signed string binds timestamp + provider + account + body, so neither the body nor the
//!     target account can be swapped under a captured signature.
//!   * A replay-freshness window (`max_skew_s`) rejects a stale `X-Webhook-Timestamp`.
//!   * All DB writes are parameter-bound; the recipient address from the payload is bound, never
//!     interpolated.

const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const http = @import("../http.zig");
const db = @import("../db.zig");
const crypto = @import("../crypto.zig");
const clock = @import("../clock.zig");
const suppression = @import("suppression.zig");
const ApiError = @import("../api/error.zig").ApiError;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const sig_header = "x-signature";
pub const ts_header = "x-webhook-timestamp";
/// Optional header scoping the suppression to a single account (else a GLOBAL suppression).
pub const account_header = "x-account-id";
/// Replay-freshness window (M5): reject an `X-Webhook-Timestamp` more than this many seconds from
/// now (in either direction). 5 minutes accommodates clock skew on a relay without leaving a wide
/// replay window.
pub const max_skew_s: i64 = 300;

/// The MAIL inbound signed string: `hex(HMAC-SHA256(secret, "<ts>.<provider>.<account>.<body>"))`.
/// Defined LOCALLY (not via `webhook.signBody`) so this binds provider + account WITHOUT changing the
/// outbound webhook signing scheme. Public so a relay / tests can recompute it.
pub fn signMailInbound(alloc: std.mem.Allocator, secret: []const u8, timestamp: []const u8, provider: []const u8, account: []const u8, body: []const u8) ![]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    var h = HmacSha256.init(secret);
    h.update(timestamp);
    h.update(".");
    h.update(provider);
    h.update(".");
    h.update(account);
    h.update(".");
    h.update(body);
    h.final(&mac);
    const hex = std.fmt.bytesToHex(mac, .lower);
    return alloc.dupe(u8, &hex);
}

/// Recompute the expected signature (binding provider + account) and compare it CONSTANT-TIME to
/// `provided`. Returns false on any mismatch / empty input — fail closed. Public for direct testing.
pub fn verifySignature(alloc: std.mem.Allocator, secret: []const u8, timestamp: []const u8, provider: []const u8, account: []const u8, body: []const u8, provided: []const u8) bool {
    if (secret.len == 0 or provided.len == 0 or timestamp.len == 0) return false;
    const expected = signMailInbound(alloc, secret, timestamp, provider, account, body) catch return false;
    defer alloc.free(expected);
    return crypto.timingSafeEql(expected, provided);
}

/// True iff `timestamp` (decimal unix seconds) is within `max_skew_s` of `now_unix` (M5). A
/// non-integer or out-of-window timestamp is rejected (fail closed).
pub fn timestampFresh(timestamp: []const u8, now_unix: i64) bool {
    const ts = std.fmt.parseInt(i64, std.mem.trim(u8, timestamp, " \t"), 10) catch return false;
    const delta = ts - now_unix;
    return delta >= -max_skew_s and delta <= max_skew_s;
}

/// Parse `body` for `provider` and upsert a suppression row per normalized event (scoped to
/// `account`, or global when `account` is ""). On a `writer` connection. Returns the number of
/// suppressions written. A malformed payload propagates `error.SyntaxError`.
pub fn ingest(io: std.Io, alloc: std.mem.Allocator, w: *db.Db, provider: suppression.Provider, account: []const u8, body: []const u8, source: []const u8) !usize {
    const events = try suppression.parseProvider(alloc, provider, body);
    defer {
        for (events) |ev| alloc.free(ev.email);
        alloc.free(events);
    }
    for (events) |ev| {
        try suppression.upsert(io, alloc, w, account, ev.email, ev.reason, source);
    }
    return events.len;
}

/// `POST /api/mail/webhooks/:provider` route handler. Verifies the shared-secret signature, maps the
/// provider payload, and upserts suppressions. 404 when the subsystem is not configured or the
/// provider is unknown; 401 on a bad signature; 400 on malformed JSON; 200 with a written-count
/// otherwise.
pub fn webhook_handler(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const secret = app.mail.webhook_secret;
    // Ingestion is opt-in: no secret → the route does not exist.
    if (secret.len == 0) return ApiError.notFound().toResponse(ctx.allocator.a);

    const provider_name = ctx.param("provider") orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    const provider: suppression.Provider = if (std.mem.eql(u8, provider_name, "ses"))
        .ses
    else if (std.mem.eql(u8, provider_name, "postmark"))
        .postmark
    else
        return ApiError.notFound().toResponse(ctx.allocator.a);

    // Account is part of the SIGNED string (I2), so a tampered header without a matching signature
    // fails verification below — a replayer cannot redirect the event to another tenant.
    const account = ctx.header(account_header) orelse "";
    const sig = ctx.header(sig_header) orelse "";
    const ts = ctx.header(ts_header) orelse "";

    // Replay-freshness (M5): reject a stale/invalid timestamp before doing any work.
    if (!timestampFresh(ts, clock.nowUnix(app.io))) {
        return ApiError.withCode(401, .unauthorized, "Stale or invalid webhook timestamp.").toResponse(ctx.allocator.a);
    }

    // Verify the shared-secret signature over ts+provider+account+body (constant-time). Fail closed.
    if (!verifySignature(ctx.allocator.a, secret, ts, provider_name, account, ctx.body, sig)) {
        return ApiError.withCode(401, .unauthorized, "Invalid webhook signature.").toResponse(ctx.allocator.a);
    }

    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const n = ingest(app.io, ctx.allocator.a, w, provider, account, ctx.body, provider_name) catch |e| switch (e) {
        error.SyntaxError, error.UnexpectedEndOfInput => return (ApiError.badRequest("Malformed webhook payload.")).toResponse(ctx.allocator.a),
        else => return e,
    };

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(ctx.allocator.a);
    try obj.put(ctx.allocator.a, "suppressed", .{ .integer = @intCast(n) });
    return .{
        .status = 200,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator.a, std.json.Value{ .object = obj }, .{}),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const migrations = @import("../migrations.zig");
const App = @import("../app.zig").App;

test "verifySignature accepts a correct HMAC (ts+provider+account+body) and rejects tampering" {
    const a = testing.allocator;
    const secret = "topsecret";
    const ts = "1700000000";
    const body =
        \\{"notificationType":"Bounce"}
    ;
    const good = try signMailInbound(a, secret, ts, "ses", "acc1", body);
    defer a.free(good);
    try testing.expect(verifySignature(a, secret, ts, "ses", "acc1", body, good));
    // Wrong secret / body / ts / provider / ACCOUNT / empty sig → all rejected (account is bound now).
    try testing.expect(!verifySignature(a, "other", ts, "ses", "acc1", body, good));
    try testing.expect(!verifySignature(a, secret, ts, "ses", "acc1", "{\"x\":1}", good));
    try testing.expect(!verifySignature(a, secret, "1700000001", "ses", "acc1", body, good));
    try testing.expect(!verifySignature(a, secret, ts, "postmark", "acc1", body, good));
    try testing.expect(!verifySignature(a, secret, ts, "ses", "acc2", body, good)); // tampered account
    try testing.expect(!verifySignature(a, secret, ts, "ses", "acc1", body, ""));
}

test "timestampFresh accepts in-window, rejects stale / future / garbage (M5)" {
    const now: i64 = 1_700_000_000;
    var buf: [32]u8 = undefined;
    try testing.expect(timestampFresh(try std.fmt.bufPrint(&buf, "{d}", .{now}), now));
    try testing.expect(timestampFresh(try std.fmt.bufPrint(&buf, "{d}", .{now - max_skew_s}), now));
    try testing.expect(!timestampFresh(try std.fmt.bufPrint(&buf, "{d}", .{now - max_skew_s - 1}), now));
    try testing.expect(!timestampFresh(try std.fmt.bufPrint(&buf, "{d}", .{now + max_skew_s + 1}), now));
    try testing.expect(!timestampFresh("not-a-number", now));
    try testing.expect(!timestampFresh("", now));
}

test "ingest maps an SES permanent bounce into a suppression row" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    const a = testing.allocator;
    const body =
        \\{"notificationType":"Bounce","bounce":{"bounceType":"Permanent","bouncedRecipients":[{"emailAddress":"bad@x.io"}]}}
    ;
    const n = try ingest(testing.io, a, &d, .ses, "acc1", body, "ses");
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(try suppression.isSuppressed(a, &d, "acc1", "bad@x.io", .transactional));
}

test "webhook_handler rejects an invalid signature (401, fail closed)" {
    // No pool is touched on the rejection path, so an undefined pool is safe here.
    // Use a FRESH timestamp so the request passes the freshness gate and actually
    // exercises the signature check.
    const a = std.testing.allocator;
    var app = App{ .allocator = a, .io = testing.io, .pool = undefined, .mail = .{ .webhook_secret = "shh" } };
    const ts = try std.fmt.allocPrint(a, "{d}", .{clock.nowUnix(testing.io)});
    defer a.free(ts);
    const headers = [_]http.Param{
        .{ .key = sig_header, .value = "deadbeef" }, // not the real signature
        .{ .key = ts_header, .value = ts },
    };
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/api/mail/webhooks/ses",
        .allocator = RequestArena.forTest(a),
        .app = &app,
        .body = "{\"notificationType\":\"Bounce\"}",
        .params = &.{.{ .key = "provider", .value = "ses" }},
        .headers = &headers,
    };
    const res = try webhook_handler(&ctx);
    defer a.free(res.body);
    try testing.expectEqual(@as(u16, 401), res.status);
}

test "webhook_handler: signed-account event verifies (200); tampering account → 401 (I2)" {
    const ga = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", ga);
    defer ga.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(ga, "{s}/inbound.db", .{dir_path}, 0);
    defer ga.free(db_path);
    var pool = try db.Pool.init(ga, testing.io, db_path);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
    }
    var app = App{ .allocator = ga, .io = testing.io, .pool = &pool, .mail = .{ .webhook_secret = "relay-secret" } };

    const body =
        \\{"notificationType":"Bounce","bounce":{"bounceType":"Permanent","bouncedRecipients":[{"emailAddress":"bad@x.io"}]}}
    ;
    const a = ga;
    const ts = try std.fmt.allocPrint(a, "{d}", .{clock.nowUnix(testing.io)});
    defer a.free(ts);
    // A relay signs ts.provider.account.body and injects X-Account-Id.
    const sig = try signMailInbound(a, "relay-secret", ts, "ses", "acc1", body);
    defer a.free(sig);

    // (1) Correctly signed for acc1 → 200, suppression scoped to acc1 (NOT global).
    {
        const headers = [_]http.Param{
            .{ .key = sig_header, .value = sig },
            .{ .key = ts_header, .value = ts },
            .{ .key = account_header, .value = "acc1" },
        };
        var ctx = http.RequestCtx{ .method = .POST, .path = "/api/mail/webhooks/ses", .allocator = RequestArena.forTest(a), .app = &app, .body = body, .params = &.{.{ .key = "provider", .value = "ses" }}, .headers = &headers };
        const res = try webhook_handler(&ctx);
        defer a.free(res.body);
        try testing.expectEqual(@as(u16, 200), res.status);
    }
    {
        var r = try pool.acquireReader();
        defer pool.releaseReader(&r);
        try testing.expect(try suppression.isSuppressed(a, &r, "acc1", "bad@x.io", .transactional));
        try testing.expect(!try suppression.isSuppressed(a, &r, "acc2", "bad@x.io", .transactional)); // not cross-tenant
    }

    // (2) Tamper the account header to acc2 WITHOUT re-signing → signature mismatch → 401.
    {
        const headers = [_]http.Param{
            .{ .key = sig_header, .value = sig },
            .{ .key = ts_header, .value = ts },
            .{ .key = account_header, .value = "acc2" }, // not what was signed
        };
        var ctx = http.RequestCtx{ .method = .POST, .path = "/api/mail/webhooks/ses", .allocator = RequestArena.forTest(a), .app = &app, .body = body, .params = &.{.{ .key = "provider", .value = "ses" }}, .headers = &headers };
        const res = try webhook_handler(&ctx);
        defer a.free(res.body);
        try testing.expectEqual(@as(u16, 401), res.status);
    }
}

test "webhook_handler 404s when no secret is configured (ingestion opt-in)" {
    const a = std.testing.allocator;
    var app = App{ .allocator = a, .io = testing.io, .pool = undefined, .mail = .{} };
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/api/mail/webhooks/ses",
        .allocator = RequestArena.forTest(a),
        .app = &app,
        .params = &.{.{ .key = "provider", .value = "ses" }},
    };
    const res = try webhook_handler(&ctx);
    defer a.free(res.body);
    try testing.expectEqual(@as(u16, 404), res.status);
}
