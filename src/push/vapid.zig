// vapid.zig — RFC 8292 Voluntary Application Server Identification (VAPID).
//
// Produces the `Authorization` header a push service requires to attribute a
// request to an application server: an ES256-signed JWT plus the raw public key.
//
//   Authorization: vapid t=<JWT>, k=<base64url(public_key)>
//
// SECURITY-CRITICAL detail (the classic JWS bug): ES256 signatures on the wire
// are the fixed-length raw `r || s` (64 bytes), NOT ASN.1 DER. std's
// `EcdsaP256Sha256.Signature.toBytes()` yields exactly that raw form — we use it
// and a round-trip verify test locks the 64-byte shape in.
//
// Spec references:
//   RFC 8292 §2 (token + JWT)   https://www.rfc-editor.org/rfc/rfc8292#section-2
//   RFC 8292 §3 (Vapid header)  https://www.rfc-editor.org/rfc/rfc8292#section-3
//   RFC 7515 §3 (JWS r||s)      https://www.rfc-editor.org/rfc/rfc7515

const std = @import("std");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const b64 = std.base64.url_safe_no_pad;

pub const Error = error{InvalidKey} || std.mem.Allocator.Error;

fn b64enc(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, b64.Encoder.calcSize(data.len));
    _ = b64.Encoder.encode(out, data);
    return out;
}

/// The claim set of a VAPID JWT (RFC 8292 §2). Field order fixes the serialized
/// JSON: aud, exp, sub.
const Claims = struct {
    /// Origin (scheme + host[:port]) of the push endpoint.
    aud: []const u8,
    /// Expiry, unix seconds. RFC 8292 caps this at 24h from issuance.
    exp: i64,
    /// Contact for the app server operator — a `mailto:` or `https:` URL.
    sub: []const u8,
};

/// base64url of the fixed ES256 JWT header `{"typ":"JWT","alg":"ES256"}`.
const header_b64 = "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9";

/// base64url(public_key). This is the `k` parameter of the Authorization header
/// and the value a subscription's server key is advertised as. Pass-2 keygen
/// uses it to surface a freshly generated VAPID public key.
pub fn publicKeyB64(alloc: std.mem.Allocator, public_key: [65]u8) ![]u8 {
    return b64enc(alloc, &public_key);
}

/// Derive the base64url public key directly from an ECDSA P-256 keypair.
pub fn publicKeyB64FromKeyPair(alloc: std.mem.Allocator, kp: Ecdsa.KeyPair) ![]u8 {
    return b64enc(alloc, &kp.public_key.toUncompressedSec1());
}

/// Build the signed VAPID JWT (`header.claims.signature`). The signature is
/// ES256 = ECDSA-P256-SHA256 over `header.claims`, emitted as raw r||s (64
/// bytes), base64url. `io` supplies random signing noise (fault-attack
/// hardening); the signature stays a valid ES256 signature regardless.
pub fn buildJwt(
    alloc: std.mem.Allocator,
    io: std.Io,
    endpoint_origin: []const u8,
    subject: []const u8,
    private_key: [32]u8,
    exp_unix: i64,
) Error![]u8 {
    const claims = Claims{ .aud = endpoint_origin, .exp = exp_unix, .sub = subject };
    const claims_json = try std.json.Stringify.valueAlloc(alloc, claims, .{});
    const claims_b64 = try b64enc(alloc, claims_json);

    const signing_input = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ header_b64, claims_b64 });

    const sk = Ecdsa.SecretKey.fromBytes(private_key) catch return error.InvalidKey;
    const kp = Ecdsa.KeyPair.fromSecretKey(sk) catch return error.InvalidKey;
    var noise: [Ecdsa.noise_length]u8 = undefined;
    io.random(&noise);
    const sig = kp.sign(signing_input, noise) catch return error.InvalidKey;
    const sig_raw = sig.toBytes(); // raw r||s (64 bytes), the JWS/ES256 form.
    const sig_b64 = try b64enc(alloc, &sig_raw);

    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ signing_input, sig_b64 });
}

/// Produce the full `Authorization` header value:
///   vapid t=<JWT>, k=<base64url(public_key)>
///
/// `endpoint_origin` — origin of the push endpoint (the JWT `aud`).
/// `subject`         — operator contact (`mailto:`/`https:` URL), the JWT `sub`.
/// `now_unix`        — issuance time (currently unused in claims; reserved for an
///                     `iat` should a push service require it — kept in the
///                     signature so Pass 2 need not change callers).
pub fn vapidAuthHeader(
    alloc: std.mem.Allocator,
    io: std.Io,
    endpoint_origin: []const u8,
    subject: []const u8,
    public_key: [65]u8,
    private_key: [32]u8,
    now_unix: i64,
    exp_unix: i64,
) Error![]u8 {
    _ = now_unix;
    const jwt = try buildJwt(alloc, io, endpoint_origin, subject, private_key, exp_unix);
    const k = try publicKeyB64(alloc, public_key);
    return std.fmt.allocPrint(alloc, "vapid t={s}, k={s}", .{ jwt, k });
}

// ---------------------------------------------------------------------------
// Tests — ES256 signatures are randomized, so we assert structure + verify
// round-trip rather than a fixed signature vector.
// ---------------------------------------------------------------------------

fn b64dec(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, try b64.Decoder.calcSizeForSlice(s));
    try b64.Decoder.decode(out, s);
    return out;
}

test "vapid: header segment decodes to the ES256 JWT header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decoded = try b64dec(a, header_b64);
    try std.testing.expectEqualStrings("{\"typ\":\"JWT\",\"alg\":\"ES256\"}", decoded);
}

test "vapid: JWT claims JSON is {aud,exp,sub} and the signature round-trips + is 64-byte r||s" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const kp = try Ecdsa.KeyPair.generateDeterministic([_]u8{0x7} ** 32);
    const priv = kp.secret_key.toBytes();

    const jwt = try buildJwt(a, std.testing.io, "https://push.example.com", "mailto:ops@example.com", priv, 1700000000);

    var it = std.mem.splitScalar(u8, jwt, '.');
    const h = it.next().?;
    const c = it.next().?;
    const s = it.next().?;
    try std.testing.expect(it.next() == null);

    try std.testing.expectEqualStrings(header_b64, h);

    const claims_json = try b64dec(a, c);
    try std.testing.expectEqualStrings(
        "{\"aud\":\"https://push.example.com\",\"exp\":1700000000,\"sub\":\"mailto:ops@example.com\"}",
        claims_json,
    );

    // Signature MUST be raw r||s (64 bytes), NOT DER.
    const sig_bytes = try b64dec(a, s);
    try std.testing.expectEqual(@as(usize, 64), sig_bytes.len);

    // Round-trip verify over "header.claims".
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ h, c });
    const sig = Ecdsa.Signature.fromBytes(sig_bytes[0..64].*);
    try sig.verify(signing_input, kp.public_key);
}

test "vapid: tampered claims break signature verification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const kp = try Ecdsa.KeyPair.generateDeterministic([_]u8{0x9} ** 32);
    const jwt = try buildJwt(a, std.testing.io, "https://p.example", "mailto:x@e.com", kp.secret_key.toBytes(), 1700000000);

    var it = std.mem.splitScalar(u8, jwt, '.');
    const h = it.next().?;
    const c = it.next().?;
    const s = it.next().?;

    // Flip a byte in the claims segment; the same signature must no longer verify.
    const bad_c = try a.dupe(u8, c);
    bad_c[0] = if (bad_c[0] == 'e') 'f' else 'e';
    const bad_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ h, bad_c });
    const sig = Ecdsa.Signature.fromBytes((try b64dec(a, s))[0..64].*);
    try std.testing.expectError(error.SignatureVerificationFailed, sig.verify(bad_input, kp.public_key));
}

test "vapid: Authorization header shape is `vapid t=..., k=base64url(public_key)`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const kp = try Ecdsa.KeyPair.generateDeterministic([_]u8{0x3} ** 32);
    const pub_sec1 = kp.public_key.toUncompressedSec1();

    const hdr = try vapidAuthHeader(a, std.testing.io, "https://push.example.com", "mailto:ops@example.com", pub_sec1, kp.secret_key.toBytes(), 1699999000, 1700000000);

    try std.testing.expect(std.mem.startsWith(u8, hdr, "vapid t="));
    const k_marker = ", k=";
    const ki = std.mem.indexOf(u8, hdr, k_marker).?;
    const k_val = hdr[ki + k_marker.len ..];

    // k must be base64url(public_key).
    const expected_k = try publicKeyB64(a, pub_sec1);
    try std.testing.expectEqualStrings(expected_k, k_val);
    // And it must decode back to the 65-byte SEC1 key.
    const decoded = try b64dec(a, k_val);
    try std.testing.expectEqualSlices(u8, &pub_sec1, decoded);

    // The token between "t=" and ", k=" is a well-formed 3-segment JWT.
    const t_val = hdr["vapid t=".len..ki];
    var dots: usize = 0;
    for (t_val) |ch| {
        if (ch == '.') dots += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), dots);
}

test "vapid: publicKeyB64FromKeyPair matches publicKeyB64 of the SEC1 key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kp = try Ecdsa.KeyPair.generateDeterministic([_]u8{0x5} ** 32);
    const from_kp = try publicKeyB64FromKeyPair(a, kp);
    const from_bytes = try publicKeyB64(a, kp.public_key.toUncompressedSec1());
    try std.testing.expectEqualStrings(from_bytes, from_kp);
}
