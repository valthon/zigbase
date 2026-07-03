const std = @import("std");
const zigbase = @import("zigbase");

/// The shipped binary: the framework with the `typegen` subcommand compiled in.
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
    return zigbase.App(.{ .enable_typegen = true, .mail = .{} }).runCli(init);
}
