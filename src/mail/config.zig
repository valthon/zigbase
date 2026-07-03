//! Email-subsystem runtime knobs (#154), threaded from the comptime `App(.{ .mail = ... })` config
//! into `app.App.mail`. Every field defaults to the BACK-COMPAT, byte-identical-to-pre-#154 value:
//! enforcement is OFF and the webhook route is disabled unless the app opts in. An app that only
//! calls the existing mailer is therefore completely unaffected by this subsystem.
//!
//! Enforcement engagement (be explicit — see the brief):
//!   * `require_verified_sender` — when true, a send carrying BOTH a `from` and an `account` (a
//!     tenant send) must match a VERIFIED `_sender_identities` row, else it is rejected. A send with
//!     no `account` (a system/superuser send) bypasses, preserving the simple path.
//!   * `check_suppression` — when true, a send to a hard-bounced/complained recipient is blocked.
//!   * `webhook_secret` — the shared secret the inbound bounce/complaint webhook verifies (HMAC,
//!     constant-time). EMPTY disables the webhook route entirely (404) — ingestion is opt-in.

const std = @import("std");

/// The lowered runtime config stored on `app.App.mail`.
pub const Runtime = struct {
    /// Reject a tenant send whose From is not a verified sender identity for the account. Default
    /// off so existing simple-SMTP apps are unaffected.
    require_verified_sender: bool = false,
    /// Block a send to a suppressed (hard-bounced / complained) recipient. Default off.
    check_suppression: bool = false,
    /// Shared secret for the inbound bounce/complaint webhook signature (HMAC-SHA256, constant-time
    /// compare). EMPTY (default) disables the webhook route (404). Configure it to enable ingestion.
    webhook_secret: []const u8 = "",
    /// Public base URL for the one-click unsubscribe endpoint (#154 round 2), e.g.
    /// "https://app.example.com". EMPTY (default) = the feature is OFF: no
    /// List-Unsubscribe headers are emitted and the endpoint 404s (the same
    /// default-off pattern as `webhook_secret`). Set the comptime `.mail` key or the
    /// ZIGBASE_UNSUBSCRIBE_BASE_URL env var (env wins).
    unsubscribe_base_url: []const u8 = "",

    /// True when any send-time enforcement (verified sender or suppression) is active. Lets the send
    /// path skip acquiring a reader entirely when nothing is enabled (zero-cost on the default path).
    pub fn enforces(self: Runtime) bool {
        return self.require_verified_sender or self.check_suppression;
    }
};

test "Runtime defaults are the fully-off back-compat path" {
    const r = Runtime{};
    try std.testing.expect(!r.require_verified_sender);
    try std.testing.expect(!r.check_suppression);
    try std.testing.expectEqualStrings("", r.webhook_secret);
    try std.testing.expectEqualStrings("", r.unsubscribe_base_url);
    try std.testing.expect(!r.enforces());
}

test "enforces reflects either enforcement toggle" {
    try std.testing.expect((Runtime{ .require_verified_sender = true }).enforces());
    try std.testing.expect((Runtime{ .check_suppression = true }).enforces());
}
