//! In-memory capture mailer + dev preview (#154). Two non-network delivery aids:
//!
//!   * `CaptureMailer` — a `Mailer` backend that records every outbound message into an in-memory
//!     list instead of sending it. Consumer tests wire it via `App(.{ .mailer = ... })` (or call
//!     its `mailer()` directly) and then ASSERT on the captured mail — subject, recipient, both
//!     body parts — with no SMTP server and no network. (This complements the framework-internal
//!     `testcapture.mail` outbox, which captures the framework's OWN auth mail; `CaptureMailer` is
//!     a first-class backend a consumer owns and inspects.)
//!
//!   * `renderPreview` — produce a single self-describing HTML document for one `Email` (headers +
//!     the HTML part, with the text part shown as a fallback). A dev-only `/_/mail/preview` route or
//!     a CLI can write this to disk so a developer eyeballs a template without sending anything.
//!
//! Both are pure of network I/O and fully unit-testable.

const std = @import("std");
const mailer_mod = @import("mailer.zig");
const template = @import("template.zig");

const Email = mailer_mod.Email;

/// Spin-acquire `m` (the `std.atomic.Mutex` idiom used elsewhere, e.g. testcapture.zig/ratelimit.zig).
fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

/// One captured outbound message (owned copies of the fields, freed in `deinit`).
pub const Captured = struct {
    from: []u8,
    to: []u8,
    subject: []u8,
    text: []u8,
    html: ?[]u8,
    reply_to: ?[]u8,
    list_unsubscribe: ?[]u8,
};

/// A `Mailer` backend that records messages in memory. NOT thread-safe across concurrent worker
/// sends without the internal mutex (which `record` takes); intended for single-process tests.
pub const CaptureMailer = struct {
    alloc: std.mem.Allocator,
    from: []const u8 = "capture@zigbase.dev",
    mutex: std.atomic.Mutex = .unlocked,
    messages: std.ArrayListUnmanaged(Captured) = .empty,

    pub fn init(alloc: std.mem.Allocator) CaptureMailer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *CaptureMailer) void {
        for (self.messages.items) |m| {
            self.alloc.free(m.from);
            self.alloc.free(m.to);
            self.alloc.free(m.subject);
            self.alloc.free(m.text);
            if (m.html) |h| self.alloc.free(h);
            if (m.reply_to) |rt| self.alloc.free(rt);
            if (m.list_unsubscribe) |lu| self.alloc.free(lu);
        }
        self.messages.deinit(self.alloc);
    }

    pub fn mailer(self: *CaptureMailer) mailer_mod.Mailer {
        return .{ .ptr = self, .vtable = &vtable, .from = self.from };
    }

    const vtable = mailer_mod.Mailer.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: Email) anyerror!void {
        _ = io;
        _ = alloc;
        const self: *CaptureMailer = @ptrCast(@alignCast(ptr));
        try self.record(self.from, email);
    }

    /// Record a message under the mutex (the owned copies live on `self.alloc`). Each dupe has its own
    /// `errdefer` so a later allocation failing frees the earlier copies (no partial-alloc leak).
    pub fn record(self: *CaptureMailer, from: []const u8, email: Email) !void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const from_copy = try self.alloc.dupe(u8, from);
        errdefer self.alloc.free(from_copy);
        const to_copy = try self.alloc.dupe(u8, email.to);
        errdefer self.alloc.free(to_copy);
        const subject_copy = try self.alloc.dupe(u8, email.subject);
        errdefer self.alloc.free(subject_copy);
        const text_copy = try self.alloc.dupe(u8, email.text_body);
        errdefer self.alloc.free(text_copy);
        const html_copy: ?[]u8 = if (email.html_body) |h| try self.alloc.dupe(u8, h) else null;
        errdefer if (html_copy) |h| self.alloc.free(h);
        const reply_to_copy: ?[]u8 = if (email.reply_to) |rt| try self.alloc.dupe(u8, rt) else null;
        errdefer if (reply_to_copy) |rt| self.alloc.free(rt);
        const list_unsubscribe_copy: ?[]u8 = if (email.list_unsubscribe) |lu| try self.alloc.dupe(u8, lu) else null;
        errdefer if (list_unsubscribe_copy) |lu| self.alloc.free(lu);
        try self.messages.append(self.alloc, .{
            .from = from_copy,
            .to = to_copy,
            .subject = subject_copy,
            .text = text_copy,
            .html = html_copy,
            .reply_to = reply_to_copy,
            .list_unsubscribe = list_unsubscribe_copy,
        });
    }

    pub fn count(self: *CaptureMailer) usize {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        return self.messages.items.len;
    }

    /// The most recently captured message, or null if none. Borrowed (valid until `deinit`/`clear`).
    pub fn last(self: *CaptureMailer) ?Captured {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.messages.items.len == 0) return null;
        return self.messages.items[self.messages.items.len - 1];
    }

    /// Every captured message, oldest first. BORROWED — valid until the next `record`/
    /// `clear`/`deinit` (single-threaded test usage; take the values you need eagerly).
    pub fn all(self: *CaptureMailer) []const Captured {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        return self.messages.items;
    }

    /// Number of captured messages addressed to exactly `addr` (bulk tests assert
    /// per-recipient fan-out and dedup with this).
    pub fn countTo(self: *CaptureMailer, addr: []const u8) usize {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.messages.items) |m| {
            if (std.mem.eql(u8, m.to, addr)) n += 1;
        }
        return n;
    }

    /// Drop all captured messages (freeing their copies).
    pub fn clear(self: *CaptureMailer) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        for (self.messages.items) |m| {
            self.alloc.free(m.from);
            self.alloc.free(m.to);
            self.alloc.free(m.subject);
            self.alloc.free(m.text);
            if (m.html) |h| self.alloc.free(h);
            if (m.reply_to) |rt| self.alloc.free(rt);
            if (m.list_unsubscribe) |lu| self.alloc.free(lu);
        }
        self.messages.clearRetainingCapacity();
    }
};

/// Render a self-describing dev-preview HTML page for `email`: an envelope header block followed by
/// the HTML part (or the text part wrapped in `<pre>` when there is no HTML). Header-bound values
/// are HTML-escaped via the template engine so the preview can never be XSS'd by a crafted subject.
pub fn renderPreview(alloc: std.mem.Allocator, from: []const u8, email: Email) ![]u8 {
    const html_part = email.html_body orelse "";
    const layout =
        \\<!doctype html><html><head><meta charset="utf-8"><title>Mail preview</title></head>
        \\<body style="font-family:sans-serif">
        \\<table border="1" cellpadding="4" style="border-collapse:collapse;margin-bottom:1em">
        \\<tr><td><b>From</b></td><td>{{ from }}</td></tr>
        \\<tr><td><b>To</b></td><td>{{ to }}</td></tr>
        \\<tr><td><b>Subject</b></td><td>{{ subject }}</td></tr>
        \\</table>
        \\<div style="border:1px solid #ccc;padding:1em">{{{ html }}}</div>
        \\<details><summary>Text part</summary><pre>{{ text }}</pre></details>
        \\</body></html>
    ;
    const vars = [_]template.Var{
        .{ .key = "from", .value = from },
        .{ .key = "to", .value = email.to },
        .{ .key = "subject", .value = email.subject },
        .{ .key = "html", .value = html_part },
        .{ .key = "text", .value = email.text_body },
    };
    return template.renderHtml(alloc, layout, &vars, &.{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "CaptureMailer records sends without a network and is assertable" {
    var cap = CaptureMailer.init(testing.allocator);
    defer cap.deinit();
    const m = cap.mailer();
    try m.send(testing.io, testing.allocator, .{
        .to = "user@example.com",
        .subject = "Welcome",
        .text_body = "hello",
        .html_body = "<b>hi</b>",
        .reply_to = "support@zigbase.dev",
        .list_unsubscribe = "https://app.example/u?t=1",
    });
    try testing.expectEqual(@as(usize, 1), cap.count());
    const last = cap.last().?;
    try testing.expectEqualStrings("user@example.com", last.to);
    try testing.expectEqualStrings("Welcome", last.subject);
    try testing.expectEqualStrings("hello", last.text);
    try testing.expectEqualStrings("<b>hi</b>", last.html.?);
    try testing.expectEqualStrings("support@zigbase.dev", last.reply_to.?);
    try testing.expectEqualStrings("https://app.example/u?t=1", last.list_unsubscribe.?);

    try m.send(testing.io, testing.allocator, .{
        .to = "user2@example.com",
        .subject = "Welcome",
        .text_body = "hello",
    });
    try m.send(testing.io, testing.allocator, .{
        .to = "user@example.com",
        .subject = "Again",
        .text_body = "hi",
    });
    try testing.expectEqual(@as(usize, 3), cap.all().len);
    try testing.expectEqual(@as(usize, 2), cap.countTo("user@example.com"));
    try testing.expectEqual(@as(usize, 1), cap.countTo("user2@example.com"));
    try testing.expectEqual(@as(usize, 0), cap.countTo("nobody@example.com"));
    // The freshly-added messages carry no reply_to/list_unsubscribe.
    try testing.expect(cap.all()[1].reply_to == null);
    try testing.expect(cap.all()[1].list_unsubscribe == null);

    cap.clear();
    try testing.expectEqual(@as(usize, 0), cap.count());
    try testing.expect(cap.last() == null);
    try testing.expectEqual(@as(usize, 0), cap.all().len);
}

test "renderPreview escapes header fields and embeds the html part" {
    const a = testing.allocator;
    const out = try renderPreview(a, "noreply@app.com", .{
        .to = "u@x.io",
        .subject = "a<script>",
        .text_body = "plain",
        .html_body = "<p>rich</p>",
    });
    defer a.free(out);
    // Subject is escaped (no live script); the html part is embedded raw.
    try testing.expect(std.mem.indexOf(u8, out, "a&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<p>rich</p>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "noreply@app.com") != null);
}
