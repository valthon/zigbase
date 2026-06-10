const std = @import("std");

/// A single outbound email. v0.1 is text-only (no html_body) to keep the
/// message builder simple; add an optional `html_body` later for multipart.
pub const Email = struct {
    to: []const u8,
    subject: []const u8,
    text_body: []const u8,
};

/// Pluggable, backend-agnostic mailer. Mirrors the `Storage` vtable pattern in
/// `files/storage.zig`: a `*anyopaque` ctx plus a vtable with a single `send`.
///
/// This is a swappable plugin: a consumer can supply their own backend by
/// implementing a type with a `send` fn matching `VTable.send` and exposing a
/// `mailer()` helper that returns a `Mailer{ .ptr = self, .vtable = &vt }`.
/// ZigBase ships two implementations below: `LogMailer` (logs the email; the
/// default when no SMTP is configured, preserving pre-mailer dev/CI behavior)
/// and `SmtpMailer` (a minimal plaintext SMTP + AUTH LOGIN client).
pub const Mailer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: Email) anyerror!void,
    };

    pub fn send(self: Mailer, io: std.Io, alloc: std.mem.Allocator, email: Email) anyerror!void {
        return self.vtable.send(self.ptr, io, alloc, email);
    }
};

/// Default backend: logs the email (to / subject / body) via `std.log.info`.
/// This preserves the pre-mailer behavior where verify/reset tokens were
/// logged, so dev and CI work without a live SMTP server.
pub const LogMailer = struct {
    pub fn init() LogMailer {
        return .{};
    }

    pub fn mailer(self: *LogMailer) Mailer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Mailer.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: Email) anyerror!void {
        _ = ptr;
        _ = io;
        _ = alloc;
        std.log.info("[mail] to={s} subject={s} body={s}", .{ email.to, email.subject, email.text_body });
    }
};

/// Minimal SMTP backend. v0.1 supports PLAINTEXT SMTP with optional AUTH LOGIN
/// (base64 user/pass). TLS / STARTTLS is intentionally NOT implemented here to
/// avoid shipping a broken crypto path; this works against plaintext relays and
/// dev sinks like maildev/MailHog. TLS / submission-port (465/587) support is a
/// documented follow-up. Connect -> EHLO -> [AUTH LOGIN] -> MAIL FROM -> RCPT TO
/// -> DATA (RFC5322 message) -> QUIT.
pub const SmtpMailer = struct {
    host: []const u8,
    port: u16,
    username: []const u8,
    password: []const u8,
    from: []const u8,

    pub fn init(host: []const u8, port: u16, username: []const u8, password: []const u8, from: []const u8) SmtpMailer {
        return .{ .host = host, .port = port, .username = username, .password = password, .from = from };
    }

    pub fn mailer(self: *SmtpMailer) Mailer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Mailer.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: Email) anyerror!void {
        const self: *SmtpMailer = @ptrCast(@alignCast(ptr));

        const addr = try std.Io.net.IpAddress.resolve(io, self.host, self.port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var sr = stream.reader(io, &read_buf);
        var sw = stream.writer(io, &write_buf);
        const r = &sr.interface;
        const w = &sw.interface;

        // Greeting.
        try expectCode(r, 220);

        // EHLO.
        try writeLine(w, "EHLO localhost\r\n");
        try expectCode(r, 250);

        // Optional AUTH LOGIN (base64 username then password).
        if (self.username.len > 0) {
            try writeLine(w, "AUTH LOGIN\r\n");
            try expectCode(r, 334);
            try sendB64Line(w, alloc, self.username);
            try expectCode(r, 334);
            try sendB64Line(w, alloc, self.password);
            try expectCode(r, 235);
        }

        // MAIL FROM.
        const mail_from = try std.fmt.allocPrint(alloc, "MAIL FROM:<{s}>\r\n", .{self.from});
        defer alloc.free(mail_from);
        try writeLine(w, mail_from);
        try expectCode(r, 250);

        // RCPT TO.
        const rcpt = try std.fmt.allocPrint(alloc, "RCPT TO:<{s}>\r\n", .{email.to});
        defer alloc.free(rcpt);
        try writeLine(w, rcpt);
        try expectCode(r, 250);

        // DATA.
        try writeLine(w, "DATA\r\n");
        try expectCode(r, 354);

        const now_s = std.Io.Clock.real.now(io).toSeconds();
        const msg = try buildMessage(alloc, self.from, email, now_s);
        defer alloc.free(msg);
        try writeLine(w, msg);
        try writeLine(w, "\r\n.\r\n");
        try expectCode(r, 250);

        // QUIT.
        try writeLine(w, "QUIT\r\n");
        // Server replies 221; ignore failures here (message already accepted).
        _ = readReply(r) catch {};
    }

    fn writeLine(w: *std.Io.Writer, line: []const u8) anyerror!void {
        try w.writeAll(line);
        try w.flush();
    }

    fn sendB64Line(w: *std.Io.Writer, alloc: std.mem.Allocator, raw: []const u8) anyerror!void {
        const enc = std.base64.standard.Encoder;
        const out = try alloc.alloc(u8, enc.calcSize(raw.len));
        defer alloc.free(out);
        _ = enc.encode(out, raw);
        const line = try std.fmt.allocPrint(alloc, "{s}\r\n", .{out});
        defer alloc.free(line);
        try writeLine(w, line);
    }

    /// Read one SMTP reply (consuming continuation lines "NNN-...") and return
    /// the numeric reply code from the final line.
    fn readReply(r: *std.Io.Reader) anyerror!u16 {
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            if (line.len < 3) return error.SmtpBadReply;
            const code = std.fmt.parseInt(u16, line[0..3], 10) catch return error.SmtpBadReply;
            // A continuation line has a '-' as the 4th char; final line has ' '.
            if (line.len >= 4 and line[3] == '-') continue;
            return code;
        }
    }

    fn expectCode(r: *std.Io.Reader, want: u16) anyerror!void {
        const got = try readReply(r);
        if (got != want) return error.SmtpUnexpectedReply;
    }
};

/// Build the RFC5322 message bytes (headers + blank line + body). Pure: no I/O,
/// so it can be unit-tested by asserting the produced bytes. The dot-stuffing
/// terminator (\r\n.\r\n) is appended by the DATA send path, not here.
pub fn buildMessage(alloc: std.mem.Allocator, from: []const u8, email: Email, now_unix: i64) ![]u8 {
    const date = rfc5322Date(now_unix);
    return std.fmt.allocPrint(
        alloc,
        "From: {s}\r\nTo: {s}\r\nSubject: {s}\r\nDate: {s}\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n{s}",
        .{ from, email.to, email.subject, date, email.text_body },
    );
}

const Rfc5322DateBuf = [31]u8;

/// Format a unix timestamp as an RFC5322 date in UTC, e.g.
/// "Mon, 01 Jan 2024 00:00:00 +0000". Returns a fixed-size value buffer.
fn rfc5322Date(ts: i64) Rfc5322DateBuf {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(ts, 0)) };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // Day-of-week: Jan 1 1970 was a Thursday (index 4 with Sun=0).
    const dow_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mon_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const dow = @as(usize, @intCast(@mod(epoch_day.day + 4, 7)));

    var buf: Rfc5322DateBuf = undefined;
    _ = std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} +0000", .{
        dow_names[dow],
        @as(u32, month_day.day_index) + 1,
        mon_names[@intFromEnum(month_day.month) - 1],
        year_day.year,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
    return buf;
}

test "LogMailer satisfies the Mailer interface and send succeeds" {
    var lm = LogMailer.init();
    const m = lm.mailer();
    try m.send(std.testing.io, std.testing.allocator, .{
        .to = "user@example.com",
        .subject = "Hi",
        .text_body = "body",
    });
}

test "buildMessage produces RFC5322 headers and body" {
    const a = std.testing.allocator;
    const msg = try buildMessage(a, "noreply@zigbase.dev", .{
        .to = "user@example.com",
        .subject = "Verify your email",
        .text_body = "Your token: abc123",
    }, 1704067200);
    defer a.free(msg);

    try std.testing.expect(std.mem.startsWith(u8, msg, "From: noreply@zigbase.dev\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, msg, "\r\nTo: user@example.com\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\r\nSubject: Verify your email\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\r\nDate: Mon, 01 Jan 2024 00:00:00 +0000\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\r\nContent-Type: text/plain; charset=utf-8\r\n") != null);
    // Header/body separator then the body verbatim.
    try std.testing.expect(std.mem.endsWith(u8, msg, "\r\n\r\nYour token: abc123"));
}

test "rfc5322Date formats a known epoch" {
    // 0 == Thu, 01 Jan 1970 00:00:00 +0000
    const d = rfc5322Date(0);
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 +0000", &d);
    // 1704067200 == Mon, 01 Jan 2024 00:00:00 +0000
    const d2 = rfc5322Date(1704067200);
    try std.testing.expectEqualStrings("Mon, 01 Jan 2024 00:00:00 +0000", &d2);
}

test "base64 AUTH LOGIN encoding matches expected" {
    const a = std.testing.allocator;
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize("user".len));
    defer a.free(out);
    _ = enc.encode(out, "user");
    try std.testing.expectEqualStrings("dXNlcg==", out);
}
