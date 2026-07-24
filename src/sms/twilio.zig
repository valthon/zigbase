//! Twilio HTTP-API SMS provider (#224). Implements the `SmsSender` vtable so callers stay
//! provider-agnostic: `App(.{ .sms_provider = ... })` or the env-based default selection wires
//! it, and `ctx.sms().send`/`.enqueue` deliver through it like any other backend.
//!
//! Delivery: POST https://api.twilio.com/2010-04-01/Accounts/{SID}/Messages.json with HTTP
//! Basic auth (`Authorization: Basic base64("{SID}:{token}")`) and an
//! `application/x-www-form-urlencoded` body `To=...&From=...&Body=...`. A 2xx is success; any
//! other status is an error so the queue's retry/terminal policy (or a synchronous caller) sees
//! the failure. Modeled on how `mail/postmark.zig` issues its POST (same `http_client`).
//!
//! SECURITY: each form value is percent-encoded via `urlenc.percentEncode` before it goes into the
//! body — a `&`, `=`, space, or newline in the `Body` cannot smuggle an extra form parameter.
//! `to`/`from` are additionally guaranteed E.164 (digits only) by `sms/send.zig` before they
//! reach here.

const std = @import("std");
const sender_mod = @import("sender.zig");
const http_client = @import("../http_client.zig");
const urlenc = @import("../url.zig");

const Sms = sender_mod.Sms;

pub const api_base = "https://api.twilio.com/2010-04-01/Accounts/";

pub const TwilioSender = struct {
    account_sid: []const u8,
    auth_token: []const u8,
    from: []const u8,

    pub fn init(account_sid: []const u8, auth_token: []const u8, from: []const u8) TwilioSender {
        return .{ .account_sid = account_sid, .auth_token = auth_token, .from = from };
    }

    pub fn sender(self: *TwilioSender) sender_mod.SmsSender {
        return .{ .ptr = self, .vtable = &vtable, .from = self.from };
    }

    const vtable = sender_mod.SmsSender.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, sms: Sms) anyerror!void {
        const self: *TwilioSender = @ptrCast(@alignCast(ptr));

        // `send` returns void, so NOTHING it allocates escapes: the URL, auth header, form body,
        // and the http_client's response scratch (a fixed `max_response_bytes` buffer that
        // `HttpResponse` has no deinit for) are all one-shot. Route them through a function-local
        // arena so `send` is self-freeing under ANY allocator, not only a request arena.
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const url = try messagesUrl(sa, self.account_sid);
        const auth = try basicAuthHeader(sa, self.account_sid, self.auth_token);
        const body = try buildBody(sa, sms.from orelse self.from, sms);

        var client = http_client.HttpClient{ .alloc = sa, .io = io };
        const res = try client.request(.{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "Accept", .value = "application/json" },
                .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
                .{ .name = "Authorization", .value = auth },
            },
            .body = body,
        });
        if (res.status < 200 or res.status >= 300) {
            // Log the status + Twilio's diagnostic JSON body (truncated) so a delivery failure is
            // debuggable in production; Twilio returns `{"code":…,"message":…}` on error.
            const detail = res.body[0..@min(res.body.len, 300)];
            std.log.warn("[sms:twilio] send failed: HTTP {d} {s}", .{ res.status, detail });
            return error.TwilioSendFailed;
        }
    }
};

/// Build the `Messages.json` endpoint URL for `account_sid`. Pure; unit-testable.
pub fn messagesUrl(alloc: std.mem.Allocator, account_sid: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}/Messages.json", .{ api_base, account_sid });
}

/// Build the `Authorization: Basic …` header value (base64 of "sid:token"). Pure.
pub fn basicAuthHeader(alloc: std.mem.Allocator, account_sid: []const u8, auth_token: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ account_sid, auth_token });
    defer alloc.free(raw);
    const enc = std.base64.standard.Encoder;
    const b64 = try alloc.alloc(u8, enc.calcSize(raw.len));
    defer alloc.free(b64);
    _ = enc.encode(b64, raw);
    return std.fmt.allocPrint(alloc, "Basic {s}", .{b64});
}

/// Build the `application/x-www-form-urlencoded` request body. Pure (no I/O), so it is
/// unit-testable by asserting the exact bytes. Every value is percent-encoded.
pub fn buildBody(alloc: std.mem.Allocator, from: []const u8, sms: Sms) ![]u8 {
    // A space becomes `%20` (not `+`); Twilio decodes both, and `%20` is unambiguous.
    const to_enc = try urlenc.percentEncode(alloc, sms.to);
    defer alloc.free(to_enc);
    const from_enc = try urlenc.percentEncode(alloc, from);
    defer alloc.free(from_enc);
    const body_enc = try urlenc.percentEncode(alloc, sms.body);
    defer alloc.free(body_enc);
    return std.fmt.allocPrint(alloc, "To={s}&From={s}&Body={s}", .{ to_enc, from_enc, body_enc });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const testcapture = @import("../testcapture.zig");

test "messagesUrl embeds the account SID" {
    const a = testing.allocator;
    const url = try messagesUrl(a, "ACxxxxxxxx");
    defer a.free(url);
    try testing.expectEqualStrings("https://api.twilio.com/2010-04-01/Accounts/ACxxxxxxxx/Messages.json", url);
}

test "basicAuthHeader is base64 of sid:token" {
    const a = testing.allocator;
    const h = try basicAuthHeader(a, "user", "pass");
    defer a.free(h);
    // base64("user:pass") == "dXNlcjpwYXNz"
    try testing.expectEqualStrings("Basic dXNlcjpwYXNz", h);
}

test "buildBody url-encodes each value (spaces, &, newlines escaped)" {
    const a = testing.allocator;
    const body = try buildBody(a, "+15550000000", .{
        .to = "+15551234567",
        .body = "Hi there & bye\nsecond=line",
    });
    defer a.free(body);
    // '+' in the numbers is percent-encoded (%2B); space→%20; '&'→%26; '\n'→%0A; '='→%3D.
    try testing.expectEqualStrings(
        "To=%2B15551234567&From=%2B15550000000&Body=Hi%20there%20%26%20bye%0Asecond%3Dline",
        body,
    );
}

test "send builds the right URL + Basic auth + encoded body (via the http capture seam)" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true); // block unmocked → no real network
    testcapture.http.mock("api.twilio.com", .{ .status = 201, .body = "{\"sid\":\"SMxxxx\"}" });

    // `TwilioSender.send` is self-freeing (contract-1), so it runs under the raw leak-detecting
    // allocator — the captured request survives in the (page-allocator-backed) capture store.
    const a = testing.allocator;
    var tw = TwilioSender.init("ACtest", "tok", "+15550000000");
    const s = tw.sender();
    try s.send(std.testing.io, a, .{ .to = "+15551234567", .body = "Hi there" });

    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());
    const rq = testcapture.http.requestAt(0).?;
    try testing.expectEqual(http_client.Method.POST, rq.method);
    try testing.expectEqualStrings("https://api.twilio.com/2010-04-01/Accounts/ACtest/Messages.json", rq.url);
    // Basic auth header present with the right value: base64("ACtest:tok").
    var auth_found = false;
    for (rq.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Authorization")) {
            auth_found = true;
            const enc = std.base64.standard.Encoder;
            var buf: [64]u8 = undefined;
            const b64 = enc.encode(buf[0..enc.calcSize("ACtest:tok".len)], "ACtest:tok");
            const want = try std.fmt.allocPrint(a, "Basic {s}", .{b64});
            defer a.free(want);
            try testing.expectEqualStrings(want, h.value);
        }
    }
    try testing.expect(auth_found);
    // The form body carries the encoded To/From/Body.
    try testing.expectEqualStrings("To=%2B15551234567&From=%2B15550000000&Body=Hi%20there", rq.body.?);
}

test "a non-2xx Twilio status surfaces as an error" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.reset();
    defer testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("api.twilio.com", .{ .status = 401, .body = "{\"message\":\"auth\"}" });

    var tw = TwilioSender.init("ACtest", "bad", "+15550000000");
    const s = tw.sender();
    try testing.expectError(error.TwilioSendFailed, s.send(std.testing.io, testing.allocator, .{
        .to = "+15551234567",
        .body = "x",
    }));
}
