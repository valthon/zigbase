//! The single dev-only build gate. True on a dev/test build (Debug by default, or
//! `-Ddev-mode=true`); comptime-FALSE on any release/shipped binary (the release
//! script cross-compiles ReleaseSafe, so `dev_mode` defaults off there). It gates
//! every dev-only-never-in-production seam so a prod binary can't use any of them:
//! the frozen clock (`ZIGBASE_FAKE_NOW`), seeded entropy (`ZIGBASE_FAKE_SEED`),
//! the test-capture mailer/sms/push, and fake field-crypto (`ZIGBASE_FIELD_CRYPTO`).
//! When false, each of those folds to comptime-dead code and its env var is never read.
const build_options = @import("build_options");

/// Comptime gate — see the module doc comment. Every dev-only override is `if (dev.enabled) …`.
pub const enabled = build_options.dev_mode;
