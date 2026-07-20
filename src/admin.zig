const std = @import("std");
const RequestArena = @import("request_arena.zig").RequestArena;
const http = @import("http.zig");
const serve_file = @import("files/serve_file.zig");

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

const js_ctype = "application/javascript";

const Asset = struct {
    path: []const u8,
    bytes: []const u8,
    ctype: []const u8,
    etag: []const u8,
    headers: []const http.Header,
};

/// Build a manifest row with its comptime CRC32 ETag + [ETag, nosniff] headers.
fn mk(comptime path: []const u8, comptime bytes: []const u8, comptime ctype: []const u8) Asset {
    const tag: []const u8 = crcEtag(bytes);
    return .{
        .path = path,
        .bytes = bytes,
        .ctype = ctype,
        .etag = tag,
        .headers = &.{
            .{ .name = "ETag", .value = tag },
            .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        },
    };
}

const assets = [_]Asset{
    mk("/_/assets/app.js", app_js, js_ctype),
    mk("/_/assets/preact.js", preact_js, js_ctype),
    mk("/_/assets/style.css", style_css, "text/css"),
    mk("/_/assets/lib/api.js", @embedFile("admin/lib/api.js"), js_ctype),
    mk("/_/assets/lib/ui.js", @embedFile("admin/lib/ui.js"), js_ctype),
    mk("/_/assets/lib/editor.js", @embedFile("admin/lib/editor.js"), js_ctype),
    mk("/_/assets/views/collections.js", @embedFile("admin/views/collections.js"), js_ctype),
    mk("/_/assets/views/email.js", @embedFile("admin/views/email.js"), js_ctype),
    mk("/_/assets/views/files.js", @embedFile("admin/views/files.js"), js_ctype),
    mk("/_/assets/views/features.js", @embedFile("admin/views/features.js"), js_ctype),
    mk("/_/assets/views/settings.js", @embedFile("admin/views/settings.js"), js_ctype),
    mk("/_/assets/views/users.js", @embedFile("admin/views/users.js"), js_ctype),
    mk("/_/assets/views/logs.js", @embedFile("admin/views/logs.js"), js_ctype),
};

/// The SPA shell — served (with its own ETag/304) for "/_/" and any unknown "/_/…" path.
const spa_shell = mk("/_/", index_html, "text/html");

fn respond(ctx: *http.RequestCtx, a: Asset) http.Response {
    if (serve_file.etagMatches(ctx.if_none_match, a.etag))
        return .{ .status = 304, .body = "", .content_type = a.ctype, .extra_headers = a.headers };
    return .{ .status = 200, .body = a.bytes, .content_type = a.ctype, .extra_headers = a.headers };
}

/// Serve the embedded admin SPA for any path under "/_/". Known assets return their
/// bytes (with a CRC32 ETag; 304 on a matching If-None-Match); every other "/_/" path
/// returns the ETag'd index.html so client-side hash routes survive refresh.
pub fn serve(ctx: *http.RequestCtx) http.Response {
    const p = ctx.path;
    for (assets) |a| {
        if (std.mem.eql(u8, p, a.path)) return respond(ctx, a);
    }
    if (std.mem.startsWith(u8, p, "/_/assets/"))
        return .{ .status = 404, .body = "not found", .content_type = "text/plain" };
    return respond(ctx, spa_shell);
}

test "serve returns index.html for the root and unknown spa paths" {
    var ctx = http.RequestCtx{ .method = .GET, .path = "/_/", .allocator = RequestArena.forTest(std.testing.allocator) };
    const r = serve(&ctx);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("text/html", r.content_type);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "<div id=\"app\">") != null);
    var deep = http.RequestCtx{ .method = .GET, .path = "/_/collections/posts/records", .allocator = RequestArena.forTest(std.testing.allocator) };
    try std.testing.expectEqualStrings("text/html", serve(&deep).content_type);
}

test "serve returns assets with correct content types + nosniff" {
    var js = http.RequestCtx{ .method = .GET, .path = "/_/assets/app.js", .allocator = RequestArena.forTest(std.testing.allocator) };
    const rjs = serve(&js);
    try std.testing.expectEqualStrings("application/javascript", rjs.content_type);
    try std.testing.expect(rjs.extra_headers.len == 2 and std.mem.eql(u8, rjs.extra_headers[1].name, "X-Content-Type-Options"));
    var css = http.RequestCtx{ .method = .GET, .path = "/_/assets/style.css", .allocator = RequestArena.forTest(std.testing.allocator) };
    try std.testing.expectEqualStrings("text/css", serve(&css).content_type);
    var pj = http.RequestCtx{ .method = .GET, .path = "/_/assets/preact.js", .allocator = RequestArena.forTest(std.testing.allocator) };
    try std.testing.expectEqualStrings("application/javascript", serve(&pj).content_type);
    var ed = http.RequestCtx{ .method = .GET, .path = "/_/assets/lib/editor.js", .allocator = RequestArena.forTest(std.testing.allocator) };
    try std.testing.expectEqualStrings("application/javascript", serve(&ed).content_type);
    var unknown = http.RequestCtx{ .method = .GET, .path = "/_/assets/nope.js", .allocator = RequestArena.forTest(std.testing.allocator) };
    try std.testing.expectEqual(@as(u16, 404), serve(&unknown).status);
}

test "admin assets carry a build-time ETag and answer If-None-Match with 304" {
    var first = http.RequestCtx{ .method = .GET, .path = "/_/assets/app.js", .allocator = RequestArena.forTest(std.testing.allocator) };
    const r = serve(&first);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("ETag", r.extra_headers[0].name);
    const etag = r.extra_headers[0].value;
    try std.testing.expectEqual(@as(usize, 10), etag.len); // "xxxxxxxx" quoted
    try std.testing.expect(etag[0] == '"' and etag[9] == '"');

    var revalidate = http.RequestCtx{ .method = .GET, .path = "/_/assets/app.js", .allocator = RequestArena.forTest(std.testing.allocator), .if_none_match = etag };
    const r2 = serve(&revalidate);
    try std.testing.expectEqual(@as(u16, 304), r2.status);
    try std.testing.expectEqual(@as(usize, 0), r2.body.len);
    try std.testing.expectEqualStrings(etag, r2.extra_headers[0].value); // 304 keeps the headers
    try std.testing.expectEqualStrings("application/javascript", r2.content_type);

    var stale = http.RequestCtx{ .method = .GET, .path = "/_/assets/app.js", .allocator = RequestArena.forTest(std.testing.allocator), .if_none_match = "\"deadbeef\"" };
    try std.testing.expectEqual(@as(u16, 200), serve(&stale).status);

    // index.html (the SPA shell) revalidates too.
    var shell = http.RequestCtx{ .method = .GET, .path = "/_/", .allocator = RequestArena.forTest(std.testing.allocator) };
    const rs = serve(&shell);
    var shell304 = http.RequestCtx{ .method = .GET, .path = "/_/", .allocator = RequestArena.forTest(std.testing.allocator), .if_none_match = rs.extra_headers[0].value };
    try std.testing.expectEqual(@as(u16, 304), serve(&shell304).status);
}

test "every manifest asset serves 200 with an ETag and 304s on its own etag" {
    for (assets) |a| {
        var g = http.RequestCtx{ .method = .GET, .path = a.path, .allocator = RequestArena.forTest(std.testing.allocator) };
        const r = serve(&g);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings("ETag", r.extra_headers[0].name);
        try std.testing.expectEqualStrings("X-Content-Type-Options", r.extra_headers[1].name);
        var c = http.RequestCtx{ .method = .GET, .path = a.path, .allocator = RequestArena.forTest(std.testing.allocator), .if_none_match = a.etag };
        try std.testing.expectEqual(@as(u16, 304), serve(&c).status);
    }
}
