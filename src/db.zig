const std = @import("std");
const c = @import("c.zig").c;

/// Returns the linked SQLite library version string, e.g. "3.53.2".
pub fn libVersion() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

test "sqlite library links and reports a 3.x version" {
    const v = libVersion();
    try std.testing.expect(std.mem.startsWith(u8, v, "3."));
}

pub const DbError = error{ OpenFailed, ExecFailed, PrepareFailed, BindFailed, StepFailed, WalNotEnabled };

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn openMemory() DbError!Db {
        return open(":memory:");
    }

    pub fn open(path: [:0]const u8) DbError!Db {
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path.ptr, &handle, flags, null) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return DbError.OpenFailed;
        }
        return .{ .handle = handle.? };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn errMsg(self: *Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    /// Execute one or more SQL statements with no bound parameters.
    pub fn exec(self: *Db, sql: [:0]const u8) DbError!void {
        if (c.sqlite3_exec(self.handle, sql.ptr, null, null, null) != c.SQLITE_OK) {
            return DbError.ExecFailed;
        }
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) DbError!Stmt {
        var handle: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &handle, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        return .{ .handle = handle.? };
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
};

/// SQLITE_TRANSIENT tells SQLite to copy bound text/blobs immediately.
const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn bindText(self: *Stmt, idx: c_int, val: []const u8) DbError!void {
        if (c.sqlite3_bind_text(self.handle, idx, val.ptr, @intCast(val.len), SQLITE_TRANSIENT) != c.SQLITE_OK)
            return DbError.BindFailed;
    }

    pub fn bindInt(self: *Stmt, idx: c_int, val: i64) DbError!void {
        if (c.sqlite3_bind_int64(self.handle, idx, val) != c.SQLITE_OK)
            return DbError.BindFailed;
    }

    pub fn bindDouble(self: *Stmt, idx: c_int, val: f64) DbError!void {
        if (c.sqlite3_bind_double(self.handle, idx, val) != c.SQLITE_OK)
            return DbError.BindFailed;
    }

    pub fn bindNull(self: *Stmt, idx: c_int) DbError!void {
        if (c.sqlite3_bind_null(self.handle, idx) != c.SQLITE_OK)
            return DbError.BindFailed;
    }

    /// Advances to the next row. Returns true if a row is available, false when done.
    pub fn step(self: *Stmt) DbError!bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => DbError.StepFailed,
        };
    }

    pub fn columnText(self: *Stmt, idx: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.handle, idx);
        if (ptr == null) return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, idx));
        return ptr[0..len];
    }

    pub fn columnInt(self: *Stmt, idx: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, idx);
    }

    pub fn columnDouble(self: *Stmt, idx: c_int) f64 {
        return c.sqlite3_column_double(self.handle, idx);
    }

    pub const ColumnType = enum { Null, Integer, Float, Text, Blob };

    pub fn columnType(self: *Stmt, idx: c_int) ColumnType {
        return switch (c.sqlite3_column_type(self.handle, idx)) {
            c.SQLITE_INTEGER => .Integer,
            c.SQLITE_FLOAT => .Float,
            c.SQLITE_TEXT => .Text,
            c.SQLITE_BLOB => .Blob,
            else => .Null,
        };
    }

    pub fn isNull(self: *Stmt, idx: c_int) bool {
        return c.sqlite3_column_type(self.handle, idx) == c.SQLITE_NULL;
    }

    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.handle);
    }

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }
};

test "open in-memory db, create a table, exec succeeds" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);");
}

test "exec returns ExecFailed on invalid SQL" {
    var db = try Db.openMemory();
    defer db.close();
    try std.testing.expectError(DbError.ExecFailed, db.exec("NOT VALID SQL;"));
}

test "prepared insert with bound params, then read back" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);");

    {
        var ins = try db.prepare("INSERT INTO t (id, name) VALUES (?1, ?2);");
        defer ins.finalize();
        try ins.bindInt(1, 42);
        try ins.bindText(2, "ada");
        try std.testing.expect((try ins.step()) == false); // INSERT yields no row
    }

    var sel = try db.prepare("SELECT id, name FROM t WHERE id = ?1;");
    defer sel.finalize();
    try sel.bindInt(1, 42);
    try std.testing.expect((try sel.step()) == true);
    try std.testing.expectEqual(@as(i64, 42), sel.columnInt(0));
    try std.testing.expectEqualStrings("ada", sel.columnText(1));
    try std.testing.expect((try sel.step()) == false);
}

test "rollback discards uncommitted writes" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY);");

    try db.begin();
    try db.exec("INSERT INTO t (id) VALUES (1);");
    try db.rollback();

    var sel = try db.prepare("SELECT COUNT(*) FROM t;");
    defer sel.finalize();
    try std.testing.expect((try sel.step()) == true);
    try std.testing.expectEqual(@as(i64, 0), sel.columnInt(0));
}

test "commit persists writes" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY);");

    try db.begin();
    try db.exec("INSERT INTO t (id) VALUES (1);");
    try db.commit();

    var sel = try db.prepare("SELECT COUNT(*) FROM t;");
    defer sel.finalize();
    try std.testing.expect((try sel.step()) == true);
    try std.testing.expectEqual(@as(i64, 1), sel.columnInt(0));
}

/// Number of read-only connections kept warm for reuse. SQLite connection open
/// (`sqlite3_open_v2` + busy_timeout PRAGMA) costs ~47us; a reused connection
/// serves a query in ~1.3us, so caching connections avoids the per-request open.
/// Sized to comfortably cover the zap worker threads (4) plus the scheduler/job
/// threads with headroom; concurrency beyond this falls back to a fresh open.
const reader_pool_size = 16;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    path: [:0]const u8, // owned copy
    writer: Db,
    // std.Thread.Mutex was removed in Zig 0.16; use std.atomic.Mutex (spin) instead.
    // TODO(perf): std.atomic.Mutex is a spinlock; replace with a futex/blocking mutex for write-latency workloads once one is available in this std.
    writer_mutex: std.atomic.Mutex = .unlocked,

    // Warm pool of read-only connections. `readers[0..reader_count]` are the live
    // checked-in connections available for reuse, guarded by `reader_mutex`.
    reader_mutex: std.atomic.Mutex = .unlocked,
    readers: [reader_pool_size]Db = undefined,
    reader_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, path: [:0]const u8) (DbError || std.mem.Allocator.Error)!Pool {
        const owned = try allocator.dupeZ(u8, path);
        errdefer allocator.free(owned);
        var writer = try Db.open(owned);
        errdefer writer.close();
        // WAL + sane durability defaults. sqlite3_exec reports OK even when WAL
        // was not actually applied, so read back the journal_mode and verify.
        {
            var stmt = try writer.prepare("PRAGMA journal_mode=WAL;");
            defer stmt.finalize();
            if ((try stmt.step()) == false) return DbError.WalNotEnabled;
            const mode = stmt.columnText(0);
            if (!std.ascii.eqlIgnoreCase(mode, "wal")) return DbError.WalNotEnabled;
        }
        try writer.exec("PRAGMA synchronous=NORMAL;");
        try writer.exec("PRAGMA foreign_keys=ON;");
        try writer.exec("PRAGMA busy_timeout=5000;");
        return .{ .allocator = allocator, .path = owned, .writer = writer };
    }

    pub fn deinit(self: *Pool) void {
        // Close any warm readers still parked in the pool. deinit runs at
        // shutdown with no other threads touching the pool, but take the lock
        // anyway to keep the access discipline uniform.
        while (!self.reader_mutex.tryLock()) std.atomic.spinLoopHint();
        var i: usize = 0;
        while (i < self.reader_count) : (i += 1) self.readers[i].close();
        self.reader_count = 0;
        self.reader_mutex.unlock();
        self.writer.close();
        self.allocator.free(self.path);
    }

    /// Spin-locks the writer mutex and returns the writer connection.
    /// Caller MUST call releaseWriter() when done.
    pub fn acquireWriter(self: *Pool) *Db {
        while (!self.writer_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        return &self.writer;
    }

    pub fn releaseWriter(self: *Pool) void {
        self.writer_mutex.unlock();
    }

    /// Opens a fresh read-only connection. Caller owns it and must call close().
    pub fn openReader(self: *Pool) DbError!Db {
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(self.path.ptr, &handle, flags, null) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return DbError.OpenFailed;
        }
        var db = Db{ .handle = handle.? };
        errdefer db.close();
        try db.exec("PRAGMA busy_timeout=5000;");
        return db;
    }

    /// Checks out a read-only connection, reusing a warm pooled one when available
    /// to avoid the ~47us per-request `sqlite3_open_v2`+PRAGMA cost. Falls back to
    /// opening a fresh connection if the warm pool is empty. Each connection uses
    /// SQLITE_OPEN_FULLMUTEX and callers run a fresh prepared statement per query,
    /// so pooled reuse keeps the same read-only + thread-safe + WAL semantics as a
    /// freshly opened reader. Returns a `Db` by value (same shape as openReader());
    /// caller MUST hand it back via releaseReader() instead of close().
    pub fn acquireReader(self: *Pool) DbError!Db {
        while (!self.reader_mutex.tryLock()) std.atomic.spinLoopHint();
        if (self.reader_count > 0) {
            self.reader_count -= 1;
            const db = self.readers[self.reader_count];
            self.reader_mutex.unlock();
            return db;
        }
        self.reader_mutex.unlock();
        // Pool empty (cold start or more concurrent readers than slots): open one.
        return self.openReader();
    }

    /// Returns a connection obtained from acquireReader() to the warm pool for
    /// reuse when a slot is free; otherwise closes it. SQLite finalizes any
    /// per-query statements when the caller finalizes them, and a read-only
    /// connection never holds an open transaction, so there is no stale state to
    /// reset between uses. Pass the same `*Db` you received from acquireReader().
    pub fn releaseReader(self: *Pool, reader: *Db) void {
        while (!self.reader_mutex.tryLock()) std.atomic.spinLoopHint();
        if (self.reader_count < reader_pool_size) {
            self.readers[self.reader_count] = reader.*;
            self.reader_count += 1;
            self.reader_mutex.unlock();
            return;
        }
        self.reader_mutex.unlock();
        reader.close();
    }
};

test "bindDouble round-trips a REAL" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (x REAL);");
    var ins = try db.prepare("INSERT INTO t (x) VALUES (?1);");
    try ins.bindDouble(1, 2.5);
    try std.testing.expect((try ins.step()) == false);
    ins.finalize();
    var sel = try db.prepare("SELECT x FROM t;");
    defer sel.finalize();
    try std.testing.expect((try sel.step()));
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), sel.columnDouble(0), 0.0001);
}

test "column type, double, and null detection" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t (a REAL, b TEXT);");
    try db.exec("INSERT INTO t (a, b) VALUES (3.5, NULL);");
    var sel = try db.prepare("SELECT a, b FROM t;");
    defer sel.finalize();
    try std.testing.expect((try sel.step()) == true);
    try std.testing.expectEqual(Stmt.ColumnType.Float, sel.columnType(0));
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), sel.columnDouble(0), 0.0001);
    try std.testing.expect(sel.isNull(1));
}

test "pool: a reader sees writes committed by the writer (WAL)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // realPathFileAlloc returns [:0]u8 (null-terminated) in Zig 0.16.
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir_path}, 0);
    defer std.testing.allocator.free(db_path);

    var pool = try Pool.init(std.testing.allocator, db_path);
    defer pool.deinit();

    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try w.exec("CREATE TABLE t (id INTEGER PRIMARY KEY);");
        try w.exec("INSERT INTO t (id) VALUES (7);");
    }

    var reader = try pool.openReader();
    defer reader.close();
    var sel = try reader.prepare("SELECT id FROM t;");
    defer sel.finalize();
    try std.testing.expect((try sel.step()) == true);
    try std.testing.expectEqual(@as(i64, 7), sel.columnInt(0));
}

test "pool: acquireReader reuses a warm connection and sees committed writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir_path}, 0);
    defer std.testing.allocator.free(db_path);

    var pool = try Pool.init(std.testing.allocator, db_path);
    defer pool.deinit();

    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try w.exec("CREATE TABLE t (id INTEGER PRIMARY KEY);");
        try w.exec("INSERT INTO t (id) VALUES (7);");
    }

    // First checkout: pool is cold, so this opens a fresh connection.
    try std.testing.expectEqual(@as(usize, 0), pool.reader_count);
    var r1 = try pool.acquireReader();
    {
        var sel = try r1.prepare("SELECT id FROM t;");
        defer sel.finalize();
        try std.testing.expect((try sel.step()) == true);
        try std.testing.expectEqual(@as(i64, 7), sel.columnInt(0));
    }
    const h1 = r1.handle;
    pool.releaseReader(&r1); // parks it in the warm pool
    try std.testing.expectEqual(@as(usize, 1), pool.reader_count);

    // Second checkout: must hand back the SAME warm connection and still read fine,
    // proving there is no stale state left behind from the prior use.
    var r2 = try pool.acquireReader();
    try std.testing.expectEqual(h1, r2.handle);
    try std.testing.expectEqual(@as(usize, 0), pool.reader_count);
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try w.exec("INSERT INTO t (id) VALUES (8);");
    }
    var sel2 = try r2.prepare("SELECT COUNT(*) FROM t;");
    defer sel2.finalize();
    try std.testing.expect((try sel2.step()) == true);
    try std.testing.expectEqual(@as(i64, 2), sel2.columnInt(0));
    pool.releaseReader(&r2);
}

test "pool: releaseReader closes overflow beyond the warm pool capacity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir_path}, 0);
    defer std.testing.allocator.free(db_path);

    var pool = try Pool.init(std.testing.allocator, db_path);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try w.exec("CREATE TABLE t (id INTEGER PRIMARY KEY);");
    }

    // Check out more readers than the pool can hold, then return them all. The
    // pool must fill to capacity and close the rest without leaking handles.
    var readers: [reader_pool_size + 4]Db = undefined;
    for (&readers) |*rd| rd.* = try pool.acquireReader();
    for (&readers) |*rd| pool.releaseReader(rd);
    try std.testing.expectEqual(reader_pool_size, pool.reader_count);
}
