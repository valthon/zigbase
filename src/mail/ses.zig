//! Amazon SES (v2) HTTP-API mail provider (#154). Implements the `Mailer` vtable, so it is a
//! drop-in backend behind `ctx.mail()` like SMTP/Postmark.
//!
//! Delivery: POST https://email.<region>.amazonaws.com/v2/email/outbound-emails with a SESv2
//! `SendEmail` JSON body, signed with AWS SigV4 (see `../aws/sigv4.zig`). A 2xx is success; any
//! other status is an error so retry/terminal policy applies.
//!
//! SECURITY: from/to/subject/reply_to are CRLF/control-char checked before they enter the JSON
//! body; the request is SigV4-signed over the exact payload bytes, so a tampered body fails at AWS.

const std = @import("std");
const mailer_mod = @import("mailer.zig");
const sigv4 = @import("../aws/sigv4.zig");
const http_client = @import("../http_client.zig");
const clock = @import("../clock.zig");

const Email = mailer_mod.Email;

pub const path = "/v2/email/outbound-emails";

pub const SesMailer = struct {
    region: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    from: []const u8,

    pub fn init(region: []const u8, access_key: []const u8, secret_key: []const u8, from: []const u8) SesMailer {
        return .{ .region = region, .access_key = access_key, .secret_key = secret_key, .from = from };
    }

    pub fn mailer(self: *SesMailer) mailer_mod.Mailer {
        return .{ .ptr = self, .vtable = &vtable, .from = self.from };
    }

    const vtable = mailer_mod.Mailer.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: Email) anyerror!void {
        const self: *SesMailer = @ptrCast(@alignCast(ptr));
        const host = try std.fmt.allocPrint(alloc, "email.{s}.amazonaws.com", .{self.region});
        defer alloc.free(host);
        const url = try std.fmt.allocPrint(alloc, "https://{s}{s}", .{ host, path });
        defer alloc.free(url);

        const body = try buildBody(alloc, email.from orelse self.from, email);
        defer alloc.free(body);

        const amz_date = amzDate(clock.nowUnix(io));
        const payload_hash = try sigv4.sha256Hex(alloc, body);
        defer alloc.free(payload_hash);
        const authorization = try sigv4.signRequest(alloc, .{
            .access_key = self.access_key,
            .secret_key = self.secret_key,
            .region = self.region,
            .service = "ses",
            .method = "POST",
            .host = host,
            .path = path,
            .headers = &.{.{ .name = "content-type", .value = "application/json" }},
            .payload_sha256 = payload_hash,
            .amz_date = &amz_date,
        });
        defer alloc.free(authorization);

        var client = http_client.HttpClient{ .alloc = alloc, .io = io };
        const res = try client.request(.{
            .method = .POST,
            .url = url,
            .headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "X-Amz-Date", .value = &amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = payload_hash },
                .{ .name = "Authorization", .value = authorization },
            },
            .body = body,
        });
        if (res.status < 200 or res.status >= 300) return error.SesSendFailed;
    }
};

const AmzDateBuf = [16]u8; // "YYYYMMDDTHHMMSSZ" — 16 ASCII bytes

/// Format a unix timestamp as the SigV4 `X-Amz-Date` value `YYYYMMDDTHHMMSSZ` (UTC). Pure.
pub fn amzDate(ts: i64) AmzDateBuf {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(ts, 0)) };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var buf: AmzDateBuf = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
    return buf;
}

/// Build the SESv2 `SendEmail` JSON body. Pure (no I/O) → unit-testable. Header-bound fields are
/// CRLF-rejected first.
pub fn buildBody(alloc: std.mem.Allocator, from: []const u8, email: Email) ![]u8 {
    try mailer_mod.rejectControlChars(from);
    try mailer_mod.rejectControlChars(email.to);
    try mailer_mod.rejectControlChars(email.subject);
    if (email.reply_to) |rt| try mailer_mod.rejectControlChars(rt);
    if (email.list_unsubscribe) |lu| try mailer_mod.rejectControlChars(lu);

    // Build the nested value tree in a scratch arena so we never have to hand-free each nested
    // ObjectMap/Array; only the final serialized bytes are duped onto the caller's allocator.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var root: std.json.ObjectMap = .empty;
    try root.put(a, "FromEmailAddress", .{ .string = from });

    // Destination.ToAddresses = [to]
    var to_arr = std.json.Array.init(a);
    try to_arr.append(.{ .string = email.to });
    var dest: std.json.ObjectMap = .empty;
    try dest.put(a, "ToAddresses", .{ .array = to_arr });
    try root.put(a, "Destination", .{ .object = dest });

    // Content.Simple.{Subject,Body.{Text,Html}}
    var subject_obj: std.json.ObjectMap = .empty;
    try subject_obj.put(a, "Data", .{ .string = email.subject });

    var body_obj: std.json.ObjectMap = .empty;
    if (email.text_body.len > 0) {
        var text_obj: std.json.ObjectMap = .empty;
        try text_obj.put(a, "Data", .{ .string = email.text_body });
        try body_obj.put(a, "Text", .{ .object = text_obj });
    }
    if (email.html_body) |h| {
        var html_obj: std.json.ObjectMap = .empty;
        try html_obj.put(a, "Data", .{ .string = h });
        try body_obj.put(a, "Html", .{ .object = html_obj });
    }

    var simple: std.json.ObjectMap = .empty;
    try simple.put(a, "Subject", .{ .object = subject_obj });
    try simple.put(a, "Body", .{ .object = body_obj });

    if (email.list_unsubscribe) |lu| {
        // SES v2 supports per-message Headers on the Simple content object (since 2023) —
        // no switch to Raw MIME. Do NOT use ListManagementOptions (that binds unsubscribe
        // to SES's own contact lists rather than our endpoint).
        var h1: std.json.ObjectMap = .empty;
        try h1.put(a, "Name", .{ .string = "List-Unsubscribe" });
        try h1.put(a, "Value", .{ .string = try std.fmt.allocPrint(a, "<{s}>", .{lu}) });
        var h2: std.json.ObjectMap = .empty;
        try h2.put(a, "Name", .{ .string = "List-Unsubscribe-Post" });
        try h2.put(a, "Value", .{ .string = "List-Unsubscribe=One-Click" });
        var hdrs = std.json.Array.init(a);
        try hdrs.append(.{ .object = h1 });
        try hdrs.append(.{ .object = h2 });
        try simple.put(a, "Headers", .{ .array = hdrs });
    }

    var content: std.json.ObjectMap = .empty;
    try content.put(a, "Simple", .{ .object = simple });
    try root.put(a, "Content", .{ .object = content });

    if (email.reply_to) |rt| {
        var rt_arr = std.json.Array.init(a);
        try rt_arr.append(.{ .string = rt });
        try root.put(a, "ReplyToAddresses", .{ .array = rt_arr });
    }

    const json = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});
    return alloc.dupe(u8, json);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "amzDate formats a known epoch as YYYYMMDDTHHMMSSZ" {
    // 1704067200 == 2024-01-01 00:00:00 UTC.
    const d = amzDate(1704067200);
    try testing.expectEqualStrings("20240101T000000Z", &d);
    const z = amzDate(0);
    try testing.expectEqualStrings("19700101T000000Z", &z);
}

test "buildBody emits SESv2 SendEmail shape with both parts" {
    const a = testing.allocator;
    const body = try buildBody(a, "noreply@app.com", .{
        .to = "user@example.com",
        .subject = "Welcome",
        .text_body = "plain",
        .html_body = "<b>rich</b>",
        .reply_to = "support@app.com",
    });
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"FromEmailAddress\":\"noreply@app.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"ToAddresses\":[\"user@example.com\"]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"Subject\":{\"Data\":\"Welcome\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"Text\":{\"Data\":\"plain\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"Html\":{\"Data\":\"<b>rich</b>\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"ReplyToAddresses\":[\"support@app.com\"]") != null);
}

test "buildBody rejects header injection" {
    const a = testing.allocator;
    try testing.expectError(error.HeaderInjection, buildBody(a, "n@a.com", .{ .to = "x@y.io\r\nBcc: e@v.io", .subject = "S", .text_body = "b" }));
    try testing.expectError(error.HeaderInjection, buildBody(a, "n@a.com", .{ .to = "x@y.io", .subject = "S\nX:1", .text_body = "b" }));
}

test "buildBody emits RFC 8058 Headers on Content.Simple when list_unsubscribe is set" {
    const a = testing.allocator;
    const body = try buildBody(a, "noreply@app.com", .{
        .to = "user@example.com",
        .subject = "News",
        .text_body = "plain",
        .list_unsubscribe = "https://app.example/api/mail/unsubscribe?t=abc",
    });
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"Headers\":[") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"Name\":\"List-Unsubscribe\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"Value\":\"<https://app.example/api/mail/unsubscribe?t=abc>\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"Name\":\"List-Unsubscribe-Post\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"Value\":\"List-Unsubscribe=One-Click\"") != null);
}

test "buildBody omits Headers when list_unsubscribe is unset" {
    const a = testing.allocator;
    const body = try buildBody(a, "n@a.com", .{ .to = "x@y.io", .subject = "S", .text_body = "b" });
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"Headers\"") == null);
}

test "buildBody rejects CRLF in list_unsubscribe" {
    const a = testing.allocator;
    try testing.expectError(error.HeaderInjection, buildBody(a, "n@a.com", .{
        .to = "x@y.io",
        .subject = "S",
        .text_body = "b",
        .list_unsubscribe = "https://x/u?t=1\r\nBcc: e@v.io",
    }));
}
