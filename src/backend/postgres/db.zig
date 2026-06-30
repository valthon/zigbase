//! PostgreSQL `Db`, mirroring the SQLite `Db` surface in `src/db.zig`. A `Db` is a thin,
//! copyable handle around a heap-pinned `*Conn` (so it can be stored by value in the pool,
//! exactly like the SQLite `Db`). Unlike SQLite, opening a PG connection needs an allocator
//! and a `std.Io`, so `open` takes them explicitly; PR-1b's tagged-union wrapper reconciles
//! this with the SQLite arm.

const std = @import("std");
const conn_mod = @import("conn.zig");
const connstr = @import("connstr.zig");
const stmt_mod = @import("stmt.zig");
const frozen_clock = @import("clock.zig");

pub const Conn = conn_mod.Conn;
pub const Stmt = stmt_mod.Stmt;

pub const DbError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    /// PostgreSQL has no `:memory:` database — `openMemory` is unsupported on this backend.
    Unsupported,
    OutOfMemory,
};

pub const Db = struct {
    conn: *Conn,
    gpa: std.mem.Allocator,
    /// Type-erased pointer to the resolved field-encryption cipher (see SQLite `Db.field_cipher`).
    /// Stamped onto pooled connections at acquire time and copied into every Stmt by `prepare`.
    field_cipher: ?*const anyopaque = null,

    /// Connect to `uri` (`postgres://user:pass@host:port/dbname?sslmode=...`) and complete
    /// startup + authentication. Caller owns the connection and must call `close`.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, uri: []const u8) DbError!Db {
        var cfg = connstr.parse(gpa, uri) catch return DbError.OpenFailed;
        defer cfg.deinit();
        const conn = conn_mod.Conn.connect(gpa, io, cfg) catch return DbError.OpenFailed;
        // Dev-only: install the frozen test clock (`ZIGBASE_FAKE_NOW`) on every connection — the
        // Postgres analog of the SQLite `clock_sql`/`clock_vfs` shims. comptime no-op + does
        // nothing unless a freeze is active (see backend/postgres/clock.zig). The pool opens
        // BOTH the writer and every reader through `open`, so this covers all connections.
        frozen_clock.install(conn);
        return .{ .conn = conn, .gpa = gpa };
    }

    /// PostgreSQL has no in-memory database. Provided for surface parity; always fails.
    pub fn openMemory() DbError!Db {
        return DbError.Unsupported;
    }

    pub fn close(self: *Db) void {
        self.conn.deinit();
    }

    pub fn errMsg(self: *Db) []const u8 {
        return self.conn.errMsg();
    }

    /// True if the underlying connection is safe to reuse (not desynced/dead and not stuck in
    /// a failed transaction). The pool consults this to avoid recycling poisoned connections.
    pub fn isHealthy(self: *const Db) bool {
        return self.conn.isHealthy();
    }

    /// Execute one or more statements with no bound parameters (simple protocol).
    pub fn exec(self: *Db, sql: [:0]const u8) DbError!void {
        self.conn.simpleExec(sql) catch return DbError.ExecFailed;
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) DbError!Stmt {
        return stmt_mod.Stmt.init(self.conn, self.gpa, sql, self.field_cipher) catch return DbError.PrepareFailed;
    }

    pub fn begin(self: *Db) DbError!void {
        try self.exec("BEGIN;");
    }
    pub fn commit(self: *Db) DbError!void {
        try self.exec("COMMIT;");
    }
    pub fn rollback(self: *Db) DbError!void {
        try self.exec("ROLLBACK;");
    }
    /// PostgreSQL has no `BEGIN IMMEDIATE`; a plain `BEGIN` is the closest equivalent.
    pub fn beginImmediate(self: *Db) DbError!void {
        try self.exec("BEGIN;");
    }

    /// Rows changed/inserted/deleted by the most recent DML on this connection. Parsed from
    /// the CommandComplete tag (the PG analog of `sqlite3_changes64`).
    pub fn changesCount(self: *Db) i64 {
        return self.conn.last_changes;
    }

    // --- LISTEN/NOTIFY (#159, PR-6b cross-instance realtime) --------------------
    // Thin wrappers over the conn-level primitives, mapping `ConnError` → `DbError` so the
    // `db.Db` seam (`db.dbListen`/`dbNotify`/`dbWaitNotification`) stays backend-uniform. Only
    // ever reached on a Postgres-backed `Db`; SQLite stays single-process (in-process hub).

    pub const Notification = conn_mod.Conn.Notification;

    /// `LISTEN "<channel>"` — subscribe this connection to async notifications.
    pub fn listen(self: *Db, channel: []const u8) DbError!void {
        self.conn.listen(channel) catch return DbError.ExecFailed;
    }

    /// `NOTIFY` on `channel` carrying `payload` (bound via `pg_notify`, parameter-safe).
    pub fn notify(self: *Db, arena: std.mem.Allocator, channel: []const u8, payload: []const u8) DbError!void {
        self.conn.notify(arena, channel, payload) catch return DbError.ExecFailed;
    }

    /// Block for the next async notification (copied into `arena`), draining any already
    /// queued during prior query drains first. Null when the next wire message is not one.
    pub fn waitNotification(self: *Db, arena: std.mem.Allocator) DbError!?Notification {
        return self.conn.waitNotification(arena) catch return DbError.ExecFailed;
    }

    /// Non-blocking: pop the next already-captured notification, or null. Pair with a trivial
    /// round-trip query to force the server to flush pending notifications into the queue.
    pub fn takePending(self: *Db, arena: std.mem.Allocator) DbError!?Notification {
        return self.conn.takePending(arena) catch return DbError.ExecFailed;
    }
};
