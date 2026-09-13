//! Subprocess-only fault injection: cleanup failure must never return a writer.
const std = @import("std");
const zigbase = @import("zigbase");
const db = zigbase.internal.db;

extern "c" fn sqlite3_set_authorizer(?*anyopaque, ?*const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int, ?*anyopaque) c_int;

// Avoid core dumps in CI while retaining an observable, terminal panic path.
pub const panic = std.debug.FullPanic(struct {
    fn fail(message: []const u8, _: ?usize) noreturn {
        std.debug.print("{s}\n", .{message});
        std.process.exit(86);
    }
}.fail);

const Fault = enum { transaction, rollback_savepoint, release_savepoint, normal, nested_normal };
fn authorize(context: ?*anyopaque, action: c_int, first: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8) callconv(.c) c_int {
    const fault: *const Fault = @ptrCast(@alignCast(context.?));
    const operation = std.mem.span(first orelse return 0);
    // SQLite's stable public authorizer action codes: TRANSACTION=22, SAVEPOINT=32.
    const deny = switch (fault.*) {
        .transaction => action == 22 and std.mem.eql(u8, operation, "ROLLBACK"),
        .rollback_savepoint => action == 32 and std.mem.eql(u8, operation, "ROLLBACK"),
        .release_savepoint => action == 32 and std.mem.eql(u8, operation, "RELEASE"),
        .normal, .nested_normal => false,
    };
    return if (deny) 1 else 0; // SQLITE_DENY / SQLITE_OK
}

pub fn main(init: std.process.Init) !void {
    const fault = std.meta.stringToEnum(Fault, init.environ_map.get("ZIGBASE_ROLLBACK_FAULT") orelse return error.MissingFault) orelse return error.InvalidFault;
    var conn = try zigbase.Db.openMemory();
    defer conn.close();
    try zigbase.internal.migrations.run(&conn);
    const a = init.arena.allocator();
    _ = try zigbase.internal.collections.create(a, init.io, &conn, .{ .id = "", .name = "posts", .fields = &.{} });
    try conn.exec("CREATE TABLE probe(id INTEGER); CREATE TRIGGER deny_rename BEFORE UPDATE OF generation ON _schema_state WHEN NEW.generation<>OLD.generation BEGIN SELECT RAISE(ABORT,'injected'); END;");
    const nested = fault != .transaction and fault != .normal;
    if (nested) {
        try conn.begin();
        try conn.exec("INSERT INTO probe VALUES (1);");
    }
    if (sqlite3_set_authorizer(db.sqliteHandle(&conn), authorize, @constCast(&fault)) != 0) return error.AuthorizerFailed;
    var m = zigbase.Migrator{ .db = &conn, .dialect = db.dbDialect(&conn), .arena = a, .io = init.io };
    m.renameCollection("posts", "articles", .{ .offline = true }) catch |err| {
        if (err != error.ExecFailed) return err;
        if (fault != .normal and fault != .nested_normal) {
            // Any catchable return is unsafe, even if it uses a new error name.
            try conn.exec("INSERT INTO probe VALUES (2);");
            return error.UnsafeWriterReused;
        }
        if (sqlite3_set_authorizer(db.sqliteHandle(&conn), null, null) != 0) return error.AuthorizerFailed;
        if (conn.inTransaction() != nested) return error.WrongTransactionOwnership;
        if ((try zigbase.internal.collections.getByName(a, &conn, "posts")) == null or
            (try zigbase.internal.collections.getByName(a, &conn, "articles")) != null) return error.RollbackDidNotRestoreSchema;
        if (nested) {
            var st = try conn.prepare("SELECT count(*) FROM probe;");
            defer st.finalize();
            if (!try st.step() or st.columnInt(0) != 1) return error.CallerWorkLost;
        }
        if (nested) try conn.rollback();
        return;
    };
    return error.ExpectedRenameFailure;
}
