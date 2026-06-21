// authdata.zig — WebAuthn authenticatorData byte parser.
//
// Byte layout per W3C WebAuthn §6.1:
//   [0..32]  rpIdHash  — SHA-256 of RP ID
//   [32]     flags     — bitfield (bit 0 = LSB)
//   [33..37] signCount — 32-bit unsigned big-endian
//   [37..]   attestedCredentialData — present iff AT (0x40) set
//
// Flags bits (mask by value, never compare whole byte):
//   UP = 0x01, UV = 0x04, BE = 0x08, BS = 0x10, AT = 0x40, ED = 0x80
//
// attestedCredentialData layout (relative to offset 37):
//   [0..16]     aaguid
//   [16..18]    credentialIdLength (16-bit BE)
//   [18..18+L]  credentialId
//   [18+L..]    COSE_Key (length determined by parseCoseKey consumed)
//
// All offsets are bounds-checked. Parses attacker-controlled bytes.

const std = @import("std");
const cose = @import("cose.zig");

pub const Error = error{
    Truncated,
    Malformed,
    CredentialIdTooLong, // > 1023 bytes (CTAP cap)
} || cose.Error;

pub const Flags = struct {
    up: bool, // User Present (0x01)
    uv: bool, // User Verified (0x04)
    at: bool, // Attested credential data included (0x40)
    ed: bool, // Extension data included (0x80)
    be: bool, // Backup Eligibility (0x08, L3)
    bs: bool, // Backup State (0x10, L3)
};

pub const CredentialData = struct {
    aaguid: [16]u8,
    credential_id: []const u8, // slice into the input bytes
    cose_key: []const u8, // slice into the input bytes (full COSE_Key encoding)
};

pub const AuthData = struct {
    rp_id_hash: [32]u8,
    flags: Flags,
    sign_count: u32, // 32-bit BE at offset 33
    cred: ?CredentialData, // present iff AT (0x40) set
    raw: []const u8, // the FULL authData bytes (caller needs for signature base)
};

/// Parse a WebAuthn authenticatorData byte array.
/// Requires bytes.len >= 37 (else error.Truncated).
/// All flag bits are masked by value (0x01/0x04/0x40/0x80/0x08/0x10).
/// When AT bit set, parses attestedCredentialData including COSE_Key delimiting.
pub fn parse(bytes: []const u8) Error!AuthData {
    if (bytes.len < 37) return error.Truncated;

    // rp_id_hash: bytes[0..32]
    var rp_id_hash: [32]u8 = undefined;
    @memcpy(&rp_id_hash, bytes[0..32]);

    // flags byte: bytes[32] — mask each bit individually
    const flags_byte = bytes[32];
    const flags = Flags{
        .up = (flags_byte & 0x01) != 0,
        .uv = (flags_byte & 0x04) != 0,
        .at = (flags_byte & 0x40) != 0,
        .ed = (flags_byte & 0x80) != 0,
        .be = (flags_byte & 0x08) != 0,
        .bs = (flags_byte & 0x10) != 0,
    };

    // sign_count: bytes[33..37] as 32-bit big-endian
    const sign_count = std.mem.readInt(u32, bytes[33..37], .big);

    // attestedCredentialData: only if AT flag is set
    const cred: ?CredentialData = if (flags.at) blk: {
        // Need at least: 37 + 16 (aaguid) + 2 (credIdLen) = 55 bytes
        if (bytes.len < 55) return error.Truncated;

        // aaguid: bytes[37..53]
        var aaguid: [16]u8 = undefined;
        @memcpy(&aaguid, bytes[37..53]);

        // credentialIdLength: bytes[53..55] as 16-bit big-endian
        const cred_id_len = std.mem.readInt(u16, bytes[53..55], .big);

        // Cap credIdLen per CTAP: must be <= 1023
        if (cred_id_len > 1023) return error.CredentialIdTooLong;

        // credential_id: bytes[55..55+credIdLen]
        const cred_id_end = 55 + @as(usize, cred_id_len);
        if (cred_id_end > bytes.len) return error.Truncated;
        const credential_id = bytes[55..cred_id_end];

        // COSE_Key starts at cred_id_end
        const cose_start = cred_id_end;
        if (cose_start >= bytes.len) return error.Truncated;

        const cose_slice = bytes[cose_start..];
        const cose_result = try cose.parseCoseKey(cose_slice);
        const consumed = cose_result.consumed;

        // cose_key slice: exactly the bytes the COSE parser consumed
        const cose_key = bytes[cose_start .. cose_start + consumed];

        break :blk CredentialData{
            .aaguid = aaguid,
            .credential_id = credential_id,
            .cose_key = cose_key,
        };
    } else null;

    return AuthData{
        .rp_id_hash = rp_id_hash,
        .flags = flags,
        .sign_count = sign_count,
        .cred = cred,
        .raw = bytes,
    };
}

// ---------------------------------------------------------------------------
// Tests (TDD — written before implementation, following WebAuthn §6.1)
// ---------------------------------------------------------------------------

// Helper: build a minimal EC2 COSE_Key bytes (spec §6.5.1.1 KAT bytes layout)
// map(5): 1->2, 3->-7, -1->1, -2->x(32B), -3->y(32B)
fn buildEc2CoseKey(allocator: std.mem.Allocator, x: [32]u8, y: [32]u8) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // map(5) = 0xA5
    try buf.append(allocator, 0xa5);
    // 1: 2  (kty = EC2)
    try buf.append(allocator, 0x01);
    try buf.append(allocator, 0x02);
    // 3: -7  (alg = ES256) => 0x26
    try buf.append(allocator, 0x03);
    try buf.append(allocator, 0x26);
    // -1: 1  (crv = P-256) => 0x20, 0x01
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

test "authdata: 37-byte assertion authData (UP|UV, no AT)" {
    // Layout: rpIdHash(32) ++ 0x05(UP|UV) ++ 0x00000001(signCount=1 BE)
    var auth_bytes: [37]u8 = undefined;
    @memset(auth_bytes[0..32], 0xAB); // arbitrary rp_id_hash
    auth_bytes[32] = 0x05; // UP(0x01) | UV(0x04)
    auth_bytes[33] = 0x00;
    auth_bytes[34] = 0x00;
    auth_bytes[35] = 0x00;
    auth_bytes[36] = 0x01; // sign_count = 1

    const result = try parse(&auth_bytes);

    try std.testing.expect(result.flags.up);
    try std.testing.expect(result.flags.uv);
    try std.testing.expect(!result.flags.at);
    try std.testing.expect(!result.flags.ed);
    try std.testing.expect(!result.flags.be);
    try std.testing.expect(!result.flags.bs);
    try std.testing.expectEqual(@as(u32, 1), result.sign_count);
    try std.testing.expect(result.cred == null);
    try std.testing.expectEqualSlices(u8, &auth_bytes, result.raw);
    var expected_hash: [32]u8 = undefined;
    @memset(&expected_hash, 0xAB);
    try std.testing.expectEqualSlices(u8, &expected_hash, &result.rp_id_hash);
}

test "authdata: flags 0x0D (UP|UV|BE) — BE bit does not break UP/UV detection" {
    // 0x0D = 0x01 (UP) | 0x04 (UV) | 0x08 (BE)
    var auth_bytes: [37]u8 = undefined;
    @memset(auth_bytes[0..32], 0x00);
    auth_bytes[32] = 0x0D;
    auth_bytes[33] = 0x00;
    auth_bytes[34] = 0x00;
    auth_bytes[35] = 0x00;
    auth_bytes[36] = 0x00;

    const result = try parse(&auth_bytes);

    try std.testing.expect(result.flags.up); // UP should be set
    try std.testing.expect(result.flags.uv); // UV should be set
    try std.testing.expect(result.flags.be); // BE should be set
    try std.testing.expect(!result.flags.at); // AT should NOT be set
    try std.testing.expect(!result.flags.bs);
    try std.testing.expect(!result.flags.ed);
}

test "authdata: truncated (<37 bytes) returns error.Truncated" {
    var short: [36]u8 = undefined;
    @memset(&short, 0x00);

    try std.testing.expectError(error.Truncated, parse(&short));
}

test "authdata: empty input returns error.Truncated" {
    try std.testing.expectError(error.Truncated, parse(&[_]u8{}));
}

test "authdata: attestation authData with AT set, parses attestedCredentialData" {
    // Layout: rpIdHash(32) ++ 0x45(UP|UV|AT) ++ signCount(4 BE) ++
    //         aaguid(16 zeros) ++ credIdLen(2 BE = 4) ++ credId(4 bytes) ++
    //         COSE_Key (EC2)
    const alloc = std.testing.allocator;

    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    @memset(&x, 0x11);
    @memset(&y, 0x22);

    var cose_key_buf = try buildEc2CoseKey(alloc, x, y);
    defer cose_key_buf.deinit(alloc);

    // Total: 32 + 1 + 4 + 16 + 2 + 4 + cose_key_len
    const cred_id = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const total = 37 + 16 + 2 + cred_id.len + cose_key_buf.items.len;

    var auth_bytes = try alloc.alloc(u8, total);
    defer alloc.free(auth_bytes);

    @memset(auth_bytes[0..32], 0xFF); // rp_id_hash
    auth_bytes[32] = 0x45; // UP(0x01) | UV(0x04) | AT(0x40)
    // sign_count = 0x00000002 = 2
    auth_bytes[33] = 0x00;
    auth_bytes[34] = 0x00;
    auth_bytes[35] = 0x00;
    auth_bytes[36] = 0x02;
    // aaguid: 16 zeros at offset 37
    @memset(auth_bytes[37..53], 0x00);
    // credIdLen = 4 (big-endian 0x0004) at offset 53
    auth_bytes[53] = 0x00;
    auth_bytes[54] = 0x04;
    // credId: 4 bytes at offset 55
    @memcpy(auth_bytes[55..59], &cred_id);
    // COSE_Key at offset 59
    @memcpy(auth_bytes[59..], cose_key_buf.items);

    const result = try parse(auth_bytes);

    try std.testing.expect(result.flags.up);
    try std.testing.expect(result.flags.uv);
    try std.testing.expect(result.flags.at);
    try std.testing.expect(!result.flags.ed);
    try std.testing.expectEqual(@as(u32, 2), result.sign_count);

    const cd = result.cred orelse return error.TestUnexpectedNull;

    // aaguid should be 16 zeros
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 16, &cd.aaguid);

    // credential_id should be our 4 bytes
    try std.testing.expectEqualSlices(u8, &cred_id, cd.credential_id);

    // cose_key slice should parse as EC2
    const parsed_cose = try cose.parseCoseKey(cd.cose_key);
    switch (parsed_cose.key) {
        .ec2 => |k| {
            try std.testing.expectEqual(@as(i64, -7), k.alg);
            try std.testing.expectEqualSlices(u8, &x, &k.x);
            try std.testing.expectEqualSlices(u8, &y, &k.y);
        },
        else => return error.TestUnexpectedResult,
    }

    // raw should point to full bytes
    try std.testing.expectEqualSlices(u8, auth_bytes, result.raw);
}

test "authdata: AT set but credIdLen runs past buffer returns error.Truncated" {
    // Build a minimal AT authData but with credIdLen that claims more bytes than exist.
    // rpIdHash(32) ++ 0x41(UP|AT) ++ signCount(4) ++ aaguid(16) ++ credIdLen(0x00FF=255)
    // but NO credential_id bytes follow.
    var auth_bytes: [55]u8 = undefined; // exactly up to credIdLen, no data after
    @memset(auth_bytes[0..32], 0x00);
    auth_bytes[32] = 0x41; // UP | AT
    auth_bytes[33] = 0x00;
    auth_bytes[34] = 0x00;
    auth_bytes[35] = 0x00;
    auth_bytes[36] = 0x00;
    @memset(auth_bytes[37..53], 0x00); // aaguid
    // credIdLen = 100 (0x0064) but only 0 bytes follow
    auth_bytes[53] = 0x00;
    auth_bytes[54] = 0x64; // = 100

    try std.testing.expectError(error.Truncated, parse(&auth_bytes));
}

test "authdata: AT set but buffer too short for aaguid returns error.Truncated" {
    // Only 37 bytes — AT set but no room for aaguid
    var auth_bytes: [37]u8 = undefined;
    @memset(auth_bytes[0..32], 0x00);
    auth_bytes[32] = 0x40; // AT set
    auth_bytes[33] = 0x00;
    auth_bytes[34] = 0x00;
    auth_bytes[35] = 0x00;
    auth_bytes[36] = 0x00;

    try std.testing.expectError(error.Truncated, parse(&auth_bytes));
}
