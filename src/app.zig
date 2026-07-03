const std = @import("std");
const db = @import("db.zig");
const ratelimit = @import("ratelimit.zig");
const pagination = @import("pagination.zig");
const features = @import("features.zig");
const captcha = @import("captcha.zig");
const tenancy_mod = @import("tenancy/tenancy.zig");

/// Session-management model (#99). `epoch` (default) is the stateless token-epoch
/// revocation scheme: cheap, no per-request DB read beyond the existing auth fetch.
/// `table` opts into the server-side `_sessions` store for per-device list/revoke
/// (DESIGNED-but-STUBBED — see the session-management design spec); the epoch verbs
/// (revokeAllSessions/refresh/rotate) work in BOTH modes.
pub const SessionStore = enum { epoch, table };

/// Shared request-handling state. `io` supplies entropy for id generation;
/// `pool` is the SQLite connection pool. Config/auth are added in later sub-projects.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *db.Pool,
    jwt_secret: []const u8 = "",
    cookie_secure: bool = true,
    auth_token_ttl_s: i64 = 14 * 24 * 3600,
    /// Selected session-management model (#99); resolved from the comptime
    /// `App(.{ .session_store = .epoch | .table })` config. Defaults to `.epoch`.
    session_store: SessionStore = .epoch,
    verification_ttl_s: i64 = 7 * 24 * 3600,
    password_reset_ttl_s: i64 = 3600,
    /// Server-side OAuth `state` CSRF protection (F11). ON by default: the backend
    /// issues a `state` via the oauth2 method initiate call and verifies+consumes it on
    /// complete. Set ZIGBASE_OAUTH_STATE_SERVER=false to opt out (client-driven state only).
    oauth_state_server: bool = true,
    oauth_state_ttl_s: i64 = 600,
    realtime_allowed_origins: []const u8 = "",
    /// SSE heartbeat interval seconds (#188); 0 = inherit the listener ws_timeout tick.
    /// Applied per-connection via http_sse_set_timout at stream open. Startup-validated.
    sse_heartbeat_seconds: u8 = 0,
    /// When false (default), client-IP logic ignores X-Forwarded-For/X-Real-IP and
    /// keys on the real socket peer. Only honor proxy headers when true (behind a
    /// trusted reverse proxy). See F8.
    trust_proxy: bool = false,
    max_upload_size: u64 = 50 << 20,
    file_token_ttl_s: i64 = 120,
    sentry_dsn: []const u8 = "", // "" = log errors to stderr; set to enable Sentry reporting
    public_url: []const u8 = "",
    /// Static-file source resolved by framework.serveImpl (.none = no static serving).
    static_source: @import("static_files.zig").Source = .none,
    /// §C.2: resolved Cache-Control value for STATIC serving only (flag/env wins over
    /// the comptime default). null = knob unset — server.zig's `listen()` then never
    /// registers the FIO_CALL_PRE_START swap, so facil.io's stock `max-age=3600` stays
    /// byte-identical to today. Never touches record-file downloads (api/files.zig).
    static_cache_control: ?[]const u8 = null,
    /// Tier-2 comptime static rewrites (issue #183), lowered from `App(.{ .static_routes })`
    /// by framework.zig and threaded here by serveImpl. Comptime constant slice
    /// (static lifetime); empty = no routes.
    static_routes: []const @import("static_files.zig").StaticRoute = &.{},
    /// Tier-1 `.spa` marker roots (issue #183) — EMBEDDED source only: startup-derived
    /// root-relative prefixes ("" = the static root), sorted longest-first. Owned/freed
    /// by serveImpl; empty = marker disabled, no markers, or a dir-mode source (dir mode
    /// resolves markers LIVE per request instead — see `spa_marker_enabled` and
    /// `static_files.resolveSpaMarkerDirLive`).
    spa_roots: []const []const u8 = &.{},
    /// Tier-1 `.spa` marker enablement (issue #183), mirrors comptime `enable_spa_marker`.
    /// Gates BOTH the embedded `spa_roots` match and the dir-mode live filesystem
    /// resolution — false means a `.spa` is just another never-served dotfile.
    spa_marker_enabled: bool = false,
    storage: ?*const @import("files/storage.zig").Storage = null,
    /// Pluggable mailer (resolved from the comptime mailer plugin in serveImpl).
    /// Default = LogMailer (logs); set SMTP config to upgrade to SmtpMailer. null in
    /// tests/CLI where no mailer was wired (callers must fall back to logging).
    mailer: ?*const @import("mail/mailer.zig").Mailer = null,
    /// Email-subsystem runtime knobs (#154), threaded from the comptime `App(.{ .mail = ... })`
    /// config in serveImpl. Default `.{}` is the fully-off, byte-identical-to-pre-#154 path:
    /// verified-sender + suppression enforcement are disabled and the bounce/complaint webhook
    /// route is 404 until a `webhook_secret` is configured. So an app that only calls the existing
    /// mailer is completely unaffected by this subsystem.
    mail: @import("mail/config.zig").Runtime = .{},
    /// Resolved pagination knobs (offset/cursor enablement + cursor token format), threaded from
    /// the comptime `App(.{ .pagination = ... })` config in framework.serveImpl. Defaults match
    /// the stock binary: both modes enabled, stateless tokens.
    pagination: pagination.Runtime = .{},
    /// Resolved multi-tenancy knobs (#156), threaded from the comptime `App(.{ .tenancy = ... })`
    /// config in serveImpl. Default `.enabled = false` is the byte-identical no-tenancy path: the
    /// per-request resolver is skipped and `tenancy.scopePredicate` is a no-op.
    tenancy: tenancy_mod.Runtime = .{},
    /// Role total-order (#155/#156) used to compare a membership role against an ability's
    /// `.min_role`. Threaded from the comptime `.tenancy.roles` config (default ladder otherwise)
    /// and copied onto each request's `RequestContext.role_ranking` by `buildContext`.
    role_ranking: @import("tenancy/roles.zig").Ranking = .{},
    /// Type-erased event dispatch built by the comptime App(cfg) builder; null = no subscribers.
    dispatch: ?*const @import("events.zig").Dispatch = null,
    /// Declared feature-flag + experiment registry (lowered at comptime from the
    /// `App(.{ .flags, .experiments })` config and pointed here by serveImpl; #128/#129/#130).
    /// Drives `ctx.flagByName` / `ctx.flags().resolveAll` and the typed `App.flag`/`App.experiment`
    /// accessors. null = no registry wired (tests/CLI constructing App directly).
    features: ?*const features.Registry = null,
    /// TTL in DAYS for sticky `_experiment_assignments` rows (#129); read by the
    /// comptime-gated `_experiment_gc` job. Set by serveImpl from the comptime config
    /// (`.experiment_assignment_ttl`, default 90). Only consulted when a `.sticky`
    /// experiment is declared (otherwise the GC job is never installed).
    experiment_assignment_ttl: u32 = 90,
    /// Mount path for the public feature-state projection (`GET <path>?subject=`,
    /// served by `api/state.zig`); null = disabled. Lowered from the `.features`
    /// config knob and set by serveImpl. Default "/api/state" (auto-mounted).
    features_public_route: ?[]const u8 = "/api/state",
    /// In-memory rate limiter for sensitive auth endpoints; null = disabled
    /// (rate_limit_max == 0, or tests/CLI that don't wire it). Set in serveImpl.
    rate_limiter: ?*ratelimit.RateLimiter = null,
    /// Type-erased pointer to the lowered queue/worker/job `Registry` (#137 PR2), set by
    /// serveImpl from the comptime `.queues`/`.workers`/`.jobs` config. Drives
    /// `ctx.enqueue`/`App.enqueue` (route by backend) and the durable poller/GC jobs.
    /// Stored as opaque (cast to `*const @import("queue/queue.zig").Registry`) to avoid an
    /// app.zig→queue→ctx→app import cycle, mirroring `auth_methods`. null = no registry
    /// wired (tests/CLI constructing App directly).
    queues: ?*const anyopaque = null,
    /// Type-erased pointer to the lowered analytics rollup `Registry` (#158), set by serveImpl from
    /// the comptime `.analytics` config. Drives the per-rollup scheduled aggregation job and the
    /// `/api/analytics/rollups/:name` read endpoint. Stored opaque (cast to
    /// `*const @import("analytics/analytics.zig").Registry`) to avoid an app→analytics import cycle,
    /// mirroring `queues`. null = no `.analytics` config (events still capture; no rollups scheduled).
    analytics: ?*const anyopaque = null,
    /// Type-erased pointer to the running auth-method Registry (set by serveImpl); null = not running.
    /// Cast to `*const @import("auth/registry.zig").Registry` to read slugs. Stored as opaque
    /// to avoid an import cycle: app.zig must NOT import registry.zig or auth/method.zig.
    auth_methods: ?*const anyopaque = null,
    /// The CAPTCHA provider configured via `App(.{ .captcha = .{ .provider = ..., .secret = "..." } })`.
    /// null = captcha not configured (ctx.verifyCaptcha uses the dev-bypass — ok=true — when secret is "").
    captcha_provider: ?captcha.Provider = null,
    /// The configured CAPTCHA site-verify secret (the server-side key sent to the provider).
    /// Empty string = dev-bypass mode: ctx.verifyCaptcha returns .{.ok=true} without any network call.
    captcha_secret: []const u8 = "",
    /// Type-erased pointer to the running Scheduler (set by Scheduler.start); null = not running.
    scheduler: ?*anyopaque = null,
    /// Type-erased pointer to the running memory-queue worker Pool (`queue/memory.zig`),
    /// set by `Pool.install` in serveImpl; null = not serving (tests/CLI). Memory-backend
    /// `ctx.enqueue` jobs AND `app.submit` tasks run on this bounded, shutdown-joined pool.
    memory_pool: ?*anyopaque = null,
    /// Submit an ad-hoc job task for async execution; set by `queue/memory.zig` Pool.install.
    submit_fn: ?*const fn (ctx: *anyopaque, name: []const u8, task: @import("events.zig").JobTask) anyerror!void = null,
    /// The collection-metadata cache (colcache.zig), installed by serveImpl for the
    /// SQLite backend only (single-process ⇒ the in-process invalidation contract holds;
    /// on Postgres another instance could run DDL unseen, so reads stay direct). null =
    /// uncached (tests/CLI/Postgres) — colcache.lease falls back to a direct load.
    col_cache: ?*@import("colcache.zig").Cache = null,

    /// Submit an ad-hoc job task for async execution on the bounded background pool
    /// (queue/memory.zig Pool — shared with memory-queue jobs). Set by Pool.install in
    /// serveImpl, so it is available whenever the server is running (0.10.0: previously it
    /// required a configured scheduler). Tasks queued before shutdown are DRAINED and the
    /// workers JOINED — a task submitted near shutdown completes (at-most-once across a
    /// crash). Returns error.SchedulerUnavailable when no pool is installed (unit tests /
    /// CLI — the historical error name is kept for compatibility) and error.QueueFull when
    /// the bounded ring is full (reject-not-block; see queue/memory.zig for the policy).
    pub fn submit(self: *App, name: []const u8, task: @import("events.zig").JobTask) !void {
        const f = self.submit_fn orelse return error.SchedulerUnavailable;
        return f(self.memory_pool.?, name, task);
    }
};
