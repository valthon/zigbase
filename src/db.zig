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

pub const DbError = error{ OpenFailed, ExecFailed, PrepareFailed, BindFailed, StepFailed };

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

    var ins = try db.prepare("INSERT INTO t (id, name) VALUES (?1, ?2);");
    try ins.bindInt(1, 42);
    try ins.bindText(2, "ada");
    try std.testing.expect((try ins.step()) == false); // INSERT yields no row
    ins.finalize();

    var sel = try db.prepare("SELECT id, name FROM t WHERE id = ?1;");
    try sel.bindInt(1, 42);
    try std.testing.expect((try sel.step()) == true);
    try std.testing.expectEqual(@as(i64, 42), sel.columnInt(0));
    try std.testing.expectEqualStrings("ada", sel.columnText(1));
    try std.testing.expect((try sel.step()) == false);
    sel.finalize();
}
