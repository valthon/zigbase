const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");
const values = @import("values.zig");
const ddl = @import("ddl.zig");
const id_gen = @import("id.zig");
const clock = @import("clock.zig");
const compiler = @import("query/compiler.zig");
const lexer = @import("query/lexer.zig");
const parser = @import("query/parser.zig");
const joiner = @import("query/joiner.zig");
const sort = @import("query/sort.zig");
const request = @import("request.zig");
const keyset = @import("query/keyset.zig");
const pagination = @import("pagination.zig");
const regex = @import("regex.zig");
const datetime = @import("datetime.zig");
const field_policy = @import("field_policy.zig");
const tenancy = @import("tenancy/tenancy.zig");
const abilities = @import("authz/abilities.zig");
const fts = @import("search/fts.zig");
const vector = @import("search/vector.zig");
const param_sink = @import("sql/param_sink.zig");

/// Renumber a statement's placeholders for `h`'s active backend before preparing it: SQLite gets
/// the verbatim `?`/`?N` SQL (zero-cost — the same slice), Postgres gets `$n` matching the
/// positional bind order (`sql/param_sink.zig`). Every CRUD/query `prepare` of a placeholder-
/// bearing statement in this file routes through here so the `$n` rework has one chokepoint.
fn prep(alloc: std.mem.Allocator, h: *db.Db, sql: [:0]const u8) !db.Stmt {
    const renumbered = try param_sink.renumberZ(alloc, db.dbDialect(h), sql);
    // SQLite returns `sql` itself (same pointer, no allocation); Postgres allocates a fresh
    // `$n` string. `prepare` copies the statement text, so the Postgres allocation is scratch
    // that can be freed immediately — free it here so every `prep` caller stays leak-correct
    // under a non-arena allocator instead of each leaking one rewritten string per statement.
    defer if (renumbered.ptr != sql.ptr) alloc.free(renumbered);
    return h.prepare(renumbered);
}

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
/// Public so an HTTP handler that owns the write transaction can evaluate the
/// access-rule guard inside that same transaction (see api/records.zig).
pub fn guardPasses(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, rid: []const u8, g: Guard) !bool {
    const js = try guardJoinsSql(alloc, g.joins);
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT 1 FROM \"{s}\"{s} WHERE \"{s}\".\"id\"=?1 AND ({s});", .{ col.name, js, col.name, g.where_sql }, 0);
    var st = try prep(alloc, w, sql);
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

pub const RecordError = error{ Validation, NotFound, NotObject, Forbidden, InvalidId } ||
    db.DbError || values.ValueError || ReadError || CollectionsGetError;

/// Options for the low-level create path. `allow_provided_id` is **import-only**: the
/// offline bulk-import (`src/import.zig`) sets it so a source record's own `id` is
/// preserved (relations across an exported dataset stay intact). Every HTTP / route /
/// hook create path leaves it false — the public `create`/`createInTxn` wrappers pass
/// `.{}` — so a client can NEVER supply a record id; the server always generates one.
/// Do not thread this flag to any request-facing caller.
pub const CreateOpts = struct { allow_provided_id: bool = false };

/// Sanity gate for an import-preserved record id: non-empty, at most 255 bytes, and
/// every byte a printable, non-space ASCII character (URL/JSON-safe). This is NOT the
/// id GENERATOR's alphabet — an imported dataset may carry ids minted by another
/// system — and NOT the injection barrier (the id binds as a `?1` parameter, never
/// interpolated). It only rejects obviously-bogus ids (control chars, whitespace,
/// absurd length) before they land in the primary key.
pub fn isPlausibleRecordId(s: []const u8) bool {
    if (s.len == 0 or s.len > 255) return false;
    for (s) |ch| {
        if (ch <= ' ' or ch >= 127) return false;
    }
    return true;
}

/// Hard cap on the length of an attacker-supplied `?filter=`/`?sort=` string. Rejected
/// before lexing so a giant or deeply-nested expression can't exhaust CPU/stack.
pub const max_filter_len = 4096;

fn columnList(alloc: std.mem.Allocator, col: schema.Collection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "\"id\",\"created\",\"updated\"");
    for (col.fields) |f| {
        try out.append(alloc, ',');
        const q = try ddl.quoteIdent(alloc, f.name);
        defer alloc.free(q); // quoteIdent's buffer is copied into `out`; free the temporary
        try out.appendSlice(alloc, q);
    }
    return out.toOwnedSlice(alloc);
}

fn rowToObject(alloc: std.mem.Allocator, stmt: *db.Stmt, col: schema.Collection) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    // Pre-size for id/created/updated + every field so the map backing is allocated once
    // instead of reallocating as it grows per `put` — fewer, larger allocations on the read
    // hot path (hidden fields are a slight over-estimate, which only wastes a little capacity).
    try obj.ensureTotalCapacity(alloc, 3 + col.fields.len);
    try obj.put(alloc, "id", .{ .string = try alloc.dupe(u8, stmt.columnText(0)) });
    try obj.put(alloc, "created", .{ .string = try alloc.dupe(u8, stmt.columnText(1)) });
    try obj.put(alloc, "updated", .{ .string = try alloc.dupe(u8, stmt.columnText(2)) });
    for (col.fields, 0..) |f, i| {
        const v = try values.readValue(alloc, stmt, @intCast(3 + i), f);
        if (!f.hidden) try obj.put(alloc, f.name, v);
    }
    return .{ .object = obj };
}

/// Like `rowToObject`, but encrypted fields are returned as their AT-REST ciphertext envelope
/// (NEVER decrypted) instead of plaintext. Every other field reads identically. Backs `getAtRest`.
fn rowToObjectAtRest(alloc: std.mem.Allocator, stmt: *db.Stmt, col: schema.Collection) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    // Pre-size for id/created/updated + every field so the map backing is allocated once
    // instead of reallocating as it grows per `put` — fewer, larger allocations on the read
    // hot path (hidden fields are a slight over-estimate, which only wastes a little capacity).
    try obj.ensureTotalCapacity(alloc, 3 + col.fields.len);
    try obj.put(alloc, "id", .{ .string = try alloc.dupe(u8, stmt.columnText(0)) });
    try obj.put(alloc, "created", .{ .string = try alloc.dupe(u8, stmt.columnText(1)) });
    try obj.put(alloc, "updated", .{ .string = try alloc.dupe(u8, stmt.columnText(2)) });
    for (col.fields, 0..) |f, i| {
        const idx: c_int = @intCast(3 + i);
        const v: std.json.Value = if (f.encrypted)
            // At-rest envelope verbatim (or NULL) — no decryption, so a captured snapshot holds no
            // plaintext. Authz compares the ciphertext column on the live path too, so this stays
            // consistent for the (nonsensical) case of a rule referencing an encrypted field.
            (if (stmt.isNull(idx)) std.json.Value{ .null = {} } else std.json.Value{ .string = try alloc.dupe(u8, stmt.columnText(idx)) })
        else
            try values.readValue(alloc, stmt, idx, f);
        if (!f.hidden) try obj.put(alloc, f.name, v);
    }
    return .{ .object = obj };
}

/// Read a row WITHOUT decrypting its encrypted fields (they come back as the at-rest ciphertext
/// envelope). Used by the cross-instance realtime DELETE path (#159, PR-6b) to capture a snapshot
/// that holds NO decrypted plaintext: the snapshot transits a side table (not the NOTIFY wire) and
/// is used only for the receiving instance's delete authz — which, like the live create/update
/// path, compares the at-rest (ciphertext) column. No TTL filter (the row is live, captured
/// pre-delete inside the delete transaction).
pub fn getAtRest(alloc: std.mem.Allocator, r: *db.Db, col: schema.Collection, id: []const u8) !?std.json.Value {
    const cols = try columnList(alloc, col);
    defer alloc.free(cols);
    if (!schema.isValidIdentifier(col.name)) return null; // identifier gate before interpolation
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\" WHERE \"id\" = ?1;", .{ cols, col.name }, 0);
    defer alloc.free(sql);
    var st = try prep(alloc, r, sql);
    defer st.finalize();
    try st.bindText(1, id);
    if (!try st.step()) return null;
    return try rowToObjectAtRest(alloc, &st, col);
}

pub fn get(alloc: std.mem.Allocator, r: *db.Db, col: schema.Collection, id: []const u8) RecordError!?std.json.Value {
    const cols = try columnList(alloc, col);
    defer alloc.free(cols);
    // TTL read-time exclusion: never return an expired row. Mirrors gcExpiredRecords: both
    // sides are normalised via strftime so non-canonical date values (offsets, space, date-
    // only) compare correctly as instants, not lexically. The three-clause OR matches the
    // GC's fail-safe: NULL ttl → no expiry (always shown); strftime(tf) IS NULL means an
    // unparseable value → fail-safe, keep visible (same as GC which won't delete garbage).
    // Security: identifiers gated through isValidIdentifier before interpolation.
    const dialect = db.dbDialect(r);
    const sql = blk: {
        if (col.options.ttl_field) |tf| {
            if (schema.isValidIdentifier(col.name) and schema.isValidIdentifier(tf)) {
                const qtf = try std.fmt.allocPrint(alloc, "\"{s}\"", .{tf});
                defer alloc.free(qtf);
                const ttl_pred = try dialect.ttlVisiblePredicate(alloc, qtf);
                defer alloc.free(ttl_pred);
                break :blk try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\" WHERE \"id\" = ?1 AND ({s});", .{ cols, col.name, ttl_pred }, 0);
            }
        }
        break :blk try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\" WHERE \"id\" = ?1;", .{ cols, col.name }, 0);
    };
    defer alloc.free(sql);
    var st = try prep(alloc, r, sql);
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
                // so this is defense in depth. An allocator failure (OutOfMemory) is
                // propagated, not masqueraded as an invalid-pattern validation error.
                if (regex.compile(alloc, pat)) |prog| {
                    defer prog.deinit(alloc);
                    if (!regex.matches(prog, v.string))
                        try errs.append(alloc, .{ .field = f.name, .code = "validation_pattern", .message = "Value does not match the required pattern." });
                } else |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
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
            if (countValues(v) > o.maxSelect) {
                try errs.append(alloc, .{ .field = f.name, .code = "validation_select", .message = "Too many values." });
                return; // reject on count; skip the per-value scan so an over-limit array can't drive unbounded work
            }
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
            if (countValues(v) > o.maxSelect) {
                try errs.append(alloc, .{ .field = f.name, .code = "validation_relation", .message = "Too many relations." });
                return; // reject on count BEFORE the per-element existence SELECTs, so an over-limit
                // array can't drive N writer-lock queries from already-invalid input
            }
            // The target collection load and per-element existence SQL are scratch that never
            // escapes; reclaim them via a child arena so validation stays leak-correct under a
            // non-arena allocator. `errs` still escapes on `alloc` (read after return).
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            const sa = scratch.allocator();
            const tcol = (try collections.get(sa, conn, o.targetCollectionId)) orelse {
                try errs.append(alloc, .{ .field = f.name, .code = "validation_relation", .message = "Relation target missing." });
                return;
            };
            const items: []const std.json.Value = switch (v) {
                .array => |arr| arr.items,
                .string => &.{v},
                else => &.{},
            };
            for (items) |it| if (it == .string) {
                const q = try std.fmt.allocPrintSentinel(sa, "SELECT 1 FROM \"{s}\" WHERE \"id\" = ?1;", .{tcol.name}, 0);
                var st = try prep(sa, conn, q);
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
        .bool => {
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
            .{ .id = "f5", .name = "flag", .options = .{ .bool = .{} } },
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
    return createInTxnOpts(alloc, io, w, col, data, .{});
}

/// Insert a record on `w` WITHOUT opening a transaction. The caller must already
/// be inside one (or accept autocommit). Applies the same column/JSON handling as
/// the former createImpl but performs no begin/commit/guard. The server always
/// generates the record id (a client-supplied `id` is ignored) — see `createInTxnOpts`.
pub fn createInTxn(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, col: schema.Collection, data: std.json.Value) RecordError!std.json.Value {
    return createInTxnOpts(alloc, io, w, col, data, .{});
}

/// The single insert implementation behind `create`/`createInTxn`. `opts.allow_provided_id`
/// is **import-only** (see `CreateOpts`): when set AND `data` carries a non-empty string
/// `"id"`, that id is preserved (after `isPlausibleRecordId` validation) instead of
/// generating one. With the default `.{}` a client-supplied `id` is silently ignored and
/// the server generates the id — the invariant every HTTP/route/hook create relies on.
pub fn createInTxnOpts(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, col: schema.Collection, data: std.json.Value, opts: CreateOpts) RecordError!std.json.Value {
    last_errors = null;
    if (data != .object) return error.NotObject;
    // `errs` escapes via `last_errors` (read by the API layer after this returns), so it stays on
    // `alloc`. Everything else here — the column/value/bind lists, the quoted identifiers, the
    // INSERT SQL — is scratch that never leaves this call; route it through a child arena so the
    // insert path is leak-correct under any allocator (the returned record is the only other
    // allocation kept on `alloc`).
    var errs: std.ArrayList(schema.ValidationError) = .empty;
    errdefer errs.deinit(alloc); // handed to the caller via last_errors as an OWNED slice; freed here on the OOM edge
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const dialect = db.dbDialect(w);
    const now_iso = dialect.nowIso8601Expr();

    var cols: std.ArrayList(u8) = .empty;
    var vals: std.ArrayList(u8) = .empty;
    try cols.appendSlice(sa, "\"id\",\"created\",\"updated\"");
    try vals.appendSlice(sa, try std.fmt.allocPrint(sa, "?1,{s},{s}", .{ now_iso, now_iso }));

    var binds: std.ArrayList(BindItem) = .empty;
    var next: usize = 2;
    for (col.fields) |f| {
        const provided = data.object.get(f.name);
        // autodate is server-set, so it must be handled before the required check
        // (a required autodate field correctly receives no client value).
        if (f.fieldType() == .autodate) {
            try cols.append(sa, ',');
            try cols.appendSlice(sa, try ddl.quoteIdent(sa, f.name));
            try vals.append(sa, ',');
            try vals.appendSlice(sa, if (f.options.autodate.onCreate) now_iso else "NULL");
            continue;
        }
        if (f.required and (provided == null or isEmpty(provided.?))) {
            try errs.append(alloc, .{ .field = f.name, .code = "validation_required", .message = "Missing required value." });
            continue;
        }
        if (provided) |pv| {
            try validateFieldValue(alloc, w, f, pv, &errs);
            try cols.append(sa, ',');
            try cols.appendSlice(sa, try ddl.quoteIdent(sa, f.name));
            try vals.append(sa, ',');
            try vals.appendSlice(sa, try std.fmt.allocPrint(sa, "?{d}", .{next}));
            try binds.append(sa, .{ .idx = @intCast(next), .field = f, .value = pv });
            next += 1;
        }
    }
    if (errs.items.len > 0) {
        last_errors = try errs.toOwnedSlice(alloc);
        return error.Validation;
    }

    const rcols = try columnList(sa, col);
    // The id bound at ?1. Default: a freshly-generated id (client `id` ignored). Import-only:
    // when `opts.allow_provided_id` is set the source record's own non-empty `id` is preserved
    // (validated by isPlausibleRecordId first). `gen_id` outlives the bind/step below.
    const gen_id = id_gen.collectionId(io);
    var id_slice: []const u8 = &gen_id;
    if (opts.allow_provided_id) {
        if (data.object.get("id")) |idv| {
            if (idv == .string and idv.string.len > 0) {
                if (!isPlausibleRecordId(idv.string)) return error.InvalidId;
                id_slice = idv.string;
            }
        }
    }

    const sql = try std.fmt.allocPrintSentinel(sa, "INSERT INTO \"{s}\" ({s}) VALUES ({s}) RETURNING {s};", .{ col.name, cols.items, vals.items, rcols }, 0);
    var st = try prep(sa, w, sql);
    defer st.finalize();
    try st.bindText(1, id_slice);
    for (binds.items) |b| {
        values.bindValue(sa, &st, b.idx, b.field, b.value) catch |e| {
            try errs.append(alloc, .{ .field = b.field.name, .code = convCode(e), .message = "Invalid value." });
            last_errors = try errs.toOwnedSlice(alloc);
            return error.Validation;
        };
    }
    if (!try st.step()) return error.NotFound;
    const rec = try rowToObject(alloc, &st, col);
    while (try st.step()) {} // drain to DONE so the statement isn't active at commit time
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

/// Free a record whose values are all scalar strings (id/created/updated + text fields). Keys are
/// static ("id"/…) or borrowed from the collection schema, so only the string values and the map
/// backing are owned. Used by the leak-detection regression test below.
fn freeStringRecord(a: std.mem.Allocator, rec: std.json.Value) void {
    var obj = rec.object;
    var it = obj.iterator();
    while (it.next()) |e| if (e.value_ptr.* == .string) a.free(e.value_ptr.*.string);
    obj.deinit(a);
}

test "write path frees its DDL/SQL scratch under the checking allocator" {
    // The whole point: run create + record-insert + read (hit and miss) under the RAW
    // leak-detecting std.testing.allocator, with NO arena to mask leaks. Any column-list, DDL,
    // INSERT/SELECT or placeholder-rewrite scratch the write path failed to free is reported as a
    // leak here. This is the regression guard for the allocator-ownership fix — before it, one
    // `create` here surfaced ~30 leaked allocations.
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    // A base collection with a literal field def: create() returns a fully-owned reload (every
    // string/slice on `a`), so it is freed with a single Collection.deinit.
    const fields = [_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }};
    const def = schema.Collection{ .id = "", .name = "posts", .fields = &fields, .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "" };
    const full = try collections.create(a, std.testing.io, &d, def);
    defer full.deinit(a);
    try std.testing.expectEqual(@as(usize, 15), full.id.len);

    // Insert a record. rowToObject's result is the only allocation kept on `a`; free it by hand.
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "hello" });
    const rec = try create(a, std.testing.io, &d, full, .{ .object = data });
    data.deinit(a);
    const rid = try a.dupe(u8, rec.object.get("id").?.string);
    defer a.free(rid);
    freeStringRecord(a, rec);

    // Read the row back (exercises get()'s column-list + SELECT scratch and rowToObject).
    const got = (try get(a, &d, full, rid)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", got.object.get("title").?.string);
    freeStringRecord(a, got);

    // Update it (exercises updateInTxn's SET-list/bind/UPDATE-SQL scratch; the returned record is
    // the only allocation kept on `a`).
    var udata: std.json.ObjectMap = .empty;
    try udata.put(a, "title", .{ .string = "world" });
    const upd = (try update(a, &d, full, rid, .{ .object = udata })) orelse return error.TestUnexpectedResult;
    udata.deinit(a);
    try std.testing.expectEqualStrings("world", upd.object.get("title").?.string);
    freeStringRecord(a, upd);

    // Read-miss paths allocate their SQL scratch but return null (no row/collection to free) — so a
    // leak here can only be that unfreed scratch.
    try std.testing.expect((try get(a, &d, full, "missingid0000000")) == null);
    try std.testing.expect((try collections.get(a, &d, "no-such-collection")) == null);

    // Delete frees its DELETE SQL scratch; returns a bool (nothing to free).
    try std.testing.expect(try delete(a, &d, full, rid));
    try std.testing.expect(!try delete(a, &d, full, "missingid0000000"));
}

test "createInTxnOpts: default IGNORES a client-supplied id (server always generates)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "id", .{ .string = "client-forced-id" });
    try obj.put(a, "title", .{ .string = "hi" });
    // Default opts (the HTTP/route/hook path): the client id must be thrown away.
    const rec = try create(a, std.testing.io, &d, col, .{ .object = obj });
    try std.testing.expect(!std.mem.eql(u8, "client-forced-id", rec.object.get("id").?.string));
    try std.testing.expectEqual(@as(usize, 15), rec.object.get("id").?.string.len);
}

test "createInTxnOpts: allow_provided_id PRESERVES a valid id; rejects an implausible one" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    // A valid provided id is preserved verbatim.
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "id", .{ .string = "my-imported-id-01" });
    try obj.put(a, "title", .{ .string = "hi" });
    const rec = try createInTxnOpts(a, std.testing.io, &d, col, .{ .object = obj }, .{ .allow_provided_id = true });
    try std.testing.expectEqualStrings("my-imported-id-01", rec.object.get("id").?.string);
    // An implausible id (embedded space) is rejected fail-closed.
    var bad: std.json.ObjectMap = .empty;
    try bad.put(a, "id", .{ .string = "bad id" });
    try bad.put(a, "title", .{ .string = "x" });
    try std.testing.expectError(error.InvalidId, createInTxnOpts(a, std.testing.io, &d, col, .{ .object = bad }, .{ .allow_provided_id = true }));
    // An empty/absent id under allow_provided_id falls back to a generated id.
    var noid: std.json.ObjectMap = .empty;
    try noid.put(a, "title", .{ .string = "y" });
    const gen = try createInTxnOpts(a, std.testing.io, &d, col, .{ .object = noid }, .{ .allow_provided_id = true });
    try std.testing.expectEqual(@as(usize, 15), gen.object.get("id").?.string.len);
}

test "isPlausibleRecordId gate" {
    try std.testing.expect(isPlausibleRecordId("abc123"));
    try std.testing.expect(isPlausibleRecordId("a1b2c3d4e5f6g7h"));
    try std.testing.expect(!isPlausibleRecordId(""));
    try std.testing.expect(!isPlausibleRecordId("has space"));
    try std.testing.expect(!isPlausibleRecordId("tab\ther"));
    try std.testing.expect(!isPlausibleRecordId("newline\n"));
}

test "list tenant scoping: only the active account's rows; superuser sees all; off = unchanged" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "account", .options = .{ .text = .{} } },
    };
    var col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &fields });
    col.options.tenant_field = "account"; // make it tenant-owned
    try d.exec("INSERT INTO posts (id,created,updated,title,account) VALUES " ++
        "('r1','2026-01-01T00:00:00Z','t','a','acc1')," ++
        "('r2','2026-01-02T00:00:00Z','t','b','acc1')," ++
        "('r3','2026-01-03T00:00:00Z','t','c','acc2');");

    // Active account acc1 -> only its 2 rows.
    const member = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };
    const r1 = try list(a, &d, col, .{ .rctx = &member });
    try std.testing.expectEqual(@as(?i64, 2), r1.totalItems);
    for (r1.items) |it| try std.testing.expectEqualStrings("acc1", it.object.get("account").?.string);

    // No account context (empty) -> no rows (fail closed).
    const noacct = request.RequestContext{ .tenancy_enabled = true, .account_id = "" };
    const r2 = try list(a, &d, col, .{ .rctx = &noacct });
    try std.testing.expectEqual(@as(?i64, 0), r2.totalItems);

    // Superuser bypasses scoping -> all 3 rows.
    const su = request.RequestContext{ .tenancy_enabled = true, .is_superuser = true, .account_id = "acc1" };
    const r3 = try list(a, &d, col, .{ .rctx = &su });
    try std.testing.expectEqual(@as(?i64, 3), r3.totalItems);

    // Tenancy OFF -> all 3 rows (byte-identical to pre-tenancy, even though tenant_field is set).
    const off = request.RequestContext{ .tenancy_enabled = false, .account_id = "acc1" };
    const r4 = try list(a, &d, col, .{ .rctx = &off });
    try std.testing.expectEqual(@as(?i64, 3), r4.totalItems);

    // The tenant predicate composes with a user filter (still scoped to acc1).
    const r5 = try list(a, &d, col, .{ .rctx = &member, .filter = "title = \"a\"" });
    try std.testing.expectEqual(@as(?i64, 1), r5.totalItems);
    try std.testing.expectEqualStrings("r1", r5.items[0].object.get("id").?.string);
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

test "over-maxSelect relation short-circuits before the per-element existence check" {
    // DoS guard: `.relation` validation runs one existence SELECT per submitted id under the
    // writer lock. An over-maxSelect array is already invalid, so it must be rejected on the
    // COUNT before the loop — otherwise an attacker-sized array drives N writer-lock queries.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const targets = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "targets", .fields = &[_]schema.Field{.{ .id = "t1", .name = "name", .options = .{ .text = .{} } }} });
    const fields = [_]schema.Field{.{ .id = "f1", .name = "refs", .options = .{ .relation = .{ .targetCollectionId = targets.id, .maxSelect = 2 } } }};
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "holders", .fields = &fields });
    // Three non-existent ids (> maxSelect=2). Pre-fix: the loop runs 3 existence SELECTs and each
    // absent id also appends `validation_not_found`. Post-fix: the count check returns first, so
    // ONLY the "too many" error exists and the per-element loop never runs.
    var refs = std.json.Array.init(a);
    try refs.append(.{ .string = "nope1" });
    try refs.append(.{ .string = "nope2" });
    try refs.append(.{ .string = "nope3" });
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "refs", .{ .array = refs });
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, col, .{ .object = data }));
    try expectFieldCode("refs", "validation_relation"); // the over-count error is present
    const errs = last_errors orelse return error.TestExpectedEqual;
    for (errs) |e| {
        // A per-element existence error would prove the loop ran despite the over-count input.
        if (std.mem.eql(u8, e.code, "validation_not_found")) return error.TestUnexpectedResult;
    }
}

test "over-maxSelect select short-circuits before the per-value allowed-set scan" {
    // Same short-circuit for `.select`: an over-maxSelect array must be rejected on the COUNT
    // before the per-value allowed-set scan runs. Both the count error and the membership error
    // share the code `validation_select`, so this asserts on the MESSAGE: an over-limit array
    // containing an invalid value must yield ONLY "Too many values." — the presence of "Value not
    // in the allowed set." would prove the loop ran on already-invalid input.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{.{ .id = "f1", .name = "tags", .options = .{ .select = .{ .values = &.{ "x", "y" }, .maxSelect = 2 } } }};
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "tagged", .fields = &fields });
    // Three values (> maxSelect=2), one of which ("bad") is NOT in the allowed set {x,y}.
    var tags = std.json.Array.init(a);
    try tags.append(.{ .string = "x" });
    try tags.append(.{ .string = "y" });
    try tags.append(.{ .string = "bad" });
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "tags", .{ .array = tags });
    try std.testing.expectError(error.Validation, create(a, std.testing.io, &d, col, .{ .object = data }));
    const errs = last_errors orelse return error.TestExpectedEqual;
    var saw_too_many = false;
    for (errs) |e| {
        if (std.mem.eql(u8, e.message, "Too many values.")) saw_too_many = true;
        // The allowed-set scan running on over-count input would append this — must NOT happen.
        if (std.mem.eql(u8, e.message, "Value not in the allowed set.")) return error.TestUnexpectedResult;
    }
    try std.testing.expect(saw_too_many);
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
    return updateInTxn(alloc, w, col, id, data);
}

/// Update a record on `w` WITHOUT opening a transaction. The caller must already
/// be inside one (or accept autocommit). Returns null if the row does not exist.
pub fn updateInTxn(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, id: []const u8, data: std.json.Value) RecordError!?std.json.Value {
    last_errors = null;
    if (data != .object) return error.NotObject;
    // Same ownership split as createInTxnOpts: `errs` escapes via last_errors (OWNED slice) on the
    // caller allocator; the SET list, binds and UPDATE SQL are scratch reclaimed by a child arena;
    // the returned record stays on `alloc`.
    var errs: std.ArrayList(schema.ValidationError) = .empty;
    errdefer errs.deinit(alloc);
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const dialect = db.dbDialect(w);
    const now_iso = dialect.nowIso8601Expr();

    var sets: std.ArrayList(u8) = .empty;
    try sets.appendSlice(sa, try std.fmt.allocPrint(sa, "\"updated\"={s}", .{now_iso}));
    var binds: std.ArrayList(BindItem) = .empty;
    var next: usize = 2; // ?1 is the id in WHERE

    for (col.fields) |f| {
        if (f.fieldType() == .autodate) {
            if (f.options.autodate.onUpdate) {
                try sets.appendSlice(sa, try std.fmt.allocPrint(sa, ",\"{s}\"={s}", .{ f.name, now_iso }));
            }
            continue;
        }
        const provided = data.object.get(f.name) orelse continue; // partial: only provided fields
        try validateFieldValue(alloc, w, f, provided, &errs);
        try sets.appendSlice(sa, try std.fmt.allocPrint(sa, ",\"{s}\"=?{d}", .{ f.name, next }));
        try binds.append(sa, .{ .idx = @intCast(next), .field = f, .value = provided });
        next += 1;
    }
    if (errs.items.len > 0) {
        last_errors = try errs.toOwnedSlice(alloc);
        return error.Validation;
    }

    const rcols = try columnList(sa, col);

    const sql = try std.fmt.allocPrintSentinel(sa, "UPDATE \"{s}\" SET {s} WHERE \"id\"=?1 RETURNING {s};", .{ col.name, sets.items, rcols }, 0);
    var st = try prep(sa, w, sql);
    defer st.finalize();
    try st.bindText(1, id);
    for (binds.items) |b| {
        values.bindValue(sa, &st, b.idx, b.field, b.value) catch |e| {
            try errs.append(alloc, .{ .field = b.field.name, .code = convCode(e), .message = "Invalid value." });
            last_errors = try errs.toOwnedSlice(alloc);
            return error.Validation;
        };
    }
    if (!try st.step()) return null;
    const rec = try rowToObject(alloc, &st, col);
    while (try st.step()) {} // drain to DONE so the statement isn't active at commit time
    return rec;
}

pub fn delete(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, id: []const u8) RecordError!bool {
    return deleteInTxn(alloc, w, col, id);
}

/// Delete a record on `w` WITHOUT opening a transaction. The caller must already
/// be inside one (or accept autocommit). Returns true if a row was deleted.
pub fn deleteInTxn(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, id: []const u8) RecordError!bool {
    const sql = try std.fmt.allocPrintSentinel(alloc, "DELETE FROM \"{s}\" WHERE \"id\"=?1 RETURNING \"id\";", .{col.name}, 0);
    defer alloc.free(sql);
    var st = try prep(alloc, w, sql);
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

test "list: filter_args with an empty/absent filter is a loud BadFilter (never silently ignored)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);

    // filter == null but args supplied -> 0 placeholders vs 1 arg is a mismatch.
    try std.testing.expectError(error.BadFilter, list(a, &d, col, .{ .filter_args = &.{.{ .string = "x" }} }));
    // filter == "" (empty) but args supplied -> same mismatch.
    try std.testing.expectError(error.BadFilter, list(a, &d, col, .{ .filter = "", .filter_args = &.{.{ .string = "x" }} }));
    // Sanity: empty filter with NO args stays a clean full list (the guard only fires on args).
    _ = try list(a, &d, col, .{ .filter = "" });
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

test "createInTxn inserts without opening its own transaction" {
    var conn = try db.Db.openMemory();
    defer conn.close();
    try conn.exec("PRAGMA foreign_keys=ON;");
    try migrations.run(&conn);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const fields = [_]schema.Field{.{ .id = "f1", .name = "title", .required = true, .options = .{ .text = .{} } }};
    const col = try collections.create(a, io, &conn, .{ .id = "", .name = "posts", .fields = &fields });

    // Caller owns the transaction; createInTxn must participate, not nest.
    try conn.beginImmediate();
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "title", .{ .string = "x" });
    const rec = try createInTxn(a, io, &conn, col, .{ .object = o });
    try conn.rollback(); // caller rolls back -> row must be gone
    try std.testing.expect((try get(a, &conn, col, rec.object.get("id").?.string)) == null);
}

/// Re-export so `ListQuery`/`ListOptions` consumers can name the bound-arg type without reaching
/// into `query/compiler.zig`.
pub const FilterArg = compiler.FilterArg;

pub const ListMode = enum { offset, cursor };

pub const ListQuery = struct {
    filter: ?[]const u8 = null,
    /// Bound values for `?` placeholders in `filter` (0-based, left-to-right). Each `?` binds its
    /// value as a literal SQL parameter — NEVER re-parsed as filter grammar (the injection-safe way
    /// to bind a runtime value). The placeholder count MUST equal `filter_args.len` or `list`
    /// returns `error.BadFilter`. The REST path supplies none, so a `?` in a `?filter=` query fails
    /// closed here. See `compiler.FilterArg`.
    filter_args: []const compiler.FilterArg = &.{},
    sort: ?[]const u8 = null,
    page: u32 = 1,
    perPage: u32 = 30,
    rule: ?[]const u8 = null,
    rctx: ?*const request.RequestContext = null,
    /// Full-text search terms (#157, the `?search=`/`?q=` param). When non-null/non-empty on a
    /// SEARCHABLE collection, a bound FTS5 `MATCH` predicate is AND-ed into the same WHERE
    /// composition as filter/rule/ability/tenant/ttl, and results are ranked by bm25 relevance
    /// (offset mode). A search on a non-searchable collection returns `error.NotSearchable`.
    /// On SQLite, honored only in an `-Dfts5` build (default ON; else `error.SearchDisabled`) —
    /// Postgres full-text search is unaffected by the flag.
    search: ?[]const u8 = null,
    /// Vector / nearest-neighbor search spec (#157, the `?vector=` param) — `<field>[:metric]:<json
    /// embedding>`. Honored only in a `-Dvector` build (else `error.VectorDisabled`); composes a
    /// KNN distance ordering into the SAME scoped query (offset mode).
    vectorSpec: ?[]const u8 = null,
    /// Opaque cursor token. When non-null, `list` runs in CURSOR (keyset) mode. The `page`
    /// field is then ignored. Decode/validation failures surface as keyset.DecodeError.
    cursor: ?[]const u8 = null,
    /// Force CURSOR mode even when `cursor == null` (the first page of a cursor walk, or when
    /// offset mode is disabled). Implied true whenever `cursor != null`.
    cursorMode: bool = false,
    /// Cursor-mode page size (alias of perPage). When non-null in cursor mode it overrides
    /// perPage (still clamped to 500). The very first cursor page (cursor==null but mode forced
    /// to cursor by the handler) uses perPage.
    limit: ?u32 = null,
    /// Cursor mode: skip the COUNT(*) total by default (true). Set false to include totalItems.
    skipTotal: bool = true,
    /// Which token format to mint/accept (handler threads this from the comptime app config).
    cursorToken: pagination.CursorToken = .stateless,
    /// HMAC secret for the SIGNED token format (the server's JWT secret).
    signingSecret: []const u8 = "",
    /// Entropy source for STATEFUL token ids; required only in stateful mode.
    io: ?std.Io = null,
    /// Writer DB for the STATEFUL store (mint/lookup write/read `_cursorStates`). When null in
    /// stateful mode, `conn` is used (it must be a writer).
    writer: ?*db.Db = null,
    /// TTL (seconds) for a stateful cursor entry. Default 1 hour.
    statefulTtlS: i64 = 3600,
};

pub const ListResult = struct {
    mode: ListMode = .offset,
    page: u32,
    perPage: u32,
    /// Offset mode: always set. Cursor mode: set only when skipTotal==false, else null.
    totalItems: ?i64,
    items: []std.json.Value,
    /// Cursor-mode navigation (null/false in offset mode).
    nextCursor: ?[]const u8 = null,
    prevCursor: ?[]const u8 = null,
    hasNext: bool = false,
    hasPrev: bool = false,
};

fn baseColumnList(alloc: std.mem.Allocator, col: schema.Collection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\".\"id\",\"{s}\".\"created\",\"{s}\".\"updated\"", .{ col.name, col.name, col.name }));
    for (col.fields) |f| {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"{s}\".{s}", .{ col.name, try ddl.quoteIdent(alloc, f.name) }));
    }
    return out.toOwnedSlice(alloc);
}

/// Append the `id` tiebreaker to the resolved sort terms so the order is strictly total
/// (keyset requires it). The tiebreaker's direction follows the LAST sort term (or DESC for the
/// default `created DESC` sort), matching the SDK's synthesized cursors for migration parity.
fn effectiveSortTerms(alloc: std.mem.Allocator, col: schema.Collection, base_terms: []const sort.SortTerm) ![]sort.SortTerm {
    var out: std.ArrayList(sort.SortTerm) = .empty;
    var last_desc = true; // default sort is created DESC -> id DESC
    if (base_terms.len > 0) {
        try out.appendSlice(alloc, base_terms);
        last_desc = base_terms[base_terms.len - 1].desc;
    } else {
        // No client sort -> default ORDER BY created DESC.
        try out.append(alloc, .{
            .col_sql = try std.fmt.allocPrint(alloc, "\"{s}\".\"created\"", .{col.name}),
            .field = null,
            .desc = true,
            .path = "created",
        });
    }
    // Don't double-append id if the client already sorted by id last.
    const already_id = base_terms.len > 0 and std.mem.eql(u8, base_terms[base_terms.len - 1].path, "id");
    if (!already_id) {
        try out.append(alloc, .{
            .col_sql = try std.fmt.allocPrint(alloc, "\"{s}\".\"id\"", .{col.name}),
            .field = null,
            .desc = last_desc,
            .path = "id",
        });
    }
    return out.toOwnedSlice(alloc);
}

/// The PUBLIC effective-sort string the cursor token binds to (its `s` field), built from the
/// client-facing field paths with a leading `-` for DESC — e.g. `-created,id`. This is the form
/// the SDK can synthesize, so a client-minted stateless cursor round-trips (the SQL ORDER BY,
/// `order_sql`, is column-qualified and unsuitable as a token binding). Stored in the token and
/// re-validated on decode.
fn effectiveSortString(alloc: std.mem.Allocator, terms: []const sort.SortTerm) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (terms, 0..) |t, i| {
        if (i != 0) try out.append(alloc, ',');
        if (t.desc) try out.append(alloc, '-');
        try out.appendSlice(alloc, t.path);
    }
    return out.toOwnedSlice(alloc);
}

/// Reject a relation-path sort (e.g. `author.name`, which lives under `expand`, not the row root)
/// as a keyset boundary: its value can't be read back from the row's JSON object, so it would mint
/// a cursor whose boundary is silently null and corrupt the keyset window — fail loudly instead.
/// Returns BadCursorSort so the handler returns a clear 400 BEFORE any rows are fetched. Hidden and
/// encrypted sort fields never reach here: the joiner rejects them (`error.HiddenField` /
/// `EncryptedField`) when the sort spec is resolved, which is the single chokepoint for that class.
fn validateCursorSort(terms: []const sort.SortTerm) keyset.DecodeError!void {
    for (terms) |t| {
        if (std.mem.indexOfScalar(u8, t.path, '.') != null) return error.BadCursorSort;
    }
}

/// Read a single sort-key value out of a built record JSON object by the term's field path.
/// System columns (id/created/updated) and top-level visible user fields live at the object root.
/// Callers must `validateCursorSort` first, which rejects relation-path/hidden terms; a missing
/// key here therefore means a genuinely NULL column value.
fn rowSortKey(obj: std.json.Value, term: sort.SortTerm) keyset.KeysetError!std.json.Value {
    if (obj != .object) return error.BadCursor;
    if (std.mem.indexOfScalar(u8, term.path, '.') != null) return error.BadCursor;
    return obj.object.get(term.path) orelse .null;
}

/// Mint a cursor token from a kept row's sort-key values, in the selected token format.
fn mintCursor(alloc: std.mem.Allocator, q: ListQuery, conn: *db.Db, col: schema.Collection, terms: []const sort.SortTerm, row: std.json.Value, forward: bool, sort_str: []const u8, filter_hash: u64) !?[]const u8 {
    var keys = try alloc.alloc(std.json.Value, terms.len);
    for (terms, 0..) |t, i| keys[i] = try rowSortKey(row, t);
    const cur = keyset.Cursor{ .forward = forward, .keys = keys, .sort_str = sort_str, .filter_hash = filter_hash };
    return switch (q.cursorToken) {
        .stateless => try keyset.encodeStateless(alloc, cur),
        .signed => try keyset.encodeSigned(alloc, cur, q.signingSecret),
        .stateful => try storeStatefulCursor(alloc, q, conn, col, cur),
    };
}

/// STATEFUL mint: persist the payload keyed by a random opaque id, return the id as the token.
fn storeStatefulCursor(alloc: std.mem.Allocator, q: ListQuery, conn: *db.Db, col: schema.Collection, cur: keyset.Cursor) ![]const u8 {
    const w = q.writer orelse conn;
    const io = q.io orelse return error.BadCursor;
    const payload = try keyset.statefulPayload(alloc, cur);
    var id_buf: [32]u8 = undefined;
    id_gen.generate(io, &id_buf);
    const id: []const u8 = try alloc.dupe(u8, &id_buf);
    const now = try nowUnixDb(conn);
    const insert_sql = try std.fmt.allocPrintSentinel(alloc, "INSERT INTO \"_cursorStates\" (\"id\",\"collectionRef\",\"payload\",\"expires\",\"created\") VALUES (?1,?2,?3,?4,{s});", .{db.dbDialect(w).nowExpr()}, 0);
    var st = try prep(alloc, w, insert_sql);
    defer st.finalize();
    try st.bindText(1, id);
    try st.bindText(2, col.name);
    try st.bindText(3, payload);
    try st.bindInt(4, now + q.statefulTtlS);
    _ = try st.step();
    return id;
}

/// STATEFUL decode: look the opaque id up (unexpired) in `_cursorStates` and decode its payload.
/// Unknown/expired -> keyset.DecodeError.CursorState (the handler maps it to 410 Gone).
fn loadStatefulCursor(alloc: std.mem.Allocator, q: ListQuery, conn: *db.Db, col: schema.Collection, token: []const u8) keyset.DecodeError!keyset.Cursor {
    // Read from the SAME connection the store writes to (`q.writer orelse conn`), so a deployment
    // that threads a distinct writer can't INSERT on one connection and SELECT on another.
    const c = q.writer orelse conn;
    if (token.len == 0 or token.len > keyset.max_cursor_len) return error.BadCursor;
    const now = nowUnixDb(c) catch return error.BadCursor;
    const select_sql = param_sink.renumberZ(alloc, db.dbDialect(c),
        \\SELECT "payload" FROM "_cursorStates"
        \\ WHERE "id"=?1 AND "collectionRef"=?2 AND "expires" > ?3;
    ) catch return error.BadCursor;
    var st = c.prepare(select_sql) catch return error.BadCursor;
    defer st.finalize();
    st.bindText(1, token) catch return error.BadCursor;
    st.bindText(2, col.name) catch return error.BadCursor;
    st.bindInt(3, now) catch return error.BadCursor;
    const found = st.step() catch return error.BadCursor;
    if (!found) return error.CursorState;
    const payload = try alloc.dupe(u8, st.columnText(0));
    return keyset.decodeStatefulPayload(alloc, payload);
}

/// Decode + validate a cursor in the selected format, binding it to the request's effective sort
/// and filter. Mismatches surface as the specific DecodeError the handler maps to 400/410.
fn decodeCursor(alloc: std.mem.Allocator, q: ListQuery, conn: *db.Db, col: schema.Collection, token: []const u8, sort_str: []const u8, filter_hash: u64) keyset.DecodeError!keyset.Cursor {
    const cur = switch (q.cursorToken) {
        .stateless => try keyset.decodeStateless(alloc, token),
        .signed => try keyset.decodeSigned(alloc, token, q.signingSecret),
        .stateful => try loadStatefulCursor(alloc, q, conn, col, token),
    };
    if (!std.mem.eql(u8, cur.sort_str, sort_str)) return error.CursorSort;
    if (cur.filter_hash != filter_hash) return error.CursorFilter;
    return cur;
}

/// Unix seconds for cursor-state TTL/expiry, via the clock seam (honors the dev-only
/// `ZIGBASE_FAKE_NOW` override so a frozen e2e clock expires cursors deterministically).
fn nowUnixDb(conn: *db.Db) db.DbError!i64 {
    return clock.sqlNowUnix(conn);
}

/// GC: delete expired stateful cursor entries. Safe to call periodically (scheduler) or inline.
pub fn gcCursorStates(w: *db.Db) db.DbError!void {
    const now = try nowUnixDb(w);
    // No request arena here; the placeholder renumber needs a tiny scratch allocator (the SQL is a
    // fixed ~50 bytes, so a stack buffer is ample). SQLite renumber is a no-op (returns the slice).
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const sql = param_sink.renumberZ(fba.allocator(), db.dbDialect(w), "DELETE FROM \"_cursorStates\" WHERE \"expires\" <= ?1;") catch return error.PrepareFailed;
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindInt(1, now);
    _ = try st.step();
}

// ---------------------------------------------------------------------------
// TTL read-time exclusion tests
// ---------------------------------------------------------------------------

test "ttl read-exclusion: get returns null for expired, row for future+null, non-ttl unaffected" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);

    // TTL collection: expires_at is the ttl_field.
    const sfields = [_]schema.Field{
        .{ .id = "f1", .name = "token", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "expires_at", .options = .{ .date = .{} } },
    };
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "sessions", .fields = &sfields, .options = .{ .ttl_field = "expires_at" } });

    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('past','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','a','2000-01-01T00:00:00Z');");
    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('future','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','b','2999-01-01T00:00:00Z');");
    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('never','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','c',NULL);");

    // Non-TTL collection: a past-looking date on a non-ttl_field must not be filtered.
    const pfields = [_]schema.Field{
        .{ .id = "f3", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f4", .name = "created_at", .options = .{ .date = .{} } },
    };
    const pcol = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pfields });
    try d.exec("INSERT INTO posts (id,created,updated,title,created_at) VALUES ('p1','2000-01-01T00:00:00Z','2000-01-01T00:00:00Z','keep','2000-01-01T00:00:00Z');");

    // get: expired → null; future → returned; null ttl → returned.
    try std.testing.expect(null == try get(a, &d, col, "past"));
    try std.testing.expect(null != try get(a, &d, col, "future"));
    try std.testing.expect(null != try get(a, &d, col, "never"));

    // get: non-ttl collection is unaffected.
    try std.testing.expect(null != try get(a, &d, pcol, "p1"));
}

test "ttl read-exclusion: list excludes expired, includes future+null, non-ttl unaffected" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);

    const sfields = [_]schema.Field{
        .{ .id = "f1", .name = "token", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "expires_at", .options = .{ .date = .{} } },
    };
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "sessions", .fields = &sfields, .options = .{ .ttl_field = "expires_at" } });

    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('past','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','a','2000-01-01T00:00:00Z');");
    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('future','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','b','2999-01-01T00:00:00Z');");
    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('never','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','c',NULL);");

    const pfields = [_]schema.Field{.{ .id = "f3", .name = "title", .options = .{ .text = .{} } }};
    const pcol = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pfields });
    try d.exec("INSERT INTO posts (id,created,updated,title) VALUES ('p1','2000-01-01T00:00:00Z','2000-01-01T00:00:00Z','keep');");

    // list: only 2 of the 3 session rows are returned (future + null; past is hidden).
    const r = try list(a, &d, col, .{});
    try std.testing.expectEqual(@as(?i64, 2), r.totalItems);
    try std.testing.expectEqual(@as(usize, 2), r.items.len);

    // Verify the IDs returned are future and never, not past.
    var saw_future = false;
    var saw_never = false;
    for (r.items) |item| {
        const id_val = item.object.get("id") orelse continue;
        const id_str = id_val.string;
        if (std.mem.eql(u8, id_str, "future")) saw_future = true;
        if (std.mem.eql(u8, id_str, "never")) saw_never = true;
        try std.testing.expect(!std.mem.eql(u8, id_str, "past"));
    }
    try std.testing.expect(saw_future);
    try std.testing.expect(saw_never);

    // list: non-ttl collection returns all rows unaffected.
    const pr = try list(a, &d, pcol, .{});
    try std.testing.expectEqual(@as(?i64, 1), pr.totalItems);
}

test "ttl read-exclusion: composes with user filter (both predicates ANDed)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);

    const sfields = [_]schema.Field{
        .{ .id = "f1", .name = "token", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "expires_at", .options = .{ .date = .{} } },
    };
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "sessions", .fields = &sfields, .options = .{ .ttl_field = "expires_at" } });

    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('past_a','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','tokenA','2000-01-01T00:00:00Z');");
    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('future_a','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','tokenA','2999-01-01T00:00:00Z');");
    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('future_b','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','tokenB','2999-01-01T00:00:00Z');");

    // filter=token='tokenA' should match 2 rows (past_a + future_a), but TTL hides past_a.
    const r = try list(a, &d, col, .{ .filter = "token='tokenA'" });
    try std.testing.expectEqual(@as(?i64, 1), r.totalItems);
    try std.testing.expectEqual(@as(usize, 1), r.items.len);
    const id_val = r.items[0].object.get("id") orelse return error.MissingId;
    try std.testing.expectEqualStrings("future_a", id_val.string);
}

test "ttl read-exclusion: instant comparison not lexical (offset/space/date-only)" {
    // A future instant stored with a negative-offset literal (e.g. '2026-07-01T10:00:00-05:00',
    // i.e. 15:00Z) sorts LEXICALLY before '...Z' because '-' < 'Z'. A lexical comparison
    // would wrongly hide this row. strftime normalises both sides so it is kept.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "label", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "expires_at", .options = .{ .date = .{} } },
    };
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "tokens", .fields = &fields, .options = .{ .ttl_field = "expires_at" } });

    // KEPT — future instant whose literal sorts BEFORE canonical now (negative offset).
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('future_neg','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','a', strftime('%Y-%m-%dT%H:%M:%S','now','-1 minute') || '-05:00');");
    // KEPT — far-future canonical Z.
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('future_z','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','b','2999-01-01T00:00:00Z');");
    // KEPT — unparseable garbage: strftime → NULL → NULL > x → NULL → not hidden (fail-safe).
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('garbage','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','c','not-a-date');");
    // HIDDEN — genuinely past non-canonical forms.
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('past_offset','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','d','2000-01-01T00:00:00+05:00');");
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('past_space','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','e','2000-01-01 00:00:00');");

    const r = try list(a, &d, col, .{});
    // 3 kept (future_neg, future_z, garbage) + 2 hidden (past_offset, past_space).
    try std.testing.expectEqual(@as(?i64, 3), r.totalItems);

    // Also verify get: future_neg must be returned; past_offset must not.
    try std.testing.expect(null != try get(a, &d, col, "future_neg"));
    try std.testing.expect(null == try get(a, &d, col, "past_offset"));
    try std.testing.expect(null != try get(a, &d, col, "garbage")); // unparseable → kept
}

test "gcExpiredRecords deletes past rows, keeps future rows, ignores non-ttl collections" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    // A collection that opts into TTL via a date field.
    const sfields = [_]schema.Field{
        .{ .id = "f1", .name = "token", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "expires_at", .options = .{ .date = .{} } },
    };
    _ = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "sessions", .fields = &sfields, .options = .{ .ttl_field = "expires_at" } });
    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('past','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','a','2000-01-01T00:00:00Z');");
    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('future','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','b','2999-01-01T00:00:00Z');");
    // A null ttl value must NOT be treated as expired.
    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('never','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','c',NULL);");
    // A collection WITHOUT a ttl_field must be untouched.
    const pfields = [_]schema.Field{.{ .id = "f3", .name = "title", .options = .{ .text = .{} } }};
    _ = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pfields });
    try d.exec("INSERT INTO posts (id,created,updated,title) VALUES ('p1','2000-01-01T00:00:00Z','2000-01-01T00:00:00Z','keep');");

    const deleted = try gcExpiredRecords(a, &d);
    try std.testing.expectEqual(@as(usize, 1), deleted);

    const Counter = struct {
        fn count(dd: *db.Db, sql: [:0]const u8) !i64 {
            var st = try dd.prepare(sql);
            defer st.finalize();
            _ = try st.step();
            return st.columnInt(0);
        }
    };
    try std.testing.expectEqual(@as(i64, 0), try Counter.count(&d, "SELECT COUNT(*) FROM sessions WHERE id='past';"));
    try std.testing.expectEqual(@as(i64, 1), try Counter.count(&d, "SELECT COUNT(*) FROM sessions WHERE id='future';"));
    try std.testing.expectEqual(@as(i64, 1), try Counter.count(&d, "SELECT COUNT(*) FROM sessions WHERE id='never';"));
    try std.testing.expectEqual(@as(i64, 1), try Counter.count(&d, "SELECT COUNT(*) FROM posts;"));
}

test "gcExpiredRecords: no scratch leak on a non-arena (GPA) caller" {
    // Regression: the sweep once freed only the DELETE text and leaked the collections list plus
    // the per-collection quoted-field and predicate strings whenever the caller passed a real GPA.
    // Call it with the leak-DETECTING testing allocator DIRECTLY (not an arena) — the internal
    // arena must free every allocation, or the test framework flags the leak.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const sfields = [_]schema.Field{
        .{ .id = "f1", .name = "token", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "expires_at", .options = .{ .date = .{} } },
    };
    _ = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "sessions", .fields = &sfields, .options = .{ .ttl_field = "expires_at" } });
    try d.exec("INSERT INTO sessions (id,created,updated,token,expires_at) VALUES ('past','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','a','2000-01-01T00:00:00Z');");

    // The load-bearing line: gcExpiredRecords receives the leak-checked GPA, not the arena `a`.
    const deleted = try gcExpiredRecords(std.testing.allocator, &d);
    try std.testing.expectEqual(@as(usize, 1), deleted);
}

test "gcExpiredRecords compares ttl as an instant, not lexically (offsets/date-only/space)" {
    // Regression: `.date` values are stored RAW and the validator accepts non-canonical
    // ISO-8601 (offsets, date-only, space separator). A naive lexical `tf <= '...Z'`
    // wrongly reaps a FUTURE instant whose literal sorts before "now" (e.g. a negative
    // UTC offset: '-' < 'Z'). The GC normalizes both sides via strftime, so it compares
    // true instants.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "label", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "expires_at", .options = .{ .date = .{} } },
    };
    _ = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "tokens", .fields = &fields, .options = .{ .ttl_field = "expires_at" } });

    // KEPT — future instant whose literal sorts BEFORE "now" (the exact lexical-vs-instant
    // bug). Built in SQL relative to now: a wall-clock literal one minute in the past (so it
    // is lexically < the canonical "...Z" now) but tagged -05:00, making the INSTANT now+~5h.
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('future_neg','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','a', strftime('%Y-%m-%dT%H:%M:%S','now','-1 minute') || '-05:00');");
    // KEPT — canonical far-future Z (sanity that the canonical path is unchanged).
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('future_z','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','b','2999-01-01T00:00:00Z');");
    // KEPT — unparseable garbage: strftime -> NULL -> NULL <= x -> NULL -> not deleted (fail-safe).
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('garbage','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','c','not-a-date');");
    // DELETED — genuinely-past non-canonical forms: positive-offset, date-only, space-separated.
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('past_offset','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','d','2000-01-01T00:00:00+05:00');");
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('past_dateonly','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','e','2000-01-01');");
    try d.exec("INSERT INTO tokens (id,created,updated,label,expires_at) VALUES ('past_space','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','f','2000-01-01 00:00:00');");

    const deleted = try gcExpiredRecords(a, &d);
    try std.testing.expectEqual(@as(usize, 3), deleted);

    const C = struct {
        fn n(dd: *db.Db, sql: [:0]const u8) !i64 {
            var st = try dd.prepare(sql);
            defer st.finalize();
            _ = try st.step();
            return st.columnInt(0);
        }
    };
    // future/garbage rows survive
    try std.testing.expectEqual(@as(i64, 1), try C.n(&d, "SELECT COUNT(*) FROM tokens WHERE id='future_neg';"));
    try std.testing.expectEqual(@as(i64, 1), try C.n(&d, "SELECT COUNT(*) FROM tokens WHERE id='future_z';"));
    try std.testing.expectEqual(@as(i64, 1), try C.n(&d, "SELECT COUNT(*) FROM tokens WHERE id='garbage';"));
    // past non-canonical forms reaped
    try std.testing.expectEqual(@as(i64, 0), try C.n(&d, "SELECT COUNT(*) FROM tokens WHERE id IN ('past_offset','past_dateonly','past_space');"));
}

test "gcExpiredRecords is resilient: a drifted collection does not abort the sweep" {
    // A TTL collection whose physical table was dropped (but whose `_collections`
    // metadata remains) must not prevent GC of a second, healthy TTL collection.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "label", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "expires_at", .options = .{ .date = .{} } },
    };
    _ = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "drifted", .fields = &fields, .options = .{ .ttl_field = "expires_at" } });
    _ = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "healthy", .fields = &fields, .options = .{ .ttl_field = "expires_at" } });
    try d.exec("INSERT INTO healthy (id,created,updated,label,expires_at) VALUES ('h1','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','x','2000-01-01T00:00:00Z');");
    // Simulate drift: drop the table out from under the still-present metadata row.
    try d.exec("DROP TABLE drifted;");

    // The sweep must NOT propagate the drifted collection's error; it logs+skips it
    // and still reaps the healthy collection's expired row.
    const deleted = try gcExpiredRecords(a, &d);
    try std.testing.expectEqual(@as(usize, 1), deleted);
    var st = try d.prepare("SELECT COUNT(*) FROM healthy;");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

/// GC: delete rows whose `ttl_field` timestamp is at/before "now" across every
/// collection that opts into TTL (`options.ttl_field != null`). Returns the total
/// number of rows deleted. Safe to call periodically (the framework-internal
/// `_ttl_gc` job) or once at startup. Collections without a ttl_field are untouched.
///
/// Security: both the collection name and the ttl_field name are gated through
/// `schema.isValidIdentifier` before interpolation (the query-string threat model
/// in docs/security-audit.md requires every interpolated identifier be validated).
/// The comptime `.collections` path already guarantees valid names, but a
/// hand-crafted `_collections` row must not be trusted.
///
/// Both sides of the comparison are normalized to a canonical UTC instant via
/// `strftime('%Y-%m-%dT%H:%M:%SZ', x)` BEFORE comparing. This matters because a
/// `.date` value is stored RAW (whatever the writer bound) and the validator accepts
/// non-canonical ISO-8601 forms — `±HH:MM` offsets, fractional seconds, a space
/// separator, or date-only. A future instant written with a negative offset (e.g.
/// `"2026-06-27T12:00:00-05:00"`, i.e. 17:00Z) sorts LEXICALLY before `"…Z"` and
/// would be wrongly reaped by a raw string `<=`. Letting SQLite parse both sides as
/// instants fixes that. `strftime` returns NULL for unparseable input, so a garbage
/// ttl value yields `NULL <= x` → NULL → the row is NOT deleted (fail-safe). The
/// outer `IS NOT NULL` keeps an unset (optional) ttl column from ever being reaped.
pub fn gcExpiredRecords(alloc: std.mem.Allocator, w: *db.Db) !usize {
    // Every allocation below (the collections list, and per collection the quoted field, the
    // dialect predicate, and the DELETE text) is throwaway scratch freed together at return. An
    // internal arena frees it all in one shot, keeping the sweep leak-free for ANY caller allocator
    // (arena OR GPA) with no per-allocation bookkeeping — mirrors `provision.applySpecs`.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    const cols = try collections.list(a, w);
    var total: usize = 0;
    for (cols) |col| {
        const tf = col.options.ttl_field orelse continue;
        if (!schema.isValidIdentifier(col.name)) continue;
        if (!schema.isValidIdentifier(tf)) continue;
        const qtf = try std.fmt.allocPrint(a, "\"{s}\"", .{tf});
        const expired = try db.dbDialect(w).ttlExpiredDeletePredicate(a, qtf);
        const sql = try std.fmt.allocPrintSentinel(a, "DELETE FROM \"{s}\" WHERE {s};", .{ col.name, expired }, 0);
        // Resilient per-collection: a single drifted collection (e.g. the table was
        // dropped but its `_collections` metadata remains) must not abort the whole
        // sweep and silence GC for every later collection. Log and skip to the next.
        var st = w.prepare(sql) catch |err| {
            std.log.warn("TTL GC: skipping collection '{s}': {s}", .{ col.name, @errorName(err) });
            continue;
        };
        defer st.finalize();
        _ = st.step() catch |err| {
            std.log.warn("TTL GC: step failed for collection '{s}': {s}", .{ col.name, @errorName(err) });
            continue;
        };
        total += @intCast(@max(@as(i64, 0), w.changesCount()));
    }
    return total;
}

fn rawCell(d: *db.Db, alloc: std.mem.Allocator, sql: [:0]const u8) ![]const u8 {
    var st = try d.prepare(sql);
    defer st.finalize();
    _ = try st.step();
    return alloc.dupe(u8, st.columnText(0));
}

test "encrypted field: round-trip through records, ciphertext-at-rest, strict fail-closed" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try migrations.run(&d);

    // Stamp a field cipher on the connection (as the pool does in serveImpl).
    var cipher = field_policy.Cipher.fromEnv(io, "operator-field-key");
    db.dbSetFieldCipher(&d, @ptrCast(&cipher));

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "secret", .encrypted = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "blob", .encrypted = true, .options = .{ .json = .{} } },
        .{ .id = "f3", .name = "plain", .options = .{ .text = .{} } },
    };
    const col = try collections.create(a, io, &d, .{ .id = "", .name = "vault", .fields = &fields });

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "secret", .{ .string = "topsecret" });
    var jblob: std.json.ObjectMap = .empty;
    try jblob.put(a, "pin", .{ .integer = 1234 });
    try obj.put(a, "blob", .{ .object = jblob });
    try obj.put(a, "plain", .{ .string = "visible" });
    const created = try create(a, io, &d, col, .{ .object = obj });
    const id = created.object.get("id").?.string;

    // (a) Read-back through the records API returns PLAINTEXT (transparent).
    const got = (try get(a, &d, col, id)).?;
    try std.testing.expectEqualStrings("topsecret", got.object.get("secret").?.string);
    try std.testing.expectEqual(@as(i64, 1234), got.object.get("blob").?.object.get("pin").?.integer);
    try std.testing.expectEqualStrings("visible", got.object.get("plain").?.string);

    // (b) Ciphertext-at-rest: the raw SQLite cells hold a v1 envelope, NOT the plaintext.
    const raw_secret = try rawCell(&d, a, "SELECT secret FROM vault;");
    try std.testing.expect(std.mem.startsWith(u8, raw_secret, "v1:"));
    try std.testing.expect(std.mem.indexOf(u8, raw_secret, "topsecret") == null);
    const raw_blob = try rawCell(&d, a, "SELECT blob FROM vault;");
    try std.testing.expect(std.mem.startsWith(u8, raw_blob, "v1:"));
    try std.testing.expect(std.mem.indexOf(u8, raw_blob, "1234") == null);
    // The non-encrypted field is stored as plaintext.
    const raw_plain = try rawCell(&d, a, "SELECT plain FROM vault;");
    try std.testing.expectEqualStrings("visible", raw_plain);

    // (c) Strict fail-closed: decrypting the real envelope with the WRONG key fails.
    var wrong = field_policy.Cipher.fromEnv(io, "a-totally-different-key");
    db.dbSetFieldCipher(&d, @ptrCast(&wrong));
    try std.testing.expectError(error.BadEnvelope, get(a, &d, col, id));

    // A legacy/plaintext stored value (no envelope) also fails closed — no passthrough.
    db.dbSetFieldCipher(&d, @ptrCast(&cipher));
    try d.exec("UPDATE vault SET secret='legacy-plaintext';");
    try std.testing.expectError(error.BadEnvelope, get(a, &d, col, id));
}

test "encrypted field with no cipher fails closed (never plaintext)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try migrations.run(&d);
    // No cipher stamped: d.field_cipher == null.
    const fields = [_]schema.Field{.{ .id = "f1", .name = "secret", .encrypted = true, .options = .{ .text = .{} } }};
    const col = try collections.create(a, io, &d, .{ .id = "", .name = "vault2", .fields = &fields });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "secret", .{ .string = "x" });
    // Write to an encrypted field with no key configured must fail (not store plaintext).
    try std.testing.expectError(error.Validation, create(a, io, &d, col, .{ .object = obj }));
}

pub fn list(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, q: ListQuery) !ListResult {
    if (q.filter) |fstr| if (fstr.len > max_filter_len) return error.BadFilter;
    if (q.sort) |sstr| if (sstr.len > max_filter_len) return error.BadSort;
    const dialect = db.dbDialect(conn);
    var j = joiner.Joiner.init(alloc, conn, col);
    var where_sql: []const u8 = "";
    var params: []const compiler.Param = &.{};

    // Full-text search (#157): compose a BOUND FTS5 `MATCH` predicate as the FIRST WHERE clause —
    // so its `?` is params[0] — then let filter/rule/ability/tenant/ttl below narrow it further. The
    // FTS shadow table is brought in via a join; relevance (bm25 `rank`) drives the OFFSET ordering.
    // CRITICAL: search NEVER bypasses scoping — it AND-s INTO the same composition, so a search on a
    // tenant-/ability-guarded collection still returns only rows the caller may view. A search on a
    // collection with no searchable field is `error.NotSearchable` (handler -> 400).
    var search_order: ?[]const u8 = null;
    var search_order_param: ?compiler.Param = null; // PG ts_rank re-binds the term in ORDER BY; null on SQLite
    var search_term_hash: ?[]const u8 = null; // the SANITIZED term, folded into the cursor hash
    if (q.search) |sterm| {
        const trimmed = std.mem.trim(u8, sterm, " \t\r\n");
        if (trimmed.len > 0) {
            if (!fts.isSearchable(col)) return error.NotSearchable;
            if (try fts.build(alloc, dialect, col, sterm)) |s| {
                // Postgres' tsvector lives on the base table → no JOIN (empty join_sql); SQLite's
                // FTS5 shadow table needs one. Only append a non-empty join.
                if (s.join_sql.len > 0) try j.joins.append(alloc, s.join_sql);
                where_sql = s.where_sql;
                const p = try alloc.alloc(compiler.Param, 1);
                p[0] = s.param;
                params = p;
                search_order = s.order_sql;
                search_order_param = s.order_param;
                search_term_hash = s.param.text;
            } else {
                // A non-empty search that sanitizes to nothing (operator-/punctuation-only, e.g.
                // `?search=AND`) carries no matchable token. Match NOTHING rather than silently
                // degrade to a full (scoped) list — the constant-false `"0"` fragment short-circuits
                // every page to empty through the normal machinery (and AND-s harmlessly with the
                // scope predicates below). The query was a search; an empty search yields no rows.
                // SQLite accepts the bare `0`; Postgres needs `false` (boolean context).
                where_sql = dialect.constFalse();
                search_term_hash = trimmed; // bind the cursor to the (rejected) term anyway
            }
        }
    }

    // Vector / nearest-neighbor search (#157, gated by `-Dvector`). The WHERE fragment (no param)
    // AND-s into the same scoped composition; the distance ordering + its bound query-embedding
    // param are threaded into the OFFSET path below. A `?vector=` in a default build, or in cursor
    // mode, is a clean error the handler maps to 400.
    var vector_order: ?[]const u8 = null;
    var vector_param: ?compiler.Param = null;
    if (q.vectorSpec) |vspec| if (vspec.len > 0) {
        // `vector.build` carries the explicit `error.VectorDisabled` in a default build, so the
        // handler's error mapping stays well-typed regardless of the `-Dvector` flag.
        const v = try vector.build(alloc, dialect, col, vspec);
        if (q.cursor != null or q.cursorMode) return error.VectorCursorUnsupported;
        where_sql = if (where_sql.len > 0)
            try std.fmt.allocPrint(alloc, "({s}) AND ({s})", .{ where_sql, v.where_sql })
        else
            v.where_sql;
        vector_order = v.order_sql;
        vector_param = v.param;
    };

    // The per-compile placeholder/arg count check lives inside `compiler.compile`, which only runs
    // for a NON-empty filter below. Guard the empty/absent-filter case here so a caller who supplies
    // `filter_args` but no (or an empty) filter gets the documented loud `error.BadFilter` instead of
    // silently ignored args. Net invariant: placeholder_count MUST always equal filter_args.len — and
    // an empty filter has zero placeholders, so any supplied args are a mismatch.
    if ((q.filter == null or q.filter.?.len == 0) and q.filter_args.len > 0) return error.BadFilter;

    if (q.filter) |fstr| if (fstr.len > 0) {
        const toks = try lexer.lex(alloc, fstr);
        const ast = try parser.parse(alloc, toks);
        const compiled = try compiler.compile(alloc, &j, ast, null, dialect, q.filter_args);
        // AND-compose onto any prior clause (the FTS `MATCH` / vector predicate set above) and
        // APPEND params — never assign, which would clobber the search predicate AND drop its bound
        // term, so `?search=X&filter=Y` would silently ignore the search. Mirrors the rule block.
        where_sql = if (where_sql.len > 0)
            try std.fmt.allocPrint(alloc, "({s}) AND ({s})", .{ where_sql, compiled.where_sql })
        else
            compiled.where_sql;
        var merged: std.ArrayList(compiler.Param) = .empty;
        try merged.appendSlice(alloc, params);
        try merged.appendSlice(alloc, compiled.params);
        params = try merged.toOwnedSlice(alloc);
    };
    if (q.rule) |rstr| if (rstr.len > 0) {
        // The list rule is operator-authored and trusted: permit references to hidden fields (a
        // server-side WHERE clause, never serialized), then restore the client-input default so the
        // sort below still rejects a hidden sort key.
        j.allow_hidden = true;
        defer j.allow_hidden = false;
        const rtoks = try lexer.lex(alloc, rstr);
        const rast = try parser.parse(alloc, rtoks);
        const rc = try compiler.compile(alloc, &j, rast, q.rctx, dialect, &.{});
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

    // Ability scoping (#155): AND the lowered `"<col>"."<via>" IN (?,…)` view-ability predicate so a
    // LIST narrows to the rows the principal may VIEW by relationship — the read-path complement to
    // `policy.compilePredicate` (which governs view/create/update/delete/expand/realtime). Without
    // this, a list rule broader than the ability would leak ability-denied rows on the bulk endpoint.
    // An empty qualifying set lowers to the constant-false `"0"` fragment (zero params) → 0 rows
    // (fail closed); a superuser / no-ability collection yields null → byte-identical to the prior
    // SQL. Identifiers are gated in `abilityPredicate`; account-ids are bound.
    if (q.rctx) |rctx| {
        const view_ability = if (col.options.abilities) |ab| ab.view else null;
        if (try abilities.abilityPredicate(alloc, col, view_ability, rctx, dialect)) |ap| {
            where_sql = if (where_sql.len > 0)
                try std.fmt.allocPrint(alloc, "({s}) AND ({s})", .{ where_sql, ap.sql })
            else
                ap.sql;
            var merged: std.ArrayList(compiler.Param) = .empty;
            defer merged.deinit(alloc);
            try merged.appendSlice(alloc, params);
            try merged.appendSlice(alloc, ap.params);
            params = try merged.toOwnedSlice(alloc);
        }
    }

    // TTL read-time exclusion: AND a predicate that hides expired rows. This is the
    // read-time complement to gcExpiredRecords (which only runs every ~5 min), giving
    // immediate consistency. Three-clause OR mirrors the GC's fail-safe semantics:
    //   1. col IS NULL            → no expiry set → always visible
    //   2. strftime(col) IS NULL  → unparseable value → fail-safe: keep visible (same as
    //                              GC, which also won't delete a row with garbage ttl)
    //   3. strftime(col) > now    → genuine future instant → visible
    // strftime normalises both sides so non-canonical forms (offsets, space, date-only)
    // compare as instants, not lexically. Table-qualified because JOINs may be present.
    // Security: both col.name and tf validated through isValidIdentifier (GC pattern).
    if (col.options.ttl_field) |tf| {
        if (schema.isValidIdentifier(col.name) and schema.isValidIdentifier(tf)) {
            const qtf = try std.fmt.allocPrint(alloc, "\"{s}\".\"{s}\"", .{ col.name, tf });
            const ttl_pred = try dialect.ttlVisiblePredicate(alloc, qtf);
            where_sql = if (where_sql.len > 0)
                try std.fmt.allocPrint(alloc, "({s}) AND ({s})", .{ where_sql, ttl_pred })
            else
                ttl_pred;
        }
    }

    // Tenant scoping (#156): AND the bound `"<col>"."<tenant_field>" = ?` predicate so a list of a
    // tenant-owned collection only returns the request's active account's rows. The single param
    // is appended LAST (after filter+rule params); the TTL block above binds no params, so the
    // trailing `?` here is the last placeholder in `where_sql` and therefore the last param. Null
    // (no tenancy / not tenant-owned / superuser) is a no-op → byte-identical to the prior SQL.
    if (q.rctx) |rctx| if (try tenancy.scopePredicate(alloc, col, rctx)) |sp| {
        where_sql = if (where_sql.len > 0)
            try std.fmt.allocPrint(alloc, "({s}) AND ({s})", .{ where_sql, sp.sql })
        else
            sp.sql;
        var merged: std.ArrayList(compiler.Param) = .empty;
        defer merged.deinit(alloc); // no-op after toOwnedSlice (success); frees on an OOM error path
        try merged.appendSlice(alloc, params);
        try merged.append(alloc, sp.param);
        params = try merged.toOwnedSlice(alloc);
    };

    // Resolve the client sort into structured terms. Cursor mode appends an `id` tiebreaker so the
    // order is strictly total (keyset requires it); OFFSET mode keeps its historical ORDER BY
    // (client sort or the default `created DESC`) UNCHANGED so existing offset clients are byte-
    // identical.
    const base_terms = if (q.sort) |sstr| (if (sstr.len > 0) try sort.compileTerms(alloc, &j, sstr) else &.{}) else &.{};
    var offset_order_sql: []const u8 = if (base_terms.len > 0)
        try sort.orderByFromTerms(alloc, base_terms, dialect)
    else
        try std.fmt.allocPrint(alloc, "\"{s}\".\"created\" DESC{s}", .{ col.name, dialect.nullsOrder(.desc) });
    // Search/vector relevance leads the OFFSET ordering: bm25 `rank` (FTS) and/or nearest-neighbor
    // distance (vector), with any client sort kept as the tiebreaker. Cursor mode keeps the keyset
    // order (the MATCH/where predicate still scopes the page; vector cursors are rejected above).
    if (search_order) |so|
        offset_order_sql = if (base_terms.len > 0) try std.fmt.allocPrint(alloc, "{s}, {s}", .{ so, offset_order_sql }) else so;
    if (vector_order) |vo|
        offset_order_sql = if (base_terms.len > 0 or search_order != null) try std.fmt.allocPrint(alloc, "{s}, {s}", .{ vo, offset_order_sql }) else vo;
    const eff_terms = try effectiveSortTerms(alloc, col, base_terms);
    const order_sql = try sort.orderByFromTerms(alloc, eff_terms, dialect);

    var joins_sql: std.ArrayList(u8) = .empty;
    for (j.joins.items) |jn| {
        try joins_sql.append(alloc, ' ');
        try joins_sql.appendSlice(alloc, jn);
    }
    const where_clause = if (where_sql.len > 0) try std.fmt.allocPrint(alloc, " WHERE {s}", .{where_sql}) else "";
    const bcols = try baseColumnList(alloc, col);
    const per: u32 = blk: {
        const requested = if ((q.cursor != null or q.cursorMode) and q.limit != null) q.limit.? else q.perPage;
        break :blk if (requested == 0) 30 else @min(requested, 500);
    };

    // ----- CURSOR (keyset) MODE -----
    // Entered when a token is supplied OR cursorMode is forced (the first page of a walk / when
    // offset mode is disabled). The first page (no token) has no keyset predicate, hasPrev=false.
    if (q.cursor != null or q.cursorMode) {
        // Reject un-mintable keyset sorts (relation-path / hidden) up front with a clear 400,
        // before any rows are fetched, so a cursor boundary is never silently null.
        try validateCursorSort(eff_terms);
        // The token binds to the PUBLIC effective-sort spec (e.g. "-created,id"), not the column
        // SQL — so an SDK that synthesizes the same spec produces a matching cursor.
        const eff_sort_str = try effectiveSortString(alloc, eff_terms);
        // Fold the SANITIZED search term into the cursor hash so a token minted under `?search=X` is
        // rejected when replayed with a different search (else the boundary would straddle a
        // different result set). Vector + cursor is rejected earlier, so the vector spec can't reach
        // here. `q.filter`/`q.rule` already bind the rest of the result-set shape.
        const fh = keyset.filterHash(q.filter, q.rule, search_term_hash);

        // Decode the boundary cursor (if any). first_page = no token supplied.
        const maybe_cur: ?keyset.Cursor = if (q.cursor) |token| try decodeCursor(alloc, q, conn, col, token, eff_sort_str, fh) else null;
        if (maybe_cur) |cur| if (cur.keys.len != eff_terms.len) return error.BadCursor;
        const forward = if (maybe_cur) |cur| cur.forward else true;

        // Keyset predicate (only when a boundary cursor is present), AND-ed onto filter+rule.
        var win_where: []const u8 = where_clause;
        var ks_params: []const compiler.Param = &.{};
        if (maybe_cur) |cur| {
            const ks = try keyset.build(alloc, eff_terms, cur.keys, forward, dialect);
            ks_params = ks.params;
            win_where = if (where_sql.len > 0)
                try std.fmt.allocPrint(alloc, " WHERE ({s}) AND {s}", .{ where_sql, ks.where_sql })
            else
                try std.fmt.allocPrint(alloc, " WHERE {s}", .{ks.where_sql});
        }

        // Backward travel: reverse the ORDER BY so the DB returns the rows CLOSEST to the boundary
        // going backward; we re-reverse the page into forward order after fetch.
        const fetch_order = if (forward) order_sql else try reversedOrderBy(alloc, eff_terms, dialect);

        const page_sql = try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\"{s}{s} ORDER BY {s} LIMIT ?;", .{ bcols, col.name, joins_sql.items, win_where, fetch_order }, 0);
        var pst = try prep(alloc, conn, page_sql);
        defer pst.finalize();
        var idx = try bindParams(&pst, params, 1);
        idx = try bindParams(&pst, ks_params, idx);
        try pst.bindInt(idx, @as(i64, per) + 1); // fetch limit+1 to detect "has more"

        var fetched: std.ArrayList(std.json.Value) = .empty;
        try fetched.ensureTotalCapacity(alloc, @as(usize, per) + 1); // fetch limit+1 — size once
        while (try pst.step()) try fetched.append(alloc, try rowToObject(alloc, &pst, col));

        const has_more = fetched.items.len > per;
        var kept = fetched.items;
        if (has_more) kept = kept[0..per];
        // Backward page: re-reverse into forward order.
        if (!forward) std.mem.reverse(std.json.Value, kept);

        // Navigation. On the FIRST page (no token) there is no previous page. Otherwise a page
        // reached via a forward cursor has a previous page, and one reached via a backward cursor
        // has a next page; the extra (N+1) row reveals more in the travel direction.
        var has_next = false;
        var has_prev = false;
        if (maybe_cur == null) {
            has_next = has_more;
            has_prev = false;
        } else if (forward) {
            has_next = has_more;
            has_prev = true;
        } else {
            has_prev = has_more;
            has_next = true;
        }
        var next_cursor: ?[]const u8 = null;
        var prev_cursor: ?[]const u8 = null;
        if (kept.len > 0) {
            if (has_next) next_cursor = try mintCursor(alloc, q, conn, col, eff_terms, kept[kept.len - 1], true, eff_sort_str, fh);
            if (has_prev) prev_cursor = try mintCursor(alloc, q, conn, col, eff_terms, kept[0], false, eff_sort_str, fh);
        }

        var total: ?i64 = null;
        if (!q.skipTotal) total = try countTotal(alloc, conn, col, joins_sql.items, where_clause, params);

        return .{
            .mode = .cursor,
            .page = 0,
            .perPage = per,
            .totalItems = total,
            .items = kept,
            .nextCursor = next_cursor,
            .prevCursor = prev_cursor,
            .hasNext = has_next,
            .hasPrev = has_prev,
        };
    }

    // ----- OFFSET MODE (unchanged wire behavior) -----
    const total = try countTotal(alloc, conn, col, joins_sql.items, where_clause, params);
    const page: u32 = if (q.page == 0) 1 else q.page;
    const offset: i64 = @as(i64, (page - 1)) * @as(i64, per);
    const page_sql = try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\"{s}{s} ORDER BY {s} LIMIT ? OFFSET ?;", .{ bcols, col.name, joins_sql.items, where_clause, offset_order_sql }, 0);
    var pst = try prep(alloc, conn, page_sql);
    defer pst.finalize();
    var after = try bindParams(&pst, params, 1);
    // The relevance ORDER BY carries up to two `?`s, in the SAME textual order they were prepended
    // to `offset_order_sql`: vector distance FIRST (`vector_order` is prepended last → leads), then
    // the Postgres `ts_rank` term (`search_order`), then LIMIT/OFFSET. Bind them in that exact order
    // so the placeholder indices line up. On SQLite both are null (bm25 `rank` takes no param; the
    // vector arm needs `-Dvector`), so this is byte-identical to the prior single-vector binding.
    if (vector_param) |vp| after = try bindParams(&pst, &.{vp}, after);
    if (search_order_param) |sp| after = try bindParams(&pst, &.{sp}, after);
    try pst.bindInt(after, @intCast(per));
    try pst.bindInt(after + 1, offset);

    var items: std.ArrayList(std.json.Value) = .empty;
    try items.ensureTotalCapacity(alloc, per); // at most `per` rows (LIMIT) — size once, no growth
    while (try pst.step()) try items.append(alloc, try rowToObject(alloc, &pst, col));
    const kept_items = try items.toOwnedSlice(alloc);
    const total_pages_rows: i64 = @as(i64, (page)) * @as(i64, per);
    return .{
        .mode = .offset,
        .page = page,
        .perPage = per,
        .totalItems = total,
        .items = kept_items,
        // Offset mode derives has_next/has_prev from page math so the handler can answer either.
        .hasNext = total > total_pages_rows,
        .hasPrev = page > 1,
    };
}

fn countTotal(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, joins: []const u8, where_clause: []const u8, params: []const compiler.Param) !i64 {
    const count_sql = try std.fmt.allocPrintSentinel(alloc, "SELECT COUNT(*) FROM \"{s}\"{s}{s};", .{ col.name, joins, where_clause }, 0);
    var cst = try prep(alloc, conn, count_sql);
    defer cst.finalize();
    _ = try bindParams(&cst, params, 1);
    _ = try cst.step();
    return cst.columnInt(0);
}

fn reversedOrderBy(alloc: std.mem.Allocator, terms: []const sort.SortTerm, dialect: db.Dialect) ![]u8 {
    const rev = try alloc.alloc(sort.SortTerm, terms.len);
    // `rev` is a scratch copy (SortTerms only borrow their slices); free it after building the
    // string so only the returned ORDER BY fragment remains allocated.
    defer alloc.free(rev);
    for (terms, 0..) |t, i| {
        rev[i] = t;
        rev[i].desc = !t.desc;
    }
    return sort.orderByFromTerms(alloc, rev, dialect);
}

pub fn bindParams(st: *db.Stmt, params: []const compiler.Param, start: c_int) !c_int {
    var idx = start;
    for (params) |p| {
        switch (p) {
            .text => |t| try st.bindText(idx, t),
            .int => |n| try st.bindInt(idx, n),
            .double => |dv| try st.bindDouble(idx, dv),
            .null => try st.bindNull(idx),
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

// ----- Cursor (keyset) pagination -----

fn seedSeq(d: *db.Db, n: usize) !void {
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const sql = try std.fmt.allocPrintSentinel(std.testing.allocator, "INSERT INTO posts (id,created,updated,title,price) VALUES ('r{d:0>3}','2026-01-{d:0>2}T00:00:00Z','t','t{d}',{d});", .{ i, i, i, i * 10 }, 0);
        defer std.testing.allocator.free(sql);
        try d.exec(sql);
    }
}

test "cursor: forward walk to exhaustion has no dup/skip and ends hasNext=false" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try seedSeq(&d, 7); // r001..r007, created ascending
    // Sort created ASC so the natural sequence is r001..r007.
    var seen: std.ArrayList([]const u8) = .empty;
    var cursor: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) {
        const res = try list(a, &d, col, .{ .sort = "created", .perPage = 3, .limit = 3, .cursor = cursor, .cursorMode = true });
        try std.testing.expectEqual(records_list_mode_cursor, res.mode);
        for (res.items) |it| try seen.append(a, it.object.get("id").?.string);
        pages += 1;
        if (!res.hasNext) {
            try std.testing.expect(res.nextCursor == null);
            break;
        }
        cursor = res.nextCursor.?;
        try std.testing.expect(pages < 10); // guard against an infinite loop
    }
    try std.testing.expectEqual(@as(usize, 7), seen.items.len);
    // Strictly increasing, no dup/skip.
    for (seen.items, 0..) |id, i| {
        var buf: [8]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "r{d:0>3}", .{i + 1});
        try std.testing.expectEqualStrings(want, id);
    }
}

const records_list_mode_cursor: ListMode = .cursor;

test "cursor: forward then prevCursor returns the prior window in forward order" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try seedSeq(&d, 6); // r001..r006
    // page 1 (r001,r002), page 2 (r003,r004)
    const p1 = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = null, .cursorMode = true });
    try std.testing.expectEqualStrings("r001", p1.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("r002", p1.items[1].object.get("id").?.string);
    try std.testing.expect(p1.hasNext);
    const p2 = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = p1.nextCursor.? });
    try std.testing.expectEqualStrings("r003", p2.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("r004", p2.items[1].object.get("id").?.string);
    try std.testing.expect(p2.hasPrev);
    // Walk back from page 2: should reproduce page 1 in forward order.
    const back = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = p2.prevCursor.? });
    try std.testing.expectEqual(@as(usize, 2), back.items.len);
    try std.testing.expectEqualStrings("r001", back.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("r002", back.items[1].object.get("id").?.string);
}

test "cursor: a deleted boundary row still paginates correctly (no skip)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try seedSeq(&d, 5); // r001..r005
    const p1 = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = null, .cursorMode = true });
    try std.testing.expectEqualStrings("r002", p1.items[1].object.get("id").?.string);
    // Delete the boundary row (r002) before fetching the next page.
    try d.exec("DELETE FROM posts WHERE id='r002';");
    const p2 = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = p1.nextCursor.? });
    // Keyset is value-based: the next window is still r003,r004 — no skip, no error.
    try std.testing.expectEqualStrings("r003", p2.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("r004", p2.items[1].object.get("id").?.string);
}

test "cursor: rule clause is still AND-ed (no rule bypass)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','2026-01-01T00:00:00Z','t','keep',1),('r2','2026-01-02T00:00:00Z','t','drop',1),('r3','2026-01-03T00:00:00Z','t','keep',1);");
    const res = try list(a, &d, col, .{ .sort = "created", .limit = 50, .rule = "title = \"keep\"", .cursor = null, .cursorMode = true });
    try std.testing.expectEqual(@as(usize, 2), res.items.len);
    try std.testing.expectEqualStrings("r1", res.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("r3", res.items[1].object.get("id").?.string);
    // The minted nextCursor must also carry the same filter binding (rule), so replaying it under
    // a different filter fails. With cursor==null no nextCursor here (only 2 rows < limit).
    try std.testing.expect(!res.hasNext);
}

test "cursor: skipTotal default omits the count; opt-in includes it" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try seedSeq(&d, 4);
    const cheap = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursorMode = true, .skipTotal = true });
    try std.testing.expect(cheap.totalItems == null);
    const withTotal = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursorMode = true, .skipTotal = false });
    try std.testing.expectEqual(@as(i64, 4), withTotal.totalItems.?);
}

test "cursor: changed sort/filter between pages is rejected (BadCursor variants)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try seedSeq(&d, 4);
    const p1 = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = null, .cursorMode = true });
    const tok = p1.nextCursor.?;
    // Different sort -> CursorSort.
    try std.testing.expectError(error.CursorSort, list(a, &d, col, .{ .sort = "-created", .limit = 2, .cursor = tok }));
    // Different filter -> CursorFilter.
    try std.testing.expectError(error.CursorFilter, list(a, &d, col, .{ .sort = "created", .limit = 2, .filter = "price > 0", .cursor = tok }));
    // Garbage token -> BadCursor.
    try std.testing.expectError(error.BadCursor, list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = "!!!garbage!!!" }));
}

test "cursor: signed token round-trips across pages and rejects tampering" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try seedSeq(&d, 4);
    const secret = "a-32-byte-minimum-test-secret!!!!";
    const p1 = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursorMode = true, .cursorToken = .signed, .signingSecret = secret });
    const tok = p1.nextCursor.?;
    const p2 = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = tok, .cursorToken = .signed, .signingSecret = secret });
    try std.testing.expectEqualStrings("r003", p2.items[0].object.get("id").?.string);
    // Tamper a byte -> CursorSig.
    const bad = try a.dupe(u8, tok);
    bad[0] = if (bad[0] == 'A') 'B' else 'A';
    try std.testing.expectError(error.CursorSig, list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = bad, .cursorToken = .signed, .signingSecret = secret }));
}

test "cursor: stateful token stores state, walks pages, and 410s on unknown id" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try seedSeq(&d, 4);
    const p1 = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursorMode = true, .cursorToken = .stateful, .io = std.testing.io, .writer = &d });
    const tok = p1.nextCursor.?;
    // The token is a short opaque id, not a base64 payload.
    try std.testing.expect(tok.len <= 64);
    const p2 = try list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = tok, .cursorToken = .stateful, .io = std.testing.io, .writer = &d });
    try std.testing.expectEqualStrings("r003", p2.items[0].object.get("id").?.string);
    // Unknown id -> CursorState (handler maps to 410).
    try std.testing.expectError(error.CursorState, list(a, &d, col, .{ .sort = "created", .limit = 2, .cursor = "deadbeefdeadbeefdeadbeefdeadbeef", .cursorToken = .stateful, .io = std.testing.io, .writer = &d }));
}

test "cursor: a hidden sort field is rejected (HiddenField) end-to-end, not silently null" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "secret", .hidden = true, .options = .{ .text = .{} } },
    };
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "notes", .fields = &fields });
    try d.exec("INSERT INTO notes (id,created,updated,title,secret) VALUES ('r1','t','t','a','x');");
    // Sorting a cursor walk by a hidden field must fail loudly rather than mint a null boundary. The
    // joiner rejects it (HiddenField) as the sort spec resolves — the single chokepoint — so this
    // asserts the end-to-end behavior through list(), before any rows are fetched.
    try std.testing.expectError(error.HiddenField, list(a, &d, col, .{ .sort = "secret", .cursorMode = true, .limit = 2 }));
}

test "cursor: a relation-path sort is rejected (BadCursorSort)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }} });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts2", .fields = &pf });
    try std.testing.expectError(error.BadCursorSort, list(a, &d, posts, .{ .sort = "author.name", .cursorMode = true, .limit = 2 }));
}

test "offset mode ORDER BY is unchanged (no id tiebreaker appended)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    // Two rows with the SAME created: offset order falls back to physical/rowid order (the prior
    // behavior), NOT an id tiebreaker — r1 then r2 as inserted.
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('z9','2026-01-01T00:00:00Z','t','a',1),('a1','2026-01-01T00:00:00Z','t','b',1);");
    const res = try list(a, &d, col, .{ .sort = "created", .page = 1, .perPage = 10 });
    try std.testing.expectEqual(records_list_mode_offset, res.mode);
    // Insertion order preserved (id tiebreaker would have put 'a1' before 'z9').
    try std.testing.expectEqualStrings("z9", res.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("a1", res.items[1].object.get("id").?.string);
}

const records_list_mode_offset: ListMode = .offset;

test "reversedOrderBy frees its scratch slice (no leak on the testing allocator)" {
    // Drive reversedOrderBy directly on the raw testing allocator: it allocates a `rev` scratch
    // copy of the terms and must free it, leaving only the returned string allocated. A leaked
    // `rev` fails this test (the testing allocator panics on teardown).
    const a = std.testing.allocator;
    const terms = [_]sort.SortTerm{
        .{ .col_sql = "\"posts\".\"created\"", .field = null, .desc = true, .path = "created" },
        .{ .col_sql = "\"posts\".\"id\"", .field = null, .desc = true, .path = "id" },
    };
    const ob = try reversedOrderBy(a, &terms, db.Dialect.sqlite);
    defer a.free(ob);
    // Reversed: DESC -> ASC for every term.
    try std.testing.expectEqualStrings("\"posts\".\"created\" ASC, \"posts\".\"id\" ASC", ob);
}

test "gcCursorStates prunes only expired rows" {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    try d.exec("INSERT INTO \"_cursorStates\" (\"id\",\"collectionRef\",\"payload\",\"expires\",\"created\") VALUES ('live','posts','{}',9999999999,''),('dead','posts','{}',1,'');");
    try gcCursorStates(&d);
    var st = try d.prepare("SELECT COUNT(*) FROM \"_cursorStates\";");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 1), st.columnInt(0));
}
