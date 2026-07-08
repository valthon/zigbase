//! Database seam (issue #159, PR-1b). Historically this file WAS the SQLite backend; it is now
//! the runtime-selectable tagged-union over the SQLite backend (`backend/sqlite/db.zig`, the
//! verbatim former body) and the pure-Zig Postgres backend (`backend/postgres/`, PR-1a).
//!
//! ## Byte-identical default build
//! The whole Postgres arm is gated behind the comptime `build_options.postgres` flag. With
//! `-Dpostgres=false` (the default), `Db`/`Stmt`/`Pool`/`DbError` are *direct aliases* of the
//! SQLite backend's types — not single-variant unions — so every one of the ~480 call sites
//! resolves to exactly the same SQLite code path it did before, and the shipped binary is
//! byte-for-byte unchanged. Only `-Dpostgres=true` turns `Db`/`Stmt` into real tagged unions
//! and `Pool` into a struct-over-union (the latter because `acquireWriter` returns `*Db`, which
//! a bare union cannot synthesize from an inner `*sqlite.Db`/`*pg.Db` — see `Pool.writer_view`).
//!
//! ## Selection
//! The backend is chosen once, at pool-open time, from the target string: a `postgres://` /
//! `postgresql://` URI opens the PG backend; anything else (a file path / `:memory:`) opens
//! SQLite. `poolDialect`/`poolBackend` expose the active backend's SQL `Dialect` to the rest of
//! the stack. The default file-path path is unchanged.

const std = @import("std");
const build_options = @import("build_options");
const sqlite = @import("backend/sqlite/db.zig");
const dialect_mod = @import("sql/dialect.zig");

/// Imported only when Postgres is compiled in; an empty struct otherwise so the default build
/// never references the subtree (and links zero new symbols).
const pg = if (build_options.postgres) @import("backend/postgres/postgres.zig") else struct {};

/// Which database backend is active. The tag of the `Db`/`Stmt`/`Pool` unions under
/// `-Dpostgres=true`; always `.sqlite` in the default build.
pub const Backend = enum { sqlite, postgres };

pub const Dialect = dialect_mod.Dialect;
/// The dialect/SQL-flavor tag (sqlite | postgres). Parallels `Backend`; kept distinct so the
/// dialect layer stays independent of the database seam.
pub const DialectKind = dialect_mod.Kind;

/// The linked SQLite library version (e.g. "3.53.2"). Always available — SQLite is compiled
/// into every build regardless of the Postgres gate.
pub fn libVersion() []const u8 {
    return sqlite.libVersion();
}

pub const default_cache_kib = sqlite.default_cache_kib;
/// Pool tuning. The SQLite options (warm-reader cap + page-cache budget) are the superset;
/// the Postgres pool consumes only `reader_cap` and ignores `cache_kib`.
pub const PoolOptions = sqlite.PoolOptions;

/// The error set of database operations. In the default build this is *exactly* the SQLite
/// backend's set (so error values/names are unchanged); with Postgres compiled in it is the
/// union of both backends' errors.
pub const DbError = if (build_options.postgres)
    sqlite.DbError || pg.DbError
else
    sqlite.DbError;

// ===========================================================================
// Db
// ===========================================================================

pub const Db = if (build_options.postgres) union(Backend) {
    sqlite: sqlite.Db,
    postgres: pg.Db,

    /// In-memory SQLite (used pervasively by unit tests + the realtime rule sandbox). There is
    /// no Postgres analog, so this always opens the SQLite arm.
    pub fn openMemory() DbError!Db {
        return .{ .sqlite = try sqlite.Db.openMemory() };
    }

    /// Open a SQLite database file. Reserved for the few call sites that open a concrete local
    /// `data.db` (e.g. the codegen data-dir adapter); Postgres is opened via the pool / the
    /// `openPostgres` constructor.
    pub fn open(path: [:0]const u8) DbError!Db {
        return .{ .sqlite = try sqlite.Db.open(path) };
    }

    /// Open a Postgres connection directly from a `postgres://…` URI.
    pub fn openPostgres(gpa: std.mem.Allocator, io: std.Io, uri: []const u8) DbError!Db {
        return .{ .postgres = try pg.Db.open(gpa, io, uri) };
    }

    pub fn close(self: *Db) void {
        switch (self.*) {
            inline else => |*d| d.close(),
        }
    }
    pub fn errMsg(self: *Db) []const u8 {
        switch (self.*) {
            inline else => |*d| return d.errMsg(),
        }
    }
    pub fn exec(self: *Db, sql: [:0]const u8) DbError!void {
        switch (self.*) {
            inline else => |*d| return d.exec(sql),
        }
    }
    pub fn prepare(self: *Db, sql: [:0]const u8) DbError!Stmt {
        return switch (self.*) {
            .sqlite => |*d| .{ .sqlite = try d.prepare(sql) },
            .postgres => |*d| .{ .postgres = try d.prepare(sql) },
        };
    }
    pub fn begin(self: *Db) DbError!void {
        switch (self.*) {
            inline else => |*d| return d.begin(),
        }
    }
    pub fn commit(self: *Db) DbError!void {
        switch (self.*) {
            inline else => |*d| return d.commit(),
        }
    }
    pub fn rollback(self: *Db) DbError!void {
        switch (self.*) {
            inline else => |*d| return d.rollback(),
        }
    }
    pub fn beginImmediate(self: *Db) DbError!void {
        switch (self.*) {
            inline else => |*d| return d.beginImmediate(),
        }
    }
    pub fn changesCount(self: *Db) i64 {
        switch (self.*) {
            inline else => |*d| return d.changesCount(),
        }
    }
} else sqlite.Db;

// ===========================================================================
// Stmt
// ===========================================================================

pub const Stmt = if (build_options.postgres) union(Backend) {
    sqlite: sqlite.Stmt,
    postgres: pg.Stmt,

    /// Unified column-type tag. Field ORDER is identical to both backends' own `ColumnType`
    /// (Null, Integer, Float, Text, Blob), so `columnType` maps by ordinal.
    pub const ColumnType = enum { Null, Integer, Float, Text, Blob };

    pub fn bindText(self: *Stmt, idx: c_int, val: []const u8) DbError!void {
        switch (self.*) {
            inline else => |*s| return s.bindText(idx, val),
        }
    }
    pub fn bindInt(self: *Stmt, idx: c_int, val: i64) DbError!void {
        switch (self.*) {
            inline else => |*s| return s.bindInt(idx, val),
        }
    }
    pub fn bindDouble(self: *Stmt, idx: c_int, val: f64) DbError!void {
        switch (self.*) {
            inline else => |*s| return s.bindDouble(idx, val),
        }
    }
    pub fn bindNull(self: *Stmt, idx: c_int) DbError!void {
        switch (self.*) {
            inline else => |*s| return s.bindNull(idx),
        }
    }
    pub fn step(self: *Stmt) DbError!bool {
        switch (self.*) {
            inline else => |*s| return s.step(),
        }
    }
    pub fn columnText(self: *Stmt, idx: c_int) []const u8 {
        switch (self.*) {
            inline else => |*s| return s.columnText(idx),
        }
    }
    /// Number of result columns. On Postgres this is only known after the first `step()`
    /// (the row description arrives with the result); on SQLite it is valid right after
    /// `prepare`. Name-mapped decoders (`data.queryAs`) step once before reading it so the
    /// count is populated on both backends.
    pub fn columnCount(self: *Stmt) c_int {
        switch (self.*) {
            inline else => |*s| return s.columnCount(),
        }
    }
    /// The name of result column `idx` (respecting `AS` aliases). Empty if out of range —
    /// or, on Postgres, before the first `step()`. Both backends expose result-column names
    /// (sqlite: `sqlite3_column_name`; postgres: the RowDescription `name`).
    pub fn columnName(self: *Stmt, idx: c_int) []const u8 {
        switch (self.*) {
            inline else => |*s| return s.columnName(idx),
        }
    }
    pub fn columnInt(self: *Stmt, idx: c_int) i64 {
        switch (self.*) {
            inline else => |*s| return s.columnInt(idx),
        }
    }
    pub fn columnDouble(self: *Stmt, idx: c_int) f64 {
        switch (self.*) {
            inline else => |*s| return s.columnDouble(idx),
        }
    }
    pub fn columnType(self: *Stmt, idx: c_int) ColumnType {
        switch (self.*) {
            // Same ordinal layout across all three enums (asserted by the seam tests).
            inline else => |*s| return @enumFromInt(@intFromEnum(s.columnType(idx))),
        }
    }
    pub fn isNull(self: *Stmt, idx: c_int) bool {
        switch (self.*) {
            inline else => |*s| return s.isNull(idx),
        }
    }
    pub fn reset(self: *Stmt) void {
        switch (self.*) {
            inline else => |*s| s.reset(),
        }
    }
    pub fn finalize(self: *Stmt) void {
        switch (self.*) {
            inline else => |*s| s.finalize(),
        }
    }
} else sqlite.Stmt;

// ===========================================================================
// Pool
// ===========================================================================

pub const Pool = if (build_options.postgres) struct {
    impl: Impl,
    /// A union `Db` view of the active backend's single writer connection. `acquireWriter`
    /// refreshes this from the inner pool's writer (under the writer mutex) and returns a
    /// pointer to it, preserving the SQLite pool's `acquireWriter() *Db` contract. It is a
    /// single shared slot, which is safe because the writer mutex serializes holders.
    writer_view: Db = undefined,
    /// Observability/test counter: total successful writer acquisitions across either
    /// backend. Mirrors the inner pools' own counters (see `backend/sqlite/db.zig`).
    writer_acquires: usize = 0,

    const Impl = union(Backend) {
        sqlite: sqlite.Pool,
        postgres: pg.Pool,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, target: [:0]const u8) (DbError || std.mem.Allocator.Error)!Pool {
        return initOpts(allocator, io, target, .{});
    }
    pub fn initCapped(allocator: std.mem.Allocator, io: std.Io, target: [:0]const u8, reader_cap: usize) (DbError || std.mem.Allocator.Error)!Pool {
        return initOpts(allocator, io, target, .{ .reader_cap = reader_cap });
    }
    pub fn initOpts(allocator: std.mem.Allocator, io: std.Io, target: [:0]const u8, options: PoolOptions) (DbError || std.mem.Allocator.Error)!Pool {
        if (connstrLooksLikePostgres(target)) {
            return .{ .impl = .{ .postgres = try pg.Pool.initOpts(allocator, io, target, .{ .reader_cap = options.reader_cap }) } };
        }
        return .{ .impl = .{ .sqlite = try sqlite.Pool.initOpts(allocator, io, target, options) } };
    }

    pub fn deinit(self: *Pool) void {
        switch (self.impl) {
            inline else => |*p| p.deinit(),
        }
    }

    pub fn acquireWriter(self: *Pool) *Db {
        switch (self.impl) {
            inline else => |*p, tag| {
                const inner = p.acquireWriter();
                self.writer_acquires += 1;
                self.writer_view = @unionInit(Db, @tagName(tag), inner.*);
                return &self.writer_view;
            },
        }
    }
    pub fn releaseWriter(self: *Pool) void {
        switch (self.impl) {
            inline else => |*p| p.releaseWriter(),
        }
    }

    pub fn acquireReader(self: *Pool) DbError!Db {
        switch (self.impl) {
            inline else => |*p, tag| return @unionInit(Db, @tagName(tag), try p.acquireReader()),
        }
    }
    pub fn releaseReader(self: *Pool, reader: *Db) void {
        switch (self.impl) {
            inline else => |*p, tag| {
                // M-4: the returned reader's active union arm MUST match the pool's backend —
                // `@field(reader.*, tag)` reads the inactive variant (UB) otherwise. A caller
                // can only obtain a `*Db` for THIS pool from `acquireReader`/`openReader`, so a
                // mismatch is a logic bug; assert it in safe builds.
                std.debug.assert(std.meta.activeTag(reader.*) == tag);
                p.releaseReader(&@field(reader.*, @tagName(tag)));
            },
        }
    }
    pub fn openReader(self: *Pool) DbError!Db {
        switch (self.impl) {
            inline else => |*p, tag| return @unionInit(Db, @tagName(tag), try p.openReader()),
        }
    }
} else sqlite.Pool;

// ===========================================================================
// Cross-cutting accessors (work for BOTH the bare-SQLite alias and the union/struct forms)
//
// These exist because a tagged union cannot expose a payload field (`pool.field_cipher`) or a
// SQLite-specific handle directly. Each is `inline` and comptime-branches on the Postgres gate,
// so in the default build it folds to the exact same direct field access the call sites used
// before — preserving byte-identity — while compiling against the union/struct forms when
// Postgres is on.
// ===========================================================================

/// Read a pool's stamped field-encryption cipher pointer (or null). Replaces `pool.field_cipher`.
pub inline fn poolFieldCipher(pool: *const Pool) ?*const anyopaque {
    if (build_options.postgres) {
        switch (pool.impl) {
            inline else => |*p| return p.field_cipher,
        }
    } else {
        return pool.field_cipher;
    }
}

/// Stamp a pool's field-encryption cipher pointer. Replaces `pool.field_cipher = v`.
pub inline fn poolSetFieldCipher(pool: *Pool, v: ?*const anyopaque) void {
    if (build_options.postgres) {
        switch (pool.impl) {
            inline else => |*p| p.field_cipher = v,
        }
    } else {
        pool.field_cipher = v;
    }
}

/// Stamp a `Db`'s field-encryption cipher pointer. Replaces `d.field_cipher = v`.
pub inline fn dbSetFieldCipher(d: *Db, v: ?*const anyopaque) void {
    if (build_options.postgres) {
        switch (d.*) {
            inline else => |*x| x.field_cipher = v,
        }
    } else {
        d.field_cipher = v;
    }
}

/// Read a `Stmt`'s field-encryption cipher pointer (or null). Replaces `stmt.field_cipher`.
pub inline fn stmtFieldCipher(s: *const Stmt) ?*const anyopaque {
    if (build_options.postgres) {
        switch (s.*) {
            inline else => |*x| return x.field_cipher,
        }
    } else {
        return s.field_cipher;
    }
}

/// The SQLite connection handle behind a `Db`. Only valid on a SQLite-backed `Db`; used by the
/// dev-mode SQL-shadow tests, which are inherently SQLite-specific.
pub inline fn sqliteHandle(d: *Db) *@import("c.zig").c.sqlite3 {
    if (build_options.postgres) return d.sqlite.handle else return d.handle;
}

/// The number of warm connections currently parked in a pool's reader free-list. Both backends
/// expose `reader_count`; used by tests that assert warm-pool reuse. Replaces `pool.reader_count`.
pub inline fn poolReaderCount(pool: *const Pool) usize {
    if (build_options.postgres) {
        switch (pool.impl) {
            inline else => |*p| return p.reader_count,
        }
    } else {
        return pool.reader_count;
    }
}

/// The active backend of a pool.
pub inline fn poolBackend(pool: *const Pool) Backend {
    if (build_options.postgres) return std.meta.activeTag(pool.impl) else return .sqlite;
}

/// The SQL `Dialect` for a pool's active backend. The rest of the stack reaches the active
/// dialect through this (PR-2/PR-3 thread it into the DDL / query producers).
pub inline fn poolDialect(pool: *const Pool) Dialect {
    return Dialect.forKind(switch (poolBackend(pool)) {
        .sqlite => .sqlite,
        .postgres => .postgres,
    });
}

/// The active backend of a live `Db` handle. Mirrors `poolBackend` for the per-connection
/// handle the DDL / migration / collection layers hold. In the default build (`Db == sqlite.Db`)
/// this is always `.sqlite`; the union switch is only compiled when Postgres is built in.
pub inline fn dbBackend(d: *const Db) Backend {
    if (build_options.postgres) return std.meta.activeTag(d.*) else return .sqlite;
}

/// The SQL `Dialect` for a live `Db` handle's backend. The schema/DDL/migration/provision layers
/// (#169) AND the record CRUD/query `$n`/`now()`/`ILIKE`/`NULLS …` producers (#170, PR-3) reach the
/// active dialect through this so the SAME code emits backend-correct SQL on both. Always `.sqlite`
/// in the default build (folds to a constant; the Postgres branches are dead code).
pub inline fn dbDialect(d: *const Db) Dialect {
    return Dialect.forKind(switch (dbBackend(d)) {
        .sqlite => .sqlite,
        .postgres => .postgres,
    });
}

// ---- LISTEN/NOTIFY seam (#159, PR-6b cross-instance realtime) ---------------
// Postgres async notifications, exposed through the union seam so the realtime bridge never
// names a backend type. SQLite is single-process — every helper is a comptime no-op there, so
// the default build links zero new behavior and the realtime in-process hub is unchanged.

/// An async LISTEN/NOTIFY notification. On Postgres this aliases the driver's type; in the
/// default (SQLite) build it is a structurally-identical stand-in so callers compile uniformly
/// (the helpers below only ever return one on a Postgres-backed `Db`).
pub const Notification = if (build_options.postgres) pg.Db.Notification else struct {
    pid: i32,
    channel: []const u8,
    payload: []const u8,
};

/// `LISTEN "<channel>"` on a Postgres `Db`. No-op on SQLite (in-process delivery only).
pub inline fn dbListen(d: *Db, channel: []const u8) DbError!void {
    if (build_options.postgres) switch (d.*) {
        .postgres => |*x| return x.listen(channel),
        .sqlite => {},
    };
}

/// `NOTIFY <channel>, '<payload>'` (via `pg_notify`) on a Postgres `Db`. No-op on SQLite.
pub inline fn dbNotify(d: *Db, arena: std.mem.Allocator, channel: []const u8, payload: []const u8) DbError!void {
    if (build_options.postgres) switch (d.*) {
        .postgres => |*x| return x.notify(arena, channel, payload),
        .sqlite => {},
    };
}

/// Block for the next async notification on a Postgres `Db` (copied into `arena`); null if the
/// next wire message was not a notification. Always null on SQLite.
pub inline fn dbWaitNotification(d: *Db, arena: std.mem.Allocator) DbError!?Notification {
    if (build_options.postgres) switch (d.*) {
        .postgres => |*x| return x.waitNotification(arena),
        .sqlite => return null,
    };
    return null;
}

// ---- Test discovery --------------------------------------------------------
// Pull in the relocated SQLite backend's tests + the dialect tests. The Postgres
// seam-smoke lives in backend/seam_test.zig, referenced from root.zig only under
// the `-Dpostgres` gate.
test {
    _ = @import("backend/sqlite/db.zig");
    _ = @import("sql/dialect.zig");
}

test "seam: a SQLite pool reports the sqlite backend + dialect" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/sel.db", .{dir_path}, 0);
    defer std.testing.allocator.free(db_path);

    var pool = try Pool.init(std.testing.allocator, std.testing.io, db_path);
    defer pool.deinit();
    try std.testing.expectEqual(Backend.sqlite, poolBackend(&pool));
    try std.testing.expectEqual(DialectKind.sqlite, poolDialect(&pool).kind);
}

test "seam: connstr routing selects the backend (no live PG needed)" {
    // A file path / :memory: is SQLite; a postgres:// URI routes to the PG arm. This asserts
    // the selection predicate the pool keys on, without opening a connection.
    try std.testing.expect(!connstrLooksLikePostgres("/var/data/data.db"));
    try std.testing.expect(!connstrLooksLikePostgres(":memory:"));
    try std.testing.expect(connstrLooksLikePostgres("postgres://localhost/db"));
    try std.testing.expect(connstrLooksLikePostgres("postgresql://h:5432/db"));
    // M-2: the scheme is matched case-insensitively, so a mixed-case PG URL is recognized
    // (and thus routed/warned correctly) instead of falling through to a confusing SQLite open.
    try std.testing.expect(connstrLooksLikePostgres("POSTGRES://h/db"));
    try std.testing.expect(connstrLooksLikePostgres("PostgreSQL://h/db"));
    // A scheme that merely starts with "postgres" but isn't exactly the PG scheme is NOT PG.
    try std.testing.expect(!connstrLooksLikePostgres("postgresx://h/db"));
}

/// Backend-neutral connection-string classifier (mirrors the predicate `Pool.initOpts` keys on).
/// Lives here so the routing test runs in the default build too (the real `connstr` module is
/// Postgres-gated). The scheme is compared case-insensitively (M-2): `POSTGRES://…` is as valid
/// a PG URL as `postgres://…`, so a mixed-case URL is recognized (and routed/warned) rather than
/// falling through to a confusing SQLite `OpenFailed`.
pub fn connstrLooksLikePostgres(s: []const u8) bool {
    const sep = std.mem.indexOf(u8, s, "://") orelse return false;
    const scheme = s[0..sep];
    return std.ascii.eqlIgnoreCase(scheme, "postgres") or std.ascii.eqlIgnoreCase(scheme, "postgresql");
}

/// The backend a connection-string config resolves to. `postgres_url_without_build` is the
/// fail-loud case (I-1): a `postgres://` URL in a binary built WITHOUT `-Dpostgres` — the
/// selector logs a warning and falls back to SQLite rather than silently misdirecting writes.
pub const BackendChoice = enum { sqlite, postgres, postgres_url_without_build };

/// Classify a `ZIGBASE_DB_URL` value into the backend to use. A `postgres://` URL maps to
/// `.postgres` only when Postgres is compiled in; otherwise to `.postgres_url_without_build`
/// (warn + SQLite fallback). Anything else (a file path, `:memory:`, or no URL) is `.sqlite` —
/// the default SQLite data path, unchanged.
pub fn chooseBackend(db_url: ?[]const u8) BackendChoice {
    if (db_url) |u| {
        if (connstrLooksLikePostgres(u)) {
            return if (build_options.postgres) .postgres else .postgres_url_without_build;
        }
    }
    return .sqlite;
}

test "I-1: chooseBackend never silently misdirects a postgres:// URL to SQLite" {
    // SQLite data path is unchanged: a file path / :memory: / no URL always selects SQLite.
    try std.testing.expectEqual(BackendChoice.sqlite, chooseBackend(null));
    try std.testing.expectEqual(BackendChoice.sqlite, chooseBackend("/var/data/data.db"));
    try std.testing.expectEqual(BackendChoice.sqlite, chooseBackend(":memory:"));
    // A postgres:// URL is NEVER classified as plain .sqlite — it either opens PG (pg build) or
    // trips the loud warn-and-fallback path (non-pg build). Either way, no silent misdirection.
    const pg_choice = chooseBackend("postgres://h:5432/db");
    try std.testing.expect(pg_choice != .sqlite);
    if (build_options.postgres) {
        try std.testing.expectEqual(BackendChoice.postgres, pg_choice);
    } else {
        try std.testing.expectEqual(BackendChoice.postgres_url_without_build, pg_choice);
    }
}
