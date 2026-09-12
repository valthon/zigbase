//! File-serving and lifecycle knobs, threaded from the comptime `App(.{ .files = ... })` config into
//! `app.App.files`. Every field defaults to the BACK-COMPAT, byte-identical-to-pre-feature value:
//! presigned-redirect serving is OFF, so an app that does nothing keeps the proxy-only path where
//! the server fetches (and, for S3, spool-caches) the bytes and streams them itself.
//!
//! Engagement (opt-in):
//!   * `presign_redirect` — when true AND the active storage backend supports presigning (S3, i.e.
//!     a `-Ds3` build with `ZIGBASE_S3_*` configured), an authorized file download is answered with
//!     a 302 redirect to a time-limited presigned GET URL instead of proxying the bytes. On a
//!     backend without presigning (local disk, or a build without `-Ds3`) the storage vtable
//!     returns null and the serve path falls through to the unchanged proxy. Default off.
//!   * `presign_ttl_s` — the validity window (seconds) of the issued presigned URL, the
//!     `X-Amz-Expires` value. The URL is a BEARER capability (not bound to the authorized
//!     requester) valid until it expires, so keep this short. Default 900s (15 min).
//!   * `cleanup_queue` — resolved by App against its durable queue registry, which
//!     installs the transactional enqueue callback and worker only when configured.

const std = @import("std");

// SQLite bounds the entire encoded row, not only its BLOB. Reserve the bounded
// metadata JSON plus id/state, three 64-bit integers and record-header varints.
pub const durable_metadata_bytes = 16384;
pub const durable_row_overhead = durable_metadata_bytes + 256;
pub const durable_sqlite_max_length = 1_000_000_000; // vendored SQLITE_MAX_LENGTH
pub const durable_max_upload_bytes = durable_sqlite_max_length - durable_row_overhead;

/// Comptime resource budgets for opt-in process-local upload sessions.
pub const ResumableLimits = struct {
    durable: if (@import("build_options").durable_resumable_uploads) bool else void = if (@import("build_options").durable_resumable_uploads) false else {},
    max_sessions: usize = 8,
    max_upload_bytes: usize = 8 << 20,
    max_total_bytes: usize = 32 << 20,
    max_chunk_bytes: usize = 1 << 20,
    ttl_seconds: u32 = 900,
    max_sessions_per_principal: usize = 2,
};

/// Shared by comptime configuration and runtime persisted-budget validation.
pub fn validResumableLimits(r: ResumableLimits) bool {
    if (@import("build_options").durable_resumable_uploads) {
        if (r.durable and r.max_upload_bytes > durable_max_upload_bytes) return false;
    }
    return r.max_sessions > 0 and r.max_sessions <= 1024 and
        r.max_sessions_per_principal > 0 and r.max_sessions_per_principal <= r.max_sessions and
        r.max_upload_bytes > 0 and r.max_upload_bytes <= r.max_total_bytes and
        r.max_total_bytes <= 1 << 30 and r.max_chunk_bytes > 0 and
        r.max_chunk_bytes <= r.max_upload_bytes and r.ttl_seconds > 0 and r.ttl_seconds <= 86400;
}

/// The lowered runtime config stored on `app.App.files`.
pub const Runtime = struct {
    thumbnails: if (@import("build_options").image_thumbnails) @import("thumbnail_config.zig").Config else void = if (@import("build_options").image_thumbnails) .{} else {},
    resumable: if (@import("build_options").resumable_uploads) ResumableLimits else void = if (@import("build_options").resumable_uploads) .{} else {},
    /// Installed only by an opt-in App; absent builds do not retain cleanup code.
    cleanup: ?*const fn (std.mem.Allocator, *@import("../db.zig").Db, std.Io, @import("../queue/queue.zig").QueueDef, @import("../schema.zig").Collection, []const u8, std.json.Value, ?std.json.Value) anyerror!void = null,
    cleanup_queue: ?@import("../queue/queue.zig").QueueDef = null,
    /// Serve authorized S3 downloads as a 302 redirect to a presigned GET URL instead of proxying
    /// the bytes. Default off = the byte-identical proxy-only path. No effect on non-presigning
    /// backends (local disk / non-`-Ds3` builds), where the storage vtable declines and the proxy
    /// path is taken.
    presign_redirect: bool = false,
    /// Validity window (seconds) for the presigned URL (`X-Amz-Expires`). The URL is a time-limited
    /// bearer capability — keep it short. Default 900s. S3 caps a presign at 7 days (604800s).
    presign_ttl_s: u32 = 900,
};

/// Comptime-lower a `.files` config group into `Runtime`, validating each sub-key. Absent keys keep
/// their default. `presign_ttl_s` must be in `1..=604800` (S3's max presign window) and
/// `presign_redirect` must be a bool, else `@compileError`.
pub fn lower(comptime files_cfg: anytype) Runtime {
    const FC = @TypeOf(files_cfg);
    if (@typeInfo(FC) != .@"struct")
        @compileError(".files must be a struct, e.g. '.{ .s3_presign_redirect = true, .s3_presign_ttl_s = 900 }'");
    inline for (std.meta.fields(FC)) |f| {
        if (comptime !std.mem.eql(u8, f.name, "thumbnails") and !std.mem.eql(u8, f.name, "resumable") and !std.mem.eql(u8, f.name, "cleanup_queue") and !std.mem.eql(u8, f.name, "s3_presign_redirect") and !std.mem.eql(u8, f.name, "s3_presign_ttl_s"))
            @compileError(".files: unknown key '." ++ f.name ++ "' (recognized: .thumbnails, .resumable, .cleanup_queue, .s3_presign_redirect, .s3_presign_ttl_s)");
    }
    var rt = Runtime{};
    if (@hasField(FC, "thumbnails")) {
        if (!@import("build_options").image_thumbnails) @compileError(".files.thumbnails requires -Dimage-thumbnails=true");
        rt.thumbnails = @import("thumbnail_config.zig").lower(files_cfg.thumbnails);
    }
    if (@hasField(FC, "resumable")) {
        if (!@import("build_options").resumable_uploads) @compileError(".files.resumable requires -Dresumable-uploads=true");
        if (@typeInfo(@TypeOf(files_cfg.resumable)) != .@"struct") @compileError(".files.resumable must be a struct of resource budgets");
        inline for (std.meta.fields(@TypeOf(files_cfg.resumable))) |field| {
            if (!@hasField(ResumableLimits, field.name)) @compileError("Unknown .files.resumable limit: " ++ field.name);
            if (comptime std.mem.eql(u8, field.name, "durable") and !@import("build_options").durable_resumable_uploads) {
                if (files_cfg.resumable.durable) @compileError(".files.resumable.durable requires -Ddurable-resumable-uploads=true");
            } else @field(rt.resumable, field.name) = @field(files_cfg.resumable, field.name);
        }
        if (!validResumableLimits(rt.resumable))
            @compileError("Invalid .files.resumable budgets: positive limits, sessions<=1024, principal<=sessions, chunk<=upload<=total<=1GiB, TTL<=86400 required; durable upload<=999983360 bytes");
    }
    if (@hasField(FC, "s3_presign_redirect")) {
        if (@TypeOf(files_cfg.s3_presign_redirect) != bool)
            @compileError(".files.s3_presign_redirect must be a bool (true/false)");
        rt.presign_redirect = files_cfg.s3_presign_redirect;
    }
    if (@hasField(FC, "s3_presign_ttl_s")) {
        const ttl = files_cfg.s3_presign_ttl_s;
        if (ttl < 1 or ttl > 604800)
            @compileError(".files.s3_presign_ttl_s must be in 1..=604800 seconds (S3's max presign window is 7 days)");
        rt.presign_ttl_s = ttl;
    }
    return rt;
}

test "resumable budget validity is shared across configuration and recovery" {
    try std.testing.expect(validResumableLimits(.{}));
    try std.testing.expect(validResumableLimits(.{ .max_sessions = 1024, .max_sessions_per_principal = 1024, .max_total_bytes = 1 << 30, .max_upload_bytes = 1 << 30, .max_chunk_bytes = 1 << 30, .ttl_seconds = 86400 }));
    for ([_]ResumableLimits{
        .{ .max_sessions = 0 },
        .{ .max_sessions = 1025 },
        .{ .max_sessions_per_principal = 0 },
        .{ .max_sessions_per_principal = 9 },
        .{ .max_upload_bytes = 0 },
        .{ .max_upload_bytes = 33 << 20 },
        .{ .max_total_bytes = (1 << 30) + 1 },
        .{ .max_chunk_bytes = 0 },
        .{ .max_chunk_bytes = 9 << 20 },
        .{ .ttl_seconds = 0 },
        .{ .ttl_seconds = 86401 },
    }) |invalid| try std.testing.expect(!validResumableLimits(invalid));
}

test "durable upload budget leaves SQLite whole-row headroom without lowering RAM cap" {
    if (comptime !@import("build_options").durable_resumable_uploads) return error.SkipZigTest;
    var limits = ResumableLimits{ .durable = true, .max_upload_bytes = durable_max_upload_bytes, .max_total_bytes = 1 << 30 };
    try std.testing.expect(validResumableLimits(limits));
    limits.max_upload_bytes += 1;
    try std.testing.expect(!validResumableLimits(limits));
    limits.max_upload_bytes = 1 << 30;
    try std.testing.expect(!validResumableLimits(limits));
    limits.durable = false;
    try std.testing.expect(validResumableLimits(limits));
}

test "lower defaults are the fully-off proxy path" {
    const r = lower(.{});
    try std.testing.expect(!r.presign_redirect);
    try std.testing.expectEqual(@as(u32, 900), r.presign_ttl_s);
}

test "lower applies overrides" {
    const r = lower(.{ .s3_presign_redirect = true, .s3_presign_ttl_s = 3600 });
    try std.testing.expect(r.presign_redirect);
    try std.testing.expectEqual(@as(u32, 3600), r.presign_ttl_s);
}

test "Runtime defaults are proxy-only" {
    const r = Runtime{};
    try std.testing.expect(!r.presign_redirect);
    try std.testing.expectEqual(@as(u32, 900), r.presign_ttl_s);
}

test "resumable budgets are compiled out or comptime configurable" {
    if (comptime @import("build_options").resumable_uploads) {
        const rt = comptime lower(.{ .resumable = .{ .max_sessions = 3, .max_sessions_per_principal = 1, .max_upload_bytes = 32, .max_total_bytes = 64, .max_chunk_bytes = 8, .ttl_seconds = 10 } });
        try std.testing.expectEqual(@as(usize, 3), rt.resumable.max_sessions);
        try std.testing.expectEqual(@as(usize, 64), rt.resumable.max_total_bytes);
        try std.testing.expectEqual(@as(u32, 10), rt.resumable.ttl_seconds);
    } else {
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(@FieldType(Runtime, "resumable")));
    }
}
