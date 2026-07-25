const std = @import("std");

pub const Params = struct {
    pairs: []const Pair,
    pub const Pair = struct { key: []const u8, value: []const u8 };

    pub fn get(self: Params, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }
};

/// Parse a raw URL query string ("a=1&b=hello%20world") into decoded key/value pairs.
/// '+' is treated as space; '%XX' is percent-decoded. Values are owned by `alloc`.
///
/// OWNED ON PURPOSE — do not "deduplicate" into facil.io: fio's http_parse_query
/// type-guesses values through fiobj (`filter=123` becomes an int — the same corruption
/// class that forced the multipart parser off fio, see server.zig's multipart note /
/// commit 205859e), and zap's getParamSlice returns values NON-decoded. The filter/sort/
/// expand grammar needs exact decoded strings, so ZigBase splits the ~20 lines itself
/// and lets std.Uri do the decoding.
pub fn parse(alloc: std.mem.Allocator, query: []const u8) !Params {
    var list: std.ArrayList(Params.Pair) = .empty;
    errdefer list.deinit(alloc);
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, seg, '=');
        const raw_key = if (eq) |i| seg[0..i] else seg;
        const raw_val = if (eq) |i| seg[i + 1 ..] else "";
        try list.append(alloc, .{ .key = try decode(alloc, raw_key), .value = try decode(alloc, raw_val) });
    }
    return .{ .pairs = try list.toOwnedSlice(alloc) };
}

fn decode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    // `percentDecodeInPlace` may shrink the buffer (each "%XX" collapses to one byte), so
    // its return is a sub-slice of `buf` shorter than the allocation — freeing THAT slice
    // at its reported (decoded) length would be an invalid free under any allocator that
    // checks the original allocation size (as opposed to an arena, which no-ops on free
    // and so never surfaces the mismatch). Decode into scratch, then dupe the decoded
    // result to a right-sized, independently-freeable buffer.
    const scratch = try alloc.alloc(u8, s.len);
    defer alloc.free(scratch);
    for (s, 0..) |c, i| scratch[i] = if (c == '+') ' ' else c;
    const decoded = std.Uri.percentDecodeInPlace(scratch);
    return alloc.dupe(u8, decoded);
}

test "parse decodes pairs" {
    const a = std.testing.allocator;
    const p = try parse(a, "filter=name%3D%22x%22&page=2&q=a+b");
    defer {
        for (p.pairs) |pair| {
            a.free(pair.key);
            a.free(pair.value);
        }
        a.free(p.pairs);
    }
    try std.testing.expectEqualStrings("name=\"x\"", p.get("filter").?);
    try std.testing.expectEqualStrings("2", p.get("page").?);
    try std.testing.expectEqualStrings("a b", p.get("q").?);
    try std.testing.expect(p.get("missing") == null);
}
