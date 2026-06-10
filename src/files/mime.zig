const std = @import("std");

const Sig = struct { magic: []const u8, mime: []const u8 };

const signatures = [_]Sig{
    .{ .magic = &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, .mime = "image/png" },
    .{ .magic = &[_]u8{ 0xFF, 0xD8, 0xFF }, .mime = "image/jpeg" },
    .{ .magic = "GIF87a", .mime = "image/gif" },
    .{ .magic = "GIF89a", .mime = "image/gif" },
    .{ .magic = "%PDF-", .mime = "application/pdf" },
    .{ .magic = &[_]u8{ 'P', 'K', 0x03, 0x04 }, .mime = "application/zip" },
    .{ .magic = &[_]u8{ 'P', 'K', 0x05, 0x06 }, .mime = "application/zip" },
};

/// Best-effort content type from leading magic bytes. Unknown/empty/truncated -> octet-stream.
pub fn sniff(bytes: []const u8) []const u8 {
    for (signatures) |s| {
        if (bytes.len >= s.magic.len and std.mem.eql(u8, bytes[0..s.magic.len], s.magic)) return s.mime;
    }
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP"))
        return "image/webp";
    return "application/octet-stream";
}

const Ext = struct { ext: []const u8, mime: []const u8 };

const extensions = [_]Ext{
    .{ .ext = "html", .mime = "text/html; charset=utf-8" },
    .{ .ext = "css", .mime = "text/css; charset=utf-8" },
    .{ .ext = "js", .mime = "application/javascript" },
    .{ .ext = "mjs", .mime = "application/javascript" },
    .{ .ext = "json", .mime = "application/json" },
    .{ .ext = "map", .mime = "application/json" },
    .{ .ext = "svg", .mime = "image/svg+xml" },
    .{ .ext = "png", .mime = "image/png" },
    .{ .ext = "jpg", .mime = "image/jpeg" },
    .{ .ext = "jpeg", .mime = "image/jpeg" },
    .{ .ext = "gif", .mime = "image/gif" },
    .{ .ext = "webp", .mime = "image/webp" },
    .{ .ext = "avif", .mime = "image/avif" },
    .{ .ext = "ico", .mime = "image/x-icon" },
    .{ .ext = "woff2", .mime = "font/woff2" },
    .{ .ext = "woff", .mime = "font/woff" },
    .{ .ext = "ttf", .mime = "font/ttf" },
    .{ .ext = "wasm", .mime = "application/wasm" },
    .{ .ext = "txt", .mime = "text/plain; charset=utf-8" },
    .{ .ext = "xml", .mime = "application/xml" },
    .{ .ext = "pdf", .mime = "application/pdf" },
    .{ .ext = "mp4", .mime = "video/mp4" },
    .{ .ext = "webm", .mime = "video/webm" },
};

/// Content type from a path's file extension (the text after the LAST '.').
/// Unknown/missing extensions -> application/octet-stream.
pub fn fromExtension(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    if (ext.len == 0) return "application/octet-stream";
    for (extensions) |e| {
        if (std.ascii.eqlIgnoreCase(e.ext, ext)) return e.mime;
    }
    return "application/octet-stream";
}

/// True if `allowlist` is null (unrestricted) or contains `sniffed`.
pub fn allowed(allowlist: ?[]const []const u8, sniffed: []const u8) bool {
    const list = allowlist orelse return true;
    for (list) |m| if (std.mem.eql(u8, m, sniffed)) return true;
    return false;
}

test "sniff detects common types from magic bytes" {
    try std.testing.expectEqualStrings("image/png", sniff(&[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }));
    try std.testing.expectEqualStrings("image/jpeg", sniff(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 }));
    try std.testing.expectEqualStrings("image/gif", sniff("GIF89a....."));
    try std.testing.expectEqualStrings("application/pdf", sniff("%PDF-1.7"));
    try std.testing.expectEqualStrings("application/zip", sniff(&[_]u8{ 'P', 'K', 0x03, 0x04 }));
    try std.testing.expectEqualStrings("application/octet-stream", sniff("just some text"));
    try std.testing.expectEqualStrings("application/octet-stream", sniff(""));
    try std.testing.expectEqualStrings("application/octet-stream", sniff("PK"));
}

test "allowed: null allowlist permits anything; otherwise membership" {
    try std.testing.expect(allowed(null, "image/png"));
    const list = [_][]const u8{ "image/png", "image/jpeg" };
    try std.testing.expect(allowed(&list, "image/png"));
    try std.testing.expect(!allowed(&list, "application/pdf"));
}

test "fromExtension maps common static-asset extensions" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", fromExtension("index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", fromExtension("assets/site.css"));
    try std.testing.expectEqualStrings("application/javascript", fromExtension("a/b/app-Abc123.js"));
    try std.testing.expectEqualStrings("application/javascript", fromExtension("m.mjs"));
    try std.testing.expectEqualStrings("application/json", fromExtension("data.json"));
    try std.testing.expectEqualStrings("image/svg+xml", fromExtension("logo.svg"));
    try std.testing.expectEqualStrings("image/png", fromExtension("img.png"));
    try std.testing.expectEqualStrings("image/jpeg", fromExtension("photo.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", fromExtension("photo.jpeg"));
    try std.testing.expectEqualStrings("image/webp", fromExtension("img.webp"));
    try std.testing.expectEqualStrings("image/avif", fromExtension("img.avif"));
    try std.testing.expectEqualStrings("image/gif", fromExtension("anim.gif"));
    try std.testing.expectEqualStrings("image/x-icon", fromExtension("favicon.ico"));
    try std.testing.expectEqualStrings("font/woff2", fromExtension("f.woff2"));
    try std.testing.expectEqualStrings("font/woff", fromExtension("f.woff"));
    try std.testing.expectEqualStrings("font/ttf", fromExtension("f.ttf"));
    try std.testing.expectEqualStrings("application/wasm", fromExtension("mod.wasm"));
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", fromExtension("robots.txt"));
    try std.testing.expectEqualStrings("application/xml", fromExtension("sitemap.xml"));
    try std.testing.expectEqualStrings("application/json", fromExtension("app.js.map"));
    try std.testing.expectEqualStrings("application/pdf", fromExtension("doc.pdf"));
    try std.testing.expectEqualStrings("video/mp4", fromExtension("v.mp4"));
    try std.testing.expectEqualStrings("video/webm", fromExtension("v.webm"));
}

test "fromExtension falls back to octet-stream" {
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension("archive.tar.zst"));
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension("noext"));
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension(""));
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension("trailingdot."));
}
