//! Emit-helpers for the Python typed client: one fn per Python fragment, each
//! appending to a *std.ArrayList(u8). The Python counterpart of emit_dart.zig.
//! Fragments instantiate the runtime in clients/python/src/zigbase/typed.py
//! (imported here as `zbt`) into concrete pydantic BaseModel classes.
//!
//! Scope note (Task 5): this file emits the DATA half only — select enums,
//! record classes (+ `<Rec>Expand` submodels), and Create/Update payload
//! models with `to_map()`. Fluent field builders, per-collection metadata,
//! typed services, and realtime — the Python counterparts of emit_dart's
//! emitFields/emitMeta/emitService/emitRealtime/emitClient — are Task 6.
const std = @import("std");
const schema = @import("../schema.zig");
const pt = @import("python_type.zig");
const ident = @import("identifiers.zig");

const W = std.ArrayList(u8);

fn put(alloc: std.mem.Allocator, w: *W, s: []const u8) !void {
    try w.appendSlice(alloc, s);
}
fn putf(alloc: std.mem.Allocator, w: *W, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    try w.appendSlice(alloc, s);
}

/// Emit `s` as a Python double-quoted string literal (quotes included),
/// escaping the characters that would break the literal. Used for
/// user-controlled values (select values); field/collection names go through
/// the identifier guard. `ruff format` may later normalize quote style — this
/// only has to be valid Python.
fn putPyString(alloc: std.mem.Allocator, w: *W, s: []const u8) !void {
    try w.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '\\' => try w.appendSlice(alloc, "\\\\"),
        '"' => try w.appendSlice(alloc, "\\\""),
        '\n' => try w.appendSlice(alloc, "\\n"),
        '\r' => try w.appendSlice(alloc, "\\r"),
        '\t' => try w.appendSlice(alloc, "\\t"),
        else => try w.append(alloc, ch),
    };
    try w.append(alloc, '"');
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
// Python identifier sanitizer
//
// TS/Python keywords: Python's ARE reserved (unlike TS's, which are legal as
// member names) — a schema field named `class`/`import`/`in` would emit
// `class: str` in the generated model and the file would not parse. The
// rule (mirrors emit_dart.zig): the PYTHON identifier gets a trailing `_`
// appended while it collides (with a keyword or a context-reserved member);
// the WIRE key is never changed — coercers/to_map read/write by wire key
// (`r.get("class")` / `m["class"] = ...`), so only the Python-side attribute
// name shifts (`class` -> `class_`, wire stays "class").
// ---------------------------------------------------------------------------

/// Python's reserved words (`keyword.kwlist` as of 3.10+), PLUS the soft
/// keywords `match`/`case` — not actually reserved (both are legal
/// identifiers outside a `match` statement's own syntax), but sanitized
/// anyway per the SP3 plan's Global Constraints for defensive conservatism
/// (a generated field literally named `match`/`case` reads awkwardly even
/// where it would compile).
fn isPythonKeyword(name: []const u8) bool {
    const kws = [_][]const u8{
        "False",  "None",   "True",    "and",      "as",       "assert", "async",
        "await",  "break",  "class",   "continue", "def",      "del",    "elif",
        "else",   "except", "finally", "for",      "from",     "global", "if",
        "import", "in",     "is",      "lambda",   "nonlocal", "not",    "or",
        "pass",   "raise",  "return",  "try",      "while",    "with",   "yield",
        "match",  "case",
    };
    for (kws) |k| if (std.mem.eql(u8, name, k)) return true;
    return false;
}

fn inSet(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Context-reserved member sets (the generated class's own members that a
/// schema name must not shadow). Kept modest — mirrors emit_dart.zig's set
/// minus the Dart-only `fromJson`/`values`/`index` (no Python counterpart).
const record_reserved: []const []const u8 = &.{ "expand", "from_record" };
const payload_reserved: []const []const u8 = &.{"to_map"};
/// Uppercase — compared against the already-uppercased enum member name.
const enum_reserved: []const []const u8 = &.{ "NAME", "VALUE", "FROM_WIRE" };
/// The `<Rec>Fields` builder's own methods — a field named `filter` (say)
/// would not actually collide here since `filter` lives on the *service*, not
/// the fields builder, but kept for defensive symmetry with `client_reserved`.
const fields_reserved: []const []const u8 = &.{};
/// The generated `ZbClient`/`AsyncZbClient`'s own fixed members — a
/// collection literally named `raw`/`send`/etc. must not shadow them.
const client_reserved: []const []const u8 = &.{ "raw", "owned", "close", "aclose", "send", "auth_store" };

/// Map a schema name to a legal Python member identifier for the given
/// context. Appends `_` until the name no longer collides. The wire key is
/// NEVER sanitized — callers keep using the original name for `r.get('…')`
/// / `to_map()` keys.
fn memberIdent(alloc: std.mem.Allocator, name: []const u8, reserved: []const []const u8) ![]const u8 {
    var out = name;
    while (isPythonKeyword(out) or inSet(out, reserved)) {
        out = try std.fmt.allocPrint(alloc, "{s}_", .{out});
    }
    return out;
}

/// Generation-time duplicate-identifier check: two distinct schema names that
/// sanitize to the same Python identifier (e.g. fields `class` and `class_`)
/// would emit a duplicate model field. Errors with the colliding names.
fn checkDuplicateIdents(idents: []const []const u8, names: []const []const u8, scope: []const u8) !void {
    for (idents, 0..) |a, i| {
        for (idents[i + 1 ..], i + 1..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                std.log.warn(
                    "gen_python: schema names '{s}' and '{s}' both map to Python identifier '{s}' in {s} — rename one of them",
                    .{ names[i], names[j], a, scope },
                );
                return error.PythonIdentCollision;
            }
        }
    }
}

fn collectionExists(cols: []const schema.Collection, name: []const u8) bool {
    for (cols) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

fn hasResolvableRelations(cols: []const schema.Collection, c: schema.Collection) bool {
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        if (collectionExists(cols, f.options.relation.targetCollectionId)) return true;
    }
    return false;
}

fn hasFileField(c: schema.Collection) bool {
    for (c.fields) |f| if (pt.kindOf(f) == .file_name) return true;
    return false;
}

/// True if `c` has at least one SINGLE-value file field — gates the typed
/// `file_url` service method and its `<Rec>FileField` enum (a multi-value
/// file field has no single filename to build one URL from, so it's excluded
/// exactly like emit_dart's `hasSingleFileFields`).
fn hasSingleFileFields(c: schema.Collection) bool {
    for (c.fields) |f| if (pt.kindOf(f) == .file_name and !f.isMultiValue()) return true;
    return false;
}

/// The `<col>_meta` module-level `CollectionMeta` constant name. Keeps the
/// collection name's casing verbatim (matching the "wire casing, not
/// snake_case" convention Task 5 already established for record field
/// members, e.g. `sentAt` stays `sentAt`) and only appends the `_meta` suffix.
fn pyMetaConst(alloc: std.mem.Allocator, col_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}_meta", .{col_name});
}

/// True if ANY collection declares a file field (single or multi) — gates the
/// `zigbase._multipart.FileArg` import and the `ConfigDict` import (a
/// pydantic model with an `IO[bytes]`-bearing union field needs
/// `arbitrary_types_allowed=True`; pydantic cannot build a core schema for
/// `typing.IO` otherwise).
pub fn anyFileFields(cols: []const schema.Collection) bool {
    for (cols) |c| for (c.fields) |f| if (pt.kindOf(f) == .file_name) return true;
    return false;
}

/// True if ANY collection declares a select field — gates the `enum.Enum` import.
pub fn anySelectFields(cols: []const schema.Collection) bool {
    for (cols) |c| for (c.fields) |f| if (f.options == .select) return true;
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

fn toUpperIdent(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try alloc.alloc(u8, s.len);
    for (s, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
    return out;
}

/// The member identifier for one select value: the wire value UPPERCASED
/// when it is a valid Python identifier (matching the SCREAMING_SNAKE
/// convention `zigbase.typed`'s own enums use, e.g. `FieldType.TEXT`);
/// otherwise a positional `V<i>`. Uppercasing sidesteps Python keyword
/// collisions entirely (every keyword is lowercase), so only the enum's own
/// reserved member set (`NAME`/`VALUE`/`FROM_WIRE`) is checked here.
fn enumMemberIdent(alloc: std.mem.Allocator, value: []const u8, i: usize) ![]const u8 {
    if (schema.isValidIdentifier(value)) {
        return memberIdent(alloc, try toUpperIdent(alloc, value), enum_reserved);
    }
    return std.fmt.allocPrint(alloc, "V{d}", .{i});
}

pub fn emitSelectEnums(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    for (c.fields) |f| {
        if (f.options != .select) continue;
        const ename = try pt.selectEnumName(alloc, c.name, f.name);
        const values = f.options.select.values;

        // Two distinct select values that uppercase to the same Python
        // identifier (e.g. "active"/"ACTIVE") would silently collapse to one
        // enum member — the LAST one written wins and the other is lost.
        // Compute every member identifier up front and dedup-check before
        // emitting anything, so this fails generation instead of shipping a
        // client that silently drops a select value.
        const idents = try alloc.alloc([]const u8, values.len);
        for (values, 0..) |v, i| idents[i] = try enumMemberIdent(alloc, v, i);
        try checkDuplicateIdents(idents, values, try std.fmt.allocPrint(
            alloc,
            "select enum {s} (collection '{s}', field '{s}')",
            .{ ename, c.name, f.name },
        ));

        try putf(alloc, w, "class {s}(str, Enum):\n", .{ename});
        for (values, 0..) |v, i| {
            try putf(alloc, w, "    {s} = ", .{idents[i]});
            try putPyString(alloc, w, v);
            try put(alloc, w, "\n");
        }
        try putf(alloc, w,
            \\
            \\    @classmethod
            \\    def from_wire(cls, v: object) -> {s} | None:
            \\        for e in cls:
            \\            if e.value == v:
            \\                return e
            \\        return None
            \\
            \\
        , .{ename});
    }
}

// ---------------------------------------------------------------------------
// Record classes + expand
// ---------------------------------------------------------------------------

/// The `zbt.coerce*`/enum `from_wire` expression that parses `r.get("<name>")`
/// into the field's Python type.
fn coerceExpr(alloc: std.mem.Allocator, col: []const u8, f: schema.Field) ![]const u8 {
    const key = f.name;
    return switch (pt.kindOf(f)) {
        .string, .relation_id, .file_name => if (f.isMultiValue())
            try std.fmt.allocPrint(alloc, "zbt.coerce_str_list(r.get(\"{s}\"))", .{key})
        else
            try std.fmt.allocPrint(alloc, "zbt.coerce_str(r.get(\"{s}\"))", .{key}),
        .integer => if (f.isMultiValue())
            try std.fmt.allocPrint(alloc, "zbt.coerce_int_list(r.get(\"{s}\"))", .{key})
        else
            try std.fmt.allocPrint(alloc, "zbt.coerce_int(r.get(\"{s}\"))", .{key}),
        .float_ => if (f.isMultiValue())
            try std.fmt.allocPrint(alloc, "zbt.coerce_float_list(r.get(\"{s}\"))", .{key})
        else
            try std.fmt.allocPrint(alloc, "zbt.coerce_float(r.get(\"{s}\"))", .{key}),
        .boolean => try std.fmt.allocPrint(alloc, "zbt.coerce_bool(r.get(\"{s}\"))", .{key}),
        .json => try std.fmt.allocPrint(alloc, "r.get(\"{s}\")", .{key}),
        .select_enum => blk: {
            const en = try pt.selectEnumName(alloc, col, f.name);
            break :blk if (f.isMultiValue())
                try std.fmt.allocPrint(alloc, "[e for v in zbt.coerce_str_list(r.get(\"{s}\")) if (e := {s}.from_wire(v)) is not None]", .{ key, en })
            else
                try std.fmt.allocPrint(alloc, "{s}.from_wire(r.get(\"{s}\"))", .{ en, key });
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

    try putf(alloc, w, "class {s}(BaseModel):\n", .{rec});
    for (fields, 0..) |f, i| {
        const ty = try pt.pyRecordTypeOf(alloc, c.name, f);
        try putf(alloc, w, "    {s}: {s}\n", .{ idents[i], ty });
    }
    if (has_rel) {
        const ex = try ident.expandName(alloc, c.name);
        try putf(alloc, w, "    expand: {s}\n", .{ex});
    }

    try put(alloc, w, "\n    @classmethod\n");
    try putf(alloc, w, "    def from_record(cls, r: Mapping[str, Any]) -> {s}:\n        return cls(\n", .{rec});
    for (fields, 0..) |f, i| {
        try putf(alloc, w, "            {s}={s},\n", .{ idents[i], try coerceExpr(alloc, c.name, f) });
    }
    if (has_rel) {
        const ex = try ident.expandName(alloc, c.name);
        try putf(alloc, w, "            expand={s}.from_record(r),\n", .{ex});
    }
    try put(alloc, w, "        )\n\n\n");

    if (has_rel) try emitExpand(alloc, w, cols, c);
}

fn emitExpand(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    const ex = try ident.expandName(alloc, c.name);
    const expand_reserved: []const []const u8 = &.{"from_record"};

    try putf(alloc, w, "class {s}(BaseModel):\n", .{ex});
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        const target = f.options.relation.targetCollectionId;
        if (!collectionExists(cols, target)) continue;
        const trec = try ident.recordName(alloc, target);
        const mid = try memberIdent(alloc, f.name, expand_reserved);
        if (f.isMultiValue()) {
            try putf(alloc, w, "    {s}: list[{s}]\n", .{ mid, trec });
        } else {
            try putf(alloc, w, "    {s}: {s} | None\n", .{ mid, trec });
        }
    }

    try put(alloc, w, "\n    @classmethod\n");
    try putf(alloc, w, "    def from_record(cls, r: Mapping[str, Any]) -> {s}:\n        return cls(\n", .{ex});
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        const target = f.options.relation.targetCollectionId;
        if (!collectionExists(cols, target)) continue;
        const trec = try ident.recordName(alloc, target);
        const mid = try memberIdent(alloc, f.name, expand_reserved);
        if (f.isMultiValue()) {
            try putf(alloc, w, "            {s}=zbt.expand_many(r, \"{s}\", {s}.from_record),\n", .{ mid, f.name, trec });
        } else {
            try putf(alloc, w, "            {s}=zbt.expand_one(r, \"{s}\", {s}.from_record),\n", .{ mid, f.name, trec });
        }
    }
    try put(alloc, w, "        )\n\n\n");
}

// ---------------------------------------------------------------------------
// Create / Update payloads
// ---------------------------------------------------------------------------

/// The Python type of a Create/Update field (file -> FileArg).
fn payloadFieldType(alloc: std.mem.Allocator, col: []const u8, f: schema.Field) ![]const u8 {
    if (pt.kindOf(f) == .file_name) {
        return if (f.isMultiValue()) "list[FileArg]" else "FileArg";
    }
    if (f.options == .select and !f.isMultiValue()) {
        return try pt.selectEnumName(alloc, col, f.name);
    }
    if (pt.kindOf(f) == .json) return "Any";
    return pt.pyRecordTypeOf(alloc, col, f);
}

/// Emit the `m["<wire>"] = <serialization>` map-entry statement(s) for one
/// payload field, guarded by a `is not None` check when `optional`. `mid` is
/// the (sanitized) Python attribute the value expression reads via `self.`;
/// the map key is always the wire name.
fn emitToMapEntry(alloc: std.mem.Allocator, w: *W, f: schema.Field, mid: []const u8, optional: bool) !void {
    var val: []const u8 = undefined;
    switch (pt.kindOf(f)) {
        .integer => val = try std.fmt.allocPrint(alloc, "zbt.encode_int(self.{s})", .{mid}),
        .float_ => {
            if (f.options == .number and f.options.number.mode == .fixed) {
                const scale = f.options.number.scale orelse 0;
                val = try std.fmt.allocPrint(alloc, "zbt.encode_fixed(self.{s}, {d})", .{ mid, scale });
            } else {
                val = try std.fmt.allocPrint(alloc, "self.{s}", .{mid}); // float: send as-is
            }
        },
        .select_enum => {
            if (f.isMultiValue()) {
                val = try std.fmt.allocPrint(alloc, "[e.value for e in self.{s}]", .{mid});
            } else {
                val = try std.fmt.allocPrint(alloc, "self.{s}.value", .{mid});
            }
        },
        else => val = try std.fmt.allocPrint(alloc, "self.{s}", .{mid}), // string/relation/bool/json/file -> pass through
    }
    if (optional) {
        try putf(alloc, w, "        if self.{s} is not None:\n            m[\"{s}\"] = {s}\n", .{ mid, f.name, val });
    } else {
        try putf(alloc, w, "        m[\"{s}\"] = {s}\n", .{ f.name, val });
    }
}

pub fn emitCreate(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const cn = try ident.createName(alloc, c.name);
    const tenant_field = c.options.tenant_field;
    const needs_arbitrary = hasFileField(c);

    try putf(alloc, w, "class {s}(BaseModel):\n", .{cn});
    if (needs_arbitrary) try put(alloc, w, "    model_config = ConfigDict(arbitrary_types_allowed=True)\n\n");
    if (c.type == .auth) {
        try put(alloc, w, "    email: str\n    password: str\n    password_confirm: str\n");
    }
    // Required fields first, then optionals — matches emit_dart's ordering.
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name) or !f.required) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        const ty = try payloadFieldType(alloc, c.name, f);
        try putf(alloc, w, "    {s}: {s}\n", .{ try memberIdent(alloc, f.name, payload_reserved), ty });
    }
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name) or f.required) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        const ty = try payloadFieldType(alloc, c.name, f);
        try putf(alloc, w, "    {s}: {s} | None = None\n", .{ try memberIdent(alloc, f.name, payload_reserved), ty });
    }

    try put(alloc, w, "\n    def to_map(self) -> dict[str, Any]:\n        m: dict[str, Any] = {}\n");
    if (c.type == .auth) {
        try put(alloc, w, "        m[\"email\"] = self.email\n        m[\"password\"] = self.password\n        m[\"passwordConfirm\"] = self.password_confirm\n");
    }
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        try emitToMapEntry(alloc, w, f, try memberIdent(alloc, f.name, payload_reserved), !f.required);
    }
    try put(alloc, w, "        return m\n\n\n");
}

pub fn emitUpdate(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const un = try ident.updateName(alloc, c.name);
    const tenant_field = c.options.tenant_field;
    const needs_arbitrary = hasFileField(c);

    try putf(alloc, w, "class {s}(BaseModel):\n", .{un});
    if (needs_arbitrary) try put(alloc, w, "    model_config = ConfigDict(arbitrary_types_allowed=True)\n\n");
    if (c.type == .auth) try put(alloc, w, "    email: str | None = None\n");
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        const ty = try payloadFieldType(alloc, c.name, f);
        try putf(alloc, w, "    {s}: {s} | None = None\n", .{ try memberIdent(alloc, f.name, payload_reserved), ty });
    }

    try put(alloc, w, "\n    def to_map(self) -> dict[str, Any]:\n        m: dict[str, Any] = {}\n");
    if (c.type == .auth) try put(alloc, w, "        if self.email is not None:\n            m[\"email\"] = self.email\n");
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        try emitToMapEntry(alloc, w, f, try memberIdent(alloc, f.name, payload_reserved), true);
    }
    try put(alloc, w, "        return m\n\n\n");
}

/// True if ANY collection is an `auth` collection — gates the `AuthResponse`
/// import (only referenced by a generated auth collection's
/// `auth_with_password` passthrough).
pub fn anyAuthCollections(cols: []const schema.Collection) bool {
    for (cols) |c| if (c.type == .auth) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Fluent field builders
// ---------------------------------------------------------------------------

/// The `zbt.*FieldExpr` constructor expression for a fluent accessor over
/// field `f`, e.g. `zbt.StringFieldExpr(f"{self._p}name")`. Returns null when
/// the field has no fluent accessor (file / json — mirrors emit_dart's
/// `fluentExpr`).
///
/// Every branch instantiates a `zigbase.typed` FieldExpr class DIRECTLY —
/// never a generated subclass. A select field's enum-to-wire serialization is
/// expressed via `EnumFieldExpr`'s `wire_of` callback instead: this is what
/// lets `zbt.EnumFieldExpr.eq`/`.neq` (which serialize through `wire_of`
/// before calling `filter_value`) apply correctly without the generated code
/// ever overriding `__eq__`/`__ne__` itself (see `zigbase.typed.FieldExpr`'s
/// docstring on why that dunder rebind only belongs in the runtime, not here).
fn fluentExpr(alloc: std.mem.Allocator, cols: []const schema.Collection, f: schema.Field) !?[]const u8 {
    return switch (pt.kindOf(f)) {
        .file_name, .json => null,
        .string => try std.fmt.allocPrint(alloc, "zbt.StringFieldExpr(f\"{{self._p}}{s}\")", .{f.name}),
        .integer, .float_ => try std.fmt.allocPrint(alloc, "zbt.NumFieldExpr(f\"{{self._p}}{s}\")", .{f.name}),
        .boolean => try std.fmt.allocPrint(alloc, "zbt.BoolFieldExpr(f\"{{self._p}}{s}\")", .{f.name}),
        .select_enum => try std.fmt.allocPrint(alloc, "zbt.EnumFieldExpr(f\"{{self._p}}{s}\", wire_of=lambda e: e.value)", .{f.name}),
        .relation_id => blk: {
            const target = f.options.relation.targetCollectionId;
            if (collectionExists(cols, target)) {
                const tf = try ident.fieldsName(alloc, target);
                break :blk try std.fmt.allocPrint(alloc, "zbt.RelFieldExpr(f\"{{self._p}}{s}\", lambda p: {s}(p))", .{ f.name, tf });
            }
            break :blk try std.fmt.allocPrint(alloc, "zbt.FieldExpr(f\"{{self._p}}{s}\")", .{f.name});
        },
    };
}

/// The property's declared return type for the same field, e.g.
/// `zbt.EnumFieldExpr[PostStatus]`. Kept in lockstep with `fluentExpr` (null
/// for the same fields).
fn fluentReturnType(alloc: std.mem.Allocator, cols: []const schema.Collection, col: []const u8, f: schema.Field) !?[]const u8 {
    return switch (pt.kindOf(f)) {
        .file_name, .json => null,
        .string => "zbt.StringFieldExpr",
        .integer, .float_ => "zbt.NumFieldExpr",
        .boolean => "zbt.BoolFieldExpr",
        .select_enum => blk: {
            const en = try pt.selectEnumName(alloc, col, f.name);
            break :blk try std.fmt.allocPrint(alloc, "zbt.EnumFieldExpr[{s}]", .{en});
        },
        .relation_id => blk: {
            const target = f.options.relation.targetCollectionId;
            if (collectionExists(cols, target)) {
                const tf = try ident.fieldsName(alloc, target);
                break :blk try std.fmt.allocPrint(alloc, "zbt.RelFieldExpr[{s}]", .{tf});
            }
            break :blk "zbt.FieldExpr[str]";
        },
    };
}

fn emitFieldsProperty(alloc: std.mem.Allocator, w: *W, mid: []const u8, ret: []const u8, expr: []const u8) !void {
    try putf(alloc, w, "    @property\n    def {s}(self) -> {s}:\n        return {s}\n\n", .{ mid, ret, expr });
}

pub fn emitFields(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    const fname = try ident.fieldsName(alloc, c.name);
    try putf(alloc, w, "class {s}:\n    def __init__(self, prefix: str = \"\") -> None:\n        self._p = prefix\n\n", .{fname});
    if (c.type == .auth) {
        try emitFieldsProperty(alloc, w, "email", "zbt.StringFieldExpr", "zbt.StringFieldExpr(f\"{self._p}email\")");
        try emitFieldsProperty(alloc, w, "username", "zbt.StringFieldExpr", "zbt.StringFieldExpr(f\"{self._p}username\")");
        try emitFieldsProperty(alloc, w, "verified", "zbt.BoolFieldExpr", "zbt.BoolFieldExpr(f\"{self._p}verified\")");
    }
    for (c.fields) |f| {
        if (f.hidden) continue;
        if (c.type == .auth and isAuthSynthesized(f.name)) continue;
        if (isReadOnlySystem(f.name)) continue;
        const ret = (try fluentReturnType(alloc, cols, c.name, f)) orelse continue;
        const expr = (try fluentExpr(alloc, cols, f)).?;
        const mid = try memberIdent(alloc, f.name, fields_reserved);
        try emitFieldsProperty(alloc, w, mid, ret, expr);
    }
    try emitFieldsProperty(alloc, w, "id", "zbt.StringFieldExpr", "zbt.StringFieldExpr(f\"{self._p}id\")");
    try emitFieldsProperty(alloc, w, "created", "zbt.StringFieldExpr", "zbt.StringFieldExpr(f\"{self._p}created\")");
    try emitFieldsProperty(alloc, w, "updated", "zbt.StringFieldExpr", "zbt.StringFieldExpr(f\"{self._p}updated\")");
    try put(alloc, w, "\n");
}

// ---------------------------------------------------------------------------
// Per-collection metadata const
// ---------------------------------------------------------------------------

/// Write a Python tuple literal `("v1", "v2")` with every element Python-
/// string-escaped, ALWAYS trailing-comma-ing each element (including the
/// last) so a single-element result is still a real 1-tuple (`("v1", )`) and
/// not a parenthesized string.
fn putStrTuple(alloc: std.mem.Allocator, w: *W, values: []const []const u8) !void {
    try put(alloc, w, "(");
    for (values) |v| {
        try putPyString(alloc, w, v);
        try put(alloc, w, ", ");
    }
    try put(alloc, w, ")");
}

pub fn emitMeta(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const mc = try pyMetaConst(alloc, c.name);
    const fields = try recordFields(alloc, c);

    try putf(alloc, w, "{s} = zbt.CollectionMeta(\n    name=", .{mc});
    try putPyString(alloc, w, c.name);
    try put(alloc, w, ",\n    fields={\n");
    for (fields) |f| {
        try put(alloc, w, "        ");
        try putPyString(alloc, w, f.name);
        try putf(alloc, w, ": zbt.FieldMeta(type=zbt.FieldType.{s}", .{pt.fieldTypeEnum(f)});
        if (f.isMultiValue()) try put(alloc, w, ", multi=True");
        if (f.options == .number) switch (f.options.number.mode) {
            .int => try put(alloc, w, ", mode=zbt.NumberMode.INTEGER"),
            .fixed => try putf(alloc, w, ", mode=zbt.NumberMode.FIXED, scale={d}", .{f.options.number.scale orelse 0}),
            .float => {},
        };
        try put(alloc, w, "),\n");
    }
    try put(alloc, w, "    },\n");

    var file_fields: std.ArrayList([]const u8) = .empty;
    for (c.fields) |f| if (pt.kindOf(f) == .file_name) try file_fields.append(alloc, f.name);
    try put(alloc, w, "    file_fields=");
    try putStrTuple(alloc, w, file_fields.items);
    try put(alloc, w, ",\n");

    var expandable: std.ArrayList([]const u8) = .empty;
    for (c.fields) |f| if (f.options == .relation) try expandable.append(alloc, f.name);
    try put(alloc, w, "    expandable=");
    try putStrTuple(alloc, w, expandable.items);
    try put(alloc, w, ",\n");

    try putf(alloc, w, "    is_auth={s},\n", .{if (c.type == .auth) "True" else "False"});

    var searchable: std.ArrayList([]const u8) = .empty;
    for (c.fields) |f| if (!f.hidden and f.searchable) try searchable.append(alloc, f.name);
    if (searchable.items.len > 0) {
        try put(alloc, w, "    searchable=");
        try putStrTuple(alloc, w, searchable.items);
        try put(alloc, w, ",\n");
    }

    if (c.options.tenant_field) |tf| {
        try put(alloc, w, "    tenant=");
        try putPyString(alloc, w, tf);
        try put(alloc, w, ",\n");
    }
    try put(alloc, w, ")\n\n\n");
}

// ---------------------------------------------------------------------------
// Typed collection service (sync + async fork)
// ---------------------------------------------------------------------------

fn enumMemberFor(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (schema.isValidIdentifier(name)) return memberIdent(alloc, try toUpperIdent(alloc, name), enum_reserved);
    return std.fmt.allocPrint(alloc, "F_{s}", .{name});
}

/// Emit the `<Rec>FileField` enum: one SCREAMING_SNAKE member per SINGLE-
/// value file field, valued at the field's wire name. A generated service's
/// `file_url` switches on this to pick the right filename off a record.
fn emitFileFieldEnum(alloc: std.mem.Allocator, w: *W, c: schema.Collection, ffenum: []const u8) !void {
    try putf(alloc, w, "class {s}(Enum):\n", .{ffenum});
    for (c.fields) |f| {
        if (pt.kindOf(f) != .file_name or f.isMultiValue()) continue;
        const member = try enumMemberFor(alloc, f.name);
        try putf(alloc, w, "    {s} = ", .{member});
        try putPyString(alloc, w, f.name);
        try put(alloc, w, "\n");
    }
    try put(alloc, w, "\n\n");
}

/// Emit the service's `file_url` method — SHARED verbatim between the sync
/// and async service (the underlying `TypedCollection`/
/// `AsyncTypedCollection.file_url` is a plain, non-`async`, string builder on
/// both), so this method is never `async` either way. Accepts `record` as
/// either the generated record model OR a raw record mapping (e.g. a
/// realtime event's payload before it's coerced) — the Mapping branch reads
/// by WIRE key, the model branch reads by the record's sanitized attribute.
///
/// The Mapping branch builds a dict literal with one entry per single-value
/// file field so `[field]` can pick the requested one; every entry is
/// evaluated eagerly (that's how a Python dict literal works), so a
/// bracket-indexed `record["{name}"]` would raise `KeyError` for a caller's
/// Mapping that only carries the field it actually wants (e.g. a partial
/// realtime payload) even though the OTHER fields' keys are never looked at
/// again after `[field]` selects one. `.get()` fixes that: only the
/// requested field's key needs to actually be present.
fn emitFileUrlMethod(alloc: std.mem.Allocator, w: *W, c: schema.Collection, rec: []const u8, ffenum: []const u8) !void {
    try putf(alloc, w, "    def file_url(\n        self,\n        record: {s} | Mapping[str, Any],\n        *,\n        field: {s},\n        download: bool = False,\n        thumb: str | None = None,\n        token: str | None = None,\n    ) -> str:\n", .{ rec, ffenum });
    try put(alloc, w, "        record_id = record[\"id\"] if isinstance(record, Mapping) else record.id\n");
    try put(alloc, w, "        filename = {\n");
    for (c.fields) |f| {
        if (pt.kindOf(f) != .file_name or f.isMultiValue()) continue;
        const member = try enumMemberFor(alloc, f.name);
        const mid = try memberIdent(alloc, f.name, record_reserved);
        try putf(alloc, w, "            {s}.{s}: record.get(\"{s}\") if isinstance(record, Mapping) else record.{s},\n", .{ ffenum, member, f.name, mid });
    }
    try put(alloc, w, "        }[field]\n");
    try putf(alloc, w, "        return self._c.file_url(\n            {{\"id\": record_id, \"collectionName\": \"{s}\"}},\n            filename,\n            download=download,\n            thumb=thumb,\n            token=token,\n        )\n\n\n", .{c.name});
}

pub fn emitService(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    _ = cols;
    const svc = try ident.serviceName(alloc, c.name);
    const rec = try ident.recordName(alloc, c.name);
    const cn = try ident.createName(alloc, c.name);
    const un = try ident.updateName(alloc, c.name);
    const fld = try ident.fieldsName(alloc, c.name);
    const mc = try pyMetaConst(alloc, c.name);

    try putf(alloc, w,
        \\class {0s}:
        \\    def __init__(self, client: ZigBase) -> None:
        \\        self._c: zbt.TypedCollection[{1s}] = zbt.TypedCollection(client, {2s}, {1s}.from_record)
        \\
        \\    def get_list(
        \\        self,
        \\        page: int = 1,
        \\        per_page: int = 30,
        \\        *,
        \\        where: Callable[[{3s}], zbt.Expr] | None = None,
        \\        sort: str | Sequence[str] | None = None,
        \\        expand: Sequence[str] | None = None,
        \\        fields: str | None = None,
        \\        skip_total: bool = False,
        \\        search: str | None = None,
        \\    ) -> zbt.TypedList[{1s}]:
        \\        return self._c.get_list(
        \\            page,
        \\            per_page,
        \\            filter=where({3s}()).compile() if where else None,
        \\            sort=sort,
        \\            expand=expand,
        \\            fields=fields,
        \\            skip_total=skip_total,
        \\            search=search,
        \\        )
        \\
        \\    def get_one(
        \\        self, record_id: str, *, expand: Sequence[str] | None = None, fields: str | None = None
        \\    ) -> {1s}:
        \\        return self._c.get_one(record_id, expand=expand, fields=fields)
        \\
        \\    def get_first_list_item(
        \\        self,
        \\        where: Callable[[{3s}], zbt.Expr],
        \\        *,
        \\        sort: str | Sequence[str] | None = None,
        \\        expand: Sequence[str] | None = None,
        \\        fields: str | None = None,
        \\        search: str | None = None,
        \\    ) -> {1s}:
        \\        return self._c.get_first_list_item(
        \\            where({3s}()).compile(), sort=sort, expand=expand, fields=fields, search=search
        \\        )
        \\
        \\    def get_page(
        \\        self,
        \\        *,
        \\        where: Callable[[{3s}], zbt.Expr] | None = None,
        \\        sort: str | Sequence[str] | None = None,
        \\        expand: Sequence[str] | None = None,
        \\        cursor: str | None = None,
        \\        limit: int = 30,
        \\        with_total: bool = False,
        \\        fields: str | None = None,
        \\        search: str | None = None,
        \\    ) -> zbt.TypedCursorPage[{1s}]:
        \\        return self._c.get_page(
        \\            cursor=cursor,
        \\            limit=limit,
        \\            filter=where({3s}()).compile() if where else None,
        \\            sort=sort,
        \\            expand=expand,
        \\            with_total=with_total,
        \\            fields=fields,
        \\            search=search,
        \\        )
        \\
        \\    def iterate(
        \\        self,
        \\        *,
        \\        where: Callable[[{3s}], zbt.Expr] | None = None,
        \\        sort: str | Sequence[str] | None = None,
        \\        expand: Sequence[str] | None = None,
        \\        batch: int = 100,
        \\        fields: str | None = None,
        \\        search: str | None = None,
        \\    ) -> Iterator[{1s}]:
        \\        return self._c.iterate(
        \\            batch=batch,
        \\            filter=where({3s}()).compile() if where else None,
        \\            sort=sort,
        \\            expand=expand,
        \\            fields=fields,
        \\            search=search,
        \\        )
        \\
        \\    def get_full_list(
        \\        self,
        \\        *,
        \\        where: Callable[[{3s}], zbt.Expr] | None = None,
        \\        sort: str | Sequence[str] | None = None,
        \\        expand: Sequence[str] | None = None,
        \\        batch: int = 100,
        \\        fields: str | None = None,
        \\        search: str | None = None,
        \\    ) -> list[{1s}]:
        \\        return self._c.get_full_list(
        \\            batch=batch,
        \\            filter=where({3s}()).compile() if where else None,
        \\            sort=sort,
        \\            expand=expand,
        \\            fields=fields,
        \\            search=search,
        \\        )
        \\
        \\    def create(
        \\        self, data: {4s}, *, expand: Sequence[str] | None = None, fields: str | None = None
        \\    ) -> {1s}:
        \\        return self._c.create(data.to_map(), expand=expand, fields=fields)
        \\
        \\    def update(
        \\        self,
        \\        record_id: str,
        \\        data: {5s},
        \\        *,
        \\        expand: Sequence[str] | None = None,
        \\        fields: str | None = None,
        \\    ) -> {1s}:
        \\        return self._c.update(record_id, data.to_map(), expand=expand, fields=fields)
        \\
        \\    def delete(self, record_id: str) -> None:
        \\        self._c.delete(record_id)
        \\
        \\    def filter(self, fn: Callable[[{3s}], zbt.Expr]) -> str:
        \\        """Compile a typed filter expression to a server filter string."""
        \\        return fn({3s}()).compile()
        \\
        \\
    , .{ svc, rec, mc, fld, cn, un });

    if (c.type == .auth) {
        try put(alloc, w,
            \\    def auth_with_password(self, identity: str, password: str) -> AuthResponse:
            \\        return self._c.collection.auth_with_password(identity, password)
            \\
            \\
        );
    }

    if (hasSingleFileFields(c)) {
        const ffenum = try std.fmt.allocPrint(alloc, "{s}FileField", .{rec});
        try emitFileUrlMethod(alloc, w, c, rec, ffenum);
        try emitFileFieldEnum(alloc, w, c, ffenum);
    } else {
        try put(alloc, w, "\n");
    }
}

pub fn emitAsyncService(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    _ = cols;
    const svc = try std.fmt.allocPrint(alloc, "Async{s}", .{try ident.serviceName(alloc, c.name)});
    const rec = try ident.recordName(alloc, c.name);
    const cn = try ident.createName(alloc, c.name);
    const un = try ident.updateName(alloc, c.name);
    const fld = try ident.fieldsName(alloc, c.name);
    const mc = try pyMetaConst(alloc, c.name);

    try putf(alloc, w,
        \\class {0s}:
        \\    def __init__(self, client: AsyncZigBase) -> None:
        \\        self._c: zbt.AsyncTypedCollection[{1s}] = zbt.AsyncTypedCollection(
        \\            client, {2s}, {1s}.from_record
        \\        )
        \\
        \\    async def get_list(
        \\        self,
        \\        page: int = 1,
        \\        per_page: int = 30,
        \\        *,
        \\        where: Callable[[{3s}], zbt.Expr] | None = None,
        \\        sort: str | Sequence[str] | None = None,
        \\        expand: Sequence[str] | None = None,
        \\        fields: str | None = None,
        \\        skip_total: bool = False,
        \\        search: str | None = None,
        \\    ) -> zbt.TypedList[{1s}]:
        \\        return await self._c.get_list(
        \\            page,
        \\            per_page,
        \\            filter=where({3s}()).compile() if where else None,
        \\            sort=sort,
        \\            expand=expand,
        \\            fields=fields,
        \\            skip_total=skip_total,
        \\            search=search,
        \\        )
        \\
        \\    async def get_one(
        \\        self, record_id: str, *, expand: Sequence[str] | None = None, fields: str | None = None
        \\    ) -> {1s}:
        \\        return await self._c.get_one(record_id, expand=expand, fields=fields)
        \\
        \\    async def get_first_list_item(
        \\        self,
        \\        where: Callable[[{3s}], zbt.Expr],
        \\        *,
        \\        sort: str | Sequence[str] | None = None,
        \\        expand: Sequence[str] | None = None,
        \\        fields: str | None = None,
        \\        search: str | None = None,
        \\    ) -> {1s}:
        \\        return await self._c.get_first_list_item(
        \\            where({3s}()).compile(), sort=sort, expand=expand, fields=fields, search=search
        \\        )
        \\
        \\    async def get_page(
        \\        self,
        \\        *,
        \\        where: Callable[[{3s}], zbt.Expr] | None = None,
        \\        sort: str | Sequence[str] | None = None,
        \\        expand: Sequence[str] | None = None,
        \\        cursor: str | None = None,
        \\        limit: int = 30,
        \\        with_total: bool = False,
        \\        fields: str | None = None,
        \\        search: str | None = None,
        \\    ) -> zbt.TypedCursorPage[{1s}]:
        \\        return await self._c.get_page(
        \\            cursor=cursor,
        \\            limit=limit,
        \\            filter=where({3s}()).compile() if where else None,
        \\            sort=sort,
        \\            expand=expand,
        \\            with_total=with_total,
        \\            fields=fields,
        \\            search=search,
        \\        )
        \\
        \\    def iterate(
        \\        self,
        \\        *,
        \\        where: Callable[[{3s}], zbt.Expr] | None = None,
        \\        sort: str | Sequence[str] | None = None,
        \\        expand: Sequence[str] | None = None,
        \\        batch: int = 100,
        \\        fields: str | None = None,
        \\        search: str | None = None,
        \\    ) -> AsyncIterator[{1s}]:
        \\        return self._c.iterate(
        \\            batch=batch,
        \\            filter=where({3s}()).compile() if where else None,
        \\            sort=sort,
        \\            expand=expand,
        \\            fields=fields,
        \\            search=search,
        \\        )
        \\
        \\    async def get_full_list(
        \\        self,
        \\        *,
        \\        where: Callable[[{3s}], zbt.Expr] | None = None,
        \\        sort: str | Sequence[str] | None = None,
        \\        expand: Sequence[str] | None = None,
        \\        batch: int = 100,
        \\        fields: str | None = None,
        \\        search: str | None = None,
        \\    ) -> list[{1s}]:
        \\        return await self._c.get_full_list(
        \\            batch=batch,
        \\            filter=where({3s}()).compile() if where else None,
        \\            sort=sort,
        \\            expand=expand,
        \\            fields=fields,
        \\            search=search,
        \\        )
        \\
        \\    async def create(
        \\        self, data: {4s}, *, expand: Sequence[str] | None = None, fields: str | None = None
        \\    ) -> {1s}:
        \\        return await self._c.create(data.to_map(), expand=expand, fields=fields)
        \\
        \\    async def update(
        \\        self,
        \\        record_id: str,
        \\        data: {5s},
        \\        *,
        \\        expand: Sequence[str] | None = None,
        \\        fields: str | None = None,
        \\    ) -> {1s}:
        \\        return await self._c.update(record_id, data.to_map(), expand=expand, fields=fields)
        \\
        \\    async def delete(self, record_id: str) -> None:
        \\        await self._c.delete(record_id)
        \\
        \\    def filter(self, fn: Callable[[{3s}], zbt.Expr]) -> str:
        \\        """Compile a typed filter expression to a server filter string."""
        \\        return fn({3s}()).compile()
        \\
        \\
    , .{ svc, rec, mc, fld, cn, un });

    if (c.type == .auth) {
        try put(alloc, w,
            \\    async def auth_with_password(self, identity: str, password: str) -> AuthResponse:
            \\        return await self._c.collection.auth_with_password(identity, password)
            \\
            \\
        );
    }

    // The `<Rec>FileField` enum is emitted once, by the sync service (above)
    // — re-declaring the same class name here would just shadow it.
    if (hasSingleFileFields(c)) {
        const ffenum = try std.fmt.allocPrint(alloc, "{s}FileField", .{rec});
        try emitFileUrlMethod(alloc, w, c, rec, ffenum);
    } else {
        try put(alloc, w, "\n");
    }
}

// ---------------------------------------------------------------------------
// Realtime subclass (async-only)
// ---------------------------------------------------------------------------

pub fn emitRealtime(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const rt = try ident.realtimeAliasName(alloc, c.name);
    const rec = try ident.recordName(alloc, c.name);
    const mc = try pyMetaConst(alloc, c.name);
    try putf(alloc, w,
        \\class {0s}(zbt.TypedRealtime[{1s}]):
        \\    def __init__(self, client: AsyncZigBase) -> None:
        \\        super().__init__(client, {2s}, {1s}.from_record)
        \\
        \\
    , .{ rt, rec, mc });
}

// ---------------------------------------------------------------------------
// Client class + factory
// ---------------------------------------------------------------------------

pub fn emitClient(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, client_name: []const u8, auth_collection: []const u8) !void {
    const svc_idents = try alloc.alloc([]const u8, cols.len);
    const names = try alloc.alloc([]const u8, cols.len);
    for (cols, 0..) |c, i| {
        svc_idents[i] = try memberIdent(alloc, c.name, client_reserved);
        names[i] = c.name;
    }
    try checkDuplicateIdents(svc_idents, names, try std.fmt.allocPrint(alloc, "client class {s}", .{client_name}));

    try putf(alloc, w, "class {s}:\n    def __init__(self, raw: ZigBase, *, owned: bool = False) -> None:\n        self.raw = raw\n        self.owned = owned\n", .{client_name});
    for (cols, 0..) |c, i| {
        const svc = try ident.serviceName(alloc, c.name);
        try putf(alloc, w, "        self.{s} = {s}(raw)\n", .{ svc_idents[i], svc });
    }
    try put(alloc, w,
        \\
        \\    @property
        \\    def auth_store(self) -> AuthStore:
        \\        return self.raw.auth_store
        \\
        \\    def send(
        \\        self,
        \\        method: str,
        \\        path: str,
        \\        *,
        \\        query: dict[str, str] | None = None,
        \\        body: Mapping[str, Any] | None = None,
        \\        headers: dict[str, str] | None = None,
        \\    ) -> Any:
        \\        return self.raw.send(method, path, query=query, body=body, headers=headers)
        \\
        \\    def close(self) -> None:
        \\        if self.owned:
        \\            self.raw.close()
        \\
        \\
    );

    const auth_kw = if (auth_collection.len > 0)
        try std.fmt.allocPrint(alloc, "    kwargs.setdefault(\"auth_collection\", \"{s}\")\n", .{auth_collection})
    else
        "";
    try putf(alloc, w,
        \\def create_client(url: str, **kwargs: Any) -> {s}:
        \\{s}    return {s}(ZigBase(url, **kwargs), owned=True)
        \\
        \\
    , .{ client_name, auth_kw, client_name });
}

pub fn emitAsyncClient(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, client_name: []const u8, auth_collection: []const u8) !void {
    const async_name = try std.fmt.allocPrint(alloc, "Async{s}", .{client_name});
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
    try checkDuplicateIdents(all_idents, all_names, try std.fmt.allocPrint(alloc, "client class {s}", .{async_name}));

    try putf(alloc, w, "class {s}:\n    def __init__(self, raw: AsyncZigBase, *, owned: bool = False) -> None:\n        self.raw = raw\n        self.owned = owned\n", .{async_name});
    for (cols, 0..) |c, i| {
        const svc = try std.fmt.allocPrint(alloc, "Async{s}", .{try ident.serviceName(alloc, c.name)});
        try putf(alloc, w, "        self.{s} = {s}(raw)\n", .{ svc_idents[i], svc });
    }
    for (cols, 0..) |c, i| {
        const rt = try ident.realtimeAliasName(alloc, c.name);
        try putf(alloc, w, "        self.{s} = {s}(raw)\n", .{ rt_idents[i], rt });
    }
    try put(alloc, w,
        \\
        \\    @property
        \\    def auth_store(self) -> AuthStore:
        \\        return self.raw.auth_store
        \\
        \\    async def send(
        \\        self,
        \\        method: str,
        \\        path: str,
        \\        *,
        \\        query: dict[str, str] | None = None,
        \\        body: Mapping[str, Any] | None = None,
        \\        headers: dict[str, str] | None = None,
        \\    ) -> Any:
        \\        return await self.raw.send(method, path, query=query, body=body, headers=headers)
        \\
        \\    async def aclose(self) -> None:
        \\        if self.owned:
        \\            await self.raw.aclose()
        \\
        \\
    );

    const auth_kw = if (auth_collection.len > 0)
        try std.fmt.allocPrint(alloc, "    kwargs.setdefault(\"auth_collection\", \"{s}\")\n", .{auth_collection})
    else
        "";
    try putf(alloc, w,
        \\def create_async_client(url: str, **kwargs: Any) -> {s}:
        \\{s}    return {s}(AsyncZigBase(url, **kwargs), owned=True)
        \\
        \\
    , .{ async_name, auth_kw, async_name });
}
