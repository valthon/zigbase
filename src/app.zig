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
};
