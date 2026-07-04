//! GET /api/files/config — superuser-only, read-only storage backend info for the
//! admin UI. Non-secret only; NEVER exposes the S3 access key id / secret.
const std = @import("std");
const http = @import("../http.zig");
const auth = @import("../auth.zig");
const ApiError = @import("error.zig").ApiError;

pub fn get(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app orelse return ApiError.notFound().toResponse(ctx.allocator);
    var r = try app.pool.acquireReader();
    defer app.pool.releaseReader(&r);
    const a = (auth.authenticate(app.io, ctx.allocator, app, ctx, &r) catch null) orelse
        return (ApiError{ .status = 401, .message = "Authentication required." }).toResponse(ctx.allocator);
    if (!a.is_superuser)
        return (ApiError{ .status = 403, .message = "Superuser only." }).toResponse(ctx.allocator);

    const si = app.storage_info;
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "backend", .{ .string = if (si.backend == .s3) "s3" else "local" });
    if (si.backend == .s3) {
        try root.put(ctx.allocator, "bucket", .{ .string = si.bucket });
        try root.put(ctx.allocator, "region", .{ .string = si.region });
        try root.put(ctx.allocator, "endpoint", .{ .string = si.endpoint });
        try root.put(ctx.allocator, "key_prefix", .{ .string = si.key_prefix });
    } else {
        try root.put(ctx.allocator, "dir", .{ .string = si.dir });
    }
    return .{
        .status = 200,
        .content_type = "application/json",
        .body = try std.json.Stringify.valueAlloc(ctx.allocator, std.json.Value{ .object = root }, .{}),
    };
}

test "files config JSON never contains credential keys" {
    const info = @import("../files/info.zig");
    // Pin: the Info struct has no access-key/secret fields at all.
    const fields = @typeInfo(info.Info).@"struct".fields;
    inline for (fields) |f| {
        try std.testing.expect(std.mem.indexOf(u8, f.name, "access_key") == null);
        try std.testing.expect(std.mem.indexOf(u8, f.name, "secret") == null);
    }
}
