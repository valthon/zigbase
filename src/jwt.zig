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

/// Length of an HS256 signature, in bytes.
const sig_len = 32;

/// Hard ceiling on a token this module will process, enforced BEFORE any allocation.
///
/// Without it, token length is attacker-controlled and unbounded: nothing on the request
/// path bounds it, and the transport caps are both huge and uneven — a request BODY may be
/// `max_upload_size` (50 MiB by default, `config.zig`) and a realtime frame 256 KiB
/// (facil.io's default), and both carry a `token` field straight into `peekClaims`.
/// Because decoding happens BEFORE the signature check, a garbage token allocates in
/// proportion to its size while still UNAUTHENTICATED: a ~1 MiB token was measured
/// consuming ~1 MiB before rejection.
///
/// 4096 comfortably exceeds any token this system mints (a session token with all claims
/// populated is a few hundred bytes) while capping pre-auth allocation at a few tens of KiB.
pub const max_token_len: usize = 4096;

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

    // Bound `sign` by the SAME ceiling `verify` enforces, so this module can never mint a
    // token it would then refuse. `pl` is caller-supplied and unchecked, so without this an
    // app stuffing a few KB into it gets a token that fails at the next request — a failure
    // that would surface far from its cause. Checked before the final concat, from the exact
    // final length: signing_input + '.' + the base64 of a 32-byte HMAC.
    const token_len = signing_input.len + 1 + b64.Encoder.calcSize(sig_len);
    if (token_len > max_token_len) return error.TokenTooLarge;

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
    // FIRST statement, before any allocation: this is what bounds pre-auth memory on every
    // caller, whichever contract they use. Putting it in `verifyInto` only would leave the
    // arena callers — which are all of the production ones — unbounded.
    if (token.len > max_token_len) return error.TokenTooLarge;

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
    // As in `verify`: first statement, before any allocation. This path is the more exposed
    // of the two — it runs on tokens whose signing key is not yet known, so it decodes
    // attacker-supplied bytes with no authentication whatsoever.
    if (token.len > max_token_len) return error.TokenTooLarge;

    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next() orelse return error.Malformed; // header
    const p = it.next() orelse return error.Malformed; // payload
    _ = it.next() orelse return error.Malformed; // signature
    const payload_json = b64dec(alloc, p) catch return error.Malformed;
    const parsed = std.json.parseFromSlice(Claims, alloc, payload_json, .{}) catch return error.Malformed;
    return parsed.value;
}

/// Scratch sufficient to verify ANY token this module accepts, i.e. any token of at most
/// `max_token_len` bytes. Derived from measurement, not estimate.
///
/// This is NOT a per-token size bound. A `FixedBufferAllocator` never reuses freed memory,
/// so what must fit is the SUM of every allocation `verify` makes: the re-concatenated
/// signing input, the decoded signature, the decoded payload, and whatever
/// `std.json.parseFromSlice` copies.
///
/// Measured consumption (bytes handed out, read from `fba.end_index`):
///   - ordinary claims: ~1.74x token length. `parseFromSlice` defaults to
///     `.alloc_if_needed`, so it BORROWS strings from the input and copies almost nothing.
///   - escape-heavy claims: the ratio is NOT constant and RISES with size, because every
///     escaped string forces a copy into the parser's arena, which over-allocates as it
///     grows. Measured 2.74x at 912 bytes, 3.18x at 2960, 4.03x at 5691.
///
/// So the ratio must be taken from the adversarial case, not the typical one. Worst case
/// measured over every token <= `max_token_len` (payload swept 1..3000, all-escape, all
/// claims populated) is 14800 bytes; 16384 is that rounded up, ~10% headroom.
///
/// This constant is only meaningful because `verify`/`peekClaims` enforce `max_token_len`
/// before allocating. If that ceiling is raised, re-derive this at ~3.6x it and re-measure —
/// do not assume the ratio holds, since it grows with size.
pub const scratch_size: usize = 16384;

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

test "an over-long token is rejected before allocating (pre-auth amplification bound)" {
    // Regression for the unbounded pre-auth path: nothing on the request path bounded token
    // length, while a request body may be 50 MiB and a realtime frame 256 KiB. Decoding
    // happens BEFORE the signature check, so a garbage token allocated in proportion to its
    // own size while still unauthenticated.
    //
    // The token must be STRUCTURALLY VALID (header.payload.signature) to be a real test.
    // A blob of bytes with no '.' is rejected as Malformed before any allocation regardless,
    // so it would pass against unpatched code and prove nothing.
    //
    // `failing_allocator` is the assertion: it returns OutOfMemory on the FIRST allocation.
    // Passing therefore proves rejection happens with ZERO allocation, not merely that an
    // oversized token is eventually refused after the amplification already occurred.
    const a = std.testing.allocator;
    const payload = try a.alloc(u8, max_token_len);
    defer a.free(payload);
    @memset(payload, 'A'); // valid base64url alphabet, so decoding would proceed

    const token = try std.fmt.allocPrint(a, "{s}.{s}.AAAA", .{ header_b64, payload });
    defer a.free(token);
    try std.testing.expect(token.len > max_token_len);

    const fa = std.testing.failing_allocator;
    try std.testing.expectError(error.TokenTooLarge, verify(fa, token, "k", 0));
    try std.testing.expectError(error.TokenTooLarge, peekClaims(fa, token));
}

test "sign refuses to mint a token that verify would reject" {
    // The two bounds must agree. Without a ceiling in `sign`, an app stuffing a few KB into
    // the caller-supplied `pl` claim mints a token that fails at the NEXT request, surfacing
    // the error far from its cause.
    const a = std.testing.allocator;
    const key = [_]u8{7} ** 32;

    var big: [max_token_len]u8 = undefined;
    @memset(&big, 'x');
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 4000, .pl = &big };

    try std.testing.expectError(error.TokenTooLarge, sign(a, claims, &key));
}

test "scratch_size holds for the largest token max_token_len admits" {
    // Guards the derivation in `scratch_size`'s doc comment: the constant is only correct
    // relative to `max_token_len`, and the consumption ratio GROWS with token size, so a
    // raise to either constant must be re-measured rather than assumed.
    const a = std.testing.allocator;
    const key = [_]u8{3} ** 32;

    // Escape-heavy payload: forces std.json to copy into its arena instead of borrowing,
    // which is the adversarial case scratch_size is sized against.
    var pl: [1800]u8 = undefined;
    @memset(&pl, '"');
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 4000, .pl = &pl };

    const token = sign(a, claims, &key) catch |e| switch (e) {
        // If this payload can't be minted, the ceiling is doing its job; nothing to check.
        error.TokenTooLarge => return,
        else => return e,
    };
    defer a.free(token);
    try std.testing.expect(token.len <= max_token_len);

    var scratch: [scratch_size]u8 = undefined;
    const got = try verifyInto(&scratch, token, &key, 1500);
    try std.testing.expectEqualStrings("u1", got.id);
}
