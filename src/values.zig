const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const field_policy = @import("field_policy.zig");

pub const ValueError = error{ TypeMismatch, TooPrecise, Overflow, BadNumber, BadSelect, NotObject } || std.mem.Allocator.Error;

/// Raised when an `.encrypted` field is read or written but no field cipher is
/// configured on the connection (ZIGBASE_FIELD_KEY unset). Fail-closed: we never
/// store an encrypted field as plaintext, nor return ciphertext as plaintext.
pub const EncryptError = error{FieldKeyMissing};

/// Recover a pointer to the field cipher (key-ring) stamped on the connection
/// (db.Db.field_cipher), or null. Returns a pointer so the whole ring is not
/// copied per value.
fn cipherOf(stmt: *db.Stmt) ?*const field_policy.Cipher {
    const p = db.stmtFieldCipher(stmt) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Bind a storage string, sealing it into an at-rest envelope first when the field
/// is `.encrypted`. Fail-closed: an encrypted field with no configured cipher errors.
fn bindStorage(alloc: std.mem.Allocator, stmt: *db.Stmt, idx: c_int, field: schema.Field, storage: []const u8) (EncryptError || db.DbError || std.mem.Allocator.Error)!void {
    if (field.encrypted) {
        const cph = cipherOf(stmt) orelse return error.FieldKeyMissing;
        return stmt.bindText(idx, try cph.seal(alloc, storage));
    }
    return stmt.bindText(idx, storage);
}

/// Read a column's storage string, STRICTLY decrypting it when the field is
/// `.encrypted`. A legacy/plaintext or undecryptable stored value fails closed.
fn readStorage(alloc: std.mem.Allocator, stmt: *db.Stmt, idx: c_int, field: schema.Field) ![]u8 {
    const raw = stmt.columnText(idx);
    if (field.encrypted) {
        const cph = cipherOf(stmt) orelse return error.FieldKeyMissing;
        return cph.open(alloc, raw);
    }
    return alloc.dupe(u8, raw);
}

/// 10^scale as i64. error.Overflow when scale > 18 (i64 holds up to 10^18).
/// The single source of scale arithmetic for fixed/int number handling.
pub fn pow10(scale: u8) error{Overflow}!i64 {
    if (scale > 18) return error.Overflow;
    var p: i64 = 1;
    var k: u8 = 0;
    while (k < scale) : (k += 1) p *= 10;
    return p;
}

pub fn decimalToScaledInt(s: []const u8, scale: u8) ValueError!i64 {
    if (s.len == 0) return error.BadNumber;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') {
        neg = true;
        i = 1;
    } else if (s[0] == '+') {
        i = 1;
    }
    var int_part: i64 = 0;
    var seen = false;
    while (i < s.len and s[i] != '.') : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return error.BadNumber;
        seen = true;
        int_part = std.math.mul(i64, int_part, 10) catch return error.Overflow;
        int_part = std.math.add(i64, int_part, s[i] - '0') catch return error.Overflow;
    }
    var frac: i64 = 0;
    var fdigits: u8 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len) : (i += 1) {
            if (s[i] < '0' or s[i] > '9') return error.BadNumber;
            seen = true;
            if (fdigits >= scale) return error.TooPrecise;
            frac = frac * 10 + (s[i] - '0');
            fdigits += 1;
        }
    }
    if (!seen) return error.BadNumber;
    const pow = try pow10(scale);
    while (fdigits < scale) : (fdigits += 1) frac *= 10;
    var result = std.math.mul(i64, int_part, pow) catch return error.Overflow;
    result = std.math.add(i64, result, frac) catch return error.Overflow;
    return if (neg) -result else result;
}

pub fn scaledIntToDecimal(alloc: std.mem.Allocator, v: i64, scale: u8) ![]u8 {
    if (scale == 0) return std.fmt.allocPrint(alloc, "{d}", .{v});
    // -minInt(i64) overflows; only reachable via direct DB tampering since
    // decimalToScaledInt is overflow-checked. Reject rather than panic.
    if (v == std.math.minInt(i64)) return error.Overflow;
    const pow = try pow10(scale);
    const neg = v < 0;
    const av: i64 = if (neg) -v else v;
    const int_part = @divTrunc(av, pow);
    const frac_part = @rem(av, pow);
    var fbuf: [24]u8 = undefined;
    const fs = try std.fmt.bufPrint(&fbuf, "{d}", .{frac_part});
    const pad = scale - @as(u8, @intCast(fs.len));
    var ibuf: [24]u8 = undefined;
    const is = try std.fmt.bufPrint(&ibuf, "{d}", .{int_part});
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (neg) try out.append(alloc, '-');
    try out.appendSlice(alloc, is);
    try out.append(alloc, '.');
    var p: u8 = 0;
    while (p < pad) : (p += 1) try out.append(alloc, '0');
    try out.appendSlice(alloc, fs);
    return out.toOwnedSlice(alloc);
}

/// Bind a `std.json.Value` into a prepared statement parameter according to the field's type.
pub fn bindValue(alloc: std.mem.Allocator, stmt: *db.Stmt, idx: c_int, field: schema.Field, v: std.json.Value) (ValueError || db.DbError || EncryptError)!void {
    if (v == .null) return stmt.bindNull(idx);
    switch (field.options) {
        .text, .email, .url, .editor, .date, .autodate => {
            if (v != .string) return error.TypeMismatch;
            try bindStorage(alloc, stmt, idx, field, v.string);
        },
        .bool => {
            if (v != .bool) return error.TypeMismatch;
            try stmt.bindInt(idx, if (v.bool) 1 else 0);
        },
        .number => |o| switch (o.mode) {
            .float => {
                const f: f64 = switch (v) {
                    .float => v.float,
                    .integer => @floatFromInt(v.integer),
                    else => return error.TypeMismatch,
                };
                try stmt.bindDouble(idx, f);
            },
            .int => {
                // Symmetric with reads (which RETURN `.string`): accept a JSON string
                // (the canonical form), a JSON integer (bind directly), or a JSON float
                // (rendered to a decimal string — a fractional float then errors via
                // decimalToScaledInt(str, 0), which is the correct rejection for an int field).
                switch (v) {
                    .string => try stmt.bindInt(idx, try decimalToScaledInt(v.string, 0)),
                    .integer => try stmt.bindInt(idx, v.integer),
                    .float => {
                        const str = try std.fmt.allocPrint(alloc, "{d}", .{v.float});
                        defer alloc.free(str);
                        try stmt.bindInt(idx, try decimalToScaledInt(str, 0));
                    },
                    else => return error.TypeMismatch,
                }
            },
            .fixed => {
                // Symmetric with reads: accept a JSON string (canonical) or a JSON number.
                // A number is rendered to a decimal string and scaled through the SAME
                // render→scale path as the string form, so `.float = 5.0` on a fixed(scale=2)
                // field scales to 500, identically to the string "5.0"/"5.00". `v.string` is
                // BORROWED (not owned) — only the two allocPrint arms allocate, so only those
                // get freed.
                var allocated: ?[]u8 = null;
                const str = switch (v) {
                    .string => v.string,
                    .integer => blk: {
                        allocated = try std.fmt.allocPrint(alloc, "{d}", .{v.integer});
                        break :blk allocated.?;
                    },
                    .float => blk: {
                        allocated = try std.fmt.allocPrint(alloc, "{d}", .{v.float});
                        break :blk allocated.?;
                    },
                    else => return error.TypeMismatch,
                };
                defer if (allocated) |s| alloc.free(s);
                try stmt.bindInt(idx, try decimalToScaledInt(str, o.scale orelse 0));
            },
        },
        .json => {
            const s = try std.json.Stringify.valueAlloc(alloc, v, .{});
            try bindStorage(alloc, stmt, idx, field, s);
        },
        .select, .relation, .file => {
            if (field.isMultiValue()) {
                if (v != .array) return error.TypeMismatch;
                const s = try std.json.Stringify.valueAlloc(alloc, v, .{});
                try stmt.bindText(idx, s);
            } else {
                if (v != .string) return error.TypeMismatch;
                try stmt.bindText(idx, v.string);
            }
        },
    }
}

/// Read a column value from a stepped statement into a `std.json.Value` according to the field's type.
/// Requires an arena allocator: the parse tree for json/multi-value fields is allocated into `alloc`
/// and is never freed individually — it lives until the arena is released.
pub fn readValue(alloc: std.mem.Allocator, stmt: *db.Stmt, idx: c_int, field: schema.Field) !std.json.Value {
    if (stmt.isNull(idx)) return .null;
    switch (field.options) {
        .text, .email, .url, .editor, .date, .autodate => {
            return .{ .string = try readStorage(alloc, stmt, idx, field) };
        },
        .bool => return .{ .bool = stmt.columnInt(idx) != 0 },
        .number => |o| switch (o.mode) {
            .float => return .{ .float = stmt.columnDouble(idx) },
            .int => return .{ .string = try scaledIntToDecimal(alloc, stmt.columnInt(idx), 0) },
            .fixed => return .{ .string = try scaledIntToDecimal(alloc, stmt.columnInt(idx), o.scale orelse 0) },
        },
        .json => {
            // Fast path: parseFromSlice copies into `alloc` during the parse and the
            // columnText slice stays valid for that call, so a non-encrypted JSON value
            // needs no intermediate dup. Only route through readStorage (decrypt) when
            // the field is encrypted. (The text/string branch still MUST dup —
            // columnText is invalidated on the next stmt.step.)
            const txt = if (field.encrypted) try readStorage(alloc, stmt, idx, field) else stmt.columnText(idx);
            return (try std.json.parseFromSlice(std.json.Value, alloc, txt, .{})).value;
        },
        .select, .relation, .file => {
            const txt = stmt.columnText(idx);
            if (field.isMultiValue()) {
                return (try std.json.parseFromSlice(std.json.Value, alloc, txt, .{})).value;
            }
            return .{ .string = try alloc.dupe(u8, txt) };
        },
    }
}

fn roundTrip(a: std.mem.Allocator, field: schema.Field, sql_type: []const u8, in: std.json.Value) !std.json.Value {
    var d = try db.Db.openMemory();
    defer d.close();
    const create = try std.fmt.allocPrintSentinel(a, "CREATE TABLE t (v {s});", .{sql_type}, 0);
    defer a.free(create); // a build-time temporary, not the returned value — free regardless of allocator
    try d.exec(create);
    var ins = try d.prepare("INSERT INTO t (v) VALUES (?1);");
    try bindValue(a, &ins, 1, field, in);
    _ = try ins.step();
    ins.finalize();
    var sel = try d.prepare("SELECT v FROM t;");
    defer sel.finalize();
    _ = try sel.step();
    return readValue(a, &sel, 0, field);
}

test "text round-trips" {
    const a = std.testing.allocator;
    const f = schema.Field{ .id = "f", .name = "title", .options = .{ .text = .{} } };
    const out = try roundTrip(a, f, "TEXT", .{ .string = "hello" });
    defer a.free(out.string); // readStorage-duped storage string
    try std.testing.expectEqualStrings("hello", out.string);
}

test "bool round-trips" {
    const a = std.testing.allocator;
    const f = schema.Field{ .id = "f", .name = "ok", .options = .{ .bool = .{} } };
    const out = try roundTrip(a, f, "INTEGER", .{ .bool = true }); // .bool result carries no allocation
    try std.testing.expectEqual(true, out.bool);
}

test "fixed number round-trips as a precise string" {
    const a = std.testing.allocator;
    const f = schema.Field{ .id = "f", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } };
    const out = try roundTrip(a, f, "INTEGER", .{ .string = "10.50" });
    defer a.free(out.string); // scaledIntToDecimal-allocated return value
    try std.testing.expectEqualStrings("10.50", out.string);
}

test "float round-trips as a number" {
    const a = std.testing.allocator;
    const f = schema.Field{ .id = "f", .name = "ratio", .options = .{ .number = .{ .mode = .float } } };
    const out = try roundTrip(a, f, "REAL", .{ .float = 1.5 }); // .float result carries no allocation
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), out.float, 0.0001);
}

test "int number round-trips as a string" {
    const a = std.testing.allocator;
    const f = schema.Field{ .id = "f", .name = "n", .options = .{ .number = .{ .mode = .int } } };
    const out = try roundTrip(a, f, "INTEGER", .{ .string = "9007199254740993" });
    defer a.free(out.string); // scaledIntToDecimal-allocated return value
    try std.testing.expectEqualStrings("9007199254740993", out.string);
}

test "int number accepts a JSON integer on write (symmetric with reads)" {
    const a = std.testing.allocator;
    const f = schema.Field{ .id = "f", .name = "n", .options = .{ .number = .{ .mode = .int } } };
    // Passed AS a number, not a string.
    const out = try roundTrip(a, f, "INTEGER", .{ .integer = 42 });
    defer a.free(out.string); // scaledIntToDecimal-allocated return value
    try std.testing.expectEqualStrings("42", out.string);
    // Back-compat: the string form still works.
    const out_s = try roundTrip(a, f, "INTEGER", .{ .string = "42" });
    defer a.free(out_s.string);
    try std.testing.expectEqualStrings("42", out_s.string);
}

test "int number rejects a fractional float on write" {
    const a = std.testing.allocator;
    const f = schema.Field{ .id = "f", .name = "n", .options = .{ .number = .{ .mode = .int } } };
    // Error path: bindValue frees its allocPrint temporary before returning error.TooPrecise.
    try std.testing.expectError(error.TooPrecise, roundTrip(a, f, "INTEGER", .{ .float = 4.2 }));
}

test "fixed number accepts JSON integer/float and scales identically to the string form" {
    const a = std.testing.allocator;
    const f = schema.Field{ .id = "f", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } };
    // `.float = 5.0` scales to 500, then reads back as "5.00" — identical to the string forms.
    const out_f = try roundTrip(a, f, "INTEGER", .{ .float = 5.0 });
    defer a.free(out_f.string); // scaledIntToDecimal-allocated return value
    try std.testing.expectEqualStrings("5.00", out_f.string);
    const out_i = try roundTrip(a, f, "INTEGER", .{ .integer = 5 });
    defer a.free(out_i.string);
    try std.testing.expectEqualStrings("5.00", out_i.string);
    const out_s = try roundTrip(a, f, "INTEGER", .{ .string = "5.0" });
    defer a.free(out_s.string);
    try std.testing.expectEqualStrings("5.00", out_s.string);
    const out_s2 = try roundTrip(a, f, "INTEGER", .{ .string = "5.00" });
    defer a.free(out_s2.string);
    try std.testing.expectEqualStrings("5.00", out_s2.string);
}

test "bindValue on the raw GPA path: numeric-as-number writes free their allocPrint temporaries" {
    // roundTrip's other callers all pass an arena, which reclaims the `allocPrint`
    // temporaries in bindValue's `.int`-mode `.float` arm and the `.fixed`-mode
    // `.integer`/`.float` arms whether or not they're individually freed — masking a
    // leak whenever `alloc` is not an arena (e.g. a `Data` built directly on a plain GPA).
    // `std.testing.allocator` here fails the test on any unfreed byte.
    const a = std.testing.allocator;

    // `.int`-mode field written with a JSON float: exercises the allocPrint'd `str` in
    // the `.float` arm of the `.int` mode switch.
    const int_field = schema.Field{ .id = "f", .name = "n", .options = .{ .number = .{ .mode = .int } } };
    const out_int = try roundTrip(a, int_field, "INTEGER", .{ .float = 42.0 });
    a.free(out_int.string); // readValue's scaledIntToDecimal-allocated return value

    // `.fixed`-mode field written with a JSON integer: exercises the allocPrint'd `str`
    // in the `.fixed` mode's `.integer` arm.
    const fixed_field = schema.Field{ .id = "f", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } };
    const out_fixed_int = try roundTrip(a, fixed_field, "INTEGER", .{ .integer = 5 });
    try std.testing.expectEqualStrings("5.00", out_fixed_int.string);
    a.free(out_fixed_int.string);

    // `.fixed`-mode field written with a JSON float: exercises the allocPrint'd `str`
    // in the `.fixed` mode's `.float` arm.
    const out_fixed_float = try roundTrip(a, fixed_field, "INTEGER", .{ .float = 5.0 });
    try std.testing.expectEqualStrings("5.00", out_fixed_float.string);
    a.free(out_fixed_float.string);

    // `.fixed`-mode field written with a JSON string (the borrowed, non-allocated arm):
    // must NOT be freed by bindValue, and the read-back value is still freed by us.
    const out_fixed_str = try roundTrip(a, fixed_field, "INTEGER", .{ .string = "5.00" });
    try std.testing.expectEqualStrings("5.00", out_fixed_str.string);
    a.free(out_fixed_str.string);
}

test "multi-select round-trips as an array" {
    // Arena-scoped by contract (NO_SLOP.md 2.2a, contract-4): for a multi-value field
    // readValue returns `(try std.json.parseFromSlice(...)).value`, DISCARDING the
    // std.json.Parsed wrapper that owns the parse arena. The returned Value graph
    // therefore cannot be freed piecewise — the backing arena handle is gone by design
    // (readValue's doc-comment states it "Requires an arena allocator"). readValue is
    // only ever driven request-scoped, so the caller's arena reclaims the tree.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = schema.Field{ .id = "f", .name = "tags", .options = .{ .select = .{ .values = &.{ "x", "y" }, .maxSelect = 3 } } };
    var arr = std.json.Array.init(a);
    try arr.append(.{ .string = "x" });
    try arr.append(.{ .string = "y" });
    const out = try roundTrip(a, f, "TEXT", .{ .array = arr });
    try std.testing.expectEqual(@as(usize, 2), out.array.items.len);
    try std.testing.expectEqualStrings("x", out.array.items[0].string);
}

test "null round-trips" {
    const a = std.testing.allocator;
    const f = schema.Field{ .id = "f", .name = "title", .options = .{ .text = .{} } };
    const out = try roundTrip(a, f, "TEXT", .null); // .null result carries no allocation
    try std.testing.expect(out == .null);
}

test "pow10: exact powers and the >18 overflow guard" {
    try std.testing.expectEqual(@as(i64, 1), try pow10(0));
    try std.testing.expectEqual(@as(i64, 100), try pow10(2));
    try std.testing.expectEqual(@as(i64, 1_000_000_000_000_000_000), try pow10(18));
    try std.testing.expectError(error.Overflow, pow10(19));
}

test "decimalToScaledInt: scale 2" {
    try std.testing.expectEqual(@as(i64, 1050), try decimalToScaledInt("10.50", 2));
    try std.testing.expectEqual(@as(i64, 1050), try decimalToScaledInt("10.5", 2));
    try std.testing.expectEqual(@as(i64, 1000), try decimalToScaledInt("10", 2));
    try std.testing.expectEqual(@as(i64, -5), try decimalToScaledInt("-0.05", 2));
    try std.testing.expectEqual(@as(i64, 0), try decimalToScaledInt("0", 2));
    try std.testing.expectError(error.TooPrecise, decimalToScaledInt("10.123", 2));
    try std.testing.expectError(error.BadNumber, decimalToScaledInt("abc", 2));
    try std.testing.expectError(error.BadNumber, decimalToScaledInt("", 2));
}

test "decimalToScaledInt: scale 0 (int)" {
    try std.testing.expectEqual(@as(i64, 42), try decimalToScaledInt("42", 0));
    try std.testing.expectEqual(@as(i64, -7), try decimalToScaledInt("-7", 0));
    try std.testing.expectError(error.TooPrecise, decimalToScaledInt("4.2", 0));
    try std.testing.expectEqual(@as(i64, 9007199254740993), try decimalToScaledInt("9007199254740993", 0));
}

test "scaledIntToDecimal round-trips" {
    const a = std.testing.allocator;
    const s1 = try scaledIntToDecimal(a, 1050, 2);
    defer a.free(s1);
    try std.testing.expectEqualStrings("10.50", s1);
    const s2 = try scaledIntToDecimal(a, -5, 2);
    defer a.free(s2);
    try std.testing.expectEqualStrings("-0.05", s2);
    const s3 = try scaledIntToDecimal(a, 0, 2);
    defer a.free(s3);
    try std.testing.expectEqualStrings("0.00", s3);
    const s4 = try scaledIntToDecimal(a, 42, 0);
    defer a.free(s4);
    try std.testing.expectEqualStrings("42", s4);
    const s5 = try scaledIntToDecimal(a, 9007199254740993, 0);
    defer a.free(s5);
    try std.testing.expectEqualStrings("9007199254740993", s5);
}
