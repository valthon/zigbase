// client_data.zig — clientDataJSON parsing and verification for WebAuthn ceremonies.
//
// The RP-side responsibilities covered here (spec §7.1 steps 6–9, §7.2 steps 10–13):
//   - Parse clientDataJSON as UTF-8 JSON, extract type/challenge/origin string fields.
//   - Verify type is exactly the expected ceremony string ("webauthn.create"/"webauthn.get").
//   - Verify origin is an EXACT match (scheme+host+port) — NO prefix/substring matching.
//   - Verify challenge is the base64url-nopad encoding of the stored raw challenge bytes,
//     compared constant-time to C.challenge. Never base64url-DECODE the incoming value.
//
// Caller note: the RAW clientDataJSON bytes (before parsing) must be hashed with SHA-256
// by the caller to form the signature base. This module only does the field checks.

const std = @import("std");
const crypto = @import("../../crypto.zig");

pub const ClientData = struct {
    type: []const u8,
    challenge: []const u8,
    origin: []const u8,
};

pub const ParseError = error{
    InvalidJson,
    MissingType,
    MissingChallenge,
    MissingOrigin,
    NonStringField,
};

pub const VerifyError = error{
    TypeMismatch,
    OriginMismatch,
    ChallengeMismatch,
    OutOfMemory,
};

/// Parse clientDataJSON bytes into a ClientData struct.
/// The returned strings are allocated into `alloc` and must be freed by the caller.
/// Unknown fields (e.g. crossOrigin, tokenBinding, topOrigin) are silently ignored.
pub fn parseClientData(alloc: std.mem.Allocator, json_bytes: []const u8) (ParseError || std.mem.Allocator.Error)!ClientData {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{
        .ignore_unknown_fields = true,
        .max_value_len = 16 * 1024, // 16 KiB is more than enough for clientDataJSON
    }) catch return error.InvalidJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidJson,
    };

    // Extract required string fields. Any missing or non-string → fail closed.
    const type_val = root.get("type") orelse return error.MissingType;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return error.NonStringField,
    };

    const challenge_val = root.get("challenge") orelse return error.MissingChallenge;
    const challenge_str = switch (challenge_val) {
        .string => |s| s,
        else => return error.NonStringField,
    };

    const origin_val = root.get("origin") orelse return error.MissingOrigin;
    const origin_str = switch (origin_val) {
        .string => |s| s,
        else => return error.NonStringField,
    };

    // Dupe all strings into caller-owned memory before `parsed` is freed.
    return ClientData{
        .type = try alloc.dupe(u8, type_str),
        .challenge = try alloc.dupe(u8, challenge_str),
        .origin = try alloc.dupe(u8, origin_str),
    };
}

/// Encode `raw` bytes as base64url WITHOUT padding (RFC 4648 §5, no `=`).
/// Caller owns the returned slice.
pub fn b64urlNoPad(alloc: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const enc_len = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    const buf = try alloc.alloc(u8, enc_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(buf, raw);
    return buf;
}

/// Verify a parsed ClientData against expected ceremony parameters.
///
///   expected_type         — "webauthn.create" or "webauthn.get"
///   expected_origin       — exact RP origin string (e.g. "https://example.test")
///   stored_challenge_raw  — the raw challenge bytes the RP issued (NOT base64url)
///
/// The stored raw challenge is base64url-nopad-encoded and compared constant-time
/// to cd.challenge. Any mismatch → a distinct error (fail closed).
pub fn verifyClientData(
    alloc: std.mem.Allocator,
    cd: ClientData,
    expected_type: []const u8,
    expected_origin: []const u8,
    stored_challenge_raw: []const u8,
) (VerifyError || std.mem.Allocator.Error)!void {
    // 1. Type check — exact equality; prevents cross-ceremony reuse.
    if (!std.mem.eql(u8, cd.type, expected_type)) return error.TypeMismatch;

    // 2. Origin check — EXACT match only (scheme+host+port).
    //    startsWith/contains is explicitly forbidden (spec §7 pitfall).
    if (!std.mem.eql(u8, cd.origin, expected_origin)) return error.OriginMismatch;

    // 3. Challenge check — encode the stored raw bytes as base64url-nopad and
    //    compare the resulting string to cd.challenge constant-time. We do NOT
    //    decode cd.challenge to avoid any base64 decoder leniency issues.
    const expected_challenge = try b64urlNoPad(alloc, stored_challenge_raw);
    defer alloc.free(expected_challenge);

    // Constant-time compare via the shared slice helper (#20). A length mismatch short-circuits
    // and is not timing-sensitive here: the base64url challenge length is deterministic from the
    // stored raw size and carries no secret.
    if (!crypto.timingSafeEql(cd.challenge, expected_challenge)) return error.ChallengeMismatch;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseClientData: extracts type/challenge/origin from valid JSON" {
    const alloc = std.testing.allocator;
    const json =
        \\{"type":"webauthn.get","challenge":"abc123","origin":"https://x.test"}
    ;
    const cd = try parseClientData(alloc, json);
    defer {
        alloc.free(cd.type);
        alloc.free(cd.challenge);
        alloc.free(cd.origin);
    }
    try std.testing.expectEqualStrings("webauthn.get", cd.type);
    try std.testing.expectEqualStrings("abc123", cd.challenge);
    try std.testing.expectEqualStrings("https://x.test", cd.origin);
}

test "parseClientData: ignores extra fields (crossOrigin, tokenBinding, topOrigin)" {
    const alloc = std.testing.allocator;
    const json =
        \\{"type":"webauthn.get","challenge":"AAEC","origin":"https://x.test","crossOrigin":false,"tokenBinding":{"status":"not-supported"},"topOrigin":"https://parent.test"}
    ;
    const cd = try parseClientData(alloc, json);
    defer {
        alloc.free(cd.type);
        alloc.free(cd.challenge);
        alloc.free(cd.origin);
    }
    try std.testing.expectEqualStrings("webauthn.get", cd.type);
    try std.testing.expectEqualStrings("AAEC", cd.challenge);
    try std.testing.expectEqualStrings("https://x.test", cd.origin);
}

test "parseClientData: error on missing type" {
    const alloc = std.testing.allocator;
    const json =
        \\{"challenge":"abc","origin":"https://x.test"}
    ;
    try std.testing.expectError(error.MissingType, parseClientData(alloc, json));
}

test "parseClientData: error on missing challenge" {
    const alloc = std.testing.allocator;
    const json =
        \\{"type":"webauthn.get","origin":"https://x.test"}
    ;
    try std.testing.expectError(error.MissingChallenge, parseClientData(alloc, json));
}

test "parseClientData: error on missing origin" {
    const alloc = std.testing.allocator;
    const json =
        \\{"type":"webauthn.get","challenge":"abc"}
    ;
    try std.testing.expectError(error.MissingOrigin, parseClientData(alloc, json));
}

test "parseClientData: error on invalid JSON" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidJson, parseClientData(alloc, "not json"));
}

test "b64urlNoPad: no padding characters" {
    const alloc = std.testing.allocator;

    // 1-byte input → 2 output chars, no padding
    {
        const raw = [_]u8{0xFF};
        const enc = try b64urlNoPad(alloc, &raw);
        defer alloc.free(enc);
        try std.testing.expectEqual(@as(usize, 2), enc.len);
        try std.testing.expect(std.mem.indexOf(u8, enc, "=") == null);
    }

    // 2-byte input → 3 output chars, no padding
    {
        const raw = [_]u8{ 0x00, 0x01 };
        const enc = try b64urlNoPad(alloc, &raw);
        defer alloc.free(enc);
        try std.testing.expectEqual(@as(usize, 3), enc.len);
        try std.testing.expect(std.mem.indexOf(u8, enc, "=") == null);
    }

    // 3-byte input → 4 output chars (full block, no padding needed regardless)
    {
        const raw = [_]u8{ 0x00, 0x01, 0x02 };
        const enc = try b64urlNoPad(alloc, &raw);
        defer alloc.free(enc);
        try std.testing.expectEqual(@as(usize, 4), enc.len);
        try std.testing.expect(std.mem.indexOf(u8, enc, "=") == null);
    }

    // Known vector: 0xFB 0xFF 0xFE → base64url "----" with standard, but nopad variant
    // Actually test a known ASCII vector: "Man" → "TWFu" (standard base64)
    // but url_safe replaces + with - and / with _; "TWFu" has none of those.
    {
        const raw = "Man";
        const enc = try b64urlNoPad(alloc, raw);
        defer alloc.free(enc);
        try std.testing.expectEqualStrings("TWFu", enc);
    }
}

test "b64urlNoPad: uses url-safe alphabet (- and _ instead of + and /)" {
    const alloc = std.testing.allocator;
    // 0xFB encodes to the last few chars that exercise + and / in standard b64.
    // 0xFB 0xFF = 11111011 11111111 → groups: 111110 111111 1111xx
    // In standard b64: '+' '/' ... In url-safe: '-' '_' ...
    const raw = [_]u8{ 0xFB, 0xFF };
    const enc = try b64urlNoPad(alloc, &raw);
    defer alloc.free(enc);
    try std.testing.expect(std.mem.indexOf(u8, enc, "+") == null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "/") == null);
}

test "verifyClientData: passes on matching type/origin/challenge" {
    const alloc = std.testing.allocator;

    const stored_raw = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03 };
    const encoded_challenge = try b64urlNoPad(alloc, &stored_raw);
    defer alloc.free(encoded_challenge);

    const cd = ClientData{
        .type = "webauthn.get",
        .challenge = encoded_challenge,
        .origin = "https://x.test",
    };

    try verifyClientData(alloc, cd, "webauthn.get", "https://x.test", &stored_raw);
}

test "verifyClientData: fails on wrong type" {
    const alloc = std.testing.allocator;

    const stored_raw = [_]u8{0xAA} ** 8;
    const encoded_challenge = try b64urlNoPad(alloc, &stored_raw);
    defer alloc.free(encoded_challenge);

    const cd = ClientData{
        .type = "webauthn.create", // wrong: expected "webauthn.get"
        .challenge = encoded_challenge,
        .origin = "https://x.test",
    };

    try std.testing.expectError(
        error.TypeMismatch,
        verifyClientData(alloc, cd, "webauthn.get", "https://x.test", &stored_raw),
    );
}

test "verifyClientData: fails on wrong origin (exact match required)" {
    const alloc = std.testing.allocator;

    const stored_raw = [_]u8{0xBB} ** 8;
    const encoded_challenge = try b64urlNoPad(alloc, &stored_raw);
    defer alloc.free(encoded_challenge);

    // Prefix-style near-miss: attacker provides superdomain
    {
        const cd = ClientData{
            .type = "webauthn.get",
            .challenge = encoded_challenge,
            .origin = "https://x.test.evil.com",
        };
        try std.testing.expectError(
            error.OriginMismatch,
            verifyClientData(alloc, cd, "webauthn.get", "https://x.test", &stored_raw),
        );
    }

    // Different port → must also be rejected
    {
        const cd = ClientData{
            .type = "webauthn.get",
            .challenge = encoded_challenge,
            .origin = "https://x.test:8443",
        };
        try std.testing.expectError(
            error.OriginMismatch,
            verifyClientData(alloc, cd, "webauthn.get", "https://x.test", &stored_raw),
        );
    }

    // Subdomain prefix: "https://sub.x.test" should not match "https://x.test"
    {
        const cd = ClientData{
            .type = "webauthn.get",
            .challenge = encoded_challenge,
            .origin = "https://sub.x.test",
        };
        try std.testing.expectError(
            error.OriginMismatch,
            verifyClientData(alloc, cd, "webauthn.get", "https://x.test", &stored_raw),
        );
    }
}

test "verifyClientData: fails on wrong challenge (different stored_raw)" {
    const alloc = std.testing.allocator;

    const stored_raw = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const other_raw = [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 };

    // cd.challenge is the encoding of other_raw, but we verify against stored_raw
    const wrong_challenge = try b64urlNoPad(alloc, &other_raw);
    defer alloc.free(wrong_challenge);

    const cd = ClientData{
        .type = "webauthn.get",
        .challenge = wrong_challenge,
        .origin = "https://x.test",
    };

    try std.testing.expectError(
        error.ChallengeMismatch,
        verifyClientData(alloc, cd, "webauthn.get", "https://x.test", &stored_raw),
    );
}

test "verifyClientData: challenge comparison is constant-time (no early exit)" {
    // This test exercises the constant-time property by feeding strings that share
    // a common prefix. If the compare had an early exit, we could not distinguish
    // from outside Zig's test runner, but the challenge check routes through
    // crypto.timingSafeEql (XOR-accumulator, no early exit) — we test behavior.
    const alloc = std.testing.allocator;

    // Two challenges that differ only in the last byte — both must be rejected.
    const stored_raw_a = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const stored_raw_b = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF };

    const challenge_b = try b64urlNoPad(alloc, &stored_raw_b);
    defer alloc.free(challenge_b);

    const cd = ClientData{
        .type = "webauthn.get",
        .challenge = challenge_b,
        .origin = "https://x.test",
    };

    // stored_raw_a != stored_raw_b → ChallengeMismatch
    try std.testing.expectError(
        error.ChallengeMismatch,
        verifyClientData(alloc, cd, "webauthn.get", "https://x.test", &stored_raw_a),
    );
}

test "parseClientData + verifyClientData: full round-trip with b64url challenge" {
    const alloc = std.testing.allocator;

    // Simulate a 32-byte random challenge (the recommended size from research §6).
    const stored_raw = [_]u8{
        0x52, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67,
        0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67,
        0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67,
        0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67,
    };
    const encoded = try b64urlNoPad(alloc, &stored_raw);
    defer alloc.free(encoded);

    // Build a realistic clientDataJSON as the browser would send it.
    const json = try std.fmt.allocPrint(
        alloc,
        "{{\"type\":\"webauthn.create\",\"challenge\":\"{s}\",\"origin\":\"https://example.test\",\"crossOrigin\":false}}",
        .{encoded},
    );
    defer alloc.free(json);

    const cd = try parseClientData(alloc, json);
    defer {
        alloc.free(cd.type);
        alloc.free(cd.challenge);
        alloc.free(cd.origin);
    }

    try verifyClientData(alloc, cd, "webauthn.create", "https://example.test", &stored_raw);
}
