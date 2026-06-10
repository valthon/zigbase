const std = @import("std");
const db = @import("db.zig");

/// Shared request-handling state. `io` supplies entropy for id generation;
/// `pool` is the SQLite connection pool. Config/auth are added in later sub-projects.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *db.Pool,
    jwt_secret: []const u8 = "dev-insecure-secret-change-me",
    cookie_secure: bool = false,
    auth_token_ttl_s: i64 = 14 * 24 * 3600,
    verification_ttl_s: i64 = 7 * 24 * 3600,
    password_reset_ttl_s: i64 = 3600,
    realtime_allowed_origins: []const u8 = "",
    max_upload_size: u64 = 50 << 20,
    file_token_ttl_s: i64 = 120,
    sentry_dsn: []const u8 = "", // "" = log errors to stderr; set to enable Sentry reporting
    storage: ?*const @import("files/storage.zig").Storage = null,
    /// Type-erased event dispatch built by the comptime App(cfg) builder; null = no subscribers.
    dispatch: ?*const @import("events.zig").Dispatch = null,
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
