const std = @import("std");
const config = @import("../config.zig");
const SmtpTls = config.SmtpTls;

/// A single outbound email. Text-only for now (no `html_body`) to keep the
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

/// Minimal SMTP backend with optional TLS. Supports three transport modes,
/// driven by `tls` (see `config.SmtpTls`):
///   .none     — plaintext SMTP (MailHog / local relays).
///   .implicit — SMTPS: TLS handshake immediately after connect, then the whole
///               exchange runs over TLS (typically port 465).
///   .starttls — connect plaintext, EHLO, STARTTLS, upgrade the SAME socket to
///               TLS, re-EHLO, continue over TLS (typically port 587/25).
///   .auto     — inferred from port (465→implicit, 587→starttls, else→none).
/// AUTH LOGIN credentials (base64) are only ever sent AFTER the TLS handshake
/// when a TLS mode is active, so they never leak in plaintext.
///
/// Connect -> [TLS] -> EHLO -> [STARTTLS -> TLS -> EHLO] -> [AUTH LOGIN] ->
/// MAIL FROM -> RCPT TO -> DATA (RFC5322 message) -> QUIT.
pub const SmtpMailer = struct {
    host: []const u8,
    port: u16,
    username: []const u8,
    password: []const u8,
    from: []const u8,
    tls: SmtpTls = .auto,
    insecure_skip_verify: bool = false,

    pub fn init(host: []const u8, port: u16, username: []const u8, password: []const u8, from: []const u8) SmtpMailer {
        return .{ .host = host, .port = port, .username = username, .password = password, .from = from };
    }

    /// Full constructor with explicit TLS mode + cert-verification policy.
    pub fn initTls(
        host: []const u8,
        port: u16,
        username: []const u8,
        password: []const u8,
        from: []const u8,
        tls_mode: SmtpTls,
        insecure_skip_verify: bool,
    ) SmtpMailer {
        return .{
            .host = host,
            .port = port,
            .username = username,
            .password = password,
            .from = from,
            .tls = tls_mode,
            .insecure_skip_verify = insecure_skip_verify,
        };
    }

    pub fn mailer(self: *SmtpMailer) Mailer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Mailer.VTable{ .send = send };

    /// Active SMTP byte stream. `r`/`w` are the plaintext SMTP reader/writer;
    /// over plaintext these point at the raw socket interfaces, over TLS they
    /// point at the TLS client's decrypted reader / plaintext writer. When TLS
    /// is active, `socket_w` is the underlying socket writer that must ALSO be
    /// flushed after the TLS writer (the TLS writer encrypts into the socket
    /// writer's buffer, which then has to be pushed to the wire) — mirrors
    /// std/http/Client.zig Connection.flush (flush tls.client.writer then the
    /// stream writer).
    const Conn = struct {
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        socket_w: ?*std.Io.Writer = null,
    };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: Email) anyerror!void {
        const self: *SmtpMailer = @ptrCast(@alignCast(ptr));

        const mode = config.Config.resolveSmtpTls(self.tls, self.port);

        const addr = try std.Io.net.IpAddress.resolve(io, self.host, self.port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        // Underlying socket reader/writer. For TLS these carry ciphertext; for
        // plaintext they ARE the SMTP stream. TLS frames can be up to ~16 KiB,
        // so size the socket buffers to the TLS minimum when TLS may be used.
        const tls_min = std.crypto.tls.Client.min_buffer_len;
        var sock_read: [tls_min]u8 = undefined;
        var sock_write: [tls_min]u8 = undefined;
        var sr = stream.reader(io, &sock_read);
        var sw = stream.writer(io, &sock_write);
        const sock_r = &sr.interface;
        const sock_w = &sw.interface;

        switch (mode) {
            .none => {
                var conn = Conn{ .r = sock_r, .w = sock_w };
                try self.runExchange(io, alloc, email, &conn, false);
            },
            .implicit => {
                // Handshake immediately; the entire exchange runs over TLS.
                var tls_state = try TlsState.init(self, alloc, io, sock_r, sock_w);
                defer tls_state.deinit();
                var conn = Conn{ .r = &tls_state.client.reader, .w = &tls_state.client.writer, .socket_w = sock_w };
                try self.runExchange(io, alloc, email, &conn, false);
            },
            .starttls => {
                // Plaintext greeting + EHLO, issue STARTTLS, then upgrade.
                var plain = Conn{ .r = sock_r, .w = sock_w };
                try expectCode(plain.r, 220);
                try ehlo(&plain);
                try writeLine(&plain, "STARTTLS\r\n");
                try expectCode(plain.r, 220);

                var tls_state = try TlsState.init(self, alloc, io, sock_r, sock_w);
                defer tls_state.deinit();
                var conn = Conn{ .r = &tls_state.client.reader, .w = &tls_state.client.writer, .socket_w = sock_w };
                // Banner already consumed on the plaintext leg; re-EHLO over TLS.
                try self.runExchange(io, alloc, email, &conn, true);
            },
            .auto => unreachable, // resolveSmtpTls never returns .auto
        }
    }

    /// Run the SMTP exchange over `conn`. When `skip_greeting` is false we first
    /// wait for the 220 banner and EHLO; for STARTTLS the banner was already
    /// consumed on the plaintext leg and we only re-EHLO over TLS.
    fn runExchange(self: *SmtpMailer, io: std.Io, alloc: std.mem.Allocator, email: Email, conn: *Conn, comptime starttls_resumed: bool) anyerror!void {
        // Reject control chars in the envelope BEFORE writing any command: `self.from`
        // and `email.to` are interpolated into the `MAIL FROM`/`RCPT TO` command lines,
        // so a newline would let an attacker inject arbitrary SMTP commands (extra
        // RCPT TO, DATA, etc.). `email.subject` is NOT part of the envelope — it is
        // validated in buildMessage where it goes into the headers — so it is not
        // checked here.
        try checkHeaderField(self.from);
        try checkHeaderField(email.to);
        if (!starttls_resumed) {
            // Greeting (implicit TLS and plaintext both see the banner here).
            try expectCode(conn.r, 220);
        }
        // EHLO (initial for none/implicit; the post-STARTTLS re-EHLO otherwise).
        try ehlo(conn);

        // Optional AUTH LOGIN (base64 username then password). Over TLS this runs
        // encrypted; credentials never traverse a plaintext leg.
        if (self.username.len > 0) {
            try writeLine(conn, "AUTH LOGIN\r\n");
            try expectCode(conn.r, 334);
            try sendB64Line(conn, alloc, self.username);
            try expectCode(conn.r, 334);
            try sendB64Line(conn, alloc, self.password);
            try expectCode(conn.r, 235);
        }

        // MAIL FROM.
        const mail_from = try std.fmt.allocPrint(alloc, "MAIL FROM:<{s}>\r\n", .{self.from});
        defer alloc.free(mail_from);
        try writeLine(conn, mail_from);
        try expectCode(conn.r, 250);

        // RCPT TO.
        const rcpt = try std.fmt.allocPrint(alloc, "RCPT TO:<{s}>\r\n", .{email.to});
        defer alloc.free(rcpt);
        try writeLine(conn, rcpt);
        try expectCode(conn.r, 250);

        // DATA.
        try writeLine(conn, "DATA\r\n");
        try expectCode(conn.r, 354);

        const now_s = std.Io.Clock.real.now(io).toSeconds();
        const msg = try buildMessage(alloc, self.from, email, now_s);
        defer alloc.free(msg);
        try writeLine(conn, msg);
        try writeLine(conn, "\r\n.\r\n");
        try expectCode(conn.r, 250);

        // QUIT.
        try writeLine(conn, "QUIT\r\n");
        // Server replies 221; ignore failures here (message already accepted).
        _ = readReply(conn.r) catch {};
    }

    fn ehlo(conn: *Conn) anyerror!void {
        try writeLine(conn, "EHLO localhost\r\n");
        try expectCode(conn.r, 250);
    }

    /// Write a line over the connection and flush. For TLS this flushes the
    /// plaintext TLS writer (encrypting into the socket buffer) AND the socket
    /// writer (pushing the ciphertext to the wire); see Conn doc comment.
    fn writeLine(conn: *Conn, line: []const u8) anyerror!void {
        try conn.w.writeAll(line);
        try conn.w.flush();
        if (conn.socket_w) |swr| try swr.flush();
    }

    fn sendB64Line(conn: *Conn, alloc: std.mem.Allocator, raw: []const u8) anyerror!void {
        const enc = std.base64.standard.Encoder;
        const out = try alloc.alloc(u8, enc.calcSize(raw.len));
        defer alloc.free(out);
        _ = enc.encode(out, raw);
        const line = try std.fmt.allocPrint(alloc, "{s}\r\n", .{out});
        defer alloc.free(line);
        try writeLine(conn, line);
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

/// Owns the TLS client + the buffers it borrows and (optionally) the CA bundle.
/// `std.crypto.tls.Client` keeps pointers into `read_buffer`/`write_buffer`, so
/// they must outlive the client — hence heap-allocated and freed in `deinit`.
const TlsState = struct {
    client: std.crypto.tls.Client,
    alloc: std.mem.Allocator,
    read_buffer: []u8,
    write_buffer: []u8,
    bundle: std.crypto.Certificate.Bundle,
    bundle_lock: std.Io.RwLock,
    have_bundle: bool,

    /// Handshake TLS over an already-connected socket (`sock_r`/`sock_w` carry
    /// ciphertext). Loads the system CA bundle via `Certificate.Bundle.rescan`
    /// and verifies the chain against `self.host` (SNI + hostname check) unless
    /// `insecure_skip_verify` is set. Mirrors std/http/Client.zig's TLS setup.
    fn init(self: *SmtpMailer, alloc: std.mem.Allocator, io: std.Io, sock_r: *std.Io.Reader, sock_w: *std.Io.Writer) anyerror!TlsState {
        const tls_min = std.crypto.tls.Client.min_buffer_len;
        const read_buffer = try alloc.alloc(u8, tls_min);
        errdefer alloc.free(read_buffer);
        const write_buffer = try alloc.alloc(u8, tls_min);
        errdefer alloc.free(write_buffer);

        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);

        const now = std.Io.Clock.real.now(io);

        var state = TlsState{
            .client = undefined,
            .alloc = alloc,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .bundle = .empty,
            .bundle_lock = .init,
            .have_bundle = false,
        };

        const host_opt: @TypeOf(@as(std.crypto.tls.Client.Options, undefined).host) =
            if (self.insecure_skip_verify) .no_verification else .{ .explicit = self.host };

        var ca_opt: @TypeOf(@as(std.crypto.tls.Client.Options, undefined).ca) = undefined;
        if (self.insecure_skip_verify) {
            ca_opt = .no_verification;
        } else {
            // Load the system trust store. Captured by pointer below, so the
            // bundle must live as long as the client (it's a field of state,
            // but the handshake reads it during init only).
            try state.bundle.rescan(alloc, io, now);
            state.have_bundle = true;
            ca_opt = .{ .bundle = .{
                .gpa = alloc,
                .io = io,
                .lock = &state.bundle_lock,
                .bundle = &state.bundle,
            } };
        }

        state.client = std.crypto.tls.Client.init(sock_r, sock_w, .{
            .host = host_opt,
            .ca = ca_opt,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .entropy = &entropy,
            .realtime_now = now,
        }) catch |err| {
            if (state.have_bundle) state.bundle.deinit(alloc);
            return err;
        };
        return state;
    }

    fn deinit(state: *TlsState) void {
        const a = state.alloc;
        if (state.have_bundle) state.bundle.deinit(a);
        a.free(state.read_buffer);
        a.free(state.write_buffer);
    }
};

/// Rejecting a header value that would let an attacker inject extra SMTP commands
/// or additional RFC5322 headers. `to`/`subject`/`from` are interpolated into
/// single-line headers and the `MAIL FROM`/`RCPT TO` commands, so a CR, LF, or NUL
/// in them is a header/command-injection vector (e.g. a `to` of
/// `victim@x\r\nBcc: spam@evil` would add a Bcc). Email addresses and subjects are
/// often attacker-controlled (signup/password-reset email fields) and this is also
/// a public plugin entry point (`Mailer.send`), so we sanitize here as a backstop
/// regardless of upstream validation. The message body is data after the header
/// separator and may legitimately contain newlines, so it is NOT checked here.
pub const HeaderError = error{HeaderInjection};

fn hasControlChar(s: []const u8) bool {
    // Reject every ASCII control character (0x00–0x1F and 0x7F), not just CR/LF/NUL:
    // TAB/VT/FF and friends can fold or mangle headers in downstream mail infrastructure.
    for (s) |c| if (c < 32 or c == 127) return true;
    return false;
}

fn checkHeaderField(s: []const u8) HeaderError!void {
    if (hasControlChar(s)) return error.HeaderInjection;
}

/// Build the RFC5322 message bytes (headers + blank line + body). Pure: no I/O,
/// so it can be unit-tested by asserting the produced bytes. The dot-stuffing
/// terminator (\r\n.\r\n) is appended by the DATA send path, not here.
/// Returns error.HeaderInjection if `from`/`to`/`subject` contain CR, LF, or NUL.
pub fn buildMessage(alloc: std.mem.Allocator, from: []const u8, email: Email, now_unix: i64) ![]u8 {
    try checkHeaderField(from);
    try checkHeaderField(email.to);
    try checkHeaderField(email.subject);
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

test "buildMessage rejects CRLF header injection in to/subject/from" {
    const a = std.testing.allocator;
    // CRLF in `to` would inject a Bcc header (and a RCPT TO on the wire).
    try std.testing.expectError(error.HeaderInjection, buildMessage(a, "noreply@zigbase.dev", .{
        .to = "victim@x.io\r\nBcc: spam@evil.com",
        .subject = "Hi",
        .text_body = "body",
    }, 0));
    // CRLF in the subject would inject an arbitrary header.
    try std.testing.expectError(error.HeaderInjection, buildMessage(a, "noreply@zigbase.dev", .{
        .to = "victim@x.io",
        .subject = "Hi\r\nX-Injected: yes",
        .text_body = "body",
    }, 0));
    // A bare LF and a NUL are equally rejected (in `from`).
    try std.testing.expectError(error.HeaderInjection, buildMessage(a, "noreply@zigbase.dev\nEvil: 1", .{
        .to = "victim@x.io",
        .subject = "Hi",
        .text_body = "body",
    }, 0));
    try std.testing.expectError(error.HeaderInjection, buildMessage(a, "noreply@zigbase.dev", .{
        .to = "victim@x.io\x00",
        .subject = "Hi",
        .text_body = "body",
    }, 0));
    // Other ASCII control chars (TAB here) are rejected too — some mail infra folds on them.
    try std.testing.expectError(error.HeaderInjection, buildMessage(a, "noreply@zigbase.dev", .{
        .to = "victim@x.io",
        .subject = "Hi\tthere",
        .text_body = "body",
    }, 0));
    // A newline in the BODY is fine (data, not a header).
    const ok = try buildMessage(a, "noreply@zigbase.dev", .{
        .to = "victim@x.io",
        .subject = "Hi",
        .text_body = "line1\r\nline2",
    }, 0);
    defer a.free(ok);
    try std.testing.expect(std.mem.endsWith(u8, ok, "\r\n\r\nline1\r\nline2"));
}

test "rfc5322Date formats a known epoch" {
    // 0 == Thu, 01 Jan 1970 00:00:00 +0000
    const d = rfc5322Date(0);
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 +0000", &d);
    // 1704067200 == Mon, 01 Jan 2024 00:00:00 +0000
    const d2 = rfc5322Date(1704067200);
    try std.testing.expectEqualStrings("Mon, 01 Jan 2024 00:00:00 +0000", &d2);
}

test "SmtpMailer.init defaults to auto TLS with verification on" {
    const m = SmtpMailer.init("smtp.example.com", 587, "u", "p", "from@example.com");
    try std.testing.expectEqual(SmtpTls.auto, m.tls);
    try std.testing.expectEqual(false, m.insecure_skip_verify);
    // auto@587 resolves to starttls.
    try std.testing.expectEqual(SmtpTls.starttls, config.Config.resolveSmtpTls(m.tls, m.port));
}

test "SmtpMailer.initTls records explicit mode + insecure flag" {
    const m = SmtpMailer.initTls("smtp.example.com", 465, "u", "p", "from@example.com", .implicit, true);
    try std.testing.expectEqual(SmtpTls.implicit, m.tls);
    try std.testing.expectEqual(true, m.insecure_skip_verify);
}

test "base64 AUTH LOGIN encoding matches expected" {
    const a = std.testing.allocator;
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize("user".len));
    defer a.free(out);
    _ = enc.encode(out, "user");
    try std.testing.expectEqualStrings("dXNlcg==", out);
}
