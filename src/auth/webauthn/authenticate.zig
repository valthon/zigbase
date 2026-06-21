// authenticate.zig — WebAuthn authentication ceremony verification (§7.2).
//
// Implements verifyAssertion: the RP-side check of an AuthenticatorAssertionResponse.
//
// § 7.2 step order implemented:
//   1. Parse + verify clientDataJSON (type="webauthn.get", challenge, origin)
//   2. Parse assertion authenticatorData (cred==null is expected for assertions)
//   3. Verify rpIdHash == SHA-256(rp_id)
//   4. Verify UP flag; if require_uv, verify UV flag
//   5. Build signature base: authenticator_data || SHA-256(client_data_json) (raw bytes)
//      CRITICAL: authData FIRST, then the 32-byte hash. Wrong order is the #1 WebAuthn bug.
//   6. verify(stored_key, signature_base, signature) — fail-closed: error -> reject
//   7. signCount clone detection:
//      - new > stored    → clone=false (update stored)
//      - new==0 && stored==0 → clone=false (counter unsupported, passkey-safe)
//      - else (new<=stored, either nonzero) → clone=true (clone signal)
//   8. Return AssertionResult{.new_sign_count, .clone_suspected}
//
// Policy note (per task-7-brief.md): the caller treats clone_suspected=true as a
// failure (fail-closed). We return it as a flag so the caller logs and rejects.

const std = @import("std");
const authdata = @import("authdata.zig");
const client_data = @import("client_data.zig");
const cose = @import("cose.zig");
const verify_sig = @import("verify_sig.zig");

/// Result of a successful (or clone-suspected) assertion verification.
pub const AssertionResult = struct {
    new_sign_count: u32,
    clone_suspected: bool,
};

pub const AssertionError = error{
    /// rpIdHash in authData does not match SHA-256(rp_id).
    RpIdMismatch,
    /// User Present (UP) bit is not set in authData flags.
    UserNotPresent,
    /// User Verified (UV) bit is not set but require_uv=true.
    UserNotVerified,
    /// Cryptographic signature is invalid.
    SignatureInvalid,
} || client_data.ParseError || client_data.VerifyError || authdata.Error || std.mem.Allocator.Error;

/// Verify a WebAuthn authentication assertion (§7.2).
///
/// Parameters:
///   alloc                 — allocator for transient string buffers
///   rp_id                 — Relying Party identifier (e.g. "example.test")
///   origin                — expected RP origin (e.g. "https://example.test")
///   expected_challenge_raw — raw challenge bytes the RP issued
///   stored_key            — the credential's stored COSE public key
///   stored_sign_count     — the stored signCount for clone detection
///   client_data_json      — raw clientDataJSON bytes from the assertion
///   authenticator_data    — raw authenticatorData bytes from the assertion
///   signature             — wire signature (DER for ES256/RS256, raw 64B for Ed25519)
///   require_uv            — if true, require the UV flag to be set
///
/// Returns AssertionResult on success; an error on any verification failure.
/// NEVER returns SignatureInvalid via error propagation — all sig errors are
/// converted to error.SignatureInvalid explicitly (fail-closed).
pub fn verifyAssertion(
    alloc: std.mem.Allocator,
    rp_id: []const u8,
    origin: []const u8,
    expected_challenge_raw: []const u8,
    stored_key: cose.CoseKey,
    stored_sign_count: u32,
    client_data_json: []const u8,
    authenticator_data: []const u8,
    signature: []const u8,
    require_uv: bool,
) AssertionError!AssertionResult {
    // Step 1: Parse and verify clientDataJSON
    // parseClientData allocates type/challenge/origin; we free them after verification.
    const cd = try client_data.parseClientData(alloc, client_data_json);
    defer {
        alloc.free(cd.type);
        alloc.free(cd.challenge);
        alloc.free(cd.origin);
    }
    try client_data.verifyClientData(alloc, cd, "webauthn.get", origin, expected_challenge_raw);

    // Step 2: Parse assertion authenticatorData.
    // Assertions do NOT carry attestedCredentialData (AT bit is NOT set) → cred==null.
    const ad = try authdata.parse(authenticator_data);

    // Step 3: Verify rpIdHash == SHA-256(rp_id)
    var expected_rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &expected_rp_id_hash, .{});
    if (!std.mem.eql(u8, &ad.rp_id_hash, &expected_rp_id_hash)) {
        return error.RpIdMismatch;
    }

    // Step 4: Verify UP flag (always required); optionally verify UV
    if (!ad.flags.up) return error.UserNotPresent;
    if (require_uv and !ad.flags.uv) return error.UserNotVerified;

    // Step 5: Build signature base = authenticator_data (raw bytes) || SHA-256(client_data_json)
    // CRITICAL ORDER: authData first, then 32-byte hash.
    var base = try alloc.alloc(u8, authenticator_data.len + 32);
    defer alloc.free(base);
    @memcpy(base[0..authenticator_data.len], authenticator_data);
    std.crypto.hash.sha2.Sha256.hash(client_data_json, base[authenticator_data.len..][0..32], .{});

    // Step 6: Verify signature — FAIL CLOSED.
    // verify() returns VerifyError!bool:
    //   - error.*  → malformed sig / unsupported alg → reject
    //   - false    → valid format, bad cryptographic check → reject
    //   - true     → valid
    // We catch ALL error cases and map them to error.SignatureInvalid.
    const ok = verify_sig.verify(stored_key, base, signature) catch false;
    if (!ok) return error.SignatureInvalid;

    // Step 7: signCount clone detection (§7.2 step 21)
    const new_count = ad.sign_count;
    const clone = blk: {
        if (new_count > stored_sign_count) {
            // New count is strictly greater → not a clone.
            break :blk false;
        } else if (new_count == 0 and stored_sign_count == 0) {
            // Both zero → authenticator does not use counters (common for passkeys).
            // This is not a clone signal per spec ("if nonzero… run the sub-step").
            break :blk false;
        } else {
            // new <= stored, and at least one is nonzero → clone signal.
            break :blk true;
        }
    };

    // Step 8: Return result
    return AssertionResult{
        .new_sign_count = new_count,
        .clone_suspected = clone,
    };
}

// ---------------------------------------------------------------------------
// Tests — TDD: written to define correct §7.2 behavior.
//
// Fixture construction approach (per research §8):
//   - Generate EC P-256 key pair deterministically
//   - Build authenticator_data = SHA-256("example.test") || 0x05(UP|UV) || signCount(1 BE u32)
//   - Build clientDataJSON = {type,challenge,origin} with b64url-encoded raw challenge
//   - Build base = authData || SHA-256(clientDataJSON)  — authData FIRST
//   - Sign base → DER-encode → use as signature
//   - Derive EC2 COSE key from keypair's public key
// ---------------------------------------------------------------------------

const testing = std.testing;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

/// Helper: build the 37-byte assertion authenticatorData for "example.test" with UP|UV
/// and given signCount.
fn buildAuthData(rp_id: []const u8, flags_byte: u8, sign_count: u32) [37]u8 {
    var auth: [37]u8 = undefined;
    // rpIdHash = SHA-256(rp_id)
    std.crypto.hash.sha2.Sha256.hash(rp_id, auth[0..32], .{});
    auth[32] = flags_byte;
    std.mem.writeInt(u32, auth[33..37], sign_count, .big);
    return auth;
}

/// Helper: build clientDataJSON with a b64url-encoded challenge.
fn buildClientDataJson(alloc: std.mem.Allocator, challenge_raw: []const u8, origin: []const u8) ![]u8 {
    const encoded_challenge = try client_data.b64urlNoPad(alloc, challenge_raw);
    defer alloc.free(encoded_challenge);
    return std.fmt.allocPrint(
        alloc,
        "{{\"type\":\"webauthn.get\",\"challenge\":\"{s}\",\"origin\":\"{s}\"}}",
        .{ encoded_challenge, origin },
    );
}

/// Helper: derive COSE EC2 key from an Ecdsa keypair.
fn cosekeyFromKp(kp: Ecdsa.KeyPair) cose.CoseKey {
    const sec1 = kp.public_key.toUncompressedSec1();
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memcpy(&x, sec1[1..33]);
    @memcpy(&y, sec1[33..65]);
    return cose.CoseKey{ .ec2 = .{ .alg = -7, .crv = 1, .x = x, .y = y } };
}

test "verifyAssertion: happy path — valid assertion succeeds with new_sign_count=1, clone_suspected=false" {
    const alloc = testing.allocator;
    const seed = [_]u8{0x10} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0xAA} ** 16;

    const auth_data = buildAuthData(rp_id, 0x05, 1); // UP|UV, count=1
    const cdj = try buildClientDataJson(alloc, &challenge_raw, origin);
    defer alloc.free(cdj);

    // Build signature base: auth_data || SHA-256(cdj)
    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    std.crypto.hash.sha2.Sha256.hash(cdj, base[37..][0..32], .{});

    // Sign and DER-encode
    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = raw_sig.toDer(&der_buf);

    const stored_key = cosekeyFromKp(kp);

    const result = try verifyAssertion(
        alloc, rp_id, origin, &challenge_raw,
        stored_key, 0, // stored_sign_count = 0 → new(1) > stored(0)
        cdj, &auth_data, der, true,
    );

    try testing.expectEqual(@as(u32, 1), result.new_sign_count);
    try testing.expect(!result.clone_suspected);
}

test "verifyAssertion: tampered signature byte → error.SignatureInvalid" {
    const alloc = testing.allocator;
    const seed = [_]u8{0x11} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0xBB} ** 16;

    const auth_data = buildAuthData(rp_id, 0x05, 1);
    const cdj = try buildClientDataJson(alloc, &challenge_raw, origin);
    defer alloc.free(cdj);

    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    std.crypto.hash.sha2.Sha256.hash(cdj, base[37..][0..32], .{});

    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der_slice = raw_sig.toDer(&der_buf);

    // Tamper: flip last byte
    var bad_der: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    @memcpy(bad_der[0..der_slice.len], der_slice);
    bad_der[der_slice.len - 1] ^= 0xFF;

    const stored_key = cosekeyFromKp(kp);

    try testing.expectError(
        error.SignatureInvalid,
        verifyAssertion(alloc, rp_id, origin, &challenge_raw, stored_key, 0, cdj, &auth_data, bad_der[0..der_slice.len], true),
    );
}

test "verifyAssertion: UP flag off (flags=0x04) → error.UserNotPresent" {
    const alloc = testing.allocator;
    const seed = [_]u8{0x12} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0xCC} ** 16;

    // flags = 0x04 = UV only, no UP
    const auth_data = buildAuthData(rp_id, 0x04, 1);
    const cdj = try buildClientDataJson(alloc, &challenge_raw, origin);
    defer alloc.free(cdj);

    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    std.crypto.hash.sha2.Sha256.hash(cdj, base[37..][0..32], .{});

    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = raw_sig.toDer(&der_buf);

    const stored_key = cosekeyFromKp(kp);

    try testing.expectError(
        error.UserNotPresent,
        verifyAssertion(alloc, rp_id, origin, &challenge_raw, stored_key, 0, cdj, &auth_data, der, false),
    );
}

test "verifyAssertion: wrong rp_id → error.RpIdMismatch" {
    const alloc = testing.allocator;
    const seed = [_]u8{0x13} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    const rp_id = "example.test";
    const wrong_rp_id = "evil.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0xDD} ** 16;

    // Build auth_data for the CORRECT rp_id
    const auth_data = buildAuthData(rp_id, 0x05, 1);
    const cdj = try buildClientDataJson(alloc, &challenge_raw, origin);
    defer alloc.free(cdj);

    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    std.crypto.hash.sha2.Sha256.hash(cdj, base[37..][0..32], .{});

    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = raw_sig.toDer(&der_buf);

    const stored_key = cosekeyFromKp(kp);

    // Pass wrong_rp_id to verifyAssertion — SHA-256("evil.test") != SHA-256("example.test")
    try testing.expectError(
        error.RpIdMismatch,
        verifyAssertion(alloc, wrong_rp_id, origin, &challenge_raw, stored_key, 0, cdj, &auth_data, der, true),
    );
}

test "verifyAssertion: wrong challenge → error.ChallengeMismatch" {
    const alloc = testing.allocator;
    const seed = [_]u8{0x14} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    const rp_id = "example.test";
    const origin = "https://example.test";
    const real_challenge = [_]u8{0xEE} ** 16;
    const wrong_challenge = [_]u8{0xFF} ** 16;

    const auth_data = buildAuthData(rp_id, 0x05, 1);
    // clientDataJSON encodes real_challenge
    const cdj = try buildClientDataJson(alloc, &real_challenge, origin);
    defer alloc.free(cdj);

    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    std.crypto.hash.sha2.Sha256.hash(cdj, base[37..][0..32], .{});

    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = raw_sig.toDer(&der_buf);

    const stored_key = cosekeyFromKp(kp);

    // Verify with wrong_challenge — should fail ChallengeMismatch
    try testing.expectError(
        error.ChallengeMismatch,
        verifyAssertion(alloc, rp_id, origin, &wrong_challenge, stored_key, 0, cdj, &auth_data, der, true),
    );
}

test "verifyAssertion: wrong origin → error.OriginMismatch" {
    const alloc = testing.allocator;
    const seed = [_]u8{0x15} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    const rp_id = "example.test";
    const real_origin = "https://example.test";
    const wrong_origin = "https://evil.test";
    const challenge_raw = [_]u8{0x11} ** 16;

    const auth_data = buildAuthData(rp_id, 0x05, 1);
    // clientDataJSON has the real origin
    const cdj = try buildClientDataJson(alloc, &challenge_raw, real_origin);
    defer alloc.free(cdj);

    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    std.crypto.hash.sha2.Sha256.hash(cdj, base[37..][0..32], .{});

    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = raw_sig.toDer(&der_buf);

    const stored_key = cosekeyFromKp(kp);

    // Verify with wrong_origin as expected — but clientDataJSON says real_origin
    try testing.expectError(
        error.OriginMismatch,
        verifyAssertion(alloc, rp_id, wrong_origin, &challenge_raw, stored_key, 0, cdj, &auth_data, der, true),
    );
}

test "verifyAssertion: signCount clone — stored=5, assertion count=1 → clone_suspected=true" {
    const alloc = testing.allocator;
    const seed = [_]u8{0x16} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0x22} ** 16;

    // Assertion reports count=1, but stored is 5 → clone signal
    const auth_data = buildAuthData(rp_id, 0x05, 1);
    const cdj = try buildClientDataJson(alloc, &challenge_raw, origin);
    defer alloc.free(cdj);

    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    std.crypto.hash.sha2.Sha256.hash(cdj, base[37..][0..32], .{});

    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = raw_sig.toDer(&der_buf);

    const stored_key = cosekeyFromKp(kp);

    const result = try verifyAssertion(
        alloc, rp_id, origin, &challenge_raw,
        stored_key, 5, // stored_sign_count = 5 > new(1) → clone!
        cdj, &auth_data, der, true,
    );

    try testing.expectEqual(@as(u32, 1), result.new_sign_count);
    try testing.expect(result.clone_suspected); // MUST be true
}

test "verifyAssertion: both-zero signCount — stored=0, assertion count=0 → clone_suspected=false" {
    const alloc = testing.allocator;
    const seed = [_]u8{0x17} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0x33} ** 16;

    // Both counts zero → passkey/authenticator with no counter — not a clone signal
    const auth_data = buildAuthData(rp_id, 0x05, 0);
    const cdj = try buildClientDataJson(alloc, &challenge_raw, origin);
    defer alloc.free(cdj);

    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    std.crypto.hash.sha2.Sha256.hash(cdj, base[37..][0..32], .{});

    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = raw_sig.toDer(&der_buf);

    const stored_key = cosekeyFromKp(kp);

    const result = try verifyAssertion(
        alloc, rp_id, origin, &challenge_raw,
        stored_key, 0, // stored=0, assertion=0 → both-zero → NOT clone
        cdj, &auth_data, der, true,
    );

    try testing.expectEqual(@as(u32, 0), result.new_sign_count);
    try testing.expect(!result.clone_suspected); // MUST be false
}
