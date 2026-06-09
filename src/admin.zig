const std = @import("std");
const http = @import("http.zig");

const index_html = @embedFile("admin/index.html");
const app_js = @embedFile("admin/app.js");
const preact_js = @embedFile("admin/preact.js");
const style_css = @embedFile("admin/style.css");

const nosniff = [_]http.Header{.{ .name = "X-Content-Type-Options", .value = "nosniff" }};

fn asset(bytes: []const u8, content_type: []const u8) http.Response {
    return .{ .status = 200, .body = bytes, .content_type = content_type, .extra_headers = &nosniff };
}

/// Serve the embedded admin SPA for any path under "/_/". Known assets return their bytes; every
/// other "/_/" path returns index.html (so client-side hash routes survive refresh/deep-link).
pub fn serve(ctx: *http.RequestCtx) http.Response {
    const p = ctx.path;
    if (std.mem.eql(u8, p, "/_/assets/app.js")) return asset(app_js, "application/javascript");
    if (std.mem.eql(u8, p, "/_/assets/preact.js")) return asset(preact_js, "application/javascript");
    if (std.mem.eql(u8, p, "/_/assets/style.css")) return asset(style_css, "text/css");
    if (std.mem.startsWith(u8, p, "/_/assets/")) return .{ .status = 404, .body = "not found", .content_type = "text/plain" };
    return asset(index_html, "text/html");
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
    try std.testing.expect(rjs.extra_headers.len == 1 and std.mem.eql(u8, rjs.extra_headers[0].name, "X-Content-Type-Options"));
    var css = http.RequestCtx{ .method = .GET, .path = "/_/assets/style.css", .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("text/css", serve(&css).content_type);
    var pj = http.RequestCtx{ .method = .GET, .path = "/_/assets/preact.js", .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("application/javascript", serve(&pj).content_type);
    var unknown = http.RequestCtx{ .method = .GET, .path = "/_/assets/nope.js", .allocator = std.testing.allocator };
    try std.testing.expectEqual(@as(u16, 404), serve(&unknown).status);
}
