const std = @import("std");
const db = @import("db.zig");

pub const Migration = struct { name: []const u8, up: *const fn (w: *db.Db) db.DbError!void };

fn init_0001(w: *db.Db) db.DbError!void {
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_collections" (
        \\  "id" TEXT PRIMARY KEY, "name" TEXT UNIQUE NOT NULL, "type" TEXT NOT NULL DEFAULT 'base',
        \\  "system" INTEGER NOT NULL DEFAULT 0, "schema" TEXT NOT NULL DEFAULT '[]',
        \\  "indexes" TEXT NOT NULL DEFAULT '[]',
        \\  "listRule" TEXT, "viewRule" TEXT, "createRule" TEXT, "updateRule" TEXT, "deleteRule" TEXT,
        \\  "created" TEXT NOT NULL, "updated" TEXT NOT NULL
        \\);
    );
}

pub const all = [_]Migration{
    .{ .name = "0001_init", .up = init_0001 },
};

pub fn run(w: *db.Db) db.DbError!void {
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS "_migrations" (
        \\  "id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT UNIQUE NOT NULL, "applied_at" TEXT NOT NULL
        \\);
    );
    for (all) |m| {
        if (try isApplied(w, m.name)) continue;
        try w.begin();
        errdefer w.rollback() catch {};
        try m.up(w);
        try recordApplied(w, m.name);
        try w.commit();
    }
}

fn isApplied(w: *db.Db, name: []const u8) db.DbError!bool {
    var st = try w.prepare("SELECT 1 FROM \"_migrations\" WHERE \"name\" = ?1;");
    defer st.finalize();
    try st.bindText(1, name);
    return try st.step();
}

fn recordApplied(w: *db.Db, name: []const u8) db.DbError!void {
    var st = try w.prepare("INSERT INTO \"_migrations\" (\"name\", \"applied_at\") VALUES (?1, datetime('now'));");
    defer st.finalize();
    try st.bindText(1, name);
    _ = try st.step();
}

test "migrations apply once and are idempotent" {
    var d = try db.Db.openMemory();
    defer d.close();
    try run(&d);
    try run(&d);
    var st = try d.prepare("SELECT COUNT(*) FROM \"_migrations\";");
    defer st.finalize();
    try std.testing.expect((try st.step()));
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
    var c = try d.prepare("SELECT COUNT(*) FROM \"_collections\";");
    defer c.finalize();
    try std.testing.expect((try c.step()));
}
