//! Non-secret storage backend info, lowered from config.Config in serveImpl and
//! exposed read-only via GET /api/files/config. NEVER holds S3 credentials.
pub const Backend = enum { local, s3 };
pub const Info = struct {
    backend: Backend = .local,
    dir: []const u8 = "storage", // local: the storage subdir under data_dir
    bucket: []const u8 = "", // s3 (non-secret)
    region: []const u8 = "",
    endpoint: []const u8 = "",
    key_prefix: []const u8 = "",
};

test "Info defaults to local with no credentials fields" {
    const std = @import("std");
    const i = Info{};
    try std.testing.expect(i.backend == .local);
    try std.testing.expectEqualStrings("storage", i.dir);
}
