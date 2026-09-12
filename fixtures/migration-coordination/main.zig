//! Real-process fixture for cooperative consumer migration batch locking.
const std = @import("std");
const zigbase = @import("zigbase");

fn seed(m: *zigbase.Migrator) !void {
    try m.exec("CREATE TABLE IF NOT EXISTS coordination_control (hold INTEGER, fail INTEGER);");
    try m.exec("CREATE TABLE coordination_events (direction INTEGER);");
}

fn pause(m: *zigbase.Migrator, direction: i64) !void {
    var insert = try m.prepare("INSERT INTO coordination_events VALUES (?1);");
    defer insert.finalize();
    try insert.bindInt(1, direction);
    _ = try insert.step();
    // A deterministic parent-controlled gate, with a bounded escape if the test dies.
    for (0..1000) |_| {
        const held = blk: {
            var st = try m.prepare("SELECT hold, fail FROM coordination_control;");
            defer st.finalize();
            if (!try st.step()) break :blk false;
            if (st.columnInt(1) != 0) return error.CoordinationFixtureFailure;
            break :blk st.columnInt(0) != 0;
        };
        if (!held) return;
        try m.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake);
    }
    return error.CoordinationFixtureTimeout;
}

fn up(m: *zigbase.Migrator) !void {
    try pause(m, 1);
}

fn down(m: *zigbase.Migrator) !void {
    try pause(m, -1);
}

fn transactionalPause(m: *zigbase.Migrator) !void {
    try m.exec("INSERT INTO coordination_events VALUES (1);");
    // Unlike the SQL-controlled nontransactional gate, this remains observable
    // while the callback owns SQLite's writer transaction.
    try std.Io.Dir.cwd().writeFile(m.io, .{ .sub_path = "entered", .data = "" });
    for (0..2000) |_| {
        std.Io.Dir.cwd().access(m.io, "release", .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try m.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake);
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.CoordinationFixtureTimeout;
}

pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get("ZIGBASE_TEST_TRANSACTIONAL") != null) {
        return zigbase.App(.{ .migrations = &[_]zigbase.Migration{
            .{ .id = "coordination_seed", .up = seed },
            .{ .id = "coordination_transactional", .up = transactionalPause, .down = transactionalPause },
        } }).runCli(init);
    }
    try zigbase.App(.{ .migrations = &[_]zigbase.Migration{
        .{ .id = "coordination_seed", .up = seed },
        .{ .id = "coordination_pause", .up = up, .down = down, .transactional = false },
    } }).runCli(init);
}
