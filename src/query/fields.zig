const std = @import("std");

/// `fields=` response projection (PocketBase-style). This is a PURE OUTPUT FILTER over an
/// already-built `std.json.Value` record: it runs AFTER `expand`, view-rule authorization,
/// and any sensitive-field stripping, and can ONLY REMOVE keys. It never reads a column,
/// re-queries, or invents data, so it is structurally impossible to widen access with it —
/// a field the record wouldn't otherwise expose can never appear.
///
/// Syntax: comma-separated dot-paths. `expand.author.name` selects the nested key. `*` as a
/// segment means "all keys at this level". A leading `-` on a path excludes it (applied after
/// includes). Whitespace around each comma-separated path (and each segment) is trimmed.
/// A single dot-path, already split into its segments (e.g. `["expand","author","name"]`).
pub const Path = []const []const u8;

pub const Spec = struct {
    includes: []const Path,
    excludes: []const Path,

    pub fn isEmpty(self: Spec) bool {
        return self.includes.len == 0 and self.excludes.len == 0;
    }
};

/// Parse a raw `fields=` value into include/exclude path lists (allocated on `alloc`, the
/// request arena). Empty/whitespace-only paths are skipped; empty segments (e.g. `a..b`)
/// are dropped. A path starting with `-` is an exclude.
pub fn parse(alloc: std.mem.Allocator, raw: []const u8) !Spec {
    var inc: std.ArrayList(Path) = .empty;
    var exc: std.ArrayList(Path) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |seg_raw| {
        var path_str = std.mem.trim(u8, seg_raw, " \t");
        if (path_str.len == 0) continue;
        var is_exclude = false;
        if (path_str[0] == '-') {
            is_exclude = true;
            path_str = std.mem.trim(u8, path_str[1..], " \t");
            if (path_str.len == 0) continue;
        }
        var segs: std.ArrayList([]const u8) = .empty;
        var pit = std.mem.splitScalar(u8, path_str, '.');
        while (pit.next()) |s| {
            const seg = std.mem.trim(u8, s, " \t");
            if (seg.len == 0) continue;
            try segs.append(alloc, seg);
        }
        if (segs.items.len == 0) continue;
        const path = try segs.toOwnedSlice(alloc);
        if (is_exclude) try exc.append(alloc, path) else try inc.append(alloc, path);
    }
    return .{ .includes = try inc.toOwnedSlice(alloc), .excludes = try exc.toOwnedSlice(alloc) };
}

fn segMatches(seg: []const u8, key: []const u8) bool {
    return std.mem.eql(u8, seg, "*") or std.mem.eql(u8, seg, key);
}

/// The implicit `["*"]` include used for an exclude-only spec — comptime constant (static
/// lifetime), so `project` never takes the address of a stack local.
const star_seg = [_][]const u8{"*"};
const star_path = [_]Path{&star_seg};

/// Project `value` down to the include `paths` (each a slice of the segments remaining AT THIS
/// LEVEL). Returns a NEW value built from kept keys (never mutates `value` in place, so the
/// hashmap iterator is never invalidated). Returns `null` when nothing at this level matches
/// and the value is a scalar the paths tried to descend into (the key is then omitted).
fn projectValue(alloc: std.mem.Allocator, value: std.json.Value, paths: []const Path) !?std.json.Value {
    switch (value) {
        .object => |obj| {
            var out: std.json.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                var include_whole = false;
                var subpaths: std.ArrayList(Path) = .empty;
                defer subpaths.deinit(alloc); // freed each key iteration (used before this fires)
                for (paths) |p| {
                    if (p.len == 0) continue;
                    if (!segMatches(p[0], key)) continue;
                    if (p.len == 1) {
                        include_whole = true;
                    } else {
                        try subpaths.append(alloc, p[1..]);
                    }
                }
                // A leaf match (whole value) always wins over a deeper descent for the same key,
                // matching PocketBase: `*,expand.author.name` keeps the whole `expand`.
                if (include_whole) {
                    try out.put(alloc, key, entry.value_ptr.*);
                } else if (subpaths.items.len > 0) {
                    if (try projectValue(alloc, entry.value_ptr.*, subpaths.items)) |v|
                        try out.put(alloc, key, v);
                }
            }
            return .{ .object = out };
        },
        .array => |arr| {
            // Multi-relation expand: apply the same sub-projection to each element.
            var out = std.json.Array.init(alloc);
            for (arr.items) |elem| {
                if (try projectValue(alloc, elem, paths)) |v| try out.append(v);
            }
            return .{ .array = out };
        },
        // A scalar the paths tried to descend into cannot match — yield nothing (omit the key).
        else => return null,
    }
}

/// Remove `path` from `value` (descending through objects and expand arrays). A non-present
/// path is a silent no-op. A leaf `*` removes all keys at that level.
fn applyExclude(value: *std.json.Value, path: Path) void {
    if (path.len == 0) return;
    switch (value.*) {
        .array => |*arr| {
            for (arr.items) |*e| applyExclude(e, path);
        },
        .object => |*obj| {
            const seg = path[0];
            if (path.len == 1) {
                if (std.mem.eql(u8, seg, "*")) {
                    obj.clearRetainingCapacity();
                } else {
                    _ = obj.orderedRemove(seg);
                }
            } else {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    if (segMatches(seg, entry.key_ptr.*))
                        applyExclude(entry.value_ptr, path[1..]);
                }
            }
        },
        else => {},
    }
}

/// Apply `spec` to a record `value` (a `.object`) in place: build the projected object from the
/// includes, then remove the excludes. When there are no includes but there ARE excludes, the
/// implicit base is `*` (all top-level keys), so `fields=-secret` means "everything but secret".
/// An empty spec (neither includes nor excludes) is a no-op (full record).
pub fn project(alloc: std.mem.Allocator, value: *std.json.Value, spec: Spec) !void {
    if (spec.isEmpty()) return;
    if (value.* != .object) return;

    // Exclude-only spec (no includes) starts from an implicit `*` (all top-level keys), then
    // applies the excludes. `star_path` is a comptime constant (static lifetime) rather than a
    // stack local whose address we'd take.
    const includes: []const Path = if (spec.includes.len > 0) spec.includes else &star_path;

    if (try projectValue(alloc, value.*, includes)) |projected| value.* = projected;

    for (spec.excludes) |ex| applyExclude(value, ex);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a `std.json.Value` from a JSON literal on `arena`.
fn jval(arena: std.mem.Allocator, comptime json: []const u8) !std.json.Value {
    return (try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}));
}

/// Stringify a value with sorted-by-insertion order for stable comparison.
fn dump(arena: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, v, .{});
}

fn hasKey(v: std.json.Value, key: []const u8) bool {
    return v == .object and v.object.get(key) != null;
}

fn projectStr(arena: std.mem.Allocator, comptime json: []const u8, spec_str: []const u8) !std.json.Value {
    var v = try jval(arena, json);
    const spec = try parse(arena, spec_str);
    try project(arena, &v, spec);
    return v;
}

test "top-level include selects only listed keys, no auto-id" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const v = try projectStr(arena, "{\"id\":\"1\",\"title\":\"t\",\"body\":\"b\"}", "id,title");
    try testing.expect(hasKey(v, "id"));
    try testing.expect(hasKey(v, "title"));
    try testing.expect(!hasKey(v, "body"));

    // No auto-id: `fields=title` yields only title.
    const v2 = try projectStr(arena, "{\"id\":\"1\",\"title\":\"t\",\"body\":\"b\"}", "title");
    try testing.expect(!hasKey(v2, "id"));
    try testing.expect(hasKey(v2, "title"));
    try testing.expectEqual(@as(usize, 1), v2.object.count());
}

test "* keeps all top-level keys" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try projectStr(arena, "{\"id\":\"1\",\"title\":\"t\",\"body\":\"b\"}", "*");
    try testing.expectEqual(@as(usize, 3), v.object.count());
    try testing.expect(hasKey(v, "id") and hasKey(v, "title") and hasKey(v, "body"));
}

test "*,-body keeps all except body" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try projectStr(arena, "{\"id\":\"1\",\"title\":\"t\",\"body\":\"b\"}", "*,-body");
    try testing.expect(hasKey(v, "id") and hasKey(v, "title"));
    try testing.expect(!hasKey(v, "body"));
}

test "exclude-only implies all-but-excluded" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try projectStr(arena, "{\"id\":\"1\",\"title\":\"t\",\"secret\":\"x\"}", "-secret");
    try testing.expect(hasKey(v, "id") and hasKey(v, "title"));
    try testing.expect(!hasKey(v, "secret"));
}

test "expand descent trims to the requested nested key" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try projectStr(arena, "{\"id\":\"1\",\"title\":\"t\",\"expand\":{\"author\":{\"id\":\"a1\",\"name\":\"Jo\",\"email\":\"j@x\"}}}", "id,expand.author.name");
    try testing.expect(hasKey(v, "id"));
    try testing.expect(!hasKey(v, "title"));
    const exp = v.object.get("expand").?;
    const author = exp.object.get("author").?;
    try testing.expect(hasKey(author, "name"));
    try testing.expect(!hasKey(author, "id"));
    try testing.expect(!hasKey(author, "email"));
    try testing.expectEqual(@as(usize, 1), author.object.count());
}

test "expand block dropped when no expand path listed" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try projectStr(arena, "{\"id\":\"1\",\"expand\":{\"author\":{\"id\":\"a1\",\"name\":\"Jo\"}}}", "id");
    try testing.expect(hasKey(v, "id"));
    try testing.expect(!hasKey(v, "expand"));
    try testing.expectEqual(@as(usize, 1), v.object.count());
}

test "multi-relation array: each element projected" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try projectStr(arena, "{\"id\":\"1\",\"expand\":{\"tags\":[{\"id\":\"t1\",\"label\":\"a\"},{\"id\":\"t2\",\"label\":\"b\"}]}}", "expand.tags.label");
    const tags = v.object.get("expand").?.object.get("tags").?;
    try testing.expect(tags == .array);
    try testing.expectEqual(@as(usize, 2), tags.array.items.len);
    for (tags.array.items) |t| {
        try testing.expect(hasKey(t, "label"));
        try testing.expect(!hasKey(t, "id"));
        try testing.expectEqual(@as(usize, 1), t.object.count());
    }
}

test "nested expand descends two levels" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try projectStr(arena, "{\"id\":\"1\",\"expand\":{\"author\":{\"id\":\"a1\",\"expand\":{\"org\":{\"id\":\"o1\",\"name\":\"ACME\",\"tier\":\"gold\"}}}}}", "expand.author.expand.org.name");
    const org = v.object.get("expand").?.object
        .get("author").?.object
        .get("expand").?.object
        .get("org").?;
    try testing.expect(hasKey(org, "name"));
    try testing.expect(!hasKey(org, "id"));
    try testing.expect(!hasKey(org, "tier"));
}

test "exclusion inside expand" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try projectStr(arena, "{\"id\":\"1\",\"expand\":{\"author\":{\"id\":\"a1\",\"name\":\"Jo\",\"email\":\"j@x\"}}}", "expand.author.*,-expand.author.email");
    const author = v.object.get("expand").?.object.get("author").?;
    try testing.expect(hasKey(author, "id") and hasKey(author, "name"));
    try testing.expect(!hasKey(author, "email"));
}

test "non-present include path is a no-op" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try projectStr(arena, "{\"id\":\"1\",\"title\":\"t\"}", "nonexistent");
    try testing.expect(v == .object);
    try testing.expectEqual(@as(usize, 0), v.object.count());
}

test "whitespace tolerance around paths" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const v = try projectStr(arena, "{\"id\":\"1\",\"title\":\"t\",\"body\":\"b\"}", "id, title");
    try testing.expect(hasKey(v, "id") and hasKey(v, "title"));
    try testing.expect(!hasKey(v, "body"));
}

test "projection cannot invent an absent field" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    // The record never contained `password` (e.g. stripped upstream); asking for it yields nothing.
    const v = try projectStr(arena, "{\"id\":\"1\",\"title\":\"t\"}", "id,password");
    try testing.expect(hasKey(v, "id"));
    try testing.expect(!hasKey(v, "password"));
    try testing.expectEqual(@as(usize, 1), v.object.count());
}
