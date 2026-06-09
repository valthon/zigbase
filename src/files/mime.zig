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
