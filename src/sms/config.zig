//! SMS-subsystem runtime knobs (#224), threaded from the comptime `App(.{ .sms = ... })` config
//! into `app.App.sms`. Mirrors `mail/config.zig`. Every field defaults to a sensible value: an
//! app that only calls `ctx.sms()` with `+`-prefixed international numbers is unaffected by the
//! `default_region` knob, and background delivery rides the always-present `"default"` queue.

const std = @import("std");
const e164 = @import("e164.zig");

pub const Region = e164.Region;

/// The lowered runtime config stored on `app.App.sms`.
pub const Runtime = struct {
    /// Region whose country code is prefixed onto a national number sent without a leading `+`
    /// (see `e164.normalizeE164`). Default US.
    default_region: Region = .us,
    /// Default queue name for `ctx.sms().enqueue` when the caller does not pick one.
    queue: []const u8 = "default",
};

test "Runtime defaults" {
    const r = Runtime{};
    try std.testing.expectEqual(Region.us, r.default_region);
    try std.testing.expectEqualStrings("default", r.queue);
}
