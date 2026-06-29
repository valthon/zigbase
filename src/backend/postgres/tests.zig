//! Live integration tests for the pure-Zig PostgreSQL driver. These run only under
//! `-Dpostgres=true` (the whole subtree is comptime-gated off otherwise) and require a
//! reachable PostgreSQL.
//!
//! Connection string: `ZIGBASE_PG_TEST_URL` if set, else the local default below — which
//! targets `[::1]` so the stock Debian/Ubuntu `pg_hba.conf` forces `scram-sha-256`, and
//! uses `sslmode=require` to force TLS. A test that cannot connect SKIPS (so the suite is
//! still runnable where no PG exists) rather than failing; CI's `postgres` job sets the env
//! var against its service container so the tests actually execute there.

const std = @import("std");
const pg = @import("postgres.zig");

const default_url = "postgres://zbpg:zbpg_secret_pw@[::1]:5432/zbpgtest?sslmode=require";

/// Read an environment variable via libc's `environ` (linked into the module). Returns a
/// borrowed slice into the process environment, valid for the test's lifetime.
fn getEnv(key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (e.len > key.len and std.mem.startsWith(u8, e, key) and e[key.len] == '=')
            return e[key.len + 1 ..];
    }
    return null;
}

/// The connection URL: `ZIGBASE_PG_TEST_URL` if set, else the local default (which forces
/// SCRAM via [::1] and TLS via sslmode=require).
fn testUrl() []const u8 {
    return getEnv("ZIGBASE_PG_TEST_URL") orelse default_url;
}

/// True when running against the built-in default URL (no env override) — i.e. the URL is
/// known to use [::1] (SCRAM) + sslmode=require (TLS), so those assertions are valid.
fn usingDefaultUrl() bool {
    return getEnv("ZIGBASE_PG_TEST_URL") == null;
}

/// Connect, or return null to signal the caller should skip (no reachable PG).
fn connectOrSkip(a: std.mem.Allocator, io: std.Io) !?pg.Db {
    return pg.Db.open(a, io, testUrl()) catch null;
}

test "pg: connect over TLS + SCRAM and run a trivial SELECT" {
    const a = std.testing.allocator;
    var db = (try connectOrSkip(a, std.testing.io)) orelse return error.SkipZigTest;
    defer db.close();

    // The default URL connects over [::1] (pg_hba → scram-sha-256) with sslmode=require,
    // so reaching this point proves SCRAM-SHA-256 auth AND a TLS session succeeded.
    if (usingDefaultUrl()) try std.testing.expect(db.conn.using_tls);

    var st = try db.prepare("SELECT 1;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
    try std.testing.expect(!try st.step());
}

test "pg: DDL + prepared INSERT/SELECT with \\$n binds" {
    const a = std.testing.allocator;
    var db = (try connectOrSkip(a, std.testing.io)) orelse return error.SkipZigTest;
    defer db.close();

    try db.exec("CREATE TEMP TABLE t (id bigint, name text);");
    {
        var ins = try db.prepare("INSERT INTO t (id, name) VALUES ($1, $2);");
        defer ins.finalize();
        try ins.bindInt(1, 42);
        try ins.bindText(2, "ada");
        try std.testing.expect(!try ins.step()); // INSERT yields no row
        try std.testing.expectEqual(@as(i64, 1), db.changesCount());
    }

    var sel = try db.prepare("SELECT id, name FROM t WHERE id = $1;");
    defer sel.finalize();
    try sel.bindInt(1, 42);
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 42), sel.columnInt(0));
    try std.testing.expectEqualStrings("ada", sel.columnText(1));
    try std.testing.expect(!try sel.step());
}

test "pg: type round-trips (text/int/double/null/bool)" {
    const a = std.testing.allocator;
    var db = (try connectOrSkip(a, std.testing.io)) orelse return error.SkipZigTest;
    defer db.close();

    try db.exec("CREATE TEMP TABLE rt (i bigint, d double precision, s text, n text, b boolean);");
    {
        var ins = try db.prepare("INSERT INTO rt (i, d, s, n, b) VALUES ($1, $2, $3, $4, $5);");
        defer ins.finalize();
        try ins.bindInt(1, -9001);
        try ins.bindDouble(2, 2.5);
        try ins.bindText(3, "héllo");
        try ins.bindNull(4);
        try ins.bindText(5, "true");
        try std.testing.expect(!try ins.step());
    }

    var sel = try db.prepare("SELECT i, d, s, n, b FROM rt;");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, -9001), sel.columnInt(0));
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), sel.columnDouble(1), 0.0001);
    try std.testing.expectEqualStrings("héllo", sel.columnText(2));
    try std.testing.expect(sel.isNull(3));
    try std.testing.expectEqual(pg.ColumnType.Null, sel.columnType(3));
    // bool comes back in TEXT format as 't'/'f' (the dialect layer converts; PR-3).
    try std.testing.expectEqualStrings("t", sel.columnText(4));
    try std.testing.expectEqual(pg.ColumnType.Integer, sel.columnType(0));
    try std.testing.expectEqual(pg.ColumnType.Float, sel.columnType(1));
    try std.testing.expectEqual(pg.ColumnType.Text, sel.columnType(2));
}

test "pg: transaction commit and rollback" {
    const a = std.testing.allocator;
    var db = (try connectOrSkip(a, std.testing.io)) orelse return error.SkipZigTest;
    defer db.close();

    try db.exec("CREATE TEMP TABLE tx (id bigint);");

    try db.begin();
    try db.exec("INSERT INTO tx (id) VALUES (1);");
    try db.commit();

    try db.begin();
    try db.exec("INSERT INTO tx (id) VALUES (2);");
    try db.rollback();

    var sel = try db.prepare("SELECT count(*) FROM tx;");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 1), sel.columnInt(0)); // only the committed row
}

test "pg: reset re-executes a prepared statement with new bindings" {
    const a = std.testing.allocator;
    var db = (try connectOrSkip(a, std.testing.io)) orelse return error.SkipZigTest;
    defer db.close();

    var st = try db.prepare("SELECT $1::bigint + 1;");
    defer st.finalize();
    try st.bindInt(1, 10);
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 11), st.columnInt(0));

    st.reset();
    try st.bindInt(1, 100);
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 101), st.columnInt(0));
}

test "pg: pool acquire/release across threads" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var pool = pg.Pool.init(a, io, testUrl()) catch return error.SkipZigTest;
    defer pool.deinit();

    // Seed a shared table via the writer.
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try w.exec("CREATE TABLE IF NOT EXISTS pool_probe (n bigint);");
        try w.exec("TRUNCATE pool_probe;");
        try w.exec("INSERT INTO pool_probe (n) VALUES (7);");
    }
    defer {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        w.exec("DROP TABLE IF EXISTS pool_probe;") catch {};
    }

    const Worker = struct {
        fn run(p: *pg.Pool) void {
            var r = p.acquireReader() catch return;
            defer p.releaseReader(&r);
            var st = r.prepare("SELECT n FROM pool_probe;") catch return;
            defer st.finalize();
            _ = st.step() catch return;
            std.debug.assert(st.columnInt(0) == 7);
        }
    };

    var threads: [6]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&pool});
    for (threads) |t| t.join();

    // After the burst, the warm free-list should hold some parked connections (<= cap).
    try std.testing.expect(pool.reader_count <= pool.reader_cap);
}

test "pg: LISTEN/NOTIFY basic round-trip" {
    const a = std.testing.allocator;
    var db = (try connectOrSkip(a, std.testing.io)) orelse return error.SkipZigTest;
    defer db.close();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    try db.conn.listen("zb_test_chan");
    try db.conn.notify(arena.allocator(), "zb_test_chan", "hello");
    // Pump one more round-trip so the server flushes the self-notification; our query drain
    // captures the NotificationResponse into the in-memory queue. Then take it non-blocking
    // (never block the socket waiting for a notification that may have already arrived).
    try db.exec("SELECT 1;");
    const note = (try db.conn.takePending(arena.allocator())) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("zb_test_chan", note.channel);
    try std.testing.expectEqualStrings("hello", note.payload);

    // A channel that would break out of the double-quoted identifier is refused. (gemini#3.)
    try std.testing.expectError(error.InvalidIdentifier, db.conn.listen("evil\"; DROP TABLE x; --"));
}

test "pg: booleans read back through columnInt as 1/0 (I-5)" {
    const a = std.testing.allocator;
    var db = (try connectOrSkip(a, std.testing.io)) orelse return error.SkipZigTest;
    defer db.close();

    var sel = try db.prepare("SELECT true, false;");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    // columnType advertises bool as .Integer, so columnInt MUST decode the 't'/'f' TEXT form.
    try std.testing.expectEqual(pg.ColumnType.Integer, sel.columnType(0));
    try std.testing.expectEqual(@as(i64, 1), sel.columnInt(0)); // true  -> 1
    try std.testing.expectEqual(@as(i64, 0), sel.columnInt(1)); // false -> 0
    try std.testing.expectEqualStrings("t", sel.columnText(0));
    try std.testing.expectEqualStrings("f", sel.columnText(1));
}

test "pg: pool does not recycle a broken connection (I-2)" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var pool = pg.Pool.init(a, io, testUrl()) catch return error.SkipZigTest;
    defer pool.deinit();

    // Acquire a reader, then simulate a mid-query failure (server closed / desync) that left
    // the connection dead — exactly what `readMessage`/flush set via `Conn.broken`.
    var r = try pool.acquireReader();
    try std.testing.expect(r.conn.isHealthy());
    r.conn.broken = true;
    pool.releaseReader(&r); // a broken conn must be CLOSED, not parked

    try std.testing.expectEqual(@as(usize, 0), pool.reader_count);

    // The next acquire must hand back a fresh, healthy connection (not the poisoned one), and
    // it must actually work.
    var r2 = try pool.acquireReader();
    defer pool.releaseReader(&r2);
    try std.testing.expect(r2.conn.isHealthy());
    var st = try r2.prepare("SELECT 1;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
}
