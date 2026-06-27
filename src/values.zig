const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const field_policy = @import("field_policy.zig");

pub const ValueError = error{ TypeMismatch, TooPrecise, Overflow, BadNumber, BadSelect, NotObject } || std.mem.Allocator.Error;

/// Raised when an `.encrypted` field is read or written but no field cipher is
/// configured on the connection (ZIGBASE_FIELD_KEY unset). Fail-closed: we never
/// store an encrypted field as plaintext, nor return ciphertext as plaintext.
pub const EncryptError = error{FieldKeyMissing};

/// Recover the field cipher stamped on the connection (db.Db.field_cipher), or null.
fn cipherOf(stmt: *db.Stmt) ?field_policy.Cipher {
    const p = stmt.field_cipher orelse return null;
    const cph: *const field_policy.Cipher = @ptrCast(@alignCast(p));
    return cph.*;
}

/// Bind a storage string, sealing it into an at-rest envelope first when the field
/// is `.encrypted`. Fail-closed: an encrypted field with no configured cipher errors.
fn bindStorage(alloc: std.mem.Allocator, stmt: *db.Stmt, idx: c_int, field: schema.Field, storage: []const u8) (EncryptError || db.DbError || std.mem.Allocator.Error)!void {
    if (field.encrypted) {
        const cph = cipherOf(stmt) orelse return error.FieldKeyMissing;
        return stmt.bindText(idx, try field_policy.seal(cph, alloc, storage));
    }
    return stmt.bindText(idx, storage);
}

/// Read a column's storage string, STRICTLY decrypting it when the field is
/// `.encrypted`. A legacy/plaintext or undecryptable stored value fails closed.
fn readStorage(alloc: std.mem.Allocator, stmt: *db.Stmt, idx: c_int, field: schema.Field) ![]u8 {
    const raw = stmt.columnText(idx);
    if (field.encrypted) {
        const cph = cipherOf(stmt) orelse return error.FieldKeyMissing;
        return field_policy.open(cph, alloc, raw);
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
    if (s[0] == '-') { neg = true; i = 1; } else if (s[0] == '+') { i = 1; }
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
        .@"bool" => {
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
                if (v != .string) return error.TypeMismatch;
                try stmt.bindInt(idx, try decimalToScaledInt(v.string, 0));
            },
            .fixed => {
                if (v != .string) return error.TypeMismatch;
                try stmt.bindInt(idx, try decimalToScaledInt(v.string, o.scale orelse 0));
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
        .@"bool" => return .{ .bool = stmt.columnInt(idx) != 0 },
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = schema.Field{ .id = "f", .name = "title", .options = .{ .text = .{} } };
    const out = try roundTrip(a, f, "TEXT", .{ .string = "hello" });
    try std.testing.expectEqualStrings("hello", out.string);
}

test "bool round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = schema.Field{ .id = "f", .name = "ok", .options = .{ .@"bool" = .{} } };
    const out = try roundTrip(a, f, "INTEGER", .{ .bool = true });
    try std.testing.expectEqual(true, out.bool);
}

test "fixed number round-trips as a precise string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = schema.Field{ .id = "f", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } };
    const out = try roundTrip(a, f, "INTEGER", .{ .string = "10.50" });
    try std.testing.expectEqualStrings("10.50", out.string);
}

test "float round-trips as a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = schema.Field{ .id = "f", .name = "ratio", .options = .{ .number = .{ .mode = .float } } };
    const out = try roundTrip(a, f, "REAL", .{ .float = 1.5 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), out.float, 0.0001);
}

test "int number round-trips as a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = schema.Field{ .id = "f", .name = "n", .options = .{ .number = .{ .mode = .int } } };
    const out = try roundTrip(a, f, "INTEGER", .{ .string = "9007199254740993" });
    try std.testing.expectEqualStrings("9007199254740993", out.string);
}

test "multi-select round-trips as an array" {
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = schema.Field{ .id = "f", .name = "title", .options = .{ .text = .{} } };
    const out = try roundTrip(a, f, "TEXT", .null);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("10.50", try scaledIntToDecimal(a, 1050, 2));
    try std.testing.expectEqualStrings("-0.05", try scaledIntToDecimal(a, -5, 2));
    try std.testing.expectEqualStrings("0.00", try scaledIntToDecimal(a, 0, 2));
    try std.testing.expectEqualStrings("42", try scaledIntToDecimal(a, 42, 0));
    try std.testing.expectEqualStrings("9007199254740993", try scaledIntToDecimal(a, 9007199254740993, 0));
}
