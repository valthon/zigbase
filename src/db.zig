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
