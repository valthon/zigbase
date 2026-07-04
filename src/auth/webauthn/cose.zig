// cose.zig — COSE_Key parser for WebAuthn credential public keys.
// Parses a COSE_Key CBOR map and returns a typed CoseKey union.
// Supported key types: EC2 (ES256, kty=2, alg=-7), OKP (Ed25519, kty=1, alg=-8),
// RSA (RS256, kty=3, alg=-257).
//
// IMPORTANT: label -1 means `crv` for EC2/OKP but `n` (modulus) for RSA.
// Branch on kty FIRST, then read type-specific labels.

const std = @import("std");
const cbor = @import("cbor.zig");

pub const Error = error{
    UnknownKeyType,
    UnknownAlgorithm,
    MissingField,
    InvalidFieldSize,
    /// The COSE_Key's curve does not match its algorithm (curve-confusion guard).
    CurveMismatch,
} || cbor.Error;

/// A decoded COSE_Key. For RSA, n/e are slices into the original buffer.
pub const CoseKey = union(enum) {
    ec2: struct { alg: i64, crv: i64, x: [32]u8, y: [32]u8 }, // ES256: kty=2, alg=-7, crv=1
    okp: struct { alg: i64, crv: i64, x: [32]u8 }, // Ed25519: kty=1, alg=-8, crv=6
    rsa: struct { alg: i64, n: []const u8, e: []const u8 }, // RS256: kty=3, alg=-257
};

/// Parse a COSE_Key from `bytes`. Returns the key and number of bytes consumed.
pub fn parseCoseKey(bytes: []const u8) Error!struct { key: CoseKey, consumed: usize } {
    var r = cbor.Reader.init(bytes);

    const map_len = try r.readMapLen();

    // We do two passes:
    // Pass 1: find kty (label 1) — needed to disambiguate label -1 (crv vs n).
    // Pass 2: collect type-specific fields.
    // We reset r.pos to the start of map pairs between passes.

    const map_start_pos = r.pos;

    // --- Pass 1: find kty ---
    var kty: ?i64 = null;
    var alg: ?i64 = null;
    {
        var i: u64 = 0;
        while (i < map_len) : (i += 1) {
            const label = try r.readInt();
            switch (label) {
                1 => {
                    kty = try r.readInt();
                },
                3 => {
                    alg = try r.readInt();
                },
                else => {
                    try r.skip();
                },
            }
        }
    }

    if (kty == null) return error.MissingField;

    // --- Pass 2: collect type-specific fields ---
    r.pos = map_start_pos;

    var crv: ?i64 = null;
    var x_bytes: ?[]const u8 = null;
    var y_bytes: ?[]const u8 = null;
    var n_bytes: ?[]const u8 = null;
    var e_bytes: ?[]const u8 = null;

    {
        var i: u64 = 0;
        while (i < map_len) : (i += 1) {
            const label = try r.readInt();
            switch (kty.?) {
                1 => { // OKP
                    switch (label) {
                        1, 3 => {
                            try r.skip();
                        },
                        -1 => {
                            crv = try r.readInt();
                        },
                        -2 => {
                            x_bytes = try r.readBytes();
                        },
                        else => {
                            try r.skip();
                        },
                    }
                },
                2 => { // EC2
                    switch (label) {
                        1, 3 => {
                            try r.skip();
                        },
                        -1 => {
                            crv = try r.readInt();
                        },
                        -2 => {
                            x_bytes = try r.readBytes();
                        },
                        -3 => {
                            y_bytes = try r.readBytes();
                        },
                        else => {
                            try r.skip();
                        },
                    }
                },
                3 => { // RSA
                    switch (label) {
                        1, 3 => {
                            try r.skip();
                        },
                        -1 => {
                            n_bytes = try r.readBytes();
                        },
                        -2 => {
                            e_bytes = try r.readBytes();
                        },
                        else => {
                            try r.skip();
                        },
                    }
                },
                else => return error.UnknownKeyType,
            }
        }
    }

    const consumed = r.pos;

    const key: CoseKey = switch (kty.?) {
        1 => blk: { // OKP / Ed25519
            if (alg == null) return error.MissingField;
            if (alg.? != -8) return error.UnknownAlgorithm;
            if (crv == null) return error.MissingField;
            // EdDSA (alg=-8) requires crv == Ed25519 (COSE crv id 6) — reject curve confusion.
            if (crv.? != 6) return error.CurveMismatch;
            if (x_bytes == null) return error.MissingField;
            if (x_bytes.?.len != 32) return error.InvalidFieldSize;
            var x: [32]u8 = undefined;
            @memcpy(&x, x_bytes.?);
            break :blk CoseKey{ .okp = .{ .alg = alg.?, .crv = crv.?, .x = x } };
        },
        2 => blk: { // EC2 / ES256
            if (alg == null) return error.MissingField;
            if (alg.? != -7) return error.UnknownAlgorithm;
            if (crv == null) return error.MissingField;
            // ES256 (alg=-7) requires crv == P-256 (COSE crv id 1) — reject curve confusion.
            if (crv.? != 1) return error.CurveMismatch;
            if (x_bytes == null) return error.MissingField;
            if (y_bytes == null) return error.MissingField;
            if (x_bytes.?.len != 32) return error.InvalidFieldSize;
            if (y_bytes.?.len != 32) return error.InvalidFieldSize;
            var x: [32]u8 = undefined;
            var y: [32]u8 = undefined;
            @memcpy(&x, x_bytes.?);
            @memcpy(&y, y_bytes.?);
            break :blk CoseKey{ .ec2 = .{ .alg = alg.?, .crv = crv.?, .x = x, .y = y } };
        },
        3 => blk: { // RSA / RS256
            if (alg == null) return error.MissingField;
            if (alg.? != -257) return error.UnknownAlgorithm;
            if (n_bytes == null) return error.MissingField;
            if (e_bytes == null) return error.MissingField;
            break :blk CoseKey{ .rsa = .{ .alg = alg.?, .n = n_bytes.?, .e = e_bytes.? } };
        },
        else => return error.UnknownKeyType,
    };

    return .{ .key = key, .consumed = consumed };
}

// ---------------------------------------------------------------------------
// Test helpers (module-scope to avoid Zig anonymous-struct type mismatch)
// ---------------------------------------------------------------------------

const TestPairValue = union(enum) {
    int: i64,
    bstr: []const u8,
};

const TestPair = struct {
    k: i64,
    v: TestPairValue,
};

fn buildCoseMap(allocator: std.mem.Allocator, pairs: []const TestPair) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const n = pairs.len;
    if (n <= 23) {
        try buf.append(allocator, 0xa0 | @as(u8, @intCast(n)));
    } else {
        try buf.append(allocator, 0xb8);
        try buf.append(allocator, @intCast(n));
    }
    for (pairs) |pair| {
        try appendCborInt(allocator, &buf, pair.k);
        switch (pair.v) {
            .int => |iv| try appendCborInt(allocator, &buf, iv),
            .bstr => |bs| {
                if (bs.len <= 23) {
                    try buf.append(allocator, 0x40 | @as(u8, @intCast(bs.len)));
                } else if (bs.len <= 255) {
                    try buf.append(allocator, 0x58);
                    try buf.append(allocator, @intCast(bs.len));
                } else {
                    try buf.append(allocator, 0x59);
                    try buf.append(allocator, @intCast(bs.len >> 8));
                    try buf.append(allocator, @intCast(bs.len & 0xff));
                }
                try buf.appendSlice(allocator, bs);
            },
        }
    }
    return buf;
}

fn appendCborInt(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: i64) !void {
    if (v >= 0) {
        const u: u64 = @intCast(v);
        if (u <= 23) {
            try buf.append(allocator, @intCast(u));
        } else if (u <= 255) {
            try buf.append(allocator, 0x18);
            try buf.append(allocator, @intCast(u));
        } else if (u <= 65535) {
            try buf.append(allocator, 0x19);
            try buf.append(allocator, @intCast(u >> 8));
            try buf.append(allocator, @intCast(u & 0xff));
        } else {
            try buf.append(allocator, 0x1a);
            try buf.append(allocator, @intCast((u >> 24) & 0xff));
            try buf.append(allocator, @intCast((u >> 16) & 0xff));
            try buf.append(allocator, @intCast((u >> 8) & 0xff));
            try buf.append(allocator, @intCast(u & 0xff));
        }
    } else {
        const n: u64 = @intCast(-(v + 1));
        if (n <= 23) {
            try buf.append(allocator, 0x20 | @as(u8, @intCast(n)));
        } else if (n <= 255) {
            try buf.append(allocator, 0x38);
            try buf.append(allocator, @intCast(n));
        } else if (n <= 65535) {
            try buf.append(allocator, 0x39);
            try buf.append(allocator, @intCast(n >> 8));
            try buf.append(allocator, @intCast(n & 0xff));
        } else {
            try buf.append(allocator, 0x3a);
            try buf.append(allocator, @intCast((n >> 24) & 0xff));
            try buf.append(allocator, @intCast((n >> 16) & 0xff));
            try buf.append(allocator, @intCast((n >> 8) & 0xff));
            try buf.append(allocator, @intCast(n & 0xff));
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "cose: parse EC2 COSE KAT (spec §6.5.1.1)" {
    // A5 01 02 03 26 20 01 21 58 20 <x:32> 22 58 20 <y:32>
    // map(5): 1->2(kty=EC2), 3->-7(alg=ES256), -1->1(crv=P-256), -2->x, -3->y
    var x_bytes: [32]u8 = undefined;
    var y_bytes: [32]u8 = undefined;
    @memset(&x_bytes, 0x01);
    @memset(&y_bytes, 0x02);

    var buf = try buildCoseMap(std.testing.allocator, &[_]TestPair{
        .{ .k = 1, .v = .{ .int = 2 } },
        .{ .k = 3, .v = .{ .int = -7 } },
        .{ .k = -1, .v = .{ .int = 1 } },
        .{ .k = -2, .v = .{ .bstr = &x_bytes } },
        .{ .k = -3, .v = .{ .bstr = &y_bytes } },
    });
    defer buf.deinit(std.testing.allocator);

    const result = try parseCoseKey(buf.items);
    try std.testing.expectEqual(buf.items.len, result.consumed);
    switch (result.key) {
        .ec2 => |k| {
            try std.testing.expectEqual(@as(i64, -7), k.alg);
            try std.testing.expectEqual(@as(i64, 1), k.crv);
            try std.testing.expectEqualSlices(u8, &x_bytes, &k.x);
            try std.testing.expectEqualSlices(u8, &y_bytes, &k.y);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "cose: parse OKP / Ed25519" {
    var x_bytes: [32]u8 = undefined;
    @memset(&x_bytes, 0xab);

    var buf = try buildCoseMap(std.testing.allocator, &[_]TestPair{
        .{ .k = 1, .v = .{ .int = 1 } },
        .{ .k = 3, .v = .{ .int = -8 } },
        .{ .k = -1, .v = .{ .int = 6 } },
        .{ .k = -2, .v = .{ .bstr = &x_bytes } },
    });
    defer buf.deinit(std.testing.allocator);

    const result = try parseCoseKey(buf.items);
    switch (result.key) {
        .okp => |k| {
            try std.testing.expectEqual(@as(i64, -8), k.alg);
            try std.testing.expectEqual(@as(i64, 6), k.crv);
            try std.testing.expectEqualSlices(u8, &x_bytes, &k.x);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "cose: parse RSA / RS256" {
    var n_bytes: [256]u8 = undefined;
    const e_bytes = [_]u8{ 0x01, 0x00, 0x01 };
    @memset(&n_bytes, 0xcd);

    var buf = try buildCoseMap(std.testing.allocator, &[_]TestPair{
        .{ .k = 1, .v = .{ .int = 3 } },
        .{ .k = 3, .v = .{ .int = -257 } },
        .{ .k = -1, .v = .{ .bstr = &n_bytes } },
        .{ .k = -2, .v = .{ .bstr = &e_bytes } },
    });
    defer buf.deinit(std.testing.allocator);

    const result = try parseCoseKey(buf.items);
    switch (result.key) {
        .rsa => |k| {
            try std.testing.expectEqual(@as(i64, -257), k.alg);
            try std.testing.expectEqual(@as(usize, 256), k.n.len);
            try std.testing.expectEqualSlices(u8, &e_bytes, k.e);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "cose: unknown kty returns error" {
    var buf = try buildCoseMap(std.testing.allocator, &[_]TestPair{
        .{ .k = 1, .v = .{ .int = 99 } },
        .{ .k = 3, .v = .{ .int = -7 } },
    });
    defer buf.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnknownKeyType, parseCoseKey(buf.items));
}

test "cose: x wrong size returns InvalidFieldSize" {
    var x_bytes: [16]u8 = undefined;
    var y_bytes: [32]u8 = undefined;
    @memset(&x_bytes, 0x01);
    @memset(&y_bytes, 0x02);

    var buf = try buildCoseMap(std.testing.allocator, &[_]TestPair{
        .{ .k = 1, .v = .{ .int = 2 } },
        .{ .k = 3, .v = .{ .int = -7 } },
        .{ .k = -1, .v = .{ .int = 1 } },
        .{ .k = -2, .v = .{ .bstr = &x_bytes } },
        .{ .k = -3, .v = .{ .bstr = &y_bytes } },
    });
    defer buf.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidFieldSize, parseCoseKey(buf.items));
}

test "cose: EC2/ES256 with wrong crv (Ed25519=6) returns CurveMismatch" {
    // alg=-7 (ES256) but crv=6 (Ed25519) — curve confusion must be rejected.
    var x_bytes: [32]u8 = undefined;
    var y_bytes: [32]u8 = undefined;
    @memset(&x_bytes, 0x01);
    @memset(&y_bytes, 0x02);

    var buf = try buildCoseMap(std.testing.allocator, &[_]TestPair{
        .{ .k = 1, .v = .{ .int = 2 } }, // kty=EC2
        .{ .k = 3, .v = .{ .int = -7 } }, // alg=ES256
        .{ .k = -1, .v = .{ .int = 6 } }, // crv=Ed25519 (WRONG for ES256)
        .{ .k = -2, .v = .{ .bstr = &x_bytes } },
        .{ .k = -3, .v = .{ .bstr = &y_bytes } },
    });
    defer buf.deinit(std.testing.allocator);

    try std.testing.expectError(error.CurveMismatch, parseCoseKey(buf.items));
}

test "cose: OKP/EdDSA with wrong crv (P-256=1) returns CurveMismatch" {
    // alg=-8 (EdDSA) but crv=1 (P-256) — curve confusion must be rejected.
    var x_bytes: [32]u8 = undefined;
    @memset(&x_bytes, 0xab);

    var buf = try buildCoseMap(std.testing.allocator, &[_]TestPair{
        .{ .k = 1, .v = .{ .int = 1 } }, // kty=OKP
        .{ .k = 3, .v = .{ .int = -8 } }, // alg=EdDSA
        .{ .k = -1, .v = .{ .int = 1 } }, // crv=P-256 (WRONG for EdDSA)
        .{ .k = -2, .v = .{ .bstr = &x_bytes } },
    });
    defer buf.deinit(std.testing.allocator);

    try std.testing.expectError(error.CurveMismatch, parseCoseKey(buf.items));
}

test "cose: RSA label -1 is n (not crv)" {
    // Confirm that for kty=3 (RSA), label -1 is read as bstr (modulus n), not int (crv).
    var n_bytes: [32]u8 = undefined;
    const e_bytes = [_]u8{ 0x01, 0x00, 0x01 };
    @memset(&n_bytes, 0xef);

    var buf = try buildCoseMap(std.testing.allocator, &[_]TestPair{
        .{ .k = 1, .v = .{ .int = 3 } },
        .{ .k = 3, .v = .{ .int = -257 } },
        .{ .k = -1, .v = .{ .bstr = &n_bytes } },
        .{ .k = -2, .v = .{ .bstr = &e_bytes } },
    });
    defer buf.deinit(std.testing.allocator);

    const result = try parseCoseKey(buf.items);
    switch (result.key) {
        .rsa => |k| {
            try std.testing.expectEqualSlices(u8, &n_bytes, k.n);
        },
        else => return error.TestUnexpectedResult,
    }
}
