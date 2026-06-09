const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const crypto = @import("crypto.zig");

const HashPasswordError = @typeInfo(@typeInfo(@TypeOf(crypto.hashPassword)).@"fn".return_type.?).error_union.error_set;
const GenTokenError = @typeInfo(@typeInfo(@TypeOf(crypto.genToken)).@"fn".return_type.?).error_union.error_set;

pub const AuthError = error{ PasswordTooShort, IdentityTaken } || db.DbError || std.mem.Allocator.Error || HashPasswordError || GenTokenError;

/// Given the request data for an auth-collection record, return a copy with `passwordHash`,
/// `tokenKey`, and `verified` populated (plaintext `password` removed). Hashes the `password`.
/// `min_len` is the collection's minPasswordLength.
pub fn applyCreate(io: std.Io, alloc: std.mem.Allocator, data: std.json.Value, min_len: u8) AuthError!std.json.Value {
    if (data != .object) return error.PasswordTooShort;
    const pw = (data.object.get("password")) orelse return error.PasswordTooShort;
    if (pw != .string or pw.string.len < min_len) return error.PasswordTooShort;
    const phc = try crypto.hashPassword(io, alloc, pw.string);
    const tk = try crypto.genToken(io, alloc, 32);
    var out: std.json.ObjectMap = .empty;
    var it = data.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "password")) continue; // never store the plaintext
        try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), e.value_ptr.*);
    }
    try out.put(alloc, "passwordHash", .{ .string = phc });
    try out.put(alloc, "tokenKey", .{ .string = tk });
    if (out.get("verified") == null) try out.put(alloc, "verified", .{ .bool = false });
    return .{ .object = out };
}

/// For an update: if `data` contains a new `password`, return a copy with a fresh `passwordHash`
/// and a rotated `tokenKey` (invalidating existing tokens), plaintext removed. If no password is
/// present, returns `data` unchanged.
pub fn applyUpdate(io: std.Io, alloc: std.mem.Allocator, data: std.json.Value, min_len: u8) AuthError!std.json.Value {
    if (data != .object) return data;
    const pw = data.object.get("password") orelse return data;
    if (pw != .string or pw.string.len < min_len) return error.PasswordTooShort;
    const phc = try crypto.hashPassword(io, alloc, pw.string);
    const tk = try crypto.genToken(io, alloc, 32);
    var out: std.json.ObjectMap = .empty;
    var it = data.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "password")) continue;
        try out.put(alloc, try alloc.dupe(u8, e.key_ptr.*), e.value_ptr.*);
    }
    try out.put(alloc, "passwordHash", .{ .string = phc });
    try out.put(alloc, "tokenKey", .{ .string = tk });
    return .{ .object = out };
}

test "applyCreate hashes the password, sets tokenKey/verified, strips plaintext" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "email", .{ .string = "a@b.c" });
    try data.put(a, "password", .{ .string = "longenough" });
    const out = try applyCreate(std.testing.io, a, .{ .object = data }, 8);
    try std.testing.expect(out.object.get("password") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.object.get("passwordHash").?.string, "$argon2id$"));
    try std.testing.expectEqual(@as(usize, 32), out.object.get("tokenKey").?.string.len);
    try std.testing.expectEqual(false, out.object.get("verified").?.bool);
    try std.testing.expectEqualStrings("a@b.c", out.object.get("email").?.string);
}

test "applyCreate rejects a short password" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "password", .{ .string = "short" });
    try std.testing.expectError(error.PasswordTooShort, applyCreate(std.testing.io, a, .{ .object = data }, 8));
}

test "applyUpdate rotates tokenKey when a new password is given, no-ops otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var with_pw: std.json.ObjectMap = .empty;
    try with_pw.put(a, "password", .{ .string = "longenough" });
    const updated = try applyUpdate(std.testing.io, a, .{ .object = with_pw }, 8);
    try std.testing.expect(updated.object.get("tokenKey") != null);
    try std.testing.expect(updated.object.get("password") == null);

    var no_pw: std.json.ObjectMap = .empty;
    try no_pw.put(a, "bio", .{ .string = "hi" });
    const same = try applyUpdate(std.testing.io, a, .{ .object = no_pw }, 8);
    try std.testing.expect(same.object.get("tokenKey") == null); // unchanged
    try std.testing.expectEqualStrings("hi", same.object.get("bio").?.string);
}
