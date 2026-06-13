const std = @import("std");
const db = @import("db.zig");
const ratelimit = @import("ratelimit.zig");

/// Shared request-handling state. `io` supplies entropy for id generation;
/// `pool` is the SQLite connection pool. Config/auth are added in later sub-projects.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *db.Pool,
    jwt_secret: []const u8 = "",
    cookie_secure: bool = true,
    auth_token_ttl_s: i64 = 14 * 24 * 3600,
    verification_ttl_s: i64 = 7 * 24 * 3600,
    password_reset_ttl_s: i64 = 3600,
    /// Server-side OAuth `state` CSRF protection (F11). Opt-in: when true, the backend
    /// issues a `state` at oauth2-init and verifies+consumes it on auth-with-oauth2.
    oauth_state_server: bool = false,
    oauth_state_ttl_s: i64 = 600,
    realtime_allowed_origins: []const u8 = "",
    /// When false (default), client-IP logic ignores X-Forwarded-For/X-Real-IP and
    /// keys on the real socket peer. Only honor proxy headers when true (behind a
    /// trusted reverse proxy). See F8.
    trust_proxy: bool = false,
    max_upload_size: u64 = 50 << 20,
    file_token_ttl_s: i64 = 120,
    sentry_dsn: []const u8 = "", // "" = log errors to stderr; set to enable Sentry reporting
    /// Static-file source resolved by framework.serveImpl (.none = no static serving).
    static_source: @import("static_files.zig").Source = .none,
    storage: ?*const @import("files/storage.zig").Storage = null,
    /// Pluggable mailer (resolved from the comptime mailer plugin in serveImpl).
    /// Default = LogMailer (logs); set SMTP config to upgrade to SmtpMailer. null in
    /// tests/CLI where no mailer was wired (callers must fall back to logging).
    mailer: ?*const @import("mail/mailer.zig").Mailer = null,
    /// Type-erased event dispatch built by the comptime App(cfg) builder; null = no subscribers.
    dispatch: ?*const @import("events.zig").Dispatch = null,
    /// In-memory rate limiter for sensitive auth endpoints; null = disabled
    /// (rate_limit_max == 0, or tests/CLI that don't wire it). Set in serveImpl.
    rate_limiter: ?*ratelimit.RateLimiter = null,
    /// Type-erased pointer to the running Scheduler (set by Scheduler.start); null = not running.
    scheduler: ?*anyopaque = null,
    /// Submit an ad-hoc job task for async execution; set by Scheduler.start. Task 5 wires App.submit().
    submit_fn: ?*const fn (ctx: *anyopaque, name: []const u8, task: @import("events.zig").JobTask) anyerror!void = null,

    /// Offload an ad-hoc background task onto the scheduler (runs off the request thread).
    /// Returns error.SchedulerUnavailable if no scheduler is running (CLI/tests/no jobs configured).
    ///
    /// LIMITATION (v0.1): ad-hoc submitted tasks currently run on a DETACHED thread that is
    /// NOT joined at shutdown. A task submitted near shutdown may outlive the Scheduler's
    /// stop()/deinit() and must not assume `app` (or its pool/storage) outlives it
    /// indefinitely. Cron/interval jobs, by contrast, use the bounded, cleanly-joined worker pool.
    pub fn submit(self: *App, name: []const u8, task: @import("events.zig").JobTask) !void {
        const f = self.submit_fn orelse return error.SchedulerUnavailable;
        return f(self.scheduler.?, name, task);
    }
};
