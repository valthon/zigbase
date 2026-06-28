//! CAPTCHA verification for reCAPTCHA v2/v3, hCaptcha, and Cloudflare Turnstile.
//!
//! The public entry point is `verify(provider, secret, token, alloc, client) !Result`.
//! Consumers reach it through `ctx.verifyCaptcha(provider, token)` which reads the
//! configured `app.captcha_secret` and short-circuits with `.{.ok=true}` when the secret
//! is empty (the dev-bypass — no live provider needed for local development or unit tests).
//!
//! ## Provider URL + response schema
//!
//! | Provider       | Verify URL                                                               | score? | action? | hostname? |
//! |---------------|--------------------------------------------------------------------------|--------|---------|-----------|
//! | recaptcha_v2  | https://www.google.com/recaptcha/api/siteverify                          | no     | no      | yes       |
//! | recaptcha_v3  | https://www.google.com/recaptcha/api/siteverify                          | yes    | yes     | yes       |
//! | hcaptcha      | https://hcaptcha.com/siteverify                                           | no     | no      | yes       |
//! | turnstile     | https://challenges.cloudflare.com/turnstile/v0/siteverify                 | no     | no      | yes       |
//!
//! All providers accept a POST with `application/x-www-form-urlencoded` body
//! `secret=<key>&response=<token>` and return JSON with at least `{"success": bool}`.
//! Error codes (when present) live in the `error-codes` JSON array.

const std = @import("std");
const http_client = @import("http_client.zig");

/// The four supported CAPTCHA providers.
pub const Provider = enum {
    recaptcha_v2,
    recaptcha_v3,
    hcaptcha,
    turnstile,

    /// The siteverify URL for this provider.
    pub fn verifyUrl(self: Provider) []const u8 {
        return switch (self) {
            .recaptcha_v2, .recaptcha_v3 => "https://www.google.com/recaptcha/api/siteverify",
            .hcaptcha => "https://hcaptcha.com/siteverify",
            .turnstile => "https://challenges.cloudflare.com/turnstile/v0/siteverify",
        };
    }
};

/// The parsed result of a siteverify call. All slices are owned by the caller's allocator.
pub const Result = struct {
    /// Whether the token was accepted by the provider.
    ok: bool,
    /// reCAPTCHA v3 only: the risk score (0.0 = bot, 1.0 = human). Null for all other providers.
    score: ?f32 = null,
    /// reCAPTCHA v3 only: the action name submitted with the token. Null for all other providers.
    action: ?[]const u8 = null,
    /// The hostname of the site where the token was generated. Returned by all four
    /// providers; null only when the provider omitted it from the response. Use it for the
    /// recommended `hostname == expected_domain` cross-site-reuse check.
    hostname: ?[]const u8 = null,
    /// Provider error codes (e.g. `"timeout-or-duplicate"`, `"invalid-input-response"`).
    /// Empty slice when success is true or when the provider returned no error-codes.
    errors: []const []const u8 = &.{},
};

/// Percent-encode a single byte that is NOT an unreserved URI character.
/// Unreserved chars per RFC 3986: A-Z a-z 0-9 - _ . ~
/// Everything else is encoded as %XX (uppercase hex).
fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

/// Percent-encode `input` for use as a form field value in
/// `application/x-www-form-urlencoded`. Allocates the result on `alloc`.
fn formEncode(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    // Count encoded length.
    var len: usize = 0;
    for (input) |c| len += if (isUnreserved(c)) @as(usize, 1) else 3; // %XX = 3 chars

    const out = try alloc.alloc(u8, len);
    var i: usize = 0;
    for (input) |c| {
        if (isUnreserved(c)) {
            out[i] = c;
            i += 1;
        } else {
            out[i] = '%';
            out[i + 1] = "0123456789ABCDEF"[c >> 4];
            out[i + 2] = "0123456789ABCDEF"[c & 0x0F];
            i += 3;
        }
    }
    return out;
}

/// Parse the provider's JSON response into a `Result`. All strings are arena-owned.
///
/// Expected JSON shape (common to all providers):
/// ```json
/// {
///   "success": bool,
///   "score": float,        // reCAPTCHA v3 only
///   "action": "...",       // reCAPTCHA v3 only
///   "hostname": "...",     // all providers
///   "error-codes": [...]   // present when success is false
/// }
/// ```
///
/// A malformed / non-object response is NOT silently treated as a failed CAPTCHA — it
/// propagates as `error.CaptchaParseError` so a caller can distinguish "the provider said
/// no" (`ok=false`) from "we could not reach a verdict" (an error, like the non-2xx and
/// transport-failure paths) and choose fail-open vs fail-closed accordingly.
fn parseResponse(alloc: std.mem.Allocator, body: []const u8, provider: Provider) !Result {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch |e| {
        std.log.warn("captcha: failed to parse provider response: {s}", .{@errorName(e)});
        return error.CaptchaParseError;
    };
    const root = switch (parsed) {
        .object => |o| o,
        else => {
            std.log.warn("captcha: provider response was not a JSON object", .{});
            return error.CaptchaParseError;
        },
    };

    const ok: bool = blk: {
        const sv = root.get("success") orelse break :blk false;
        break :blk switch (sv) {
            .bool => |b| b,
            else => false,
        };
    };

    const score: ?f32 = switch (provider) {
        .recaptcha_v3 => blk: {
            const sv = root.get("score") orelse break :blk null;
            break :blk switch (sv) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => null,
            };
        },
        else => null,
    };

    const action: ?[]const u8 = switch (provider) {
        .recaptcha_v3 => blk: {
            const sv = root.get("action") orelse break :blk null;
            break :blk switch (sv) {
                .string => |s| s,
                else => null,
            };
        },
        else => null,
    };

    // All four providers (reCAPTCHA v2/v3, hCaptcha, Turnstile) return `hostname` on a
    // successful verify; parse it generically so consumers can do the recommended
    // `hostname == expected_domain` cross-site-reuse check.
    const hostname: ?[]const u8 = blk: {
        const sv = root.get("hostname") orelse break :blk null;
        break :blk switch (sv) {
            .string => |s| s,
            else => null,
        };
    };

    // Parse "error-codes" (a JSON array of strings). Use an empty slice on success.
    const errors: []const []const u8 = blk: {
        const ev = root.get("error-codes") orelse break :blk &.{};
        const arr = switch (ev) {
            .array => |a| a,
            else => break :blk &.{},
        };
        const out = try alloc.alloc([]const u8, arr.items.len);
        var count: usize = 0;
        for (arr.items) |item| {
            switch (item) {
                .string => |s| {
                    out[count] = s;
                    count += 1;
                },
                else => {},
            }
        }
        break :blk out[0..count];
    };

    return .{
        .ok = ok,
        .score = score,
        .action = action,
        .hostname = hostname,
        .errors = errors,
    };
}

/// Verify `token` against `provider`'s siteverify endpoint using `secret`.
///
/// POSTs `secret=<key>&response=<token>` to the provider URL. Parses the JSON
/// response into a typed `Result`. `alloc` is the per-request allocator (all
/// result slices are owned by it). `client` is an `HttpClient` bound to the
/// same allocator.
///
/// Errors propagate as a Zig error so the caller can distinguish a verdict from a
/// non-verdict and choose fail-open vs fail-closed: a transport failure surfaces as
/// `error.TransportFailed`, a non-2xx provider reply as `error.CaptchaProviderError`,
/// and a malformed / non-object JSON body as `error.CaptchaParseError`. A reachable
/// provider that simply rejects the token returns `.{ .ok = false, .errors = ... }`.
///
/// **Dev-bypass**: `ctx.verifyCaptcha` (the normal call site) returns
/// `.{.ok = true}` immediately when `app.captcha_secret` is empty — this
/// function is only called with a non-empty secret.
pub fn verify(
    provider: Provider,
    secret: []const u8,
    token: []const u8,
    alloc: std.mem.Allocator,
    client: http_client.HttpClient,
) !Result {
    const enc_secret = try formEncode(alloc, secret);
    const enc_token = try formEncode(alloc, token);
    const body_form = try std.fmt.allocPrint(alloc, "secret={s}&response={s}", .{ enc_secret, enc_token });

    const resp = try client.post(provider.verifyUrl(), .{
        .headers = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
        .body = body_form,
    });

    if (resp.status < 200 or resp.status >= 300) {
        // Provider returned a non-2xx; treat as a network-level failure (caller decides policy).
        std.log.warn("captcha: provider returned HTTP {d}", .{resp.status});
        return error.CaptchaProviderError;
    }

    return parseResponse(alloc, resp.body, provider);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testcapture = @import("testcapture.zig");

test "Provider.verifyUrl maps to distinct, expected URLs" {
    try std.testing.expectEqualStrings(
        "https://www.google.com/recaptcha/api/siteverify",
        Provider.recaptcha_v2.verifyUrl(),
    );
    try std.testing.expectEqualStrings(
        "https://www.google.com/recaptcha/api/siteverify",
        Provider.recaptcha_v3.verifyUrl(),
    );
    try std.testing.expectEqualStrings(
        "https://hcaptcha.com/siteverify",
        Provider.hcaptcha.verifyUrl(),
    );
    try std.testing.expectEqualStrings(
        "https://challenges.cloudflare.com/turnstile/v0/siteverify",
        Provider.turnstile.verifyUrl(),
    );
    // recaptcha_v2 and recaptcha_v3 share the same endpoint (response schema differs).
    try std.testing.expectEqualStrings(
        Provider.recaptcha_v2.verifyUrl(),
        Provider.recaptcha_v3.verifyUrl(),
    );
    // hCaptcha and Turnstile must be distinct from Google.
    try std.testing.expect(!std.mem.eql(u8, Provider.hcaptcha.verifyUrl(), Provider.recaptcha_v2.verifyUrl()));
    try std.testing.expect(!std.mem.eql(u8, Provider.turnstile.verifyUrl(), Provider.recaptcha_v2.verifyUrl()));
    try std.testing.expect(!std.mem.eql(u8, Provider.turnstile.verifyUrl(), Provider.hcaptcha.verifyUrl()));
}

test "formEncode: unreserved chars pass through; special chars are percent-encoded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("abc123", try formEncode(a, "abc123"));
    try std.testing.expectEqualStrings("hello-world_v2.~", try formEncode(a, "hello-world_v2.~"));
    try std.testing.expectEqualStrings("%20", try formEncode(a, " "));
    try std.testing.expectEqualStrings("%2B", try formEncode(a, "+"));
    try std.testing.expectEqualStrings("%3D", try formEncode(a, "="));
    try std.testing.expectEqualStrings("%26", try formEncode(a, "&"));
    try std.testing.expectEqualStrings("secret%3Dvalue%26more", try formEncode(a, "secret=value&more"));
}

test "parseResponse: success=true maps to ok=true; no errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseResponse(arena.allocator(), "{\"success\":true,\"hostname\":\"example.com\"}", .recaptcha_v2);
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(usize, 0), r.errors.len);
    try std.testing.expectEqualStrings("example.com", r.hostname.?);
    try std.testing.expect(r.score == null);
    try std.testing.expect(r.action == null);
}

test "parseResponse: recaptcha_v3 extracts score and action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"success":true,"score":0.9,"action":"submit","hostname":"example.com"}
    ;
    const r = try parseResponse(arena.allocator(), body, .recaptcha_v3);
    try std.testing.expect(r.ok);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), r.score.?, 0.001);
    try std.testing.expectEqualStrings("submit", r.action.?);
    try std.testing.expectEqualStrings("example.com", r.hostname.?);
}

test "parseResponse: score/action null for non-v3 providers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = "{\"success\":true,\"score\":0.9,\"action\":\"submit\",\"hostname\":\"example.com\"}";
    const rv2 = try parseResponse(arena.allocator(), body, .recaptcha_v2);
    try std.testing.expect(rv2.score == null);
    try std.testing.expect(rv2.action == null);
    const rhc = try parseResponse(arena.allocator(), body, .hcaptcha);
    try std.testing.expect(rhc.score == null);
    try std.testing.expect(rhc.action == null);
    const rts = try parseResponse(arena.allocator(), body, .turnstile);
    try std.testing.expect(rts.score == null);
    try std.testing.expect(rts.action == null);
}

test "parseResponse: success=false + error-codes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"success":false,"error-codes":["timeout-or-duplicate","invalid-input-response"]}
    ;
    const r = try parseResponse(arena.allocator(), body, .hcaptcha);
    try std.testing.expect(!r.ok);
    try std.testing.expectEqual(@as(usize, 2), r.errors.len);
    try std.testing.expectEqualStrings("timeout-or-duplicate", r.errors[0]);
    try std.testing.expectEqualStrings("invalid-input-response", r.errors[1]);
}

test "parseResponse: hcaptcha parses hostname (its schema returns it)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = "{\"success\":true,\"hostname\":\"example.com\"}";
    const r = try parseResponse(arena.allocator(), body, .hcaptcha);
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("example.com", r.hostname.?);
}

test "parseResponse: malformed JSON propagates error.CaptchaParseError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Non-JSON body.
    try std.testing.expectError(error.CaptchaParseError, parseResponse(arena.allocator(), "not-json", .turnstile));
    // Valid JSON but not an object.
    try std.testing.expectError(error.CaptchaParseError, parseResponse(arena.allocator(), "[1,2,3]", .turnstile));
}

test "verify: mock reCAPTCHA v3 success via testcapture.http" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();

    testcapture.http.enable(true);
    testcapture.http.mock("google.com/recaptcha", .{
        .status = 200,
        .body =
        \\{"success":true,"score":0.8,"action":"login","hostname":"example.com"}
        ,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = http_client.HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };

    const r = try verify(.recaptcha_v3, "secret123", "token456", arena.allocator(), client);
    try std.testing.expect(r.ok);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), r.score.?, 0.001);
    try std.testing.expectEqualStrings("login", r.action.?);
    try std.testing.expectEqualStrings("example.com", r.hostname.?);

    // Verify the POST was formed correctly.
    const req = testcapture.http.requestAt(0).?;
    try std.testing.expectEqual(http_client.Method.POST, req.method);
    try std.testing.expect(std.mem.indexOf(u8, req.url, "google.com") != null);
    const body = req.body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "secret=secret123") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "response=token456") != null);
}

test "verify: mock hCaptcha failure with error-codes via testcapture.http" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();

    testcapture.http.enable(true);
    testcapture.http.mock("hcaptcha.com", .{
        .status = 200,
        .body =
        \\{"success":false,"error-codes":["invalid-input-secret"]}
        ,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = http_client.HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };

    const r = try verify(.hcaptcha, "badsecret", "sometoken", arena.allocator(), client);
    try std.testing.expect(!r.ok);
    try std.testing.expectEqual(@as(usize, 1), r.errors.len);
    try std.testing.expectEqualStrings("invalid-input-secret", r.errors[0]);
}

test "verify: mock Turnstile success via testcapture.http" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();

    testcapture.http.enable(true);
    testcapture.http.mock("cloudflare.com", .{
        .status = 200,
        .body =
        \\{"success":true,"hostname":"myapp.example.com"}
        ,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = http_client.HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };

    const r = try verify(.turnstile, "ts-secret", "ts-token", arena.allocator(), client);
    try std.testing.expect(r.ok);
    try std.testing.expect(r.score == null);
    try std.testing.expect(r.action == null);
    try std.testing.expectEqualStrings("myapp.example.com", r.hostname.?);
}

test "verify: network error propagates as error.TransportFailed" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();

    // Enable capture with block_unmocked=true; no mock registered → any request fails.
    testcapture.http.enable(true);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = http_client.HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };

    try std.testing.expectError(error.TransportFailed, verify(.turnstile, "s", "t", arena.allocator(), client));
}

test "verify: special chars in secret/token are percent-encoded in the POST body" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();

    testcapture.http.enable(true);
    testcapture.http.mock("hcaptcha.com", .{ .status = 200, .body = "{\"success\":true}" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = http_client.HttpClient{ .alloc = arena.allocator(), .io = std.testing.io };

    // Secret and token contain chars that must be encoded.
    _ = try verify(.hcaptcha, "key=value&more", "tok+1", arena.allocator(), client);
    const req = testcapture.http.requestAt(0).?;
    const body = req.body.?;
    // '=', '&', '+' must all be percent-encoded.
    try std.testing.expect(std.mem.indexOf(u8, body, "secret=key%3Dvalue%26more") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "response=tok%2B1") != null);
}
