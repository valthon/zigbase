//! Request-owned response construction for caller-authorized local files.
const std = @import("std");
const http = @import("../http.zig");
pub const serve_file = @import("serve_file.zig");
pub const mime = @import("mime.zig");

pub const Options = struct {
    content_type: ?[]const u8 = null,
    cache_control: []const u8 = "private",
    /// A caller-supplied strong ETag for immutable/versioned content avoids hashing
    /// the entire file on each request. Include the surrounding quotes.
    etag: ?[]const u8 = null,
};

/// Return a streaming response, including Range/If-Range/If-None-Match semantics.
/// The caller must authorize and validate the path (including symlink confinement),
/// and keep the file immutable until transmission finishes. Errors propagate.
/// Response strings and headers belong to ctx's request arena. Without an explicit
/// ETag, hashing uses bounded memory but reads the entire file before responding.
pub fn respondPath(ctx: *@import("../ctx.zig").Ctx, path: []const u8, options: Options) !http.Response {
    return respond(ctx.app.io, ctx.request orelse return error.NoHttpRequest, path, options);
}

pub fn respond(io: std.Io, ctx: *http.RequestCtx, path: []const u8, options: Options) !http.Response {
    if (ctx.method != .GET and ctx.method != .HEAD) return error.MethodNotAllowed;
    const a = ctx.allocator.a;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    if (st.kind != .file) return error.NotAFile;
    const etag = if (options.etag) |value| try a.dupe(u8, value) else blk: {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [16384]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = try file.readPositional(io, &.{&buffer}, offset);
            if (n == 0) break;
            hash.update(buffer[0..n]);
            offset += n;
        }
        const digest = hash.finalResult();
        break :blk try std.fmt.allocPrint(a, "\"{s}\"", .{std.fmt.bytesToHex(digest, .lower)});
    };
    const p = try serve_file.plan(a, .{
        .size = st.size,
        .etag = etag,
        .range = ctx.header("range") orelse "",
        .if_range = ctx.header("if-range") orelse "",
        .if_none_match = ctx.if_none_match,
    });
    var headers: std.ArrayList(http.Header) = .empty;
    try headers.appendSlice(a, &.{
        .{ .name = "ETag", .value = etag },
        .{ .name = "Accept-Ranges", .value = "bytes" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        .{ .name = "Cache-Control", .value = try a.dupe(u8, options.cache_control) },
    });
    if (p.content_range) |value| try headers.append(a, .{ .name = "Content-Range", .value = value });
    if (p.status == 304 or ctx.method == .HEAD) try headers.append(a, .{
        .name = "content-length",
        .value = try std.fmt.allocPrint(a, "{d}", .{if (p.status == 304) st.size else p.len}),
    });
    return .{
        .status = p.status,
        .body = "",
        .content_type = if (options.content_type) |value| try a.dupe(u8, value) else mime.fromExtension(path),
        .extra_headers = try headers.toOwnedSlice(a),
        .file = if ((p.status == 200 or p.status == 206) and ctx.method != .HEAD)
            .{ .path = try a.dupe(u8, path), .offset = p.offset, .len = p.len }
        else
            null,
    };
}
