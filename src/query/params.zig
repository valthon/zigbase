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
    const buf = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = if (c == '+') ' ' else c;
    return std.Uri.percentDecodeInPlace(buf);
}

test "parse decodes pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "filter=name%3D%22x%22&page=2&q=a+b");
    try std.testing.expectEqualStrings("name=\"x\"", p.get("filter").?);
    try std.testing.expectEqualStrings("2", p.get("page").?);
    try std.testing.expectEqualStrings("a b", p.get("q").?);
    try std.testing.expect(p.get("missing") == null);
}
