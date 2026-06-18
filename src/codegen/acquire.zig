const std = @import("std");
const schema = @import("../schema.zig");

/// Source-agnostic representation of one `_collections` row / one
/// `GET /api/collections` array element. Both acquisition adapters populate
/// this and call buildCollection, so the paths converge on identical values.
pub const RawRow = struct {
    name: []const u8,
    type_str: []const u8, // "base" | "auth" | "view"
    schema_json: []const u8, // JSON array of field objects
    indexes_json: []const u8, // JSON array of index objects ("[]" if none)
    options_json: []const u8, // JSON object ("{}" if none)
};

/// True if `name` is one of the framework's injected auth system fields. The
/// server stores these in an auth collection's schema, but the emitter
/// re-synthesizes the visible ones — so the adapter strips them back to the
/// user-defined set. Referencing authSystemFields() keeps this in lockstep
/// with the framework if the injected set ever changes.
pub fn isAuthSystemField(name: []const u8) bool {
    for (schema.authSystemFields()) |f| {
        if (std.mem.eql(u8, name, f.name)) return true;
    }
    return false;
}

/// Build a schema.Collection from raw JSON strings using the engine's own
/// parsers. Rules and collection-level options are intentionally left at their
/// defaults: src/codegen/* never reads them, so they do not affect output.
pub fn buildCollection(alloc: std.mem.Allocator, row: RawRow) !schema.Collection {
    const ctype = std.meta.stringToEnum(schema.CollectionType, row.type_str) orelse .base;
    const all_fields = try schema.fieldsFromJson(alloc, row.schema_json);
    const indexes = try schema.indexesFromJson(alloc, row.indexes_json);
    const options = try schema.optionsFromJson(alloc, row.options_json);

    const fields: []const schema.Field = if (ctype == .auth) blk: {
        var kept: std.ArrayList(schema.Field) = .empty;
        for (all_fields) |f| {
            if (!isAuthSystemField(f.name)) try kept.append(alloc, f);
        }
        break :blk try kept.toOwnedSlice(alloc);
    } else all_fields;

    return .{
        .id = "",
        .name = try alloc.dupe(u8, row.name),
        .type = ctype,
        .fields = fields,
        .indexes = indexes,
        .options = options,
    };
}

fn lessByName(_: void, a: schema.Collection, b: schema.Collection) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Sort by name for output determinism independent of provisioning order
/// (provision.applySpecs inserts in topological order, not declaration order).
pub fn sortByName(cols: []schema.Collection) void {
    std.mem.sort(schema.Collection, cols, {}, lessByName);
}

test "buildCollection: base collection keeps user fields and parses types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const row = RawRow{
        .name = "posts",
        .type_str = "base",
        .schema_json =
        \\[{"id":"f1","name":"title","type":"text","options":{}},
        \\ {"id":"f2","name":"views","type":"number","options":{"mode":"int"}}]
        ,
        .indexes_json = "[]",
        .options_json = "{}",
    };
    const c = try buildCollection(a, row);
    try std.testing.expectEqualStrings("posts", c.name);
    try std.testing.expectEqual(schema.CollectionType.base, c.type);
    try std.testing.expectEqual(@as(usize, 2), c.fields.len);
    try std.testing.expectEqualStrings("title", c.fields[0].name);
    try std.testing.expectEqual(schema.FieldType.text, c.fields[0].fieldType());
    try std.testing.expectEqual(schema.FieldType.number, c.fields[1].fieldType());
}

test "buildCollection: auth collection strips injected system fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Simulates a stored auth schema: server-injected system fields + one user field.
    const row = RawRow{
        .name = "users",
        .type_str = "auth",
        .schema_json =
        \\[{"id":"_email","name":"email","type":"email","options":{}},
        \\ {"id":"_username","name":"username","type":"text","options":{}},
        \\ {"id":"_pwhash","name":"passwordHash","type":"text","options":{}},
        \\ {"id":"_tokkey","name":"tokenKey","type":"text","options":{}},
        \\ {"id":"_verified","name":"verified","type":"bool","options":{}},
        \\ {"id":"u1","name":"displayName","type":"text","options":{}}]
        ,
        .indexes_json = "[]",
        .options_json = "{}",
    };
    const c = try buildCollection(a, row);
    try std.testing.expectEqual(schema.CollectionType.auth, c.type);
    // Only the user field survives; all five authSystemFields() names are stripped.
    try std.testing.expectEqual(@as(usize, 1), c.fields.len);
    try std.testing.expectEqualStrings("displayName", c.fields[0].name);
}

test "sortByName orders collections by name" {
    var cols = [_]schema.Collection{
        .{ .id = "", .name = "zebra", .fields = &.{} },
        .{ .id = "", .name = "alpha", .fields = &.{} },
    };
    sortByName(&cols);
    try std.testing.expectEqualStrings("alpha", cols[0].name);
    try std.testing.expectEqualStrings("zebra", cols[1].name);
}
