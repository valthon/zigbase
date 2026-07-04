// cbor.zig — definite-length-only CBOR decoder, zero-allocation, bounds-checked.
// Supports major types: 0 (uint), 1 (nint), 2 (bstr), 3 (tstr), 4 (array, skip-only),
// 5 (map), 6 (tag, skip). Rejects major type 7 (float/simple) and all indefinite-length
// items (0x5F/0x7F/0x9F/0xBF/0xFF).
//
// All integer argument forms are supported: inline (0–23), 1-byte (0x18), 2-byte (0x19),
// 4-byte (0x1A), 8-byte (0x1B). Slices returned point into the input; no allocation.

const std = @import("std");

pub const Error = error{
    Truncated, // ran off end of input
    Malformed, // invalid encoding (indefinite-length, major-7, etc.)
    Overflow, // integer value doesn't fit in target type
    UnsupportedType, // major type 7 (float/simple)
};

/// A decoded CBOR value. Slices alias into the source buffer.
pub const Value = union(enum) {
    uint: u64,
    nint: i64, // value is -1 - n  where n is the encoded uint
    bytes: []const u8,
    text: []const u8,
    map_len: u64, // length of a map (number of key/value pairs)
    array_len: u64, // length of an array (number of items)
};

/// Maximum nesting depth (tags + map/array levels combined). 16 is far more
/// than any real COSE_Key or attestationObject ever nests; a crafted input
/// with more levels returns error.Malformed instead of overflowing the stack.
const max_depth: u16 = 16;

/// Cursor over a CBOR byte slice. All mutating methods advance `pos`.
pub const Reader = struct {
    data: []const u8,
    pos: usize,
    depth: u16 = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data, .pos = 0 };
    }

    /// Remaining bytes.
    pub fn remaining(self: Reader) usize {
        return self.data.len - self.pos;
    }

    /// Read a single byte; advance pos.
    fn readByte(self: *Reader) Error!u8 {
        if (self.pos >= self.data.len) return error.Truncated;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    /// Read `n` bytes into a slice (alias into data); advance pos.
    fn readSlice(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.data.len - self.pos) return error.Truncated;
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    /// Decode the CBOR argument (additional-info field) from the initial byte.
    /// Returns (major_type, argument). Does NOT consume the data payload for
    /// byte/text strings or map/array bodies — that is the caller's job.
    fn readHead(self: *Reader) Error!struct { major: u3, arg: u64 } {
        const ib = try self.readByte();
        const major: u3 = @intCast(ib >> 5);
        const info: u5 = @intCast(ib & 0x1f);

        // Reject indefinite-length break code (0xFF = major 7, info 31)
        if (ib == 0xff) return error.Malformed;

        const arg: u64 = switch (info) {
            0...23 => @as(u64, info),
            24 => blk: { // 1-byte follow-on
                const v = try self.readByte();
                break :blk @as(u64, v);
            },
            25 => blk: { // 2-byte follow-on
                const hi = try self.readByte();
                const lo = try self.readByte();
                break :blk (@as(u64, hi) << 8) | @as(u64, lo);
            },
            26 => blk: { // 4-byte follow-on
                const b0 = try self.readByte();
                const b1 = try self.readByte();
                const b2 = try self.readByte();
                const b3 = try self.readByte();
                break :blk (@as(u64, b0) << 24) | (@as(u64, b1) << 16) | (@as(u64, b2) << 8) | @as(u64, b3);
            },
            27 => blk: { // 8-byte follow-on
                const bytes = try self.readSlice(8);
                break :blk std.mem.readInt(u64, bytes[0..8], .big);
            },
            28, 29, 30 => return error.Malformed, // reserved
            31 => return error.Malformed, // indefinite-length (0x5F/0x7F/0x9F/0xBF/0xFF handled above for break)
        };
        return .{ .major = major, .arg = arg };
    }

    /// Decode the next CBOR item as a Value (for map/array only returns the length).
    /// Byte and text string slices alias into self.data.
    pub fn next(self: *Reader) Error!Value {
        const head = try self.readHead();
        // Note: readHead() already rejects indefinite-length (info=31) and 0xFF.

        return switch (head.major) {
            0 => Value{ .uint = head.arg },
            1 => blk: {
                // nint: value = -1 - arg; arg fits in u63 or overflows i64
                if (head.arg > std.math.maxInt(i64)) return error.Overflow;
                break :blk Value{ .nint = -1 - @as(i64, @intCast(head.arg)) };
            },
            2 => blk: { // byte string
                if (head.arg > self.data.len - self.pos) return error.Truncated;
                const s = try self.readSlice(@intCast(head.arg));
                break :blk Value{ .bytes = s };
            },
            3 => blk: { // text string
                if (head.arg > self.data.len - self.pos) return error.Truncated;
                const s = try self.readSlice(@intCast(head.arg));
                break :blk Value{ .text = s };
            },
            4 => Value{ .array_len = head.arg }, // caller must consume items
            5 => Value{ .map_len = head.arg }, // caller must consume key/value pairs
            6 => blk: { // tag — tag number already consumed as `arg`; return the tagged item
                self.depth += 1;
                defer self.depth -= 1;
                if (self.depth > max_depth) return error.Malformed;
                break :blk try self.next();
            },
            7 => return error.UnsupportedType, // float/simple — reject
        };
    }

    /// Read a uint from the next CBOR item.
    pub fn readUint(self: *Reader) Error!u64 {
        return switch (try self.next()) {
            .uint => |v| v,
            else => error.Malformed,
        };
    }

    /// Read a negative int (or uint if it fits) as i64.
    pub fn readInt(self: *Reader) Error!i64 {
        return switch (try self.next()) {
            .uint => |v| blk: {
                if (v > std.math.maxInt(i64)) return error.Overflow;
                break :blk @as(i64, @intCast(v));
            },
            .nint => |v| v,
            else => error.Malformed,
        };
    }

    /// Read a byte string. Slice aliases into self.data.
    pub fn readBytes(self: *Reader) Error![]const u8 {
        return switch (try self.next()) {
            .bytes => |v| v,
            else => error.Malformed,
        };
    }

    /// Read a text string. Slice aliases into self.data.
    pub fn readText(self: *Reader) Error![]const u8 {
        return switch (try self.next()) {
            .text => |v| v,
            else => error.Malformed,
        };
    }

    /// Read a map header and return the number of key/value pairs.
    pub fn readMapLen(self: *Reader) Error!u64 {
        return switch (try self.next()) {
            .map_len => |v| v,
            else => error.Malformed,
        };
    }

    /// Skip the next CBOR item (recursively skips nested maps/arrays/tags).
    pub fn skip(self: *Reader) Error!void {
        const v = try self.next();
        switch (v) {
            .map_len => |n| {
                self.depth += 1;
                defer self.depth -= 1;
                if (self.depth > max_depth) return error.Malformed;
                var i: u64 = 0;
                while (i < n) : (i += 1) {
                    try self.skip(); // key
                    try self.skip(); // value
                }
            },
            .array_len => |n| {
                self.depth += 1;
                defer self.depth -= 1;
                if (self.depth > max_depth) return error.Malformed;
                var i: u64 = 0;
                while (i < n) : (i += 1) {
                    try self.skip();
                }
            },
            else => {}, // atomic values already consumed by next()
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "cbor: decode spec §6.5.1.1 EC2 COSE KAT" {
    // A5 01 02 03 26 20 01 21 58 20 <x:32> 22 58 20 <y:32>
    // map(5): 1->2, 3->-7, -1->1, -2->x(32B), -3->y(32B)
    var x_bytes: [32]u8 = undefined;
    var y_bytes: [32]u8 = undefined;
    @memset(&x_bytes, 0x01);
    @memset(&y_bytes, 0x02);

    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // map(5)
    try buf.append(alloc, 0xa5);
    // 1: 2  (kty = EC2)
    try buf.append(alloc, 0x01);
    try buf.append(alloc, 0x02);
    // 3: -7  (alg = ES256)
    try buf.append(alloc, 0x03);
    try buf.append(alloc, 0x26);
    // -1: 1  (crv = P-256)
    try buf.append(alloc, 0x20);
    try buf.append(alloc, 0x01);
    // -2: bstr(32, x)
    try buf.append(alloc, 0x21);
    try buf.append(alloc, 0x58);
    try buf.append(alloc, 0x20);
    try buf.appendSlice(alloc, &x_bytes);
    // -3: bstr(32, y)
    try buf.append(alloc, 0x22);
    try buf.append(alloc, 0x58);
    try buf.append(alloc, 0x20);
    try buf.appendSlice(alloc, &y_bytes);

    var r = Reader.init(buf.items);

    const map_len = try r.readMapLen();
    try std.testing.expectEqual(@as(u64, 5), map_len);

    // 1: 2
    const k1 = try r.readInt();
    const v1 = try r.readInt();
    try std.testing.expectEqual(@as(i64, 1), k1);
    try std.testing.expectEqual(@as(i64, 2), v1);

    // 3: -7
    const k2 = try r.readInt();
    const v2 = try r.readInt();
    try std.testing.expectEqual(@as(i64, 3), k2);
    try std.testing.expectEqual(@as(i64, -7), v2);

    // -1: 1
    const k3 = try r.readInt();
    const v3 = try r.readInt();
    try std.testing.expectEqual(@as(i64, -1), k3);
    try std.testing.expectEqual(@as(i64, 1), v3);

    // -2: bstr(32)
    const k4 = try r.readInt();
    const v4 = try r.readBytes();
    try std.testing.expectEqual(@as(i64, -2), k4);
    try std.testing.expectEqual(@as(usize, 32), v4.len);
    try std.testing.expectEqualSlices(u8, &x_bytes, v4);

    // -3: bstr(32)
    const k5 = try r.readInt();
    const v5 = try r.readBytes();
    try std.testing.expectEqual(@as(i64, -3), k5);
    try std.testing.expectEqual(@as(usize, 32), v5.len);
    try std.testing.expectEqualSlices(u8, &y_bytes, v5);
}

test "cbor: negative int decoding" {
    // 0x26 = major 1, info 6 => nint(-7)
    {
        const data = [_]u8{0x26};
        var r = Reader.init(&data);
        const v = try r.readInt();
        try std.testing.expectEqual(@as(i64, -7), v);
    }
    // 0x39 0x01 0x00 = major 1, info 25 (2-byte), value 256 => nint(-257) = RS256 alg
    {
        const data = [_]u8{ 0x39, 0x01, 0x00 };
        var r = Reader.init(&data);
        const v = try r.readInt();
        try std.testing.expectEqual(@as(i64, -257), v);
    }
    // nint(-1): 0x20
    {
        const data = [_]u8{0x20};
        var r = Reader.init(&data);
        const v = try r.readInt();
        try std.testing.expectEqual(@as(i64, -1), v);
    }
    // nint(-8): 0x27
    {
        const data = [_]u8{0x27};
        var r = Reader.init(&data);
        const v = try r.readInt();
        try std.testing.expectEqual(@as(i64, -8), v);
    }
}

test "cbor: indefinite-length rejection" {
    // 0x5F = indefinite-length byte string
    {
        const data = [_]u8{0x5f};
        var r = Reader.init(&data);
        try std.testing.expectError(error.Malformed, r.next());
    }
    // 0x7F = indefinite-length text string
    {
        const data = [_]u8{0x7f};
        var r = Reader.init(&data);
        try std.testing.expectError(error.Malformed, r.next());
    }
    // 0x9F = indefinite-length array
    {
        const data = [_]u8{0x9f};
        var r = Reader.init(&data);
        try std.testing.expectError(error.Malformed, r.next());
    }
    // 0xBF = indefinite-length map
    {
        const data = [_]u8{0xbf};
        var r = Reader.init(&data);
        try std.testing.expectError(error.Malformed, r.next());
    }
    // 0xFF = break code
    {
        const data = [_]u8{0xff};
        var r = Reader.init(&data);
        try std.testing.expectError(error.Malformed, r.next());
    }
}

test "cbor: truncated map returns Truncated" {
    // map(5) but only 2 bytes of actual data follow
    const data = [_]u8{ 0xa5, 0x01, 0x02 };
    var r = Reader.init(&data);
    const map_len = try r.readMapLen();
    try std.testing.expectEqual(@as(u64, 5), map_len);
    _ = try r.readInt(); // key 1 ok
    _ = try r.readInt(); // value 2 ok
    // next pair should be truncated
    try std.testing.expectError(error.Truncated, r.readInt());
}

test "cbor: truncated byte string" {
    // bstr(32) but only 5 bytes present
    const data = [_]u8{ 0x58, 0x20, 0x01, 0x02, 0x03, 0x04, 0x05 };
    var r = Reader.init(&data);
    try std.testing.expectError(error.Truncated, r.readBytes());
}

test "cbor: major type 7 rejected" {
    // 0xF4 = false (simple value 20, major 7)
    const data = [_]u8{0xf4};
    var r = Reader.init(&data);
    try std.testing.expectError(error.UnsupportedType, r.next());
}

test "cbor: uint variants" {
    // inline 0..23
    {
        const data = [_]u8{0x17}; // 23
        var r = Reader.init(&data);
        try std.testing.expectEqual(@as(u64, 23), try r.readUint());
    }
    // 1-byte
    {
        const data = [_]u8{ 0x18, 0xff };
        var r = Reader.init(&data);
        try std.testing.expectEqual(@as(u64, 255), try r.readUint());
    }
    // 2-byte
    {
        const data = [_]u8{ 0x19, 0x01, 0x00 };
        var r = Reader.init(&data);
        try std.testing.expectEqual(@as(u64, 256), try r.readUint());
    }
    // 4-byte
    {
        const data = [_]u8{ 0x1a, 0x00, 0x01, 0x00, 0x00 };
        var r = Reader.init(&data);
        try std.testing.expectEqual(@as(u64, 65536), try r.readUint());
    }
}

test "cbor: skip works over nested map" {
    // map(1) { 1: map(1) { 2: 3 } }
    const data = [_]u8{ 0xa1, 0x01, 0xa1, 0x02, 0x03 };
    var r = Reader.init(&data);
    try r.skip();
    try std.testing.expectEqual(data.len, r.pos);
}

test "cbor: tag (major 6) returns tagged item" {
    // tag(1, uint 42) = 0xC1 0x18 0x2A
    // major=6, info=1 (tag number 1), then uint(42)
    const data = [_]u8{ 0xc1, 0x18, 0x2a };
    var r = Reader.init(&data);
    const v = try r.next();
    try std.testing.expectEqual(Value{ .uint = 42 }, v);
    try std.testing.expectEqual(data.len, r.pos);
}

test "cbor: deeply nested tags (max_depth+5) rejected as Malformed" {
    // Build max_depth + 5 = 21 nested tag bytes (0xC1 each), then a uint leaf 0x00.
    // Each 0xC1 is major=6, info=1 (tag number 1), one byte each.
    const depth_over = max_depth + 5; // 21
    var buf: [depth_over + 1]u8 = undefined;
    @memset(buf[0..depth_over], 0xc1); // tag(1, ...) x 21
    buf[depth_over] = 0x00; // uint(0) leaf
    var r = Reader.init(&buf);
    try std.testing.expectError(error.Malformed, r.next());
}

test "cbor: legitimately nested structure within depth limit decodes fine" {
    // map(1) { bstr(1) "k": map(1) { bstr(1) "v": bstr(2) "hi" } }
    // Encoded:
    //   A1              map(1)
    //     41 6B         bstr(1) "k"
    //     A1            map(1)
    //       41 76       bstr(1) "v"
    //       42 68 69    bstr(2) "hi"
    const data = [_]u8{
        0xa1,
        0x41,
        'k',
        0xa1,
        0x41,
        'v',
        0x42,
        'h',
        'i',
    };
    var r = Reader.init(&data);
    // outer map
    const outer_len = try r.readMapLen();
    try std.testing.expectEqual(@as(u64, 1), outer_len);
    // key "k"
    const key1 = try r.readBytes();
    try std.testing.expectEqualSlices(u8, "k", key1);
    // inner map
    const inner_len = try r.readMapLen();
    try std.testing.expectEqual(@as(u64, 1), inner_len);
    // key "v"
    const key2 = try r.readBytes();
    try std.testing.expectEqualSlices(u8, "v", key2);
    // value "hi"
    const val = try r.readBytes();
    try std.testing.expectEqualSlices(u8, "hi", val);
    try std.testing.expectEqual(data.len, r.pos);
}
