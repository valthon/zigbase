//! Offline consumer declarations, not an execution plan. Streams borrowed metadata
//! without allocations, configuration, database access or callback invocation.
const std = @import("std");
const Migration = @import("provision.zig").Migration;

pub fn write(migrations: []const Migration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("{\"protocol_version\":1,\"scope\":\"compiled-consumer-migrations\",\"items\":[");
    for (migrations, 0..) |m, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("{f}", .{std.json.fmt(.{
            .id = m.id,
            .transactional = m.transactional,
            .forward_callback = if (m.change != null) "change" else "up",
            .reverse_callback = if (m.down != null) "down" else if (m.change != null) "change" else "none",
            .rollback_declaration = if (m.down != null) "explicit_down" else if (m.change == null) "missing_reverse" else if (!m.transactional) "nontransactional_change_rejected" else "change_requires_runtime_verification",
        }, .{})});
    }
    try writer.writeAll("],\"unknown\":[\"pending_state\",\"sql\",\"effects\",\"runtime_reversibility\"],\"includes_system_migrations\":false}\n");
}

test "preview preserves order and callback declarations without executing callbacks" {
    const Sentinel = struct {
        fn callback(_: *@import("migrator.zig").Migrator) !void {
            @panic("preview must never invoke migration callbacks");
        }
    };
    const entries = [_]Migration{
        .{ .id = "z\"\n", .up = Sentinel.callback },
        .{ .id = "a", .change = Sentinel.callback },
        .{ .id = "b", .change = Sentinel.callback, .transactional = false },
        .{ .id = "c", .change = Sentinel.callback, .down = Sentinel.callback, .transactional = false },
        .{ .id = "d", .up = Sentinel.callback, .down = Sentinel.callback },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&entries, &out.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("items").?.array.items;
    const eligibility = [_][]const u8{ "missing_reverse", "change_requires_runtime_verification", "nontransactional_change_rejected", "explicit_down", "explicit_down" };
    for (items, entries, eligibility) |item, declared, expected| {
        try std.testing.expectEqualStrings(declared.id, item.object.get("id").?.string);
        try std.testing.expectEqual(declared.transactional, item.object.get("transactional").?.bool);
        try std.testing.expectEqualStrings(expected, item.object.get("rollback_declaration").?.string);
        try std.testing.expectEqualStrings(if (declared.change != null) "change" else "up", item.object.get("forward_callback").?.string);
        try std.testing.expectEqualStrings(if (declared.down != null) "down" else if (declared.change != null) "change" else "none", item.object.get("reverse_callback").?.string);
    }
}

test "preview handles empty declarations and propagates writer failure" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&.{}, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"items\":[]") != null);
    var tiny: [1]u8 = undefined;
    var failing = std.Io.Writer.fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, write(&.{}, &failing));
}
