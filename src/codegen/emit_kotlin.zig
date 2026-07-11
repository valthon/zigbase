//! Emit-helpers for the Kotlin typed client: one fn per Kotlin fragment, each
//! appending to a *std.ArrayList(u8). The Kotlin counterpart of emit_python.zig.
//! Fragments instantiate the runtime in
//! clients/kotlin/src/main/kotlin/io/github/valthon/zigbase/typed/*.kt into
//! concrete `@Serializable` data classes.
//!
//! Scope note (Task 5 data half / Task 6 behavior half): select enums,
//! record classes (+ `<Rec>Expand` submodels), and Create/Update payload
//! models with `toMap()` (Task 5) plus fluent field builders, per-collection
//! metadata, typed services, typed realtime, and the `ZbClient` façade + its
//! `createClient` factory (Task 6) — the Kotlin counterparts of
//! emit_python's emitFields/emitMeta/emitService/emitRealtime/emitClient.
//! Kotlin is coroutine-first (see clients/kotlin's `typed/TypedCollection.kt`):
//! there is no sync/async fork, so (unlike emit_python) there is only ONE
//! service/client emitter — no `emitAsyncService`/`emitAsyncClient`.
const std = @import("std");
const schema = @import("../schema.zig");
const kt = @import("kotlin_type.zig");
const ident = @import("identifiers.zig");

const W = std.ArrayList(u8);

fn put(alloc: std.mem.Allocator, w: *W, s: []const u8) !void {
    try w.appendSlice(alloc, s);
}
fn putf(alloc: std.mem.Allocator, w: *W, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    try w.appendSlice(alloc, s);
}

/// Emit `s` as a Kotlin double-quoted string literal (quotes included),
/// escaping the characters that would break the literal. Used for
/// user-controlled values (select values); field/collection names go through
/// the identifier guard. `spotlessApply`/ktlint may later normalize quote
/// style — this only has to be valid Kotlin.
fn putKtString(alloc: std.mem.Allocator, w: *W, s: []const u8) !void {
    try w.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '\\' => try w.appendSlice(alloc, "\\\\"),
        '"' => try w.appendSlice(alloc, "\\\""),
        '\n' => try w.appendSlice(alloc, "\\n"),
        '\r' => try w.appendSlice(alloc, "\\r"),
        '\t' => try w.appendSlice(alloc, "\\t"),
        '$' => try w.appendSlice(alloc, "\\$"), // Kotlin string-template escape
        else => try w.append(alloc, ch),
    };
    try w.append(alloc, '"');
}

fn isReadOnlySystem(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "created") or
        std.mem.eql(u8, name, "updated");
}
/// A schema field name that duplicates one of the auth-synthesized visible
/// fields (`email`/`username`/`verified`) already appended by
/// `appendVisibleAuthFields`/`emitFields`'s own auth-only block — skipped to
/// avoid emitting the same fluent accessor twice.
fn isAuthSynthesized(name: []const u8) bool {
    return std.mem.eql(u8, name, "email") or
        std.mem.eql(u8, name, "username") or
        std.mem.eql(u8, name, "verified");
}

// ---------------------------------------------------------------------------
// Kotlin identifier sanitizer
//
// Kotlin's hard keywords are ALSO reserved as identifiers (unlike TS's, which
// are legal as member names) — a schema field named `class`/`object`/`when`
// would emit an unparseable `val class: String` in the generated model. The
// rule (mirrors emit_python.zig/emit_dart.zig): the Kotlin identifier gets a
// trailing `_` appended while it collides (with a keyword or a
// context-reserved member); the WIRE key is never changed — `fromRecord`/
// `toMap` read/write by wire key (`r["class"]` / `m["class"] = ...`), with a
// `@SerialName("class")` carrying the original wire key on the property.
// ---------------------------------------------------------------------------

/// Kotlin's hard keywords (reserved in every context; there is no legal
/// identifier with this exact spelling short of backtick-escaping — which
/// this emitter deliberately avoids, see the SP3 plan's Global Constraints).
fn isKotlinKeyword(name: []const u8) bool {
    const kws = [_][]const u8{
        "as",     "break",  "class",     "continue", "do",     "else",  "false",
        "for",    "fun",    "if",        "in",       "interface", "is", "null",
        "object", "package", "return",   "super",    "this",   "throw", "true",
        "try",    "typealias", "typeof", "val",      "var",    "when",  "while",
    };
    for (kws) |k| if (std.mem.eql(u8, name, k)) return true;
    return false;
}

fn inSet(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Context-reserved member sets (the generated class's own members that a
/// schema name must not shadow). Mirrors emit_python.zig's sets, translated
/// to the Kotlin runtime's own vocabulary.
const record_reserved: []const []const u8 = &.{ "expand", "fromRecord" };
const expand_reserved: []const []const u8 = &.{"fromRecord"};
const payload_reserved: []const []const u8 = &.{"toMap"};
/// Compared against the already-uppercased enum member name.
const enum_reserved: []const []const u8 = &.{ "WIRE", "FROM_WIRE", "ENTRIES", "VALUES", "VALUE_OF", "NAME", "ORDINAL" };
/// The `<Rec>Fields` builder's own methods — kept empty (mirrors
/// emit_python.zig's `fields_reserved`): a field named e.g. `filter` lives on
/// the *service*, not the fields builder, so it can't actually collide here.
const fields_reserved: []const []const u8 = &.{};
/// The generated `ZbClient`'s own fixed members — a collection literally
/// named `raw`/`send`/etc. must not shadow them. `realtime` is reserved
/// defensively even though `ZbClient` does not itself expose a `realtime`
/// property (mirrors the SP3 plan's Global Constraints client-reserved set).
const client_reserved: []const []const u8 = &.{ "raw", "owned", "close", "send", "authStore", "realtime" };

/// Map a schema name to a legal Kotlin member identifier for the given
/// context. Appends `_` until the name no longer collides. The wire key is
/// NEVER sanitized — callers keep using the original name for `r["…"]` /
/// `toMap()` keys, plus a `@SerialName` when the identifier actually shifted.
fn memberIdent(alloc: std.mem.Allocator, name: []const u8, reserved: []const []const u8) ![]const u8 {
    var out = name;
    while (isKotlinKeyword(out) or inSet(out, reserved)) {
        out = try std.fmt.allocPrint(alloc, "{s}_", .{out});
    }
    return out;
}

/// Generation-time duplicate-identifier check: two distinct schema names that
/// sanitize to the same Kotlin identifier (e.g. fields `class` and `class_`)
/// would emit a duplicate data-class member. Errors with the colliding names.
fn checkDuplicateIdents(idents: []const []const u8, names: []const []const u8, scope: []const u8) !void {
    for (idents, 0..) |a, i| {
        for (idents[i + 1 ..], i + 1..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                std.log.warn(
                    "gen_kotlin: schema names '{s}' and '{s}' both map to Kotlin identifier '{s}' in {s} — rename one of them",
                    .{ names[i], names[j], a, scope },
                );
                return error.KotlinIdentCollision;
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
    for (c.fields) |f| if (kt.kindOf(f) == .file_name) return true;
    return false;
}

/// True if `c` has at least one SINGLE-value file field — gates the typed
/// `fileUrl` service method and its `<Rec>FileField` enum (a multi-value file
/// field has no single filename to build one URL from, mirroring
/// emit_python.zig's `hasSingleFileFields`).
fn hasSingleFileFields(c: schema.Collection) bool {
    for (c.fields) |f| if (kt.kindOf(f) == .file_name and !f.isMultiValue()) return true;
    return false;
}

/// True if ANY collection declares a file field (single or multi) — gates the
/// `io.github.valthon.zigbase.FileArg` import.
pub fn anyFileFields(cols: []const schema.Collection) bool {
    for (cols) |c| for (c.fields) |f| if (kt.kindOf(f) == .file_name) return true;
    return false;
}

/// True if ANY collection declares a select field.
pub fn anySelectFields(cols: []const schema.Collection) bool {
    for (cols) |c| for (c.fields) |f| if (f.options == .select) return true;
    return false;
}

/// True if ANY collection is an `auth` collection.
pub fn anyAuthCollections(cols: []const schema.Collection) bool {
    for (cols) |c| if (c.type == .auth) return true;
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
/// when it is a valid Kotlin identifier (matching the SCREAMING_SNAKE
/// convention `io.github.valthon.zigbase.typed.FieldType`'s own enums use,
/// e.g. `FieldType.TEXT`); otherwise a positional `V<i>`. Uppercasing
/// sidesteps Kotlin keyword collisions entirely (every hard keyword is
/// lowercase), so only the enum's own reserved member set is checked here.
fn enumMemberIdent(alloc: std.mem.Allocator, value: []const u8, i: usize) ![]const u8 {
    if (schema.isValidIdentifier(value)) {
        return memberIdent(alloc, try toUpperIdent(alloc, value), enum_reserved);
    }
    return std.fmt.allocPrint(alloc, "V{d}", .{i});
}

pub fn emitSelectEnums(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    for (c.fields) |f| {
        if (f.options != .select) continue;
        const ename = try kt.selectEnumName(alloc, c.name, f.name);
        const values = f.options.select.values;

        // Two distinct select values that uppercase to the same Kotlin
        // identifier (e.g. "active"/"ACTIVE") would silently collapse to one
        // enum entry — the LAST one written wins and the other is lost.
        // Compute every entry identifier up front and dedup-check before
        // emitting anything, so this fails generation instead of shipping a
        // client that silently drops a select value.
        const idents = try alloc.alloc([]const u8, values.len);
        for (values, 0..) |v, i| idents[i] = try enumMemberIdent(alloc, v, i);
        try checkDuplicateIdents(idents, values, try std.fmt.allocPrint(
            alloc,
            "select enum {s} (collection '{s}', field '{s}')",
            .{ ename, c.name, f.name },
        ));

        try putf(alloc, w, "@Serializable\nenum class {s}(val wire: String) {{\n", .{ename});
        for (values, 0..) |v, i| {
            try put(alloc, w, "    @SerialName(");
            try putKtString(alloc, w, v);
            try putf(alloc, w, ") {s}(", .{idents[i]});
            try putKtString(alloc, w, v);
            try put(alloc, w, "),\n");
        }
        try putf(alloc, w,
            \\    ;
            \\
            \\    companion object {{
            \\        fun fromWire(v: String?): {s}? = entries.firstOrNull {{ it.wire == v }}
            \\    }}
            \\}}
            \\
            \\
        , .{ename});
    }
}

// ---------------------------------------------------------------------------
// Record classes + expand
// ---------------------------------------------------------------------------

/// The `wireStringOrNull(r["<name>"])`-wrapped `<Enum>.fromWire(...)` / plain
/// `coerce*`/`r["<name>"]` expression that parses the raw wire value into the
/// field's Kotlin type.
fn coerceExpr(alloc: std.mem.Allocator, col: []const u8, f: schema.Field) ![]const u8 {
    const key = f.name;
    return switch (kt.kindOf(f)) {
        .string, .relation_id, .file_name => if (f.isMultiValue())
            try std.fmt.allocPrint(alloc, "coerceStringList(r[\"{s}\"])", .{key})
        else
            try std.fmt.allocPrint(alloc, "coerceString(r[\"{s}\"])", .{key}),
        .integer => if (f.isMultiValue())
            try std.fmt.allocPrint(alloc, "coerceLongList(r[\"{s}\"])", .{key})
        else
            try std.fmt.allocPrint(alloc, "coerceLong(r[\"{s}\"])", .{key}),
        .double_ => if (f.isMultiValue())
            try std.fmt.allocPrint(alloc, "coerceDoubleList(r[\"{s}\"])", .{key})
        else
            try std.fmt.allocPrint(alloc, "coerceDouble(r[\"{s}\"])", .{key}),
        .boolean => try std.fmt.allocPrint(alloc, "coerceBoolean(r[\"{s}\"])", .{key}),
        .json => try std.fmt.allocPrint(alloc, "r[\"{s}\"]", .{key}),
        .select_enum => blk: {
            const en = try kt.selectEnumName(alloc, col, f.name);
            break :blk if (f.isMultiValue())
                try std.fmt.allocPrint(alloc, "coerceStringList(r[\"{s}\"]).mapNotNull {{ {s}.fromWire(it) }}", .{ key, en })
            else
                try std.fmt.allocPrint(alloc, "{s}.fromWire(wireStringOrNull(r[\"{s}\"]))", .{ en, key });
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

    // `<Rec>Expand` is emitted *before* `<Rec>` (matching emit_python's
    // ordering, even though Kotlin — unlike Python — has no forward-reference
    // restriction of its own; kept for cross-emitter consistency).
    if (has_rel) try emitExpand(alloc, w, cols, c);

    try putf(alloc, w, "@Serializable\ndata class {s}(\n", .{rec});
    for (fields, 0..) |f, i| {
        const ty = try kt.ktRecordTypeOf(alloc, c.name, f);
        if (!std.mem.eql(u8, idents[i], f.name)) {
            try put(alloc, w, "    @SerialName(");
            try putKtString(alloc, w, f.name);
            try put(alloc, w, ")\n");
        }
        try putf(alloc, w, "    val {s}: {s},\n", .{ idents[i], ty });
    }
    if (has_rel) {
        const ex = try ident.expandName(alloc, c.name);
        try putf(alloc, w, "    val expand: {s} = {s}(),\n", .{ ex, ex });
    }
    try put(alloc, w, ") {\n");

    try putf(alloc, w, "    companion object {{\n        fun fromRecord(r: JsonObject): {s} = {s}(\n", .{ rec, rec });
    for (fields, 0..) |f, i| {
        try putf(alloc, w, "            {s} = {s},\n", .{ idents[i], try coerceExpr(alloc, c.name, f) });
    }
    if (has_rel) {
        const ex = try ident.expandName(alloc, c.name);
        try putf(alloc, w, "            expand = {s}.fromRecord(r),\n", .{ex});
    }
    try put(alloc, w, "        )\n    }\n}\n\n");
}

fn emitExpand(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    const ex = try ident.expandName(alloc, c.name);

    try putf(alloc, w, "@Serializable\ndata class {s}(\n", .{ex});
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        const target = f.options.relation.targetCollectionId;
        if (!collectionExists(cols, target)) continue;
        const trec = try ident.recordName(alloc, target);
        const mid = try memberIdent(alloc, f.name, expand_reserved);
        if (!std.mem.eql(u8, mid, f.name)) {
            try put(alloc, w, "    @SerialName(");
            try putKtString(alloc, w, f.name);
            try put(alloc, w, ")\n");
        }
        if (f.isMultiValue()) {
            try putf(alloc, w, "    val {s}: List<{s}> = emptyList(),\n", .{ mid, trec });
        } else {
            try putf(alloc, w, "    val {s}: {s}? = null,\n", .{ mid, trec });
        }
    }
    try put(alloc, w, ") {\n");

    try putf(alloc, w, "    companion object {{\n        fun fromRecord(r: JsonObject): {s} = {s}(\n", .{ ex, ex });
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        const target = f.options.relation.targetCollectionId;
        if (!collectionExists(cols, target)) continue;
        const trec = try ident.recordName(alloc, target);
        const mid = try memberIdent(alloc, f.name, expand_reserved);
        if (f.isMultiValue()) {
            try putf(alloc, w, "            {s} = expandMany(r, \"{s}\", {s}::fromRecord),\n", .{ mid, f.name, trec });
        } else {
            try putf(alloc, w, "            {s} = expandOne(r, \"{s}\", {s}::fromRecord),\n", .{ mid, f.name, trec });
        }
    }
    try put(alloc, w, "        )\n    }\n}\n\n");
}

// ---------------------------------------------------------------------------
// Create / Update payloads
// ---------------------------------------------------------------------------

/// The Kotlin BASE type of a Create/Update field — never itself
/// nullable-suffixed (the caller uniformly appends `?` for optional fields),
/// unlike `ktRecordTypeOf` which pre-applies `?` for a single json/select
/// field's *read* type. file -> FileArg; select (single) -> the enum type;
/// json -> `JsonElement` (not `JsonElement?` — `ktRecordTypeOf`'s json
/// nullability reflects a MISSING key on read, which doesn't apply to a
/// payload field the caller is actively setting).
fn payloadFieldType(alloc: std.mem.Allocator, col: []const u8, f: schema.Field) ![]const u8 {
    if (kt.kindOf(f) == .file_name) {
        return if (f.isMultiValue()) "List<FileArg>" else "FileArg";
    }
    if (f.options == .select and !f.isMultiValue()) {
        return try kt.selectEnumName(alloc, col, f.name);
    }
    if (kt.kindOf(f) == .json) return "JsonElement";
    return kt.ktRecordTypeOf(alloc, col, f);
}

/// Emit the `m["<wire>"] = <serialization>` map-entry statement for one
/// payload field, guarded by a `!= null` check when `optional`. `mid` is the
/// (sanitized) Kotlin property; the map key is always the wire name.
fn emitToMapEntry(alloc: std.mem.Allocator, w: *W, f: schema.Field, mid: []const u8, optional: bool) !void {
    var val: []const u8 = undefined;
    switch (kt.kindOf(f)) {
        .integer => val = try std.fmt.allocPrint(alloc, "encodeInt({s})", .{mid}),
        .double_ => {
            if (f.options == .number and f.options.number.mode == .fixed) {
                const scale = f.options.number.scale orelse 0;
                val = try std.fmt.allocPrint(alloc, "encodeFixed({s}, {d})", .{ mid, scale });
            } else {
                val = mid; // float: send as-is
            }
        },
        .select_enum => {
            if (f.isMultiValue()) {
                val = try std.fmt.allocPrint(alloc, "{s}.map {{ it.wire }}", .{mid});
            } else {
                val = try std.fmt.allocPrint(alloc, "{s}.wire", .{mid});
            }
        },
        else => val = mid, // string/relation/bool/json/file -> pass through
    }
    if (optional) {
        try putf(alloc, w, "        if ({s} != null) m[\"{s}\"] = {s}\n", .{ mid, f.name, val });
    } else {
        try putf(alloc, w, "        m[\"{s}\"] = {s}\n", .{ f.name, val });
    }
}

/// True if `c` has at least one field the Create/Update payload would carry
/// (not hidden, not a read-only system field, not the tenant field) — the
/// same filter `emitCreate`/`emitUpdate`'s own loops apply. Auth collections
/// always have a non-empty payload (email/password fields) regardless of
/// this check.
fn hasPayloadField(c: schema.Collection) bool {
    const tenant_field = c.options.tenant_field;
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        return true;
    }
    return false;
}

pub fn emitCreate(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const cn = try ident.createName(alloc, c.name);
    const tenant_field = c.options.tenant_field;

    // A ZERO-field payload (every field hidden/read-only-system/tenant-owned,
    // on a non-auth collection) has no primary-ctor params — `data class X()`
    // is invalid Kotlin. Fall back to a plain class with a constant `toMap`.
    if (c.type != .auth and !hasPayloadField(c)) {
        try putf(alloc, w, "class {s} {{\n    fun toMap(): Map<String, Any?> = emptyMap()\n}}\n\n", .{cn});
        return;
    }

    try putf(alloc, w, "data class {s}(\n", .{cn});
    if (c.type == .auth) {
        try put(alloc, w, "    val email: String,\n    val password: String,\n    val passwordConfirm: String,\n");
    }
    // Required fields first, then optionals — matches emit_python's ordering.
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name) or !f.required) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        const ty = try payloadFieldType(alloc, c.name, f);
        try putf(alloc, w, "    val {s}: {s},\n", .{ try memberIdent(alloc, f.name, payload_reserved), ty });
    }
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name) or f.required) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        const ty = try payloadFieldType(alloc, c.name, f);
        try putf(alloc, w, "    val {s}: {s}? = null,\n", .{ try memberIdent(alloc, f.name, payload_reserved), ty });
    }

    try put(alloc, w, ") {\n    fun toMap(): Map<String, Any?> {\n        val m = mutableMapOf<String, Any?>()\n");
    if (c.type == .auth) {
        try put(alloc, w, "        m[\"email\"] = email\n        m[\"password\"] = password\n        m[\"passwordConfirm\"] = passwordConfirm\n");
    }
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        try emitToMapEntry(alloc, w, f, try memberIdent(alloc, f.name, payload_reserved), !f.required);
    }
    try put(alloc, w, "        return m\n    }\n}\n\n");
}

pub fn emitUpdate(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const un = try ident.updateName(alloc, c.name);
    const tenant_field = c.options.tenant_field;

    // See emitCreate's matching guard: a non-auth collection with no eligible
    // field would otherwise emit an invalid zero-param `data class`.
    if (c.type != .auth and !hasPayloadField(c)) {
        try putf(alloc, w, "class {s} {{\n    fun toMap(): Map<String, Any?> = emptyMap()\n}}\n\n", .{un});
        return;
    }

    try putf(alloc, w, "data class {s}(\n", .{un});
    if (c.type == .auth) try put(alloc, w, "    val email: String? = null,\n");
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        const ty = try payloadFieldType(alloc, c.name, f);
        try putf(alloc, w, "    val {s}: {s}? = null,\n", .{ try memberIdent(alloc, f.name, payload_reserved), ty });
    }

    try put(alloc, w, ") {\n    fun toMap(): Map<String, Any?> {\n        val m = mutableMapOf<String, Any?>()\n");
    if (c.type == .auth) try put(alloc, w, "        if (email != null) m[\"email\"] = email\n");
    for (c.fields) |f| {
        if (f.hidden or isReadOnlySystem(f.name)) continue;
        if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
        try emitToMapEntry(alloc, w, f, try memberIdent(alloc, f.name, payload_reserved), true);
    }
    try put(alloc, w, "        return m\n    }\n}\n\n");
}

// ---------------------------------------------------------------------------
// Fluent field builders
// ---------------------------------------------------------------------------

/// The `<FieldExpr subtype>("${prefix}<name>")` constructor expression for a
/// fluent accessor over field `f`. Returns null when the field has no fluent
/// accessor (file / json — mirrors emit_python's `fluentExpr`/emit_dart's
/// `fluentExpr`). Every branch instantiates a `io.github.valthon.zigbase.typed`
/// FieldExpr class DIRECTLY — a select field's enum-to-wire serialization is
/// expressed via `EnumFieldExpr`'s trailing-lambda `wireOf` callback instead of
/// the generated code overriding anything itself (see `EnumFieldExpr`'s KDoc).
/// select_enum is handled separately by `fluentSelectExpr` (it needs the
/// collection name to derive the enum type, which this fn does not receive).
fn fluentExpr(alloc: std.mem.Allocator, cols: []const schema.Collection, f: schema.Field) !?[]const u8 {
    return switch (kt.kindOf(f)) {
        .file_name, .json, .select_enum => null,
        .string => try std.fmt.allocPrint(alloc, "StringFieldExpr(\"${{prefix}}{s}\")", .{f.name}),
        .integer, .double_ => try std.fmt.allocPrint(alloc, "NumberFieldExpr(\"${{prefix}}{s}\")", .{f.name}),
        .boolean => try std.fmt.allocPrint(alloc, "BoolFieldExpr(\"${{prefix}}{s}\")", .{f.name}),
        .relation_id => blk: {
            const target = f.options.relation.targetCollectionId;
            if (collectionExists(cols, target)) {
                const tf = try ident.fieldsName(alloc, target);
                break :blk try std.fmt.allocPrint(alloc, "RelFieldExpr<{s}>(\"${{prefix}}{s}\") {{ {s}(it) }}", .{ tf, f.name, tf });
            }
            break :blk try std.fmt.allocPrint(alloc, "FieldExpr(\"${{prefix}}{s}\")", .{f.name});
        },
    };
}

/// The `EnumFieldExpr<Enum>("${prefix}<name>") { it.wire }` expression for a
/// select field — needs `col` (for the enum type name), so it is not folded
/// into `fluentExpr` (which only gets `f`).
fn fluentSelectExpr(alloc: std.mem.Allocator, col: []const u8, f: schema.Field) ![]const u8 {
    const en = try kt.selectEnumName(alloc, col, f.name);
    return std.fmt.allocPrint(alloc, "EnumFieldExpr<{s}>(\"${{prefix}}{s}\") {{ it.wire }}", .{ en, f.name });
}

/// The property's declared return type for the same field, e.g.
/// `EnumFieldExpr<PostStatus>`. Kept in lockstep with `fluentExpr`/
/// `fluentSelectExpr` (null for the same fields).
fn fluentReturnType(alloc: std.mem.Allocator, cols: []const schema.Collection, col: []const u8, f: schema.Field) !?[]const u8 {
    return switch (kt.kindOf(f)) {
        .file_name, .json => null,
        .string => "StringFieldExpr",
        .integer, .double_ => "NumberFieldExpr",
        .boolean => "BoolFieldExpr",
        .select_enum => blk: {
            const en = try kt.selectEnumName(alloc, col, f.name);
            break :blk try std.fmt.allocPrint(alloc, "EnumFieldExpr<{s}>", .{en});
        },
        .relation_id => blk: {
            const target = f.options.relation.targetCollectionId;
            if (collectionExists(cols, target)) {
                const tf = try ident.fieldsName(alloc, target);
                break :blk try std.fmt.allocPrint(alloc, "RelFieldExpr<{s}>", .{tf});
            }
            break :blk "FieldExpr";
        },
    };
}

fn emitFieldsProperty(alloc: std.mem.Allocator, w: *W, mid: []const u8, ret: []const u8, expr: []const u8) !void {
    try putf(alloc, w, "    val {s}: {s} get() = {s}\n\n", .{ mid, ret, expr });
}

pub fn emitFields(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    const fname = try ident.fieldsName(alloc, c.name);
    try putf(alloc, w, "class {s}(\n    private val prefix: String = \"\",\n) {{\n", .{fname});
    if (c.type == .auth) {
        try emitFieldsProperty(alloc, w, "email", "StringFieldExpr", "StringFieldExpr(\"${prefix}email\")");
        try emitFieldsProperty(alloc, w, "username", "StringFieldExpr", "StringFieldExpr(\"${prefix}username\")");
        try emitFieldsProperty(alloc, w, "verified", "BoolFieldExpr", "BoolFieldExpr(\"${prefix}verified\")");
    }
    for (c.fields) |f| {
        if (f.hidden) continue;
        if (c.type == .auth and isAuthSynthesized(f.name)) continue;
        if (isReadOnlySystem(f.name)) continue;
        const ret = (try fluentReturnType(alloc, cols, c.name, f)) orelse continue;
        const expr = if (f.options == .select) try fluentSelectExpr(alloc, c.name, f) else (try fluentExpr(alloc, cols, f)).?;
        const mid = try memberIdent(alloc, f.name, fields_reserved);
        try emitFieldsProperty(alloc, w, mid, ret, expr);
    }
    try emitFieldsProperty(alloc, w, "id", "StringFieldExpr", "StringFieldExpr(\"${prefix}id\")");
    try emitFieldsProperty(alloc, w, "created", "StringFieldExpr", "StringFieldExpr(\"${prefix}created\")");
    try emitFieldsProperty(alloc, w, "updated", "StringFieldExpr", "StringFieldExpr(\"${prefix}updated\")");
    try put(alloc, w, "}\n\n");
}

// ---------------------------------------------------------------------------
// Per-collection metadata const
// ---------------------------------------------------------------------------

/// Write a Kotlin `listOf("v1", "v2")` call with every element Kotlin-
/// string-escaped, no trailing comma (a single-line call, unlike the
/// multi-line `mapOf`/`data class` bodies elsewhere in this file).
fn putKtStringListOf(alloc: std.mem.Allocator, w: *W, values: []const []const u8) !void {
    try put(alloc, w, "listOf(");
    for (values, 0..) |v, i| {
        if (i > 0) try put(alloc, w, ", ");
        try putKtString(alloc, w, v);
    }
    try put(alloc, w, ")");
}

pub fn emitMeta(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const mc = try ident.metaConst(alloc, c.name);
    const fields = try recordFields(alloc, c);

    try putf(alloc, w, "val {s} =\n    CollectionMeta(\n        name = ", .{mc});
    try putKtString(alloc, w, c.name);
    try put(alloc, w, ",\n        fields =\n            mapOf(\n");
    for (fields) |f| {
        try put(alloc, w, "                ");
        try putKtString(alloc, w, f.name);
        try putf(alloc, w, " to FieldMeta(type = FieldType.{s}", .{kt.fieldTypeEnum(f)});
        if (f.isMultiValue()) try put(alloc, w, ", multi = true");
        if (f.options == .number) switch (f.options.number.mode) {
            .int => try put(alloc, w, ", mode = NumberMode.INTEGER"),
            .fixed => try putf(alloc, w, ", mode = NumberMode.FIXED, scale = {d}", .{f.options.number.scale orelse 0}),
            .float => {},
        };
        try put(alloc, w, "),\n");
    }
    try put(alloc, w, "            ),\n");

    var file_fields: std.ArrayList([]const u8) = .empty;
    for (c.fields) |f| if (kt.kindOf(f) == .file_name) try file_fields.append(alloc, f.name);
    try put(alloc, w, "        fileFields = ");
    try putKtStringListOf(alloc, w, file_fields.items);
    try put(alloc, w, ",\n");

    var expandable: std.ArrayList([]const u8) = .empty;
    for (c.fields) |f| if (f.options == .relation) try expandable.append(alloc, f.name);
    try put(alloc, w, "        expandable = ");
    try putKtStringListOf(alloc, w, expandable.items);
    try put(alloc, w, ",\n");

    try putf(alloc, w, "        isAuth = {s},\n", .{if (c.type == .auth) "true" else "false"});

    var searchable: std.ArrayList([]const u8) = .empty;
    for (c.fields) |f| if (!f.hidden and f.searchable) try searchable.append(alloc, f.name);
    if (searchable.items.len > 0) {
        try put(alloc, w, "        searchable = ");
        try putKtStringListOf(alloc, w, searchable.items);
        try put(alloc, w, ",\n");
    }

    if (c.options.tenant_field) |tf| {
        try put(alloc, w, "        tenant = ");
        try putKtString(alloc, w, tf);
        try put(alloc, w, ",\n");
    }
    try put(alloc, w, "    )\n\n");
}

// ---------------------------------------------------------------------------
// Typed collection service
// ---------------------------------------------------------------------------

fn enumMemberFor(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (schema.isValidIdentifier(name)) return memberIdent(alloc, try toUpperIdent(alloc, name), enum_reserved);
    return std.fmt.allocPrint(alloc, "F_{s}", .{name});
}

/// Emit the `<Rec>FileField` enum: one SCREAMING_SNAKE member per SINGLE-
/// value file field, valued at the field's wire name. A generated service's
/// `fileUrl` switches on this to pick the right filename off a record.
fn emitFileFieldEnum(alloc: std.mem.Allocator, w: *W, c: schema.Collection, ffenum: []const u8) !void {
    try putf(alloc, w, "enum class {s}(\n    val wire: String,\n) {{\n", .{ffenum});
    for (c.fields) |f| {
        if (kt.kindOf(f) != .file_name or f.isMultiValue()) continue;
        const member = try enumMemberFor(alloc, f.name);
        try putf(alloc, w, "    {s}(", .{member});
        try putKtString(alloc, w, f.name);
        try put(alloc, w, "),\n");
    }
    try put(alloc, w, "}\n\n");
}

/// Emit the service's `fileUrl` method body (no enclosing class braces — the
/// caller closes the class after this and any auth graft). Unlike
/// emit_python's `Mapping`-accepting overload, a generated Kotlin record's
/// single-value file field member is a non-nullable `String` (see
/// `kt.ktRecordTypeOf`), so there is no `KeyError`/null concern to route
/// around: the `when` below is built straight off the typed record's own
/// members.
fn emitFileUrlMethod(alloc: std.mem.Allocator, w: *W, c: schema.Collection, rec: []const u8, ffenum: []const u8) !void {
    try putf(alloc, w,
        \\    fun fileUrl(
        \\        record: {0s},
        \\        field: {1s},
        \\        download: Boolean = false,
        \\        thumb: String? = null,
        \\        token: String? = null,
        \\    ): String {{
        \\        val filename =
        \\            when (field) {{
        \\
    , .{ rec, ffenum });
    for (c.fields) |f| {
        if (kt.kindOf(f) != .file_name or f.isMultiValue()) continue;
        const member = try enumMemberFor(alloc, f.name);
        const mid = try memberIdent(alloc, f.name, record_reserved);
        try putf(alloc, w, "                {s}.{s} -> record.{s}\n", .{ ffenum, member, mid });
    }
    try putf(alloc, w,
        \\            }}
        \\        return c.fileUrl(
        \\            ZbRecord(buildJsonObject {{ put("id", record.id); put("collectionName", "{s}") }}),
        \\            filename,
        \\            download = download,
        \\            thumb = thumb,
        \\            token = token,
        \\        )
        \\    }}
        \\
        \\
    , .{c.name});
}

pub fn emitService(alloc: std.mem.Allocator, w: *W, cols: []const schema.Collection, c: schema.Collection) !void {
    _ = cols;
    const svc = try ident.serviceName(alloc, c.name);
    const rec = try ident.recordName(alloc, c.name);
    const cn = try ident.createName(alloc, c.name);
    const un = try ident.updateName(alloc, c.name);
    const fld = try ident.fieldsName(alloc, c.name);
    const mc = try ident.metaConst(alloc, c.name);

    try putf(alloc, w,
        \\class {0s}(
        \\    client: ZigbaseClient,
        \\) {{
        \\    private val c: TypedCollection<{1s}> = TypedCollection(client, {2s}, {1s}::fromRecord)
        \\
        \\    suspend fun getList(
        \\        page: Int = 1,
        \\        perPage: Int = 30,
        \\        where: (({3s}) -> Expr)? = null,
        \\        sort: List<String>? = null,
        \\        expand: List<String>? = null,
        \\        fields: String? = null,
        \\        skipTotal: Boolean = false,
        \\        search: String? = null,
        \\    ): TypedList<{1s}> =
        \\        c.getList(
        \\            page = page,
        \\            perPage = perPage,
        \\            filter = where?.let {{ it({3s}()).compile() }},
        \\            sort = sort,
        \\            expand = expand,
        \\            fields = fields,
        \\            skipTotal = skipTotal,
        \\            search = search,
        \\        )
        \\
        \\    suspend fun getOne(
        \\        id: String,
        \\        expand: List<String>? = null,
        \\        fields: String? = null,
        \\    ): {1s} = c.getOne(id, expand = expand, fields = fields)
        \\
        \\    suspend fun getFirstListItem(
        \\        where: ({3s}) -> Expr,
        \\        sort: List<String>? = null,
        \\        expand: List<String>? = null,
        \\        fields: String? = null,
        \\        search: String? = null,
        \\    ): {1s} =
        \\        c.getFirstListItem(
        \\            where({3s}()).compile(),
        \\            sort = sort,
        \\            expand = expand,
        \\            fields = fields,
        \\            search = search,
        \\        )
        \\
        \\    suspend fun getPage(
        \\        where: (({3s}) -> Expr)? = null,
        \\        sort: List<String>? = null,
        \\        expand: List<String>? = null,
        \\        cursor: String? = null,
        \\        limit: Int = 30,
        \\        withTotal: Boolean = false,
        \\        fields: String? = null,
        \\        search: String? = null,
        \\    ): TypedCursorPage<{1s}> =
        \\        c.getPage(
        \\            cursor = cursor,
        \\            limit = limit,
        \\            filter = where?.let {{ it({3s}()).compile() }},
        \\            sort = sort,
        \\            expand = expand,
        \\            withTotal = withTotal,
        \\            fields = fields,
        \\            search = search,
        \\        )
        \\
        \\    fun iterate(
        \\        where: (({3s}) -> Expr)? = null,
        \\        sort: List<String>? = null,
        \\        expand: List<String>? = null,
        \\        batch: Int = 100,
        \\        fields: String? = null,
        \\        search: String? = null,
        \\    ): Flow<{1s}> =
        \\        c.iterate(
        \\            batch = batch,
        \\            filter = where?.let {{ it({3s}()).compile() }},
        \\            sort = sort,
        \\            expand = expand,
        \\            fields = fields,
        \\            search = search,
        \\        )
        \\
        \\    suspend fun getFullList(
        \\        where: (({3s}) -> Expr)? = null,
        \\        sort: List<String>? = null,
        \\        expand: List<String>? = null,
        \\        batch: Int = 100,
        \\        fields: String? = null,
        \\        search: String? = null,
        \\    ): List<{1s}> =
        \\        c.getFullList(
        \\            batch = batch,
        \\            filter = where?.let {{ it({3s}()).compile() }},
        \\            sort = sort,
        \\            expand = expand,
        \\            fields = fields,
        \\            search = search,
        \\        )
        \\
        \\    suspend fun create(
        \\        data: {4s},
        \\        expand: List<String>? = null,
        \\        fields: String? = null,
        \\    ): {1s} = c.create(data.toMap(), expand = expand, fields = fields)
        \\
        \\    suspend fun update(
        \\        id: String,
        \\        data: {5s},
        \\        expand: List<String>? = null,
        \\        fields: String? = null,
        \\    ): {1s} = c.update(id, data.toMap(), expand = expand, fields = fields)
        \\
        \\    suspend fun delete(id: String) = c.delete(id)
        \\
        \\    /** Compiles a typed filter expression to a server filter string. */
        \\    fun filter(fn: ({3s}) -> Expr): String = fn({3s}()).compile()
        \\
        \\
    , .{ svc, rec, mc, fld, cn, un });

    if (c.type == .auth) {
        try put(alloc, w,
            \\    suspend fun authWithPassword(
            \\        identity: String,
            \\        password: String,
            \\    ): AuthResponse = c.collection.authWithPassword(identity, password)
            \\
            \\
        );
    }

    if (hasSingleFileFields(c)) {
        const ffenum = try std.fmt.allocPrint(alloc, "{s}FileField", .{rec});
        try emitFileUrlMethod(alloc, w, c, rec, ffenum);
        try put(alloc, w, "}\n\n");
        try emitFileFieldEnum(alloc, w, c, ffenum);
    } else {
        try put(alloc, w, "}\n\n");
    }
}

// ---------------------------------------------------------------------------
// Realtime subclass
// ---------------------------------------------------------------------------

pub fn emitRealtime(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
    const rt = try ident.realtimeAliasName(alloc, c.name);
    const rec = try ident.recordName(alloc, c.name);
    const mc = try ident.metaConst(alloc, c.name);
    try putf(alloc, w,
        \\class {0s}(
        \\    client: ZigbaseClient,
        \\) : TypedRealtime<{1s}>(client, {2s}, {1s}::fromRecord)
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

    try putf(alloc, w,
        \\class {s}(
        \\    val raw: ZigbaseClient,
        \\    val owned: Boolean = false,
        \\) : AutoCloseable {{
        \\
    , .{client_name});
    for (cols, 0..) |c, i| {
        const svc = try ident.serviceName(alloc, c.name);
        try putf(alloc, w, "    val {s}: {s} by lazy {{ {s}(raw) }}\n", .{ svc_idents[i], svc, svc });
    }
    try put(alloc, w, "\n");
    for (cols, 0..) |c, i| {
        const rt = try ident.realtimeAliasName(alloc, c.name);
        try putf(alloc, w, "    val {s}: {s} by lazy {{ {s}(raw) }}\n", .{ rt_idents[i], rt, rt });
    }
    try put(alloc, w,
        \\
        \\    val authStore: AuthStore get() = raw.authStore
        \\
        \\    suspend fun send(
        \\        method: HttpMethod,
        \\        path: String,
        \\        query: Map<String, String>? = null,
        \\        body: Map<String, Any?>? = null,
        \\        headers: Map<String, String>? = null,
        \\    ): JsonElement? = raw.send(method, path, query = query, body = body, headers = headers)
        \\
        \\    override fun close() {
        \\        if (owned) raw.close()
        \\    }
        \\}
        \\
        \\
    );

    const auth_default = if (auth_collection.len > 0)
        try std.fmt.allocPrint(alloc, "\"{s}\"", .{auth_collection})
    else
        "null";
    try putf(alloc, w,
        \\fun createClient(
        \\    url: String,
        \\    authStore: AuthStore = MemoryAuthStore(),
        \\    autoRefresh: Boolean = false,
        \\    authCollection: String? = {s},
        \\    accountId: String? = null,
        \\    lang: String? = null,
        \\    maxRetries: Int = 3,
        \\    httpClient: HttpClient? = null,
        \\    onRealtimeError: ((String) -> Unit)? = null,
        \\): {s} =
        \\    {s}(
        \\        ZigbaseClient(
        \\            url,
        \\            authStore = authStore,
        \\            autoRefresh = autoRefresh,
        \\            authCollection = authCollection,
        \\            accountId = accountId,
        \\            lang = lang,
        \\            maxRetries = maxRetries,
        \\            httpClient = httpClient,
        \\            onRealtimeError = onRealtimeError,
        \\        ),
        \\        owned = true,
        \\    )
        \\
    , .{ auth_default, client_name, client_name });
}
