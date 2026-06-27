const std = @import("std");
const c = @import("c.zig").c;
const clock_sql = @import("clock_sql.zig");

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
        const conn = Db{ .handle = handle.? };
        // Dev-only: shadow SQLite's date/time builtins so a consumer's raw `datetime('now')`
        // honors the frozen test clock (#84). comptime no-op on a prod build, so the writer/
        // any Db.open caller (incl. openMemory) is unchanged in production.
        clock_sql.register(conn.handle);
        return conn;
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
    pub fn beginImmediate(self: *Db) DbError!void {
        return self.exec("BEGIN IMMEDIATE;");
    }

    /// Number of rows changed/inserted/deleted by the most recent DML statement on this
    /// connection. Wraps `sqlite3_changes64`. Safe to call immediately after a Stmt.step()
    /// that ran a DML statement (UPDATE/INSERT/DELETE) on this connection.
    pub fn changesCount(self: *Db) i64 {
        return c.sqlite3_changes64(self.handle);
    }
};

/// SQLITE_TRANSIENT tells SQLite to copy bound text/blobs immediately. It is the value
/// `(void(*)(void*))-1`. A function-pointer-typed -1 fails Zig's comptime alignment check
/// on targets with aligned code pointers (e.g. aarch64, where fn pointers are 4-byte
/// aligned), so we type it — and bind the destructor argument (below) — as an opaque
/// pointer. The C ABI is identical (a pointer is a pointer), with no fn-ptr alignment
/// constraint, which lets the binary cross-compile to aarch64.
const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

/// `sqlite3_bind_text` re-declared with an opaque-pointer destructor (vs translate-c's
/// function-pointer type) so `SQLITE_TRANSIENT` passes without a fn-ptr alignment cast.
/// Links to the same C symbol; ABI-identical.
extern fn sqlite3_bind_text(stmt: ?*c.sqlite3_stmt, idx: c_int, text: [*c]const u8, n: c_int, destructor: ?*const anyopaque) callconv(.c) c_int;

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn bindText(self: *Stmt, idx: c_int, val: []const u8) DbError!void {
        if (sqlite3_bind_text(self.handle, idx, val.ptr, @intCast(val.len), SQLITE_TRANSIENT) != c.SQLITE_OK)
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

test "beginImmediate starts a write transaction that can be committed" {
    var conn = try Db.openMemory();
    defer conn.close();
    try conn.exec("CREATE TABLE t(x INTEGER);");
    try conn.beginImmediate();
    try conn.exec("INSERT INTO t(x) VALUES (1);");
    try conn.commit();
    // A second begin/commit proves the first fully closed.
    try conn.beginImmediate();
    try conn.commit();
}

/// Number of read-only connections kept warm for reuse. SQLite connection open
/// (`sqlite3_open_v2` + busy_timeout PRAGMA) costs ~47us; a reused connection
/// serves a query in ~1.3us, so caching connections avoids the per-request open.
/// Sized to comfortably cover the zap worker threads (4) plus the scheduler/job
/// threads with headroom; concurrency beyond this falls back to a fresh open.
/// This is the COMPILE-TIME upper bound on warm readers (the backing array size).
/// The actual warm-pool cap is a runtime `reader_cap` field (<= this), set from the
/// comptime `.pools.readers` lever via `Pool.init`, defaulting to this value so the
/// historical behavior (16 warm readers) is preserved.
const reader_pool_size = 16;

/// Per-connection SQLite page-cache size, in KiB, applied via `PRAGMA cache_size=-N`
/// to the writer AND every reader (warm or fallback). SQLite's built-in default is
/// 2000 KiB (~2 MiB) PER connection, so with the writer + up to `reader_cap` (16) warm
/// readers the page cache alone can reach ~34 MiB. 1024 KiB halves that to ~17 MiB max
/// while keeping a healthy cache for the small-row record workloads ZigBase serves
/// (rows are looked up by indexed id; hot pages stay resident). Tunable per-deploy via
/// the `.pools.cache_kib` comptime lever -> `Pool.initOpts.cache_kib`. A larger value
/// trades RAM for fewer page faults on big working sets; a smaller one shrinks a
/// memory-constrained deploy. The negative form pins the cache to a byte budget
/// (page-size independent), unlike a positive page count.
pub const default_cache_kib: u32 = 1024;

pub const PoolOptions = struct {
    /// Warm-reader-pool cap (<= reader_pool_size); see `initCapped`.
    reader_cap: usize = reader_pool_size,
    /// Per-connection page-cache budget in KiB; see `default_cache_kib`.
    cache_kib: u32 = default_cache_kib,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    path: [:0]const u8, // owned copy
    writer: Db,
    io: std.Io,
    // Blocking writer lock. The single writer connection serializes all writes; a
    // contended waiter sleeps on a futex (std.Io.Mutex) instead of busy-spinning,
    // which keeps throughput from collapsing and the tail latency bounded under high
    // write concurrency. On Linux std.Io.Threaded backs futexWait/Wake with the raw
    // OS futex syscall, so this is correct from any OS thread (zap workers, scheduler
    // threads) regardless of the event loop.
    writer_mutex: std.Io.Mutex = .init,

    // Warm pool of read-only connections. `readers[0..reader_count]` are the live
    // checked-in connections available for reuse, guarded by `reader_mutex`.
    reader_mutex: std.atomic.Mutex = .unlocked,
    readers: [reader_pool_size]Db = undefined,
    reader_count: usize = 0,
    // Runtime cap on warm pooled readers (<= reader_pool_size). Comptime lever
    // `.pools.readers` sets this; defaults to reader_pool_size (16) for legacy behavior.
    reader_cap: usize = reader_pool_size,
    // Per-connection SQLite page-cache budget (KiB), applied to the writer and every
    // reader. Comptime lever `.pools.cache_kib`; defaults to default_cache_kib.
    cache_kib: u32 = default_cache_kib,

    /// Open a pool with the default warm-reader cap (16) and page-cache budget. Thin
    /// wrapper over `initOpts` kept for the many call sites (tests/CLI) that don't tune.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) (DbError || std.mem.Allocator.Error)!Pool {
        return initOpts(allocator, io, path, .{});
    }

    /// Open a pool, capping the warm reader pool at `reader_cap` (clamped to the
    /// compile-time backing-array size). Excess concurrent readers still fall back
    /// to a fresh open and are closed on release, so a small cap shrinks the warm
    /// footprint without changing read-only/thread-safe/WAL semantics. Uses the
    /// default page-cache budget; `initOpts` to tune both.
    pub fn initCapped(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8, reader_cap: usize) (DbError || std.mem.Allocator.Error)!Pool {
        return initOpts(allocator, io, path, .{ .reader_cap = reader_cap });
    }

    /// Open a pool with explicit `PoolOptions` (warm-reader cap + per-connection page-cache
    /// budget). The cache budget is applied as `PRAGMA cache_size=-cache_kib` on the writer
    /// here and on every reader in `openReader`, so it bounds the page cache across all
    /// connections; it changes only memory/perf trade-off, not read/write/WAL semantics.
    pub fn initOpts(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8, options: PoolOptions) (DbError || std.mem.Allocator.Error)!Pool {
        const reader_cap = options.reader_cap;
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
        // Checkpoint less often than the 1000-page default. Each checkpoint briefly
        // blocks the (single) writer; doubling the threshold cut checkpoint-induced
        // stalls and raised sustained single-writer INSERT throughput by ~50% in
        // measurement, while keeping the WAL bounded (~2000 pages ≈ 8 MiB peak).
        // synchronous=NORMAL still governs fsync, so durability is unchanged.
        try writer.exec("PRAGMA wal_autocheckpoint=2000;");
        // Bound the writer's page cache to cache_kib (negative = KiB budget). PRAGMA
        // values can't be bound, so format the (trusted, in-range) integer into the SQL.
        try setCacheSize(&writer, options.cache_kib);
        return .{
            .allocator = allocator,
            .path = owned,
            .writer = writer,
            .io = io,
            .reader_cap = @min(reader_cap, reader_pool_size),
            .cache_kib = options.cache_kib,
        };
    }

    /// Apply `PRAGMA cache_size=-kib` to `db` (negative pins a KiB byte budget rather
    /// than a page count). cache_kib is clamped to i32 range; 0 leaves SQLite's default.
    fn setCacheSize(db: *Db, cache_kib: u32) DbError!void {
        if (cache_kib == 0) return;
        const kib: i64 = @min(@as(i64, cache_kib), std.math.maxInt(i32));
        var buf: [64]u8 = undefined;
        const sql = std.fmt.bufPrintZ(&buf, "PRAGMA cache_size=-{d};", .{kib}) catch return DbError.ExecFailed;
        try db.exec(sql);
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

    /// Blocks on the writer mutex (futex-backed; waiters sleep, not spin) and returns
    /// the writer connection. Caller MUST call releaseWriter() when done.
    pub fn acquireWriter(self: *Pool) *Db {
        self.writer_mutex.lockUncancelable(self.io);
        return &self.writer;
    }

    pub fn releaseWriter(self: *Pool) void {
        self.writer_mutex.unlock(self.io);
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
        // Match the writer's page-cache budget on every reader (warm + fallback) so the
        // pool's total page-cache footprint is bounded by (1 + reader_cap) * cache_kib.
        try setCacheSize(&db, self.cache_kib);
        // Dev-only: same date/time-builtin shadowing as the writer (#84). The reader path
        // opens via raw sqlite3_open_v2 (not Db.open), so register here too. comptime no-op
        // on a prod build.
        clock_sql.register(db.handle);
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
        if (self.reader_count < self.reader_cap) {
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

    var pool = try Pool.init(std.testing.allocator, std.testing.io, db_path);
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

    var pool = try Pool.init(std.testing.allocator, std.testing.io, db_path);
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

    var pool = try Pool.init(std.testing.allocator, std.testing.io, db_path);
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

fn readCacheSize(db: *Db) !i64 {
    var stmt = try db.prepare("PRAGMA cache_size;");
    defer stmt.finalize();
    try std.testing.expect((try stmt.step()) == true);
    return stmt.columnInt(0);
}

test "pool: cache_kib lever bounds the page cache on writer AND readers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir_path}, 0);
    defer std.testing.allocator.free(db_path);

    // 512 KiB budget -> PRAGMA cache_size reports -512 (negative = KiB) on every connection.
    var pool = try Pool.initOpts(std.testing.allocator, std.testing.io, db_path, .{ .cache_kib = 512 });
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try std.testing.expectEqual(@as(i64, -512), try readCacheSize(w));
    }
    var reader = try pool.openReader();
    defer reader.close();
    try std.testing.expectEqual(@as(i64, -512), try readCacheSize(&reader));
}

test "pool: default cache_kib applies the memory-conscious default to connections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/test.db", .{dir_path}, 0);
    defer std.testing.allocator.free(db_path);

    var pool = try Pool.init(std.testing.allocator, std.testing.io, db_path);
    defer pool.deinit();
    const expected: i64 = -@as(i64, default_cache_kib);
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try std.testing.expectEqual(expected, try readCacheSize(w));
    }
    var reader = try pool.openReader();
    defer reader.close();
    try std.testing.expectEqual(expected, try readCacheSize(&reader));
}
