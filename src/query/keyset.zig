//! Keyset (cursor) pagination: the lexicographic WHERE-fragment generator and the opaque
//! cursor token codecs. See `docs/superpowers/specs/2026-06-16-native-cursor-pagination-*`.
//!
//! Two concerns live here:
//!   1. `build` — given the EFFECTIVE sort terms (caller has appended the id tiebreaker) and a
//!      boundary row's values, emit a NULL-aware OR-of-AND ladder parameterized through the same
//!      `compiler.Param` path filter literals use (injection-safe by construction).
//!   2. The token codec — a `Cursor` payload `{v,d,k,s,fh}` and three encodings selected by the
//!      comptime `pagination.CursorToken`: stateless (base64url JSON), signed (HMAC-SHA256 over
//!      the stateless bytes), stateful (a random id whose payload is stored in `_cursorStates`).
//!      The stateful store's DB glue lives in `records.zig`; here we expose the payload + the
//!      stateless/signed encoders the store reuses.

const std = @import("std");
const compiler = @import("compiler.zig");
const sort = @import("sort.zig");
const values = @import("../values.zig");
const schema = @import("../schema.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;

const b64 = std.base64.url_safe_no_pad;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Token format version. Bumped if the payload shape changes incompatibly.
pub const token_version: u8 = 1;
/// Hard cap on a raw cursor token length, checked BEFORE any base64 decode so a crafted
/// oversized token can't drive allocation (mirrors `records.max_filter_len`).
pub const max_cursor_len: usize = 2048;

pub const KeysetError = error{BadCursor} || values.ValueError || std.mem.Allocator.Error;

/// Distinguished cursor-decode failures, mapped to specific HTTP statuses by the handler:
///   BadCursor       -> 400 "Invalid cursor."
///   BadCursorSort   -> 400 "Cursor pagination requires a sortable, visible, non-relation sort field."
///   CursorSig       -> 400 "Invalid cursor signature."   (signed mode, bad/absent MAC)
///   CursorSort      -> 400 "Cursor does not match the requested sort."
///   CursorFilter    -> 400 "Cursor does not match the requested filter."
///   CursorState     -> 410 "Cursor expired."             (stateful mode, unknown/expired id)
pub const DecodeError = error{ BadCursor, BadCursorSort, CursorSig, CursorSort, CursorFilter, CursorState } || std.mem.Allocator.Error;

// ===========================================================================
// Keyset predicate generation (Step 2)
// ===========================================================================

pub const Keyset = struct { where_sql: []const u8, params: []const compiler.Param };

/// Map a boundary value (decoded from a token) to a bound `compiler.Param`, honoring the term's
/// resolved field exactly like filter literals: fixed/int decimal STRINGS scale to integers,
/// floats bind as doubles, text/date/id/bool as appropriate. System columns (`field == null`)
/// bind as text. `null` is handled by the caller (it emits IS NULL / IS NOT NULL, never a param).
fn jsonToParam(field: ?schema.Field, v: std.json.Value) KeysetError!compiler.Param {
    const f = field orelse {
        // System column (id/created/updated): text. Accept a JSON string; anything else is a
        // malformed token for a text column.
        if (v != .string) return error.BadCursor;
        return .{ .text = v.string };
    };
    switch (f.options) {
        .text, .email, .url, .editor, .date, .autodate => {
            if (v != .string) return error.BadCursor;
            return .{ .text = v.string };
        },
        .bool => {
            if (v != .bool) return error.BadCursor;
            return .{ .int = if (v.bool) 1 else 0 };
        },
        .number => |o| switch (o.mode) {
            .float => return switch (v) {
                .float => .{ .double = v.float },
                .integer => .{ .double = @floatFromInt(v.integer) },
                else => error.BadCursor,
            },
            .int => {
                if (v != .string) return error.BadCursor;
                return .{ .int = try values.decimalToScaledInt(v.string, 0) };
            },
            .fixed => {
                if (v != .string) return error.BadCursor;
                return .{ .int = try values.decimalToScaledInt(v.string, o.scale orelse 0) };
            },
        },
        // select/relation/file/json sort keys are not used as keyset boundaries (sort resolves
        // them to text columns at most); bind as text if a string arrives, else reject.
        else => {
            if (v != .string) return error.BadCursor;
            return .{ .text = v.string };
        },
    }
}

/// Build the keyset WHERE fragment + ordered params for a boundary row.
///
///   `terms`       — the EFFECTIVE sort (the caller has already appended the id tiebreaker term).
///   `boundary`    — one JSON value per term, in term order (decoded from the cursor token).
///   `forward`     — true for "rows strictly AFTER the boundary in sort order", false for before.
///
/// Emits the standard OR-of-AND ladder (SQLite has no portable mixed-direction tuple compare):
///   (t1 OP1 v1)
///   OR (t1 = v1 AND t2 OP2 v2)
///   OR ... OR (t1=v1 AND ... AND t{N-1}=v{N-1} AND tN OPN vN)
/// where OPi is `>` for ASC / `<` for DESC on a forward page, flipped for a backward page.
/// NULLs are made explicit and deterministic to match SQLite's ORDER BY NULL placement
/// (NULLs FIRST in ASC, LAST in DESC). The whole fragment is wrapped in one set of parens,
/// ready to AND onto the existing filter+rule clause.
pub fn build(alloc: std.mem.Allocator, terms: []const sort.SortTerm, boundary: []const std.json.Value, forward: bool, dialect: Dialect) KeysetError!Keyset {
    if (terms.len == 0 or terms.len != boundary.len) return error.BadCursor;

    var sql: std.ArrayList(u8) = .empty;
    errdefer sql.deinit(alloc);
    var params: std.ArrayList(compiler.Param) = .empty;
    errdefer params.deinit(alloc);

    try sql.append(alloc, '(');
    // One OR-rung per term i: equality on terms 0..i-1, then a strict comparison on term i.
    var i: usize = 0;
    while (i < terms.len) : (i += 1) {
        if (i != 0) try sql.appendSlice(alloc, " OR ");
        try sql.append(alloc, '(');
        // Equality prefix (terms 0..i-1).
        var k: usize = 0;
        while (k < i) : (k += 1) {
            try emitEqRung(alloc, &sql, &params, terms[k], boundary[k]);
            try sql.appendSlice(alloc, " AND ");
        }
        // Strict comparison on term i.
        try emitCmpRung(alloc, &sql, &params, terms[i], boundary[i], forward, dialect);
        try sql.append(alloc, ')');
    }
    try sql.append(alloc, ')');

    return .{
        .where_sql = try sql.toOwnedSlice(alloc),
        .params = try params.toOwnedSlice(alloc),
    };
}

/// `ti = vi`, NULL-aware: a NULL boundary becomes `ti IS NULL` (since `= NULL` is never true).
fn emitEqRung(alloc: std.mem.Allocator, sql: *std.ArrayList(u8), params: *std.ArrayList(compiler.Param), term: sort.SortTerm, v: std.json.Value) KeysetError!void {
    if (v == .null) {
        try sql.appendSlice(alloc, term.col_sql);
        try sql.appendSlice(alloc, " IS NULL");
        return;
    }
    try sql.appendSlice(alloc, term.col_sql);
    try sql.appendSlice(alloc, " = ?");
    try params.append(alloc, try jsonToParam(term.field, v));
}

/// True iff the term's column can hold a NULL: system columns (id/created/updated) and required
/// user fields are NOT NULL, so their comparison rungs can skip the IS NULL branch (tighter SQL).
fn nullable(term: sort.SortTerm) bool {
    const f = term.field orelse return false; // system columns are never NULL
    return !f.required;
}

/// Strict "after the boundary on term i" comparison, NULL-aware and direction-aware.
///
/// Effective direction for THIS page = term.desc XOR (!forward): a backward page flips every op.
/// With ASC-effective the ordering is NULLs-first then ascending values; "strictly after vi" is:
///   - vi IS NULL  -> `ti IS NOT NULL`           (any non-NULL comes after a leading NULL)
///   - else        -> `ti > vi`                  (NULLs already passed; SQLite drops NULL rows here)
/// With DESC-effective the ordering is descending values then NULLs-last; "strictly after vi" is:
///   - vi IS NULL  -> `0`  (nothing comes after a trailing NULL — emit a never-true predicate)
///   - else        -> `ti < vi` (+ `OR ti IS NULL` only when the column is nullable — a trailing
///                    NULL comes after any non-NULL value)
fn emitCmpRung(alloc: std.mem.Allocator, sql: *std.ArrayList(u8), params: *std.ArrayList(compiler.Param), term: sort.SortTerm, v: std.json.Value, forward: bool, dialect: Dialect) KeysetError!void {
    const asc_effective = term.desc == !forward; // term.desc XOR (!forward) == false  -> ASC
    if (asc_effective) {
        if (v == .null) {
            try sql.appendSlice(alloc, term.col_sql);
            try sql.appendSlice(alloc, " IS NOT NULL");
        } else {
            try sql.appendSlice(alloc, term.col_sql);
            try sql.appendSlice(alloc, " > ?");
            try params.append(alloc, try jsonToParam(term.field, v));
        }
    } else {
        if (v == .null) {
            // Nothing sorts after a trailing NULL: a never-true rung keeps the ladder well-formed.
            // SQLite accepts the bare `0`; Postgres needs `false` (a boolean context).
            try sql.appendSlice(alloc, dialect.constFalse());
        } else if (nullable(term)) {
            try sql.append(alloc, '(');
            try sql.appendSlice(alloc, term.col_sql);
            try sql.appendSlice(alloc, " < ? OR ");
            try sql.appendSlice(alloc, term.col_sql);
            try sql.appendSlice(alloc, " IS NULL)");
            try params.append(alloc, try jsonToParam(term.field, v));
        } else {
            try sql.appendSlice(alloc, term.col_sql);
            try sql.appendSlice(alloc, " < ?");
            try params.append(alloc, try jsonToParam(term.field, v));
        }
    }
}

// ===========================================================================
// Cursor token payload + stateless/signed codecs (Step 3)
// ===========================================================================

/// The decoded cursor payload shared by all three token formats.
pub const Cursor = struct {
    /// Direction of travel: true = forward ("after"), false = backward ("before").
    forward: bool,
    /// Boundary sort-key values in effective-sort order (id last). For a DECODED cursor these
    /// alias `owned`'s parse arena; free them by calling `deinit`.
    keys: []std.json.Value,
    /// The EFFECTIVE sort string (with id tiebreaker), for sort-binding validation.
    sort_str: []const u8,
    /// fnv64 of the normalized filter + rule, for filter-binding validation.
    filter_hash: u64,
    /// The owned `std.json` parse result that `keys`/`sort_str` alias for a DECODED cursor
    /// (contract 2: caller frees via `deinit`). null for a caller-built/encode-side cursor
    /// (`mintCursor`, tests) — `deinit` is then a no-op.
    owned: ?std.json.Parsed(Wire) = null,

    /// Free the parse arena backing a decoded cursor's `keys`/`sort_str`. No allocator argument —
    /// `std.json.Parsed` carries its own arena. A no-op for a cursor with no owned backing. Takes
    /// `*Cursor` and clears `owned` so a repeat call is a safe no-op (and `keys`/`sort_str` are
    /// visibly invalidated), rather than double-freeing the arena.
    pub fn deinit(self: *Cursor) void {
        if (self.owned) |p| {
            p.deinit();
            self.owned = null;
        }
    }
};

/// On-wire payload struct (compact keys: v/d/k/s/fh). `d` is "f"/"b"; `fh` is a hex string so it
/// round-trips losslessly through JSON (u64 can exceed JSON's safe-integer range).
const Wire = struct {
    v: u8,
    d: []const u8,
    k: []std.json.Value,
    s: []const u8,
    fh: []const u8,
};

/// fnv64 of the normalized (trimmed) filter and rule expressions, in a fixed order with a
/// separator so distinct (filter, rule) pairs can't collide by concatenation. A null/empty
/// filter or rule hashes as the empty string.
pub fn filterHash(filter: ?[]const u8, rule: ?[]const u8, search: ?[]const u8) u64 {
    var h = std.hash.Fnv1a_64.init();
    const f = std.mem.trim(u8, filter orelse "", " \t\r\n");
    const r = std.mem.trim(u8, rule orelse "", " \t\r\n");
    const s = std.mem.trim(u8, search orelse "", " \t\r\n");
    h.update(f);
    h.update("\x00"); // unambiguous separator
    h.update(r);
    h.update("\x00");
    h.update(s); // the full-text search term (#157): a cursor is bound to its search too
    return h.final();
}

/// Serialize a `Cursor` to its raw JSON payload bytes (pre-base64). Shared by all encoders.
fn payloadBytes(alloc: std.mem.Allocator, c: Cursor) ![]u8 {
    var fh_buf: [16]u8 = undefined;
    const fh_hex = try std.fmt.bufPrint(&fh_buf, "{x:0>16}", .{c.filter_hash});
    const w = Wire{
        .v = token_version,
        .d = if (c.forward) "f" else "b",
        .k = c.keys,
        .s = c.sort_str,
        .fh = fh_hex,
    };
    return std.json.Stringify.valueAlloc(alloc, w, .{});
}

/// Parse raw JSON payload bytes back into a `Cursor` (no signature/state concerns).
fn parsePayload(alloc: std.mem.Allocator, json_bytes: []const u8) DecodeError!Cursor {
    // `.alloc_always`: copy every string/value into the parse arena so the returned Cursor aliases
    // ONLY `parsed` (freed by `Cursor.deinit`), never the caller's `json_bytes` (b64 buffer). The
    // Parsed wrapper is RETAINED in `.owned` — the reject paths below errdefer-free it.
    const parsed = std.json.parseFromSlice(Wire, alloc, json_bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.BadCursor;
    errdefer parsed.deinit();
    const w = parsed.value;
    if (w.v != token_version) return error.BadCursor;
    const forward = if (std.mem.eql(u8, w.d, "f")) true else if (std.mem.eql(u8, w.d, "b")) false else return error.BadCursor;
    const fh = std.fmt.parseInt(u64, w.fh, 16) catch return error.BadCursor;
    return .{ .forward = forward, .keys = w.k, .sort_str = w.s, .filter_hash = fh, .owned = parsed };
}

/// Encode a `Cursor` as a STATELESS token (Approach A): base64url(payload).
pub fn encodeStateless(alloc: std.mem.Allocator, c: Cursor) ![]u8 {
    const payload = try payloadBytes(alloc, c);
    defer alloc.free(payload); // scratch: b64Encode copies it into the returned token
    return b64Encode(alloc, payload);
}

/// Decode a STATELESS token. Enforces the length cap before decode; maps all structural
/// failures to `error.BadCursor`.
pub fn decodeStateless(alloc: std.mem.Allocator, token: []const u8) DecodeError!Cursor {
    if (token.len > max_cursor_len) return error.BadCursor;
    const payload = b64Decode(alloc, token) catch return error.BadCursor;
    defer alloc.free(payload); // scratch: parsePayload copies (alloc_always) into the Cursor's arena
    return parsePayload(alloc, payload);
}

/// Encode a `Cursor` as a SIGNED token (Approach B): base64url(payload) ++ "." ++ base64url(mac),
/// where mac = HMAC-SHA256(payload_b64, secret). Signing the base64 text (not the raw bytes)
/// keeps verification a simple split-on-'.' with no re-encode ambiguity.
pub fn encodeSigned(alloc: std.mem.Allocator, c: Cursor, secret: []const u8) ![]u8 {
    const payload = try payloadBytes(alloc, c);
    defer alloc.free(payload); // scratch
    const p_b64 = try b64Encode(alloc, payload);
    defer alloc.free(p_b64); // scratch: copied into the returned token by allocPrint
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, p_b64, secret);
    const mac_b64 = try b64Encode(alloc, &mac);
    defer alloc.free(mac_b64); // scratch: copied into the returned token by allocPrint
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ p_b64, mac_b64 });
}

/// Decode + verify a SIGNED token. A missing/short/non-matching MAC -> `error.CursorSig`;
/// a malformed payload -> `error.BadCursor`.
pub fn decodeSigned(alloc: std.mem.Allocator, token: []const u8, secret: []const u8) DecodeError!Cursor {
    if (token.len > max_cursor_len) return error.BadCursor;
    var it = std.mem.splitScalar(u8, token, '.');
    const p_b64 = it.next() orelse return error.BadCursor;
    const mac_b64 = it.next() orelse return error.CursorSig;
    if (it.next() != null) return error.BadCursor;

    var expected: [32]u8 = undefined;
    HmacSha256.create(&expected, p_b64, secret);
    const provided = b64Decode(alloc, mac_b64) catch return error.CursorSig;
    defer alloc.free(provided); // scratch: only compared, never escapes
    if (provided.len != 32) return error.CursorSig;
    if (!std.crypto.timing_safe.eql([32]u8, expected, provided[0..32].*)) return error.CursorSig;

    const payload = b64Decode(alloc, p_b64) catch return error.BadCursor;
    defer alloc.free(payload); // scratch: parsePayload copies (alloc_always) into the Cursor's arena
    return parsePayload(alloc, payload);
}

/// Encode the STATEFUL payload (Approach C) the server stores server-side. The stored blob is
/// just the stateless payload bytes; `records.zig` writes them keyed by a random opaque id and
/// hands the client only the id. Re-uses the same JSON the stateless codec produces.
pub fn statefulPayload(alloc: std.mem.Allocator, c: Cursor) ![]u8 {
    return payloadBytes(alloc, c);
}

/// Decode a stored STATEFUL payload (the blob `statefulPayload` produced) back into a `Cursor`.
pub fn decodeStatefulPayload(alloc: std.mem.Allocator, payload: []const u8) DecodeError!Cursor {
    return parsePayload(alloc, payload);
}

fn b64Encode(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, b64.Encoder.calcSize(data.len));
    _ = b64.Encoder.encode(out, data);
    return out;
}

fn b64Decode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, try b64.Decoder.calcSizeForSlice(s));
    errdefer alloc.free(out); // a malformed-base64 `decode` failure must not leak the buffer
    try b64.Decoder.decode(out, s);
    return out;
}

// ===========================================================================
// Tests — keyset SQL (Step 2)
// ===========================================================================

const testing = std.testing;

fn sysTerm(col_sql: []const u8, desc: bool) sort.SortTerm {
    return .{ .col_sql = col_sql, .field = null, .desc = desc, .path = "x" };
}
fn fieldTerm(col_sql: []const u8, field: schema.Field, desc: bool) sort.SortTerm {
    return .{ .col_sql = col_sql, .field = field, .desc = desc, .path = "x" };
}

test "keyset: single ASC term + id tiebreaker, forward" {
    const a = testing.allocator;
    const terms = [_]sort.SortTerm{ sysTerm("c", false), sysTerm("id", false) };
    const boundary = [_]std.json.Value{ .{ .string = "2026-01-03T00:00:00Z" }, .{ .string = "r3" } };
    const ks = try build(a, &terms, &boundary, true, Dialect.sqlite);
    defer {
        a.free(ks.where_sql);
        a.free(ks.params);
    }
    try testing.expectEqualStrings("((c > ?) OR (c = ? AND id > ?))", ks.where_sql);
    try testing.expectEqual(@as(usize, 3), ks.params.len);
    try testing.expectEqualStrings("2026-01-03T00:00:00Z", ks.params[0].text);
    try testing.expectEqualStrings("2026-01-03T00:00:00Z", ks.params[1].text);
    try testing.expectEqualStrings("r3", ks.params[2].text);
}

test "keyset: single DESC term flips the operator" {
    const a = testing.allocator;
    const terms = [_]sort.SortTerm{ sysTerm("c", true), sysTerm("id", true) };
    const boundary = [_]std.json.Value{ .{ .string = "2026-01-03T00:00:00Z" }, .{ .string = "r3" } };
    const ks = try build(a, &terms, &boundary, true, Dialect.sqlite);
    defer {
        a.free(ks.where_sql);
        a.free(ks.params);
    }
    try testing.expectEqualStrings("((c < ?) OR (c = ? AND id < ?))", ks.where_sql);
}

test "keyset: backward flips every comparison op" {
    const a = testing.allocator;
    // forward DESC -> '<'; backward DESC -> '>'
    const terms = [_]sort.SortTerm{ sysTerm("c", true), sysTerm("id", true) };
    const boundary = [_]std.json.Value{ .{ .string = "t" }, .{ .string = "r3" } };
    const ks = try build(a, &terms, &boundary, false, Dialect.sqlite);
    defer {
        a.free(ks.where_sql);
        a.free(ks.params);
    }
    try testing.expectEqualStrings("((c > ?) OR (c = ? AND id > ?))", ks.where_sql);
}

test "keyset: mixed DESC,ASC uses the per-term operator" {
    const a = testing.allocator;
    // effective: created DESC, price ASC, id ASC
    const terms = [_]sort.SortTerm{ sysTerm("created", true), sysTerm("price", false), sysTerm("id", false) };
    const boundary = [_]std.json.Value{ .{ .string = "t" }, .{ .string = "2.00" }, .{ .string = "r3" } };
    const ks = try build(a, &terms, &boundary, true, Dialect.sqlite);
    defer {
        a.free(ks.where_sql);
        a.free(ks.params);
    }
    try testing.expectEqualStrings(
        "((created < ?) OR (created = ? AND price > ?) OR (created = ? AND price = ? AND id > ?))",
        ks.where_sql,
    );
}

test "keyset: NULL boundary, ASC term (NULLs first)" {
    const a = testing.allocator;
    // score ASC nullable, id ASC; boundary score is NULL -> cmp rung 'IS NOT NULL', no param
    const terms = [_]sort.SortTerm{ sysTerm("score", false), sysTerm("id", false) };
    const boundary = [_]std.json.Value{ .null, .{ .string = "r3" } };
    const ks = try build(a, &terms, &boundary, true, Dialect.sqlite);
    defer {
        a.free(ks.where_sql);
        a.free(ks.params);
    }
    try testing.expectEqualStrings("((score IS NOT NULL) OR (score IS NULL AND id > ?))", ks.where_sql);
    try testing.expectEqual(@as(usize, 1), ks.params.len);
    try testing.expectEqualStrings("r3", ks.params[0].text);
}

test "keyset: NULL boundary, DESC term (NULLs last) is never-true on the cmp rung" {
    const a = testing.allocator;
    const score = schema.Field{ .id = "s", .name = "score", .options = .{ .number = .{ .mode = .float } } };
    const terms = [_]sort.SortTerm{ fieldTerm("score", score, true), sysTerm("id", false) };
    const boundary = [_]std.json.Value{ .null, .{ .string = "r3" } };
    const ks = try build(a, &terms, &boundary, true, Dialect.sqlite);
    defer {
        a.free(ks.where_sql);
        a.free(ks.params);
    }
    try testing.expectEqualStrings("((0) OR (score IS NULL AND id > ?))", ks.where_sql);
}

test "keyset: non-NULL boundary over a nullable DESC column uses (< OR IS NULL)" {
    const a = testing.allocator;
    // a nullable (not required) float field
    const score = schema.Field{ .id = "s", .name = "score", .options = .{ .number = .{ .mode = .float } } };
    const terms = [_]sort.SortTerm{ fieldTerm("score", score, true), sysTerm("id", false) };
    const boundary = [_]std.json.Value{ .{ .float = 1.5 }, .{ .string = "r3" } };
    const ks = try build(a, &terms, &boundary, true, Dialect.sqlite);
    defer {
        a.free(ks.where_sql);
        a.free(ks.params);
    }
    // Boundary score is non-NULL (1.5), so the equality rung is `score = ?`, not `IS NULL`.
    // The cmp rung's own parens nest inside the OR-rung parens: ((...)).
    try testing.expectEqualStrings("(((score < ? OR score IS NULL)) OR (score = ? AND id > ?))", ks.where_sql);
}

test "keyset: a REQUIRED column skips the IS NULL branch on a DESC cmp rung" {
    const a = testing.allocator;
    const score = schema.Field{ .id = "s", .name = "score", .required = true, .options = .{ .number = .{ .mode = .float } } };
    const terms = [_]sort.SortTerm{ fieldTerm("score", score, true), sysTerm("id", false) };
    const boundary = [_]std.json.Value{ .{ .float = 1.5 }, .{ .string = "r3" } };
    const ks = try build(a, &terms, &boundary, true, Dialect.sqlite);
    defer {
        a.free(ks.where_sql);
        a.free(ks.params);
    }
    try testing.expectEqualStrings("((score < ?) OR (score = ? AND id > ?))", ks.where_sql);
}

test "keyset: type coercion into the right Param variant" {
    const a = testing.allocator;
    const price = schema.Field{ .id = "f", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } };
    const ratio = schema.Field{ .id = "g", .name = "ratio", .options = .{ .number = .{ .mode = .float } } };
    const terms = [_]sort.SortTerm{ fieldTerm("price", price, false), fieldTerm("ratio", ratio, false), sysTerm("id", false) };
    const boundary = [_]std.json.Value{ .{ .string = "10.50" }, .{ .float = 1.5 }, .{ .string = "r3" } };
    const ks = try build(a, &terms, &boundary, true, Dialect.sqlite);
    defer {
        a.free(ks.where_sql);
        a.free(ks.params);
    }
    // Param order follows the OR-of-AND ladder (eq prefixes repeat boundary values):
    //   [price>], [price=, ratio>], [price=, ratio=, id>]
    // => [int, int, double, int, double, text]. fixed "10.50" -> int 1050; float -> double; id -> text.
    try testing.expectEqual(@as(usize, 6), ks.params.len);
    try testing.expectEqual(@as(i64, 1050), ks.params[0].int);
    try testing.expectApproxEqAbs(@as(f64, 1.5), ks.params[2].double, 1e-9);
    try testing.expectEqualStrings("r3", ks.params[5].text);
}

test "keyset: injection-safe — SQL metacharacters stay in params, never the SQL" {
    const a = testing.allocator;
    const terms = [_]sort.SortTerm{ sysTerm("c", false), sysTerm("id", false) };
    const evil = "x'); DROP TABLE posts;--";
    const boundary = [_]std.json.Value{ .{ .string = evil }, .{ .string = "r3" } };
    const ks = try build(a, &terms, &boundary, true, Dialect.sqlite);
    defer {
        a.free(ks.where_sql);
        a.free(ks.params);
    }
    try testing.expect(std.mem.indexOf(u8, ks.where_sql, "DROP") == null);
    try testing.expectEqualStrings(evil, ks.params[0].text);
}

test "keyset: arity mismatch and empty terms are rejected" {
    const a = testing.allocator;
    const terms = [_]sort.SortTerm{sysTerm("c", false)};
    const two = [_]std.json.Value{ .{ .string = "a" }, .{ .string = "b" } };
    try testing.expectError(error.BadCursor, build(a, &terms, &two, true, Dialect.sqlite));
    const none = [_]sort.SortTerm{};
    const nonev = [_]std.json.Value{};
    try testing.expectError(error.BadCursor, build(a, &none, &nonev, true, Dialect.sqlite));
}

// ===========================================================================
// Tests — token codecs (Step 3)
// ===========================================================================

fn sampleCursor(a: std.mem.Allocator) !Cursor {
    var keys = try a.alloc(std.json.Value, 2);
    keys[0] = .{ .string = "2026-01-03T00:00:00Z" };
    keys[1] = .{ .string = "r3" };
    return .{ .forward = true, .keys = keys, .sort_str = "-created,id", .filter_hash = 0xABCD1234 };
}

fn expectSameCursor(want: Cursor, got: Cursor) !void {
    try testing.expectEqual(want.forward, got.forward);
    try testing.expectEqualStrings(want.sort_str, got.sort_str);
    try testing.expectEqual(want.filter_hash, got.filter_hash);
    try testing.expectEqual(want.keys.len, got.keys.len);
    try testing.expectEqualStrings(want.keys[0].string, got.keys[0].string);
    try testing.expectEqualStrings(want.keys[1].string, got.keys[1].string);
}

test "stateless codec round-trips" {
    const a = testing.allocator;
    const c = try sampleCursor(a);
    defer a.free(c.keys); // sampleCursor's keys are manually allocated (owned == null)
    const tok = try encodeStateless(a, c);
    defer a.free(tok);
    var back = try decodeStateless(a, tok);
    defer back.deinit(); // decoded cursor owns its parse arena
    try expectSameCursor(c, back);
}

test "stateless: oversized token rejected before decode" {
    const a = testing.allocator;
    const big = try a.alloc(u8, max_cursor_len + 1);
    defer a.free(big);
    @memset(big, 'A');
    try testing.expectError(error.BadCursor, decodeStateless(a, big));
}

test "stateless: malformed base64 / payload rejected" {
    const a = testing.allocator;
    try testing.expectError(error.BadCursor, decodeStateless(a, "!!!not base64!!!"));
    const not_json = try b64Encode(a, "this is not json");
    defer a.free(not_json);
    try testing.expectError(error.BadCursor, decodeStateless(a, not_json));
}

test "stateless: unknown version rejected" {
    const a = testing.allocator;
    const bad = try b64Encode(a, "{\"v\":99,\"d\":\"f\",\"k\":[],\"s\":\"id\",\"fh\":\"0\"}");
    defer a.free(bad);
    try testing.expectError(error.BadCursor, decodeStateless(a, bad));
}

test "signed codec round-trips and rejects tampering" {
    const a = testing.allocator;
    const secret = "a-very-long-server-jwt-secret-32b!!";
    const c = try sampleCursor(a);
    defer a.free(c.keys); // sampleCursor's keys are manually allocated (owned == null)
    const tok = try encodeSigned(a, c, secret);
    defer a.free(tok);
    var back = try decodeSigned(a, tok, secret);
    defer back.deinit(); // decoded cursor owns its parse arena
    try expectSameCursor(c, back);

    // Flip a byte in the payload portion -> MAC fails.
    const tampered = try a.dupe(u8, tok);
    defer a.free(tampered);
    tampered[0] = if (tampered[0] == 'A') 'B' else 'A';
    try testing.expectError(error.CursorSig, decodeSigned(a, tampered, secret));

    // Wrong secret -> MAC fails.
    try testing.expectError(error.CursorSig, decodeSigned(a, tok, "a-different-but-also-32b-secret!!!!"));

    // Missing MAC segment -> CursorSig.
    try testing.expectError(error.CursorSig, decodeSigned(a, "onlypayload", secret));
}

test "stateful payload round-trips through the store blob form" {
    const a = testing.allocator;
    const c = try sampleCursor(a);
    defer a.free(c.keys); // sampleCursor's keys are manually allocated (owned == null)
    const blob = try statefulPayload(a, c);
    defer a.free(blob);
    var back = try decodeStatefulPayload(a, blob);
    defer back.deinit(); // decoded cursor owns its parse arena
    try expectSameCursor(c, back);
}

test "filterHash: stable, whitespace-normalized, order-sensitive between filter and rule" {
    try testing.expectEqual(filterHash("a = 1", "b = 2", null), filterHash("  a = 1 ", "b = 2\n", null));
    try testing.expect(filterHash("a = 1", "b = 2", null) != filterHash("b = 2", "a = 1", null));
    try testing.expectEqual(filterHash(null, null, null), filterHash("", "", ""));
    try testing.expect(filterHash("a", null, null) != filterHash(null, "a", null));
    // The search term participates: same filter+rule but a different search => a different hash.
    try testing.expect(filterHash("a = 1", null, "zig") != filterHash("a = 1", null, "rust"));
    try testing.expectEqual(filterHash("a = 1", null, null), filterHash("a = 1", null, ""));
}
