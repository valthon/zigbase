const std = @import("std");
const zigbase = @import("zigbase");

// Test fixture only. Inspect entries under the same mutex as the production path.
fn probe(ctx: *zigbase.Ctx) !zigbase.http.Response {
    _ = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();
    const store = ctx.app.public_response_cache.?;
    var count: usize = 0;
    for (store.entries) |entry| if (entry.body != null) {
        count += 1;
    };
    return .{ .status = 200, .body = try std.json.Stringify.valueAlloc(ctx.arena.a, .{ .count = count, .next = store.next }, .{}) };
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .public_response_cache = .{ .collections = &.{ "posts", "private_posts", "expiring", "members" }, .max_entries = 2, .max_body_bytes = 65536, .ttl_ms = 1000 },
        .routes = .{.{ .method = .GET, .path = "/cache-probe", .auth = .superuser, .handler = probe }},
    }).runCli(init);
}
