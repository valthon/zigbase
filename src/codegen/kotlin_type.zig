//! Field → Kotlin type-string mapper. The Kotlin counterpart of python_type.zig
//! (and dart_type.zig); the single helper every emit_kotlin fragment reuses.
const std = @import("std");
const schema = @import("../schema.zig");
const ident = @import("identifiers.zig");

/// The Kotlin *kind* of a field, ignoring multiplicity. Drives emit branching
/// and coercer-helper selection. Like Python/Dart (and unlike TS), int/fixed/
/// float stay distinct-ish kinds so int-mode fields keep full precision
/// through the decimal-string wire form — but fixed and float both map to the
/// same Kotlin `Double` type (the scale is applied only at encode/coerce
/// time, via `io.github.valthon.zigbase.typed.encodeFixed`).
pub const KtKind = enum {
    string,
    integer,
    double_,
    boolean,
    json,
    select_enum,
    relation_id,
    file_name,
};

pub fn kindOf(f: schema.Field) KtKind {
    return switch (f.options) {
        .text, .email, .url, .editor, .date, .autodate => .string,
        .number => switch (f.options.number.mode) {
            .int => .integer,
            .fixed, .float => .double_,
        },
        .bool => .boolean,
        .json => .json,
        .select => .select_enum,
        .relation => .relation_id,
        .file => .file_name,
    };
}

/// The generated Kotlin enum class name for a select field, e.g.
/// ("profiles","gender") -> "ProfileGender". Mirrors python_type.selectEnumName
/// (same PascalCase derivation via the shared identifiers module).
pub fn selectEnumName(alloc: std.mem.Allocator, col_name: []const u8, field_name: []const u8) ![]const u8 {
    const rec = try ident.recordName(alloc, col_name);
    const fp = try ident.pascal(alloc, field_name);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ rec, fp });
}

/// The scalar (element) Kotlin type of a field — the value domain for a
/// single element. `List<...>` multiplicity and nullability are applied by
/// the caller (ktRecordTypeOf / payload builders).
pub fn ktBaseTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    return switch (kindOf(f)) {
        .string, .relation_id, .file_name => "String",
        .integer => "Long",
        .double_ => "Double",
        .boolean => "Boolean",
        .json => "JsonElement",
        .select_enum => try selectEnumName(alloc, col_name, f.name),
    };
}

/// The Kotlin *record* type of a field, with multiplicity and nullability
/// applied:
/// - multi-value    -> `List<Base>` (non-null; empty-list default on read)
/// - single select   -> `Base?` (an unset select has no valid enum variant)
/// - single json      -> `JsonElement?` (`JsonObject.get` yields Kotlin null
///                        for an absent/JSON-null key)
/// - everything else  -> `Base` (non-null; empty/zero/false default on read)
pub fn ktRecordTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    const base = try ktBaseTypeOf(alloc, col_name, f);
    if (f.isMultiValue()) return std.fmt.allocPrint(alloc, "List<{s}>", .{base});
    return switch (kindOf(f)) {
        .select_enum => std.fmt.allocPrint(alloc, "{s}?", .{base}),
        .json => "JsonElement?",
        else => base,
    };
}

/// The Kotlin `io.github.valthon.zigbase.typed.FieldType` enum MEMBER name for
/// a field's kind (for the emitted `CollectionMeta`). SCREAMING_SNAKE, matching
/// `FieldType`'s own members (`FieldType.TEXT`) — same mapping as Python's
/// `fieldTypeEnum` (Kotlin's `FieldType` enum is a straight port of Python's).
pub fn fieldTypeEnum(f: schema.Field) []const u8 {
    return switch (f.options) {
        .text => "TEXT",
        .email => "EMAIL",
        .url => "URL",
        .editor => "EDITOR",
        .date => "DATE",
        .autodate => "AUTODATE",
        .bool => "BOOLEAN",
        .number => "NUMBER",
        .json => "JSON",
        .select => "SELECT",
        .relation => "RELATION",
        .file => "FILE",
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
    try std.testing.expectEqualStrings("String", try ktRecordTypeOf(a, "posts", fieldT(.{ .text = .{} })));
    try std.testing.expectEqualStrings("String", try ktRecordTypeOf(a, "posts", fieldT(.{ .date = .{} })));
    try std.testing.expectEqualStrings("Double", try ktRecordTypeOf(a, "posts", fieldT(.{ .number = .{} })));
    try std.testing.expectEqualStrings("Long", try ktRecordTypeOf(a, "posts", fieldT(.{ .number = .{ .mode = .int } })));
    try std.testing.expectEqualStrings("Double", try ktRecordTypeOf(a, "posts", fieldT(.{ .number = .{ .mode = .fixed, .scale = 2 } })));
    try std.testing.expectEqualStrings("Boolean", try ktRecordTypeOf(a, "posts", fieldT(.{ .bool = .{} })));
    try std.testing.expectEqualStrings("JsonElement?", try ktRecordTypeOf(a, "posts", fieldT(.{ .json = .{} })));
}

test "select record type is nullable enum; multi is a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const single = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } };
    const multi = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "a", "b" }, .maxSelect = 3 } } };
    try std.testing.expectEqualStrings("PostStatus?", try ktRecordTypeOf(a, "posts", single));
    try std.testing.expectEqualStrings("List<PostStatus>", try ktRecordTypeOf(a, "posts", multi));
    try std.testing.expectEqualStrings("PostStatus", try ktBaseTypeOf(a, "posts", multi));
}

test "fieldTypeEnum maps bool to BOOLEAN (screaming-snake members)" {
    try std.testing.expectEqualStrings("BOOLEAN", fieldTypeEnum(fieldT(.{ .bool = .{} })));
    try std.testing.expectEqualStrings("NUMBER", fieldTypeEnum(fieldT(.{ .number = .{} })));
    try std.testing.expectEqualStrings("AUTODATE", fieldTypeEnum(fieldT(.{ .autodate = .{} })));
}

test "relation / file record types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rel1 = schema.Field{ .id = "x", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } };
    const relN = schema.Field{ .id = "x", .name = "tags", .options = .{ .relation = .{ .targetCollectionId = "tags", .maxSelect = 9 } } };
    const file1 = schema.Field{ .id = "x", .name = "cover", .options = .{ .file = .{ .maxSelect = 1 } } };
    try std.testing.expectEqualStrings("String", try ktRecordTypeOf(a, "posts", rel1));
    try std.testing.expectEqualStrings("List<String>", try ktRecordTypeOf(a, "posts", relN));
    try std.testing.expectEqualStrings("String", try ktRecordTypeOf(a, "posts", file1));
}
