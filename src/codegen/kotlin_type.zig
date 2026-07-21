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
    defer alloc.free(rec);
    const fp = try ident.pascal(alloc, field_name);
    defer alloc.free(fp);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ rec, fp });
}

/// The scalar (element) Kotlin type of a field — the value domain for a
/// single element. `List<...>` multiplicity and nullability are applied by
/// the caller (ktRecordTypeOf / payload builders).
/// Always returns an owned slice (even for the fixed keywords), so callers have a single,
/// consistent ownership contract to free — matching ts_type/dart_type.
pub fn ktBaseTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    return switch (kindOf(f)) {
        .string, .relation_id, .file_name => alloc.dupe(u8, "String"),
        .integer => alloc.dupe(u8, "Long"),
        .double_ => alloc.dupe(u8, "Double"),
        .boolean => alloc.dupe(u8, "Boolean"),
        .json => alloc.dupe(u8, "JsonElement"),
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
    // `base` is now always owned. When we wrap it (multi, or the nullable single-value
    // select/json cases) we free the intermediate and return the wrapper; otherwise `base`
    // IS the single owned result.
    const base = try ktBaseTypeOf(alloc, col_name, f);
    if (f.isMultiValue()) {
        defer alloc.free(base);
        return std.fmt.allocPrint(alloc, "List<{s}>", .{base});
    }
    // Single select and single json are both nullable — `Base?` (json's base is
    // "JsonElement", so this yields the same "JsonElement?" as before).
    if (kindOf(f) == .select_enum or kindOf(f) == .json) {
        defer alloc.free(base);
        return std.fmt.allocPrint(alloc, "{s}?", .{base});
    }
    return base;
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

// Assert a type-mapper result and free it. Every *_type mapper is now always-owned
// (the fixed keywords are duped too), so there is one ownership contract: free the
// result. Running under std.testing.allocator (no masking arena) is real leak detection.
fn eqType(al: std.mem.Allocator, expected: []const u8, got: anyerror![]const u8) !void {
    const g = try got;
    defer al.free(g); // every *_type mapper is now always-owned
    try std.testing.expectEqualStrings(expected, g);
}

test "scalar record types" {
    const a = std.testing.allocator;
    try eqType(a, "String", ktRecordTypeOf(a, "posts", fieldT(.{ .text = .{} })));
    try eqType(a, "String", ktRecordTypeOf(a, "posts", fieldT(.{ .date = .{} })));
    try eqType(a, "Double", ktRecordTypeOf(a, "posts", fieldT(.{ .number = .{} })));
    try eqType(a, "Long", ktRecordTypeOf(a, "posts", fieldT(.{ .number = .{ .mode = .int } })));
    try eqType(a, "Double", ktRecordTypeOf(a, "posts", fieldT(.{ .number = .{ .mode = .fixed, .scale = 2 } })));
    try eqType(a, "Boolean", ktRecordTypeOf(a, "posts", fieldT(.{ .bool = .{} })));
    try eqType(a, "JsonElement?", ktRecordTypeOf(a, "posts", fieldT(.{ .json = .{} })));
}

test "select record type is nullable enum; multi is a list" {
    const a = std.testing.allocator;
    const single = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } };
    const multi = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "a", "b" }, .maxSelect = 3 } } };
    try eqType(a, "PostStatus?", ktRecordTypeOf(a, "posts", single));
    try eqType(a, "List<PostStatus>", ktRecordTypeOf(a, "posts", multi));
    try eqType(a, "PostStatus", ktBaseTypeOf(a, "posts", multi));
}

test "fieldTypeEnum maps bool to BOOLEAN (screaming-snake members)" {
    try std.testing.expectEqualStrings("BOOLEAN", fieldTypeEnum(fieldT(.{ .bool = .{} })));
    try std.testing.expectEqualStrings("NUMBER", fieldTypeEnum(fieldT(.{ .number = .{} })));
    try std.testing.expectEqualStrings("AUTODATE", fieldTypeEnum(fieldT(.{ .autodate = .{} })));
}

test "relation / file record types" {
    const a = std.testing.allocator;
    const rel1 = schema.Field{ .id = "x", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } };
    const relN = schema.Field{ .id = "x", .name = "tags", .options = .{ .relation = .{ .targetCollectionId = "tags", .maxSelect = 9 } } };
    const file1 = schema.Field{ .id = "x", .name = "cover", .options = .{ .file = .{ .maxSelect = 1 } } };
    try eqType(a, "String", ktRecordTypeOf(a, "posts", rel1));
    try eqType(a, "List<String>", ktRecordTypeOf(a, "posts", relN));
    try eqType(a, "String", ktRecordTypeOf(a, "posts", file1));
}
