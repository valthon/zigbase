const std = @import("std");
const crypto = @import("crypto.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

pub const TokenType = enum { auth, verification, password_reset, file, magic_link };

pub const Claims = struct {
    id: []const u8,
    collection: []const u8,
    type: TokenType,
    csrf: []const u8 = "",
    /// Unique token id. Set on single-use tokens (verification / password-reset) so a
    /// redemption can be recorded in `_consumedTokens` and a replay rejected. Empty on
    /// auth/file tokens, which are not single-use.
    jti: []const u8 = "",
    iat: i64,
    exp: i64,
};

pub const JwtError = error{ Malformed, BadSignature, Expired } || std.mem.Allocator.Error;

const header_b64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"; // base64url of {"alg":"HS256","typ":"JWT"}

fn b64enc(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, b64.Encoder.calcSize(data.len));
    _ = b64.Encoder.encode(out, data);
    return out;
}

fn b64dec(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, try b64.Decoder.calcSizeForSlice(s));
    try b64.Decoder.decode(out, s);
    return out;
}

/// Produce a compact JWS (header.payload.signature), HS256-signed with `key`.
pub fn sign(alloc: std.mem.Allocator, claims: Claims, key: []const u8) ![]u8 {
    const payload_json = try std.json.Stringify.valueAlloc(alloc, claims, .{});
    const p = try b64enc(alloc, payload_json);
    const signing_input = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ header_b64, p });
    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, signing_input, key);
    const s = try b64enc(alloc, &sig);
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ signing_input, s });
}

/// Verify signature + expiry (against `now`, unix seconds) and return the claims.
pub fn verify(alloc: std.mem.Allocator, token: []const u8, key: []const u8, now: i64) JwtError!Claims {
    var it = std.mem.splitScalar(u8, token, '.');
    const h = it.next() orelse return error.Malformed;
    const p = it.next() orelse return error.Malformed;
    const s = it.next() orelse return error.Malformed;
    if (it.next() != null) return error.Malformed;

    // Reject any header other than the fixed HS256 header (defense-in-depth vs alg substitution).
    if (!std.mem.eql(u8, h, header_b64)) return error.Malformed;

    const signing_input = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ h, p });
    var expected: [32]u8 = undefined;
    HmacSha256.create(&expected, signing_input, key);

    const provided = b64dec(alloc, s) catch return error.Malformed;
    if (provided.len != 32) return error.BadSignature;
    if (!std.crypto.timing_safe.eql([32]u8, expected, provided[0..32].*)) return error.BadSignature;

    const payload_json = b64dec(alloc, p) catch return error.Malformed;
    const parsed = std.json.parseFromSlice(Claims, alloc, payload_json, .{}) catch return error.Malformed;
    const claims = parsed.value;
    if (claims.exp <= now) return error.Expired;
    return claims;
}

/// Decode the payload of a compact JWS WITHOUT verifying the signature or expiry.
/// Used to locate the record (id/collection) before its signing key is known.
/// The returned claims MUST then be confirmed with `verify` using the record's key.
pub fn peekClaims(alloc: std.mem.Allocator, token: []const u8) JwtError!Claims {
    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next() orelse return error.Malformed; // header
    const p = it.next() orelse return error.Malformed; // payload
    _ = it.next() orelse return error.Malformed; // signature
    const payload_json = b64dec(alloc, p) catch return error.Malformed;
    const parsed = std.json.parseFromSlice(Claims, alloc, payload_json, .{}) catch return error.Malformed;
    return parsed.value;
}

test "sign then verify round-trips claims" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .csrf = "c1", .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    const out = try verify(a, token, &key, 1500);
    try std.testing.expectEqualStrings("u1", out.id);
    try std.testing.expectEqualStrings("users", out.collection);
    try std.testing.expectEqual(TokenType.auth, out.type);
    try std.testing.expectEqualStrings("c1", out.csrf);
}

test "tampered payload fails the signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    const buf = try a.dupe(u8, token);
    const dot = std.mem.indexOfScalar(u8, buf, '.').?;
    buf[dot + 1] = if (buf[dot + 1] == 'A') 'B' else 'A';
    try std.testing.expectError(error.BadSignature, verify(a, buf, &key, 1500));
}

test "expired token is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    try std.testing.expectError(error.Expired, verify(a, token, &key, 2000));
}

test "a token signed with a rotated tokenKey no longer verifies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old_key = crypto.deriveKey("secret", "tk-old");
    const new_key = crypto.deriveKey("secret", "tk-new");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &old_key);
    try std.testing.expectError(error.BadSignature, verify(a, token, &new_key, 1500));
}

test "malformed token shapes are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    try std.testing.expectError(error.Malformed, verify(a, "not-a-jwt", &key, 0));
    try std.testing.expectError(error.Malformed, verify(a, "only.two", &key, 0));
}

test "peekClaims decodes the payload without checking the signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    // Tamper the signature: peekClaims must still return the claims.
    const buf = try a.dupe(u8, token);
    buf[buf.len - 1] = if (buf[buf.len - 1] == 'A') 'B' else 'A';
    const peeked = try peekClaims(a, buf);
    try std.testing.expectEqualStrings("u1", peeked.id);
    try std.testing.expectEqualStrings("users", peeked.collection);
    try std.testing.expectError(error.Malformed, peekClaims(a, "nope"));
}

test "verify rejects a token with a foreign header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");
    // craft header.payload.sig where header is some other base64url
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const good = try sign(a, claims, &key);
    // replace the header segment with a different (valid base64url) value
    const dot = std.mem.indexOfScalar(u8, good, '.').?;
    const tampered = try std.fmt.allocPrint(a, "ZXZpbA.{s}", .{good[dot + 1 ..]});
    try std.testing.expectError(error.Malformed, verify(a, tampered, &key, 1500));
}
