//! Authorized, privately revalidated derivatives; no retained derivative cache.
const std = @import("std");
const http = @import("../http.zig");
const ApiError = @import("../api/error.zig").ApiError;
const storage_mod = @import("storage.zig");
const backend = @import("thumbnail_imagemagick.zig");
const config = @import("thumbnail_config.zig");
const source = @import("thumbnail_source.zig");

/// Bounded waiting uses the application's futex provider, never a spin loop.
/// Wakeups race for a permit; the deadline bounds waiting, not FIFO fairness.
pub const Admission = struct {
    mutex: std.Io.Mutex = .init,
    active: u32 = 0,
    waiting: u32 = 0,
    generation: std.atomic.Value(u32) = .init(0),

    pub fn acquire(self: *Admission, io: std.Io, cfg: config.Config) bool {
        const deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(cfg.wait_timeout_ms) });
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.active < cfg.max_concurrent) {
            self.active += 1;
            return true;
        }
        if (self.waiting >= cfg.max_waiting) return false;
        self.waiting += 1;
        defer self.waiting -= 1;
        while (true) {
            if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= deadline.raw.nanoseconds) return false;
            const generation = self.generation.load(.acquire);
            self.mutex.unlock(io);
            const waited = io.futexWaitTimeout(u32, &self.generation.raw, generation, .{ .deadline = deadline });
            self.mutex.lockUncancelable(io);
            waited catch return false;
            if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= deadline.raw.nanoseconds) return false;
            if (self.active < cfg.max_concurrent) {
                self.active += 1;
                return true;
            }
        }
    }
    pub fn release(self: *Admission, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        std.debug.assert(self.active > 0);
        self.active -= 1;
        _ = self.generation.fetchAdd(1, .release);
        self.mutex.unlock(io);
        io.futexWake(u32, &self.generation.raw, std.math.maxInt(u32));
    }
};

pub fn findProfile(cfg: config.Config, name: []const u8) ?config.Profile {
    for (cfg.profiles) |profile| if (std.mem.eql(u8, profile.name, name)) return profile;
    return null;
}

fn sourceFailure(ctx: *http.RequestCtx, err: anyerror) !http.Response {
    return switch (err) {
        error.SourceTooLarge => ApiError.withCode(413, .payload_too_large, "Thumbnail source exceeds configured limits.").toResponse(ctx.allocator.a),
        error.FileNotFound, error.NotDir, error.SymLinkLoop, error.SourceNotRegular, error.InvalidSourcePath, error.SourceChanged => ApiError.notFound().toResponse(ctx.allocator.a),
        else => ApiError.internal().toResponse(ctx.allocator.a),
    };
}

fn validator(ctx: *http.RequestCtx, cfg: config.Config, profile: config.Profile, st: std.Io.File.Stat, col: []const u8, rid: []const u8, name: []const u8) ![]const u8 {
    // Weak because ImageMagick/library builds may encode equivalent pixels
    // differently. Boot epoch invalidates installed backend/policy changes.
    const metadata = try std.json.Stringify.valueAlloc(ctx.allocator.a, .{
        .epoch = ctx.app.?.thumbnail_cache_epoch,
        .backend = cfg.imagemagick,
        .profile = profile,
        .collection = col,
        .record = rid,
        .name = name,
        .inode = st.inode,
        .size = st.size,
        .mtime = st.mtime.nanoseconds,
        .ctime = st.ctime.nanoseconds,
    }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(metadata, &digest, .{});
    return std.fmt.allocPrint(ctx.allocator.a, "W/\"{x}\"", .{digest});
}

fn matches(header: []const u8, etag: []const u8) bool {
    var values = std.mem.splitScalar(u8, header, ',');
    while (values.next()) |raw| {
        var value = std.mem.trim(u8, raw, " \t");
        // A wildcard does not prove this source can produce a representation.
        if (std.mem.eql(u8, value, "*")) continue;
        if (std.mem.startsWith(u8, value, "W/")) value = value[2..];
        if (std.mem.eql(u8, value, etag[2..])) return true;
    }
    return false;
}

pub fn serve(ctx: *http.RequestCtx, storage: storage_mod.Storage, col: []const u8, rid: []const u8, name: []const u8, profile_name: []const u8) !http.Response {
    const app = ctx.app.?;
    const cfg = app.files.thumbnails;
    const profile = findProfile(cfg, profile_name) orelse return ApiError.notFound().toResponse(ctx.allocator.a);
    if (storage_mod.LocalStorage.fromStorage(storage) == null)
        return ApiError.withCode(501, .not_implemented, "Thumbnails require built-in local storage.").toResponse(ctx.allocator.a);
    // Authorization and beforeServe have already run. No source bytes are
    // allocated before admission; conditional requests need only this handle.
    const opened = source.open(app.io, storage, col, rid, name) catch |err| return sourceFailure(ctx, err);
    defer opened.file.close(app.io);
    if (opened.stat.size > cfg.imagemagick.max_input_bytes) return sourceFailure(ctx, error.SourceTooLarge);
    const etag = try validator(ctx, cfg, profile, opened.stat, col, rid, name);
    const cache_headers = try ctx.allocator.a.dupe(http.Header, &.{
        .{ .name = "Cache-Control", .value = "private, max-age=0, must-revalidate" },
        .{ .name = "ETag", .value = etag },
        .{ .name = "Vary", .value = "Authorization, Cookie, X-Account-Id" },
    });
    if (matches(ctx.if_none_match, etag)) {
        source.revalidate(opened, app.io, storage, col, rid, name) catch |err| return sourceFailure(ctx, err);
        return .{ .status = 304, .content_type = profile.format.mime(), .body = "", .extra_headers = cache_headers };
    }
    if (!app.thumbnail_admission.acquire(app.io, cfg)) {
        var response = try ApiError.withCode(503, .thumbnail_busy, "Thumbnail capacity is busy.").toResponse(ctx.allocator.a);
        response.extra_headers = &.{.{ .name = "Retry-After", .value = "1" }};
        return response;
    }
    defer app.thumbnail_admission.release(app.io);
    const input = opened.read(app.allocator, app.io, cfg.imagemagick.max_input_bytes) catch |err| return sourceFailure(ctx, err);
    defer app.allocator.free(input);
    const result = backend.transform(app.allocator, app.io, input, cfg.imagemagick, profile.image()) catch |err| switch (err) {
        error.ImageInputTooLarge, error.ImageOutputTooLarge, error.ImageDimensionsExceeded => return ApiError.withCode(413, .payload_too_large, "Thumbnail exceeds configured limits.").toResponse(ctx.allocator.a),
        error.UnsupportedImageFormat, error.AnimatedImageUnsupported, error.ImageConversionFailed, error.InvalidImageOutput => return ApiError.withCode(422, .invalid_image, "A supported single-frame PNG, JPEG or WebP image is required.").toResponse(ctx.allocator.a),
        error.OutOfMemory => return error.OutOfMemory,
        else => return ApiError.withCode(503, .internal, "Image transformation backend unavailable.").toResponse(ctx.allocator.a),
    };
    defer result.deinit(app.allocator);
    // Reopen the name as well as rechecking our descriptor: replacement during
    // queueing/transform must not return bytes under a stale source validator.
    source.revalidate(opened, app.io, storage, col, rid, name) catch |err| return sourceFailure(ctx, err);
    if (std.mem.eql(u8, std.mem.trim(u8, ctx.if_none_match, " \t"), "*")) return .{ .status = 304, .content_type = profile.format.mime(), .body = "", .extra_headers = cache_headers };
    const headers = try ctx.allocator.a.alloc(http.Header, cache_headers.len + 6);
    @memcpy(headers[0..cache_headers.len], cache_headers);
    @memcpy(headers[cache_headers.len..], &[_]http.Header{
        .{ .name = "Accept-Ranges", .value = "none" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        .{ .name = "Referrer-Policy", .value = "no-referrer" },
        .{ .name = "Content-Security-Policy", .value = "default-src 'none'; sandbox" },
        .{ .name = "Content-Disposition", .value = try std.fmt.allocPrint(ctx.allocator.a, "inline; filename=\"thumbnail.{s}\"", .{@tagName(result.format)}) },
        .{ .name = "Content-Length", .value = try std.fmt.allocPrint(ctx.allocator.a, "{d}", .{result.bytes().len}) },
    });
    return .{ .status = 200, .content_type = result.format.mime(), .extra_headers = headers, .body = if (ctx.method == .HEAD) "" else try ctx.allocator.a.dupe(u8, result.bytes()) };
}

test "thumbnail admission bounds waiters and times out without leaking permits" {
    var admission: Admission = .{};
    const cfg = config.Config{ .wait_timeout_ms = 1 };
    try std.testing.expect(admission.acquire(std.testing.io, cfg));
    try std.testing.expect(!admission.acquire(std.testing.io, cfg));
    try std.testing.expectEqual(@as(u32, 0), admission.waiting);
    admission.release(std.testing.io);
    try std.testing.expect(admission.acquire(std.testing.io, cfg));
    admission.release(std.testing.io);
}

test "thumbnail admission waits through the Io futex provider and observes release" {
    const Probe = struct {
        var calls: usize = 0;
        var admission: *Admission = undefined;
        fn wait(_: ?*anyopaque, _: *const u32, _: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
            calls += 1;
            // Deterministic release at the parking boundary also proves that
            // acquire does not retain its mutex while asking Io to wait.
            admission.release(std.testing.io);
        }
    };
    var admission: Admission = .{};
    Probe.admission = &admission;
    Probe.calls = 0;
    var vtable = std.testing.io.vtable.*;
    vtable.futexWait = Probe.wait;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    const cfg = config.Config{};
    try std.testing.expect(admission.acquire(io, cfg));
    try std.testing.expect(admission.acquire(io, cfg));
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(@as(u32, 0), admission.waiting);
    try std.testing.expectEqual(@as(u32, 1), admission.active);
    admission.release(io);
}
