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
///
/// Uses `ident.recordName` for the singularized collection part (now that it is owned and
/// freeable) so the singularization lives in one place, matching python_type/kotlin_type.
pub fn selectEnumName(alloc: std.mem.Allocator, col_name: []const u8, field_name: []const u8) ![]const u8 {
    const rec = try ident.recordName(alloc, col_name);
    defer alloc.free(rec);
    const fp = try ident.pascal(alloc, field_name);
    defer alloc.free(fp);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ rec, fp });
}

/// The scalar (element) Dart type of a field — the value domain for a single
/// element. `[]` multiplicity and nullability are applied by the caller.
/// Always returns an owned slice (even for the fixed keywords), so callers have
/// a single, consistent ownership contract to free.
pub fn dartBaseTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    return switch (kindOf(f)) {
        .string, .relation_id, .file_name => alloc.dupe(u8, "String"),
        .integer => alloc.dupe(u8, "int"),
        .double_ => alloc.dupe(u8, "double"),
        .boolean => alloc.dupe(u8, "bool"),
        .json => alloc.dupe(u8, "Object?"),
        .select_enum => try selectEnumName(alloc, col_name, f.name),
    };
}

/// The Dart *record* type of a field, with multiplicity and nullability applied:
/// - multi-value  -> `List<Base>` (non-null; empty-list default on read)
/// - single select -> `Base?` (an unset select has no valid enum variant)
/// - single json    -> `Object?`
/// - everything else -> `Base` (non-null; empty/zero/false default on read)
///
/// Returns a single owned slice; frees the intermediate base type it builds on.
pub fn dartRecordTypeOf(alloc: std.mem.Allocator, col_name: []const u8, f: schema.Field) ![]const u8 {
    const base = try dartBaseTypeOf(alloc, col_name, f);
    if (f.isMultiValue()) {
        defer alloc.free(base);
        return std.fmt.allocPrint(alloc, "List<{s}>", .{base});
    }
    switch (kindOf(f)) {
        .select_enum => {
            defer alloc.free(base);
            return std.fmt.allocPrint(alloc, "{s}?", .{base});
        },
        // `.json`'s base is already "Object?"; every other kind returns its base.
        else => return base,
    }
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

// Assert an owned type-string equals `expected`, freeing the result so the
// testing allocator's leak detector stays live (no arena masking).
const H = struct {
    fn eq(al: std.mem.Allocator, expected: []const u8, got: anyerror![]const u8) !void {
        const g = try got;
        defer al.free(g);
        try std.testing.expectEqualStrings(expected, g);
    }
};

test "scalar record types" {
    const a = std.testing.allocator;
    try H.eq(a, "String", dartRecordTypeOf(a, "posts", fieldT(.{ .text = .{} })));
    try H.eq(a, "String", dartRecordTypeOf(a, "posts", fieldT(.{ .date = .{} })));
    try H.eq(a, "double", dartRecordTypeOf(a, "posts", fieldT(.{ .number = .{} })));
    try H.eq(a, "int", dartRecordTypeOf(a, "posts", fieldT(.{ .number = .{ .mode = .int } })));
    try H.eq(a, "double", dartRecordTypeOf(a, "posts", fieldT(.{ .number = .{ .mode = .fixed, .scale = 2 } })));
    try H.eq(a, "bool", dartRecordTypeOf(a, "posts", fieldT(.{ .bool = .{} })));
    try H.eq(a, "Object?", dartRecordTypeOf(a, "posts", fieldT(.{ .json = .{} })));
}

test "select record type is nullable enum; multi is a List" {
    const a = std.testing.allocator;
    const single = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } };
    const multi = schema.Field{ .id = "x", .name = "status", .options = .{ .select = .{ .values = &.{ "a", "b" }, .maxSelect = 3 } } };
    try H.eq(a, "PostStatus?", dartRecordTypeOf(a, "posts", single));
    try H.eq(a, "List<PostStatus>", dartRecordTypeOf(a, "posts", multi));
    try H.eq(a, "PostStatus", dartBaseTypeOf(a, "posts", multi));
}

test "relation / file record types" {
    const a = std.testing.allocator;
    const rel1 = schema.Field{ .id = "x", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users", .maxSelect = 1 } } };
    const relN = schema.Field{ .id = "x", .name = "tags", .options = .{ .relation = .{ .targetCollectionId = "tags", .maxSelect = 9 } } };
    const file1 = schema.Field{ .id = "x", .name = "cover", .options = .{ .file = .{ .maxSelect = 1 } } };
    try H.eq(a, "String", dartRecordTypeOf(a, "posts", rel1));
    try H.eq(a, "List<String>", dartRecordTypeOf(a, "posts", relN));
    try H.eq(a, "String", dartRecordTypeOf(a, "posts", file1));
}

test "fieldTypeEnum maps bool to boolean" {
    try std.testing.expectEqualStrings("boolean", fieldTypeEnum(fieldT(.{ .bool = .{} })));
    try std.testing.expectEqualStrings("number", fieldTypeEnum(fieldT(.{ .number = .{} })));
    try std.testing.expectEqualStrings("autodate", fieldTypeEnum(fieldT(.{ .autodate = .{} })));
}
