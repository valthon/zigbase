//! Emit-helpers for the Dart typed client: one fn per Dart fragment, each
//! appending to a *std.ArrayList(u8). The Dart counterpart of emit.zig. Fragments
//! instantiate the runtime in clients/dart/lib/typed.dart into concrete classes.
const std = @import("std");
const schema = @import("../schema.zig");
const dt = @import("dart_type.zig");
const ident = @import("identifiers.zig");

const W = std.ArrayList(u8);

fn put(alloc: std.mem.Allocator, w: *W, s: []const u8) !void {
    try w.appendSlice(alloc, s);
}
fn putf(alloc: std.mem.Allocator, w: *W, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    try w.appendSlice(alloc, s);
}

/// Emit `s` as a Dart single-quoted string literal (quotes included), escaping
/// the characters that would break the literal. Used for user-controlled values
/// (select values); field/collection names go through the identifier guard.
fn putDartString(alloc: std.mem.Allocator, w: *W, s: []const u8) !void {
    try w.append(alloc, '\'');
    for (s) |ch| switch (ch) {
        '\\' => try w.appendSlice(alloc, "\\\\"),
        '\'' => try w.appendSlice(alloc, "\\'"),
        '\n' => try w.appendSlice(alloc, "\\n"),
        '\r' => try w.appendSlice(alloc, "\\r"),
        '\t' => try w.appendSlice(alloc, "\\t"),
        '$' => try w.appendSlice(alloc, "\\$"),
        else => try w.append(alloc, ch),
    };
    try w.append(alloc, '\'');
}

fn isReadOnlySystem(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "created") or
        std.mem.eql(u8, name, "updated");
}
fn isAuthSynthesized(name: []const u8) bool {
    return std.mem.eql(u8, name, "email") or
        std.mem.eql(u8, name, "username") or
        std.mem.eql(u8, name, "verified");
}

// ---------------------------------------------------------------------------
// Dart identifier sanitizer
//
// TS keywords are legal as member names, so the TS emitter never sanitizes.
// Dart's are NOT: a schema field named `default`/`class`/`in` would emit
// `final String default;` and the generated file would not compile. The rule:
// the DART identifier gets a trailing `_` appended while it collides (with a
// reserved word, an Object member, or a context-reserved member); the WIRE key
// is never changed — the runtime reads/writes by wire key, so only the
// Dart-side name shifts (`default` -> `default_`, wire stays 'default').
// ---------------------------------------------------------------------------

/// Dart reserved words that cannot be used as identifiers (the strict reserved
/// set, plus `await`/`yield` which are reserved inside async/generator bodies
/// — generated members may be referenced from either).
fn isDartKeyword(name: []const u8) bool {
    const kws = [_][]const u8{
        "assert",   "await",   "break",  "case",  "catch",  "class",   "const",
        "continue", "default", "do",     "else",  "enum",   "extends", "false",
        "final",    "finally", "for",    "if",    "in",     "is",      "new",
        "null",     "rethrow", "return", "super", "switch", "this",    "throw",
        "true",     "try",     "var",    "void",  "while",  "with",    "yield",
    };
    for (kws) |k| if (std.mem.eql(u8, name, k)) return true;
    return false;
}

/// Members every Dart class inherits from Object — a schema name mapping onto
/// one of these would conflict with the inherited member.
fn isObjectMember(name: []const u8) bool {
    const ms = [_][]const u8{ "toString", "hashCode", "runtimeType", "noSuchMethod" };
    for (ms) |m| if (std.mem.eql(u8, name, m)) return true;
    return false;
}

fn inSet(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Context-reserved member sets (the generated class's own members that a
/// schema name must not shadow).
const record_reserved: []const []const u8 = &.{ "expand", "fromRecord", "fromJson" };
const payload_reserved: []const []const u8 = &.{"toMap"};
const enum_reserved: []const []const u8 = &.{ "wire", "fromWire", "values", "index", "name" };
const client_reserved: []const []const u8 = &.{ "raw", "owned", "close", "send", "authStore" };

/// Map a schema name to a legal Dart member identifier for the given context.
/// Appends `_` until the name no longer collides. The wire key is NEVER
/// sanitized — callers keep using the original name for r['…'] / toMap keys /
/// filter paths.
fn memberIdent(alloc: std.mem.Allocator, name: []const u8, reserved: []const []const u8) ![]const u8 {
    var out = name;
    while (isDartKeyword(out) or isObjectMember(out) or inSet(out, reserved)) {
        out = try std.fmt.allocPrint(alloc, "{s}_", .{out});
    }
    return out;
}

/// Generation-time duplicate-identifier check: two distinct schema names that
/// sanitize to the same Dart identifier (e.g. fields `default` and `default_`)
/// would emit a duplicate member. Errors with the colliding names.
fn checkDuplicateIdents(idents: []const []const u8, names: []const []const u8, scope: []const u8) !void {
    for (idents, 0..) |a, i| {
        for (idents[i + 1 ..], i + 1..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                // warn (not err): the returned error is the failure signal and the
                // CLI layer logs err at top level; std.log.err inside would also
                // fail the Zig test runner in the expectError coverage test.
                std.log.warn(
                    "gen_dart: schema names '{s}' and '{s}' both map to Dart identifier '{s}' in {s} — rename one of them",
                    .{ names[i], names[j], a, scope },
                );
                return error.DartIdentCollision;
            }
        }
    }
}

fn collectionExists(cols: []const schema.Collection, name: []const u8) bool {
    for (cols) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

fn hasRelations(c: schema.Collection) bool {
    for (c.fields) |f| if (f.options == .relation) return true;
    return false;
}
fn hasResolvableRelations(cols: []const schema.Collection, c: schema.Collection) bool {
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        if (collectionExists(cols, f.options.relation.targetCollectionId)) return true;
    }
    return false;
}
fn hasSingleFileFields(c: schema.Collection) bool {
    for (c.fields) |f| if (dt.kindOf(f) == .file_name and !f.isMultiValue()) return true;
    return false;
}
/// True if ANY collection declares a file field (single or multi) — gates the
/// `package:http/http.dart` import needed for `MultipartFile` in Create/Update.
pub fn anyFileFields(cols: []const schema.Collection) bool {
    for (cols) |c| for (c.fields) |f| if (dt.kindOf(f) == .file_name) return true;
    return false;
}

fn appendVisibleAuthFields(alloc: std.mem.Allocator, list: *std.ArrayList(schema.Field)) !void {
    try list.append(alloc, .{ .id = "_email", .name = "email", .options = .{ .email = .{} } });
    try list.append(alloc, .{ .id = "_username", .name = "username", .options = .{ .text = .{} } });
    try list.append(alloc, .{ .id = "_verified", .name = "verified", .options = .{ .bool = .{} } });
}

/// Record fields in emission order: id, (auth visible), user fields, created, updated.
fn recordFields(alloc: std.mem.Allocator, c: schema.Collection) ![]schema.Field {
    var list: std.ArrayList(schema.Field) = .empty;
    try list.append(alloc, .{ .id = "_id", .name = "id", .options = .{ .text = .{} } });
    if (c.type == .auth) try appendVisibleAuthFields(alloc, &list);
    for (c.fields) |f| {
        if (f.hidden) continue;
        if (isReadOnlySystem(f.name)) continue;
        try list.append(alloc, f);
    }
    try list.append(alloc, .{ .id = "_created", .name = "created", .options = .{ .autodate = .{} } });
    try list.append(alloc, .{ .id = "_updated", .name = "updated", .options = .{ .autodate = .{} } });
    return list.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Select enums
// ---------------------------------------------------------------------------

pub fn emitSelectEnums(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    for (c.fields) |f| {
        if (f.options != .select) continue;
        const ename = try dt.selectEnumName(alloc, c.name, f.name);
        try putf(alloc, w, "enum {s} {{\n  ", .{ename});
        for (f.options.select.values, 0..) |v, i| {
            if (i != 0) try put(alloc, w, ",\n  ");
            // enum member identifier = the value if a valid Dart ident, else v$i.
            try emitEnumMember(alloc, w, v, i);
        }
        try put(alloc, w, ";\n\n");
        try putf(alloc, w, "  const {s}(this.wire);\n  final String wire;\n", .{ename});
        try putf(alloc, w,
            \\  static {s}? fromWire(Object? v) {{
            \\    for (final e in {s}.values) {{
            \\      if (e.wire == v) return e;
            \\    }}
            \\    return null;
            \\  }}
            \\}}
            \\
            \\
        , .{ ename, ename });
    }
}

/// Emit one enum member `<ident>('<wire>')`. The member identifier is the wire
/// value when it is a valid Dart identifier (keyword-sanitized: `default` ->
/// `default_`); otherwise a positional `v<i>`. The wire string is unchanged.
fn emitEnumMember(alloc: std.mem.Allocator, w: *W, value: []const u8, i: usize) !void {
    if (schema.isValidIdentifier(value)) {
        try put(alloc, w, try memberIdent(alloc, value, enum_reserved));
    } else {
        try putf(alloc, w, "v{d}", .{i});
    }
    try put(alloc, w, "(");
    try putDartString(alloc, w, value);
    try put(alloc, w, ")");
}

// ---------------------------------------------------------------------------
// Record classes + expand
// ---------------------------------------------------------------------------

/// The `coerce*` runtime call that parses `r['<name>']` into the field's Dart type.
fn coerceExpr(alloc: std.mem.Allocator, col: []const u8, f: schema.Field) ![]const u8 {
    const key = f.name;
    return switch (dt.kindOf(f)) {
        .string, .relation_id, .file_name => if (f.isMultiValue())
            try std.fmt.allocPrint(alloc, "coerceStringList(r['{s}'])", .{key})
        else
            try std.fmt.allocPrint(alloc, "coerceString(r['{s}'])", .{key}),
        .integer => if (f.isMultiValue())
            try std.fmt.allocPrint(alloc, "coerceIntList(r['{s}'])", .{key})
        else
            try std.fmt.allocPrint(alloc, "coerceInt(r['{s}'])", .{key}),
        .double_ => if (f.isMultiValue())
            try std.fmt.allocPrint(alloc, "coerceDoubleList(r['{s}'])", .{key})
        else
            try std.fmt.allocPrint(alloc, "coerceDouble(r['{s}'])", .{key}),
        .boolean => try std.fmt.allocPrint(alloc, "coerceBool(r['{s}'])", .{key}),
        .json => try std.fmt.allocPrint(alloc, "r['{s}']", .{key}),
        .select_enum => blk: {
            const en = try dt.selectEnumName(alloc, col, f.name);
            break :blk if (f.isMultiValue())
                try std.fmt.allocPrint(alloc, "coerceStringList(r['{s}']).map({s}.fromWire).whereType<{s}>().toList()", .{ key, en, en })
            else
                try std.fmt.allocPrint(alloc, "{s}.fromWire(r['{s}'])", .{ en, key });
        },
    };
}

pub fn emitRecord(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    const rec = try ident.recordName(alloc, c.name);
    const fields = try recordFields(alloc, c);
    const has_rel = hasResolvableRelations(cols, c);

    // Sanitize member identifiers (wire keys stay the schema names) + dedup check.
    const idents = try alloc.alloc([]const u8, fields.len);
    const names = try alloc.alloc([]const u8, fields.len);
    for (fields, 0..) |f, i| {
        idents[i] = try memberIdent(alloc, f.name, record_reserved);
        names[i] = f.name;
    }
    try checkDuplicateIdents(idents, names, try std.fmt.allocPrint(alloc, "record class {s} (collection '{s}')", .{ rec, c.name }));

    // Constructor with an initializer list from the ZbRecord.
    try putf(alloc, w, "class {s} {{\n", .{rec});
    try putf(alloc, w, "  {s}.fromRecord(ZbRecord r)\n      : ", .{rec});
    for (fields, 0..) |f, i| {
        if (i != 0) try put(alloc, w, ",\n        ");
        try putf(alloc, w, "{s} = {s}", .{ idents[i], try coerceExpr(alloc, c.name, f) });
    }
    if (has_rel) {
        const ex = try ident.expandName(alloc, c.name);
        try putf(alloc, w, ",\n        expand = {s}.fromRecord(r)", .{ex});
    }
    try put(alloc, w, ";\n\n");
    // Convenience JSON factory.
    try putf(alloc, w, "  factory {s}.fromJson(Map<String, dynamic> json) => {s}.fromRecord(ZbRecord(json));\n\n", .{ rec, rec });
    // Fields.
    for (fields, 0..) |f, i| {
        const ty = try dt.dartRecordTypeOf(alloc, c.name, f);
        try putf(alloc, w, "  final {s} {s};\n", .{ ty, idents[i] });
    }
    if (has_rel) {
        const ex = try ident.expandName(alloc, c.name);
        try putf(alloc, w, "  final {s} expand;\n", .{ex});
    }
    try put(alloc, w, "}\n\n");

    if (has_rel) try emitExpand(alloc, w, cols, c);
}

fn emitExpand(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    const ex = try ident.expandName(alloc, c.name);
    const expand_reserved: []const []const u8 = &.{"fromRecord"};
    try putf(alloc, w, "class {s} {{\n  {s}.fromRecord(ZbRecord r)\n      : ", .{ ex, ex });
    var first = true;
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        const target = f.options.relation.targetCollectionId;
        if (!collectionExists(cols, target)) continue;
        const trec = try ident.recordName(alloc, target);
        const mid = try memberIdent(alloc, f.name, expand_reserved);
        if (!first) try put(alloc, w, ",\n        ");
        first = false;
        if (f.isMultiValue()) {
            try putf(alloc, w, "{s} = expandMany<{s}>(r, '{s}', {s}.fromRecord)", .{ mid, trec, f.name, trec });
        } else {
            try putf(alloc, w, "{s} = expandOne<{s}>(r, '{s}', {s}.fromRecord)", .{ mid, trec, f.name, trec });
        }
    }
    try put(alloc, w, ";\n\n");
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        const target = f.options.relation.targetCollectionId;
        if (!collectionExists(cols, target)) continue;
        const trec = try ident.recordName(alloc, target);
        const mid = try memberIdent(alloc, f.name, expand_reserved);
        if (f.isMultiValue()) {
            try putf(alloc, w, "  final List<{s}> {s};\n", .{ trec, mid });
        } else {
            try putf(alloc, w, "  final {s}? {s};\n", .{ trec, mid });
        }
    }
    try put(alloc, w, "}\n\n");
}

// ---------------------------------------------------------------------------
// Create / Update payloads
// ---------------------------------------------------------------------------

/// The Dart type of a Create/Update field (file -> MultipartFile).
fn payloadFieldType(alloc: std.mem.Allocator, col: []const u8, f: schema.Field) ![]const u8 {
    if (dt.kindOf(f) == .file_name) {
        return if (f.isMultiValue()) "List<MultipartFile>" else "MultipartFile";
    }
    // For payloads, select single is a nullable enum handled via optional param;
    // use the base scalar type and let the '?' come from optionality.
    if (f.options == .select and !f.isMultiValue()) {
        return try dt.selectEnumName(alloc, col, f.name);
    }
    // json → non-nullable base `Object`; the caller adds `?` for optional fields
    // (avoids a doubled `Object??` since dartRecordTypeOf returns `Object?`).
    if (dt.kindOf(f) == .json) return "Object";
    return dt.dartRecordTypeOf(alloc, col, f);
}

/// Emit the `'<wire>': <serialization>` map entry for one payload field, guarded
/// by a null-check when `optional`. `mid` is the (sanitized) Dart member the
/// value expression references; the map key is always the wire name.
fn emitToMapEntry(alloc: std.mem.Allocator, w: *W, f: schema.Field, mid: []const u8, optional: bool) !void {
    // The serialized value expression (assuming the member is in scope,
    // non-null when guarded).
    var val: []const u8 = undefined;
    switch (dt.kindOf(f)) {
        .integer => val = try std.fmt.allocPrint(alloc, "encodeInt({s})", .{mid}),
        .double_ => {
            if (f.options == .number and f.options.number.mode == .fixed) {
                const scale = f.options.number.scale orelse 0;
                val = try std.fmt.allocPrint(alloc, "encodeFixed({s}, {d})", .{ mid, scale });
            } else {
                val = mid; // float: send the double as-is
            }
        },
        .select_enum => {
            if (f.isMultiValue()) {
                val = try std.fmt.allocPrint(alloc, "{s}.map((e) => e.wire).toList()", .{mid});
            } else if (optional) {
                val = try std.fmt.allocPrint(alloc, "{s}!.wire", .{mid});
            } else {
                val = try std.fmt.allocPrint(alloc, "{s}.wire", .{mid});
            }
        },
        else => val = mid, // string/relation/bool/json/file -> pass through
    }
    if (optional) {
        try putf(alloc, w, "        if ({s} != null) '{s}': {s},\n", .{ mid, f.name, val });
    } else {
        try putf(alloc, w, "        '{s}': {s},\n", .{ f.name, val });
    }
}

pub fn emitCreate(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const cn = try ident.createName(alloc, c.name);
    const tenant_field = c.options.tenant_field;
    try putf(alloc, w, "class {s} {{\n  const {s}({{\n", .{ cn, cn });
    // Auth: required email/password/passwordConfirm.
    if (c.type == .auth) {
        try put(alloc, w, "    required this.email,\n    required this.password,\n    required this.passwordConfirm,\n");
    }
    // Required user fields, then optionals.
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name) or !f.required) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        try putf(alloc, w, "    required this.{s},\n", .{try memberIdent(alloc, f.name, payload_reserved)});
    }
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name) or f.required) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        try putf(alloc, w, "    this.{s},\n", .{try memberIdent(alloc, f.name, payload_reserved)});
    }
    try put(alloc, w, "  });\n\n");
    // Fields.
    if (c.type == .auth) {
        try put(alloc, w, "  final String email;\n  final String password;\n  final String passwordConfirm;\n");
    }
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        const ty = try payloadFieldType(alloc, c.name, f);
        const optional = !f.required;
        try putf(alloc, w, "  final {s}{s} {s};\n", .{ ty, if (optional) "?" else "", try memberIdent(alloc, f.name, payload_reserved) });
    }
    // toMap.
    try put(alloc, w, "\n  Map<String, dynamic> toMap() => {\n");
    if (c.type == .auth) {
        try put(alloc, w, "        'email': email,\n        'password': password,\n        'passwordConfirm': passwordConfirm,\n");
    }
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        try emitToMapEntry(alloc, w, f, try memberIdent(alloc, f.name, payload_reserved), !f.required);
    }
    try put(alloc, w, "      };\n}\n\n");
}

pub fn emitUpdate(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const un = try ident.updateName(alloc, c.name);
    const tenant_field = c.options.tenant_field;
    try putf(alloc, w, "class {s} {{\n  const {s}({{\n", .{ un, un });
    if (c.type == .auth) try put(alloc, w, "    this.email,\n");
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        try putf(alloc, w, "    this.{s},\n", .{try memberIdent(alloc, f.name, payload_reserved)});
    }
    try put(alloc, w, "  });\n\n");
    if (c.type == .auth) try put(alloc, w, "  final String? email;\n");
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        const ty = try payloadFieldType(alloc, c.name, f);
        try putf(alloc, w, "  final {s}? {s};\n", .{ ty, try memberIdent(alloc, f.name, payload_reserved) });
    }
    try put(alloc, w, "\n  Map<String, dynamic> toMap() => {\n");
    if (c.type == .auth) try put(alloc, w, "        if (email != null) 'email': email,\n");
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        try emitToMapEntry(alloc, w, f, try memberIdent(alloc, f.name, payload_reserved), true);
    }
    try put(alloc, w, "      };\n}\n\n");
}

// ---------------------------------------------------------------------------
// Fluent fields builder
// ---------------------------------------------------------------------------

/// The FieldExpr subtype + constructor args for a fluent accessor over field `f`.
/// Returns null when the field has no fluent accessor (file / json).
fn fluentExpr(alloc: std.mem.Allocator, cols: []const schema.Collection, col: []const u8, f: schema.Field) !?[]const u8 {
    return switch (dt.kindOf(f)) {
        .file_name, .json => null,
        .string => try std.fmt.allocPrint(alloc, "StringFieldExpr('${{_p}}{s}')", .{f.name}),
        .integer, .double_ => try std.fmt.allocPrint(alloc, "NumFieldExpr('${{_p}}{s}')", .{f.name}),
        .boolean => try std.fmt.allocPrint(alloc, "BoolFieldExpr('${{_p}}{s}')", .{f.name}),
        .select_enum => blk: {
            const en = try dt.selectEnumName(alloc, col, f.name);
            break :blk try std.fmt.allocPrint(alloc, "EnumFieldExpr<{s}>('${{_p}}{s}', (e) => e.wire)", .{ en, f.name });
        },
        .relation_id => blk: {
            const target = f.options.relation.targetCollectionId;
            if (collectionExists(cols, target)) {
                const tf = try ident.fieldsName(alloc, target);
                break :blk try std.fmt.allocPrint(alloc, "RelFieldExpr<{s}>('${{_p}}{s}', (p) => {s}(p))", .{ tf, f.name, tf });
            }
            break :blk try std.fmt.allocPrint(alloc, "FieldExpr<String>('${{_p}}{s}')", .{f.name});
        },
    };
}

fn fluentReturnType(alloc: std.mem.Allocator, cols: []const schema.Collection, col: []const u8, f: schema.Field) !?[]const u8 {
    return switch (dt.kindOf(f)) {
        .file_name, .json => null,
        .string => "StringFieldExpr",
        .integer, .double_ => "NumFieldExpr",
        .boolean => "BoolFieldExpr",
        .select_enum => blk: {
            const en = try dt.selectEnumName(alloc, col, f.name);
            break :blk try std.fmt.allocPrint(alloc, "EnumFieldExpr<{s}>", .{en});
        },
        .relation_id => blk: {
            const target = f.options.relation.targetCollectionId;
            if (collectionExists(cols, target)) {
                const tf = try ident.fieldsName(alloc, target);
                break :blk try std.fmt.allocPrint(alloc, "RelFieldExpr<{s}>", .{tf});
            }
            break :blk "FieldExpr<String>";
        },
    };
}

pub fn emitFields(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    const fname = try ident.fieldsName(alloc, c.name);
    try putf(alloc, w, "class {s} {{\n  {s}([this._p = '']);\n  final String _p;\n", .{ fname, fname });
    if (c.type == .auth) {
        try put(alloc, w, "  StringFieldExpr get email => StringFieldExpr('${_p}email');\n");
        try put(alloc, w, "  StringFieldExpr get username => StringFieldExpr('${_p}username');\n");
        try put(alloc, w, "  BoolFieldExpr get verified => BoolFieldExpr('${_p}verified');\n");
    }
    for (c.fields) |f| {
        if (f.hidden) continue;
        if (c.type == .auth and isAuthSynthesized(f.name)) continue;
        if (isReadOnlySystem(f.name)) continue;
        const rt = try fluentReturnType(alloc, cols, c.name, f) orelse continue;
        const ex = (try fluentExpr(alloc, cols, c.name, f)).?;
        // Getter name is keyword-sanitized; the filter path inside `ex` stays wire.
        try putf(alloc, w, "  {s} get {s} => {s};\n", .{ rt, try memberIdent(alloc, f.name, &.{}), ex });
    }
    try put(alloc, w, "  StringFieldExpr get id => StringFieldExpr('${_p}id');\n");
    try put(alloc, w, "  StringFieldExpr get created => StringFieldExpr('${_p}created');\n");
    try put(alloc, w, "  StringFieldExpr get updated => StringFieldExpr('${_p}updated');\n");
    try put(alloc, w, "}\n\n");
}

// ---------------------------------------------------------------------------
// Per-collection metadata const
// ---------------------------------------------------------------------------

pub fn emitMeta(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const mc = try ident.metaConst(alloc, c.name);
    try putf(alloc, w, "const CollectionMeta {s} = CollectionMeta(\n  name: '{s}',\n  fields: {{\n", .{ mc, c.name });
    var metaFields: std.ArrayList(schema.Field) = .empty;
    try metaFields.append(alloc, .{ .id = "_id", .name = "id", .options = .{ .text = .{} } });
    if (c.type == .auth) try appendVisibleAuthFields(alloc, &metaFields);
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        try metaFields.append(alloc, f);
    }
    try metaFields.append(alloc, .{ .id = "_created", .name = "created", .options = .{ .autodate = .{} } });
    try metaFields.append(alloc, .{ .id = "_updated", .name = "updated", .options = .{ .autodate = .{} } });
    for (metaFields.items) |f| {
        try putf(alloc, w, "    '{s}': FieldMeta(type: FieldType.{s}", .{ f.name, dt.fieldTypeEnum(f) });
        if (f.isMultiValue()) try put(alloc, w, ", multi: true");
        if (f.options == .number) switch (f.options.number.mode) {
            .int => try put(alloc, w, ", mode: NumberMode.integer"),
            .fixed => try putf(alloc, w, ", mode: NumberMode.fixed, scale: {d}", .{f.options.number.scale orelse 0}),
            .float => {},
        };
        try put(alloc, w, "),\n");
    }
    try put(alloc, w, "  },\n  fileFields: [");
    var first = true;
    for (c.fields) |f| {
        if (dt.kindOf(f) != .file_name) continue;
        if (!first) try put(alloc, w, ", ");
        first = false;
        try putf(alloc, w, "'{s}'", .{f.name});
    }
    try put(alloc, w, "],\n  expandable: [");
    first = true;
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        if (!first) try put(alloc, w, ", ");
        first = false;
        try putf(alloc, w, "'{s}'", .{f.name});
    }
    try putf(alloc, w, "],\n  isAuth: {s},\n", .{if (c.type == .auth) "true" else "false"});
    // searchable
    var any_search = false;
    for (c.fields) |f| if (!f.hidden and f.searchable) {
        any_search = true;
    };
    if (any_search) {
        try put(alloc, w, "  searchable: [");
        first = true;
        for (c.fields) |f| {
            if (f.hidden or !f.searchable) continue;
            if (!first) try put(alloc, w, ", ");
            first = false;
            try putf(alloc, w, "'{s}'", .{f.name});
        }
        try put(alloc, w, "],\n");
    }
    if (c.options.tenant_field) |tf| try putf(alloc, w, "  tenant: '{s}',\n", .{tf});
    try put(alloc, w, ");\n\n");
}

// ---------------------------------------------------------------------------
// Service class
// ---------------------------------------------------------------------------

pub fn emitService(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    _ = cols;
    const svc = try ident.serviceName(alloc, c.name);
    const rec = try ident.recordName(alloc, c.name);
    const wn = try ident.createName(alloc, c.name);
    const un = try ident.updateName(alloc, c.name);
    const fld = try ident.fieldsName(alloc, c.name);
    const mc = try ident.metaConst(alloc, c.name);

    try putf(alloc, w, "class {s} {{\n", .{svc});
    try putf(alloc, w, "  {s}(ZigbaseClient client)\n      : _c = TypedCollection<{s}>(client, {s}, {s}.fromRecord);\n", .{ svc, rec, mc, rec });
    try putf(alloc, w, "  final TypedCollection<{s}> _c;\n\n", .{rec});

    // getList
    try putf(alloc, w,
        \\  Future<TypedList<{0s}>> getList({{
        \\    Expr Function({1s})? where,
        \\    Object? sort,
        \\    List<String>? expand,
        \\    int page = 1,
        \\    int perPage = 30,
        \\    String? fields,
        \\    bool skipTotal = false,
        \\    String? search,
        \\    String? requestKey,
        \\  }}) =>
        \\      _c.getList(
        \\        filter: where == null ? null : where({1s}()).compile(),
        \\        sort: normalizeSort(sort),
        \\        expand: expand,
        \\        page: page,
        \\        perPage: perPage,
        \\        fields: fields,
        \\        skipTotal: skipTotal,
        \\        search: search,
        \\        requestKey: requestKey,
        \\      );
        \\
        \\
    , .{ rec, fld });

    // getOne
    try putf(alloc, w,
        \\  Future<{0s}> getOne(String id,
        \\          {{List<String>? expand, String? fields, String? requestKey}}) =>
        \\      _c.getOne(id, expand: expand, fields: fields, requestKey: requestKey);
        \\
        \\
    , .{rec});

    // getFirstListItem (server-side filter)
    try putf(alloc, w,
        \\  Future<{0s}> getFirstListItem(Expr Function({1s}) where,
        \\          {{List<String>? expand, String? fields, String? requestKey}}) =>
        \\      _c.getFirstListItem(where({1s}()).compile(),
        \\          expand: expand, fields: fields, requestKey: requestKey);
        \\
        \\
    , .{ rec, fld });

    // getPage
    try putf(alloc, w,
        \\  Future<TypedCursorPage<{0s}>> getPage({{
        \\    Expr Function({1s})? where,
        \\    Object? sort,
        \\    List<String>? expand,
        \\    String? cursor,
        \\    int limit = 30,
        \\    bool withTotal = false,
        \\    String? fields,
        \\    String? search,
        \\    String? requestKey,
        \\  }}) =>
        \\      _c.getPage(
        \\        filter: where == null ? null : where({1s}()).compile(),
        \\        sort: normalizeSort(sort),
        \\        expand: expand,
        \\        cursor: cursor,
        \\        limit: limit,
        \\        withTotal: withTotal,
        \\        fields: fields,
        \\        search: search,
        \\        requestKey: requestKey,
        \\      );
        \\
        \\
    , .{ rec, fld });

    // iterate + getFullList
    try putf(alloc, w,
        \\  Stream<{0s}> iterate({{
        \\    Expr Function({1s})? where,
        \\    Object? sort,
        \\    List<String>? expand,
        \\    int batch = 100,
        \\    String? fields,
        \\    String? search,
        \\  }}) =>
        \\      _c.iterate(
        \\        filter: where == null ? null : where({1s}()).compile(),
        \\        sort: normalizeSort(sort),
        \\        expand: expand,
        \\        batch: batch,
        \\        fields: fields,
        \\        search: search,
        \\      );
        \\
        \\  Future<List<{0s}>> getFullList({{
        \\    Expr Function({1s})? where,
        \\    Object? sort,
        \\    List<String>? expand,
        \\    int batch = 100,
        \\    String? fields,
        \\    String? search,
        \\  }}) =>
        \\      _c.getFullList(
        \\        filter: where == null ? null : where({1s}()).compile(),
        \\        sort: normalizeSort(sort),
        \\        expand: expand,
        \\        batch: batch,
        \\        fields: fields,
        \\        search: search,
        \\      );
        \\
        \\
    , .{ rec, fld });

    // create / update / delete
    try putf(alloc, w,
        \\  Future<{0s}> create({1s} data,
        \\          {{List<String>? expand, String? fields, String? requestKey}}) =>
        \\      _c.create(data.toMap(),
        \\          expand: expand, fields: fields, requestKey: requestKey);
        \\
        \\  Future<{0s}> update(String id, {2s} data,
        \\          {{List<String>? expand, String? fields, String? requestKey}}) =>
        \\      _c.update(id, data.toMap(),
        \\          expand: expand, fields: fields, requestKey: requestKey);
        \\
        \\  Future<void> delete(String id) => _c.delete(id);
        \\
        \\  /// Compile a typed filter expression to a server filter string.
        \\  String filter(Expr Function({3s}) fn) => fn({3s}()).compile();
        \\
        \\
    , .{ rec, wn, un, fld });

    // Auth: authWithPassword.
    if (c.type == .auth) {
        try putf(alloc, w,
            \\  Future<AuthResponse> authWithPassword(String identity, String password) =>
            \\      _c.collection.authWithPassword(identity, password);
            \\
            \\
        , .{});
    }

    // Per-single-file-field fileUrl.
    if (hasSingleFileFields(c)) {
        const ffenum = try std.fmt.allocPrint(alloc, "{s}FileField", .{rec});
        // enum of single file fields
        try putf(alloc, w, "  String fileUrl({s} record,\n          {{required {s} field, bool download = false, String? thumb, String? token}}) {{\n", .{ rec, ffenum });
        try put(alloc, w, "    final filename = switch (field) {\n");
        for (c.fields) |f| {
            if (dt.kindOf(f) != .file_name or f.isMultiValue()) continue;
            const member = try enumMemberFor(alloc, f.name);
            // record accessor uses the record class's sanitized member name.
            try putf(alloc, w, "      {s}.{s} => record.{s},\n", .{ ffenum, member, try memberIdent(alloc, f.name, record_reserved) });
        }
        try put(alloc, w, "    };\n");
        try putf(alloc, w, "    return _c.fileUrl(\n      ZbRecord({{'id': record.id, 'collectionName': '{s}'}}),\n      filename,\n      download: download,\n      thumb: thumb,\n      token: token,\n    );\n  }}\n", .{c.name});
    }

    try put(alloc, w, "}\n\n");

    // The file-field enum (after the service so the switch above resolves it).
    if (hasSingleFileFields(c)) {
        try putf(alloc, w, "enum {s}FileField {{ ", .{rec});
        var first = true;
        for (c.fields) |f| {
            if (dt.kindOf(f) != .file_name or f.isMultiValue()) continue;
            if (!first) try put(alloc, w, ", ");
            first = false;
            try put(alloc, w, try enumMemberFor(alloc, f.name));
        }
        try put(alloc, w, " }\n\n");
    }
}

fn enumMemberFor(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (schema.isValidIdentifier(name)) return memberIdent(alloc, name, enum_reserved);
    return std.fmt.allocPrint(alloc, "f_{s}", .{name});
}

// ---------------------------------------------------------------------------
// Realtime subclass
// ---------------------------------------------------------------------------

pub fn emitRealtime(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const rt = try ident.realtimeAliasName(alloc, c.name);
    const rec = try ident.recordName(alloc, c.name);
    const mc = try ident.metaConst(alloc, c.name);
    try putf(alloc, w,
        \\class {0s} extends TypedRealtime<{1s}> {{
        \\  {0s}(ZigbaseClient client) : super(client, {2s}, {1s}.fromRecord);
        \\}}
        \\
        \\
    , .{ rt, rec, mc });
}

// ---------------------------------------------------------------------------
// Client class + factory
// ---------------------------------------------------------------------------

pub fn emitClient(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, client_name: []const u8, auth_collection: []const u8) !void {
    // Sanitize accessor names + dedup across the whole client-member scope
    // (collection accessors, realtime accessors, and the fixed members):
    // e.g. a collection named `raw` -> accessor `raw_`; collections `posts`
    // and `postsRealtime` would both claim `postsRealtime` -> hard error.
    const svc_idents = try alloc.alloc([]const u8, cols.len);
    const rt_idents = try alloc.alloc([]const u8, cols.len);
    const all_idents = try alloc.alloc([]const u8, cols.len * 2);
    const all_names = try alloc.alloc([]const u8, cols.len * 2);
    for (cols, 0..) |c, i| {
        svc_idents[i] = try memberIdent(alloc, c.name, client_reserved);
        rt_idents[i] = try memberIdent(alloc, try std.fmt.allocPrint(alloc, "{s}Realtime", .{c.name}), client_reserved);
        all_idents[i] = svc_idents[i];
        all_names[i] = c.name;
        all_idents[cols.len + i] = rt_idents[i];
        all_names[cols.len + i] = try std.fmt.allocPrint(alloc, "{s} (realtime accessor)", .{c.name});
    }
    try checkDuplicateIdents(all_idents, all_names, try std.fmt.allocPrint(alloc, "client class {s}", .{client_name}));

    try putf(alloc, w, "class {s} {{\n", .{client_name});
    try putf(alloc, w, "  {s}(this.raw, {{this.owned = false}});\n\n  final ZigbaseClient raw;\n  final bool owned;\n\n", .{client_name});
    for (cols, 0..) |c, i| {
        const svc = try ident.serviceName(alloc, c.name);
        try putf(alloc, w, "  late final {s} {s} = {s}(raw);\n", .{ svc, svc_idents[i], svc });
    }
    try put(alloc, w, "\n");
    for (cols, 0..) |c, i| {
        const rt = try ident.realtimeAliasName(alloc, c.name);
        try putf(alloc, w, "  late final {s} {s} = {s}(raw);\n", .{ rt, rt_idents[i], rt });
    }
    try put(alloc, w,
        \\
        \\  AuthStore get authStore => raw.authStore;
        \\
        \\  Future<dynamic> send(String method, String path,
        \\          {Map<String, dynamic>? query, Object? body, Map<String, String>? headers}) =>
        \\      raw.send(method, path, query: query, body: body, headers: headers);
        \\
        \\  Future<void> close() => owned ? raw.close() : Future.value();
        \\}
        \\
        \\
    );

    // Factory function.
    const auth_default = if (auth_collection.len > 0)
        try std.fmt.allocPrint(alloc, "  String authCollection = '{s}',\n", .{auth_collection})
    else
        "  String? authCollection,\n";
    try putf(alloc, w,
        \\{0s} createClient(
        \\  String url, {{
        \\  AuthStore? authStore,
        \\  bool autoRefresh = false,
        \\{1s}  String? accountId,
        \\  String? lang,
        \\  WebSocketConnector? webSocketConnector,
        \\}}) =>
        \\    {0s}(
        \\      ZigbaseClient(
        \\        url,
        \\        authStore: authStore,
        \\        autoRefresh: autoRefresh,
        \\        authCollection: authCollection,
        \\        accountId: accountId,
        \\        lang: lang,
        \\        webSocketConnector: webSocketConnector,
        \\      ),
        \\      owned: true,
        \\    );
        \\
    , .{ client_name, auth_default });
}
