//! Field → Dart type-string mapper. The Dart counterpart of ts_type.zig; the
//! single helper every emit_dart fragment reuses.
const std = @import("std");
const schema = @import("../schema.zig");
const ident = @import("identifiers.zig");

/// The Dart *kind* of a field, ignoring multiplicity. Drives emit branching and
/// coercion-helper selection. Unlike TS (which collapses int/fixed/float to
/// `number`), Dart distinguishes `int` from `double` so int-mode fields keep
/// full i64 precision through the decimal-string wire form.
pub const DartKind = enum {
    string,
    integer,
    double_,
    boolean,
    json,
    select_enum,
    relation_id,
    file_name,
};

pub fn kindOf(f: schema.Field) DartKind {
    return switch (f.options) {
        .text, .email, .url, .editor, .date, .autodate => .string,
        .number => switch (f.options.number.mode) {
            .int => .integer,
            .fixed => .double_,
            .float => .double_,
        },
        .bool => .boolean,
        .json => .json,
        .select => .select_enum,
        .relation => .relation_id,
        .file => .file_name,
    };
}

/// The generated Dart enum name for a select field, e.g. ("posts","status") ->
/// "PostStatus". Mirrors ts_type.selectUnionName (same PascalCase derivation).
pub fn selectEnumName(alloc: std.mem.Allocator, col_name: []const u8, field_name: []const u8) ![]const u8 {
    const rec = try ident.recordName(alloc, col_name);
    const fp = try ident.pascal(alloc, field_name);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ rec, fp });
}

/// The scalar (element) Dart type of a field — the value domain for a single
/// element. `[]` multiplicity and nullability are applied by the caller.
pub fn dartBaseTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    return switch (kindOf(f)) {
        .string, .relation_id, .file_name => "String",
        .integer => "int",
        .double_ => "double",
        .boolean => "bool",
        .json => "Object?",
        .select_enum => try selectEnumName(alloc, col_name, f.name),
    };
}

/// The Dart *record* type of a field, with multiplicity and nullability applied:
/// - multi-value  -> `List<Base>` (non-null; empty-list default on read)
/// - single select -> `Base?` (an unset select has no valid enum variant)
/// - single json    -> `Object?`
/// - everything else -> `Base` (non-null; empty/zero/false default on read)
pub fn dartRecordTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    const base = try dartBaseTypeOf(alloc, col_name, f);
    if (f.isMultiValue()) return std.fmt.allocPrint(alloc, "List<{s}>", .{base});
    return switch (kindOf(f)) {
        .select_enum => std.fmt.allocPrint(alloc, "{s}?", .{base}),
        .json => "Object?",
        else => base,
    };
}

/// The Dart FieldType enum member name for a field's kind (for the emitted
/// CollectionMeta). Mirrors the server field-type tag except `bool` -> `boolean`.
pub fn fieldTypeEnum(f: schema.Field) []const u8 {
    return switch (f.options) {
        .text => "text",
        .email => "email",
        .url => "url",
        .editor => "editor",
        .date => "date",
        .autodate => "autodate",
        .bool => "boolean",
        .number => "number",
        .json => "json",
        .select => "select",
        .relation => "relation",
        .file => "file",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn fieldT(comptime opts: schema.FieldOptions) schema.Field {
    return .{ .id = "x", .name = "f", .options = opts };
}

test "scalar record types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("String", try dartRecordTypeOf(a, "posts", fieldT(.{ .text = .{} })));
    try std.testing.expectEqualStrings("String", try dartRecordTypeOf(a, "posts", fieldT(.{ .date = .{} })));
    try std.testing.expectEqualStrings("double", try dartRecordTypeOf(a, "posts", fieldT(.{ .number = .{} })));
    try std.testing.expectEqualStrings("int", try dartRecordTypeOf(a, "posts", fieldT(.{ .number = .{ .mode = .int } })));
    try std.testing.expectEqualStrings("double", try dartRecordTypeOf(a, "posts", fieldT(.{ .number = .{ .mode = .fixed, .scale = 2 } })));
    try std.testing.expectEqualStrings("bool", try dartRecordTypeOf(a, "posts", fieldT(.{ .bool = .{} })));
    try std.testing.expectEqualStrings("Object?", try dartRecordTypeOf(a, "posts", fieldT(.{ .json = .{} })));
}

test "select record type is nullable enum; multi is a List" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const single = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } };
    const multi = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "a", "b" }, .maxSelect = 3 } } };
    try std.testing.expectEqualStrings("PostStatus?", try dartRecordTypeOf(a, "posts", single));
    try std.testing.expectEqualStrings("List<PostStatus>", try dartRecordTypeOf(a, "posts", multi));
    try std.testing.expectEqualStrings("PostStatus", try dartBaseTypeOf(a, "posts", multi));
}

test "relation / file record types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rel1 = schema.Field{ .id = "x", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } };
    const relN = schema.Field{ .id = "x", .name = "tags", .options = .{ .relation = .{ .targetCollectionId = "tags", .maxSelect = 9 } } };
    const file1 = schema.Field{ .id = "x", .name = "cover", .options = .{ .file = .{ .maxSelect = 1 } } };
    try std.testing.expectEqualStrings("String", try dartRecordTypeOf(a, "posts", rel1));
    try std.testing.expectEqualStrings("List<String>", try dartRecordTypeOf(a, "posts", relN));
    try std.testing.expectEqualStrings("String", try dartRecordTypeOf(a, "posts", file1));
}

test "fieldTypeEnum maps bool to boolean" {
    try std.testing.expectEqualStrings("boolean", fieldTypeEnum(fieldT(.{ .bool = .{} })));
    try std.testing.expectEqualStrings("number", fieldTypeEnum(fieldT(.{ .number = .{} })));
    try std.testing.expectEqualStrings("autodate", fieldTypeEnum(fieldT(.{ .autodate = .{} })));
}
