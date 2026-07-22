//! Web Push runtime config (#223), threaded into `app.push`. The `subject` (the VAPID
//! `sub` claim — a `mailto:`/`https:` operator contact, NOT secret) comes from the
//! comptime `App(.{ .push = .{ .subject = "…" } })` key. The VAPID keypair is a SECRET
//! and comes from the environment (`ZIGBASE_VAPID_PUBLIC_KEY` / `ZIGBASE_VAPID_PRIVATE_KEY`,
//! base64url), decoded + cross-validated at startup by `resolve`.
//!
//! Default (`configured = false`, no keys) is a LOGGING NO-OP: `ctx.push().send` logs and
//! returns `.delivered` without touching the network, so dev/CI needs no VAPID keys and the
//! byte path is safe by default. `resolve` fails fast (never post-boot) on a half-configured
//! or mismatched keypair so a misconfiguration is caught at boot with an actionable error.

const std = @import("std");
const vapid = @import("vapid.zig");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const b64 = std.base64.url_safe_no_pad;

/// The lowered runtime config stored on `app.App.push`.
pub const Runtime = struct {
    /// VAPID `sub` claim — the operator contact (`mailto:`/`https:` URL). From the comptime
    /// `.push.subject` key; not secret.
    subject: []const u8 = "",
    /// True once a valid VAPID keypair was resolved from the environment. When false, the
    /// send path is a network-free logging no-op.
    configured: bool = false,
    /// Application-server VAPID public key (uncompressed SEC1, 65 bytes). Advertised to the
    /// browser as the subscription's `applicationServerKey` and sent as the header `k=`.
    vapid_public: [65]u8 = [_]u8{0} ** 65,
    /// Application-server VAPID private key (P-256 scalar, 32 bytes). SECRET — used to sign
    /// the VAPID JWT. Never logged.
    vapid_private: [32]u8 = [_]u8{0} ** 32,
};

pub const KeyError = error{
    /// Only one of the public/private VAPID keys was supplied — both are required.
    IncompleteVapidKeys,
    /// A VAPID key was not valid base64url of the expected length (65 pub / 32 priv).
    InvalidVapidKey,
    /// The private key does not derive the supplied public key (a copy/paste mixup).
    VapidKeyMismatch,
};

/// Decode `s` (base64url, no padding) into exactly `N` bytes, or `error.InvalidVapidKey`.
fn decodeExact(comptime N: usize, s: []const u8) KeyError![N]u8 {
    const size = b64.Decoder.calcSizeForSlice(s) catch return error.InvalidVapidKey;
    if (size != N) return error.InvalidVapidKey;
    var out: [N]u8 = undefined;
    b64.Decoder.decode(&out, s) catch return error.InvalidVapidKey;
    return out;
}

/// Resolve the effective push config from the comptime `subject` and the env-provided
/// base64url VAPID keys. Absent keys → the no-op default (`configured = false`). Present
/// keys are decoded and cross-validated (the private key must derive the public key) so a
/// misconfiguration fails fast at boot rather than silently minting invalid VAPID headers.
pub fn resolve(subject: []const u8, public_b64: []const u8, private_b64: []const u8) KeyError!Runtime {
    if (public_b64.len == 0 and private_b64.len == 0)
        return .{ .subject = subject, .configured = false };
    if (public_b64.len == 0 or private_b64.len == 0) return error.IncompleteVapidKeys;

    const pubk = try decodeExact(65, public_b64);
    const privk = try decodeExact(32, private_b64);

    // Cross-validate: the private scalar must derive the supplied public point. This catches
    // a truncated key, a swapped pub/priv pair, or a copy/paste from a different keypair.
    const sk = Ecdsa.SecretKey.fromBytes(privk) catch return error.InvalidVapidKey;
    const kp = Ecdsa.KeyPair.fromSecretKey(sk) catch return error.InvalidVapidKey;
    const derived = kp.public_key.toUncompressedSec1();
    if (!std.mem.eql(u8, &derived, &pubk)) return error.VapidKeyMismatch;

    return .{ .subject = subject, .configured = true, .vapid_public = pubk, .vapid_private = privk };
}

/// A freshly generated VAPID keypair, base64url-encoded (owned by `alloc`). Backs the
/// `zigbase vapid-keygen` CLI subcommand.
pub const Keypair = struct {
    public_b64: []u8,
    private_b64: []u8,
};

/// Generate a fresh P-256 VAPID keypair and return both keys base64url-encoded. The public
/// key goes through `vapid.publicKeyB64FromKeyPair`, tying the CLI output to the same
/// encoding the sender advertises.
pub fn generateKeypair(alloc: std.mem.Allocator, io: std.Io) !Keypair {
    const kp = Ecdsa.KeyPair.generate(io);
    const public_b64 = try vapid.publicKeyB64FromKeyPair(alloc, kp);
    errdefer alloc.free(public_b64);
    const priv = kp.secret_key.toBytes();
    const private_b64 = try alloc.alloc(u8, b64.Encoder.calcSize(priv.len));
    _ = b64.Encoder.encode(private_b64, &priv);
    return .{ .public_b64 = public_b64, .private_b64 = private_b64 };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Runtime default is the fully-off no-op path" {
    const r = Runtime{};
    try testing.expect(!r.configured);
    try testing.expectEqualStrings("", r.subject);
}

test "resolve: no keys → no-op default carrying the subject" {
    const r = try resolve("mailto:ops@example.com", "", "");
    try testing.expect(!r.configured);
    try testing.expectEqualStrings("mailto:ops@example.com", r.subject);
}

test "resolve: half-configured keys fail fast" {
    try testing.expectError(error.IncompleteVapidKeys, resolve("s", "AAAA", ""));
    try testing.expectError(error.IncompleteVapidKeys, resolve("s", "", "AAAA"));
}

test "resolve: a matched keypair configures push; a mismatched one fails" {
    const a = testing.allocator;

    const kp = try generateKeypair(a, testing.io);
    defer a.free(kp.public_b64);
    defer a.free(kp.private_b64);
    const r = try resolve("mailto:ops@example.com", kp.public_b64, kp.private_b64);
    try testing.expect(r.configured);
    try testing.expectEqualStrings("mailto:ops@example.com", r.subject);

    // A public key from a DIFFERENT pair must be rejected.
    const other = try generateKeypair(a, testing.io);
    defer a.free(other.public_b64);
    defer a.free(other.private_b64);
    try testing.expectError(error.VapidKeyMismatch, resolve("s", other.public_b64, kp.private_b64));

    // Garbage / wrong-length keys are rejected as invalid.
    try testing.expectError(error.InvalidVapidKey, resolve("s", "not-base64!!", kp.private_b64));
    try testing.expectError(error.InvalidVapidKey, resolve("s", kp.public_b64, "AAAA"));
}

test "generateKeypair: output round-trips through vapidAuthHeader + verifies" {
    const a = testing.allocator;

    // Generate as the CLI does, then reload via resolve (as serveImpl does).
    const kp = try generateKeypair(a, testing.io);
    defer a.free(kp.public_b64);
    defer a.free(kp.private_b64);
    const rt = try resolve("mailto:ops@example.com", kp.public_b64, kp.private_b64);
    try testing.expect(rt.configured);

    // Build a real VAPID Authorization header with the resolved keys and verify its JWT
    // signature — this ties the CLI-generated keypair to a signature that a push service
    // would accept.
    const hdr = try vapid.vapidAuthHeader(a, testing.io, "https://push.example.com", rt.subject, rt.vapid_public, rt.vapid_private, 1700000000, 1700000000 + 12 * 3600);
    defer a.free(hdr);
    try testing.expect(std.mem.startsWith(u8, hdr, "vapid t="));

    // Extract "header.claims.signature" and verify against the public key.
    const t_start = "vapid t=".len;
    const k_marker = ", k=";
    const ki = std.mem.indexOf(u8, hdr, k_marker).?;
    const jwt = hdr[t_start..ki];
    var it = std.mem.splitScalar(u8, jwt, '.');
    const h = it.next().?;
    const c = it.next().?;
    const s = it.next().?;
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ h, c });
    defer a.free(signing_input);
    var sig_bytes: [64]u8 = undefined;
    try b64.Decoder.decode(&sig_bytes, s);
    const sig = Ecdsa.Signature.fromBytes(sig_bytes);
    const pk = try Ecdsa.PublicKey.fromSec1(&rt.vapid_public);
    try sig.verify(signing_input, pk);
}
