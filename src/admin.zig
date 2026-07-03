const std = @import("std");
const http = @import("http.zig");
const static_files = @import("static_files.zig");

const index_html = @embedFile("admin/index.html");
const app_js = @embedFile("admin/app.js");
const preact_js = @embedFile("admin/preact.js");
const style_css = @embedFile("admin/style.css");

/// Build-time CRC32 entity tag — the same `"xxxxxxxx"` (quoted hex) format build.zig's
/// embedStaticDir writes into embedded-static manifests, so admin assets and consumer
/// embedded assets present one ETag convention.
fn crcEtag(comptime bytes: []const u8) *const [10:0]u8 {
    comptime {
        @setEvalBranchQuota(10_000_000); // app.js is ~42 KB; CRC32 iterates it at comptime
        return std.fmt.comptimePrint("\"{x:0>8}\"", .{std.hash.Crc32.hash(bytes)});
    }
}

/// Serve an embedded asset with ETag + nosniff; answers a matching If-None-Match with
/// 304 (same headers, empty body — RFC 7232: the 304 reports what the 200 would have).
fn asset(ctx: *http.RequestCtx, comptime bytes: []const u8, comptime content_type: []const u8) http.Response {
    const headers = comptime [_]http.Header{
        .{ .name = "ETag", .value = crcEtag(bytes) },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    };
    if (static_files.etagMatches(ctx.if_none_match, headers[0].value))
        return .{ .status = 304, .body = "", .content_type = content_type, .extra_headers = &headers };
    return .{ .status = 200, .body = bytes, .content_type = content_type, .extra_headers = &headers };
}

/// Serve the embedded admin SPA for any path under "/_/". Known assets return their bytes
/// (with build-time CRC32 ETags / 304 revalidation); every other "/_/" path returns
/// index.html (so client-side hash routes survive refresh/deep-link).
pub fn serve(ctx: *http.RequestCtx) http.Response {
    const p = ctx.path;
    if (std.mem.eql(u8, p, "/_/assets/app.js")) return asset(ctx, app_js, "application/javascript");
    if (std.mem.eql(u8, p, "/_/assets/preact.js")) return asset(ctx, preact_js, "application/javascript");
    if (std.mem.eql(u8, p, "/_/assets/style.css")) return asset(ctx, style_css, "text/css");
    if (std.mem.startsWith(u8, p, "/_/assets/")) return .{ .status = 404, .body = "not found", .content_type = "text/plain" };
    return asset(ctx, index_html, "text/html");
}

test "serve returns index.html for the root and unknown spa paths" {
    var ctx = http.RequestCtx{ .method = .GET, .path = "/_/", .allocator = std.testing.allocator };
    const r = serve(&ctx);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("text/html", r.content_type);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "<div id=\"app\">") != null);
    var deep = http.RequestCtx{ .method = .GET, .path = "/_/collections/posts/records", .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("text/html", serve(&deep).content_type);
}

test "serve returns assets with correct content types + nosniff" {
    var js = http.RequestCtx{ .method = .GET, .path = "/_/assets/app.js", .allocator = std.testing.allocator };
    const rjs = serve(&js);
    try std.testing.expectEqualStrings("application/javascript", rjs.content_type);
    try std.testing.expect(rjs.extra_headers.len == 2 and std.mem.eql(u8, rjs.extra_headers[1].name, "X-Content-Type-Options"));
    var css = http.RequestCtx{ .method = .GET, .path = "/_/assets/style.css", .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("text/css", serve(&css).content_type);
    var pj = http.RequestCtx{ .method = .GET, .path = "/_/assets/preact.js", .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("application/javascript", serve(&pj).content_type);
    var unknown = http.RequestCtx{ .method = .GET, .path = "/_/assets/nope.js", .allocator = std.testing.allocator };
    try std.testing.expectEqual(@as(u16, 404), serve(&unknown).status);
}

test "admin assets carry a build-time ETag and answer If-None-Match with 304" {
    var first = http.RequestCtx{ .method = .GET, .path = "/_/assets/app.js", .allocator = std.testing.allocator };
    const r = serve(&first);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("ETag", r.extra_headers[0].name);
    const etag = r.extra_headers[0].value;
    try std.testing.expectEqual(@as(usize, 10), etag.len); // "xxxxxxxx" quoted
    try std.testing.expect(etag[0] == '"' and etag[9] == '"');

    var revalidate = http.RequestCtx{ .method = .GET, .path = "/_/assets/app.js", .allocator = std.testing.allocator, .if_none_match = etag };
    const r2 = serve(&revalidate);
    try std.testing.expectEqual(@as(u16, 304), r2.status);
    try std.testing.expectEqual(@as(usize, 0), r2.body.len);
    try std.testing.expectEqualStrings(etag, r2.extra_headers[0].value); // 304 keeps the headers
    try std.testing.expectEqualStrings("application/javascript", r2.content_type);

    var stale = http.RequestCtx{ .method = .GET, .path = "/_/assets/app.js", .allocator = std.testing.allocator, .if_none_match = "\"deadbeef\"" };
    try std.testing.expectEqual(@as(u16, 200), serve(&stale).status);

    // index.html (the SPA shell) revalidates too.
    var shell = http.RequestCtx{ .method = .GET, .path = "/_/", .allocator = std.testing.allocator };
    const rs = serve(&shell);
    var shell304 = http.RequestCtx{ .method = .GET, .path = "/_/", .allocator = std.testing.allocator, .if_none_match = rs.extra_headers[0].value };
    try std.testing.expectEqual(@as(u16, 304), serve(&shell304).status);
}
