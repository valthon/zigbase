const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const values = @import("values.zig");
const ddl = @import("ddl.zig");
const id_gen = @import("id.zig");
const compiler = @import("query/compiler.zig");
const lexer = @import("query/lexer.zig");
const parser = @import("query/parser.zig");
const joiner = @import("query/joiner.zig");
const sort = @import("query/sort.zig");
const request = @import("request.zig");
const regex = @import("regex.zig");
const datetime = @import("datetime.zig");

/// A compiled rule constraint enforced atomically on create/update.
pub const Guard = struct {
    where_sql: []const u8,
    joins: []const []const u8 = &.{},
    params: []const compiler.Param = &.{},
};

fn guardJoinsSql(alloc: std.mem.Allocator, joins: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (joins) |jn| {
        try out.append(alloc, ' ');
        try out.appendSlice(alloc, jn);
    }
    return out.toOwnedSlice(alloc);
}

/// SELECT 1 FROM col <joins> WHERE col.id=?1 AND (where) — bound id + guard params.
fn guardPasses(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, rid: []const u8, g: Guard) !bool {
    const js = try guardJoinsSql(alloc, g.joins);
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT 1 FROM \"{s}\"{s} WHERE \"{s}\".\"id\"=?1 AND ({s});", .{ col.name, js, col.name, g.where_sql }, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, rid);
    _ = try bindParams(&st, g.params, 2);
    return try st.step();
}

/// readValue / rowToObject can surface std.json parse errors (for json and multi-value
/// fields), and collections.get widens its own inferred error set. Capture those so
/// RecordError covers everything get/create can produce, the way collections.zig does.
const ReadError = @typeInfo(@typeInfo(@TypeOf(values.readValue)).@"fn".return_type.?).error_union.error_set;
const CollectionsGetError = @typeInfo(@typeInfo(@TypeOf(collections.get)).@"fn".return_type.?).error_union.error_set;

pub const RecordError = error{ Validation, NotFound, NotObject, Forbidden } ||
    db.DbError || values.ValueError || ReadError || CollectionsGetError;

/// Hard cap on the length of an attacker-supplied `?filter=`/`?sort=` string. Rejected
/// before lexing so a giant or deeply-nested expression can't exhaust CPU/stack.
pub const max_filter_len = 4096;

fn columnList(alloc: std.mem.Allocator, col: schema.Collection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    for (col.fields) |f| {
        try out.append(alloc, ',');
        try out.appendSlice(alloc, try ddl.quoteIdent(alloc, f.name));
    }
    return out.toOwnedSlice(alloc);
}

fn rowToObject(alloc: std.mem.Allocator, stmt: *db.Stmt, col: schema.Collection) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "id", .{ .string = try alloc.dupe(u8, stmt.columnText(0)) });
    try obj.put(alloc, "created", .{ .string = try alloc.dupe(u8, stmt.columnText(1)) });
    try obj.put(alloc, "updated", .{ .string = try alloc.dupe(u8, stmt.columnText(2)) });
    for (col.fields, 0..) |f, i| {
        const v = try values.readValue(alloc, stmt, @intCast(3 + i), f);
        if (!f.hidden) try obj.put(alloc, f.name, v);
    }
    return .{ .object = obj };
}

pub fn get(alloc: std.mem.Allocator, r: *db.Db, col: schema.Collection, id: []const u8) RecordError!?std.json.Value {
    const cols = try columnList(alloc, col);
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\" WHERE \"id\" = ?1;", .{ cols, col.name }, 0);
    var st = try r.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id);
    if (!try st.step()) return null;
    return try rowToObject(alloc, &st, col);
}

pub threadlocal var last_errors: ?[]const schema.ValidationError = null;

const BindItem = struct { idx: c_int, field: schema.Field, value: std.json.Value };

fn isEmpty(v: std.json.Value) bool {
    return switch (v) {
        .null => true,
        .string => |s| s.len == 0,
        .array => |arr| arr.items.len == 0,
        else => false,
    };
}

fn countValues(v: std.json.Value) usize {
    return switch (v) {
        .array => |arr| arr.items.len,
        .null => 0,
        else => 1,
    };
}

fn convCode(e: anyerror) []const u8 {
    return switch (e) {
        error.TooPrecise => "validation_too_precise",
        error.TypeMismatch => "validation_type",
        error.Overflow => "validation_overflow",
        error.BadNumber => "validation_number",
        else => "validation_value",
    };
}

fn appendMinMax(alloc: std.mem.Allocator, errs: *std.ArrayList(schema.ValidationError), field: []const u8, x: f64, min: ?f64, max: ?f64) !void {
    if (min) |mn| if (x < mn)
        try errs.append(alloc, .{ .field = field, .code = "validation_min", .message = "Value is below the minimum." });
    if (max) |mx| if (x > mx)
        try errs.append(alloc, .{ .field = field, .code = "validation_max", .message = "Value is above the maximum." });
}

/// Validate text/number min/max constraints, select membership/count, relation
/// existence/count, and number string parsing. Appends field errors to `errs`.
/// `conn` is used for relation existence lookups. Null and empty values skip the
/// min/max constraint checks (required-ness is enforced separately by the caller,
/// and an optional field must stay clearable).
fn validateFieldValue(alloc: std.mem.Allocator, conn: *db.Db, f: schema.Field, v: std.json.Value, errs: *std.ArrayList(schema.ValidationError)) !void {
    switch (f.options) {
        .text => |o| if (v == .string and v.string.len > 0) {
            // min/max are documented as length in unicode codepoints (docs/fields.md).
            const n = std.unicode.utf8CountCodepoints(v.string) catch v.string.len;
            if (o.min) |mn| if (n < mn)
                try errs.append(alloc, .{ .field = f.name, .code = "validation_min", .message = "Value is too short." });
            if (o.max) |mx| if (n > mx)
                try errs.append(alloc, .{ .field = f.name, .code = "validation_max", .message = "Value is too long." });
            if (o.pattern) |pat| {
                // Compile per-write (patterns are small). Fail closed: a stored
                // pattern that won't compile rejects the write rather than silently
                // passing. schema.validate rejects bad patterns at definition time,
                // so this is defense in depth. `alloc` is the request arena; the
                // compiled program is freed with it.
                if (regex.compile(alloc, pat)) |prog| {
                    if (!regex.matches(prog, v.string))
                        try errs.append(alloc, .{ .field = f.name, .code = "validation_pattern", .message = "Value does not match the required pattern." });
                } else |_| {
                    try errs.append(alloc, .{ .field = f.name, .code = "validation_pattern", .message = "Field pattern is invalid." });
                }
            }
        },
        // Email: require a minimal, single-line address. We do NOT attempt full
        // RFC5322 validation, but we MUST reject control characters: an email value
        // flows into outbound SMTP (`To:`/`RCPT TO:`) where a CR/LF/NUL is a
        // header/command-injection vector, and a record stored with such a value
        // would inject on every later verification/reset send. Also require a single
        // '@' with non-empty local/domain parts so obviously-bogus values are caught.
        .email => if (v == .string and v.string.len > 0) {
            const s = v.string;
            var bad = false;
            // Reject ALL ASCII control characters (incl. TAB/VT/FF) and spaces — any of
            // them in an address is bogus and can confuse downstream header/log parsers.
            for (s) |c| if (c < 32 or c == 127 or c == ' ') {
                bad = true;
                break;
            };
            const at = std.mem.indexOfScalar(u8, s, '@');
            if (bad or at == null or at.? == 0 or at.? == s.len - 1 or std.mem.indexOfScalarPos(u8, s, at.? + 1, '@') != null)
                try errs.append(alloc, .{ .field = f.name, .code = "validation_invalid_email", .message = "Invalid email address." });
        },
        // Date values are normalized to UTC seconds for a sound comparison across
        // mixed formats (e.g. "2026-06-10 08:00:00" vs "2026-06-10T08:00:00Z").
        // A non-empty value must parse (rejects garbage like "25:99:99").
        .date => |o| if (v == .string and v.string.len > 0) {
            const secs = datetime.parse(v.string) catch {
                try errs.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Invalid date." });
                return;
            };
            if (o.min) |mn| {
                const b = datetime.parse(mn) catch {
                    try errs.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Invalid date bound." });
                    return;
                };
                if (secs < b) try errs.append(alloc, .{ .field = f.name, .code = "validation_min", .message = "Date is before the minimum." });
            }
            if (o.max) |mx| {
                const b = datetime.parse(mx) catch {
                    try errs.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Invalid date bound." });
                    return;
                };
                if (secs > b) try errs.append(alloc, .{ .field = f.name, .code = "validation_max", .message = "Date is after the maximum." });
            }
        },
        .number => |o| if (o.mode == .float) {
            const x: f64 = switch (v) {
                .float => |fl| fl,
                .integer => |i| @floatFromInt(i),
                else => return,
            };
            try appendMinMax(alloc, errs, f.name, x, o.min, o.max);
        } else if (v == .string) {
            const scale: u8 = if (o.mode == .fixed) (o.scale orelse 0) else 0;
            const sv = values.decimalToScaledInt(v.string, scale) catch |e| {
                try errs.append(alloc, .{ .field = f.name, .code = convCode(e), .message = "Invalid number." });
                return;
            };
            // Compare the decimal value as f64 (value/10^scale vs the f64 bound).
            // Dividing — not multiplying the bound out — is deliberate: the division
            // correctly rounds to the same f64 a decimal-equal bound parsed to, so
            // "0.10" passes min=0.1, whereas f64(0.1)*100 = 10.000000000000002 would
            // false-reject sv=10. Bounds are f64, so values beyond 2^53 cannot be
            // bounded exactly anyway (see the documented-edge test).
            const pow: f64 = @floatFromInt(values.pow10(scale) catch return); // unreachable: decimalToScaledInt already validated scale
            try appendMinMax(alloc, errs, f.name, @as(f64, @floatFromInt(sv)) / pow, o.min, o.max);
        },
        .select => |o| {
            if (countValues(v) > o.maxSelect)
                try errs.append(alloc, .{ .field = f.name, .code = "validation_select", .message = "Too many values." });
            const items: []const std.json.Value = switch (v) {
                .array => |arr| arr.items,
                .string => &.{v},
                else => &.{},
            };
            for (items) |it| if (it == .string) {
                var ok = false;
                for (o.values) |allowed| {
                    if (std.mem.eql(u8, allowed, it.string)) {
                        ok = true;
                        break;
                    }
                }
                if (!ok) try errs.append(alloc, .{ .field = f.name, .code = "validation_select", .message = "Value not in the allowed set." });
            };
        },
        .relation => |o| {
            if (countValues(v) > o.maxSelect)
                try errs.append(alloc, .{ .field = f.name, .code = "validation_relation", .message = "Too many relations." });
            const tcol = (try collections.get(alloc, conn, o.targetCollectionId)) orelse {
                try errs.append(alloc, .{ .field = f.name, .code = "validation_relation", .message = "Relation target missing." });
                return;
            };
            const items: []const std.json.Value = switch (v) {
                .array => |arr| arr.items,
                .string => &.{v},
                else => &.{},
            };
            for (items) |it| if (it == .string) {
                const q = try std.fmt.allocPrintSentinel(alloc, "SELECT 1 FROM \"{s}\" WHERE \"id\" = ?1;", .{tcol.name}, 0);
                var st = try conn.prepare(q);
                defer st.finalize();
                try st.bindText(1, it.string);
                if (!try st.step())
                    try errs.append(alloc, .{ .field = f.name, .code = "validation_not_found", .message = "Referenced record not found." });
            };
        },
        else => {},
    }
}

/// Schema-aware coercion of multipart form fields, applied ONLY to multipart
/// input (never JSON bodies), BEFORE validation. Multipart values arrive as
/// verbatim strings (see src/files/multipart.zig); this makes them look like a
/// well-formed JSON client per the collection schema:
///   bool          "" -> null; "true"/"false" -> JSON bool (else left as-is)
///   number (all)  "" -> null; float mode: parseable, finite -> JSON float
///                 (else left as a string); int/fixed: kept as a string
///                 (the accepted form)
///   select/relation (multi)  "" -> null; JSON-array string -> array (the admin
///                 UI sends JSON.stringify(array)); any other string wraps as a
///                 one-element array of the ORIGINAL string ("123" -> ["123"])
///   json          "" -> null; any parseable JSON -> the parsed value; else the
///                 raw string
///   everything else (text/email/url/editor/date/single select/relation/file)
///                 kept verbatim — including "", which is their JSON clear form
/// So an empty multipart value clears every field type: text-likes store "",
/// bool/number/json/multi-value fields store null. Keys that match no schema
/// field ("<field>-" removal keys, auth password/passwordConfirm) and
/// non-string values pass through untouched. Allocates into `alloc` (arena).
pub fn coerceFormFields(alloc: std.mem.Allocator, col: schema.Collection, data: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    if (data != .object) return data;
    var out: std.json.ObjectMap = .empty;
    var it = data.object.iterator();
    while (it.next()) |e| {
        try out.put(alloc, e.key_ptr.*, try coerceFieldValue(alloc, col, e.key_ptr.*, e.value_ptr.*));
    }
    return .{ .object = out };
}

fn coerceFieldValue(alloc: std.mem.Allocator, col: schema.Collection, key: []const u8, v: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    const f = schema.fieldByName(col, key) orelse return v;
    if (v != .string) return v;
    const s = v.string;
    switch (f.options) {
        .@"bool" => {
            if (s.len == 0) return .null; // multipart "" = clear
            if (std.mem.eql(u8, s, "true")) return .{ .bool = true };
            if (std.mem.eql(u8, s, "false")) return .{ .bool = false };
            return v;
        },
        .number => |o| {
            if (s.len == 0) return .null; // multipart "" = clear (all modes)
            if (o.mode != .float) return v; // int/fixed: strings are the accepted JSON form
            const x = std.fmt.parseFloat(f64, s) catch return v;
            if (!std.math.isFinite(x)) return v; // JSON can't carry nan/inf; let validation reject
            return .{ .float = x };
        },
        .json => {
            if (s.len == 0) return .null; // multipart "" = clear
            // Leaked into the arena deliberately (the codebase-wide pattern for parse trees).
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, s, .{}) catch return v;
            return parsed.value;
        },
        .select, .relation => {
            if (!f.isMultiValue()) return v;
            if (s.len == 0) return .null; // multipart "" = clear
            if (std.json.parseFromSlice(std.json.Value, alloc, s, .{})) |parsed| {
                if (parsed.value == .array) return parsed.value;
            } else |_| {}
            // A single occurrence (-F tags=x) wraps as a one-element array of the
            // ORIGINAL string, mirroring how repeated keys arrive as string arrays.
            var arr = std.json.Array.init(alloc);
            try arr.append(v);
            return .{ .array = arr };
        },
        else => return v,
    }
}

// ---------------------------------------------------------------------------
// Multipart coercion tests (TDD: written before coerceFormFields exists).
// Multipart values are all strings; coercion makes them look like a
// well-formed JSON client per the collection schema, BEFORE validation.
// ---------------------------------------------------------------------------

fn coerceCol() schema.Collection {
    const S = struct {
        const fields = [_]schema.Field{
            .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
            .{ .id = "f3", .name = "ratio", .options = .{ .number = .{ .mode = .float } } },
            .{ .id = "f4", .name = "qty", .options = .{ .number = .{ .mode = .int } } },
            .{ .id = "f5", .name = "flag", .options = .{ .@"bool" = .{} } },
            .{ .id = "f6", .name = "tags", .options = .{ .select = .{ .values = &.{ "x", "y" }, .maxSelect = 3 } } },
            .{ .id = "f7", .name = "status", .options = .{ .select = .{ .values = &.{ "a", "b" }, .maxSelect = 1 } } },
            .{ .id = "f8", .name = "meta", .options = .{ .json = .{} } },
            .{ .id = "f9", .name = "photos", .options = .{ .file = .{ .maxSelect = 3 } } },
        };
    };
    return .{ .id = "c", .name = "things", .fields = &S.fields };
}

fn coerceOneField(a: std.mem.Allocator, key: []const u8, s: []const u8) !std.json.Value {
    var data: std.json.ObjectMap = .empty;
    try data.put(a, key, .{ .string = s });
    const out = try coerceFormFields(a, coerceCol(), .{ .object = data });
    return out.object.get(key).?;
}

test "coerce: text keeps scalar-looking strings verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "123", "true", "false", "b", "007", "+15551234" }) |s| {
        const v = try coerceOneField(a, "title", s);
        try std.testing.expect(v == .string);
        try std.testing.expectEqualStrings(s, v.string);
    }
}

test "coerce: bool 'true'/'false' become JSON bools; anything else is left alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(true, (try coerceOneField(a, "flag", "true")).bool);
    try std.testing.expectEqual(false, (try coerceOneField(a, "flag", "false")).bool);
    const odd = try coerceOneField(a, "flag", "yes");
    try std.testing.expect(odd == .string);
}

test "coerce: float mode parses to a JSON float; unparseable/non-finite stays string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try coerceOneField(a, "ratio", "45.00");
    try std.testing.expectApproxEqAbs(@as(f64, 45.0), v.float, 0.0001);
    try std.testing.expect((try coerceOneField(a, "ratio", "abc")) == .string);
    try std.testing.expect((try coerceOneField(a, "ratio", "nan")) == .string);
    try std.testing.expect((try coerceOneField(a, "ratio", "inf")) == .string);
}

test "coerce: int/fixed number modes keep the decimal string (the accepted JSON form)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try coerceOneField(a, "price", "45.00");
    try std.testing.expectEqualStrings("45.00", p.string);
    const q = try coerceOneField(a, "qty", "42");
    try std.testing.expectEqualStrings("42", q.string);
}

test "coerce: multi-select JSON-array string becomes an array; single select stays a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try coerceOneField(a, "tags", "[\"x\",\"y\"]");
    try std.testing.expect(v == .array);
    try std.testing.expectEqual(@as(usize, 2), v.array.items.len);
    try std.testing.expectEqualStrings("x", v.array.items[0].string);
    // single-valued select: a JSON-looking string is the literal value
    const sv = try coerceOneField(a, "status", "[\"a\"]");
    try std.testing.expect(sv == .string);
}

test "coerce: a single plain value for a multi-value field wraps as a one-element array of the ORIGINAL string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // -F tags=x (one occurrence) must behave like ["x"], matching -F tags=x -F tags=y
    const v = try coerceOneField(a, "tags", "x");
    try std.testing.expect(v == .array);
    try std.testing.expectEqual(@as(usize, 1), v.array.items.len);
    try std.testing.expectEqualStrings("x", v.array.items[0].string);
    // valid-JSON-but-not-array strings wrap the ORIGINAL string, never the parsed value
    const n = try coerceOneField(a, "tags", "123");
    try std.testing.expect(n == .array);
    try std.testing.expectEqualStrings("123", n.array.items[0].string);
    const b = try coerceOneField(a, "tags", "true");
    try std.testing.expect(b == .array);
    try std.testing.expectEqualStrings("true", b.array.items[0].string);
}

test "coerce: an empty multipart value clears optional non-text fields to null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // bool, number (all modes), json, and multi-value fields: "" -> null
    try std.testing.expect((try coerceOneField(a, "flag", "")) == .null);
    try std.testing.expect((try coerceOneField(a, "price", "")) == .null);
    try std.testing.expect((try coerceOneField(a, "qty", "")) == .null);
    try std.testing.expect((try coerceOneField(a, "ratio", "")) == .null);
    try std.testing.expect((try coerceOneField(a, "meta", "")) == .null);
    try std.testing.expect((try coerceOneField(a, "tags", "")) == .null);
    // text-like and single select keep "" (their JSON form accepts it)
    const tv = try coerceOneField(a, "title", "");
    try std.testing.expect(tv == .string and tv.string.len == 0);
    const sv = try coerceOneField(a, "status", "");
    try std.testing.expect(sv == .string and sv.string.len == 0);
}

test "coerce: json field parses any valid JSON; invalid stays string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const obj = try coerceOneField(a, "meta", "{\"a\":1}");
    try std.testing.expect(obj == .object);
    try std.testing.expectEqual(@as(i64, 1), obj.object.get("a").?.integer);
    try std.testing.expectEqual(true, (try coerceOneField(a, "meta", "true")).bool);
    try std.testing.expect((try coerceOneField(a, "meta", "not json")) == .string);
}

test "coerce: non-schema keys (removal/auth) and non-string values pass through untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "photos-", .{ .string = "[\"old.jpg\"]" });
    try data.put(a, "password", .{ .string = "true" });
    try data.put(a, "passwordConfirm", .{ .string = "true" });
    var arr = std.json.Array.init(a);
    try arr.append(.{ .string = "x" });
    try data.put(a, "tags", .{ .array = arr });
    const out = try coerceFormFields(a, coerceCol(), .{ .object = data });
    try std.testing.expectEqualStrings("[\"old.jpg\"]", out.object.get("photos-").?.string);
    try std.testing.expectEqualStrings("true", out.object.get("password").?.string);
    try std.testing.expectEqualStrings("true", out.object.get("passwordConfirm").?.string);
    try std.testing.expect(out.object.get("tags").? == .array);
}

test "coerce: file field values are untouched (the file plan owns them)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try coerceOneField(a, "photos", "[\"a.jpg\"]");
    try std.testing.expect(v == .string);
}

test "coerce: non-object data is returned as-is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try coerceFormFields(a, coerceCol(), .{ .string = "nope" });
    try std.testing.expect(out == .string);
}

pub fn create(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, col: schema.Collection, data: std.json.Value) RecordError!std.json.Value {
    return createImpl(alloc, io, w, col, data, null);
}

pub fn createGuarded(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, col: schema.Collection, data: std.json.Value, guard: Guard) RecordError!std.json.Value {
    return createImpl(alloc, io, w, col, data, guard);
}

fn createImpl(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, col: schema.Collection, data: std.json.Value, guard: ?Guard) RecordError!std.json.Value {
    last_errors = null;
    if (data != .object) return error.NotObject;
    var errs: std.ArrayList(schema.ValidationError) = .empty;

    var cols: std.ArrayList(u8) = .empty;
    var vals: std.ArrayList(u8) = .empty;
    try cols.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    try vals.appendSlice(alloc, "?1,strftime('%Y-%m-%dT%H:%M:%SZ','now'),strftime('%Y-%m-%dT%H:%M:%SZ','now')");

    var binds: std.ArrayList(BindItem) = .empty;
    var next: usize = 2;
    for (col.fields) |f| {
        const provided = data.object.get(f.name);
        // autodate is server-set, so it must be handled before the required check
        // (a required autodate field correctly receives no client value).
        if (f.fieldType() == .autodate) {
            try cols.append(alloc, ',');
            try cols.appendSlice(alloc, try ddl.quoteIdent(alloc, f.name));
            try vals.append(alloc, ',');
            try vals.appendSlice(alloc, if (f.options.autodate.onCreate) "strftime('%Y-%m-%dT%H:%M:%SZ','now')" else "NULL");
            continue;
        }
        if (f.required and (provided == null or isEmpty(provided.?))) {
            try errs.append(alloc, .{ .field = f.name, .code = "validation_required", .message = "Missing required value." });
            continue;
        }
        if (provided) |pv| {
            try validateFieldValue(alloc, w, f, pv, &errs);
            try cols.append(alloc, ',');
            try cols.appendSlice(alloc, try ddl.quoteIdent(alloc, f.name));
            try vals.append(alloc, ',');
            try vals.appendSlice(alloc, try std.fmt.allocPrint(alloc, "?{d}", .{next}));
            try binds.append(alloc, .{ .idx = @intCast(next), .field = f, .value = pv });
            next += 1;
        }
    }
    if (errs.items.len > 0) {
        last_errors = errs.items;
        return error.Validation;
    }

    const rcols = try columnList(alloc, col);
    var gen_id = id_gen.collectionId(io);

    if (guard != null) try w.begin();
    errdefer if (guard != null) {
        w.rollback() catch {};
    };

    const sql = try std.fmt.allocPrintSentinel(alloc, "INSERT INTO \"{s}\" ({s}) VALUES ({s}) RETURNING {s};", .{ col.name, cols.items, vals.items, rcols }, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, &gen_id);
    for (binds.items) |b| {
        values.bindValue(alloc, &st, b.idx, b.field, b.value) catch |e| {
            try errs.append(alloc, .{ .field = b.field.name, .code = convCode(e), .message = "Invalid value." });
            last_errors = errs.items;
            return error.Validation;
        };
    }
    if (!try st.step()) return error.NotFound;
    const rec = try rowToObject(alloc, &st, col);
    while (try st.step()) {} // drain to DONE so the statement isn't active at commit time
    if (guard) |g| {
        if (!try guardPasses(alloc, w, col, &gen_id, g)) {
            return error.Forbidden;
        }
        try w.commit();
    }
    return rec;
}

fn seedPosts(d: *db.Db, a: std.mem.Allocator) !schema.Collection {
    try migrations.run(d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    return collections.create(a, std.testing.io, d, .{ .id = "", .name = "posts", .fields = &fields });
}

test "get returns a record as a JSON object with typed values" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','hello',1050);");
    const rec = (try get(a, &d, col, "r1")).?;
    try std.testing.expectEqualStrings("r1", rec.object.get("id").?.string);
    try std.testing.expectEqualStrings("hello", rec.object.get("title").?.string);
    try std.testing.expectEqualStrings("10.50", rec.object.get("price").?.string);
    try std.testing.expect((try get(a, &d, col, "nope")) == null);
}

test "create inserts a record, sets id/timestamps, returns it" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "hi" });
    try data.put(a, "price", .{ .string = "3.25" });
    const rec = try create(a, std.testing.io, &d, col, .{ .object = data });
    try std.testing.expectEqual(@as(usize, 15), rec.object.get("id").?.string.len);
    try std.testing.expect(rec.object.get("created").?.string.len > 0);
    try std.testing.expectEqualStrings("hi", rec.object.get("title").?.string);
    try std.testing.expectEqualStrings("3.25", rec.object.get("price").?.string);
}

test "create rejects an over-precise fixed value with a field error" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "price", .{ .string = "1.999" });
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, col, .{ .object = data }));
    try std.testing.expect(last_errors != null and last_errors.?.len >= 1);
}

test "create rejects a missing required field" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{.{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } }};
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &fields });
    const data: std.json.ObjectMap = .empty;
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, col, .{ .object = data }));
}

test "create rejects a value outside a select's allowed set" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{.{ .id = "f1", .name = "status", .options = .{ .select = .{ .values = &.{ "open", "closed" }, .maxSelect = 1 } } }};
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "tickets", .fields = &fields });
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "status", .{ .string = "banana" });
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, col, .{ .object = data }));
}

// ---------------------------------------------------------------------------
// Field-constraint enforcement tests (TDD; Bug 3). The schema stores
// text min/max, number min/max, and date min/max, but validateFieldValue
// never enforced them.
// ---------------------------------------------------------------------------

fn seedConstrained(d: *db.Db, a: std.mem.Allocator) !schema.Collection {
    try migrations.run(d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{ .min = 2, .max = 5 } } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2, .min = 0, .max = 100 } } },
        .{ .id = "f3", .name = "seats", .options = .{ .number = .{ .mode = .int, .min = 1, .max = 8 } } },
        .{ .id = "f4", .name = "ratio", .options = .{ .number = .{ .mode = .float, .min = 0, .max = 1 } } },
        .{ .id = "f5", .name = "when", .options = .{ .date = .{ .min = "2026-01-01 00:00:00", .max = "2026-12-31 23:59:59" } } },
        .{ .id = "f6", .name = "slug", .options = .{ .text = .{ .pattern = "^[a-z0-9-]+$" } } },
    };
    return collections.create(a, std.testing.io, d, .{ .id = "", .name = "limits", .fields = &fields });
}

fn expectFieldCode(field: []const u8, code: []const u8) !void {
    const errs = last_errors orelse return error.TestExpectedEqual;
    for (errs) |e| {
        if (std.mem.eql(u8, e.field, field) and std.mem.eql(u8, e.code, code)) return;
    }
    return error.TestExpectedEqual;
}

fn createOne(a: std.mem.Allocator, d: *db.Db, col: schema.Collection, key: []const u8, v: std.json.Value) RecordError!std.json.Value {
    var data: std.json.ObjectMap = .empty;
    try data.put(a, key, v);
    return create(a, std.testing.io, d, col, .{ .object = data });
}

test "text min/max enforce unicode codepoint counts" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedConstrained(&d, a);
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "title", .{ .string = "a" }));
    try expectFieldCode("title", "validation_min");
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "title", .{ .string = "abcdef" }));
    try expectFieldCode("title", "validation_max");
    // "héllo" is 5 codepoints but 6 bytes: max=5 must count codepoints, not bytes
    _ = try createOne(a, &d, col, "title", .{ .string = "héllo" });
    _ = try createOne(a, &d, col, "title", .{ .string = "ab" });
}

test "email field rejects control chars (CRLF/NUL) and obviously-bogus addresses" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{.{ .id = "f1", .name = "contact", .options = .{ .email = .{} } }};
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "contacts", .fields = &fields });

    // CRLF injection attempt (would inject a Bcc header on outbound SMTP) is rejected.
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "victim@x.io\r\nBcc: spam@evil.com" }));
    try expectFieldCode("contact", "validation_invalid_email");
    // A bare newline, a space, and a NUL are each rejected.
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "a@b.io\nx" }));
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "a b@x.io" }));
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "a@b.io\x00" }));
    // Other ASCII control chars (TAB, vertical tab, form feed, DEL) are rejected too.
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "a\tb@x.io" }));
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "a@b.io\x0b" }));
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "a@b.io\x7f" }));
    // Structurally-bogus addresses are rejected.
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "no-at-sign" }));
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "@nolocal.io" }));
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "nodomain@" }));
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "contact", .{ .string = "two@at@x.io" }));
    // A normal address is accepted, and clearing (empty/null) stays possible.
    _ = try createOne(a, &d, col, "contact", .{ .string = "user@example.com" });
    _ = try createOne(a, &d, col, "contact", .{ .string = "" });
    _ = try createOne(a, &d, col, "contact", .null);
}

test "text min does not reject an explicitly empty optional value (clearing stays possible)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedConstrained(&d, a);
    _ = try createOne(a, &d, col, "title", .{ .string = "" });
    _ = try createOne(a, &d, col, "title", .null);
}

test "fixed-mode number min/max compare the decimal value" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedConstrained(&d, a);
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "price", .{ .string = "-1" }));
    try expectFieldCode("price", "validation_min");
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "price", .{ .string = "-0.01" }));
    try expectFieldCode("price", "validation_min");
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "price", .{ .string = "100.01" }));
    try expectFieldCode("price", "validation_max");
    _ = try createOne(a, &d, col, "price", .{ .string = "0" });
    _ = try createOne(a, &d, col, "price", .{ .string = "100.00" });
    _ = try createOne(a, &d, col, "price", .{ .string = "45.00" });
}

test "int-mode number min/max" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedConstrained(&d, a);
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "seats", .{ .string = "0" }));
    try expectFieldCode("seats", "validation_min");
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "seats", .{ .string = "9" }));
    try expectFieldCode("seats", "validation_max");
    _ = try createOne(a, &d, col, "seats", .{ .string = "1" });
    _ = try createOne(a, &d, col, "seats", .{ .string = "8" });
}

test "fixed-mode bound equality: a value textually equal to the f64 bound passes (divide semantics)" {
    // Pins the divide-based compare: "0.10" with min=0.1 must pass. Multiplying the
    // bound out instead (f64(0.1)*100 = 10.000000000000002 > sv=10) would false-reject.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "amt", .options = .{ .number = .{ .mode = .fixed, .scale = 2, .min = 0.1, .max = 0.3 } } },
    };
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "tenths", .fields = &fields });
    _ = try createOne(a, &d, col, "amt", .{ .string = "0.10" }); // == min
    _ = try createOne(a, &d, col, "amt", .{ .string = "0.30" }); // == max
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "amt", .{ .string = "0.09" }));
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "amt", .{ .string = "0.31" }));
}

test "int-mode bounds compare as f64: values beyond 2^53 lose precision (documented edge)" {
    // The schema stores min/max as f64, so bounds themselves cannot represent
    // integers above 2^53 exactly. 9007199254740993 (2^53+1) rounds to 2^53 when
    // compared, so a max of 9007199254740992 does NOT reject it. This is the
    // accepted behavior; exact enforcement would need decimal bounds in the schema.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "big", .options = .{ .number = .{ .mode = .int, .max = 9007199254740992.0 } } },
    };
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "bigints", .fields = &fields });
    _ = try createOne(a, &d, col, "big", .{ .string = "9007199254740993" });
}

test "float-mode number min/max (float and integer JSON values)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedConstrained(&d, a);
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "ratio", .{ .float = -0.5 }));
    try expectFieldCode("ratio", "validation_min");
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "ratio", .{ .float = 1.5 }));
    try expectFieldCode("ratio", "validation_max");
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "ratio", .{ .integer = 2 }));
    try expectFieldCode("ratio", "validation_max");
    _ = try createOne(a, &d, col, "ratio", .{ .float = 0.5 });
    _ = try createOne(a, &d, col, "ratio", .{ .integer = 1 });
}

test "date values are validated and min/max enforced" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedConstrained(&d, a); // "when": min 2026-01-01, max 2026-12-31
    // garbage is rejected
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "when", .{ .string = "2026-06-10 25:99:99" }));
    try expectFieldCode("when", "validation_date");
    // below min / above max rejected, across mixed formats
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "when", .{ .string = "2025-12-31 23:59:59" }));
    try expectFieldCode("when", "validation_min");
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "when", .{ .string = "2027-01-01T00:00:00Z" }));
    try expectFieldCode("when", "validation_max");
    // an in-range value in the canonical stored form is accepted
    _ = try createOne(a, &d, col, "when", .{ .string = "2026-06-10T08:00:00Z" });
}

test "text pattern is enforced" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedConstrained(&d, a);
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "slug", .{ .string = "Has Spaces" }));
    try expectFieldCode("slug", "validation_pattern");
    _ = try createOne(a, &d, col, "slug", .{ .string = "ok-slug-1" });
}

test "update enforces the same constraints" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedConstrained(&d, a);
    const rec = try createOne(a, &d, col, "price", .{ .string = "1.00" });
    const rid = rec.object.get("id").?.string;
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "price", .{ .string = "-1" });
    try std.testing.expectError(error.Validation, update(a, &d, col, rid, .{ .object = data }));
    try expectFieldCode("price", "validation_min");
}

pub fn update(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, id: []const u8, data: std.json.Value) RecordError!?std.json.Value {
    return updateImpl(alloc, w, col, id, data, null);
}

pub fn updateGuarded(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, id: []const u8, data: std.json.Value, guard: Guard) RecordError!?std.json.Value {
    return updateImpl(alloc, w, col, id, data, guard);
}

fn updateImpl(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, id: []const u8, data: std.json.Value, guard: ?Guard) RecordError!?std.json.Value {
    last_errors = null;
    if (data != .object) return error.NotObject;
    var errs: std.ArrayList(schema.ValidationError) = .empty;

    var sets: std.ArrayList(u8) = .empty;
    try sets.appendSlice(alloc, "\"updated\"=strftime('%Y-%m-%dT%H:%M:%SZ','now')");
    var binds: std.ArrayList(BindItem) = .empty;
    var next: usize = 2; // ?1 is the id in WHERE

    for (col.fields) |f| {
        if (f.fieldType() == .autodate) {
            if (f.options.autodate.onUpdate) {
                try sets.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"{s}\"=strftime('%Y-%m-%dT%H:%M:%SZ','now')", .{f.name}));
            }
            continue;
        }
        const provided = data.object.get(f.name) orelse continue; // partial: only provided fields
        try validateFieldValue(alloc, w, f, provided, &errs);
        try sets.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"{s}\"=?{d}", .{ f.name, next }));
        try binds.append(alloc, .{ .idx = @intCast(next), .field = f, .value = provided });
        next += 1;
    }
    if (errs.items.len > 0) { last_errors = errs.items; return error.Validation; }

    const rcols = try columnList(alloc, col);

    if (guard != null) try w.begin();
    errdefer if (guard != null) {
        w.rollback() catch {};
    };

    const sql = try std.fmt.allocPrintSentinel(alloc, "UPDATE \"{s}\" SET {s} WHERE \"id\"=?1 RETURNING {s};", .{ col.name, sets.items, rcols }, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id);
    for (binds.items) |b| {
        values.bindValue(alloc, &st, b.idx, b.field, b.value) catch |e| {
            try errs.append(alloc, .{ .field = b.field.name, .code = convCode(e), .message = "Invalid value." });
            last_errors = errs.items;
            return error.Validation;
        };
    }
    if (!try st.step()) {
        if (guard != null) w.rollback() catch {};
        return null;
    }
    const rec = try rowToObject(alloc, &st, col);
    while (try st.step()) {} // drain to DONE so the statement isn't active at commit time
    if (guard) |g| {
        if (!try guardPasses(alloc, w, col, id, g)) {
            return error.Forbidden;
        }
        try w.commit();
    }
    return rec;
}

pub fn delete(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, id: []const u8) RecordError!bool {
    const sql = try std.fmt.allocPrintSentinel(alloc, "DELETE FROM \"{s}\" WHERE \"id\"=?1 RETURNING \"id\";", .{col.name}, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id);
    return try st.step();
}

test "update merges provided fields, bumps updated, 404 on missing" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','t','t','old',100);");

    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "new" }); // price omitted -> unchanged
    const rec = (try update(a, &d, col, "r1", .{ .object = data })).?;
    try std.testing.expectEqualStrings("new", rec.object.get("title").?.string);
    try std.testing.expectEqualStrings("1.00", rec.object.get("price").?.string);

    const empty: std.json.ObjectMap = .empty;
    try std.testing.expect((try update(a, &d, col, "missing", .{ .object = empty })) == null);
}

test "update rejects an over-precise fixed value and leaves the row unchanged" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','t','t','keep',100);");

    var data: std.json.ObjectMap = .empty;
    try data.put(a, "price", .{ .string = "1.999" }); // scale=2 -> too precise
    try std.testing.expectError(error.Validation, update(a, &d, col, "r1", .{ .object = data }));
    try std.testing.expect(last_errors != null and last_errors.?.len >= 1);

    // The row must be untouched (price still "1.00", title still "keep").
    const rec = (try get(a, &d, col, "r1")).?;
    try std.testing.expectEqualStrings("keep", rec.object.get("title").?.string);
    try std.testing.expectEqualStrings("1.00", rec.object.get("price").?.string);
}

test "updateGuarded rolls back when the guard fails, preserving the original value" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','t','t','old',100);");

    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "new" });
    // Guard never matches -> the UPDATE inside the txn is rolled back.
    const guard = Guard{ .where_sql = "\"posts\".\"title\" = ?", .params = &.{.{ .text = "nope" }} };
    try std.testing.expectError(error.Forbidden, updateGuarded(a, &d, col, "r1", .{ .object = data }, guard));

    // Rollback worked: the original "old" title persists.
    const rec = (try get(a, &d, col, "r1")).?;
    try std.testing.expectEqualStrings("old", rec.object.get("title").?.string);
}

test "list clamps pagination bounds" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','t','t','a',1),('r2','t','t','b',2);");

    // perPage=0 -> default 30.
    {
        const res = try list(a, &d, col, .{ .perPage = 0 });
        try std.testing.expectEqual(@as(u32, 30), res.perPage);
    }
    // perPage above the cap is clamped to 500.
    {
        const res = try list(a, &d, col, .{ .perPage = 1000 });
        try std.testing.expectEqual(@as(u32, 500), res.perPage);
    }
    // page=0 -> normalized to 1.
    {
        const res = try list(a, &d, col, .{ .page = 0 });
        try std.testing.expectEqual(@as(u32, 1), res.page);
    }
}

test "delete removes the row; 404 on missing" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','t','t','x',1);");
    try std.testing.expect(try delete(a, &d, col, "r1"));
    try std.testing.expect(!try delete(a, &d, col, "r1"));
}

pub const ListQuery = struct {
    filter: ?[]const u8 = null,
    sort: ?[]const u8 = null,
    page: u32 = 1,
    perPage: u32 = 30,
    rule: ?[]const u8 = null,
    rctx: ?*const request.RequestContext = null,
};
pub const ListResult = struct { page: u32, perPage: u32, totalItems: i64, items: []std.json.Value };

fn baseColumnList(alloc: std.mem.Allocator, col: schema.Collection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\".\"id\",\"{s}\".\"created\",\"{s}\".\"updated\"", .{ col.name, col.name, col.name }));
    for (col.fields) |f| {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"{s}\".{s}", .{ col.name, try ddl.quoteIdent(alloc, f.name) }));
    }
    return out.toOwnedSlice(alloc);
}

pub fn list(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, q: ListQuery) !ListResult {
    if (q.filter) |fstr| if (fstr.len > max_filter_len) return error.BadFilter;
    if (q.sort) |sstr| if (sstr.len > max_filter_len) return error.BadSort;
    var j = joiner.Joiner.init(alloc, conn, col);
    var where_sql: []const u8 = "";
    var params: []const compiler.Param = &.{};
    if (q.filter) |fstr| if (fstr.len > 0) {
        const toks = try lexer.lex(alloc, fstr);
        const ast = try parser.parse(alloc, toks);
        const compiled = try compiler.compile(alloc, &j, ast, null);
        where_sql = compiled.where_sql;
        params = compiled.params;
    };
    if (q.rule) |rstr| if (rstr.len > 0) {
        const rtoks = try lexer.lex(alloc, rstr);
        const rast = try parser.parse(alloc, rtoks);
        const rc = try compiler.compile(alloc, &j, rast, q.rctx);
        if (where_sql.len > 0) {
            where_sql = try std.fmt.allocPrint(alloc, "({s}) AND ({s})", .{ where_sql, rc.where_sql });
        } else {
            where_sql = rc.where_sql;
        }
        var merged: std.ArrayList(compiler.Param) = .empty;
        try merged.appendSlice(alloc, params);
        try merged.appendSlice(alloc, rc.params);
        params = try merged.toOwnedSlice(alloc);
    };
    var order_sql: []const u8 = try std.fmt.allocPrint(alloc, "\"{s}\".\"created\" DESC", .{col.name});
    if (q.sort) |sstr| if (sstr.len > 0) {
        const ob = try sort.compile(alloc, &j, sstr);
        if (ob.len > 0) order_sql = ob;
    };
    var joins_sql: std.ArrayList(u8) = .empty;
    for (j.joins.items) |jn| { try joins_sql.append(alloc, ' '); try joins_sql.appendSlice(alloc, jn); }

    const where_clause = if (where_sql.len > 0) try std.fmt.allocPrint(alloc, " WHERE {s}", .{where_sql}) else "";

    const count_sql = try std.fmt.allocPrintSentinel(alloc, "SELECT COUNT(*) FROM \"{s}\"{s}{s};", .{ col.name, joins_sql.items, where_clause }, 0);
    var cst = try conn.prepare(count_sql);
    defer cst.finalize();
    _ = try bindParams(&cst, params, 1);
    _ = try cst.step();
    const total = cst.columnInt(0);

    const per: u32 = if (q.perPage == 0) 30 else @min(q.perPage, 500);
    const page: u32 = if (q.page == 0) 1 else q.page;
    const offset: i64 = @as(i64, (page - 1)) * @as(i64, per);
    const bcols = try baseColumnList(alloc, col);
    const page_sql = try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\"{s}{s} ORDER BY {s} LIMIT ? OFFSET ?;", .{ bcols, col.name, joins_sql.items, where_clause, order_sql }, 0);
    var pst = try conn.prepare(page_sql);
    defer pst.finalize();
    const after = try bindParams(&pst, params, 1);
    try pst.bindInt(after, @intCast(per));
    try pst.bindInt(after + 1, offset);

    var items: std.ArrayList(std.json.Value) = .empty;
    while (try pst.step()) try items.append(alloc, try rowToObject(alloc, &pst, col));
    return .{ .page = page, .perPage = per, .totalItems = total, .items = try items.toOwnedSlice(alloc) };
}

pub fn bindParams(st: *db.Stmt, params: []const compiler.Param, start: c_int) !c_int {
    var idx = start;
    for (params) |p| {
        switch (p) {
            .text => |t| try st.bindText(idx, t),
            .int => |n| try st.bindInt(idx, n),
            .double => |dv| try st.bindDouble(idx, dv),
        }
        idx += 1;
    }
    return idx;
}

test "list filters, sorts, and paginates" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a); // posts(title text, price fixed/2)
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','2026-01-01T00:00:00Z','t','aaa',100),('r2','2026-01-02T00:00:00Z','t','bbb',200),('r3','2026-01-03T00:00:00Z','t','ccc',300);");
    const res = try list(a, &d, col, .{ .filter = "price >= 2.00", .sort = "-created", .page = 1, .perPage = 1 });
    try std.testing.expectEqual(@as(i64, 2), res.totalItems);
    try std.testing.expectEqual(@as(usize, 1), res.items.len);
    try std.testing.expectEqualStrings("r3", res.items[0].object.get("id").?.string);
}

test "list rejects an over-long filter (DoS cap) before lexing" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    const big = try a.alloc(u8, max_filter_len + 1);
    @memset(big, '(');
    try std.testing.expectError(error.BadFilter, list(a, &d, col, .{ .filter = big }));
}

test "createGuarded rolls back when the guard fails" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "hi" });
    const guard = Guard{ .where_sql = "\"posts\".\"title\" = ?", .params = &.{.{ .text = "nope" }} };
    try std.testing.expectError(error.Forbidden, createGuarded(a, std.testing.io, &d, col, .{ .object = data }, guard));
    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "createGuarded commits when the guard passes" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "hi" });
    const guard = Guard{ .where_sql = "\"posts\".\"title\" = ?", .params = &.{.{ .text = "hi" }} };
    const rec = try createGuarded(a, std.testing.io, &d, col, .{ .object = data }, guard);
    try std.testing.expectEqualStrings("hi", rec.object.get("title").?.string);
}

test "list applies a rule clause AND-ed with the filter" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','t','t','keep',100),('r2','t','t','drop',100);");
    const res = try list(a, &d, col, .{ .rule = "title = \"keep\"" });
    try std.testing.expectEqual(@as(i64, 1), res.totalItems);
    try std.testing.expectEqualStrings("r1", res.items[0].object.get("id").?.string);
}
