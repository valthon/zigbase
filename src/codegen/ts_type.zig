//! Field → TypeScript type-string mapper. The single helper every emit fn reuses.
const std = @import("std");
const schema = @import("../schema.zig");
const ident = @import("identifiers.zig");

pub const TsKind = enum { string, number, boolean, unknown, select_union, relation_id, file_name };

/// The TS *kind* of a field, ignoring multiplicity. Drives guards + emit branching.
pub fn kindOf(f: schema.Field) TsKind {
    return switch (f.options) {
        .text, .email, .url, .editor, .date, .autodate => .string,
        .number => .number,
        .bool => .boolean,
        .json => .unknown,
        .select => .select_union,
        .relation => .relation_id,
        .file => .file_name,
    };
}

/// The emitted union *type name* for a select field, e.g. ("posts","status") -> "PostStatus".
/// `<RecordName><FieldPascal>`. RecordName mirrors identifiers.recordName.
pub fn selectUnionName(alloc: std.mem.Allocator, col_name: []const u8, field_name: []const u8) ![]const u8 {
    const rec = try ident.recordName(alloc, col_name);
    const fp = try ident.pascal(alloc, field_name);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ rec, fp });
}

/// The scalar (element) TS type of a field — the operand domain for where/fields.
pub fn tsBaseTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    return switch (kindOf(f)) {
        .string, .relation_id, .file_name => "string",
        .number => "number",
        .boolean => "boolean",
        .unknown => "unknown",
        .select_union => try selectUnionName(alloc, col_name, f.name),
    };
}

/// The record/value TS type of a field — `[]` appended when the field is multi-value.
pub fn tsTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    const base = try tsBaseTypeOf(alloc, col_name, f);
    if (f.isMultiValue()) return std.fmt.allocPrint(alloc, "{s}[]", .{base});
    return base;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn fieldT(comptime opts: schema.FieldOptions) schema.Field {
    return .{ .id = "x", .name = "f", .options = opts };
}

test "scalar field types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("string", try tsTypeOf(a, "posts", fieldT(.{ .text = .{} })));
    try std.testing.expectEqualStrings("string", try tsTypeOf(a, "posts", fieldT(.{ .email = .{} })));
    try std.testing.expectEqualStrings("string", try tsTypeOf(a, "posts", fieldT(.{ .url = .{} })));
    try std.testing.expectEqualStrings("string", try tsTypeOf(a, "posts", fieldT(.{ .editor = .{} })));
    try std.testing.expectEqualStrings("number", try tsTypeOf(a, "posts", fieldT(.{ .number = .{} })));
    try std.testing.expectEqualStrings("boolean", try tsTypeOf(a, "posts", fieldT(.{ .bool = .{} })));
    try std.testing.expectEqualStrings("string", try tsTypeOf(a, "posts", fieldT(.{ .date = .{} })));
    try std.testing.expectEqualStrings("string", try tsTypeOf(a, "posts", fieldT(.{ .autodate = .{} })));
    try std.testing.expectEqualStrings("unknown", try tsTypeOf(a, "posts", fieldT(.{ .json = .{} })));
}

test "select field -> named union; multi -> array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const single = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } };
    const multi = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "a", "b" }, .maxSelect = 3 } } };
    try std.testing.expectEqualStrings("PostStatus", try tsTypeOf(a, "posts", single));
    try std.testing.expectEqualStrings("PostStatus[]", try tsTypeOf(a, "posts", multi));
    // base (element) type drops the [] for where/fields operands
    try std.testing.expectEqualStrings("PostStatus", try tsBaseTypeOf(a, "posts", multi));
}

test "relation -> id string; multi -> string[]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const single = schema.Field{ .id = "x", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } };
    const multi = schema.Field{ .id = "x", .name = "tags", .options = .{ .relation = .{ .targetCollectionId = "tags", .maxSelect = 99 } } };
    try std.testing.expectEqualStrings("string", try tsTypeOf(a, "posts", single));
    try std.testing.expectEqualStrings("string[]", try tsTypeOf(a, "posts", multi));
}

test "file -> filename string; multi -> string[]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const single = schema.Field{ .id = "x", .name = "cover", .options = .{ .file = .{ .maxSelect = 1 } } };
    const multi = schema.Field{ .id = "x", .name = "gallery", .options = .{ .file = .{ .maxSelect = 9 } } };
    try std.testing.expectEqualStrings("string", try tsTypeOf(a, "posts", single));
    try std.testing.expectEqualStrings("string[]", try tsTypeOf(a, "posts", multi));
}

test "kindOf branches" {
    try std.testing.expectEqual(TsKind.string, kindOf(fieldT(.{ .text = .{} })));
    try std.testing.expectEqual(TsKind.number, kindOf(fieldT(.{ .number = .{} })));
    try std.testing.expectEqual(TsKind.boolean, kindOf(fieldT(.{ .bool = .{} })));
    try std.testing.expectEqual(TsKind.unknown, kindOf(fieldT(.{ .json = .{} })));
    try std.testing.expectEqual(TsKind.select_union, kindOf(.{ .id = "x", .name = "s", .options = .{ .select = .{ .values = &.{"a"} } } }));
    try std.testing.expectEqual(TsKind.relation_id, kindOf(.{ .id = "x", .name = "r", .options = .{ .relation = .{ .targetCollectionId = "t" } } }));
    try std.testing.expectEqual(TsKind.file_name, kindOf(fieldT(.{ .file = .{} })));
}
