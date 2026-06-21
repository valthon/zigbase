// verify_sig.zig — WebAuthn signature verification for ES256 (ECDSA P-256 DER),
// Ed25519 (raw 64-byte), and RS256 (best-effort via std.crypto.Certificate.rsa).
//
// SECURITY-CRITICAL: Two classic bugs to guard against:
//   1. DER-vs-raw: ES256 signatures are ASN.1 DER SEQUENCE{r,s}, NOT raw 64-byte r||s.
//      Feeding raw bytes to fromDer() correctly errors (enforced by negative test).
//   2. Signature base byte order: base = authData || SHA-256(clientDataJSON).
//      authData first, then 32-byte hash. Wrong order must fail (negative test locks this in).
//
// RS256 note: std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify() takes a
// comptime modulus_len parameter. Since WebAuthn RS256 modulus length is runtime-
// determined from the COSE key, we'd need to branch on common sizes (256/384/512).
// However, this is risky (a size mismatch silently truncates). We implement it
// behind a comptime branch that rejects at runtime with error.UnsupportedAlgorithm,
// and document the reason. Adjust if RS256 support is needed later.

const std = @import("std");
const cose = @import("cose.zig");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed = std.crypto.sign.Ed25519;

pub const VerifyError = error{
    /// Signature is invalid for the given message and key.
    SignatureInvalid,
    /// Signature bytes are malformed (e.g. DER parse failure, wrong length).
    MalformedSignature,
    /// Algorithm is not supported (e.g. RS256 without a fixed modulus).
    UnsupportedAlgorithm,
    /// Public key is malformed or encodes an identity element.
    InvalidPublicKey,
};

/// Verify a WebAuthn signature.
///
/// `key`            — the COSE public key (from stored credential).
/// `signature_base` — authData || SHA-256(clientDataJSON)  (caller MUST build in THAT order).
/// `sig`            — wire signature: DER-encoded for ES256/RS256, raw 64 bytes for Ed25519.
///
/// Returns `true` if the signature is valid.
/// Returns `false` if the signature is cryptographically invalid (bad r/s for the message).
/// Returns an error if the signature is malformed / algorithm unsupported / key invalid
///   — callers MUST treat any error as "reject" (fail-closed).
///
/// NOTE: The distinction between `false` vs error on invalid-signature is intentional:
///   - `false`: valid DER/format, bad cryptographic check (common "reject this assertion")
///   - error: the signature bytes are themselves malformed (DER parse error, wrong length, etc.)
pub fn verify(key: cose.CoseKey, signature_base: []const u8, sig: []const u8) VerifyError!bool {
    switch (key) {
        .ec2 => |k| {
            // ES256: signature MUST be ASN.1 DER SEQUENCE{r,s}.
            // fromDer() will error on raw 64 bytes — this is by design and guards DER-vs-raw.
            const der_sig = Ecdsa.Signature.fromDer(sig) catch return error.MalformedSignature;

            // Build uncompressed SEC1 public key: 0x04 || x (32B) || y (32B)
            var sec1: [65]u8 = undefined;
            sec1[0] = 0x04;
            @memcpy(sec1[1..33], &k.x);
            @memcpy(sec1[33..65], &k.y);
            const pk = Ecdsa.PublicKey.fromSec1(&sec1) catch return error.InvalidPublicKey;

            // verify() SHA-256-hashes signature_base internally — pass the RAW base,
            // NOT a pre-hash (authData || sha256(clientDataJSON)).
            der_sig.verify(signature_base, pk) catch |err| switch (err) {
                error.SignatureVerificationFailed => return false,
                else => return error.SignatureInvalid,
            };
            return true;
        },
        .okp => |k| {
            // Ed25519: signature is raw 64 bytes, NOT DER.
            if (sig.len != Ed.Signature.encoded_length) return error.MalformedSignature;
            const ed_sig = Ed.Signature.fromBytes(sig[0..Ed.Signature.encoded_length].*);
            const pk = Ed.PublicKey.fromBytes(k.x) catch return error.InvalidPublicKey;

            // Ed25519 verify() handles hashing internally.
            ed_sig.verify(signature_base, pk) catch |err| switch (err) {
                error.SignatureVerificationFailed => return false,
                else => return error.SignatureInvalid,
            };
            return true;
        },
        .rsa => {
            // RS256 via std.crypto.Certificate.rsa is feasible but requires a
            // comptime modulus_len parameter that is not known statically here.
            // We would need to branch on common sizes (256, 384, 512 bytes) and
            // risk silent truncation on a mismatch. Given RS256 is rare in the
            // modern passkey ecosystem (mostly old Windows Hello TPMs), we reject
            // it clearly rather than implement it unsafely.
            //
            // To enable RS256: branch on key.rsa.n.len, call
            //   std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(modulus_len, sig[0..modulus_len].*, ...)
            // for each supported modulus_len, and handle the comptime requirement.
            return error.UnsupportedAlgorithm;
        },
    }
}

// ---------------------------------------------------------------------------
// Tests — TDD: these are written FIRST and define the correct behavior.
// Each test covers a precise security property; a wrong implementation fails them.
// ---------------------------------------------------------------------------

test "verify_sig: ES256 happy path — DER signature verifies" {
    // Generate a deterministic key pair from a fixed seed.
    const seed = [_]u8{0x42} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    // Build a representative signature_base: 37-byte authData || 32-byte clientDataHash.
    // (In a real assertion: authData = rpIdHash[32]||flags[1]||signCount[4]; hash = SHA-256(clientDataJSON))
    var auth_data = [_]u8{0xAA} ** 37;
    auth_data[32] = 0x05; // flags: UP | UV
    auth_data[33] = 0x00; // signCount BE u32 = 1
    auth_data[34] = 0x00;
    auth_data[35] = 0x00;
    auth_data[36] = 0x01;
    const client_data_hash = [_]u8{0xBB} ** 32;

    // Concatenate: authData first, then the 32-byte hash (THE canonical order).
    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    @memcpy(base[37..], &client_data_hash);

    // Sign and DER-encode the signature.
    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der = raw_sig.toDer(&der_buf);

    // Extract x/y from the public key's uncompressed SEC1 encoding.
    const sec1 = kp.public_key.toUncompressedSec1();
    // sec1 = 0x04 || x[32] || y[32]
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memcpy(&x, sec1[1..33]);
    @memcpy(&y, sec1[33..65]);

    const key = cose.CoseKey{ .ec2 = .{ .alg = -7, .crv = 1, .x = x, .y = y } };

    const result = try verify(key, &base, der);
    try std.testing.expect(result == true);
}

test "verify_sig: ES256 negative — flipped signature byte returns false or error (reject)" {
    const seed = [_]u8{0x43} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    var auth_data = [_]u8{0xAA} ** 37;
    const client_data_hash = [_]u8{0xBB} ** 32;
    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    @memcpy(base[37..], &client_data_hash);

    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der_slice = raw_sig.toDer(&der_buf);

    const sec1 = kp.public_key.toUncompressedSec1();
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memcpy(&x, sec1[1..33]);
    @memcpy(&y, sec1[33..65]);
    const key = cose.CoseKey{ .ec2 = .{ .alg = -7, .crv = 1, .x = x, .y = y } };

    // Flip one byte in the DER signature — should NOT verify.
    var bad_der: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    @memcpy(bad_der[0..der_slice.len], der_slice);
    bad_der[der_slice.len - 1] ^= 0xFF;
    const bad_der_slice = bad_der[0..der_slice.len];

    // Must NOT return true — either false or error is acceptable (caller rejects either way).
    const result = verify(key, &base, bad_der_slice) catch return; // error = rejected, test passes
    try std.testing.expect(result == false); // false = rejected, test passes
}

test "verify_sig: ES256 negative — flipped signature_base byte returns false or error (reject)" {
    const seed = [_]u8{0x44} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    var auth_data = [_]u8{0xAA} ** 37;
    const client_data_hash = [_]u8{0xBB} ** 32;
    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    @memcpy(base[37..], &client_data_hash);

    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der_slice = raw_sig.toDer(&der_buf);

    const sec1 = kp.public_key.toUncompressedSec1();
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memcpy(&x, sec1[1..33]);
    @memcpy(&y, sec1[33..65]);
    const key = cose.CoseKey{ .ec2 = .{ .alg = -7, .crv = 1, .x = x, .y = y } };

    // Flip one byte in the base — the message no longer matches what was signed.
    var bad_base = base;
    bad_base[0] ^= 0xFF;

    const result = verify(key, &bad_base, der_slice) catch return;
    try std.testing.expect(result == false);
}

test "verify_sig: ES256 negative — raw 64-byte r||s must NOT verify as DER (DER-vs-raw guard)" {
    // This is THE classic WebAuthn bug: accepting raw r||s as if it were DER.
    // fromDer() must reject raw 64 bytes, so verify() must return an error (not true).
    const seed = [_]u8{0x45} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    var base: [37 + 32]u8 = undefined;
    @memset(&base, 0xCC);

    const raw_sig = try kp.sign(&base, null);
    const raw_bytes = raw_sig.toBytes(); // raw 64-byte r||s, NOT DER

    const sec1 = kp.public_key.toUncompressedSec1();
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memcpy(&x, sec1[1..33]);
    @memcpy(&y, sec1[33..65]);
    const key = cose.CoseKey{ .ec2 = .{ .alg = -7, .crv = 1, .x = x, .y = y } };

    // fromDer() will reject raw 64 bytes (not 0x30-prefixed SEQUENCE) → error.MalformedSignature.
    // Under no circumstances should this return true.
    const result = verify(key, &base, &raw_bytes) catch |err| {
        try std.testing.expect(err == error.MalformedSignature);
        return; // correctly rejected
    };
    // If somehow it returned a bool, it must be false.
    try std.testing.expect(result == false);
}

test "verify_sig: ES256 negative — truncated DER returns error.MalformedSignature" {
    const seed = [_]u8{0x46} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    var base: [37 + 32]u8 = undefined;
    @memset(&base, 0xDD);

    const raw_sig = try kp.sign(&base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der_slice = raw_sig.toDer(&der_buf);

    const sec1 = kp.public_key.toUncompressedSec1();
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memcpy(&x, sec1[1..33]);
    @memcpy(&y, sec1[33..65]);
    const key = cose.CoseKey{ .ec2 = .{ .alg = -7, .crv = 1, .x = x, .y = y } };

    // Truncate the DER signature — must fail with MalformedSignature.
    const truncated = der_slice[0 .. der_slice.len / 2];
    try std.testing.expectError(error.MalformedSignature, verify(key, &base, truncated));
}

test "verify_sig: ES256 base-order sanity — authData||hash passes; hash||authData fails" {
    // Locks in the concatenation order: authData MUST come before the hash.
    // WebAuthn §7.2 step 20: "verify that sig is a valid signature over the
    // binary concatenation of authData and hash" — authData first.
    const seed = [_]u8{0x47} ** 32;
    const kp = try Ecdsa.KeyPair.generateDeterministic(seed);

    var auth_data: [37]u8 = undefined;
    @memset(&auth_data, 0xEE);
    var hash: [32]u8 = undefined;
    @memset(&hash, 0xFF);

    // Correct order: authData || hash
    var correct_base: [37 + 32]u8 = undefined;
    @memcpy(correct_base[0..37], &auth_data);
    @memcpy(correct_base[37..], &hash);

    // Wrong order: hash || authData (swapped)
    var wrong_base: [32 + 37]u8 = undefined;
    @memcpy(wrong_base[0..32], &hash);
    @memcpy(wrong_base[32..], &auth_data);

    const raw_sig = try kp.sign(&correct_base, null);
    var der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const der_slice = raw_sig.toDer(&der_buf);

    const sec1 = kp.public_key.toUncompressedSec1();
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memcpy(&x, sec1[1..33]);
    @memcpy(&y, sec1[33..65]);
    const key = cose.CoseKey{ .ec2 = .{ .alg = -7, .crv = 1, .x = x, .y = y } };

    // Correct base must verify.
    const ok = try verify(key, &correct_base, der_slice);
    try std.testing.expect(ok == true);

    // Wrong (swapped) base must NOT verify.
    const bad = verify(key, &wrong_base, der_slice) catch return; // error = rejected, ok
    try std.testing.expect(bad == false);
}

test "verify_sig: Ed25519 happy path — raw 64-byte signature verifies" {
    // Generate a deterministic Ed25519 key pair.
    const seed: [32]u8 = [_]u8{0x55} ** 32;
    const kp = try Ed.KeyPair.generateDeterministic(seed);

    var auth_data = [_]u8{0xAA} ** 37;
    auth_data[32] = 0x05;
    const client_data_hash = [_]u8{0xBB} ** 32;

    var base: [37 + 32]u8 = undefined;
    @memcpy(base[0..37], &auth_data);
    @memcpy(base[37..], &client_data_hash);

    // Ed25519 sign returns raw 64-byte signature.
    const raw_sig = try kp.sign(&base, null);
    const sig_bytes = raw_sig.toBytes();

    const key = cose.CoseKey{ .okp = .{ .alg = -8, .crv = 6, .x = kp.public_key.toBytes() } };

    const result = try verify(key, &base, &sig_bytes);
    try std.testing.expect(result == true);
}

test "verify_sig: Ed25519 negative — tampered message returns false or error (reject)" {
    const seed: [32]u8 = [_]u8{0x56} ** 32;
    const kp = try Ed.KeyPair.generateDeterministic(seed);

    var base: [37 + 32]u8 = undefined;
    @memset(&base, 0x11);

    const raw_sig = try kp.sign(&base, null);
    const sig_bytes = raw_sig.toBytes();

    const key = cose.CoseKey{ .okp = .{ .alg = -8, .crv = 6, .x = kp.public_key.toBytes() } };

    // Tamper with the base — must not verify.
    var bad_base = base;
    bad_base[0] ^= 0xFF;

    const result = verify(key, &bad_base, &sig_bytes) catch return;
    try std.testing.expect(result == false);
}

test "verify_sig: Ed25519 negative — wrong length sig returns error.MalformedSignature" {
    const key = cose.CoseKey{ .okp = .{ .alg = -8, .crv = 6, .x = [_]u8{0} ** 32 } };
    const base = [_]u8{0} ** 69;
    const bad_sig = [_]u8{0} ** 32; // 32 bytes, not 64
    try std.testing.expectError(error.MalformedSignature, verify(key, &base, &bad_sig));
}

test "verify_sig: RS256 key returns error.UnsupportedAlgorithm" {
    // RS256 is rejected cleanly — caller must treat this as "deny".
    // Document: to enable RS256, implement comptime modulus_len branching via
    //   std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(modulus_len, ...).
    const n_bytes = [_]u8{0xCD} ** 256;
    const e_bytes = [_]u8{ 0x01, 0x00, 0x01 };
    const key = cose.CoseKey{ .rsa = .{ .alg = -257, .n = &n_bytes, .e = &e_bytes } };
    const base = [_]u8{0} ** 69;
    const sig_bytes = [_]u8{0} ** 256;

    try std.testing.expectError(error.UnsupportedAlgorithm, verify(key, &base, &sig_bytes));
}
