const std = @import("std");

fn isLiteralByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or
        std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@", byte) != null;
}

fn isCaptureName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_'))
        return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn isCanonicalLiteral(segment: []const u8) bool {
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    for (segment) |byte| if (!isLiteralByte(byte)) return false;
    return true;
}

/// Canonical route grammar shared by framework assembly and OpenAPI export.
/// `:name` is a one-segment router capture; every other segment is a canonical
/// URI segment. Capture names follow the OpenAPI identifier grammar.
pub fn isCanonicalPattern(comptime path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] != '/' or
        (path.len > 1 and (path[1] == '/' or path[path.len - 1] == '/')))
        return false;

    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return path.len == 1;
        if (segment[0] == ':') {
            const name = segment[1..];
            if (!isCaptureName(name)) return false;
            var occurrences: usize = 0;
            var all_segments = std.mem.splitScalar(u8, path[1..], '/');
            while (all_segments.next()) |candidate| {
                if (candidate.len > 1 and candidate[0] == ':' and
                    std.mem.eql(u8, candidate[1..], name)) occurrences += 1;
            }
            if (occurrences != 1) return false;
        } else if (!isCanonicalLiteral(segment)) return false;
    }
    return true;
}

pub fn isCanonicalFixed(comptime path: []const u8) bool {
    if (!isCanonicalPattern(path)) return false;
    if (path.len == 0) return false;
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| if (segment.len > 0 and segment[0] == ':') return false;
    return true;
}

pub fn hasCapture(comptime path: []const u8, comptime name: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len > 1 and segment[0] == ':' and std.mem.eql(u8, segment[1..], name))
            return true;
    }
    return false;
}

pub fn patternsOverlap(a: []const u8, b: []const u8) bool {
    var ait = std.mem.splitScalar(u8, a, '/');
    var bit = std.mem.splitScalar(u8, b, '/');
    while (true) {
        const as = ait.next();
        const bs = bit.next();
        if (as == null or bs == null) return as == null and bs == null;
        if (as.?.len > 0 and as.?[0] == ':') continue;
        if (bs.?.len > 0 and bs.?[0] == ':') continue;
        if (!std.mem.eql(u8, as.?, bs.?)) return false;
    }
}

test "canonical consumer patterns distinguish captures from fixed paths" {
    try std.testing.expect(isCanonicalPattern("/api/reports/:report_id"));
    try std.testing.expect(isCanonicalPattern("/"));
    try std.testing.expect(!isCanonicalFixed("/api/reports/:report_id"));
    try std.testing.expect(isCanonicalFixed("/api/reports/current"));
    try std.testing.expect(hasCapture("/api/reports/:report_id", "report_id"));
}

test "canonical consumer patterns reject ambiguous and non-canonical spellings" {
    inline for (&.{
        "api/x",        "/api//x",         "/api/x/", "/api/./x",       "/api/%2F/x",
        "/api/%41",     "/api/{id}",       "/api/:",  "/api/:bad-name", "/api/:id/:id",
        "/api/x?query", "/api/x#fragment",
    }) |path| try std.testing.expect(!isCanonicalPattern(path));
}

test "canonical consumer patterns reject percent escapes" {
    inline for (&.{ "/caf%C3%A9", "/api/%41", "/api/%2F" }) |path|
        try std.testing.expect(!isCanonicalPattern(path));
}
