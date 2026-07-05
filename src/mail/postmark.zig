//! Postmark HTTP-API mail provider (#154). Implements the `Mailer` vtable so callers stay
//! provider-agnostic: `App(.{ .mailer = ... })` or the framework's `.mail` config selects it, and
//! `ctx.mail().send`/`.enqueue` deliver through it like any other backend.
//!
//! Delivery: POST https://api.postmarkapp.com/email with the `X-Postmark-Server-Token` header and
//! a JSON body `{From,To,Subject,TextBody,HtmlBody,ReplyTo}`. A 2xx is success; any other status is
//! an error so the queue's retry/terminal policy (or a synchronous caller) sees the failure.
//!
//! SECURITY: every header-bound value (from/to/subject/reply_to) is CRLF/control-char checked via
//! `mailer.rejectControlChars` BEFORE it is placed into the JSON body — a newline in `to` cannot
//! smuggle an extra Postmark field or header. The body text/html parts are data and are not checked
//! (std.json escapes them when serializing).

const std = @import("std");
const mailer_mod = @import("mailer.zig");
const http_client = @import("../http_client.zig");

const Email = mailer_mod.Email;

pub const endpoint = "https://api.postmarkapp.com/email";

pub const PostmarkMailer = struct {
    server_token: []const u8,
    from: []const u8,
    /// Optional Postmark message stream ("outbound" by default on Postmark's side; left empty here
    /// to use the server's default stream).
    message_stream: []const u8 = "",

    pub fn init(server_token: []const u8, from: []const u8) PostmarkMailer {
        return .{ .server_token = server_token, .from = from };
    }

    pub fn mailer(self: *PostmarkMailer) mailer_mod.Mailer {
        return .{ .ptr = self, .vtable = &vtable, .from = self.from };
    }

    const vtable = mailer_mod.Mailer.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: Email) anyerror!void {
        const self: *PostmarkMailer = @ptrCast(@alignCast(ptr));
        const body = try buildBody(alloc, email.from orelse self.from, self.message_stream, email);
        defer alloc.free(body);

        var client = http_client.HttpClient{ .alloc = alloc, .io = io };
        const res = try client.request(.{
            .method = .POST,
            .url = endpoint,
            .headers = &.{
                .{ .name = "Accept", .value = "application/json" },
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "X-Postmark-Server-Token", .value = self.server_token },
            },
            .body = body,
        });
        if (res.status < 200 or res.status >= 300) return error.PostmarkSendFailed;
    }
};

/// Build the Postmark JSON request body. Pure (no I/O), so it is unit-testable by asserting the
/// exact bytes. Header-bound fields are CRLF-rejected first; body parts are JSON-escaped.
///
/// Builds the nested value tree on a scratch arena (mirrors `ses.buildBody`): the `Headers` array
/// (RFC 8058 unsubscribe pair) is a nested `ObjectMap`/`Array` structure that a single top-level
/// `obj.deinit(alloc)` cannot free — only the final serialized bytes are duped onto `alloc`.
pub fn buildBody(alloc: std.mem.Allocator, from: []const u8, message_stream: []const u8, email: Email) ![]u8 {
    try mailer_mod.rejectControlChars(from);
    try mailer_mod.rejectControlChars(email.to);
    try mailer_mod.rejectControlChars(email.subject);
    if (email.reply_to) |rt| try mailer_mod.rejectControlChars(rt);
    if (email.list_unsubscribe) |lu| try mailer_mod.rejectControlChars(lu);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "From", .{ .string = from });
    try obj.put(a, "To", .{ .string = email.to });
    try obj.put(a, "Subject", .{ .string = email.subject });
    if (email.text_body.len > 0) try obj.put(a, "TextBody", .{ .string = email.text_body });
    if (email.html_body) |h| try obj.put(a, "HtmlBody", .{ .string = h });
    if (email.reply_to) |rt| try obj.put(a, "ReplyTo", .{ .string = rt });
    if (message_stream.len > 0) try obj.put(a, "MessageStream", .{ .string = message_stream });

    if (email.list_unsubscribe) |lu| {
        var h1: std.json.ObjectMap = .empty;
        try h1.put(a, "Name", .{ .string = "List-Unsubscribe" });
        try h1.put(a, "Value", .{ .string = try std.fmt.allocPrint(a, "<{s}>", .{lu}) });
        var h2: std.json.ObjectMap = .empty;
        try h2.put(a, "Name", .{ .string = "List-Unsubscribe-Post" });
        try h2.put(a, "Value", .{ .string = "List-Unsubscribe=One-Click" });
        var hdrs = std.json.Array.init(a);
        try hdrs.append(.{ .object = h1 });
        try hdrs.append(.{ .object = h2 });
        try obj.put(a, "Headers", .{ .array = hdrs });
    }

    if (email.attachments.len > 0) {
        // Postmark's native attachment shape (#219): an `Attachments` array of
        // `{ Name, Content: base64(data), ContentType }` — no raw-MIME round-trip needed.
        var atts = std.json.Array.init(a);
        for (email.attachments) |att| {
            try mailer_mod.rejectControlChars(att.filename);
            try mailer_mod.rejectControlChars(att.content_type);
            const enc = std.base64.standard.Encoder;
            const b64 = try a.alloc(u8, enc.calcSize(att.data.len));
            _ = enc.encode(b64, att.data);
            var o: std.json.ObjectMap = .empty;
            try o.put(a, "Name", .{ .string = att.filename });
            try o.put(a, "Content", .{ .string = b64 });
            try o.put(a, "ContentType", .{ .string = att.content_type });
            try atts.append(.{ .object = o });
        }
        try obj.put(a, "Attachments", .{ .array = atts });
    }

    const json = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = obj }, .{});
    return alloc.dupe(u8, json);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "buildBody emits From/To/Subject and both body parts" {
    const a = testing.allocator;
    const body = try buildBody(a, "noreply@app.com", "", .{
        .to = "user@example.com",
        .subject = "Hi",
        .text_body = "plain",
        .html_body = "<b>rich</b>",
        .reply_to = "support@app.com",
    });
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"From\":\"noreply@app.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"To\":\"user@example.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"Subject\":\"Hi\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"TextBody\":\"plain\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"HtmlBody\":\"<b>rich</b>\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"ReplyTo\":\"support@app.com\"") != null);
}

test "buildBody omits empty text and absent html" {
    const a = testing.allocator;
    const body = try buildBody(a, "n@a.com", "broadcast", .{ .to = "u@x.io", .subject = "S", .text_body = "", .html_body = "<p>x</p>" });
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "TextBody") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"HtmlBody\":\"<p>x</p>\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"MessageStream\":\"broadcast\"") != null);
}

test "buildBody rejects CRLF header injection in to/subject/from/reply_to" {
    const a = testing.allocator;
    try testing.expectError(error.HeaderInjection, buildBody(a, "n@a.com", "", .{ .to = "x@y.io\r\nBcc: e@v.io", .subject = "S", .text_body = "b" }));
    try testing.expectError(error.HeaderInjection, buildBody(a, "n@a.com", "", .{ .to = "x@y.io", .subject = "S\nX: 1", .text_body = "b" }));
    try testing.expectError(error.HeaderInjection, buildBody(a, "n@a.com\r\nEvil: 1", "", .{ .to = "x@y.io", .subject = "S", .text_body = "b" }));
    try testing.expectError(error.HeaderInjection, buildBody(a, "n@a.com", "", .{ .to = "x@y.io", .subject = "S", .text_body = "b", .reply_to = "r@x.io\r\nE: 1" }));
}

test "buildBody emits RFC 8058 Headers array when list_unsubscribe is set" {
    const a = testing.allocator;
    const body = try buildBody(a, "noreply@app.com", "", .{
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
    const body = try buildBody(a, "n@a.com", "", .{ .to = "x@y.io", .subject = "S", .text_body = "b" });
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"Headers\"") == null);
}

test "buildBody rejects CRLF in list_unsubscribe" {
    const a = testing.allocator;
    try testing.expectError(error.HeaderInjection, buildBody(a, "n@a.com", "", .{
        .to = "x@y.io",
        .subject = "S",
        .text_body = "b",
        .list_unsubscribe = "https://x/u?t=1\r\nBcc: e@v.io",
    }));
}

test "buildBody emits an Attachments array with base64 Content when attachments are present (#219)" {
    const a = testing.allocator;
    const ics = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n";
    const body = try buildBody(a, "n@a.com", "", .{
        .to = "u@x.io",
        .subject = "Invite",
        .text_body = "See attached.",
        .attachments = &.{.{ .filename = "invite.ics", .content_type = "text/calendar", .data = ics }},
    });
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"Attachments\":[") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"Name\":\"invite.ics\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"ContentType\":\"text/calendar\"") != null);
    // The Content is the base64 of the .ics bytes.
    const enc = std.base64.standard.Encoder;
    const expect_b64 = try a.alloc(u8, enc.calcSize(ics.len));
    defer a.free(expect_b64);
    _ = enc.encode(expect_b64, ics);
    const needle = try std.fmt.allocPrint(a, "\"Content\":\"{s}\"", .{expect_b64});
    defer a.free(needle);
    try testing.expect(std.mem.indexOf(u8, body, needle) != null);
}

test "buildBody omits Attachments when there are none (byte-identical)" {
    const a = testing.allocator;
    const body = try buildBody(a, "n@a.com", "", .{ .to = "u@x.io", .subject = "S", .text_body = "b" });
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "Attachments") == null);
}

test "buildBody rejects CRLF in an attachment filename/content_type (#219)" {
    const a = testing.allocator;
    try testing.expectError(error.HeaderInjection, buildBody(a, "n@a.com", "", .{
        .to = "u@x.io",
        .subject = "S",
        .text_body = "b",
        .attachments = &.{.{ .filename = "evil\r\nX: 1", .content_type = "text/plain", .data = "x" }},
    }));
}
