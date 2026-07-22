const std = @import("std");
const id = @import("../id.zig");

fn isSafe(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-';
}

/// The basename with unsafe characters replaced by `_`. Drops any path before the last `/` or `\`,
/// strips a leading `.` (no hidden files), and can never contain a path separator or `..`.
/// Empty / "." / ".." -> "file".
pub fn sanitizeBase(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var base = name;
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |i| base = base[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, base, '\\')) |i| base = base[i + 1 ..];
    var start: usize = 0;
    while (start < base.len and base[start] == '.') start += 1;
    base = base[start..];
    if (base.len == 0) return alloc.dupe(u8, "file");

    var out: std.ArrayList(u8) = .empty;
    // Always freed (not just on error): every return below is a fresh `alloc.dupe` of
    // (a trim of) `out.items`, never `out`'s own backing buffer, so it's always scratch.
    defer out.deinit(alloc);
    // `pending_us` is a run of unsafe chars collapsed to a single `_`, emitted
    // lazily so it can be dropped when it would sit right next to a `.`.
    var pending_us = false;
    for (base) |ch| {
        if (isSafe(ch)) {
            if (pending_us and ch != '.') try out.append(alloc, '_');
            pending_us = false;
            try out.append(alloc, ch);
        } else {
            pending_us = true;
        }
    }
    if (pending_us) try out.append(alloc, '_');
    const s = std.mem.trim(u8, out.items, "_");
    if (s.len == 0) return alloc.dupe(u8, "file");
    return alloc.dupe(u8, s);
}

/// "<stem>_<10 base36>.<ext>" where stem/ext come from the sanitized name (ext lowercased, <=16).
pub fn storedName(io: std.Io, alloc: std.mem.Allocator, original: []const u8) ![]const u8 {
    const clean = try sanitizeBase(alloc, original);
    defer alloc.free(clean); // scratch: the return is always a fresh allocPrint, never `clean` itself
    var rand: [10]u8 = undefined;
    id.generate(io, &rand);
    if (std.mem.lastIndexOfScalar(u8, clean, '.')) |dot| {
        if (dot > 0 and dot < clean.len - 1) {
            const stem = clean[0..dot];
            var ext_buf: [16]u8 = undefined;
            const raw_ext = clean[dot + 1 ..];
            const elen = @min(raw_ext.len, ext_buf.len);
            for (raw_ext[0..elen], 0..) |c, i| ext_buf[i] = std.ascii.toLower(c);
            return std.fmt.allocPrint(alloc, "{s}_{s}.{s}", .{ stem, rand, ext_buf[0..elen] });
        }
    }
    return std.fmt.allocPrint(alloc, "{s}_{s}", .{ clean, rand });
}

test "sanitizeBase strips path components and unsafe chars" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{ "../../etc/passwd", "a/b/c.png", "a\\b\\c.png", "my file.txt", "..", "", ".", "a*b?.c", ".bashrc" };
    const expected = [_][]const u8{ "passwd", "c.png", "c.png", "my_file.txt", "file", "file", "file", "a_b.c", "bashrc" };
    for (cases, expected) |c, e| {
        const got = try sanitizeBase(a, c);
        defer a.free(got);
        try std.testing.expectEqualStrings(e, got);
    }
}

test "storedName keeps a sanitized stem + ext and adds a random suffix" {
    const a = std.testing.allocator;
    const n1 = try storedName(std.testing.io, a, "Photo Final.JPG");
    defer a.free(n1);
    try std.testing.expect(std.mem.startsWith(u8, n1, "Photo_Final_"));
    try std.testing.expect(std.mem.endsWith(u8, n1, ".jpg"));
    try std.testing.expect(std.mem.indexOfScalar(u8, n1, '/') == null);
    const n2 = try storedName(std.testing.io, a, "Photo Final.JPG");
    defer a.free(n2);
    try std.testing.expect(!std.mem.eql(u8, n1, n2));
    const n3 = try storedName(std.testing.io, a, "README");
    defer a.free(n3);
    try std.testing.expect(std.mem.startsWith(u8, n3, "README_"));
    try std.testing.expect(std.mem.indexOfScalar(u8, n3, '.') == null);
    const n4 = try storedName(std.testing.io, a, "../../x.png");
    defer a.free(n4);
    try std.testing.expect(std.mem.indexOf(u8, n4, "..") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, n4, '/') == null);
}
