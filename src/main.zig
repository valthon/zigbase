const std = @import("std");
const zigbase = @import("zigbase");

/// Opt the shipped binary into the framework's timestamped, leveled, JSON-capable
/// log core (`src/logging.zig`) for every `std.log` call. Access lines and their
/// `--log-format`/`--log-level` behavior work either way (the server logs them
/// directly); omitting this line just leaves std.log output in Zig's default
/// (ANSI, timestamp-free) format, mixed with JSON access lines under `--log-format json`.
pub const std_options = zigbase.std_options;

/// The shipped binary: the framework with the `typegen` subcommand compiled in.
/// It explicitly includes TOTP/WebAuthn second factors; collection policy stays
/// disabled until configured. Embedders omit `.auth.two_factor` for exclusion.
/// One binary serves both the GitHub release tarballs and the @zigbase/server
/// npm packages. `enable_typegen` stays a framework option for embedders who
/// want it off. Demo flags/experiments live in fixtures/features (test-only).
///
/// `.mail = .{}` opts the standalone product into the built-in mail routes
/// (verified-sender management, the inbound bounce/complaint webhook, and the
/// RFC 8058 one-click unsubscribe). Route registration is now comptime-gated on
/// `.mail` (see server.zig `Gates`); this keeps those routes ON for the shipped
/// `zigbase serve` binary — matching its historical behavior — while embedders
/// who omit `.mail` still get the smaller, mail-free build. It is behavior-neutral
/// at runtime: the mail Runtime defaults are all back-compat-off, and each
/// endpoint stays inert until its activating env/config is set (e.g. the
/// unsubscribe route needs `ZIGBASE_UNSUBSCRIBE_BASE_URL`).
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{ .enable_typegen = true, .mail = .{}, .auth = .{ .two_factor = .{ .factors = .{ .totp, .webauthn } } } }).runCli(init);
}
