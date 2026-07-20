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

pub const JwtError = error{ Malformed, BadSignature, Expired, TokenTooLarge } || std.mem.Allocator.Error;

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
    // Every intermediate below is scratch; only the returned token escapes. Freeing them keeps
    // `sign` correct under ANY allocator (§2.1) rather than only under a caller-supplied arena —
    // it runs on every login and token refresh, so a per-call leak would be a live one.
    const payload_json = try std.json.Stringify.valueAlloc(alloc, claims, .{ .emit_null_optional_fields = false });
    defer alloc.free(payload_json);
    const p = try b64enc(alloc, payload_json);
    defer alloc.free(p);
    const signing_input = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ header_b64, p });
    defer alloc.free(signing_input);
    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, signing_input, key);
    const s = try b64enc(alloc, &sig);
    defer alloc.free(s);
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ signing_input, s });
}

/// Verify signature + expiry (against `now`, unix seconds) and return the claims.
///
/// Contract 4 (arena-scoped) — the returned `Claims` borrow the JSON parse tree allocated
/// from `alloc`, so this function cannot free it. Callers must pass an arena. PREFER
/// `verifyInto`, which is contract 3 and allocates nothing. Retained for callers already
/// holding a request arena; it is scheduled for removal once they migrate.
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
///
/// Contract 4 (arena-scoped) — the returned `Claims` borrow the JSON parse tree allocated
/// from `alloc`, so this function cannot free it. Callers must pass an arena. PREFER
/// `peekClaimsInto`, which is contract 3 and allocates nothing. Retained for callers already
/// holding a request arena; it is scheduled for removal once they migrate.
pub fn peekClaims(alloc: std.mem.Allocator, token: []const u8) JwtError!Claims {
    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next() orelse return error.Malformed; // header
    const p = it.next() orelse return error.Malformed; // payload
    _ = it.next() orelse return error.Malformed; // signature
    const payload_json = b64dec(alloc, p) catch return error.Malformed;
    const parsed = std.json.parseFromSlice(Claims, alloc, payload_json, .{}) catch return error.Malformed;
    return parsed.value;
}

/// Scratch needed to decode + parse the largest token we accept. This is NOT a per-token
/// bound of 8192 bytes — the buffer must simultaneously hold the re-concatenated signing
/// input, the decoded signature, the decoded payload, AND the JSON parse tree that
/// `std.json.parseFromSlice` builds over it, roughly 2-2.5x the token's own size. So the
/// largest token `verifyInto`/`peekClaimsInto` can actually verify is ~3-4 KB, not 8 KB.
/// An over-large token fails closed with `error.TokenTooLarge` rather than allocating.
///
/// Asymmetry: `sign` (heap-allocating) is unbounded, but `verifyInto`/`peekClaimsInto`
/// (caller-buffer) are bounded by this constant. An application that stuffs several KB
/// into the caller-supplied `pl` claim can mint a token with `sign` that `verifyInto`
/// then rejects as `TokenTooLarge`. Resolving that asymmetry (e.g. sizing scratch to the
/// caller's own claim payload, or bounding `pl` at `sign` time) is deferred to the
/// follow-on allocator-ownership migration; this constant and mechanism are unchanged here.
pub const scratch_size: usize = 8192;

/// Contract 3 (caller-buffer): verifies signature + expiry and returns claims that BORROW
/// `scratch`. Allocates nothing on the heap — `scratch` is the only storage, so the claims
/// are valid exactly as long as the caller keeps it alive. Prefer this over `verify`.
pub fn verifyInto(scratch: []u8, token: []const u8, key: []const u8, now: i64) JwtError!Claims {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    return verify(fba.allocator(), token, key, now) catch |e| switch (e) {
        error.OutOfMemory => error.TokenTooLarge,
        else => e,
    };
}

/// Contract 3 counterpart of `peekClaims`: decodes the payload WITHOUT verifying the
/// signature or expiry, borrowing `scratch`. Allocates nothing on the heap.
pub fn peekClaimsInto(scratch: []u8, token: []const u8) JwtError!Claims {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    return peekClaims(fba.allocator(), token) catch |e| switch (e) {
        error.OutOfMemory => error.TokenTooLarge,
        else => e,
    };
}

test "verifyInto round-trips claims with zero heap allocation" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .csrf = "c1", .iat = 1000, .exp = 2000 };

    const token = try sign(a, claims, &key);
    defer a.free(token);

    var scratch: [scratch_size]u8 = undefined;
    const out = try verifyInto(&scratch, token, &key, 1500);
    try std.testing.expectEqualStrings("u1", out.id);
    try std.testing.expectEqualStrings("users", out.collection);
    try std.testing.expectEqual(TokenType.auth, out.type);
    try std.testing.expectEqualStrings("c1", out.csrf);
}

test "verifyInto fails closed when the scratch buffer is too small" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    defer a.free(token);

    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.TokenTooLarge, verifyInto(&tiny, token, &key, 1500));
}

test "verifyInto still rejects a tampered payload and an expired token" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    defer a.free(token);

    var scratch: [scratch_size]u8 = undefined;
    try std.testing.expectError(error.Expired, verifyInto(&scratch, token, &key, 3000));

    const bad = try a.dupe(u8, token);
    defer a.free(bad);
    bad[bad.len - 1] = if (bad[bad.len - 1] == 'A') 'B' else 'A';
    try std.testing.expectError(error.BadSignature, verifyInto(&scratch, bad, &key, 1500));
}

test "sign then verify round-trips claims" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .csrf = "c1", .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    defer a.free(token);
    var scratch: [scratch_size]u8 = undefined;
    const out = try verifyInto(&scratch, token, &key, 1500);
    try std.testing.expectEqualStrings("u1", out.id);
    try std.testing.expectEqualStrings("users", out.collection);
    try std.testing.expectEqual(TokenType.auth, out.type);
    try std.testing.expectEqualStrings("c1", out.csrf);
}

test "#99 sid claim: omitted when null (epoch token unchanged), present + round-trips when set" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");

    // Epoch-mode token (sid == null): the JSON must NOT contain "sid" at all, so the token is
    // byte-identical to a pre-Variant-B token. Prove it equals a token signed by a Claims type
    // that never had a sid field by checking the serialized payload omits the key entirely.
    const epoch_claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .csrf = "c1", .iat = 1000, .exp = 2000 };
    const epoch_token = try sign(a, epoch_claims, &key);
    defer a.free(epoch_token);
    // decode payload segment and assert "sid" is absent.
    var it = std.mem.splitScalar(u8, epoch_token, '.');
    _ = it.next();
    const payload_json = try b64dec(a, it.next().?);
    defer a.free(payload_json);
    try std.testing.expect(std.mem.indexOf(u8, payload_json, "\"sid\"") == null);
    var scratch1: [scratch_size]u8 = undefined;
    const epoch_out = try verifyInto(&scratch1, epoch_token, &key, 1500);
    try std.testing.expect(epoch_out.sid == null);

    // Table-mode token (sid set): present in JSON + round-trips through verify.
    const tbl_claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .sid = "sess123", .iat = 1000, .exp = 2000 };
    const tbl_token = try sign(a, tbl_claims, &key);
    defer a.free(tbl_token);
    var it2 = std.mem.splitScalar(u8, tbl_token, '.');
    _ = it2.next();
    const tbl_payload = try b64dec(a, it2.next().?);
    defer a.free(tbl_payload);
    try std.testing.expect(std.mem.indexOf(u8, tbl_payload, "\"sid\":\"sess123\"") != null);
    var scratch2: [scratch_size]u8 = undefined;
    const tbl_out = try verifyInto(&scratch2, tbl_token, &key, 1500);
    try std.testing.expectEqualStrings("sess123", tbl_out.sid.?);
}

test "pl claim round-trips, empty and set" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");

    // No payload: pl serializes as the empty string, like the other default-empty claims.
    const bare = Claims{ .id = "u1", .collection = "users", .type = .magic_link, .jti = "j1", .iat = 1000, .exp = 2000 };
    const bare_json = try std.json.Stringify.valueAlloc(a, bare, .{});
    defer a.free(bare_json);
    try std.testing.expect(std.mem.indexOf(u8, bare_json, "\"pl\":\"\"") != null);
    const bare_token = try sign(a, bare, &key);
    defer a.free(bare_token);
    var scratch1: [scratch_size]u8 = undefined;
    const bare_out = try verifyInto(&scratch1, bare_token, &key, 1500);
    try std.testing.expectEqualStrings("", bare_out.pl);

    // With a payload: the key is present and the value round-trips through sign/verify.
    const withpl = Claims{ .id = "u1", .collection = "users", .type = .magic_link, .jti = "j1", .pl = "/club/profile", .iat = 1000, .exp = 2000 };
    const withpl_json = try std.json.Stringify.valueAlloc(a, withpl, .{});
    defer a.free(withpl_json);
    try std.testing.expect(std.mem.indexOf(u8, withpl_json, "\"pl\":\"/club/profile\"") != null);
    const withpl_token = try sign(a, withpl, &key);
    defer a.free(withpl_token);
    var scratch2: [scratch_size]u8 = undefined;
    const withpl_out = try verifyInto(&scratch2, withpl_token, &key, 1500);
    try std.testing.expectEqualStrings("/club/profile", withpl_out.pl);
}

test "tampered payload fails the signature" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    defer a.free(token);
    const buf = try a.dupe(u8, token);
    defer a.free(buf);
    const dot = std.mem.indexOfScalar(u8, buf, '.').?;
    buf[dot + 1] = if (buf[dot + 1] == 'A') 'B' else 'A';
    var scratch: [scratch_size]u8 = undefined;
    try std.testing.expectError(error.BadSignature, verifyInto(&scratch, buf, &key, 1500));
}

test "expired token is rejected" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    defer a.free(token);
    var scratch: [scratch_size]u8 = undefined;
    try std.testing.expectError(error.Expired, verifyInto(&scratch, token, &key, 2000));
}

test "a token signed with a rotated tokenKey no longer verifies" {
    const a = std.testing.allocator;
    const old_key = crypto.deriveKey("secret", "tk-old");
    const new_key = crypto.deriveKey("secret", "tk-new");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &old_key);
    defer a.free(token);
    var scratch: [scratch_size]u8 = undefined;
    try std.testing.expectError(error.BadSignature, verifyInto(&scratch, token, &new_key, 1500));
}

test "malformed token shapes are rejected" {
    const key = crypto.deriveKey("secret", "tk1");
    var scratch: [scratch_size]u8 = undefined;
    try std.testing.expectError(error.Malformed, verifyInto(&scratch, "not-a-jwt", &key, 0));
    try std.testing.expectError(error.Malformed, verifyInto(&scratch, "only.two", &key, 0));
}

test "peekClaims decodes the payload without checking the signature" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    defer a.free(token);
    // Tamper the signature: peekClaims must still return the claims.
    const buf = try a.dupe(u8, token);
    defer a.free(buf);
    buf[buf.len - 1] = if (buf[buf.len - 1] == 'A') 'B' else 'A';
    var scratch: [scratch_size]u8 = undefined;
    const peeked = try peekClaimsInto(&scratch, buf);
    try std.testing.expectEqualStrings("u1", peeked.id);
    try std.testing.expectEqualStrings("users", peeked.collection);
    try std.testing.expectError(error.Malformed, peekClaimsInto(&scratch, "nope"));
}

test "#99 token_epoch claim round-trips; a pre-epoch token (no claim) parses as 0" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");

    // Round-trip: a non-zero epoch survives sign -> verify.
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .token_epoch = 7, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    defer a.free(token);
    var scratch1: [scratch_size]u8 = undefined;
    const out = try verifyInto(&scratch1, token, &key, 1500);
    try std.testing.expectEqual(@as(i64, 7), out.token_epoch);

    // Back-compat: a token minted BEFORE #99 carries no "token_epoch" key. Build such a
    // payload by hand and confirm verify() fills the struct default (0), not an error.
    const legacy_json = "{\"id\":\"u1\",\"collection\":\"users\",\"type\":\"auth\",\"csrf\":\"\",\"jti\":\"\",\"pl\":\"\",\"iat\":1000,\"exp\":2000}";
    const p = try b64enc(a, legacy_json);
    defer a.free(p);
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ header_b64, p });
    defer a.free(signing_input);
    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, signing_input, &key);
    const s = try b64enc(a, &sig);
    defer a.free(s);
    const legacy_token = try std.fmt.allocPrint(a, "{s}.{s}", .{ signing_input, s });
    defer a.free(legacy_token);
    var scratch2: [scratch_size]u8 = undefined;
    const legacy = try verifyInto(&scratch2, legacy_token, &key, 1500);
    try std.testing.expectEqual(@as(i64, 0), legacy.token_epoch);
}

test "verify rejects a token with a foreign header" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    // craft header.payload.sig where header is some other base64url
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const good = try sign(a, claims, &key);
    defer a.free(good);
    // replace the header segment with a different (valid base64url) value
    const dot = std.mem.indexOfScalar(u8, good, '.').?;
    const tampered = try std.fmt.allocPrint(a, "ZXZpbA.{s}", .{good[dot + 1 ..]});
    defer a.free(tampered);
    var scratch: [scratch_size]u8 = undefined;
    try std.testing.expectError(error.Malformed, verifyInto(&scratch, tampered, &key, 1500));
}
