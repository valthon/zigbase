//! Pure HTTP Range/conditional planner for ZigBase-OWNED file responses (SP3 Theme D §B.2).
//! No I/O: given an entity's size + strong quoted ETag and the request's conditional headers,
//! decide the status (200 | 206 | 304 | 416), the byte window to transmit, and the
//! Content-Range value. Consumers: the record-file download route (api/files.zig) and the
//! EMBEDDED static path (static_files.zig, §A.4). Dir-mode static NEVER uses this planner —
//! that path stays 100% facil.io's (§A.3); only its Range *request header* is normalized
//! (static_files.normalizeRange, which reuses parseRange below).
const std = @import("std");

pub const PlanInput = struct {
    size: u64,
    /// Strong entity tag INCLUDING its surrounding quotes (e.g. "\"a1b2c3d4\"").
    etag: []const u8,
    range: []const u8 = "", // raw Range header value; "" = absent
    if_none_match: []const u8 = "", // raw If-None-Match value; "" = absent
    if_range: []const u8 = "", // raw If-Range value; "" = absent
    /// HEAD gets the identical plan (status/len/content_range); the caller sends no body.
    head: bool = false,
};

pub const Plan = struct {
    status: u16, // 200 | 206 | 304 | 416
    offset: u64 = 0,
    len: u64 = 0,
    content_range: ?[]const u8 = null, // "bytes a-b/N" (206) or "bytes */N" (416)
};

/// RFC 9110 §13.2.2 evaluation order: If-None-Match (weak comparison, list + `*`) → 304;
/// else If-Range (STRONG comparison — exact match required, a `W/` prefix always refuses);
/// else a single `bytes=` range; unsatisfiable → 416 with `Content-Range: bytes */N`.
pub fn plan(alloc: std.mem.Allocator, in: PlanInput) !Plan {
    if (etagMatches(in.if_none_match, in.etag)) return .{ .status = 304 };
    // If-Range: honor Range only when the validator exactly equals our strong ETag.
    // RFC 9110 §13.1.5 requires the strong comparison function here — weak tags refuse.
    const range_ok = in.if_range.len == 0 or
        std.mem.eql(u8, std.mem.trim(u8, in.if_range, " \t"), in.etag);
    if (in.range.len > 0 and range_ok) {
        switch (parseRange(in.range, in.size)) {
            .none => {}, // malformed / multi-range / non-bytes: ignore → full 200 (RFC-permitted)
            .unsatisfiable => return .{
                .status = 416,
                .content_range = try std.fmt.allocPrint(alloc, "bytes */{d}", .{in.size}),
            },
            .slice => |s| return .{
                .status = 206,
                .offset = s.offset,
                .len = s.len,
                .content_range = try std.fmt.allocPrint(
                    alloc,
                    "bytes {d}-{d}/{d}",
                    .{ s.offset, s.offset + s.len - 1, in.size },
                ),
            },
        }
    }
    return .{ .status = 200, .offset = 0, .len = in.size };
}

pub const ParsedRange = union(enum) {
    none,
    unsatisfiable,
    slice: struct { offset: u64, len: u64 },
};

/// Parse a SINGLE `bytes=` range against an entity of `size` bytes (RFC 9110 §14.1.2).
/// Syntactically-multi ("a-b,c-d"), malformed, and non-bytes units all yield `.none`
/// (callers then serve the full 200 — a server MAY ignore Range). Forms:
///   `a-b` — closed; `b` clamped to size-1; `b < a` is malformed → .none
///   `a-`  — open-ended, a..EOF
///   `-n`  — suffix, the final n bytes; n >= size → the whole entity as a 206;
///           `-0` → .unsatisfiable (RFC: a suffix-length of zero is unsatisfiable)
///   `a >= size` (incl. size == 0) → .unsatisfiable
pub fn parseRange(raw: []const u8, size: u64) ParsedRange {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (!std.mem.startsWith(u8, trimmed, "bytes=")) return .none;
    const spec = trimmed["bytes=".len..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .none; // multi-range: ignore
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .none;
    const first = spec[0..dash];
    const second = spec[dash + 1 ..];
    if (first.len == 0) {
        // suffix form "-n"
        if (second.len == 0) return .none; // bare "bytes=-" is malformed
        const n = std.fmt.parseInt(u64, second, 10) catch return .none;
        if (n == 0 or size == 0) return .unsatisfiable;
        const len = @min(n, size);
        return .{ .slice = .{ .offset = size - len, .len = len } };
    }
    const a = std.fmt.parseInt(u64, first, 10) catch return .none;
    if (a >= size) return .unsatisfiable; // covers size == 0 too
    if (second.len == 0) {
        // open-ended "a-": a..EOF (the form video players send when seeking)
        return .{ .slice = .{ .offset = a, .len = size - a } };
    }
    const b = std.fmt.parseInt(u64, second, 10) catch return .none;
    if (b < a) return .none; // malformed: ignore
    const end = @min(b, size - 1);
    return .{ .slice = .{ .offset = a, .len = end - a + 1 } };
}

/// Strong, content-immutable ETag for a stored record file. Stored names are minted with a
/// random 10-char base36 suffix and an UPDATE always mints a NEW stored name
/// (files/naming.zig storedName), so (collection, record id, stored name) is content-stable:
/// hex FNV-1a-64 of `col ++ "/" ++ rid ++ "/" ++ name`, quoted. No stat-derived component —
/// identical for local and S3-spooled serving (§B.3).
pub fn fileEtag(alloc: std.mem.Allocator, col: []const u8, rid: []const u8, name: []const u8) ![]const u8 {
    var h = std.hash.Fnv1a_64.init();
    h.update(col);
    h.update("/");
    h.update(rid);
    h.update("/");
    h.update(name);
    return std.fmt.allocPrint(alloc, "\"{x:0>16}\"", .{h.final()});
}

/// Strip an RFC 7232 weak-validator prefix ("W/") from an entity tag.
fn opaqueTag(tag: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tag, "W/")) tag[2..] else tag;
}

/// True when the request's If-None-Match matches this entity tag ("*", or a list member).
/// RFC 7232 §3.2: If-None-Match MUST use the WEAK comparison function — W/ prefixes are
/// ignored on both sides (proxies may weaken our strong tag). Moved here (was a private fn
/// in static_files.zig) so the record route, embedded static, and the SPA shell share one
/// implementation; static_files.zig re-imports it.
pub fn etagMatches(if_none_match: []const u8, etag: []const u8) bool {
    if (if_none_match.len == 0) return false;
    if (std.mem.eql(u8, if_none_match, "*")) return true;
    const ours = opaqueTag(etag);
    var it = std.mem.splitScalar(u8, if_none_match, ',');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, opaqueTag(std.mem.trim(u8, raw, " \t")), ours)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn expectSlice(pr: ParsedRange, offset: u64, len: u64) !void {
    try testing.expect(pr == .slice);
    try testing.expectEqual(offset, pr.slice.offset);
    try testing.expectEqual(len, pr.slice.len);
}

test "parseRange: closed, open-ended, suffix, clamping" {
    try expectSlice(parseRange("bytes=0-99", 1000), 0, 100);
    try expectSlice(parseRange("bytes=500-999", 1000), 500, 500);
    try expectSlice(parseRange(" bytes=0-0", 1000), 0, 1); // leading space trimmed
    // open-ended "X-" — the video-seek form facil.io drops to a 200 (KNOWN_LIMITATIONS bullet)
    try expectSlice(parseRange("bytes=200-", 1000), 200, 800);
    try expectSlice(parseRange("bytes=999-", 1000), 999, 1);
    // suffix "-n"
    try expectSlice(parseRange("bytes=-100", 1000), 900, 100);
    try expectSlice(parseRange("bytes=-1", 1000), 999, 1);
    // suffix longer than the entity: the whole entity (RFC 9110 §14.1.2)
    try expectSlice(parseRange("bytes=-5000", 1000), 0, 1000);
    // overlong closed range: end clamped to size-1
    try expectSlice(parseRange("bytes=900-5000", 1000), 900, 100);
}

test "parseRange: unsatisfiable forms -> 416" {
    try testing.expect(parseRange("bytes=1000-", 1000) == .unsatisfiable); // a == size
    try testing.expect(parseRange("bytes=1001-2000", 1000) == .unsatisfiable); // a > size
    try testing.expect(parseRange("bytes=-0", 1000) == .unsatisfiable); // zero suffix
    try testing.expect(parseRange("bytes=0-", 0) == .unsatisfiable); // empty entity
    try testing.expect(parseRange("bytes=-5", 0) == .unsatisfiable); // suffix on empty entity
}

test "parseRange: malformed / multi-range / non-bytes are ignored (.none -> full 200)" {
    try testing.expect(parseRange("", 1000) == .none);
    try testing.expect(parseRange("bytes=0-99,200-299", 1000) == .none); // multi: RFC-permitted ignore
    try testing.expect(parseRange("bytes=99-0", 1000) == .none); // b < a
    try testing.expect(parseRange("bytes=abc-def", 1000) == .none);
    try testing.expect(parseRange("bytes=-", 1000) == .none);
    try testing.expect(parseRange("bytes=", 1000) == .none);
    try testing.expect(parseRange("items=0-99", 1000) == .none); // non-bytes unit
    try testing.expect(parseRange("0-99", 1000) == .none); // missing unit
}

test "plan: If-None-Match wins over Range; weak comparison; list; star" {
    const a = testing.allocator;
    const etag = "\"0123456789abcdef\"";
    // single + Range present: 304 still wins (evaluation order)
    const p1 = try plan(a, .{ .size = 100, .etag = etag, .if_none_match = etag, .range = "bytes=0-9" });
    defer if (p1.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 304), p1.status);
    // weak comparison: W/ on the client's side matches our strong tag
    const p_wk = try plan(a, .{ .size = 100, .etag = etag, .if_none_match = "W/\"0123456789abcdef\"" });
    defer if (p_wk.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 304), p_wk.status);
    // list member
    const p_list = try plan(a, .{ .size = 100, .etag = etag, .if_none_match = "\"x\", \"0123456789abcdef\"" });
    defer if (p_list.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 304), p_list.status);
    // star
    const p_star = try plan(a, .{ .size = 100, .etag = etag, .if_none_match = "*" });
    defer if (p_star.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 304), p_star.status);
    // mismatch: falls through to the Range
    const p2 = try plan(a, .{ .size = 100, .etag = etag, .if_none_match = "\"nope\"", .range = "bytes=0-9" });
    defer if (p2.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 206), p2.status);
    try testing.expectEqualStrings("bytes 0-9/100", p2.content_range.?);
}

test "plan: If-Range strong match honors Range; mismatch/weak refuse it (full 200)" {
    const a = testing.allocator;
    const etag = "\"0123456789abcdef\"";
    const hit = try plan(a, .{ .size = 100, .etag = etag, .if_range = etag, .range = "bytes=10-19" });
    defer if (hit.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 206), hit.status);
    try testing.expectEqual(@as(u64, 10), hit.offset);
    try testing.expectEqual(@as(u64, 10), hit.len);
    // mismatched validator: Range ignored, full 200 with the whole entity
    const miss = try plan(a, .{ .size = 100, .etag = etag, .if_range = "\"old\"", .range = "bytes=10-19" });
    defer if (miss.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 200), miss.status);
    try testing.expectEqual(@as(u64, 100), miss.len);
    // WEAK validator: strong comparison required -> refused even for the same opaque tag
    const weak = try plan(a, .{ .size = 100, .etag = etag, .if_range = "W/\"0123456789abcdef\"", .range = "bytes=10-19" });
    defer if (weak.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 200), weak.status);
    // If-Range mismatch also suppresses a WOULD-BE-416 range (the range is ignored, not evaluated)
    const not416 = try plan(a, .{ .size = 100, .etag = etag, .if_range = "\"old\"", .range = "bytes=500-" });
    defer if (not416.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 200), not416.status);
}

test "plan: 200 / 206 / 416 shapes + HEAD parity" {
    const a = testing.allocator;
    const etag = "\"0123456789abcdef\"";
    const full = try plan(a, .{ .size = 42, .etag = etag });
    defer if (full.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 200), full.status);
    try testing.expectEqual(@as(u64, 42), full.len);
    try testing.expect(full.content_range == null);
    const p206 = try plan(a, .{ .size = 1000, .etag = etag, .range = "bytes=200-" });
    defer if (p206.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 206), p206.status);
    try testing.expectEqualStrings("bytes 200-999/1000", p206.content_range.?);
    const p416 = try plan(a, .{ .size = 1000, .etag = etag, .range = "bytes=2000-" });
    defer if (p416.content_range) |cr| a.free(cr);
    try testing.expectEqual(@as(u16, 416), p416.status);
    try testing.expectEqualStrings("bytes */1000", p416.content_range.?);
    // HEAD: byte-identical plan (the caller just doesn't transmit the body)
    const head = try plan(a, .{ .size = 1000, .etag = etag, .range = "bytes=200-", .head = true });
    defer if (head.content_range) |cr| a.free(cr);
    try testing.expectEqual(p206.status, head.status);
    try testing.expectEqual(p206.len, head.len);
}

test "fileEtag: quoted 16-hex, deterministic, distinct per identity component" {
    const a = testing.allocator;
    const e1 = try fileEtag(a, "docs", "r1", "a_ab12cd34ef.png");
    defer a.free(e1);
    try testing.expectEqual(@as(usize, 18), e1.len); // 2 quotes + 16 hex
    try testing.expectEqual(@as(u8, '"'), e1[0]);
    try testing.expectEqual(@as(u8, '"'), e1[e1.len - 1]);
    const e1b = try fileEtag(a, "docs", "r1", "a_ab12cd34ef.png");
    defer a.free(e1b);
    try testing.expectEqualStrings(e1, e1b);
    const e2 = try fileEtag(a, "docs", "r2", "a_ab12cd34ef.png");
    defer a.free(e2);
    try testing.expect(!std.mem.eql(u8, e1, e2));
    const e3 = try fileEtag(a, "docs2", "r1", "a_ab12cd34ef.png");
    defer a.free(e3);
    try testing.expect(!std.mem.eql(u8, e1, e3));
    // The separator prevents (col="a", rid="b/c") colliding with (col="a/b", rid="c")
    const e4 = try fileEtag(a, "ab", "c", "n");
    defer a.free(e4);
    const e5 = try fileEtag(a, "a", "bc", "n");
    defer a.free(e5);
    try testing.expect(!std.mem.eql(u8, e4, e5));
}

test "etagMatches uses RFC 7232 weak comparison (moved from static_files.zig)" {
    try testing.expect(etagMatches("W/\"22222222\"", "\"22222222\""));
    try testing.expect(etagMatches("\"x\", W/\"22222222\"", "\"22222222\""));
    try testing.expect(etagMatches("\"22222222\"", "W/\"22222222\""));
    try testing.expect(!etagMatches("W/\"junk\"", "\"22222222\""));
    try testing.expect(!etagMatches("", "\"22222222\""));
    try testing.expect(etagMatches("*", "\"anything\""));
}
