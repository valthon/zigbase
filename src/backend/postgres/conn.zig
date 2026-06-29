//! A single PostgreSQL v3 wire-protocol connection: TCP connect, optional TLS
//! (`std.crypto.tls.Client` over an `SSLRequest`), the startup + authentication
//! handshake (SCRAM-SHA-256 / cleartext / md5), and query execution via both the
//! simple (`Query`) and extended (`Parse`/`Bind`/`Describe`/`Execute`/`Sync`) protocols.
//!
//! Pure Zig `std` only — no libpq, no C, no OpenSSL. The connection owns its socket and
//! TLS buffers inline, so a `Conn` must be heap-allocated and pinned (its reader/writer
//! interfaces are self-referential); `db.zig`/`pool.zig` always hold a `*Conn`.

const std = @import("std");
const net = std.Io.net;
const tls = std.crypto.tls;
const proto = @import("protocol.zig");
const scram = @import("scram.zig");
const connstr = @import("connstr.zig");

pub const ConnError = error{
    ConnectFailed,
    TlsRequiredButRefused,
    TlsHandshakeFailed,
    Protocol,
    AuthFailed,
    UnsupportedAuth,
    QueryFailed,
    EndOfStream,
    OutOfMemory,
    /// An identifier that must be interpolated (e.g. a LISTEN channel — not parameterizable)
    /// contained a quote or NUL and was rejected before interpolation.
    InvalidIdentifier,
};

/// Reject an identifier that cannot be safely interpolated into a double-quoted SQL
/// identifier. A `"` would break out of the quoting and a NUL terminates the C string the
/// wire protocol sends, so both are refused. (gemini#3 — LISTEN channel injection.)
fn validateIdentifier(ident: []const u8) ConnError!void {
    for (ident) |ch| {
        if (ch == '"' or ch == 0) return ConnError.InvalidIdentifier;
    }
}

/// A bound parameter in TEXT format. `null` value means SQL NULL.
pub const Param = struct { value: ?[]const u8 };

pub const Column = struct { name: []const u8, oid: u32 };

/// The result of one extended-protocol execution, allocated into a caller-supplied arena.
pub const QueryResult = struct {
    columns: []Column = &.{},
    /// `rows[r][c]` is null (SQL NULL) or the column's TEXT bytes.
    rows: [][]?[]const u8 = &.{},
    /// Rows affected, parsed from the CommandComplete tag (INSERT/UPDATE/DELETE/SELECT).
    rows_affected: i64 = 0,
};

const sock_buf_len = tls.Client.min_buffer_len; // >= max TLS record; ample for plaintext

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
    sock_read_buf: [sock_buf_len]u8 = undefined,
    sock_write_buf: [sock_buf_len]u8 = undefined,

    tls_client: ?*tls.Client = null,
    tls_read_buf: []u8 = &.{},
    tls_write_buf: []u8 = &.{},

    /// Active app-data reader/writer: the plaintext stream interfaces, or the TLS client's
    /// when a TLS session is established.
    in: *std.Io.Reader = undefined,
    out: *std.Io.Writer = undefined,

    read_buf: std.ArrayList(u8) = .empty, // reused backing store for one message body
    scratch: std.ArrayList(u8) = .empty, // reused MsgBuilder scratch
    last_error: std.ArrayList(u8) = .empty, // owned text of the most recent ErrorResponse

    backend_pid: i32 = 0,
    backend_secret: i32 = 0,
    tx_status: u8 = 'I',
    using_tls: bool = false,
    /// Set when the connection is desynced/dead: a read failed (EndOfStream/Protocol), a
    /// write/flush failed, or the wire framing was violated. A broken connection must never
    /// be reused — the pool closes it instead of parking it. A *normal* SQL error (constraint
    /// violation) drains cleanly to ReadyForQuery and does NOT set this. (I-2.)
    broken: bool = false,
    /// Rows affected by the most recent DML (simple or extended). Mirrors SQLite's
    /// `changesCount`; surfaced through `db.Db.changesCount`.
    last_changes: i64 = 0,
    /// Async NotificationResponse ('A') messages captured during query drains, so a
    /// notification that arrives mid-command is not lost before `waitNotification`. Channel
    /// and payload are gpa-owned; freed on consume / `deinit`.
    notifications: std.ArrayList(Notification) = .empty,

    /// Connect, negotiate TLS per `cfg.sslmode`, and complete startup + authentication.
    /// Returns a pinned, ready-to-query connection; caller owns it and must call `deinit`.
    pub fn connect(gpa: std.mem.Allocator, io: std.Io, cfg: connstr.Config) ConnError!*Conn {
        const self = gpa.create(Conn) catch return ConnError.OutOfMemory;
        errdefer gpa.destroy(self);

        const addr = net.IpAddress.resolve(io, cfg.host, cfg.port) catch return ConnError.ConnectFailed;
        const stream = addr.connect(io, .{ .mode = .stream }) catch return ConnError.ConnectFailed;

        self.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .stream_reader = undefined,
            .stream_writer = undefined,
        };
        self.stream_reader = stream.reader(io, &self.sock_read_buf);
        self.stream_writer = stream.writer(io, &self.sock_write_buf);
        self.in = &self.stream_reader.interface;
        self.out = &self.stream_writer.interface;
        // A handshake failure (wrong password / unreachable DB) must free everything the
        // partially-live connection owns, not just the socket — these buffers can grow during
        // startup/auth (error text, notifications, message bodies). This is the pooled-open
        // hot path, so a leak here compounds. (I-4 / gemini#2.)
        errdefer {
            self.closeSocket();
            self.freeNotifications();
            self.read_buf.deinit(self.gpa);
            self.scratch.deinit(self.gpa);
            self.last_error.deinit(self.gpa);
        }

        try self.maybeStartTls(cfg.sslmode);
        try self.startup(cfg);
        try self.authenticate(cfg);
        try self.readUntilReady();
        return self;
    }

    /// Flush BOTH buffer layers. `self.out.flush()` flushes the active app-data writer
    /// (which, under TLS, only encrypts buffered plaintext into the underlying stream
    /// writer's buffer); the ciphertext still has to be flushed from the stream writer to
    /// the socket. Skipping the second flush leaves the request unsent and the next read
    /// blocks forever (matches `std.http.Client`, which flushes both layers).
    fn flushOut(self: *Conn) std.Io.Writer.Error!void {
        try self.out.flush();
        if (self.using_tls) try self.stream_writer.interface.flush();
    }

    fn closeSocket(self: *Conn) void {
        if (self.tls_client) |c| {
            c.end() catch {};
            self.gpa.destroy(c);
            self.tls_client = null;
        }
        if (self.tls_read_buf.len > 0) self.gpa.free(self.tls_read_buf);
        if (self.tls_write_buf.len > 0) self.gpa.free(self.tls_write_buf);
        self.stream.close(self.io);
    }

    pub fn deinit(self: *Conn) void {
        // Best-effort polite shutdown.
        var mb = proto.MsgBuilder.init(self.gpa, &self.scratch);
        if (mb.start(proto.Frontend.terminate)) {
            mb.finish(self.out) catch {};
            self.out.flush() catch {};
        } else |_| {}
        self.closeSocket();
        self.freeNotifications();
        self.read_buf.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.last_error.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn errMsg(self: *Conn) []const u8 {
        return self.last_error.items;
    }

    // --- TLS negotiation --------------------------------------------------------

    fn maybeStartTls(self: *Conn, sslmode: connstr.SslMode) ConnError!void {
        if (sslmode == .disable) return;

        // SSLRequest: int32 length(8), int32 magic(80877103). No type tag.
        self.out.writeInt(i32, 8, .big) catch return ConnError.ConnectFailed;
        self.out.writeInt(i32, 80877103, .big) catch return ConnError.ConnectFailed;
        self.flushOut() catch return ConnError.ConnectFailed;

        const reply = self.in.takeByte() catch return ConnError.ConnectFailed;
        switch (reply) {
            'S' => try self.startTlsHandshake(),
            'N' => if (sslmode == .require) return ConnError.TlsRequiredButRefused,
            else => return ConnError.Protocol,
        }
    }

    fn startTlsHandshake(self: *Conn) ConnError!void {
        self.tls_read_buf = self.gpa.alloc(u8, sock_buf_len) catch return ConnError.OutOfMemory;
        self.tls_write_buf = self.gpa.alloc(u8, sock_buf_len) catch return ConnError.OutOfMemory;
        const client = self.gpa.create(tls.Client) catch return ConnError.OutOfMemory;
        errdefer self.gpa.destroy(client);

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        self.io.random(&entropy);

        client.* = tls.Client.init(self.in, self.out, .{
            // The driver does not (yet) verify the server certificate chain or hostname —
            // it uses TLS purely for transport encryption (parity with libpq sslmode=require,
            // which also does not authenticate the server). connstr.parse REJECTS
            // verify-ca/verify-full (ParseError.UnsupportedSslMode) rather than silently
            // accepting them here; real cert+host verification is a documented follow-up.
            .host = .no_verification,
            .ca = .no_verification,
            .write_buffer = self.tls_write_buf,
            .read_buffer = self.tls_read_buf,
            .entropy = &entropy,
            .realtime_now = .zero,
        }) catch return ConnError.TlsHandshakeFailed;

        self.tls_client = client;
        self.in = &client.reader;
        self.out = &client.writer;
        self.using_tls = true;
    }

    // --- startup + auth ---------------------------------------------------------

    fn startup(self: *Conn, cfg: connstr.Config) ConnError!void {
        var mb = proto.MsgBuilder.init(self.gpa, &self.scratch);
        mb.start(0) catch return ConnError.OutOfMemory; // untagged
        mb.int32(196608) catch return ConnError.OutOfMemory; // protocol 3.0
        mb.cstr("user") catch return ConnError.OutOfMemory;
        mb.cstr(cfg.user) catch return ConnError.OutOfMemory;
        mb.cstr("database") catch return ConnError.OutOfMemory;
        mb.cstr(cfg.database) catch return ConnError.OutOfMemory;
        mb.cstr("client_encoding") catch return ConnError.OutOfMemory;
        mb.cstr("UTF8") catch return ConnError.OutOfMemory;
        mb.byte(0) catch return ConnError.OutOfMemory; // terminating empty key
        mb.finish(self.out) catch return ConnError.ConnectFailed;
        self.flushOut() catch return ConnError.ConnectFailed;
    }

    fn authenticate(self: *Conn, cfg: connstr.Config) ConnError!void {
        while (true) {
            const msg = try self.readMessage();
            switch (msg.type) {
                proto.Backend.authentication => {
                    var cur = Cursor{ .buf = msg.body };
                    const code = cur.int32() orelse return ConnError.Protocol;
                    switch (code) {
                        proto.Auth.ok => return,
                        proto.Auth.cleartext_password => try self.sendPassword(cfg.password),
                        proto.Auth.md5_password => {
                            const salt = cur.take(4) orelse return ConnError.Protocol;
                            try self.sendMd5Password(cfg, salt);
                        },
                        proto.Auth.sasl => try self.doScram(cfg, &cur),
                        else => return ConnError.UnsupportedAuth,
                    }
                },
                proto.Backend.error_response => {
                    self.captureError(msg.body);
                    return ConnError.AuthFailed;
                },
                proto.Backend.notice_response, proto.Backend.parameter_status => {},
                else => return ConnError.Protocol,
            }
        }
    }

    fn sendPassword(self: *Conn, password: []const u8) ConnError!void {
        var mb = proto.MsgBuilder.init(self.gpa, &self.scratch);
        mb.start(proto.Frontend.password) catch return ConnError.OutOfMemory;
        mb.cstr(password) catch return ConnError.OutOfMemory;
        mb.finish(self.out) catch return ConnError.ConnectFailed;
        self.flushOut() catch return ConnError.ConnectFailed;
    }

    fn sendMd5Password(self: *Conn, cfg: connstr.Config, salt: []const u8) ConnError!void {
        var out: [35]u8 = undefined; // "md5" + 32 hex
        const token = md5Token(cfg.user, cfg.password, salt, &out);
        try self.sendPassword(token);
    }

    fn doScram(self: *Conn, cfg: connstr.Config, list_cur: *Cursor) ConnError!void {
        // The SASL message body is a NUL-separated list of mechanism names, ended by an
        // empty string. Require SCRAM-SHA-256.
        var have_scram = false;
        while (list_cur.cstr()) |mech| {
            if (mech.len == 0) break;
            if (std.mem.eql(u8, mech, "SCRAM-SHA-256")) have_scram = true;
        }
        if (!have_scram) return ConnError.UnsupportedAuth;

        var seed: [24]u8 = undefined;
        self.io.random(&seed);
        var client = scram.Client.init(self.gpa, seed) catch return ConnError.OutOfMemory;
        defer client.deinit();

        // SASLInitialResponse: cstr(mechanism), int32(len), client-first bytes.
        const client_first = client.clientFirst() catch return ConnError.OutOfMemory;
        defer self.gpa.free(client_first);
        {
            var mb = proto.MsgBuilder.init(self.gpa, &self.scratch);
            mb.start(proto.Frontend.password) catch return ConnError.OutOfMemory;
            mb.cstr("SCRAM-SHA-256") catch return ConnError.OutOfMemory;
            mb.int32(@intCast(client_first.len)) catch return ConnError.OutOfMemory;
            mb.bytes(client_first) catch return ConnError.OutOfMemory;
            mb.finish(self.out) catch return ConnError.ConnectFailed;
            self.flushOut() catch return ConnError.ConnectFailed;
        }

        // Expect AuthenticationSASLContinue (server-first).
        const cont = try self.readMessage();
        if (cont.type == proto.Backend.error_response) {
            self.captureError(cont.body);
            return ConnError.AuthFailed;
        }
        if (cont.type != proto.Backend.authentication) return ConnError.Protocol;
        var c1 = Cursor{ .buf = cont.body };
        if ((c1.int32() orelse return ConnError.Protocol) != proto.Auth.sasl_continue) return ConnError.Protocol;
        const server_first = c1.rest();

        const client_final = client.clientFinal(cfg.password, server_first) catch return ConnError.AuthFailed;
        defer self.gpa.free(client_final);
        {
            var mb = proto.MsgBuilder.init(self.gpa, &self.scratch);
            mb.start(proto.Frontend.password) catch return ConnError.OutOfMemory;
            mb.bytes(client_final) catch return ConnError.OutOfMemory;
            mb.finish(self.out) catch return ConnError.ConnectFailed;
            self.flushOut() catch return ConnError.ConnectFailed;
        }

        // Expect AuthenticationSASLFinal (server-final, v=...).
        const fin = try self.readMessage();
        if (fin.type == proto.Backend.error_response) {
            self.captureError(fin.body);
            return ConnError.AuthFailed;
        }
        if (fin.type != proto.Backend.authentication) return ConnError.Protocol;
        var c2 = Cursor{ .buf = fin.body };
        if ((c2.int32() orelse return ConnError.Protocol) != proto.Auth.sasl_final) return ConnError.Protocol;
        client.verifyServerFinal(c2.rest()) catch return ConnError.AuthFailed;
        // AuthenticationOk follows; the outer authenticate() loop consumes it.
    }

    // --- message I/O ------------------------------------------------------------

    const Message = struct { type: u8, body: []const u8 };

    /// Read one backend message. The returned `body` aliases an internal buffer and is only
    /// valid until the next `readMessage` call — copy anything you need to retain.
    /// Largest backend message body we will allocate for. PostgreSQL's protocol allows up to
    /// ~2 GiB, but nothing this driver issues yields a message remotely near 16 MiB; bounding
    /// it before `ensureTotalCapacity` stops a malicious or desynced server from forcing a
    /// huge allocation / OOM from a bogus length prefix. (I-1 / gemini#4.)
    const max_message_len: i32 = 16 * 1024 * 1024;

    fn readMessage(self: *Conn) ConnError!Message {
        const t = self.in.takeByte() catch |e| return self.markBroken(mapRead(e));
        const len = self.in.takeInt(i32, .big) catch |e| return self.markBroken(mapRead(e));
        if (len < 4 or len > max_message_len) {
            self.broken = true; // framing violation → the stream position is now untrustworthy
            return ConnError.Protocol;
        }
        const body_len: usize = @intCast(len - 4);
        self.read_buf.clearRetainingCapacity();
        self.read_buf.ensureTotalCapacity(self.gpa, body_len) catch return ConnError.OutOfMemory;
        self.read_buf.items.len = body_len;
        self.in.readSliceAll(self.read_buf.items) catch |e| return self.markBroken(mapRead(e));
        return .{ .type = t, .body = self.read_buf.items };
    }

    fn mapRead(e: anyerror) ConnError {
        return switch (e) {
            error.EndOfStream => ConnError.EndOfStream,
            else => ConnError.Protocol,
        };
    }

    /// Mark the connection unusable and pass the error through (so it can never be re-parked).
    fn markBroken(self: *Conn, e: ConnError) ConnError {
        self.broken = true;
        return e;
    }

    /// True if the connection is safe to reuse: not broken and not stuck in a failed
    /// transaction (`tx_status == 'E'`). The pool checks this on release and acquire.
    pub fn isHealthy(self: *const Conn) bool {
        return !self.broken and self.tx_status != 'E';
    }

    /// Consume ParameterStatus / BackendKeyData / NoticeResponse until ReadyForQuery.
    fn readUntilReady(self: *Conn) ConnError!void {
        while (true) {
            const msg = try self.readMessage();
            switch (msg.type) {
                proto.Backend.ready_for_query => {
                    if (msg.body.len >= 1) self.tx_status = msg.body[0];
                    return;
                },
                proto.Backend.backend_key_data => {
                    var cur = Cursor{ .buf = msg.body };
                    self.backend_pid = cur.int32() orelse 0;
                    self.backend_secret = cur.int32() orelse 0;
                },
                proto.Backend.notification_response => self.enqueueNotification(msg.body) catch {},
                proto.Backend.error_response => {
                    self.captureError(msg.body);
                    // keep draining until ReadyForQuery
                },
                else => {}, // ParameterStatus, NoticeResponse: ignore
            }
        }
    }

    fn captureError(self: *Conn, body: []const u8) void {
        // ErrorResponse: a sequence of (field-type byte, cstr value), ended by a 0 byte.
        // 'M' is the human-readable message.
        self.last_error.clearRetainingCapacity();
        var cur = Cursor{ .buf = body };
        while (cur.byte()) |field_type| {
            if (field_type == 0) break;
            const val = cur.cstr() orelse break;
            if (field_type == 'M') {
                self.last_error.appendSlice(self.gpa, val) catch {};
            }
        }
    }

    // --- query execution --------------------------------------------------------

    /// Simple-protocol execution (`Query`). Runs one or more statements with no parameters;
    /// used for DDL and transaction control. Drains to ReadyForQuery.
    pub fn simpleExec(self: *Conn, sql: []const u8) ConnError!void {
        var mb = proto.MsgBuilder.init(self.gpa, &self.scratch);
        mb.start(proto.Frontend.query) catch return ConnError.OutOfMemory;
        mb.cstr(sql) catch return ConnError.OutOfMemory;
        mb.finish(self.out) catch return ConnError.QueryFailed;
        self.flushOut() catch { self.broken = true; return ConnError.QueryFailed; };

        var failed = false;
        while (true) {
            const msg = try self.readMessage();
            switch (msg.type) {
                proto.Backend.ready_for_query => {
                    if (msg.body.len >= 1) self.tx_status = msg.body[0];
                    if (failed) return ConnError.QueryFailed;
                    return;
                },
                proto.Backend.command_complete => {
                    var cur = Cursor{ .buf = msg.body };
                    self.last_changes = parseAffected(cur.cstr() orelse "");
                },
                proto.Backend.notification_response => self.enqueueNotification(msg.body) catch {},
                proto.Backend.error_response => {
                    self.captureError(msg.body);
                    failed = true;
                },
                else => {}, // RowDescription/DataRow/etc. ignored for exec
            }
        }
    }

    /// Extended-protocol execution: Parse+Bind+Describe+Execute+Sync with TEXT-format
    /// params and TEXT-format results. All retained bytes (column names, row values) are
    /// copied into `arena`; the returned `QueryResult` is owned by `arena`.
    pub fn execExtended(self: *Conn, arena: std.mem.Allocator, sql: []const u8, params: []const Param) ConnError!QueryResult {
        var mb = proto.MsgBuilder.init(self.gpa, &self.scratch);

        // Parse (unnamed statement, no explicit param type OIDs → server infers).
        mb.start(proto.Frontend.parse) catch return ConnError.OutOfMemory;
        mb.cstr("") catch return ConnError.OutOfMemory;
        mb.cstr(sql) catch return ConnError.OutOfMemory;
        mb.int16(0) catch return ConnError.OutOfMemory;
        mb.finish(self.out) catch return ConnError.QueryFailed;

        // Bind (unnamed portal ← unnamed statement). Param format codes count = 0 → all TEXT.
        mb.start(proto.Frontend.bind) catch return ConnError.OutOfMemory;
        mb.cstr("") catch return ConnError.OutOfMemory; // portal
        mb.cstr("") catch return ConnError.OutOfMemory; // statement
        mb.int16(0) catch return ConnError.OutOfMemory; // param format codes (0 = all text)
        mb.int16(@intCast(params.len)) catch return ConnError.OutOfMemory;
        for (params) |p| {
            if (p.value) |v| {
                mb.int32(@intCast(v.len)) catch return ConnError.OutOfMemory;
                mb.bytes(v) catch return ConnError.OutOfMemory;
            } else {
                mb.int32(-1) catch return ConnError.OutOfMemory; // NULL
            }
        }
        mb.int16(0) catch return ConnError.OutOfMemory; // result format codes (0 = all text)
        mb.finish(self.out) catch return ConnError.QueryFailed;

        // Describe the portal (→ RowDescription / NoData).
        mb.start(proto.Frontend.describe) catch return ConnError.OutOfMemory;
        mb.byte('P') catch return ConnError.OutOfMemory;
        mb.cstr("") catch return ConnError.OutOfMemory;
        mb.finish(self.out) catch return ConnError.QueryFailed;

        // Execute (unnamed portal, unlimited rows).
        mb.start(proto.Frontend.execute) catch return ConnError.OutOfMemory;
        mb.cstr("") catch return ConnError.OutOfMemory;
        mb.int32(0) catch return ConnError.OutOfMemory;
        mb.finish(self.out) catch return ConnError.QueryFailed;

        // Sync.
        mb.start(proto.Frontend.sync) catch return ConnError.OutOfMemory;
        mb.finish(self.out) catch return ConnError.QueryFailed;
        self.flushOut() catch { self.broken = true; return ConnError.QueryFailed; };

        var result = QueryResult{};
        var rows: std.ArrayList([]?[]const u8) = .empty;
        defer rows.deinit(self.gpa);
        var failed = false;

        while (true) {
            const msg = try self.readMessage();
            switch (msg.type) {
                proto.Backend.row_description => {
                    result.columns = try parseRowDescription(arena, msg.body);
                },
                proto.Backend.data_row => {
                    const row = try parseDataRow(arena, msg.body);
                    rows.append(self.gpa, row) catch return ConnError.OutOfMemory;
                },
                proto.Backend.command_complete => {
                    var cur = Cursor{ .buf = msg.body };
                    const tag = cur.cstr() orelse "";
                    result.rows_affected = parseAffected(tag);
                    self.last_changes = result.rows_affected;
                },
                proto.Backend.notification_response => self.enqueueNotification(msg.body) catch {},
                proto.Backend.error_response => {
                    self.captureError(msg.body);
                    failed = true;
                },
                proto.Backend.ready_for_query => {
                    if (msg.body.len >= 1) self.tx_status = msg.body[0];
                    if (failed) return ConnError.QueryFailed;
                    result.rows = arena.dupe([]?[]const u8, rows.items) catch return ConnError.OutOfMemory;
                    return result;
                },
                else => {}, // ParseComplete, BindComplete, NoData, ParameterStatus, etc.
            }
        }
    }

    // --- LISTEN/NOTIFY (minimal hook; full realtime fan-out is a later PR) ----------

    pub const Notification = struct { pid: i32, channel: []const u8, payload: []const u8 };

    /// Subscribe to async notifications on `channel` (issues `LISTEN`). `channel` is a SQL
    /// identifier — it cannot be a bound parameter, so it is interpolated into a double-quoted
    /// identifier and first validated (rejecting `"`/NUL) to foreclose injection.
    pub fn listen(self: *Conn, channel: []const u8) ConnError!void {
        try validateIdentifier(channel);
        const sql = std.fmt.allocPrint(self.gpa, "LISTEN \"{s}\";", .{channel}) catch return ConnError.OutOfMemory;
        defer self.gpa.free(sql);
        try self.simpleExec(sql);
    }

    /// Send a NOTIFY on `channel` with `payload` (issues `NOTIFY`). Convenience for tests /
    /// single-process use; payload is bound via `pg_notify` to stay parameter-safe.
    pub fn notify(self: *Conn, arena: std.mem.Allocator, channel: []const u8, payload: []const u8) ConnError!void {
        _ = try self.execExtended(arena, "SELECT pg_notify($1, $2)", &.{
            .{ .value = channel }, .{ .value = payload },
        });
    }

    /// Parse a NotificationResponse body and append a gpa-owned copy to the queue.
    fn enqueueNotification(self: *Conn, body: []const u8) ConnError!void {
        var cur = Cursor{ .buf = body };
        const pid = cur.int32() orelse return ConnError.Protocol;
        const channel = cur.cstr() orelse return ConnError.Protocol;
        const payload = cur.cstr() orelse return ConnError.Protocol;
        // Dup both, then append. Each later failure must free what was already duped, otherwise
        // a notification storm / hostile server can accumulate leaks one allocation at a time.
        const channel_owned = self.gpa.dupe(u8, channel) catch return ConnError.OutOfMemory;
        errdefer self.gpa.free(channel_owned);
        const payload_owned = self.gpa.dupe(u8, payload) catch return ConnError.OutOfMemory;
        errdefer self.gpa.free(payload_owned);
        self.notifications.append(self.gpa, .{
            .pid = pid,
            .channel = channel_owned,
            .payload = payload_owned,
        }) catch return ConnError.OutOfMemory;
    }

    fn freeNotifications(self: *Conn) void {
        for (self.notifications.items) |n| {
            self.gpa.free(n.channel);
            self.gpa.free(n.payload);
        }
        self.notifications.deinit(self.gpa);
    }

    /// Non-blocking: pop the next already-captured notification from the in-memory queue
    /// (notifications observed during prior query drains), or null if none are queued.
    /// Copies the channel/payload into `arena`. Never touches the socket — pair it with a
    /// round-trip query (e.g. a trivial `SELECT 1`) to force the server to flush pending
    /// notifications into the queue first.
    pub fn takePending(self: *Conn, arena: std.mem.Allocator) ConnError!?Notification {
        if (self.notifications.items.len == 0) return null;
        const n = self.notifications.orderedRemove(0);
        defer {
            self.gpa.free(n.channel);
            self.gpa.free(n.payload);
        }
        return .{
            .pid = n.pid,
            .channel = arena.dupe(u8, n.channel) catch return ConnError.OutOfMemory,
            .payload = arena.dupe(u8, n.payload) catch return ConnError.OutOfMemory,
        };
    }

    /// Return the next pending async notification (copied into `arena`), draining the
    /// in-memory queue first (notifications captured during prior query drains), then
    /// blocking for one more message. Returns null only if the next wire message is not a
    /// notification. Basic building block — a later PR wires this to the realtime hub.
    pub fn waitNotification(self: *Conn, arena: std.mem.Allocator) ConnError!?Notification {
        if (self.notifications.items.len > 0) {
            const n = self.notifications.orderedRemove(0);
            defer {
                self.gpa.free(n.channel);
                self.gpa.free(n.payload);
            }
            return .{
                .pid = n.pid,
                .channel = arena.dupe(u8, n.channel) catch return ConnError.OutOfMemory,
                .payload = arena.dupe(u8, n.payload) catch return ConnError.OutOfMemory,
            };
        }
        const msg = try self.readMessage();
        if (msg.type != proto.Backend.notification_response) return null;
        var cur = Cursor{ .buf = msg.body };
        const pid = cur.int32() orelse return ConnError.Protocol;
        const channel = cur.cstr() orelse return ConnError.Protocol;
        const payload = cur.cstr() orelse return ConnError.Protocol;
        return .{
            .pid = pid,
            .channel = arena.dupe(u8, channel) catch return ConnError.OutOfMemory,
            .payload = arena.dupe(u8, payload) catch return ConnError.OutOfMemory,
        };
    }

    fn parseRowDescription(arena: std.mem.Allocator, body: []const u8) ConnError![]Column {
        var cur = Cursor{ .buf = body };
        const n = cur.int16() orelse return ConnError.Protocol;
        if (n < 0) return ConnError.Protocol;
        const cols = arena.alloc(Column, @intCast(n)) catch return ConnError.OutOfMemory;
        var i: usize = 0;
        while (i < cols.len) : (i += 1) {
            // Every field is required: a truncated RowDescription must fail loudly, not let the
            // cursor stall on garbage and desync subsequent reads.
            const name = cur.cstr() orelse return ConnError.Protocol;
            _ = cur.int32() orelse return ConnError.Protocol; // table OID
            _ = cur.int16() orelse return ConnError.Protocol; // column attr number
            const oid = cur.int32() orelse return ConnError.Protocol; // type OID
            _ = cur.int16() orelse return ConnError.Protocol; // type size
            _ = cur.int32() orelse return ConnError.Protocol; // type modifier
            _ = cur.int16() orelse return ConnError.Protocol; // format code
            cols[i] = .{ .name = arena.dupe(u8, name) catch return ConnError.OutOfMemory, .oid = @bitCast(oid) };
        }
        return cols;
    }

    fn parseDataRow(arena: std.mem.Allocator, body: []const u8) ConnError![]?[]const u8 {
        var cur = Cursor{ .buf = body };
        const n = cur.int16() orelse return ConnError.Protocol;
        if (n < 0) return ConnError.Protocol;
        const vals = arena.alloc(?[]const u8, @intCast(n)) catch return ConnError.OutOfMemory;
        var i: usize = 0;
        while (i < vals.len) : (i += 1) {
            const vlen = cur.int32() orelse return ConnError.Protocol;
            if (vlen == -1) {
                vals[i] = null; // -1 is the ONLY NULL sentinel
            } else if (vlen < 0) {
                return ConnError.Protocol; // any other negative length is malformed framing
            } else {
                const bytes = cur.take(@intCast(vlen)) orelse return ConnError.Protocol;
                vals[i] = arena.dupe(u8, bytes) catch return ConnError.OutOfMemory;
            }
        }
        return vals;
    }
};

/// Compute the PostgreSQL md5 password token: `"md5" ++ hex(md5( hex(md5(password ++ user))
/// ++ salt ))`. Writes into `out` (must be 35 bytes: "md5" + 32 hex) and returns the slice.
/// Pure + testable; `sendMd5Password` is the only caller.
fn md5Token(user: []const u8, password: []const u8, salt: []const u8, out: *[35]u8) []const u8 {
    const Md5 = std.crypto.hash.Md5;
    var inner: [16]u8 = undefined;
    {
        var h = Md5.init(.{});
        h.update(password);
        h.update(user);
        h.final(&inner);
    }
    var inner_hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&inner_hex, "{x}", .{&inner}) catch unreachable;
    var outer: [16]u8 = undefined;
    {
        var h = Md5.init(.{});
        h.update(&inner_hex);
        h.update(salt);
        h.final(&outer);
    }
    return std.fmt.bufPrint(out, "md5{x}", .{&outer}) catch unreachable;
}

test "md5Token derives the PostgreSQL md5 auth token" {
    // Cross-check against the documented construction with an independent computation.
    const Md5 = std.crypto.hash.Md5;
    const user = "alice";
    const pass = "s3cret";
    const salt = [4]u8{ 0x01, 0x02, 0x03, 0x04 };

    var inner: [16]u8 = undefined;
    Md5.hash("s3cretalice", &inner, .{});
    var inner_hex: [32]u8 = undefined;
    _ = try std.fmt.bufPrint(&inner_hex, "{x}", .{&inner});
    var buf: [32 + 4]u8 = undefined;
    @memcpy(buf[0..32], &inner_hex);
    @memcpy(buf[32..36], &salt);
    var outer: [16]u8 = undefined;
    Md5.hash(&buf, &outer, .{});
    var expected: [35]u8 = undefined;
    _ = try std.fmt.bufPrint(&expected, "md5{x}", .{&outer});

    var out: [35]u8 = undefined;
    const tok = md5Token(user, pass, &salt, &out);
    try std.testing.expectEqualStrings(&expected, tok);
    try std.testing.expect(std.mem.startsWith(u8, tok, "md5"));
}

test "validateIdentifier rejects quote and NUL, accepts normal channels" {
    try validateIdentifier("events");
    try validateIdentifier("tenant_42_changes");
    try std.testing.expectError(ConnError.InvalidIdentifier, validateIdentifier("a\"; DROP"));
    try std.testing.expectError(ConnError.InvalidIdentifier, validateIdentifier("a\x00b"));
}

/// Parse the trailing affected-row count from a CommandComplete tag, e.g. "INSERT 0 5",
/// "UPDATE 3", "DELETE 2", "SELECT 7". Returns 0 when there is no count.
fn parseAffected(tag: []const u8) i64 {
    var it = std.mem.tokenizeScalar(u8, tag, ' ');
    var last: []const u8 = "";
    while (it.next()) |tok| last = tok;
    return std.fmt.parseInt(i64, last, 10) catch 0;
}

/// Big-endian cursor over a message body. Every getter returns `null` on underflow so a
/// truncated/malformed message surfaces as `error.Protocol` at the call site.
const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    fn byte(self: *Cursor) ?u8 {
        if (self.pos >= self.buf.len) return null;
        defer self.pos += 1;
        return self.buf[self.pos];
    }
    fn int16(self: *Cursor) ?i16 {
        if (self.pos + 2 > self.buf.len) return null;
        defer self.pos += 2;
        return std.mem.readInt(i16, self.buf[self.pos..][0..2], .big);
    }
    fn int32(self: *Cursor) ?i32 {
        if (self.pos + 4 > self.buf.len) return null;
        defer self.pos += 4;
        return std.mem.readInt(i32, self.buf[self.pos..][0..4], .big);
    }
    fn take(self: *Cursor, n: usize) ?[]const u8 {
        if (self.pos + n > self.buf.len) return null;
        defer self.pos += n;
        return self.buf[self.pos .. self.pos + n];
    }
    fn cstr(self: *Cursor) ?[]const u8 {
        const start = self.pos;
        while (self.pos < self.buf.len) : (self.pos += 1) {
            if (self.buf[self.pos] == 0) {
                defer self.pos += 1;
                return self.buf[start..self.pos];
            }
        }
        return null;
    }
    fn rest(self: *Cursor) []const u8 {
        return self.buf[self.pos..];
    }
};

test "parseAffected reads the trailing row count" {
    try std.testing.expectEqual(@as(i64, 5), parseAffected("INSERT 0 5"));
    try std.testing.expectEqual(@as(i64, 3), parseAffected("UPDATE 3"));
    try std.testing.expectEqual(@as(i64, 2), parseAffected("DELETE 2"));
    try std.testing.expectEqual(@as(i64, 7), parseAffected("SELECT 7"));
    try std.testing.expectEqual(@as(i64, 0), parseAffected("CREATE TABLE"));
}

test "cursor reads ints, strings, and rest with underflow guards" {
    var cur = Cursor{ .buf = &[_]u8{ 0, 5, 'h', 'i', 0, 1, 2, 3, 4 } };
    try std.testing.expectEqual(@as(i16, 5), cur.int16().?);
    try std.testing.expectEqualStrings("hi", cur.cstr().?);
    try std.testing.expectEqual(@as(i32, 0x01020304), cur.int32().?);
    try std.testing.expect(cur.int16() == null); // underflow
}

test "parseDataRow: -1 is NULL, other negative lengths are rejected as malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One column, length -1 (0xFFFFFFFF) → NULL.
    const null_row = [_]u8{ 0, 1, 0xFF, 0xFF, 0xFF, 0xFF };
    const vals = try Conn.parseDataRow(a, &null_row);
    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0] == null);

    // One column, length -2 (0xFFFFFFFE) → not a valid sentinel → Protocol error.
    const bad_row = [_]u8{ 0, 1, 0xFF, 0xFF, 0xFF, 0xFE };
    try std.testing.expectError(ConnError.Protocol, Conn.parseDataRow(a, &bad_row));
}
