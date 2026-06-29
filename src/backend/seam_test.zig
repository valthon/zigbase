//! End-to-end seam smoke (issue #159, PR-1b). Proves the runtime-selectable tagged-union
//! `db.Db`/`db.Stmt`/`db.Pool` dispatches to the Postgres backend correctly — i.e. that a
//! `postgres://` target opens the PG arm and a trivial exec/prepare/step/tx round-trip works
//! THROUGH the abstraction (not the driver directly). This is NOT CRUD/migration parity (that
//! is PR-2/PR-3); it only validates the seam.
//!
//! Compiled only under `-Dpostgres=true` (referenced from `root.zig`'s gated test block). Like
//! the driver's live tests, it reads `ZIGBASE_PG_TEST_URL` and SKIPS when no PostgreSQL is
//! reachable, so the suite still runs where no PG exists; CI's `postgres` job sets the env var.

const std = @import("std");
const db = @import("../db.zig");

/// Read an environment variable via libc's `environ`.
fn getEnv(key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (e.len > key.len and std.mem.startsWith(u8, e, key) and e[key.len] == '=')
            return e[key.len + 1 ..];
    }
    return null;
}

/// The PG test URL, or null to skip (no configured/reachable server).
fn testUrlZ(a: std.mem.Allocator) !?[:0]const u8 {
    const url = getEnv("ZIGBASE_PG_TEST_URL") orelse return null;
    return try a.dupeZ(u8, url);
}

test "seam: db.Pool routes a postgres:// target to the PG backend and round-trips through db.Db" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const url = (try testUrlZ(a)) orelse return error.SkipZigTest;
    defer a.free(url);

    var pool = db.Pool.init(a, io, url) catch return error.SkipZigTest;
    defer pool.deinit();

    // The selection landed on the Postgres arm, and the dialect follows the backend.
    try std.testing.expectEqual(db.Backend.postgres, db.poolBackend(&pool));
    try std.testing.expectEqual(db.DialectKind.postgres, db.poolDialect(&pool).kind);

    // Writer round-trip THROUGH the union Db: DDL + prepared $n insert + changesCount.
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try w.exec("CREATE TEMP TABLE zb_seam (id bigint, name text);");
        var ins = try w.prepare("INSERT INTO zb_seam (id, name) VALUES ($1, $2);");
        defer ins.finalize();
        try ins.bindInt(1, 7);
        try ins.bindText(2, "ada");
        try std.testing.expect(!try ins.step());
        try std.testing.expectEqual(@as(i64, 1), w.changesCount());

        // Read it back on the SAME (writer) connection so the TEMP table is visible.
        var sel = try w.prepare("SELECT id, name FROM zb_seam WHERE id = $1;");
        defer sel.finalize();
        try sel.bindInt(1, 7);
        try std.testing.expect(try sel.step());
        try std.testing.expectEqual(@as(i64, 7), sel.columnInt(0));
        try std.testing.expectEqualStrings("ada", sel.columnText(1));
        // Column types map through the unified db.Stmt.ColumnType while the row is current.
        try std.testing.expectEqual(db.Stmt.ColumnType.Integer, sel.columnType(0));
        try std.testing.expectEqual(db.Stmt.ColumnType.Text, sel.columnType(1));
        try std.testing.expect(!try sel.step());
    }
}

test "seam: transaction commit/rollback through db.Db (PG arm)" {
    const a = std.testing.allocator;
    const url = (try testUrlZ(a)) orelse return error.SkipZigTest;
    defer a.free(url);

    var conn = db.Db.openPostgres(a, std.testing.io, url) catch return error.SkipZigTest;
    defer conn.close();

    try conn.exec("CREATE TEMP TABLE zb_seam_tx (id bigint);");

    try conn.begin();
    try conn.exec("INSERT INTO zb_seam_tx (id) VALUES (1);");
    try conn.commit();

    try conn.begin();
    try conn.exec("INSERT INTO zb_seam_tx (id) VALUES (2);");
    try conn.rollback();

    var sel = try conn.prepare("SELECT count(*) FROM zb_seam_tx;");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 1), sel.columnInt(0)); // only the committed row
}

test "seam: pool reader round-trips through db.Db (PG arm)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const url = (try testUrlZ(a)) orelse return error.SkipZigTest;
    defer a.free(url);

    var pool = db.Pool.init(a, io, url) catch return error.SkipZigTest;
    defer pool.deinit();

    var r = try pool.acquireReader();
    defer pool.releaseReader(&r);
    var st = try r.prepare("SELECT 1;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
}
