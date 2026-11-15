//! Backend-neutral prepare for the mail subsystem's engine-owned statements.
//!
//! The mail modules write their SQL once, in SQLite form: `?N` placeholders and the server-`now`
//! expression `datetime('now')`. `prep` lowers that text for the connection's backend before
//! preparing it: SQLite gets it verbatim; PostgreSQL gets `$n` placeholders and the dialect's
//! ISO-8601 `now` text (`param_sink.lowerStmtZ`, the auth/queue/analytics precedent). Without it,
//! PostgreSQL rejected every suppression and bulk-send statement. `senders.zig` (#487) prepares through it too.

const std = @import("std");
const db = @import("../db.zig");
const param_sink = @import("../sql/param_sink.zig");

/// Stack scratch for one lowering (the intermediate copies plus the result). Matches
/// `queue/durable.zig`'s `prepareStatic`; the test below lowers every mail statement into it.
pub const scratch_len = 8192;

/// Lower `sql` for `dialect` into `scratch`. `error.OutOfMemory` means the statement outgrew
/// the scratch.
pub fn lower(scratch: *[scratch_len]u8, dialect: param_sink.Dialect, sql: [:0]const u8) param_sink.PrepareError![:0]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    return param_sink.lowerStmtZ(fba.allocator(), dialect, sql);
}

/// Lower + prepare one of the mail modules' constant statements for `conn`'s backend. The
/// statements live in each module's `stmts` struct; the lowered text lives in bounded stack
/// scratch (`Db.prepare` copies it), and one that does not fit fails as `PrepareFailed`, never
/// silently.
pub fn prep(conn: *db.Db, sql: [:0]const u8) db.DbError!db.Stmt {
    const dialect = db.dbDialect(conn);
    if (dialect.kind == .sqlite) return conn.prepare(sql);
    var scratch: [scratch_len]u8 = undefined;
    const lowered = lower(&scratch, dialect, sql) catch return db.DbError.PrepareFailed;
    return conn.prepare(lowered);
}

test "every mail statement lowers for PostgreSQL inside prep's scratch" {
    const modules = .{ @import("bulk.zig").stmts, @import("suppression.zig").stmts };
    var n: usize = 0;
    inline for (modules) |S| {
        inline for (@typeInfo(S).@"struct".decls) |d| {
            const sql: [:0]const u8 = @field(S, d.name);
            var scratch: [scratch_len]u8 = undefined;
            const out = try lower(&scratch, param_sink.Dialect.postgres, sql);
            // Fully lowered: no SQLite placeholder or `now` form survives.
            try std.testing.expect(std.mem.indexOf(u8, out, "?") == null);
            try std.testing.expect(std.mem.indexOf(u8, out, "datetime('now')") == null);
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 13), n);
}
