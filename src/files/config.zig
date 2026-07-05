//! File-serving runtime knobs, threaded from the comptime `App(.{ .files = ... })` config into
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

const std = @import("std");

/// The lowered runtime config stored on `app.App.files`.
pub const Runtime = struct {
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
        if (comptime !std.mem.eql(u8, f.name, "s3_presign_redirect") and !std.mem.eql(u8, f.name, "s3_presign_ttl_s"))
            @compileError(".files: unknown key '." ++ f.name ++ "' (recognized: .s3_presign_redirect, .s3_presign_ttl_s)");
    }
    var rt = Runtime{};
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
