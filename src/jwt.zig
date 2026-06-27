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
    /// Optional opaque application state carried in the signed claim (e.g. a post-login
    /// redirect path). Covered by the HMAC signature, so it is tamper-proof; bound to the
    /// `jti` because it travels in the same single-use token. Empty (`""`) when unused, and
    /// serialized as `"pl":""` like the other default-empty claims; on parse a missing `pl`
    /// (e.g. a non-magic-link token) falls back to this default.
    pl: []const u8 = "",
    /// Session epoch (Variant A revocation, #99). Embedded in `.auth` tokens at issue
    /// time from the auth record's `token_epoch` column; verify rejects the token when it
    /// no longer matches the record's current epoch (bumped by "revoke all sessions").
    /// Defaults to 0 so pre-epoch tokens (no claim) and fresh records (NULL column) agree
    /// — preserving back-compat. Not meaningful on non-`.auth` token types.
    token_epoch: i64 = 0,
    /// Server-side session id (Variant B, #99). Set ONLY when a token is issued under
    /// `App(.{ .session_store = .table })`; it keys the `_sessions` row that verify checks
    /// for existence + non-expiry (per-device revocation). OPTIONAL and omitted from the JSON
    /// when null (`sign` uses `emit_null_optional_fields = false`), so epoch-mode tokens are
    /// byte-identical to pre-#99-Variant-B tokens — the zero-overhead requirement. A missing
    /// `sid` on parse falls back to null.
    sid: ?[]const u8 = null,
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
    // `emit_null_optional_fields = false` omits a null `sid` entirely, so an epoch-mode token
    // (sid == null) serializes EXACTLY as it did before the `sid` claim existed — required so
    // enabling Variant B never changes the default mode's token format. Only `sid` is optional;
    // the other default-empty claims (csrf/jti/pl) are non-optional and still emit as "".
    const payload_json = try std.json.Stringify.valueAlloc(alloc, claims, .{ .emit_null_optional_fields = false });
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

test "#99 sid claim: omitted when null (epoch token unchanged), present + round-trips when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");

    // Epoch-mode token (sid == null): the JSON must NOT contain "sid" at all, so the token is
    // byte-identical to a pre-Variant-B token. Prove it equals a token signed by a Claims type
    // that never had a sid field by checking the serialized payload omits the key entirely.
    const epoch_claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .csrf = "c1", .iat = 1000, .exp = 2000 };
    const epoch_token = try sign(a, epoch_claims, &key);
    // decode payload segment and assert "sid" is absent.
    var it = std.mem.splitScalar(u8, epoch_token, '.');
    _ = it.next();
    const payload_json = try b64dec(a, it.next().?);
    try std.testing.expect(std.mem.indexOf(u8, payload_json, "\"sid\"") == null);
    const epoch_out = try verify(a, epoch_token, &key, 1500);
    try std.testing.expect(epoch_out.sid == null);

    // Table-mode token (sid set): present in JSON + round-trips through verify.
    const tbl_claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .sid = "sess123", .iat = 1000, .exp = 2000 };
    const tbl_token = try sign(a, tbl_claims, &key);
    var it2 = std.mem.splitScalar(u8, tbl_token, '.');
    _ = it2.next();
    const tbl_payload = try b64dec(a, it2.next().?);
    try std.testing.expect(std.mem.indexOf(u8, tbl_payload, "\"sid\":\"sess123\"") != null);
    const tbl_out = try verify(a, tbl_token, &key, 1500);
    try std.testing.expectEqualStrings("sess123", tbl_out.sid.?);
}

test "pl claim round-trips, empty and set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");

    // No payload: pl serializes as the empty string, like the other default-empty claims.
    const bare = Claims{ .id = "u1", .collection = "users", .type = .magic_link, .jti = "j1", .iat = 1000, .exp = 2000 };
    const bare_json = try std.json.Stringify.valueAlloc(a, bare, .{});
    try std.testing.expect(std.mem.indexOf(u8, bare_json, "\"pl\":\"\"") != null);
    const bare_out = try verify(a, try sign(a, bare, &key), &key, 1500);
    try std.testing.expectEqualStrings("", bare_out.pl);

    // With a payload: the key is present and the value round-trips through sign/verify.
    const withpl = Claims{ .id = "u1", .collection = "users", .type = .magic_link, .jti = "j1", .pl = "/club/profile", .iat = 1000, .exp = 2000 };
    const withpl_json = try std.json.Stringify.valueAlloc(a, withpl, .{});
    try std.testing.expect(std.mem.indexOf(u8, withpl_json, "\"pl\":\"/club/profile\"") != null);
    const withpl_out = try verify(a, try sign(a, withpl, &key), &key, 1500);
    try std.testing.expectEqualStrings("/club/profile", withpl_out.pl);
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

test "#99 token_epoch claim round-trips; a pre-epoch token (no claim) parses as 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = crypto.deriveKey("secret", "tk1");

    // Round-trip: a non-zero epoch survives sign -> verify.
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .token_epoch = 7, .iat = 1000, .exp = 2000 };
    const out = try verify(a, try sign(a, claims, &key), &key, 1500);
    try std.testing.expectEqual(@as(i64, 7), out.token_epoch);

    // Back-compat: a token minted BEFORE #99 carries no "token_epoch" key. Build such a
    // payload by hand and confirm verify() fills the struct default (0), not an error.
    const legacy_json = "{\"id\":\"u1\",\"collection\":\"users\",\"type\":\"auth\",\"csrf\":\"\",\"jti\":\"\",\"pl\":\"\",\"iat\":1000,\"exp\":2000}";
    const p = try b64enc(a, legacy_json);
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ header_b64, p });
    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, signing_input, &key);
    const s = try b64enc(a, &sig);
    const legacy_token = try std.fmt.allocPrint(a, "{s}.{s}", .{ signing_input, s });
    const legacy = try verify(a, legacy_token, &key, 1500);
    try std.testing.expectEqual(@as(i64, 0), legacy.token_epoch);
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
