// register.zig — WebAuthn Registration ceremony verification (§7.1, fmt:"none").
//
// Implements the RP server-side portion of §7.1 Registration, accepting only
// fmt:"none" attestation (v1 scope). Returns the credential data to store.
//
// Step order:
//   1. parseClientData(client_data_json) + verifyClientData(type="webauthn.create", origin, challenge)
//   2. CBOR-decode attestation_object → fmt, authData(bstr), attStmt; REQUIRE fmt=="none"
//   3. authdata.parse(authData); REQUIRE flags.at
//   4. REQUIRE rp_id_hash == SHA-256(rp_id)
//   5. REQUIRE flags.up; if require_uv REQUIRE flags.uv
//   6. parseCoseKey(cred.cose_key); REQUIRE alg in {-7 (ES256), -8 (EdDSA)}
//   7. Return RegistrationResult
//
// FAIL CLOSED: any decode/parse/check error propagates immediately.

const std = @import("std");
const cbor = @import("cbor.zig");
const authdata = @import("authdata.zig");
const cose = @import("cose.zig");
const client_data = @import("client_data.zig");

pub const RegistrationError = error{
    UnsupportedAttestationFormat, // fmt is not "none"
    MissingCredentialData, // AT flag not set in authData
    RpIdMismatch, // rpIdHash != SHA-256(rp_id)
    UserNotPresent, // UP flag not set
    UserNotVerified, // UV flag not set but require_uv=true
    UnsupportedAlgorithm, // COSE key alg not in offered set
    MissingFmt, // attestationObject missing "fmt" key
    MissingAuthData, // attestationObject missing "authData" key
    MissingAttStmt, // attestationObject missing "attStmt" key
};

pub const RegistrationResult = struct {
    /// Raw credential ID bytes (slice into authData / duped with alloc as needed).
    credential_id: []const u8,
    /// The COSE key bytes (full CBOR-encoded COSE_Key from authData).
    cose_pubkey: []const u8,
    /// COSE algorithm ID (e.g. -7 for ES256, -8 for EdDSA).
    alg: i64,
    /// Signature counter at registration (store as initial value).
    sign_count: u32,
    /// Authenticator AAGUID (16 bytes; all-zero is valid for fmt:"none").
    aaguid: [16]u8,
};

/// Verify a WebAuthn registration ceremony per §7.1 (fmt:"none" only in v1).
///
/// Inputs:
///   alloc                 — allocator for clientData parsing scratch
///   rp_id                 — the Relying Party ID (e.g. "example.test")
///   origin                — the RP's expected origin (e.g. "https://example.test")
///   expected_challenge_raw — the raw challenge bytes the RP issued (NOT base64url)
///   client_data_json      — the raw clientDataJSON bytes from the client
///   attestation_object    — the attestationObject bytes from the client (CBOR)
///   require_uv            — if true, require the UV (User Verified) flag
///
/// Returns RegistrationResult on success. Fails closed on any error.
pub fn verifyRegistration(
    alloc: std.mem.Allocator,
    rp_id: []const u8,
    origin: []const u8,
    expected_challenge_raw: []const u8,
    client_data_json: []const u8,
    attestation_object: []const u8,
    require_uv: bool,
) !RegistrationResult {
    // Step 1: Parse and verify clientDataJSON.
    const cd = try client_data.parseClientData(alloc, client_data_json);
    defer {
        alloc.free(cd.type);
        alloc.free(cd.challenge);
        alloc.free(cd.origin);
    }
    try client_data.verifyClientData(alloc, cd, "webauthn.create", origin, expected_challenge_raw);

    // Step 2: CBOR-decode the attestationObject.
    // Expected map: {"fmt": tstr, "authData": bstr, "attStmt": map}
    // Key order is not guaranteed; we scan all pairs.
    var r = cbor.Reader.init(attestation_object);
    const map_len = try r.readMapLen();

    var fmt_str: ?[]const u8 = null;
    var auth_data_bytes: ?[]const u8 = null;
    var att_stmt_present: bool = false;

    var i: u64 = 0;
    while (i < map_len) : (i += 1) {
        const key = try r.next();
        switch (key) {
            .text => |k| {
                if (std.mem.eql(u8, k, "fmt")) {
                    fmt_str = try r.readText();
                } else if (std.mem.eql(u8, k, "authData")) {
                    auth_data_bytes = try r.readBytes();
                } else if (std.mem.eql(u8, k, "attStmt")) {
                    // Skip the attStmt value (empty map for "none", or other for other fmts).
                    try r.skip();
                    att_stmt_present = true;
                } else {
                    try r.skip();
                }
            },
            else => {
                // Non-text key: skip the value.
                try r.skip();
            },
        }
    }

    if (fmt_str == null) return error.MissingFmt;
    if (auth_data_bytes == null) return error.MissingAuthData;
    if (!att_stmt_present) return error.MissingAttStmt;

    // REQUIRE fmt == "none" — explicitly reject other formats.
    if (!std.mem.eql(u8, fmt_str.?, "none")) return error.UnsupportedAttestationFormat;

    // Step 3: Parse authData; REQUIRE AT flag (attested credential data present).
    const ad = try authdata.parse(auth_data_bytes.?);
    if (!ad.flags.at) return error.MissingCredentialData;

    const cred_data = ad.cred orelse return error.MissingCredentialData;

    // Step 4: Verify rpIdHash == SHA-256(rp_id).
    var expected_rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &expected_rp_id_hash, .{});
    if (!std.mem.eql(u8, &ad.rp_id_hash, &expected_rp_id_hash)) return error.RpIdMismatch;

    // Step 5: Verify UP (and optionally UV).
    if (!ad.flags.up) return error.UserNotPresent;
    if (require_uv and !ad.flags.uv) return error.UserNotVerified;

    // Step 6: Parse the credential COSE key; REQUIRE alg is in offered set {-7, -8}.
    const cose_result = try cose.parseCoseKey(cred_data.cose_key);
    const key_alg: i64 = switch (cose_result.key) {
        .ec2 => |k| k.alg,
        .okp => |k| k.alg,
        .rsa => |k| k.alg,
    };
    if (key_alg != -7 and key_alg != -8) return error.UnsupportedAlgorithm;

    // Step 7: Return the credential to store.
    return RegistrationResult{
        .credential_id = cred_data.credential_id,
        .cose_pubkey = cred_data.cose_key,
        .alg = key_alg,
        .sign_count = ad.sign_count,
        .aaguid = cred_data.aaguid,
    };
}

// ---------------------------------------------------------------------------
// Tests — TDD: tests were written first, implementation second.
// ---------------------------------------------------------------------------

/// Build an EC2 COSE_Key bytes: map(5) {1:2, 3:-7, -1:1, -2:x(32B), -3:y(32B)}
fn buildEc2CoseKey(allocator: std.mem.Allocator, x: [32]u8, y: [32]u8) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    // map(5)
    try buf.append(allocator, 0xa5);
    // 1: 2 (kty = EC2)
    try buf.append(allocator, 0x01);
    try buf.append(allocator, 0x02);
    // 3: -7 (alg = ES256) => 0x26
    try buf.append(allocator, 0x03);
    try buf.append(allocator, 0x26);
    // -1: 1 (crv = P-256) => 0x20, 0x01
    try buf.append(allocator, 0x20);
    try buf.append(allocator, 0x01);
    // -2: bstr(32, x) => 0x21, 0x58, 0x20, x...
    try buf.append(allocator, 0x21);
    try buf.append(allocator, 0x58);
    try buf.append(allocator, 0x20);
    try buf.appendSlice(allocator, &x);
    // -3: bstr(32, y) => 0x22, 0x58, 0x20, y...
    try buf.append(allocator, 0x22);
    try buf.append(allocator, 0x58);
    try buf.append(allocator, 0x20);
    try buf.appendSlice(allocator, &y);
    return buf;
}

/// Build authData bytes with AT set (flags=0x45: UP|UV|AT).
/// Layout: rpIdHash(32) ++ flags(1) ++ signCount(4 BE) ++
///         aaguid(16) ++ credIdLen(2 BE) ++ credId ++ coseKey
fn buildAuthData(
    allocator: std.mem.Allocator,
    rp_id_hash: [32]u8,
    flags: u8,
    sign_count: u32,
    aaguid: [16]u8,
    cred_id: []const u8,
    cose_key_bytes: []const u8,
) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    // rpIdHash (32 bytes)
    try buf.appendSlice(allocator, &rp_id_hash);
    // flags (1 byte)
    try buf.append(allocator, flags);
    // signCount (4 bytes BE)
    var sc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &sc_bytes, sign_count, .big);
    try buf.appendSlice(allocator, &sc_bytes);
    // aaguid (16 bytes)
    try buf.appendSlice(allocator, &aaguid);
    // credIdLen (2 bytes BE)
    var cil_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &cil_bytes, @intCast(cred_id.len), .big);
    try buf.appendSlice(allocator, &cil_bytes);
    // credId
    try buf.appendSlice(allocator, cred_id);
    // COSE key
    try buf.appendSlice(allocator, cose_key_bytes);
    return buf;
}

/// Build an attestationObject CBOR map:
/// {
///   "fmt":      tstr ("none"),
///   "attStmt":  map(0),
///   "authData": bstr(<auth_data>),
/// }
///
/// Encoded as a 3-entry CBOR map. authData bstr uses 0x59 <u16-len> prefix
/// because authData is typically > 255 bytes.
fn buildAttestationObject(
    allocator: std.mem.Allocator,
    auth_data: []const u8,
) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // map(3) = 0xA3
    try buf.append(allocator, 0xa3);

    // "fmt": "none"
    // tstr(3) "fmt" = 0x63 'f' 'm' 't'
    try buf.append(allocator, 0x63);
    try buf.appendSlice(allocator, "fmt");
    // tstr(4) "none" = 0x64 'n' 'o' 'n' 'e'
    try buf.append(allocator, 0x64);
    try buf.appendSlice(allocator, "none");

    // "attStmt": {} (empty map)
    // tstr(7) "attStmt" = 0x67 'a' 't' 't' 'S' 't' 'm' 't'
    try buf.append(allocator, 0x67);
    try buf.appendSlice(allocator, "attStmt");
    // map(0) = 0xA0
    try buf.append(allocator, 0xa0);

    // "authData": bstr(<auth_data>)
    // tstr(8) "authData" = 0x68 'a' 'u' 't' 'h' 'D' 'a' 't' 'a'
    try buf.append(allocator, 0x68);
    try buf.appendSlice(allocator, "authData");
    // bstr with 2-byte length (authData will be > 255 bytes)
    const ad_len = auth_data.len;
    if (ad_len <= 23) {
        try buf.append(allocator, 0x40 | @as(u8, @intCast(ad_len)));
    } else if (ad_len <= 255) {
        try buf.append(allocator, 0x58);
        try buf.append(allocator, @intCast(ad_len));
    } else {
        // 2-byte length: 0x59 <u16 BE>
        try buf.append(allocator, 0x59);
        try buf.append(allocator, @intCast(ad_len >> 8));
        try buf.append(allocator, @intCast(ad_len & 0xff));
    }
    try buf.appendSlice(allocator, auth_data);

    return buf;
}

/// Build a clientDataJSON string for registration.
fn buildClientDataJson(
    allocator: std.mem.Allocator,
    challenge_raw: []const u8,
    origin: []const u8,
) ![]u8 {
    const encoded_challenge = try client_data.b64urlNoPad(allocator, challenge_raw);
    defer allocator.free(encoded_challenge);
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"webauthn.create\",\"challenge\":\"{s}\",\"origin\":\"{s}\"}}",
        .{ encoded_challenge, origin },
    );
}

test "register: happy path — EC2/ES256 registration succeeds" {
    const alloc = std.testing.allocator;
    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20 };
    const cred_id = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11 };
    const aaguid = [_]u8{0} ** 16;

    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memset(&x, 0x55);
    @memset(&y, 0x66);

    // Build COSE key
    var cose_key_buf = try buildEc2CoseKey(alloc, x, y);
    defer cose_key_buf.deinit(alloc);

    // Build rpIdHash = SHA-256("example.test")
    var rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &rp_id_hash, .{});

    // Build authData with flags 0x45 = UP|UV|AT
    var auth_data_buf = try buildAuthData(alloc, rp_id_hash, 0x45, 0, aaguid, &cred_id, cose_key_buf.items);
    defer auth_data_buf.deinit(alloc);

    // Build attestationObject
    var att_obj_buf = try buildAttestationObject(alloc, auth_data_buf.items);
    defer att_obj_buf.deinit(alloc);

    // Build clientDataJSON
    const cdj = try buildClientDataJson(alloc, &challenge_raw, origin);
    defer alloc.free(cdj);

    const result = try verifyRegistration(alloc, rp_id, origin, &challenge_raw, cdj, att_obj_buf.items, true);

    try std.testing.expectEqualSlices(u8, &cred_id, result.credential_id);
    try std.testing.expectEqual(@as(i64, -7), result.alg);
    try std.testing.expectEqual(@as(u32, 0), result.sign_count);
    try std.testing.expectEqualSlices(u8, &aaguid, &result.aaguid);
    // cose_pubkey should match what we built
    try std.testing.expectEqualSlices(u8, cose_key_buf.items, result.cose_pubkey);
}

test "register: negative — wrong rp_id causes RpIdMismatch" {
    const alloc = std.testing.allocator;
    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0x42} ** 16;
    const cred_id = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const aaguid = [_]u8{0} ** 16;

    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memset(&x, 0x11);
    @memset(&y, 0x22);

    var cose_key_buf = try buildEc2CoseKey(alloc, x, y);
    defer cose_key_buf.deinit(alloc);

    // Use WRONG rp_id_hash (SHA-256 of "wrong.rp")
    var rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("wrong.rp", &rp_id_hash, .{});

    var auth_data_buf = try buildAuthData(alloc, rp_id_hash, 0x45, 0, aaguid, &cred_id, cose_key_buf.items);
    defer auth_data_buf.deinit(alloc);

    var att_obj_buf = try buildAttestationObject(alloc, auth_data_buf.items);
    defer att_obj_buf.deinit(alloc);

    const cdj = try buildClientDataJson(alloc, &challenge_raw, origin);
    defer alloc.free(cdj);

    try std.testing.expectError(
        error.RpIdMismatch,
        verifyRegistration(alloc, rp_id, origin, &challenge_raw, cdj, att_obj_buf.items, true),
    );
}

test "register: negative — UP not set causes UserNotPresent" {
    const alloc = std.testing.allocator;
    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0x43} ** 16;
    const cred_id = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const aaguid = [_]u8{0} ** 16;

    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memset(&x, 0x11);
    @memset(&y, 0x22);

    var cose_key_buf = try buildEc2CoseKey(alloc, x, y);
    defer cose_key_buf.deinit(alloc);

    var rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &rp_id_hash, .{});

    // flags = 0x44 = UV|AT (UP not set)
    var auth_data_buf = try buildAuthData(alloc, rp_id_hash, 0x44, 0, aaguid, &cred_id, cose_key_buf.items);
    defer auth_data_buf.deinit(alloc);

    var att_obj_buf = try buildAttestationObject(alloc, auth_data_buf.items);
    defer att_obj_buf.deinit(alloc);

    const cdj = try buildClientDataJson(alloc, &challenge_raw, origin);
    defer alloc.free(cdj);

    try std.testing.expectError(
        error.UserNotPresent,
        verifyRegistration(alloc, rp_id, origin, &challenge_raw, cdj, att_obj_buf.items, true),
    );
}

test "register: negative — fmt:packed rejected with UnsupportedAttestationFormat" {
    const alloc = std.testing.allocator;
    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0x44} ** 16;
    const cred_id = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const aaguid = [_]u8{0} ** 16;

    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memset(&x, 0x11);
    @memset(&y, 0x22);

    var cose_key_buf = try buildEc2CoseKey(alloc, x, y);
    defer cose_key_buf.deinit(alloc);

    var rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &rp_id_hash, .{});

    var auth_data_buf = try buildAuthData(alloc, rp_id_hash, 0x45, 0, aaguid, &cred_id, cose_key_buf.items);
    defer auth_data_buf.deinit(alloc);

    // Build attestationObject with fmt="packed" instead of "none"
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    // map(3)
    try buf.append(alloc, 0xa3);
    // "fmt": "packed"
    try buf.append(alloc, 0x63);
    try buf.appendSlice(alloc, "fmt");
    try buf.append(alloc, 0x66);
    try buf.appendSlice(alloc, "packed");
    // "attStmt": {}
    try buf.append(alloc, 0x67);
    try buf.appendSlice(alloc, "attStmt");
    try buf.append(alloc, 0xa0);
    // "authData": bstr
    const ad_len = auth_data_buf.items.len;
    try buf.append(alloc, 0x68);
    try buf.appendSlice(alloc, "authData");
    try buf.append(alloc, 0x59);
    try buf.append(alloc, @intCast(ad_len >> 8));
    try buf.append(alloc, @intCast(ad_len & 0xff));
    try buf.appendSlice(alloc, auth_data_buf.items);

    const cdj = try buildClientDataJson(alloc, &challenge_raw, origin);
    defer alloc.free(cdj);

    try std.testing.expectError(
        error.UnsupportedAttestationFormat,
        verifyRegistration(alloc, rp_id, origin, &challenge_raw, cdj, buf.items, true),
    );
}

test "register: negative — wrong challenge causes ChallengeMismatch" {
    const alloc = std.testing.allocator;
    const rp_id = "example.test";
    const origin = "https://example.test";
    const stored_challenge = [_]u8{0x11} ** 16;
    const wrong_challenge = [_]u8{0x22} ** 16;
    const cred_id = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const aaguid = [_]u8{0} ** 16;

    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memset(&x, 0x11);
    @memset(&y, 0x22);

    var cose_key_buf = try buildEc2CoseKey(alloc, x, y);
    defer cose_key_buf.deinit(alloc);

    var rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &rp_id_hash, .{});

    var auth_data_buf = try buildAuthData(alloc, rp_id_hash, 0x45, 0, aaguid, &cred_id, cose_key_buf.items);
    defer auth_data_buf.deinit(alloc);

    var att_obj_buf = try buildAttestationObject(alloc, auth_data_buf.items);
    defer att_obj_buf.deinit(alloc);

    // clientDataJSON contains wrong_challenge, but we verify against stored_challenge
    const cdj = try buildClientDataJson(alloc, &wrong_challenge, origin);
    defer alloc.free(cdj);

    try std.testing.expectError(
        error.ChallengeMismatch,
        verifyRegistration(alloc, rp_id, origin, &stored_challenge, cdj, att_obj_buf.items, true),
    );
}

test "register: negative — wrong origin causes OriginMismatch" {
    const alloc = std.testing.allocator;
    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0x55} ** 16;
    const cred_id = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const aaguid = [_]u8{0} ** 16;

    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memset(&x, 0x11);
    @memset(&y, 0x22);

    var cose_key_buf = try buildEc2CoseKey(alloc, x, y);
    defer cose_key_buf.deinit(alloc);

    var rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &rp_id_hash, .{});

    var auth_data_buf = try buildAuthData(alloc, rp_id_hash, 0x45, 0, aaguid, &cred_id, cose_key_buf.items);
    defer auth_data_buf.deinit(alloc);

    var att_obj_buf = try buildAttestationObject(alloc, auth_data_buf.items);
    defer att_obj_buf.deinit(alloc);

    // clientDataJSON has wrong origin
    const cdj = try buildClientDataJson(alloc, &challenge_raw, "https://evil.com");
    defer alloc.free(cdj);

    try std.testing.expectError(
        error.OriginMismatch,
        verifyRegistration(alloc, rp_id, origin, &challenge_raw, cdj, att_obj_buf.items, true),
    );
}

test "register: negative — wrong clientData type (webauthn.get) causes TypeMismatch" {
    const alloc = std.testing.allocator;
    const rp_id = "example.test";
    const origin = "https://example.test";
    const challenge_raw = [_]u8{0x66} ** 16;
    const cred_id = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const aaguid = [_]u8{0} ** 16;

    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memset(&x, 0x11);
    @memset(&y, 0x22);

    var cose_key_buf = try buildEc2CoseKey(alloc, x, y);
    defer cose_key_buf.deinit(alloc);

    var rp_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &rp_id_hash, .{});

    var auth_data_buf = try buildAuthData(alloc, rp_id_hash, 0x45, 0, aaguid, &cred_id, cose_key_buf.items);
    defer auth_data_buf.deinit(alloc);

    var att_obj_buf = try buildAttestationObject(alloc, auth_data_buf.items);
    defer att_obj_buf.deinit(alloc);

    // Use webauthn.get type instead of webauthn.create
    const encoded_challenge = try client_data.b64urlNoPad(alloc, &challenge_raw);
    defer alloc.free(encoded_challenge);
    const cdj = try std.fmt.allocPrint(
        alloc,
        "{{\"type\":\"webauthn.get\",\"challenge\":\"{s}\",\"origin\":\"{s}\"}}",
        .{ encoded_challenge, origin },
    );
    defer alloc.free(cdj);

    try std.testing.expectError(
        error.TypeMismatch,
        verifyRegistration(alloc, rp_id, origin, &challenge_raw, cdj, att_obj_buf.items, true),
    );
}
