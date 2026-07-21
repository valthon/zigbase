//! Field → Python type-string mapper. The Python counterpart of dart_type.zig;
//! the single helper every emit_python fragment reuses.
const std = @import("std");
const schema = @import("../schema.zig");
const ident = @import("identifiers.zig");

/// The Python *kind* of a field, ignoring multiplicity. Drives emit branching
/// and coercer-helper selection. Like Dart (and unlike TS), int/fixed/float
/// stay distinct kinds so int-mode fields keep full precision through the
/// decimal-string wire form — but fixed and float both map to the same
/// Python `float` type (Python has no separate "fixed decimal" numeric type;
/// the scale is applied only at encode/coerce time).
pub const PyKind = enum {
    string,
    integer,
    float_,
    boolean,
    json,
    select_enum,
    relation_id,
    file_name,
};

pub fn kindOf(f: schema.Field) PyKind {
    return switch (f.options) {
        .text, .email, .url, .editor, .date, .autodate => .string,
        .number => switch (f.options.number.mode) {
            .int => .integer,
            .fixed, .float => .float_,
        },
        .bool => .boolean,
        .json => .json,
        .select => .select_enum,
        .relation => .relation_id,
        .file => .file_name,
    };
}

/// The generated Python enum class name for a select field, e.g.
/// ("profiles","gender") -> "ProfileGender". Mirrors dart_type.selectEnumName
/// (same PascalCase derivation via the shared identifiers module).
pub fn selectEnumName(alloc: std.mem.Allocator, col_name: []const u8, field_name: []const u8) ![]const u8 {
    const rec = try ident.recordName(alloc, col_name);
    defer alloc.free(rec);
    const fp = try ident.pascal(alloc, field_name);
    defer alloc.free(fp);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ rec, fp });
}

/// The scalar (element) Python type of a field — the value domain for a
/// single element. `[]` multiplicity and nullability are applied by the
/// caller (pyRecordTypeOf / payload builders).
/// Always returns an owned slice (even for the fixed keywords), so callers have a single,
/// consistent ownership contract to free — matching ts_type/dart_type.
pub fn pyBaseTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    return switch (kindOf(f)) {
        .string, .relation_id, .file_name => alloc.dupe(u8, "str"),
        .integer => alloc.dupe(u8, "int"),
        .float_ => alloc.dupe(u8, "float"),
        .boolean => alloc.dupe(u8, "bool"),
        .json => alloc.dupe(u8, "Any"),
        .select_enum => try selectEnumName(alloc, col_name, f.name),
    };
}

/// The Python *record* type of a field, with multiplicity and nullability
/// applied:
/// - multi-value    -> `list[Base]` (non-null; empty-list default on read)
/// - single select   -> `Base | None` (an unset select has no valid enum variant)
/// - single json      -> `Any` (already inclusive of None)
/// - everything else  -> `Base` (non-null; empty/zero/false default on read)
pub fn pyRecordTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    // `base` is now always owned. When we wrap it (multi / single-select) we free the
    // intermediate and return the wrapper; otherwise `base` IS the single owned result.
    const base = try pyBaseTypeOf(alloc, col_name, f);
    if (f.isMultiValue()) {
        defer alloc.free(base);
        return std.fmt.allocPrint(alloc, "list[{s}]", .{base});
    }
    if (kindOf(f) == .select_enum) {
        defer alloc.free(base);
        return std.fmt.allocPrint(alloc, "{s} | None", .{base});
    }
    return base; // json ("Any") and all scalars: base is already the owned result
}

/// The Python `zigbase.typed.FieldType` enum MEMBER name for a field's kind
/// (for the emitted `CollectionMeta`). Unlike Dart's `fieldTypeEnum` (lowercase
/// wire-shaped members, e.g. `.text`), `zigbase.typed.FieldType` members are
/// SCREAMING_SNAKE (`FieldType.TEXT`) — this returns that uppercase form.
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
    try eqType(a, "str", pyRecordTypeOf(a, "posts", fieldT(.{ .text = .{} })));
    try eqType(a, "str", pyRecordTypeOf(a, "posts", fieldT(.{ .date = .{} })));
    try eqType(a, "float", pyRecordTypeOf(a, "posts", fieldT(.{ .number = .{} })));
    try eqType(a, "int", pyRecordTypeOf(a, "posts", fieldT(.{ .number = .{ .mode = .int } })));
    try eqType(a, "float", pyRecordTypeOf(a, "posts", fieldT(.{ .number = .{ .mode = .fixed, .scale = 2 } })));
    try eqType(a, "bool", pyRecordTypeOf(a, "posts", fieldT(.{ .bool = .{} })));
    try eqType(a, "Any", pyRecordTypeOf(a, "posts", fieldT(.{ .json = .{} })));
}

test "select record type is nullable enum; multi is a list" {
    const a = std.testing.allocator;
    const single = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } };
    const multi = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "a", "b" }, .maxSelect = 3 } } };
    try eqType(a, "PostStatus | None", pyRecordTypeOf(a, "posts", single));
    try eqType(a, "list[PostStatus]", pyRecordTypeOf(a, "posts", multi));
    try eqType(a, "PostStatus", pyBaseTypeOf(a, "posts", multi));
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
    try eqType(a, "str", pyRecordTypeOf(a, "posts", rel1));
    try eqType(a, "list[str]", pyRecordTypeOf(a, "posts", relN));
    try eqType(a, "str", pyRecordTypeOf(a, "posts", file1));
}
