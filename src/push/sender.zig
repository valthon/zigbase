//! Web Push delivery (#223) — composes an RFC 8291 encrypted body + an RFC 8292 VAPID
//! `Authorization` header and POSTs it to a browser push endpoint. This is the wiring layer
//! over the verified crypto core (`encrypt.zig` / `vapid.zig`); it never re-implements any
//! crypto, only calls those `pub` fns.
//!
//! Delivery posture (issue #223, mirroring `webhook.zig`'s terminal-vs-retryable split):
//!   * 2xx           → `.delivered`
//!   * 404 / 410     → `.gone`   — the subscription is dead; the caller PRUNES it and never
//!                                 retries (a gone endpoint stays gone).
//!   * everything else (5xx, 429, transport error, timeout) → `.failed` — transient; the
//!                                 caller may retry with backoff.
//!
//! A dead or failing push NEVER propagates as an error to the request that triggered it (the
//! issue's hard rule): `deliver` returns the tri-state. A Zig `error` is reserved for
//! programmer/data misuse — an un-decodable subscription key — which a caller handles as
//! terminal (there is no point retrying a corrupt key).

const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const encrypt = @import("encrypt.zig");
const vapid = @import("vapid.zig");
const config = @import("config.zig");
const clock = @import("../clock.zig");
const http_client = @import("../http_client.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const b64 = std.base64.url_safe_no_pad;

/// VAPID JWT lifetime: 12h from issuance. RFC 8292 caps `exp` at 24h; 12h is a comfortable
/// margin under that ceiling.
const jwt_ttl_s: i64 = 12 * 3600;

/// A browser `PushSubscription` (the fields a client posts up after `pushManager.subscribe`).
/// `p256dh` is base64url of the 65-byte UA public key; `auth` is base64url of the 16-byte
/// UA auth secret.
pub const PushSubscription = struct {
    endpoint: []const u8,
    p256dh: []const u8,
    auth: []const u8,
};

/// The notification payload. The service worker receives the JSON `{title, body, data}`;
/// `data` is opaque raw JSON passed through verbatim (default `null`). `ttl_s` is the push
/// service `TTL` header — how long it should hold the message for an offline device.
pub const PushMessage = struct {
    title: []const u8,
    body: []const u8 = "",
    data: []const u8 = "",
    ttl_s: u32 = 60,
};

/// Tri-state delivery outcome (issue #223). `.gone` is the prune signal.
pub const PushResult = enum { delivered, gone, failed };

pub const Error = error{
    /// `p256dh`/`auth` was not valid base64url of the expected length — a corrupt stored
    /// subscription. Terminal: retrying will never help.
    InvalidSubscriptionKey,
} || std.mem.Allocator.Error;

/// Map an HTTP status to the tri-state (pure; separated for direct testing).
pub fn classify(status: u16) PushResult {
    if (status >= 200 and status < 300) return .delivered;
    if (status == 404 or status == 410) return .gone;
    return .failed;
}

/// The origin (scheme://host[:port]) of a push endpoint URL — the VAPID JWT `aud`. Falls back
/// to the whole URL if it has no path (already just an origin).
pub fn originOf(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
    const after = scheme + 3;
    const rel = std.mem.indexOfScalarPos(u8, url, after, '/');
    return if (rel) |slash| url[0..slash] else url;
}

/// Build the `{title, body, data}` JSON the service worker receives. `title`/`body` are
/// JSON-escaped; `data` is passed through as raw JSON (`null` when empty).
fn buildPayload(alloc: std.mem.Allocator, msg: PushMessage) ![]u8 {
    const title = try std.json.Stringify.valueAlloc(alloc, msg.title, .{});
    const body = try std.json.Stringify.valueAlloc(alloc, msg.body, .{});
    const data: []const u8 = if (msg.data.len == 0) "null" else msg.data;
    return std.fmt.allocPrint(alloc, "{{\"title\":{s},\"body\":{s},\"data\":{s}}}", .{ title, body, data });
}

/// Encrypt + POST `msg` to `sub`'s endpoint using the VAPID identity in `cfg`. Returns the
/// tri-state (`.delivered`/`.gone`/`.failed`); only an un-decodable subscription key surfaces
/// as an `error`. A fresh ephemeral ECDH keypair and random salt are generated per message.
pub fn deliver(ctx: *Ctx, cfg: config.Runtime, sub: PushSubscription, msg: PushMessage) Error!PushResult {
    const a = ctx.arena;
    const io = ctx.app.io;

    // (1) Decode the subscriber's keys (a corrupt/short key is terminal → error).
    const ua_public = decodeExact(65, sub.p256dh) catch return error.InvalidSubscriptionKey;
    const auth_secret = decodeExact(16, sub.auth) catch return error.InvalidSubscriptionKey;

    // (2) Fresh per-message application-server ephemeral keypair (ECDH over P-256; the same
    // curve/scalar encoding EcdsaP256 uses) and random 16-byte salt.
    const eph = Ecdsa.KeyPair.generate(io);
    const as_public = eph.public_key.toUncompressedSec1();
    const as_private = eph.secret_key.toBytes();
    var salt: [16]u8 = undefined;
    io.random(&salt);

    // (3) Build + encrypt the payload (RFC 8291 aes128gcm).
    const payload = try buildPayload(a.a, msg);
    const body = encrypt.encrypt(a.a, io, payload, ua_public, auth_secret, as_public, as_private, salt) catch |e| switch (e) {
        error.InvalidPublicKey => return error.InvalidSubscriptionKey,
        error.OutOfMemory => return error.OutOfMemory,
    };

    // (4) VAPID Authorization header (RFC 8292 ES256 JWT + raw key).
    const now = clock.nowUnix(io);
    const auth_header = vapid.vapidAuthHeader(a.a, io, originOf(sub.endpoint), cfg.subject, cfg.vapid_public, cfg.vapid_private, now, now + jwt_ttl_s) catch return error.InvalidSubscriptionKey;

    // (5) POST. A transport error is transient → `.failed`.
    var headers: std.ArrayList(http_client.Header) = .empty;
    try headers.append(a.a, .{ .name = "TTL", .value = try std.fmt.allocPrint(a.a, "{d}", .{msg.ttl_s}) });
    try headers.append(a.a, .{ .name = "Content-Encoding", .value = "aes128gcm" });
    try headers.append(a.a, .{ .name = "Content-Type", .value = "application/octet-stream" });
    try headers.append(a.a, .{ .name = "Authorization", .value = auth_header });

    const res = ctx.http().request(.{
        .method = .POST,
        .url = sub.endpoint,
        .headers = headers.items,
        .body = body,
        .timeout_ms = 10_000,
    }) catch return .failed;

    return classify(res.status);
}

/// Decode `s` (base64url, no padding) into exactly `N` bytes.
fn decodeExact(comptime N: usize, s: []const u8) ![N]u8 {
    const size = try b64.Decoder.calcSizeForSlice(s);
    if (size != N) return error.InvalidLength;
    var out: [N]u8 = undefined;
    try b64.Decoder.decode(&out, s);
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const App = @import("../app.zig").App;
const testcapture = @import("../testcapture.zig");

test "classify maps status families to the tri-state" {
    try testing.expectEqual(PushResult.delivered, classify(200));
    try testing.expectEqual(PushResult.delivered, classify(201));
    try testing.expectEqual(PushResult.gone, classify(404));
    try testing.expectEqual(PushResult.gone, classify(410));
    try testing.expectEqual(PushResult.failed, classify(429));
    try testing.expectEqual(PushResult.failed, classify(500));
    try testing.expectEqual(PushResult.failed, classify(400));
}

test "originOf extracts scheme://host[:port]" {
    try testing.expectEqualStrings("https://push.example.com", originOf("https://push.example.com/wpush/v1/abc"));
    try testing.expectEqualStrings("https://fcm.googleapis.com", originOf("https://fcm.googleapis.com/fcm/send/xyz:APA91"));
    try testing.expectEqualStrings("https://p.example:8443", originOf("https://p.example:8443/x"));
    try testing.expectEqualStrings("https://p.example", originOf("https://p.example")); // no path
}

test "buildPayload JSON-escapes title/body and passes data through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"title\":\"Hi\",\"body\":\"there\",\"data\":null}",
        try buildPayload(a, .{ .title = "Hi", .body = "there" }),
    );
    // Opaque data is spliced in raw; a quote in the title is escaped.
    try testing.expectEqualStrings(
        "{\"title\":\"a\\\"b\",\"body\":\"\",\"data\":{\"n\":1}}",
        try buildPayload(a, .{ .title = "a\"b", .data = "{\"n\":1}" }),
    );
}

// --- Delivery over the test HTTP capture/mock seam ---------------------------

const TestEnv = struct {
    arena: std.heap.ArenaAllocator,
    app: App,

    fn init() TestEnv {
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .app = App{ .allocator = testing.allocator, .io = testing.io, .pool = undefined },
        };
    }
    fn ctx(self: *TestEnv) Ctx {
        return Ctx{ .app = &self.app, .arena = RequestArena.from(&self.arena), .rctx = .{}, .request = null, .bound_conn = null };
    }
    fn deinit(self: *TestEnv) void {
        self.arena.deinit();
    }
};

// A known subscription: the RFC 8291 Appendix A user-agent keypair.
const test_p256dh = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4";
const test_auth = "BTBZMqHH6r4Tts7J_aSIgg";
const test_endpoint = "https://push.example.com/wpush/v1/subscription-abc";

fn testCfg(a: std.mem.Allocator) !config.Runtime {
    const kp = try config.generateKeypair(a, testing.io);
    return config.resolve("mailto:ops@example.com", kp.public_b64, kp.private_b64);
}

test "deliver: composes a well-formed POST and maps 201 → delivered" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("push.example.com", .{ .status = 201 });

    var env = TestEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    const cfg = try testCfg(env.arena.allocator());

    const res = try deliver(&cx, cfg, .{ .endpoint = test_endpoint, .p256dh = test_p256dh, .auth = test_auth }, .{ .title = "Hello", .body = "world", .ttl_s = 120 });
    try testing.expectEqual(PushResult.delivered, res);

    // Inspect the recorded request: right method, endpoint, and Web Push headers + an
    // encrypted (non-empty) body.
    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());
    const rq = testcapture.http.requestAt(0).?;
    try testing.expectEqual(http_client.Method.POST, rq.method);
    try testing.expectEqualStrings(test_endpoint, rq.url);
    try testing.expect(rq.body != null and rq.body.?.len > 86); // header(86) + ct + tag

    var have_ce = false;
    var have_ttl = false;
    var have_ct = false;
    var vapid_ok = false;
    for (rq.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Encoding")) {
            have_ce = true;
            try testing.expectEqualStrings("aes128gcm", h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "TTL")) {
            have_ttl = true;
            try testing.expectEqualStrings("120", h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
            have_ct = true;
            try testing.expectEqualStrings("application/octet-stream", h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "Authorization")) {
            // `vapid t=<JWT>, k=<base64url pubkey>`
            vapid_ok = std.mem.startsWith(u8, h.value, "vapid t=") and std.mem.indexOf(u8, h.value, ", k=") != null;
        }
    }
    try testing.expect(have_ce and have_ttl and have_ct and vapid_ok);
}

test "deliver: 410 → gone (prune), 500 → failed (retry)" {
    if (!testcapture.enabled) return error.SkipZigTest;

    inline for (.{ .{ 410, PushResult.gone }, .{ 500, PushResult.failed }, .{ 404, PushResult.gone } }) |case| {
        testcapture.http.reset();
        testcapture.http.enable(true);
        testcapture.http.mock("push.example.com", .{ .status = case[0] });

        var env = TestEnv.init();
        defer env.deinit();
        var cx = env.ctx();
        const cfg = try testCfg(env.arena.allocator());
        const res = try deliver(&cx, cfg, .{ .endpoint = test_endpoint, .p256dh = test_p256dh, .auth = test_auth }, .{ .title = "x" });
        try testing.expectEqual(case[1], res);
    }
    testcapture.http.reset();
}

test "deliver: a corrupt subscription key is a terminal error (no network)" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true); // block unmocked: proves no POST is attempted

    var env = TestEnv.init();
    defer env.deinit();
    var cx = env.ctx();
    const cfg = try testCfg(env.arena.allocator());
    try testing.expectError(error.InvalidSubscriptionKey, deliver(&cx, cfg, .{ .endpoint = test_endpoint, .p256dh = "not-a-valid-key", .auth = test_auth }, .{ .title = "x" }));
    try testing.expectEqual(@as(usize, 0), testcapture.http.requestCount());
}
