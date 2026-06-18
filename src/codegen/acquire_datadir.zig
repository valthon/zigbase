const std = @import("std");
const schema = @import("../schema.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const provision = @import("../provision.zig");
const acquire_core = @import("acquire.zig");

/// Read all user (non-system) collections from an open db handle's
/// `_collections` table, name-sorted. The schema/indexes/options columns are
/// JSON text the engine wrote via fieldsToJson/indexesToJson/optionsToJson, so
/// they parse back through acquire_core.buildCollection.
pub fn acquireFromDb(alloc: std.mem.Allocator, w: *db.Db) ![]schema.Collection {
    var st = try w.prepare(
        \\SELECT name, type, schema, indexes, options
        \\ FROM "_collections" WHERE system = 0 ORDER BY name;
    );
    defer st.finalize();

    var list: std.ArrayList(schema.Collection) = .empty;
    while (try st.step()) {
        const row = acquire_core.RawRow{
            .name = try alloc.dupe(u8, st.columnText(0)),
            .type_str = try alloc.dupe(u8, st.columnText(1)),
            .schema_json = try alloc.dupe(u8, st.columnText(2)),
            .indexes_json = try alloc.dupe(u8, st.columnText(3)),
            .options_json = try alloc.dupe(u8, st.columnText(4)),
        };
        try list.append(alloc, try acquire_core.buildCollection(alloc, row));
    }
    const cols = try list.toOwnedSlice(alloc);
    acquire_core.sortByName(cols); // ORDER BY name already sorts, but keep adapters symmetric.
    return cols;
}

/// Open `<data_dir>/data.db` and acquire its collections. Errors if the data
/// dir has no provisioned `_collections` (start the server once first).
pub fn acquire(alloc: std.mem.Allocator, data_dir: []const u8) ![]schema.Collection {
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}/data.db", .{data_dir}, 0);
    var w = db.Db.open(path) catch |e| {
        std.log.err("typegen: cannot open '{s}': {s}", .{ path, @errorName(e) });
        return error.DataDirOpenFailed;
    };
    defer w.close();
    return acquireFromDb(alloc, &w) catch |e| {
        std.log.err("typegen: cannot read _collections from '{s}': {s} (has the server provisioned this data dir?)", .{ path, @errorName(e) });
        return error.DataDirReadFailed;
    };
}

test "acquireFromDb returns user collections (sorted, system excluded, auth stripped)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    const specs = [_]schema.Collection{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{
            .{ .id = "", .name = "displayName", .options = .{ .text = .{} } },
        } },
        .{ .id = "", .name = "articles", .fields = &.{
            .{ .id = "", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "", .name = "views", .options = .{ .number = .{ .mode = .int } } },
        } },
    };
    try provision.applySpecs(a, std.testing.io, &d, &specs);

    const cols = try acquireFromDb(a, &d);
    // _superusers (system) excluded; only the two user collections, name-sorted.
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("articles", cols[0].name);
    try std.testing.expectEqualStrings("users", cols[1].name);
    // Auth system fields stripped: users has only displayName.
    try std.testing.expectEqual(@as(usize, 1), cols[1].fields.len);
    try std.testing.expectEqualStrings("displayName", cols[1].fields[0].name);
    // Number mode preserved through the round-trip.
    try std.testing.expectEqual(schema.FieldType.number, cols[0].fields[1].fieldType());
}
