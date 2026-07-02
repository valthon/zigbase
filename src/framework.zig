const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const static_files = @import("static_files.zig");
const app_mod = @import("app.zig");
const events = @import("events.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const server = @import("server.zig");
const migrations = @import("migrations.zig");
const files_storage = @import("files/storage.zig");
const db = @import("db.zig");
const crypto = @import("crypto.zig");
const id_gen = @import("id.zig");
const scheduler = @import("scheduler.zig");
const schedule = @import("schedule.zig");
const clock = @import("clock.zig");
const entropy_mod = @import("entropy.zig");
const mail = @import("mail/mailer.zig");
const provision = @import("provision.zig");
const schema = @import("schema.zig");
const ratelimit = @import("ratelimit.zig");
const pagination = @import("pagination.zig");
const registry = @import("auth/registry.zig");
const field_policy = @import("field_policy.zig");
const rewrap = @import("rewrap.zig");
const features = @import("features.zig");
const ctx_mod = @import("ctx.zig");
const queue = @import("queue/queue.zig");
const queue_config = @import("queue/config.zig");
const queue_durable = @import("queue/durable.zig");
const mail_send = @import("mail/send.zig");
const mail_cfg = @import("mail/config.zig");
const webhook = @import("webhook.zig");
const captcha = @import("captcha.zig");
const tenancy = @import("tenancy/tenancy.zig");
const roles = @import("tenancy/roles.zig");
const abilities_mod = @import("authz/abilities.zig");
const analytics = @import("analytics/analytics.zig");
const analytics_config = @import("analytics/config.zig");

/// True if any collection declares an `.encrypted` field (Theme B1). Drives the
/// fail-closed startup check (refuse to serve without ZIGBASE_FIELD_KEY).
fn anyEncryptedField(cols: []const schema.Collection) bool {
    for (cols) |c| if (schema.hasEncryptedField(c)) return true;
    return false;
}

/// Startup fail-closed detection for RUNTIME-created encrypted fields (#102). The comptime
/// guard (`anyEncryptedField` over the `.collections` literal) cannot see a collection
/// whose encrypted field was created at runtime via the superuser collections API. After
/// provisioning has settled the live schema, scan the DB-resident collections and return
/// the name of the first one declaring an encrypted field (or null if none) — the caller
/// (serveImpl) turns a non-null result into a logged `error.FieldKeyRequired` refusal when
/// no cipher is configured. The value layer also fails closed on read/write, so plaintext
/// never leaks; this just turns a silently half-broken server into a loud startup refusal.
/// The returned slice is owned by `arena`. Logging lives in the caller so this stays a
/// pure, unit-testable scan (a `.err` log would otherwise fail the test runner).
fn liveEncryptedCollection(arena: std.mem.Allocator, w: *db.Db) !?[]const u8 {
    const live = try @import("collections.zig").list(arena, w);
    for (live) |c| if (schema.hasEncryptedField(c)) return c.name;
    return null;
}

// ============================================================================
// Comptime plugins (storage + mailer)
// ----------------------------------------------------------------------------
// A *plugin* is a comptime TYPE selected via `App(.{ .storage = T, .mailer = T })`
// and instantiated in serveImpl. Both contracts are uniform:
//
//   pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !Self;
//   pub fn interface(self: *Self) <Storage|Mailer>;  // returns the vtable view
//   pub fn deinit(self: *Self) void;                 // release any owned resources
//
// `create` builds the backend from runtime config; `interface` returns the
// type-erased vtable handle stored on `App`; `deinit` tears it down. The instance
// is a serveImpl stack var that outlives the server (the vtable points at it).
//
// Defaults below reproduce the historical wiring: LocalStorage rooted at
// <data_dir>/storage, and a mailer that logs (LogMailer) unless SMTP is
// configured, in which case it speaks SMTP (SmtpMailer). A consumer overrides
// either by supplying their own comptime type implementing the same contract.
// ============================================================================

/// Default storage plugin: wraps `LocalStorage` rooted at `<data_dir>/storage`,
/// reproducing the pre-plugin file wiring. Owns the heap-allocated root string.
pub const DefaultStoragePlugin = struct {
    gpa: std.mem.Allocator,
    root: []const u8,
    backend: files_storage.LocalStorage,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !DefaultStoragePlugin {
        _ = io;
        const root = try std.fmt.allocPrint(gpa, "{s}/storage", .{cfg.data_dir});
        return .{ .gpa = gpa, .root = root, .backend = files_storage.LocalStorage.init(root) };
    }

    pub fn interface(self: *DefaultStoragePlugin) files_storage.Storage {
        return self.backend.storage();
    }

    pub fn deinit(self: *DefaultStoragePlugin) void {
        self.gpa.free(self.root);
    }
};

/// Default mailer plugin, config-driven with a fixed precedence and no code
/// change to switch between backends:
///   1. `cfg.sendmail_command` non-empty → `CommandMailer` (pipe to a local MTA).
///   2. else `cfg.smtp_host` non-empty   → `SmtpMailer` (direct SMTP/TLS).
///   3. else                             → `LogMailer` (logs; dev/CI default).
pub const DefaultMailerPlugin = struct {
    log_backend: mail.LogMailer = .{},
    smtp_backend: ?mail.SmtpMailer = null,
    command_backend: ?mail.CommandMailer = null,
    /// Owned argv parsed from `cfg.sendmail_command`; freed in `deinit`.
    command_argv: ?[][]const u8 = null,
    gpa: std.mem.Allocator = undefined,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !DefaultMailerPlugin {
        _ = io;
        if (cfg.sendmail_command.len > 0) {
            const argv = try parseCommand(gpa, cfg.sendmail_command);
            errdefer gpa.free(argv);
            if (argv.len == 0) return error.EmptySendmailCommand;
            return .{
                .gpa = gpa,
                .command_argv = argv,
                .command_backend = mail.CommandMailer.init(argv, cfg.smtp_from),
            };
        }
        if (cfg.smtp_host.len == 0) return .{ .gpa = gpa };
        return .{ .gpa = gpa, .smtp_backend = mail.SmtpMailer.initTls(
            cfg.smtp_host,
            cfg.smtp_port,
            cfg.smtp_username,
            cfg.smtp_password,
            cfg.smtp_from,
            cfg.smtp_tls,
            cfg.smtp_insecure_skip_verify,
        ) };
    }

    pub fn interface(self: *DefaultMailerPlugin) mail.Mailer {
        if (self.command_backend) |*c| return c.mailer();
        if (self.smtp_backend) |*s| return s.mailer();
        return self.log_backend.mailer();
    }

    pub fn deinit(self: *DefaultMailerPlugin) void {
        if (self.command_argv) |argv| self.gpa.free(argv);
    }

    /// Split a command string into argv on ASCII whitespace runs (no quoting —
    /// argv elements with embedded spaces aren't expressible this way; a consumer
    /// needing that supplies a `CommandMailer` directly via `.mailer = T`). The
    /// returned slice borrows `cmd`'s bytes (which live in the config), so only
    /// the outer slice is heap-allocated.
    fn parseCommand(gpa: std.mem.Allocator, cmd: []const u8) ![][]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
        while (it.next()) |tok| try parts.append(gpa, tok);
        return parts.toOwnedSlice(gpa);
    }
};

/// True iff a value of type `M` coerces to `[]const provision.Migration` — i.e. it is
/// the slice itself or a pointer to an array of `Migration` (`&[_]Migration{ ... }`).
/// A bare anonymous tuple (`.{ .{ ... } }`) does NOT, which is the footgun P2-b guards.
fn migrationsCoerce(comptime M: type) bool {
    if (M == []const provision.Migration) return true;
    const info = @typeInfo(M);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size == .slice) return ptr.child == provision.Migration;
    if (ptr.size == .one) {
        const child = @typeInfo(ptr.child);
        return child == .array and child.array.child == provision.Migration;
    }
    return false;
}

/// Comptime grammar check for one `.static_routes` match pattern (issue #183):
/// leading '/'; segments are literals, ':name' (one segment), or a TERMINAL '*'
/// (one-or-more) / '**' (zero-or-more); wildcards/':' never mix with literal text.
/// Rejecting a non-terminal '*'/'**' here is load-bearing: `static_files.matchRoute`
/// short-circuits at the FIRST '*'/'**' segment it sees (by design, for O(1) rest-match)
/// and does not check any pattern segments after it — an unvalidated pattern like
/// "/a/**/x" would silently match every path under "/a/", ignoring "/x" entirely.
fn validateRoutePattern(comptime m: []const u8) void {
    if (m.len == 0 or m[0] != '/')
        @compileError(".static_routes: match pattern '" ++ m ++ "' must start with '/'");
    if (m.len == 1) return; // "/" — the bare root literal
    var it = std.mem.splitScalar(u8, m[1..], '/');
    var rest_seen = false;
    while (it.next()) |seg| {
        if (rest_seen)
            @compileError(".static_routes: '*'/'**' must be the FINAL segment in '" ++ m ++ "'");
        if (seg.len == 0)
            @compileError(".static_routes: empty segment ('//' or trailing '/') in '" ++ m ++ "'");
        if (std.mem.eql(u8, seg, "*") or std.mem.eql(u8, seg, "**")) {
            rest_seen = true;
            continue;
        }
        if (std.mem.indexOfScalar(u8, seg, '*') != null)
            @compileError(".static_routes: '*' cannot mix with literal text in segment '" ++ seg ++ "' of '" ++ m ++ "'");
        if (seg[0] == ':') {
            if (seg.len == 1)
                @compileError(".static_routes: ':' needs a name in '" ++ m ++ "'");
            continue;
        }
        if (std.mem.indexOfScalar(u8, seg, ':') != null)
            @compileError(".static_routes: ':' must start its own segment in '" ++ m ++ "' (got '" ++ seg ++ "')");
    }
}

/// Comptime check for one `.static_routes` serve target: a fixed leading-'/' path,
/// no ':'/'*' and no '..' (targets are trusted literals interpolated into the
/// static source, so wildcards and traversal are rejected outright). No empty segments
/// either (`//`/trailing `/`) — final-review symmetry fix: `validateRoutePattern` above
/// already rejects those in `match`, but a `serve` target like "/app//x" or "/app/" used
/// to slip through here; embedded mode's `manifestHas` comptime lookup would then simply
/// miss (a proper compile error, just a confusing one), while dir mode's
/// `validateRouteTargetsDir` builds the on-disk path with a literal double slash /
/// trailing slash and gets an inconsistent pass/fail depending on the OS's stat()
/// tolerance for those forms. Rejecting both shapes here at comptime removes that
/// discrepancy for both sources.
fn validateServeTarget(comptime sv: []const u8) void {
    if (sv.len == 0 or sv[0] != '/')
        @compileError(".static_routes: serve target '" ++ sv ++ "' must start with '/'");
    if (std.mem.indexOfScalar(u8, sv, ':') != null or std.mem.indexOfScalar(u8, sv, '*') != null)
        @compileError(".static_routes: serve target '" ++ sv ++ "' must be a fixed path (no ':' or '*')");
    if (sv.len > 1) {
        var it = std.mem.splitScalar(u8, sv[1..], '/');
        while (it.next()) |seg| {
            if (seg.len == 0)
                @compileError(".static_routes: empty segment ('//' or trailing '/') in serve target '" ++ sv ++ "'");
            if (std.mem.eql(u8, seg, ".."))
                @compileError(".static_routes: serve target '" ++ sv ++ "' must not contain '..'");
        }
    }
}

/// Comptime manifest membership test for embedded serve-target validation.
fn manifestHas(files: []const static_files.StaticFile, path: []const u8) bool {
    for (files) |f| if (std.mem.eql(u8, f.path, path)) return true;
    return false;
}

/// `@compileError` unless plugin type `P` (selected via `.storage`/`.mailer`) declares
/// the three contract methods. Without this, a missing method surfaces as a generic
/// "no member named 'deinit'" at the instantiation site rather than a contract message.
fn assertPluginContract(comptime P: type, comptime kind: []const u8) void {
    inline for (.{ "create", "interface", "deinit" }) |decl| {
        if (!@hasDecl(P, decl)) {
            @compileError("'." ++ kind ++ "' plugin type '" ++ @typeName(P) ++ "' is missing the '" ++ decl ++
                "' method; a plugin must declare create(gpa, io, cfg) !Self / interface(*Self) view / deinit(*Self) void");
        }
    }
}

/// Comptime application builder. `cfg` is an anonymous struct VALUE with optional
/// `.hooks` (record hook groups) and optional `.onError` (an ErrorHandler).
/// Returns a type exposing the prebuilt `dispatch` and the CLI/serve entry points.
pub fn App(comptime cfg: anytype) type {
    return struct {
        /// Prebuilt at comptime; the runtime app holds a pointer to it (static lifetime).
        pub const dispatch: events.Dispatch = blk: {
            // Headroom: this block validates every cfg key against `allowed` (a growing
            // list) AND runs the hook-typo guard (`validateHooks`), all on one comptime
            // budget — a large consumer config (many hooks + cfg keys) can otherwise trip
            // the default 1000-branch limit inside `validateHooks`.
            @setEvalBranchQuota(20_000);
            // Guard top-level cfg keys so a typo (e.g. `.hook`, `.on_error`) fails
            // loudly at comptime instead of silently producing an empty Dispatch.
            const allowed = .{ "hooks", "onError", "routes", "onAuth", "beforeAuthSuccess", "auth", "onFileServe", "onFileUpload", "onBootstrap", "onBeforeServe", "onBeforeTerminate", "cron", "jobs", "storage", "mailer", "pools", "collections", "migrations", "static_files", "pagination", "enable_typegen", "auth_methods", "session_store", "session_gc_cron", "flags", "experiments", "features", "onFeatureExposure", "experiment_assignment_ttl", "queues", "workers", "captcha", "realtime", "tenancy", "abilities", "mail", "analytics", "static_routes", "enable_spa_marker" };
            const allowed_list = blk2: {
                var s: []const u8 = "";
                for (allowed, 0..) |name, i| s = s ++ (if (i == 0) "" else "/") ++ name;
                break :blk2 s;
            };
            for (std.meta.fields(@TypeOf(cfg))) |f| {
                var ok = false;
                for (allowed) |name| {
                    if (std.mem.eql(u8, f.name, name)) ok = true;
                }
                if (!ok) @compileError("unknown App cfg field '" ++ f.name ++ "'; expected one of " ++ allowed_list);
            }
            var d = events.Dispatch{};
            if (@hasField(@TypeOf(cfg), "hooks")) d.record = events.buildRecordDispatcher(cfg.hooks);
            if (@hasField(@TypeOf(cfg), "onError")) d.on_error = cfg.onError;
            if (@hasField(@TypeOf(cfg), "routes")) d.routes = events.buildRoutes(cfg.routes);
            if (@hasField(@TypeOf(cfg), "onAuth")) d.on_auth = cfg.onAuth;
            if (@hasField(@TypeOf(cfg), "beforeAuthSuccess")) d.before_auth_success = cfg.beforeAuthSuccess;
            // Only install the lifecycle dispatcher when the `.auth` group has ≥1 hook — an
            // empty `.auth = .{}` must NOT make `hasAuthLifecycle()` true (that would force
            // authLogout onto the writer+authenticate path for nothing).
            if (@hasField(@TypeOf(cfg), "auth") and std.meta.fields(@TypeOf(cfg.auth)).len > 0)
                d.auth_lifecycle = events.buildAuthLifecycleDispatcher(cfg.auth);
            if (@hasField(@TypeOf(cfg), "onFileServe")) d.on_file_serve = cfg.onFileServe;
            if (@hasField(@TypeOf(cfg), "onFileUpload")) d.on_file_upload = cfg.onFileUpload;
            if (@hasField(@TypeOf(cfg), "onBootstrap")) d.on_bootstrap = cfg.onBootstrap;
            if (@hasField(@TypeOf(cfg), "onBeforeServe")) d.on_before_serve = cfg.onBeforeServe;
            if (@hasField(@TypeOf(cfg), "onBeforeTerminate")) d.on_before_terminate = cfg.onBeforeTerminate;
            if (@hasField(@TypeOf(cfg), "onFeatureExposure")) d.on_feature_exposure = cfg.onFeatureExposure;
            // Consumer realtime broadcast guard (#143). `.realtime = .{ .canSubscribe = fn }`
            // installs a predicate gating subscription to NON-collection custom topics; an
            // unknown sub-key fails loudly (mirrors the `.features` guard). Absent → custom
            // topics default to public signal channels (the historical `__features` behavior).
            if (@hasField(@TypeOf(cfg), "realtime")) {
                const rcfg = cfg.realtime;
                if (@typeInfo(@TypeOf(rcfg)) != .@"struct")
                    @compileError(".realtime must be a struct, e.g. '.{ .canSubscribe = fn }'");
                for (std.meta.fields(@TypeOf(rcfg))) |f| {
                    if (!std.mem.eql(u8, f.name, "canSubscribe"))
                        @compileError(".realtime: unknown key '." ++ f.name ++ "' (recognized: .canSubscribe)");
                }
                if (@hasField(@TypeOf(rcfg), "canSubscribe")) {
                    const _coerce: events.RealtimeCanSubscribeFn = rcfg.canSubscribe;
                    _ = _coerce;
                    d.realtime_can_subscribe = rcfg.canSubscribe;
                }
            }
            break :blk d;
        };

        /// The consumer's cron/interval/reactive job table (empty when no `.cron`).
        const user_jobs: []const scheduler.RuntimeJob = if (@hasField(@TypeOf(cfg), "cron")) scheduler.buildJobs(cfg.cron) else &.{};

        /// True when ANY comptime collection opts into TTL (`.ttl_field`). Gates the
        /// framework-internal `_ttl_gc` job and the startup one-shot sweep.
        pub const has_ttl_collection: bool = blk: {
            for (collections) |col| if (col.options.ttl_field != null) break :blk true;
            break :blk false;
        };

        /// TTL sweep job (when any collection opts into `.ttl_field`), else empty.
        const ttl_jobs: []const scheduler.RuntimeJob = if (has_ttl_collection)
            scheduler.buildJobs(.{
                .{ .name = "_ttl_gc", .schedule = schedule.Schedule{ .interval = .{ .minutes = 5 } }, .handler = ttlGcJob },
            })
        else
            &.{};

        /// Expired-`_sessions` GC sweep (#114) — auto-installed ONLY in table mode, so `.epoch`
        /// installs no job/timer/writer touch (the zero-overhead guarantee). Cadence comes from
        /// `.session_gc_cron` (default hourly, `"0 * * * *"`).
        const session_gc_jobs: []const scheduler.RuntimeJob = if (session_store_config == .table)
            scheduler.buildJobs(.{
                .{ .name = "_session_gc", .schedule = schedule.Schedule{ .cron = session_gc_cron }, .handler = sessionGcJob },
            })
        else
            &.{};

        /// True when ANY declared experiment opts into sticky persistence (`.sticky = true`).
        /// Gates the framework-internal `_experiment_gc` job — pure-hash-only apps install no
        /// job/timer/writer touch (the zero-overhead guarantee, mirroring session GC).
        pub const has_sticky_experiment: bool = blk: {
            for (experiments) |e| if (e.sticky) break :blk true;
            break :blk false;
        };

        /// Sticky-assignment GC sweep (#129) — auto-installed ONLY when a `.sticky` experiment
        /// is declared, so pure-hash apps install no job/timer/writer touch. Hourly cadence;
        /// reaps `_experiment_assignments` rows older than `.experiment_assignment_ttl`.
        const experiment_gc_jobs: []const scheduler.RuntimeJob = if (has_sticky_experiment)
            scheduler.buildJobs(.{
                .{ .name = "_experiment_gc", .schedule = schedule.Schedule{ .cron = "0 * * * *" }, .handler = experimentGcJob },
            })
        else
            &.{};

        // ── Background jobs & queues (#137 PR2) ────────────────────────────────
        // The comptime `.queues`/`.workers`/`.jobs` config lowered into runtime slices,
        // plus the generated `Queue`/`Job` enums (so `App.enqueue(ctx, .q, .kind, …)` is
        // compile-checked). `.default` is always synthesized; absent `.workers` yields one
        // implicit worker over all queues (strict priority). `app.queues` points at
        // `queue_registry`. The durable poller + GC jobs are installed ONLY when a durable
        // queue is declared (pure-memory and no-queue apps install nothing — zero overhead).

        /// Declared queues (always includes a synthesized `.default`).
        pub const queue_defs: []const queue.QueueDef =
            queue_config.queueMeta(if (@hasField(@TypeOf(cfg), "queues")) cfg.queues else .{});

        /// Declared workers (or the implicit single all-queues worker when `.workers` is absent).
        pub const worker_defs: []const queue.WorkerDef =
            queue_config.workerMeta(if (@hasField(@TypeOf(cfg), "workers")) cfg.workers else .{}, queue_defs);

        /// Framework-owned built-in job kinds, prepended to the consumer `.jobs` registry
        /// below. `"mail"` (#141) backs `ctx.mail().enqueue` — a `"mail"` job deserializes
        /// the `MailMessage` payload and delivers it via `mail/send.zig`. Kept as its own
        /// const so sibling PRs (e.g. webhook, #144) can add their built-ins self-contained.
        const builtin_job_regs: []const queue.JobReg = &.{
            .{ .kind = "mail", .handler = mail_send.jobHandler },
            .{ .kind = webhook.job_kind, .handler = webhook.webhookJobHandler },
        };

        /// Names of the reserved built-in kinds, derived from `builtin_job_regs` so the
        /// collision guard below automatically covers every current AND future built-in.
        const reserved_job_kinds: []const []const u8 = blk: {
            var names: [builtin_job_regs.len][]const u8 = undefined;
            for (builtin_job_regs, 0..) |r, i| names[i] = r.kind;
            const frozen = names;
            break :blk &frozen;
        };

        /// Declared job-kind → handler registry: the built-in kinds followed by the consumer
        /// `.jobs` bindings (the reserved `.jobs.pool_size` key is skipped). `jobByKind`
        /// resolves built-ins first so `"mail"` always reaches the framework handler — and the
        /// `assertNoReservedJobKinds` guard rejects a consumer `.jobs` entry that would collide
        /// with a built-in kind (it would be dead config, never dispatched).
        pub const job_regs: []const queue.JobReg = blk: {
            const consumer_jobs = if (@hasField(@TypeOf(cfg), "jobs")) cfg.jobs else .{};
            queue_config.assertNoReservedJobKinds(consumer_jobs, reserved_job_kinds);
            break :blk builtin_job_regs ++ queue_config.jobsMeta(consumer_jobs);
        };

        /// Enum of declared queue names — the compile-checked key for `App.enqueue`.
        pub const Queue = queue_config.QueueEnum(if (@hasField(@TypeOf(cfg), "queues")) cfg.queues else .{});

        /// Enum of declared job kinds — the compile-checked kind for `App.enqueue`.
        pub const Job = queue_config.JobEnum(if (@hasField(@TypeOf(cfg), "jobs")) cfg.jobs else .{});

        /// Static lowered registry threaded (type-erased) into `app.queues` by serveImpl.
        pub const queue_registry: queue.Registry = .{ .queues = queue_defs, .workers = worker_defs, .jobs = job_regs };

        /// True when any declared queue is durable — gates the poller + GC jobs.
        pub const has_durable_queue: bool = queue_registry.hasDurable();

        /// Number of workers that drain at least one durable queue (each gets a poller).
        const durable_worker_count: usize = blk: {
            var c: usize = 0;
            for (worker_defs) |w| if (queue_registry.workerHasDurable(w)) {
                c += 1;
            };
            break :blk c;
        };

        /// One reactive poller job per durable worker (`_queue:<worker>`), claiming +
        /// dispatching its durable queues' ready jobs each cycle. Empty when no durable queue.
        const queue_worker_jobs: []const scheduler.RuntimeJob = blk: {
            if (durable_worker_count == 0) break :blk &.{};
            const Holder = struct {
                const table: [durable_worker_count]scheduler.RuntimeJob = tbl: {
                    var t: [durable_worker_count]scheduler.RuntimeJob = undefined;
                    var i: usize = 0;
                    for (worker_defs) |w| {
                        if (!queue_registry.workerHasDurable(w)) continue;
                        t[i] = .{ .name = "_queue:" ++ w.name, .schedule = schedule.Schedule.reactive, .run = queueWorkerRun };
                        i += 1;
                    }
                    break :tbl t;
                };
            };
            break :blk &Holder.table;
        };

        /// Hourly durable-queue GC + reclaim sweep (`_queue_gc`); empty when no durable queue.
        const queue_gc_jobs: []const scheduler.RuntimeJob = if (has_durable_queue)
            scheduler.buildJobs(.{
                .{ .name = "_queue_gc", .schedule = schedule.Schedule{ .cron = "0 * * * *" }, .handler = queueGcJob },
            })
        else
            &.{};

        // ── Product analytics (#158) ───────────────────────────────────────────
        // The comptime `.analytics = .{ .rollups = .{ … } }` config lowered into runtime rollup
        // specs (validated by analytics_config), plus one scheduled aggregation job per rollup
        // (`_rollup:<name>`, cadence = the rollup's `.every`). `app.analytics` points at
        // `analytics_registry`. Absent `.analytics` → no specs, no jobs: `_events` still captures
        // via `ctx.track`, but nothing is scheduled (zero overhead).

        /// Declared rollup specs (empty when no `.analytics`).
        pub const analytics_rollups: []const analytics.RollupSpec =
            if (@hasField(@TypeOf(cfg), "analytics")) analytics_config.rollupSpecs(cfg.analytics) else &.{};

        /// Static lowered registry threaded (type-erased) into `app.analytics` by serveImpl.
        pub const analytics_registry: analytics.Registry = .{ .rollups = analytics_rollups };

        /// One non-reactive aggregation job per rollup (`_rollup:<name>`), scheduled on the
        /// rollup's `.every` cadence. Empty when no rollup is declared. The handler resolves the
        /// spec by `ev.name` from `app.analytics` (mirrors the durable-queue worker poller).
        const analytics_jobs: []const scheduler.RuntimeJob = blk: {
            if (analytics_rollups.len == 0) break :blk &.{};
            const Holder = struct {
                const table: [analytics_rollups.len]scheduler.RuntimeJob = tbl: {
                    var t: [analytics_rollups.len]scheduler.RuntimeJob = undefined;
                    for (analytics_rollups, 0..) |r, i| t[i] = .{
                        .name = "_rollup:" ++ r.name,
                        .schedule = r.every,
                        .run = analyticsRollupRun,
                    };
                    break :tbl t;
                };
            };
            break :blk &Holder.table;
        };

        /// Framework-internal jobs: the TTL sweep, the session-GC sweep, the sticky-
        /// assignment GC sweep, the durable-queue worker pollers, the durable-queue GC
        /// sweep, and the analytics rollup aggregation jobs — each gated on its own
        /// condition. Appended after the consumer's jobs so user `.cron` names win the
        /// lower indices, and an internal job runs even with no user cron.
        const internal_jobs: []const scheduler.RuntimeJob = scheduler.concatJobs(
            scheduler.concatJobs(
                scheduler.concatJobs(
                    scheduler.concatJobs(scheduler.concatJobs(ttl_jobs, session_gc_jobs), experiment_gc_jobs),
                    queue_worker_jobs,
                ),
                queue_gc_jobs,
            ),
            analytics_jobs,
        );

        /// The full job table = consumer jobs ++ framework-internal jobs. The scheduler
        /// starts whenever this is non-empty, so a TTL collection alone starts it.
        pub const jobs: []const scheduler.RuntimeJob = scheduler.concatJobs(user_jobs, internal_jobs);
        /// Worker pool size for the scheduler. Precedence: `.pools.jobs` (the new
        /// unified lever), then the legacy `.jobs.pool_size`, then the default 2.
        pub const job_pool_size: usize = blk: {
            if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "jobs")) break :blk cfg.pools.jobs;
            if (@hasField(@TypeOf(cfg), "jobs") and @hasField(@TypeOf(cfg.jobs), "pool_size")) break :blk cfg.jobs.pool_size;
            break :blk 2;
        };

        /// Comptime warm-reader-pool cap (the `.pools.readers` lever). Defaults to 16,
        /// the historical hardcoded value; shrink it to reduce the connection footprint.
        pub const reader_pool_size: usize = if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "readers")) cfg.pools.readers else 16;

        /// Whether to compile the `typegen` CLI subcommand into the binary.
        /// Off by default so production builds carry no codegen weight.
        pub const enable_typegen: bool = if (@hasField(@TypeOf(cfg), "enable_typegen")) cfg.enable_typegen else false;

        /// Per-thread stack size (bytes) for the scheduler/job-pool/submit threads
        /// (the `.pools.stack_size` lever). Defaults to `scheduler.default_job_stack_size`
        /// (1 MiB), far below `std.Thread`'s 16 MiB default; raise it for unusually deep
        /// job handlers. Clamped up to `scheduler.min_job_stack_size` — a below-floor value
        /// would EINVAL-abort `pthread_create` in the full binary, so the lever can only
        /// raise the stack, never crash the server. Only consumed when jobs are configured.
        pub const job_stack_size: usize = @max(scheduler.min_job_stack_size, if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "stack_size")) cfg.pools.stack_size else scheduler.default_job_stack_size);

        /// Per-connection SQLite page-cache budget in KiB (the `.pools.cache_kib` lever).
        /// Defaults to `db.default_cache_kib` (1024 KiB); shrink it to reduce the page-cache
        /// footprint across the writer + warm readers, or raise it for large working sets.
        pub const cache_kib: u32 = if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "cache_kib")) cfg.pools.cache_kib else db.default_cache_kib;

        /// Comptime-selected storage plugin type (defaults to `DefaultStoragePlugin`).
        /// A custom type missing a contract method fails with a contract-specific message.
        pub const StoragePlugin: type = blk: {
            const P = if (@hasField(@TypeOf(cfg), "storage")) cfg.storage else DefaultStoragePlugin;
            assertPluginContract(P, "storage");
            break :blk P;
        };
        /// Comptime pagination config resolved from `.pagination` (defaults: both modes on,
        /// stateless tokens). `@compileError`s on an unknown sub-field or both modes disabled.
        pub const pagination_config: pagination.Config = pagination.resolve(cfg);

        /// Comptime session-management model resolved from `.session_store` (#99). Defaults
        /// to `.epoch` (stateless token-epoch revocation). `.table` opts into the server-side
        /// `_sessions` store for per-device list/revoke (DESIGNED-but-STUBBED). An unknown
        /// value is a `@compileError`.
        pub const session_store_config: app_mod.SessionStore = blk: {
            if (!@hasField(@TypeOf(cfg), "session_store")) break :blk .epoch;
            const ss = cfg.session_store;
            if (@TypeOf(ss) != @TypeOf(.enum_literal))
                @compileError("session_store: expected the enum literal .epoch or .table");
            if (std.mem.eql(u8, @tagName(ss), "epoch")) break :blk .epoch;
            if (std.mem.eql(u8, @tagName(ss), "table")) break :blk .table;
            @compileError("session_store: unknown value '." ++ @tagName(ss) ++ "'; expected .epoch or .table");
        };

        /// Cadence (UTC, minute-granularity cron) for the table-mode expired-`_sessions` GC
        /// sweep (#114). Default hourly; override with `.session_gc_cron = "..."`. Only consumed
        /// when `.session_store == .table` (otherwise no GC job is installed at all).
        pub const session_gc_cron: []const u8 = blk: {
            // Fail loudly on misuse: setting the cadence without enabling the table store is a
            // silent no-op otherwise (the GC job is only installed in table mode). Only triggers
            // when the user EXPLICITLY set the key — the default-unset case stays fine.
            if (@hasField(@TypeOf(cfg), "session_gc_cron") and session_store_config != .table)
                @compileError("session_gc_cron has no effect without session_store = .table");
            break :blk if (@hasField(@TypeOf(cfg), "session_gc_cron")) cfg.session_gc_cron else "0 * * * *";
        };

        /// Comptime-selected mailer plugin type (defaults to `DefaultMailerPlugin`).
        /// A custom type missing a contract method fails with a contract-specific message.
        pub const MailerPlugin: type = blk: {
            const P = if (@hasField(@TypeOf(cfg), "mailer")) cfg.mailer else DefaultMailerPlugin;
            assertPluginContract(P, "mailer");
            break :blk P;
        };

        /// Comptime-assembled list of auth method TYPES (built-ins ++ consumer types from
        /// `.auth_methods`). Each type in the list is validated against the auth-method
        /// contract (create/method/deinit) at compile time. Used in serveImpl to
        /// instantiate the Registry stack vars.
        pub const auth_method_types: []const type = blk: {
            const am = @import("auth/method.zig");
            const types = registry.assembleTypes(cfg);
            // Validate every method type (built-ins AND consumer types) against the
            // contract, mirroring how assertPluginContract always runs on storage/mailer
            // — so a broken built-in can't silently escape comptime validation either.
            for (types) |T| am.assertAuthMethodContract(T);
            break :blk types;
        };

        /// Comptime static-files mode (see static_files.Mode). Field absent -> .default,
        /// which enables the runtime `--serve-static <dir>` flag on `serve`.
        pub const static_mode: static_files.Mode = blk: {
            if (!@hasField(@TypeOf(cfg), "static_files")) break :blk .default;
            const sf = cfg.static_files;
            const T = @TypeOf(sf);
            if (T == @TypeOf(.enum_literal)) {
                if (std.mem.eql(u8, @tagName(sf), "disabled")) break :blk .disabled;
                @compileError("static_files: unknown value '." ++ @tagName(sf) ++ "'; expected .disabled, .{ .dir = \"<path>\" }, or .{ .embedded = &<manifest>.files }");
            }
            if (@hasField(T, "dir")) break :blk .{ .dir = sf.dir };
            if (@hasField(T, "embedded")) {
                // Coerce the generated manifest's structurally-identical struct type
                // into static_files.StaticFile (the generated module can't import it).
                const src = sf.embedded;
                var out: [src.len]static_files.StaticFile = undefined;
                for (src, 0..) |f, i| out[i] = .{ .path = f.path, .bytes = f.bytes, .etag = f.etag };
                const final = out;
                break :blk .{ .embedded = &final };
            }
            @compileError("static_files: expected .disabled, .{ .dir = \"<path>\" }, or .{ .embedded = &<manifest>.files }");
        };

        /// Tier-2 comptime static rewrites (issue #183): `.static_routes` lowered into a
        /// typed slice (empty when absent). Validates entry shape + pattern grammar with
        /// loud @compileErrors; in `.embedded` mode also proves every serve target exists
        /// in the manifest ("validated at build time"). Dir-mode targets are startup-
        /// validated in serveImpl instead (comptime can't see the filesystem).
        pub const static_routes: []const static_files.StaticRoute = blk: {
            if (!@hasField(@TypeOf(cfg), "static_routes")) break :blk &.{};
            const raw = cfg.static_routes;
            const RT = @TypeOf(raw);
            const list = lst: {
                switch (@typeInfo(RT)) {
                    .pointer => |p| switch (p.size) {
                        .one => break :lst raw.*, // &.{ ... } tuple/array pointer
                        .slice => break :lst raw,
                        else => {},
                    },
                    .@"struct" => |s| if (s.is_tuple) break :lst raw,
                    else => {},
                }
                @compileError(".static_routes must be a list of '.{ .match = \"/…\", .serve = \"/…\" }' entries; got '" ++ @typeName(RT) ++ "'");
            };
            const n = switch (@typeInfo(@TypeOf(list))) {
                .@"struct" => std.meta.fields(@TypeOf(list)).len,
                .array => |a| a.len,
                .pointer => list.len,
                else => unreachable,
            };
            if (n == 0) break :blk &.{};
            if (std.meta.activeTag(static_mode) == .disabled)
                @compileError(".static_routes requires static serving, but '.static_files = .disabled'; drop one of them");
            var out: [n]static_files.StaticRoute = undefined;
            for (0..n) |i| {
                const e = list[i];
                const ET = @TypeOf(e);
                if (ET != static_files.StaticRoute) {
                    if (@typeInfo(ET) != .@"struct")
                        @compileError(".static_routes: each entry must be '.{ .match = \"/…\", .serve = \"/…\" }'");
                    for (std.meta.fields(ET)) |f| {
                        if (!std.mem.eql(u8, f.name, "match") and !std.mem.eql(u8, f.name, "serve"))
                            @compileError(".static_routes: unknown key '." ++ f.name ++ "' (recognized: .match, .serve)");
                    }
                    if (!@hasField(ET, "match") or !@hasField(ET, "serve"))
                        @compileError(".static_routes: each entry needs BOTH .match and .serve");
                }
                const m: []const u8 = e.match;
                const sv: []const u8 = e.serve;
                validateRoutePattern(m);
                validateServeTarget(sv);
                out[i] = .{ .match = m, .serve = sv };
            }
            const final = out;
            if (std.meta.activeTag(static_mode) == .embedded) {
                const files = static_mode.embedded;
                for (final) |rt| {
                    const rel = rt.serve[1..];
                    const found = manifestHas(files, if (rel.len == 0) "index.html" else rel) or
                        (rel.len > 0 and manifestHas(files, rel ++ "/index.html"));
                    if (!found)
                        @compileError("static_routes: serve target '" ++ rt.serve ++ "' not in the embedded manifest");
                }
            }
            break :blk &final;
        };

        /// Tier-1 `.spa` marker enablement (issue #183). Default: ON when `static_routes`
        /// is absent/empty (a plain custom build stays byte-identical to the shipped
        /// binary), OFF when routes are declared (explicit config shouldn't gain stray-
        /// dotfile behavior). An explicit `.enable_spa_marker = true|false` always wins.
        pub const enable_spa_marker: bool = blk: {
            if (@hasField(@TypeOf(cfg), "enable_spa_marker")) {
                if (@TypeOf(cfg.enable_spa_marker) != bool)
                    @compileError(".enable_spa_marker must be a bool; got '" ++ @typeName(@TypeOf(cfg.enable_spa_marker)) ++ "'");
                break :blk cfg.enable_spa_marker;
            }
            break :blk static_routes.len == 0;
        };

        /// Comptime-lowered collection specs from `.collections` (empty when absent).
        /// Relation fields carry their target collection BY NAME in `targetCollectionId`;
        /// `provision.applySpecs` resolves names -> ids at startup. When empty, no
        /// provisioning runs and the binary behaves byte-for-byte as before.
        pub const collections: []const schema.Collection = blk: {
            const base = if (@hasField(@TypeOf(cfg), "collections")) provision.buildCollections(cfg.collections) else &[_]schema.Collection{};
            // Lower the top-level `.abilities` config onto the matching collections' options (#155).
            // Validates (unknown collection / non-relation `.via` / `.min_role` not in
            // `.tenancy.roles`) with a loud `@compileError`. Absent → byte-identical to no abilities.
            if (@hasField(@TypeOf(cfg), "abilities")) {
                // Abilities resolve `IN (@request.account.ids …)` from the request's memberships,
                // which only exist when tenancy is enabled. Without it every ability would lower to
                // the constant-false predicate and silently deny ALL non-superuser access — a
                // confusing runtime lockout. Fail loudly at comptime instead.
                if (!tenancy_config.enabled)
                    @compileError(".abilities requires .tenancy.enabled = true: abilities authorize by " ++
                        "account membership, which only resolves when tenancy is enabled (otherwise every " ++
                        "ability denies all access). Set .tenancy = .{ .enabled = true, .auth_collection = \"...\" }.");
                break :blk abilities_mod.applyAbilities(base, cfg.abilities, role_ranking);
            }
            break :blk base;
        };

        /// Comptime-reflected route metadata from `.routes` (empty when absent).
        /// Mirrors `App.collections`; consumed by the SP2.2b TS client generator to
        /// emit typed fetch wrappers. Each entry carries the derived camelCase name,
        /// method, path, auth level, and the handler's Input/Output types.
        pub const routes: []const events.RouteMeta = if (@hasField(@TypeOf(cfg), "routes"))
            events.routeMeta(cfg.routes)
        else
            &.{};

        /// Comptime-reflected typed I/O for CUSTOM auth methods declared in the
        /// `.collections` literal (one entry per `.{ .slug, .Initiate, .Complete }`
        /// struct under a collection's `.auth.methods.custom`). Parallels `App.routes`
        /// — a comptime channel carrying Zig `type`s that the build-time TS client
        /// generator reflects into precise interfaces. Bare-string custom entries
        /// contribute nothing here and stay untyped. Empty when there are no
        /// collections or no typed custom methods. ZERO runtime effect (the runtime
        /// slug list lives on `schema.MethodsOptions.custom`).
        pub const custom_auth: []const events.CustomAuthMeta = if (@hasField(@TypeOf(cfg), "collections"))
            events.customAuthMeta(cfg.collections)
        else
            &.{};

        // ── Feature flags + experiments (#128/#129/#130) ───────────────────────
        // The declared registry, lowered at comptime from `.flags`/`.experiments`.
        // `flags`/`experiments` are the metadata slices; `Flag`/`Experiment` are
        // generated enums whose members are the declared names (Option B), so a
        // typo'd `.name` at an `App.flag`/`App.experiment`/`App.setFlag` call site
        // is a compile error. `features_registry` is the static lowered registry the
        // runtime app points at (`app.features`).

        /// Declared boolean flags (empty when no `.flags`).
        pub const flags: []const features.FlagDef = if (@hasField(@TypeOf(cfg), "flags"))
            features.flagMeta(cfg.flags)
        else
            &.{};

        /// Declared experiments (empty when no `.experiments`).
        pub const experiments: []const features.ExperimentDef = if (@hasField(@TypeOf(cfg), "experiments"))
            features.experimentMeta(cfg.experiments)
        else
            &.{};

        /// Enum of declared flag names — the typed key for `App.flag`/`App.setFlag`.
        pub const Flag = features.EnumFromFields(if (@hasField(@TypeOf(cfg), "flags")) cfg.flags else .{});

        /// Enum of declared experiment names — the typed key for `App.experiment`.
        pub const Experiment = features.EnumFromFields(if (@hasField(@TypeOf(cfg), "experiments")) cfg.experiments else .{});

        /// Static lowered registry threaded into `app.features` by serveImpl.
        pub const features_registry: features.Registry = .{ .flags = flags, .experiments = experiments };

        /// TTL in DAYS for sticky `_experiment_assignments` rows (#129). The comptime-gated
        /// `_experiment_gc` sweep deletes assignments older than this. Default 90 days. Only
        /// consumed when at least one declared experiment is `.sticky` — setting it without
        /// any sticky experiment is a `@compileError` (a silent no-op otherwise, mirroring
        /// the `session_gc_cron` misuse guard).
        pub const experiment_assignment_ttl: u32 = blk: {
            if (@hasField(@TypeOf(cfg), "experiment_assignment_ttl") and !has_sticky_experiment)
                @compileError("experiment_assignment_ttl has no effect without a .sticky experiment");
            break :blk if (@hasField(@TypeOf(cfg), "experiment_assignment_ttl")) cfg.experiment_assignment_ttl else 90;
        };

        /// Mount path for the public feature-state projection (`GET <path>?subject=`,
        /// served by `api/state.zig`); null = disabled. Lowered from the `.features`
        /// config knob: `.features = .{ .public_route = "/api/state" }` (custom path)
        /// or `.features = .{ .public_route = .disabled }` (off). Default "/api/state"
        /// (auto-mounted). Loud-comptime on an unknown sub-key or a non-string,
        /// non-`.disabled` value.
        pub const features_public_route: ?[]const u8 = blk: {
            if (!@hasField(@TypeOf(cfg), "features")) break :blk "/api/state";
            const fcfg = cfg.features;
            if (@typeInfo(@TypeOf(fcfg)) != .@"struct")
                @compileError(".features must be a struct, e.g. '.{ .public_route = \"/api/state\" }' or '.{ .public_route = .disabled }'");
            for (std.meta.fields(@TypeOf(fcfg))) |f| {
                if (!std.mem.eql(u8, f.name, "public_route"))
                    @compileError(".features: unknown key '." ++ f.name ++ "' (recognized: .public_route)");
            }
            if (!@hasField(@TypeOf(fcfg), "public_route")) break :blk "/api/state";
            const pr = fcfg.public_route;
            const PRT = @TypeOf(pr);
            if (@typeInfo(PRT) == .enum_literal) {
                if (pr != .disabled)
                    @compileError(".features.public_route must be a path string (e.g. \"/api/state\") or .disabled");
                break :blk null;
            }
            const is_str = switch (@typeInfo(PRT)) {
                .pointer => |p| switch (p.size) {
                    .slice => p.child == u8,
                    .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
                    else => false,
                },
                else => false,
            };
            if (!is_str)
                @compileError(".features.public_route must be a path string (e.g. \"/api/state\") or .disabled");
            break :blk pr;
        };

        /// Resolve a DECLARED flag (the `flag:<name>` override from `_kv` if present,
        /// else the declared default). Typo'd `.name` → compile error. Swallows read
        /// errors back to the default, so a kill-switch check never fails the request.
        pub fn flag(ctx: *ctx_mod.Ctx, comptime f: Flag) bool {
            const def = comptime features_registry.flags[@intFromEnum(f)];
            return ctx.resolveDeclaredFlag(def);
        }

        /// Set a DECLARED flag's override (`flag:<name>` = `"true"`/`"false"`) in `_kv`.
        /// Typo'd `.name` → compile error.
        pub fn setFlag(ctx: *ctx_mod.Ctx, comptime f: Flag, enabled: bool) !void {
            const def = comptime features_registry.flags[@intFromEnum(f)];
            return ctx.writeFlagOverride(def.name, enabled);
        }

        /// Resolve a DECLARED experiment to a variant for `subject` (weight override
        /// from `_kv` if valid, else declared weights, then deterministic bucketing).
        /// Typo'd `.name` → compile error.
        pub fn experiment(ctx: *ctx_mod.Ctx, comptime e: Experiment, subject: []const u8) ![]const u8 {
            const def = comptime features_registry.experiments[@intFromEnum(e)];
            return ctx.resolveDeclaredExperiment(def, subject);
        }

        /// Enqueue a background job with COMPILE-CHECKED queue + kind names (mirrors
        /// `App.flag`): a typo'd `.queue` or `.kind` is a compile error. `payload` is
        /// JSON-serialized and routed to the queue's backend (memory|durable). The generic
        /// runtime escape hatch is `ctx.enqueue(.queue, .kind, payload)`. Callable from
        /// background jobs.
        pub fn enqueue(ctx: *ctx_mod.Ctx, comptime q: Queue, comptime job: Job, payload: anytype) !void {
            return ctx.enqueueByName(@tagName(q), @tagName(job), payload);
        }

        /// Explicit migrations (the escape hatch for non-additive changes), run in
        /// order before provisioning and recorded once in `_migrations`. Empty by default.
        ///
        /// `.migrations` must be a TYPED slice `&[_]zigbase.Migration{ ... }`; a bare
        /// anonymous tuple does not coerce to `[]const Migration`. Guard it here so the
        /// failure names the PUBLIC type and the fix, rather than the raw coercion error
        /// (which leaks the internal `provision.Migration` name).
        pub const provision_migrations: []const provision.Migration = blk: {
            if (!@hasField(@TypeOf(cfg), "migrations")) break :blk &.{};
            if (!migrationsCoerce(@TypeOf(cfg.migrations))) {
                @compileError("'.migrations' must be a typed slice '&[_]zigbase.Migration{ ... }' " ++
                    "(a bare tuple does not coerce to []const Migration); got '" ++ @typeName(@TypeOf(cfg.migrations)) ++ "'");
            }
            break :blk cfg.migrations;
        };

        // ── CAPTCHA (#140 PR6) ────────────────────────────────────────────────
        // Lower `.captcha = .{ .provider = .<provider>, .secret = "..." }` into the
        // serve opts. The only required sub-key is `.provider`; `.secret` defaults to
        // `""` which activates the dev-bypass in `ctx.verifyCaptcha`. Unknown sub-keys
        // are a `@compileError` (mirror the `.features` guard). The `"captcha"` key
        // in `allowed` (above) lets the guard accept it; here we do the actual lowering.

        /// The comptime-lowered CAPTCHA provider (null when `.captcha` is absent).
        pub const captcha_provider: ?captcha.Provider = blk: {
            if (!@hasField(@TypeOf(cfg), "captcha")) break :blk null;
            const cc = cfg.captcha;
            const CT = @TypeOf(cc);
            if (@typeInfo(CT) != .@"struct")
                @compileError(".captcha must be a struct, e.g. '.captcha = .{ .provider = .recaptcha_v3, .secret = \"...\" }'");
            for (std.meta.fields(CT)) |f| {
                const ok = blk2: {
                    for (.{ "provider", "secret" }) |k| {
                        if (std.mem.eql(u8, f.name, k)) break :blk2 true;
                    }
                    break :blk2 false;
                };
                if (!ok) @compileError(".captcha: unknown key '." ++ f.name ++ "' (recognized: .provider, .secret)");
            }
            if (!@hasField(CT, "provider"))
                @compileError(".captcha: missing required key .provider — set e.g. .provider = .recaptcha_v3");
            break :blk cc.provider;
        };

        /// The comptime-lowered CAPTCHA secret (`""` = dev-bypass, no network call).
        pub const captcha_secret: []const u8 = blk: {
            if (!@hasField(@TypeOf(cfg), "captcha")) break :blk "";
            const cc = cfg.captcha;
            const CT = @TypeOf(cc);
            if (@typeInfo(CT) != .@"struct") break :blk "";
            break :blk if (@hasField(CT, "secret")) cc.secret else "";
        };

        /// The comptime-lowered tenancy role total-order (#156). Validates `.tenancy.roles`
        /// (rejects empty / non-string / duplicate); defaults to `viewer<editor<admin<owner`.
        /// PR3 (abilities) threads this into the runtime; PR2 builds it to validate at comptime.
        pub const role_ranking: roles.Ranking = blk: {
            if (!@hasField(@TypeOf(cfg), "tenancy")) break :blk .{};
            const tc = cfg.tenancy;
            if (@typeInfo(@TypeOf(tc)) != .@"struct") break :blk .{};
            if (!@hasField(@TypeOf(tc), "roles")) break :blk .{};
            break :blk roles.buildRanking(tc.roles);
        };

        /// The comptime-lowered runtime tenancy knobs (#156), threaded into `app.tenancy`.
        /// Loud `@compileError` for an unknown `.tenancy` key or an unknown `.resolver`.
        pub const tenancy_config: tenancy.Runtime = blk: {
            if (!@hasField(@TypeOf(cfg), "tenancy")) break :blk .{};
            const tc = cfg.tenancy;
            const TC = @TypeOf(tc);
            if (@typeInfo(TC) != .@"struct")
                @compileError(".tenancy must be a struct, e.g. '.{ .enabled = true, .auth_collection = \"users\" }'");
            for (std.meta.fields(TC)) |f| {
                const ok = std.mem.eql(u8, f.name, "enabled") or std.mem.eql(u8, f.name, "resolver") or
                    std.mem.eql(u8, f.name, "auth_collection") or std.mem.eql(u8, f.name, "roles");
                if (!ok) @compileError(".tenancy: unknown key '." ++ f.name ++ "' (recognized: .enabled, .resolver, .auth_collection, .roles)");
            }
            var rt = tenancy.Runtime{};
            if (@hasField(TC, "enabled")) rt.enabled = tc.enabled;
            if (@hasField(TC, "resolver")) {
                // Coerce loudly: an unknown literal (e.g. `.subdomain`, not yet implemented) fails
                // here rather than silently falling back to `.header`.
                const _coerce: tenancy.Resolver = tc.resolver;
                rt.resolver = _coerce;
            }
            if (@hasField(TC, "auth_collection")) rt.auth_collection = tc.auth_collection;
            // Force role-ranking validation (rejects an empty/duplicate/non-string `.roles`).
            _ = role_ranking;
            break :blk rt;
        };

        /// The comptime-lowered email-subsystem knobs (#154), threaded into `app.mail`. Validates
        /// `.mail` keys with a loud `@compileError`; absent → `.{}` (fully off, back-compat).
        pub const mail_config: mail_cfg.Runtime = blk: {
            if (!@hasField(@TypeOf(cfg), "mail")) break :blk .{};
            const mc = cfg.mail;
            const MC = @TypeOf(mc);
            if (@typeInfo(MC) != .@"struct")
                @compileError(".mail must be a struct, e.g. '.{ .require_verified_sender = true, .webhook_secret = \"…\" }'");
            for (std.meta.fields(MC)) |f| {
                const ok = std.mem.eql(u8, f.name, "require_verified_sender") or
                    std.mem.eql(u8, f.name, "check_suppression") or std.mem.eql(u8, f.name, "webhook_secret");
                if (!ok) @compileError(".mail: unknown key '." ++ f.name ++ "' (recognized: .require_verified_sender, .check_suppression, .webhook_secret)");
            }
            var rt = mail_cfg.Runtime{};
            if (@hasField(MC, "require_verified_sender")) rt.require_verified_sender = mc.require_verified_sender;
            if (@hasField(MC, "check_suppression")) rt.check_suppression = mc.check_suppression;
            if (@hasField(MC, "webhook_secret")) rt.webhook_secret = mc.webhook_secret;
            break :blk rt;
        };

        /// Bundle of comptime-resolved knobs threaded into the serve path: the
        /// selected storage/mailer plugin TYPES, the auth method type list,
        /// and the reader-pool cap.
        const Opts = ServeOpts{
            .StoragePlugin = StoragePlugin,
            .MailerPlugin = MailerPlugin,
            .auth_method_types = auth_method_types,
            .reader_pool_size = reader_pool_size,
            .job_stack_size = job_stack_size,
            .cache_kib = cache_kib,
            .static_mode = static_mode,
            .static_routes = static_routes,
            .enable_spa_marker = enable_spa_marker,
            .pagination = pagination_config,
            .session_store = session_store_config,
            .enable_typegen = enable_typegen,
            .has_ttl = has_ttl_collection,
            .features = &features_registry,
            .experiment_assignment_ttl = experiment_assignment_ttl,
            .features_public_route = features_public_route,
            .queues = &queue_registry,
            .analytics = &analytics_registry,
            .captcha_provider = captcha_provider,
            .captcha_secret = captcha_secret,
            .tenancy = tenancy_config,
            .role_ranking = role_ranking,
            .mail = mail_config,
        };

        /// Parse argv and dispatch the CLI (serve / migrate / superuser create / help),
        /// wiring this app's `dispatch` into the runtime context for `serve`.
        pub fn runCli(init: std.process.Init) !void {
            return runCliImpl(init, &dispatch, jobs, job_pool_size, collections, provision_migrations, Opts);
        }

        /// Start the HTTP server directly with an explicit config (no CLI parsing).
        pub fn run(init: std.process.Init, cfg_runtime: config.Config) !void {
            return serveImpl(init.gpa, init.io, cfg_runtime, &dispatch, jobs, job_pool_size, collections, provision_migrations, Opts, init.environ_map);
        }
    };
}

/// The framework-internal `_ttl_gc` job handler: acquires the writer and reaps
/// expired rows across every TTL-enabled collection. Registered only when the
/// comptime schema declares at least one `.ttl_field` (see `App.internal_jobs`).
fn ttlGcJob(ctx: *@import("ctx.zig").Ctx, ev: *events.JobEvent) anyerror!void {
    _ = ev;
    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();
    _ = try @import("records.zig").gcExpiredRecords(ctx.arena, w);
}

/// The framework-internal `_session_gc` job handler (#114): acquires the writer and reaps
/// expired `_sessions` rows in bounded batches. Registered only in table mode (see
/// `App.session_gc_jobs`); never installed in `.epoch` mode.
fn sessionGcJob(ctx: *@import("ctx.zig").Ctx, ev: *events.JobEvent) anyerror!void {
    _ = ev;
    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();
    _ = try @import("api/auth.zig").gcExpiredSessions(w);
}

/// The framework-internal `_experiment_gc` job handler (#129): acquires the writer and
/// reaps sticky `_experiment_assignments` rows older than `app.experiment_assignment_ttl`
/// (days) in bounded batches. Registered only when a `.sticky` experiment is declared
/// (see `App.experiment_gc_jobs`); never installed for pure-hash-only apps.
fn experimentGcJob(ctx: *@import("ctx.zig").Ctx, ev: *events.JobEvent) anyerror!void {
    _ = ev;
    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();
    _ = try @import("features_resolver.zig").gcExpiredAssignments(w, ctx.app.experiment_assignment_ttl);
}

/// The per-durable-worker poller (`_queue:<worker>`, #137 PR2). Reactive: each cycle it
/// reclaims stale claims, claims+dispatches a batch of its durable queues' ready jobs, then
/// re-arms promptly (~one scheduler tick) so durable jobs drain with low latency. Registered
/// only for workers that drain a durable queue (see `App.queue_worker_jobs`).
fn queueWorkerRun(ctx: *ctx_mod.Ctx, ev: *events.JobEvent) anyerror!?schedule.Reactive {
    const reg = queue.registryFromApp(ctx.app) orelse return schedule.Reactive{ .after = .{ .minutes = 1 } };
    const prefix = "_queue:";
    const wname = if (std.mem.startsWith(u8, ev.name, prefix)) ev.name[prefix.len..] else ev.name;
    var worker: ?queue.WorkerDef = null;
    for (reg.workers) |w| if (std.mem.eql(u8, w.name, wname)) {
        worker = w;
    };
    const wk = worker orelse return schedule.Reactive{ .after = .{ .minutes = 1 } };
    _ = queue_durable.pollOnce(ctx.app, reg, wk) catch |e|
        std.log.warn("queue worker '{s}' poll failed: {s}", .{ wname, @errorName(e) });
    // Re-arm at the minimum interval (0) so the next scheduler tick (~500ms) polls again.
    return schedule.Reactive{ .after = .{ .minutes = 0 } };
}

/// The framework-internal `_queue_gc` job (#137 PR2): per durable queue, reclaims stale
/// claims (using that queue's `visibility_timeout_s`) and reaps done/failed rows older than
/// that queue's `done_ttl_s`, in bounded batches. Registered only when a durable queue is
/// declared (see `App.queue_gc_jobs`).
fn queueGcJob(ctx: *ctx_mod.Ctx, ev: *events.JobEvent) anyerror!void {
    _ = ev;
    const reg = queue.registryFromApp(ctx.app) orelse return;
    const now = clock.nowUnix(ctx.app.io);
    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();
    for (reg.queues) |q| {
        if (q.backend != .durable) continue;
        _ = queue_durable.reclaimStale(w, q.name, now, q.visibility_timeout_s) catch |e|
            std.log.warn("_queue_gc: reclaim for '{s}' failed: {s}", .{ q.name, @errorName(e) });
        _ = queue_durable.gcDoneJobs(w, q.name, q.done_ttl_s) catch |e|
            std.log.warn("_queue_gc: GC for '{s}' failed: {s}", .{ q.name, @errorName(e) });
    }
}

/// The per-rollup analytics aggregation job (`_rollup:<name>`, #158). Resolves the spec by
/// `ev.name` from `app.analytics`, then runs ONE incremental aggregation pass on the writer
/// (provision summary table → aggregate new events past the watermark → advance the watermark).
/// A missing registry/spec is a no-op (defensive — the job is only installed when declared).
fn analyticsRollupRun(ctx: *ctx_mod.Ctx, ev: *events.JobEvent) anyerror!void {
    const reg = analytics.registryFromApp(ctx.app) orelse return;
    const prefix = "_rollup:";
    const name = if (std.mem.startsWith(u8, ev.name, prefix)) ev.name[prefix.len..] else ev.name;
    const spec = reg.byName(name) orelse return;
    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();
    try analytics.runRollup(w, ctx.arena, spec);
}

/// Comptime knobs threaded from `App(cfg)` into the serve path: which storage /
/// mailer plugin TYPES to instantiate, the assembled auth method type list,
/// and the warm-reader-pool cap.
pub const ServeOpts = struct {
    StoragePlugin: type,
    MailerPlugin: type,
    /// Comptime-assembled list of auth method types (built-ins ++ consumer types).
    /// Defaults to just PasswordMethod when absent. serveImpl uses this to
    /// instantiate the Registry via registry.build/deinit.
    auth_method_types: []const type = &.{@import("auth/methods/password.zig").PasswordMethod},
    reader_pool_size: usize,
    job_stack_size: usize = scheduler.default_job_stack_size,
    cache_kib: u32 = db.default_cache_kib,
    static_mode: static_files.Mode = .default,
    /// Tier-2 comptime static rewrites (issue #183), threaded into `app.static_routes`.
    /// Embedded serve targets were proven at comptime; dir targets are startup-validated
    /// in serveImpl (missing target = fatal, like a missing static dir).
    static_routes: []const static_files.StaticRoute = &.{},
    /// Tier-1 `.spa` marker gate (issue #183); false skips the startup scan entirely
    /// (a `.spa` file is then just another never-served dotfile).
    enable_spa_marker: bool = true,
    pagination: pagination.Config = .{},
    /// Selected session-management model (#99); threaded into `App.session_store`.
    session_store: app_mod.SessionStore = .epoch,
    /// When true, compiles the `typegen` CLI subcommand into the binary.
    /// Off by default so production builds carry no codegen.
    enable_typegen: bool = false,
    /// True when the comptime schema declares at least one `.ttl_field`. Gates the
    /// startup one-shot TTL sweep in serveImpl (the periodic job is gated separately
    /// by `jobs`).
    has_ttl: bool = false,
    /// Declared feature-flag + experiment registry (#128/#129/#130), pointed into
    /// `app.features` by serveImpl. Static lifetime (a comptime-lowered const).
    features: ?*const features.Registry = null,
    /// TTL in DAYS for sticky `_experiment_assignments` rows (#129); threaded into
    /// `app.experiment_assignment_ttl` for the comptime-gated `_experiment_gc` job.
    experiment_assignment_ttl: u32 = 90,
    /// Public feature-state route (`api/state.zig`) mount path; null = disabled.
    /// Lowered from the `.features` knob; threaded into `app.features_public_route`.
    features_public_route: ?[]const u8 = "/api/state",
    /// Lowered queue/worker/job registry (#137 PR2), pointed (type-erased) into
    /// `app.queues` by serveImpl so `ctx.enqueue`/`App.enqueue` can route by backend.
    /// Static lifetime (a comptime-lowered const). null = no registry wired.
    queues: ?*const queue.Registry = null,
    /// Captcha provider (#140 PR6), threaded into `app.captcha_provider`.
    /// null = no `.captcha` config (ctx.verifyCaptcha activates the dev-bypass).
    captcha_provider: ?captcha.Provider = null,
    /// Captcha site-verify secret (#140 PR6), threaded into `app.captcha_secret`.
    /// `""` = dev-bypass (ctx.verifyCaptcha returns .{.ok=true} without a network call).
    captcha_secret: []const u8 = "",
    /// Lowered analytics rollup registry (#158), pointed (type-erased) into `app.analytics` by
    /// serveImpl so the `_rollup:<name>` jobs + the rollups read endpoint resolve specs by name.
    /// Static lifetime (a comptime-lowered const). null = no `.analytics` config.
    analytics: ?*const analytics.Registry = null,
    /// Multi-tenancy knobs (#156), threaded into `app.tenancy`. Default `.enabled = false` is the
    /// byte-identical no-tenancy path.
    tenancy: tenancy.Runtime = .{},
    /// Role total-order (#155/#156), threaded into `app.role_ranking` for ability `.min_role`
    /// comparisons. Default = the standard ladder (`viewer<editor<admin<owner`).
    role_ranking: roles.Ranking = .{},
    /// Email-subsystem knobs (#154), threaded into `app.mail`. Default `.{}` is fully off
    /// (no verified-sender/suppression enforcement, webhook route disabled).
    mail: mail_cfg.Runtime = .{},
};

/// Zig 0.16 entry point body: parse argv from `init.minimal.args` and dispatch.
fn runCliImpl(init: std.process.Init, dispatch: *const events.Dispatch, jobs: []const scheduler.RuntimeJob, pool_size: usize, schema_collections: []const schema.Collection, schema_migrations: []const provision.Migration, comptime opts: ServeOpts) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    // cli.parse wants []const []const u8; argv is []const [:0]const u8. Copy
    // the (sentinel-bearing) slices into plain []const u8 views.
    const args = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| args[i] = a;

    const cmd = cli.parse(args[1..], .{ .serve_static = std.meta.activeTag(opts.static_mode) == .default }) catch |err| {
        std.log.err("argument error: {s}", .{@errorName(err)});
        printUsage(init.io, std.Io.File.stderr(), std.meta.activeTag(opts.static_mode) == .default);
        return;
    };

    switch (cmd) {
        .help => |topic| switch (topic) {
            .top => printUsage(init.io, std.Io.File.stdout(), std.meta.activeTag(opts.static_mode) == .default),
            .serve => printServeUsage(init.io, std.Io.File.stdout(), std.meta.activeTag(opts.static_mode) == .default),
            .migrate => printMigrateUsage(init.io, std.Io.File.stdout()),
            .rewrap => printRewrapUsage(init.io, std.Io.File.stdout()),
            .superuser_create => printSuperuserUsage(init.io, std.Io.File.stdout()),
            .typegen => printTypegenUsage(init.io, std.Io.File.stdout()),
            .migrate_db => printMigrateDbUsage(init.io, std.Io.File.stdout()),
        },
        .version => printVersion(init.io, std.Io.File.stdout()),
        .serve => |sa| {
            const cfg = try loadCfg(init.environ_map, sa);
            try serveImpl(allocator, init.io, cfg, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts, init.environ_map);
        },
        .migrate => |sa| try migrateImpl(allocator, init.io, init.environ_map, sa),
        .rewrap => |ra| try rewrapImpl(allocator, init.io, init.environ_map, ra),
        .migrate_db => |ma| try migrateDbImpl(allocator, init.io, ma),
        .superuser_create => |sa| try superuserCreateImpl(allocator, init.io, init.environ_map, sa),
        .typegen => |ta| {
            if (opts.enable_typegen) {
                const tgen = @import("codegen/typegen_cli.zig");
                var arena_state = std.heap.ArenaAllocator.init(init.gpa);
                defer arena_state.deinit();
                const a = arena_state.allocator();
                const out = ta.out orelse {
                    std.log.err("typegen: --out <path> is required", .{});
                    return error.MissingOut;
                };
                try tgen.run(a, init.io, .{
                    .data_dir = ta.data_dir,
                    .url = ta.url,
                    .out = out,
                    .api_prefix = ta.api_prefix,
                    .client_name = ta.client_name,
                    .check = ta.check,
                    .in_repo = init.environ_map.contains("ZBASE_INREPO"),
                    .admin_email = ta.admin_email,
                    .admin_password = ta.admin_password,
                });
            } else {
                std.log.err("typegen: this binary was not built with .enable_typegen = true", .{});
                return;
            }
        },
    }
}

/// Emit `fmt` (with `args`) to `file` via a stack buffer, flushing after. Used by
/// the print* helpers so help/version go to stdout and argument errors go to stderr,
/// all without log-level/metadata prefixes that would clutter multi-section screens.
fn emit(io: std.Io, file: std.Io.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

/// Print the comprehensive top-level usage guide to stdout. We use emit()
/// (not std.log.info) so each line is emitted cleanly without log-level/metadata
/// prefixes, which keeps a multi-section help screen readable.
/// `show_serve_static` mirrors the parser gate: --serve-static is only listed in
/// the default comptime mode (in .disabled/.dir/.embedded it's an unknown flag).
fn printUsage(io: std.Io, file: std.Io.File, show_serve_static: bool) void {
    emit(io, file,
        \\zigbase — a single-binary backend (REST + WebSocket + admin UI)
        \\Docs & source: https://github.com/valthon/zigbase
        \\
        \\USAGE:
        \\  zigbase <command> [flags]
        \\
        \\COMMANDS:
        \\  serve               Start the HTTP server (REST + WebSocket + admin UI at /_/).
        \\  migrate             Apply database migrations, then exit.
        \\  rewrap              Re-encrypt all encrypted fields under the primary key (key rotation).
        \\  migrate-db          Copy an existing SQLite instance into PostgreSQL (requires -Dpostgres).
        \\  superuser create    Create an admin (superuser) account.
        \\  help                Show this help. Also: --help, -h, or no arguments.
        \\  version             Print version + build provenance. Also: --version, -V.
        \\
        \\  Per-command help is available via `zigbase <command> --help`, e.g.
        \\  `zigbase serve --help` or `zigbase superuser create --help`.
        \\
        \\COMMON FLAGS (serve / migrate):
        \\  --http-host H       Address to bind (serve only). Default is loopback; pass
        \\                      0.0.0.0 to expose on all interfaces. [env ZIGBASE_HTTP_HOST, default 127.0.0.1]
        \\  --http-port N       TCP port to listen on (serve only). [env ZIGBASE_HTTP_PORT, default 8090]
        \\  --data-dir PATH     Directory for the SQLite db + file storage. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\  --insecure-cookies  Drop the Secure flag on auth cookies (serve only); for plain-HTTP
        \\                      local dev only. Cookies are Secure by default.
        \\  --trust-proxy       Trust X-Forwarded-For/X-Real-IP for client-IP/rate-limit keying
        \\                      (serve only). Set ONLY behind a trusted reverse proxy. [default off]
        \\  --realtime-origins CSV  Allowed WebSocket Origins (serve only). Empty denies cross-origin
        \\                      browser upgrades. [env ZIGBASE_REALTIME_ORIGINS]
        \\
    , .{});
    if (show_serve_static) emit(io, file,
        \\  --serve-static DIR  Serve static files from DIR at the root path (serve only;
        \\                      available unless the app hardcodes static files at comptime).
        \\
    , .{});
    emit(io, file,
        \\
        \\ENVIRONMENT VARIABLES:
        \\  ZIGBASE_JWT_SECRET        Token-signing secret (>= 32 bytes). When UNSET, a strong
        \\                           random secret is generated and persisted at
        \\                           <data-dir>/.jwt_secret (0600) on first run, then reused.
        \\                           A provided secret shorter than 32 bytes is refused. [default: auto-generate]
        \\  ZIGBASE_HTTP_HOST         Bind address; loopback by default. Set 0.0.0.0 to expose
        \\                           on all interfaces.              [default 127.0.0.1]
        \\  ZIGBASE_HTTP_PORT         Listen port.                   [default 8090]
        \\  ZIGBASE_DATA_DIR          Data directory (db + storage). [default ./zb_data]
        \\  ZIGBASE_COOKIE_SECURE     Secure flag on auth cookies (true/1). Secure by default; set
        \\                           false only for plain-HTTP local dev. [default true]
        \\  ZIGBASE_TRUST_PROXY       Trust X-Forwarded-For/X-Real-IP (true/1). Set ONLY behind a
        \\                           trusted reverse proxy.          [default false]
        \\  ZIGBASE_SENTRY_DSN        Sentry DSN for error reporting; empty logs errors to stderr.
        \\                           [default empty]
        \\  ZIGBASE_REALTIME_ORIGINS  CSV of allowed WebSocket Origins. Empty DENIES cross-origin
        \\                           browser upgrades.               [default empty]
        \\  ZIGBASE_MAX_UPLOAD_SIZE   Max request body for uploads, in bytes. [default 52428800 = 50 MiB]
        \\  ZIGBASE_AUTH_TOKEN_TTL    Auth token lifetime, seconds.  [default 1209600 = 14 days]
        \\  ZIGBASE_VERIFICATION_TTL  Email-verification token TTL, seconds. [default 604800 = 7 days]
        \\  ZIGBASE_PASSWORD_RESET_TTL Password-reset token TTL, seconds.    [default 3600 = 1 hour]
        \\  ZIGBASE_FILE_TOKEN_TTL    Short-lived file-access token TTL, seconds. [default 120 = 2 min]
        \\  ZIGBASE_FIELD_KEY         Key for at-rest field encryption (.encrypted fields). Never
        \\                           auto-generated/persisted/logged. Required if any field is encrypted.
        \\  ZIGBASE_FIELD_KEY_GENERATION  Generation of the primary key = envelope version written
        \\                           (v<N>:). Bump to rotate; then run `zigbase rewrap`. [default 1]
        \\  ZIGBASE_FIELD_KEY_V<n>    Older read-only key for generation <n> (decrypts existing v<n>: data).
        \\
        \\EXAMPLES:
        \\  # Create the first superuser (admin) account:
        \\  zigbase superuser create --email you@example.com --password "<a strong password>" --data-dir ./zb_data
        \\
        \\  # Serve locally (binds 127.0.0.1; a random JWT secret is generated + persisted):
        \\  zigbase serve --data-dir ./zb_data
        \\
        \\  # Local dev over plain HTTP (cookies are Secure by default, which won't send on http://):
        \\  zigbase serve --insecure-cookies --data-dir ./zb_data
        \\
        \\  # Expose on all interfaces (front with a firewall / reverse proxy):
        \\  zigbase serve --http-host 0.0.0.0 --http-port 9000 --trust-proxy --data-dir /var/lib/zigbase
        \\
        \\  # Apply pending migrations and exit:
        \\  zigbase migrate --data-dir ./zb_data
        \\
        \\After `serve` starts, open http://127.0.0.1:8090/_/ for the admin UI.
        \\More docs: README.md, docs/api.md, docs/framework.md, docs/tutorial.md.
        \\
    , .{});
}

/// Print build provenance (for `--version`) to stdout. emit() keeps it prefix-free.
fn printVersion(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase {s}
        \\commit:  {s}
        \\build:   {s}
        \\target:  {s}-{s}-{s}
        \\zig:     {s}
        \\
    , .{
        build_options.version,
        build_options.commit,
        @tagName(builtin.mode),
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
        builtin.zig_version_string,
    });
}

fn printServeUsage(io: std.Io, file: std.Io.File, show_serve_static: bool) void {
    emit(io, file,
        \\zigbase serve — start the HTTP server (REST API + WebSocket + admin UI at /_/).
        \\
        \\USAGE:
        \\  zigbase serve [--http-host H] [--http-port N] [--data-dir PATH]
        \\                [--insecure-cookies] [--trust-proxy] [--realtime-origins CSV]{s}
        \\
        \\FLAGS:
        \\  --http-host H    Address to bind; loopback by default. Pass 0.0.0.0 for all
        \\                   interfaces.        [env ZIGBASE_HTTP_HOST, default 127.0.0.1]
        \\  --http-port N    TCP port to listen. [env ZIGBASE_HTTP_PORT, default 8090]
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\  --insecure-cookies   Drop the Secure cookie flag (plain-HTTP local dev only).
        \\  --trust-proxy        Trust X-Forwarded-For/X-Real-IP (behind a trusted proxy only).
        \\  --realtime-origins CSV  Allowed WebSocket Origins; empty denies cross-origin upgrades.
        \\
    , .{if (show_serve_static) " [--serve-static DIR]" else ""});
    if (show_serve_static) emit(io, file,
        \\  --serve-static DIR  Serve static files from DIR at the root path (anything
        \\                      not matching /api/, /_/, or custom routes). [default: off]
        \\
    , .{});
    emit(io, file,
        \\KEY ENVIRONMENT VARIABLES:
        \\  ZIGBASE_JWT_SECRET      Token-signing secret (>= 32 bytes). When unset, a random secret
        \\                         is generated + persisted at <data-dir>/.jwt_secret (0600) on first run.
        \\  ZIGBASE_COOKIE_SECURE  Secure flag on auth cookies (true/1). Secure by default. [default true]
        \\  ZIGBASE_TRUST_PROXY    Trust X-Forwarded-For/X-Real-IP (true/1). [default false]
        \\  ZIGBASE_SENTRY_DSN     Sentry DSN for error reporting; empty logs to stderr.
        \\  (See `zigbase help` for the full list of ZIGBASE_* variables.)
        \\
        \\EXAMPLE:
        \\  zigbase serve --http-port 9000 --data-dir ./zb_data
        \\
    , .{});
}

fn printMigrateUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase migrate — apply pending database migrations, then exit.
        \\
        \\USAGE:
        \\  zigbase migrate [--data-dir PATH]
        \\
        \\FLAGS:
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\
        \\Note: `zigbase serve` also runs migrations on startup; use `migrate` to apply
        \\them ahead of time (e.g. in a deploy step) without starting the server.
        \\
        \\EXAMPLE:
        \\  zigbase migrate --data-dir ./zb_data
        \\
    , .{});
}

fn printRewrapUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase rewrap — re-encrypt every encrypted field under the primary key.
        \\
        \\USAGE:
        \\  zigbase rewrap [--data-dir PATH] [--dry-run]
        \\
        \\FLAGS:
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\  --dry-run        Decrypt and report counts, but write nothing.
        \\
        \\WHAT IT DOES:
        \\  For every `.encrypted` field of every collection, decrypts each stored cell
        \\  with whichever key generation matches its `v<N>:` envelope version (or, for
        \\  a legacy plaintext cell, takes it as-is) and re-encrypts it under the PRIMARY
        \\  key. This is how you finish a key rotation and how you migrate existing
        \\  plaintext into ciphertext when enabling `.encrypted`.
        \\
        \\KEYS (env, never persisted/logged):
        \\  ZIGBASE_FIELD_KEY             The primary (write) key. REQUIRED.
        \\  ZIGBASE_FIELD_KEY_GENERATION  Generation of the primary key (= envelope
        \\                                version written). Default 1.
        \\  ZIGBASE_FIELD_KEY_V<n>        Older read-only key for generation <n>, needed
        \\                                to decrypt existing v<n>: data.
        \\
        \\  Run with the primary key plus every older generation present in your data.
        \\  A cell it cannot decrypt aborts the run with the row reported (fail-closed,
        \\  no data loss). The command is idempotent and transactional per collection.
        \\
        \\EXAMPLE (rotate from key gen 1 to gen 2):
        \\  ZIGBASE_FIELD_KEY=newkey ZIGBASE_FIELD_KEY_GENERATION=2 ZIGBASE_FIELD_KEY_V1=oldkey \
        \\    zigbase rewrap --data-dir ./zb_data
        \\
    , .{});
}

fn printSuperuserUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase superuser create — create an admin (superuser) account.
        \\
        \\USAGE:
        \\  zigbase superuser create --email E --password P [--data-dir PATH]
        \\
        \\FLAGS:
        \\  --email E        Superuser email address (required).
        \\  --password P     Superuser password (required, at least 8 characters).
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\
        \\Collection management and the admin UI at /_/ are superuser-only, so create one
        \\before configuring collections.
        \\
        \\EXAMPLE:
        \\  zigbase superuser create --email you@example.com --password "<a strong password>" --data-dir ./zb_data
        \\
    , .{});
}

fn loadCfg(environ: *const std.process.Environ.Map, sa: cli.ServeArgs) !config.Config {
    var cfg = try config.Config.load(config.EnvGetter{ .environ = environ });
    if (sa.http_host) |v| cfg.http_host = v;
    if (sa.http_port) |v| cfg.http_port = v;
    if (sa.data_dir) |v| cfg.data_dir = v;
    if (sa.serve_static) |v| cfg.static_dir = v;
    // Secure-by-default opt-outs/opt-ins (flags override toward the explicit choice).
    if (sa.insecure_cookies) cfg.cookie_secure = false;
    if (sa.trust_proxy) cfg.trust_proxy = true;
    if (sa.realtime_origins) |v| cfg.realtime_allowed_origins = v;
    return cfg;
}

fn openPool(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, options: db.PoolOptions) !db.Pool {
    std.Io.Dir.cwd().createDirPath(io, cfg.data_dir) catch {};
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/data.db", .{cfg.data_dir}, 0);
    defer allocator.free(db_path);
    return db.Pool.initOpts(allocator, io, db_path, options);
}

/// Open the database pool, selecting the backend (#159). When `ZIGBASE_DB_URL` is a
/// `postgres://…` URL AND the binary was built with `-Dpostgres=true`, the Postgres pool is
/// opened; otherwise the SQLite `<data_dir>/data.db` pool as before.
///
/// I-1 (fail-loud): `ZIGBASE_DB_URL` is read UNCONDITIONALLY (outside the build gate). A stock
/// `-Dpostgres=false` binary therefore no longer *silently* ignores a `postgres://` URL and
/// writes to local SQLite — it emits a prominent startup warning so an operator who points a
/// non-PG binary at production Postgres sees the misdirection instead of losing writes into a
/// `data.db`. The actual PG *selection* stays gated behind `build_options.postgres`; the SQLite
/// data path is unchanged (the warning only fires for a `postgres://` value in a non-PG build).
/// This is why the default build is no longer byte-for-byte identical to pre-#159 — by design;
/// behavioral equivalence of the SQLite path is asserted by `db.chooseBackend`'s tests instead.
fn openPoolSelect(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, options: db.PoolOptions, environ: *const std.process.Environ.Map) !db.Pool {
    const getter = config.EnvGetter{ .environ = environ };
    const db_url = getter.get("ZIGBASE_DB_URL");
    switch (db.chooseBackend(db_url)) {
        .postgres => {
            // Reachable only in a `-Dpostgres` build (chooseBackend gates on build_options).
            const url = try allocator.dupeZ(u8, db_url.?);
            defer allocator.free(url);
            std.log.info("database backend: PostgreSQL (experimental, #159)", .{});
            return db.Pool.initOpts(allocator, io, url, options);
        },
        .postgres_url_without_build => {
            std.log.warn(
                "ZIGBASE_DB_URL is a postgres:// URL but this binary was built without -Dpostgres; " ++
                    "falling back to SQLite at {s}/data.db (set -Dpostgres=true to use PostgreSQL)",
                .{cfg.data_dir},
            );
            return openPool(allocator, io, cfg, options);
        },
        .sqlite => return openPool(allocator, io, cfg, options),
    }
}

fn migrateImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, sa: cli.ServeArgs) !void {
    const cfg = try loadCfg(environ, sa);
    var pool = try openPoolSelect(allocator, io, cfg, .{}, environ);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.run(w);
    std.log.info("migrations applied", .{});
}

/// `zigbase rewrap`: re-encrypt every `.encrypted` cell under the PRIMARY key
/// generation and migrate legacy plaintext into ciphertext. Must run with the
/// primary key (ZIGBASE_FIELD_KEY) plus any older generations
/// (ZIGBASE_FIELD_KEY_V<n>) needed to read existing data configured. Fail-closed:
/// a cell it cannot decrypt aborts the run with the row reported (no data loss).
fn rewrapImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, ra: cli.RewrapArgs) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = ra.data_dir });
    if (cfg.field_key.len == 0) {
        std.log.err("rewrap: ZIGBASE_FIELD_KEY is not set; the primary key is required to re-encrypt", .{});
        return error.FieldKeyRequired;
    }
    const cipher = field_policy.Cipher.resolve(io, config.EnvGetter{ .environ = environ }, cfg.field_key, cfg.field_key_generation) catch |e| {
        std.log.err("rewrap: invalid field-encryption key config ({s}); see ZIGBASE_FIELD_KEY_GENERATION / ZIGBASE_FIELD_KEY_V<n>", .{@errorName(e)});
        return e;
    };
    var pool = try openPoolSelect(allocator, io, cfg, .{}, environ);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    // Ensure the system tables (incl. _collections) exist before enumerating.
    try migrations.run(w);
    std.log.info("rewrap: writing generation v{d}{s}", .{ cfg.field_key_generation, if (ra.dry_run) " (dry-run: no writes)" else "" });
    const stats = try rewrap.rewrapAll(allocator, w, &cipher, ra.dry_run);
    std.log.info(
        "rewrap {s}: {d} collection(s), {d} field(s); {d} re-encrypted, {d} plaintext migrated, {d} already current",
        .{ if (ra.dry_run) "dry-run complete" else "complete", stats.collections, stats.fields, stats.rewrapped, stats.plaintext_migrated, stats.skipped },
    );
}

/// `zigbase migrate-db --from <data.db> --to <postgres://…>`: copy an existing SQLite instance
/// into a PostgreSQL target (issue #159). Provisions the equivalent schema on the target via the
/// system migrations + the source's `_collections` record tables, then bulk-loads every row,
/// carrying encrypted-field envelopes verbatim and preserving ids/timestamps/metadata.
///
/// The subcommand is ALWAYS present, but the Postgres side requires a binary built with
/// `-Dpostgres`. Built without it, the command fails loudly (the target URL cannot be opened) —
/// it never silently no-ops.
fn migrateDbImpl(allocator: std.mem.Allocator, io: std.Io, ma: cli.MigrateDbArgs) !void {
    const from = ma.from orelse {
        std.log.err("migrate-db: --from <sqlite data.db path> is required", .{});
        return error.MissingFrom;
    };
    const to = ma.to orelse {
        std.log.err("migrate-db: --to <postgres://…> is required", .{});
        return error.MissingTo;
    };
    if (!db.connstrLooksLikePostgres(to)) {
        std.log.err("migrate-db: --to must be a postgres:// or postgresql:// URL (got '{s}')", .{to});
        return error.InvalidTarget;
    }
    if (comptime !build_options.postgres) {
        std.log.err("migrate-db: this binary was built WITHOUT -Dpostgres, so it cannot open a PostgreSQL target. Rebuild with `zig build -Dpostgres=true`.", .{});
        return error.PostgresSupportNotBuilt;
    } else {
        const dumpload = @import("dumpload.zig");
        const from_z = try allocator.dupeZ(u8, from);
        defer allocator.free(from_z);
        const to_z = try allocator.dupeZ(u8, to);
        defer allocator.free(to_z);

        var source = db.Db.open(from_z) catch |e| {
            std.log.err("migrate-db: cannot open source SQLite '{s}': {s}", .{ from, @errorName(e) });
            return e;
        };
        defer source.close();
        var target = db.Db.openPostgres(allocator, io, to_z) catch |e| {
            std.log.err("migrate-db: cannot connect to target Postgres: {s}", .{@errorName(e)});
            return e;
        };
        defer target.close();

        std.log.info("migrate-db: migrating '{s}' -> PostgreSQL{s}", .{ from, if (ma.force) " (--force)" else "" });
        const report = dumpload.run(allocator, &source, &target, .{ .force = ma.force }) catch |e| switch (e) {
            error.TargetNotEmpty => {
                std.log.err("migrate-db: the target already contains a ZigBase schema (refusing to overwrite). Pass --force to load into it anyway.", .{});
                return e;
            },
            error.RowCountMismatch => {
                std.log.err("migrate-db: aborted — a table's loaded row count did not match the source (see the error above).", .{});
                return e;
            },
            else => return e,
        };
        defer report.deinit(allocator);
        for (report.tables) |t| {
            if (t.rows > 0) std.log.info("migrate-db:   {s}: {d} row(s)", .{ t.name, t.rows });
        }
        std.log.info(
            "migrate-db: complete — {d} record table(s) provisioned, {d} table(s) loaded, {d} total row(s)",
            .{ report.collections_provisioned, report.tables.len, report.total_rows },
        );
    }
}

fn printMigrateDbUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase migrate-db — copy an existing SQLite instance into PostgreSQL.
        \\
        \\USAGE:
        \\  zigbase migrate-db --from PATH --to URL [--force]
        \\
        \\FLAGS:
        \\  --from PATH   Source SQLite database file (e.g. ./zb_data/data.db). REQUIRED.
        \\  --to URL      Target postgres://… connection URL. REQUIRED.
        \\  --force       Overwrite a target that already contains a ZigBase schema.
        \\
        \\It provisions the equivalent schema on the target (system migrations + every
        \\collection's record table) and bulk-loads every row, carrying encrypted-field
        \\envelopes VERBATIM (no decrypt/re-encrypt) and preserving ids, timestamps, and
        \\collection metadata. A non-empty target is refused unless --force.
        \\
        \\Requires a binary built with -Dpostgres (the pure-Zig PostgreSQL backend).
        \\
        \\EXAMPLE:
        \\  zigbase migrate-db --from ./zb_data/data.db \
        \\    --to "postgres://user:pass@db.example.com:5432/zigbase?sslmode=require"
        \\
    , .{});
}

/// Minimum acceptable length for an operator-provided JWT secret.
pub const min_jwt_secret_len = 32;
/// Filename (under the data dir) of the auto-generated, persisted JWT secret.
pub const jwt_secret_filename = ".jwt_secret";
/// Length (chars) of an auto-generated JWT secret. 64 base36 chars ~= 331 bits.
const generated_jwt_secret_len = 64;

/// Resolve the effective JWT secret (F6/F12). Three cases:
///   - operator provided a secret (`cfg.jwt_secret` non-empty): use it, but REFUSE
///     to start if it is shorter than `min_jwt_secret_len` (the old shared
///     "dev-insecure-secret-change-me" default is gone — "unset" means auto-generate).
///   - unset (empty) and `<data_dir>/.jwt_secret` exists: reuse the persisted secret.
///   - unset and no file: generate a strong random secret, persist it 0600, use it.
/// The returned slice is owned by `allocator` (caller frees). Never logs the secret.
fn resolveJwtSecret(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) ![]const u8 {
    if (cfg.jwt_secret.len > 0) {
        if (cfg.jwt_secret.len < min_jwt_secret_len) {
            std.log.err("refusing to start: ZIGBASE_JWT_SECRET is too short ({d} bytes); use at least {d} bytes", .{ cfg.jwt_secret.len, min_jwt_secret_len });
            return error.WeakJwtSecret;
        }
        return allocator.dupe(u8, cfg.jwt_secret);
    }
    // Unset: persist a per-deployment secret under the data dir so "unset" is never
    // a shared, guessable default. Ensure the data dir exists first.
    std.Io.Dir.cwd().createDirPath(io, cfg.data_dir) catch {};
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cfg.data_dir, jwt_secret_filename });
    defer allocator.free(path);
    if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096))) |existing| {
        const trimmed = std.mem.trim(u8, existing, " \t\r\n");
        if (trimmed.len >= min_jwt_secret_len) {
            // Re-own just the trimmed bytes so the caller's free matches the alloc.
            const owned = try allocator.dupe(u8, trimmed);
            allocator.free(existing);
            std.log.info("using persisted JWT secret from {s}/{s}", .{ cfg.data_dir, jwt_secret_filename });
            return owned;
        }
        allocator.free(existing);
        std.log.warn("persisted JWT secret at {s}/{s} is too short; regenerating", .{ cfg.data_dir, jwt_secret_filename });
    } else |err| switch (err) {
        error.FileNotFound => {}, // first run: fall through to generate
        else => return err,
    }
    const secret = try @import("crypto.zig").genToken(io, allocator, generated_jwt_secret_len);
    // Write 0600 (owner read/write only). createFile truncates by default.
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = secret,
        .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
    }) catch |err| {
        allocator.free(secret);
        std.log.err("could not persist generated JWT secret to {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    std.log.info("generated a new random JWT secret and persisted it to {s}/{s} (0600)", .{ cfg.data_dir, jwt_secret_filename });
    return secret;
}

fn serveImpl(allocator: std.mem.Allocator, io: std.Io, cfg_in: config.Config, dispatch: *const events.Dispatch, jobs: []const scheduler.RuntimeJob, pool_size: usize, schema_collections: []const schema.Collection, schema_migrations: []const provision.Migration, comptime opts: ServeOpts, environ: *const std.process.Environ.Map) !void {
    var cfg = cfg_in;
    const jwt_secret = try resolveJwtSecret(allocator, io, cfg);
    defer allocator.free(jwt_secret);
    cfg.jwt_secret = jwt_secret;
    // Install the dev-only frozen clock (ZIGBASE_FAKE_NOW) so every framework "now" — token
    // expiry, scheduling, challenge/cursor TTLs — reads the override. No-op + null on a prod
    // build (the gate is comptime-off; see clock.zig).
    clock.install(cfg.fake_now_unix);
    // Install the dev-only seeded entropy (ZIGBASE_FAKE_SEED) so ID/token generation uses a
    // deterministic PRNG seeded from this value for reproducible snapshot tests. No-op + null
    // on a prod build (the gate is comptime-off; see entropy.zig).
    entropy_mod.install(cfg.fake_seed);
    if (std.mem.eql(u8, cfg.http_host, "0.0.0.0") or std.mem.eql(u8, cfg.http_host, "::")) {
        std.log.warn("binding to all interfaces ({s}); ensure a firewall/reverse proxy is in front (default is loopback 127.0.0.1)", .{cfg.http_host});
    }
    if (cfg.realtime_allowed_origins.len == 0) {
        std.log.info("realtime: no allowed Origins configured; cross-origin browser WebSocket upgrades are DENIED (set ZIGBASE_REALTIME_ORIGINS)", .{});
    }
    var pool = try openPoolSelect(allocator, io, cfg, .{ .reader_cap = opts.reader_pool_size, .cache_kib = opts.cache_kib }, environ);
    defer pool.deinit();
    // Transparent at-rest field encryption (Theme B1). Resolve the cipher ONCE from
    // ZIGBASE_FIELD_KEY and stamp it onto the pool so every acquired connection carries
    // it (db.zig). FAIL-CLOSED: if any collection declares an `.encrypted` field but no
    // key is configured, refuse to start rather than silently storing plaintext. The
    // cipher is a serveImpl stack var that outlives srv.listen(); pool points at it.
    var field_cipher: field_policy.Cipher = undefined;
    if (cfg.field_key.len > 0) {
        field_cipher = field_policy.Cipher.resolve(io, config.EnvGetter{ .environ = environ }, cfg.field_key, cfg.field_key_generation) catch |e| {
            std.log.err("refusing to start: invalid field-encryption key config ({s}); see ZIGBASE_FIELD_KEY_GENERATION / ZIGBASE_FIELD_KEY_V<n>", .{@errorName(e)});
            return e;
        };
        db.poolSetFieldCipher(&pool, @ptrCast(&field_cipher));
        if (cfg.field_key_generation != 1)
            std.log.info("field encryption: primary generation v{d} (writes); older generations read from ZIGBASE_FIELD_KEY_V<n>. Run `zigbase rewrap` to migrate old data forward.", .{cfg.field_key_generation});
    } else if (anyEncryptedField(schema_collections)) {
        std.log.err("refusing to start: a collection declares an .encrypted field but ZIGBASE_FIELD_KEY is not set (encrypted data would be unreadable / stored as plaintext)", .{});
        return error.FieldKeyRequired;
    }
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
        // Comptime-schema provisioning. When `.collections`/`.migrations` are absent
        // both slices are empty, so this whole block is a no-op and the binary behaves
        // exactly as before the feature. Otherwise: run the explicit escape-hatch
        // migrations (once each, recorded in _migrations), then idempotently provision
        // the comptime collections (create-missing + additive field-add + name->id
        // relation resolution; destructive diffs are logged and skipped).
        if (schema_migrations.len > 0) {
            try provision.runMigrations(allocator, io, w, schema_migrations);
        }
        if (schema_collections.len > 0) {
            // injectOAuthSecrets allocates a rewritten collections slice (+ provider arrays
            // and encrypted secret strings) only needed through provisioning; applySpecs
            // persists the encrypted secret into the DB. Scope those in an arena so they are
            // freed after provisioning instead of leaking once at startup (the e2e
            // leak-checker flags the leak).
            var prov_arena = std.heap.ArenaAllocator.init(allocator);
            defer prov_arena.deinit();
            const resolved = try provision.injectOAuthSecrets(
                prov_arena.allocator(),
                io,
                jwt_secret,
                config.EnvGetter{ .environ = environ },
                schema_collections,
            );
            try provision.applySpecs(allocator, io, w, resolved);
        }
        // Fail-closed for RUNTIME-created encrypted fields (Theme B1, gap #102). The
        // comptime guard above only sees the `.collections` literal; a collection whose
        // encrypted field was added at runtime (via the superuser collections API while a
        // key was set) is invisible to it. Now that provisioning/migrations have run and
        // the live schema is settled, scan the DB-resident collections: if any declares an
        // encrypted field but no key is configured, refuse to start rather than serve a
        // schema whose ciphertext can never be read. (The value layer also fails closed on
        // read/write, so plaintext never leaks; this just turns a silent half-broken server
        // into a loud startup refusal.)
        if (db.poolFieldCipher(&pool) == null) {
            var scan_arena = std.heap.ArenaAllocator.init(allocator);
            defer scan_arena.deinit();
            if (try liveEncryptedCollection(scan_arena.allocator(), w)) |cname| {
                std.log.err("refusing to start: collection '{s}' has an .encrypted field but ZIGBASE_FIELD_KEY is not set (encrypted data would be unreadable)", .{cname});
                return error.FieldKeyRequired;
            }
        }
        // Stateful cursor mode accumulates rows in `_cursorStates`; sweep expired entries at
        // startup. (Lookups already ignore expired rows, so this is purely space reclamation.)
        // For long-lived servers, schedule `records.gcCursorStates` on a `.cron` interval too.
        if (opts.pagination.cursor_token == .stateful) {
            @import("records.zig").gcCursorStates(w) catch |e| std.log.warn("cursor-state GC at startup failed: {s}", .{@errorName(e)});
        }
        // Sweep expired and consumed auth challenge entries at startup. This is purely space
        // reclamation; both `take` paths already reject expired/consumed rows at query time.
        @import("auth/challenge_store.zig").gcAuthChallenges(w) catch |e| std.log.warn("auth-challenge GC at startup failed: {s}", .{@errorName(e)});
        // One-shot TTL sweep at startup (the periodic `_ttl_gc` job handles the rest). Only
        // compiled in when the comptime schema declares at least one `.ttl_field`.
        if (opts.has_ttl) {
            var ttl_arena = std.heap.ArenaAllocator.init(allocator);
            defer ttl_arena.deinit();
            _ = @import("records.zig").gcExpiredRecords(ttl_arena.allocator(), w) catch |e| std.log.warn("TTL GC at startup failed: {s}", .{@errorName(e)});
        }
    }
    // Instantiate the comptime-selected storage + mailer plugins. The instances are
    // serveImpl stack vars that outlive the server (srv.listen() runs to shutdown),
    // and the vtable handles below point at them.
    var storage_inst = try opts.StoragePlugin.create(allocator, io, cfg);
    defer storage_inst.deinit();
    const storage_iface = storage_inst.interface();

    var mailer_inst = try opts.MailerPlugin.create(allocator, io, cfg);
    defer mailer_inst.deinit();
    const mailer_iface = mailer_inst.interface();

    // Instantiate the comptime-assembled auth method registry. `am_insts` and `am_views`
    // are serveImpl stack vars that outlive the server (like storage/mailer). The Registry
    // value points into `am_views`, so all three must remain in scope across srv.listen().
    const am_types = comptime opts.auth_method_types;
    var am_insts: registry.Instances(am_types) = undefined;
    var am_views: [am_types.len]@import("auth/method.zig").AuthMethod = undefined;
    var am_registry = try registry.build(am_types, &am_insts, &am_views, allocator, io, cfg);
    defer registry.deinit(am_types, &am_insts);

    // In-memory rate limiter for sensitive auth endpoints. A serveImpl stack var that
    // outlives the server (like storage/mailer); skipped entirely when disabled.
    var rate_limiter = ratelimit.RateLimiter.init(allocator, cfg.rate_limit_max, cfg.rate_limit_window_s);
    defer rate_limiter.deinit();

    // Resolve the static-file source from the comptime mode (+ --serve-static in
    // default mode). A configured-but-missing dir is a fatal startup error.
    const static_source: static_files.Source = switch (opts.static_mode) {
        .disabled => .none,
        .dir => |d| .{ .dir = d },
        .embedded => |files| .{ .embedded = files },
        .default => if (cfg.static_dir.len > 0) static_files.Source{ .dir = cfg.static_dir } else .none,
    };
    switch (static_source) {
        .dir => |dir_path| {
            const probe = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch {
                std.log.err("static dir '{s}' is missing or unreadable (from {s})", .{
                    dir_path,
                    if (std.meta.activeTag(opts.static_mode) == .dir) "comptime .static_files" else "--serve-static",
                });
                return error.StaticDirUnavailable;
            };
            probe.close(io);
        },
        else => {},
    }

    // Tier-2 startup validation (issue #183): embedded serve targets were proven at
    // comptime; dir targets are statted here (missing = fatal, like a missing static
    // dir). Routes with NO active source could never serve anything — also fatal.
    if (opts.static_routes.len > 0) switch (static_source) {
        .none => {
            std.log.err("static_routes is configured but no static source is active (run with --serve-static <dir> or set a comptime .static_files source)", .{});
            return error.StaticRoutesRequireStaticSource;
        },
        .dir => |dir_path| {
            if (try static_files.validateRouteTargetsDir(io, allocator, dir_path, opts.static_routes)) |missing| {
                std.log.err("static_routes: serve target '{s}' not found under static dir '{s}'", .{ missing.serve, dir_path });
                return error.StaticRouteTargetMissing;
            }
        },
        .embedded => {},
    };
    // Tier-1 `.spa` marker (issue #183, owner revision): the two sources are handled
    // differently, because only the embedded manifest is comptime-static.
    //
    // - **embedded**: derive the root set once at startup (it can never go stale — the
    //   manifest is baked into the binary) and hand it to `app.spa_roots`.
    // - **dir**: NOT scanned into a cached set — markers are resolved LIVE, per miss,
    //   straight off the filesystem (`static_files.resolveSpaMarkerDirLive`, called from
    //   `serve()`), so adding/removing a `.spa`/`index.html` after boot needs no restart.
    //   Startup only VALIDATES: a `.spa`-marked directory with no `index.html` is a
    //   FATAL startup error (almost certainly a build/deploy mistake — nothing to serve
    //   as the shell); an unreadable subdirectory is skipped with a warning, exactly
    //   like dir-mode serving already treats an unreadable file as if it doesn't exist.
    var spa_validate_failure: static_files.SpaValidateFailure = undefined;
    const spa_roots: []const []const u8 = if (opts.enable_spa_marker) blk: {
        switch (static_source) {
            .embedded => |files| break :blk try static_files.deriveEmbeddedSpaRoots(allocator, files),
            .dir => |dir_path| {
                static_files.validateSpaMarkersDir(io, allocator, dir_path, &spa_validate_failure) catch |err| {
                    if (err == error.SpaValidationFailed) {
                        // `spa_validate_failure.path` was alloc.dupe'd by validateSpaMarkersDir
                        // for this log line only (this is a fail-fast startup path — nothing
                        // downstream reads it, so it doesn't outlive this catch block).
                        defer allocator.free(spa_validate_failure.path);
                        std.log.err(
                            "SPA marker at '{s}/' has no index.html: fix the build/deploy output or remove the marker " ++
                                "(refusing to start — a .spa-marked directory with no shell to serve is treated as fatal, not silently dropped)",
                            .{spa_validate_failure.path},
                        );
                    } else {
                        std.log.err(
                            "SPA marker validation failed on '{s}' ({t}): fix permissions on the static tree or remove the .spa marker",
                            .{ dir_path, err },
                        );
                    }
                    return err;
                };
                break :blk &.{};
            },
            .none => break :blk &.{},
        }
    } else &.{};
    defer static_files.freeSpaRoots(allocator, spa_roots);

    var app = app_mod.App{
        .allocator = allocator,
        .io = io,
        .pool = &pool,
        .jwt_secret = cfg.jwt_secret,
        .public_url = cfg.public_url,
        .cookie_secure = cfg.cookie_secure,
        .auth_token_ttl_s = cfg.auth_token_ttl_s,
        .session_store = opts.session_store,
        .verification_ttl_s = cfg.verification_ttl_s,
        .password_reset_ttl_s = cfg.password_reset_ttl_s,
        .oauth_state_server = cfg.oauth_state_server,
        .oauth_state_ttl_s = cfg.oauth_state_ttl_s,
        .realtime_allowed_origins = cfg.realtime_allowed_origins,
        .trust_proxy = cfg.trust_proxy,
        .max_upload_size = cfg.max_upload_size,
        .file_token_ttl_s = cfg.file_token_ttl_s,
        .sentry_dsn = cfg.sentry_dsn,
        .static_source = static_source,
        .static_routes = opts.static_routes,
        .spa_roots = spa_roots,
        .spa_marker_enabled = opts.enable_spa_marker,
        .pagination = .{
            .offset_enabled = opts.pagination.offset,
            .cursor_enabled = opts.pagination.cursor,
            .cursor_token = opts.pagination.cursor_token,
        },
        .tenancy = opts.tenancy,
        .role_ranking = opts.role_ranking,
        .mail = opts.mail,
        .storage = &storage_iface,
        .mailer = &mailer_iface,
        .auth_methods = @ptrCast(&am_registry),
        .dispatch = dispatch,
        .features = opts.features,
        .experiment_assignment_ttl = opts.experiment_assignment_ttl,
        .features_public_route = opts.features_public_route,
        .queues = if (opts.queues) |r| @as(?*const anyopaque, @ptrCast(r)) else null,
        .analytics = if (opts.analytics) |r| @as(?*const anyopaque, @ptrCast(r)) else null,
        .captcha_provider = opts.captcha_provider,
        .captcha_secret = opts.captcha_secret,
        // Always wire the shared limiter store: the default-scope limiter no-ops when
        // rate_limit_max==0 (RateLimiter.allow returns true for max==0), but a configured
        // per-method custom limit must still be honored against this store regardless of
        // the global default. (null only in tests/CLI that construct App directly.)
        .rate_limiter = &rate_limiter,
    };
    // Loud startup warning for the captcha dev-bypass: a configured provider with an empty
    // secret silently passes EVERY verifyCaptcha (the dev-bypass), a prod footgun. Mirrors
    // the `@public`-rule startup warning so operators catch it before deploying.
    if (opts.captcha_provider != null and opts.captcha_secret.len == 0) {
        std.log.warn("captcha: provider configured but secret is empty — dev-bypass active, ALL captchas will pass; set the secret before deploying", .{});
    }
    const Ctx = @import("ctx.zig").Ctx;
    // Each lifecycle hook gets a per-invocation arena owning any ctx.records()
    // results, declared before cx so its deinit runs last (LIFO).
    if (dispatch.on_bootstrap) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cx = Ctx{ .app = &app, .arena = arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
        defer cx.deinit();
        h(&cx, &ev);
    }
    if (dispatch.on_before_serve) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cx = Ctx{ .app = &app, .arena = arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
        defer cx.deinit();
        h(&cx, &ev);
    }
    // before_terminate fires when listen() returns (graceful shutdown / error).
    defer if (dispatch.on_before_terminate) |h| {
        var ev = events.LifecycleEvent{ .app = &app };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cx = Ctx{ .app = &app, .arena = arena.allocator(), .rctx = .{}, .request = null, .bound_conn = null };
        defer cx.deinit();
        h(&cx, &ev);
    };
    const host_z = try allocator.dupeZ(u8, cfg.http_host);
    defer allocator.free(host_z);
    var srv = server.Server{ .app = &app, .host = host_z, .port = cfg.http_port };
    // Start the scheduler only when jobs are configured. Registered LAST among the teardown
    // defers, so (LIFO) its stop()+deinit() runs FIRST on return — joining worker threads
    // before pool.deinit()/storage_inst go out of scope, since workers touch app.pool/storage.
    var sched: ?scheduler.Scheduler = if (jobs.len > 0) try scheduler.Scheduler.initSized(allocator, &app, jobs, pool_size, opts.job_stack_size) else null;
    if (sched) |*s| try s.start();
    defer if (sched) |*s| {
        s.stop();
        s.deinit();
    };
    try srv.listen();
}

fn superuserCreateImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, sa: cli.SuperuserArgs) !void {
    const email = sa.email orelse {
        std.log.err("--email is required", .{});
        return;
    };
    const password = sa.password orelse {
        std.log.err("--password is required", .{});
        return;
    };
    if (password.len < 8) {
        std.log.err("password must be at least 8 characters", .{});
        return;
    }
    const cfg = try loadCfg(environ, .{ .data_dir = sa.data_dir });
    var pool = try openPoolSelect(allocator, io, cfg, .{}, environ);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.run(w);

    const phc = try crypto.hashPassword(io, allocator, password);
    defer allocator.free(phc);
    const tk = try crypto.genToken(io, allocator, 32);
    defer allocator.free(tk);
    var rid = id_gen.collectionId(io);

    var st = try w.prepare(
        \\INSERT INTO "_superusers" ("id","created","updated","email","username","passwordHash","tokenKey","verified")
        \\ VALUES (?1, datetime('now'), datetime('now'), ?2, '', ?3, ?4, 1);
    );
    defer st.finalize();
    try st.bindText(1, &rid);
    try st.bindText(2, email);
    try st.bindText(3, phc);
    try st.bindText(4, tk);
    _ = st.step() catch {
        std.log.err("could not create superuser (email already exists?)", .{});
        return;
    };
    std.log.info("superuser created: {s}", .{email});
}

fn printTypegenUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\Usage: <app> typegen (--data-dir <path> | --url <origin>) --out <file>
        \\                     [--api-prefix <prefix>] [--client-name <name>] [--check]
        \\                     [--admin-email <e> --admin-password <p>]   (with --url)
        \\
        \\Generates a typed TypeScript client from a running instance's schema.
        \\
    , .{});
}

test "App(cfg) builds a record dispatcher only when hooks are present" {
    const Empty = App(.{});
    try std.testing.expect(Empty.dispatch.record == null);

    const H = struct {
        fn f(ctx: *@import("ctx.zig").Ctx, ev: *@import("events.zig").RecordEvent) anyerror!void {
            _ = ctx;
            _ = ev;
        }
    };
    const WithHook = App(.{ .hooks = .{ .posts = .{ .afterCreate = H.f } } });
    try std.testing.expect(WithHook.dispatch.record != null);
}

fn qTestHandler(ctx: *ctx_mod.Ctx, payload: []const u8) anyerror!void {
    _ = ctx;
    _ = payload;
}

test "App(cfg) synthesizes a default queue + implicit worker; no durable jobs for memory-only" {
    const Bare = App(.{});
    try std.testing.expectEqual(@as(usize, 1), Bare.queue_defs.len);
    try std.testing.expectEqualStrings("default", Bare.queue_defs[0].name);
    try std.testing.expect(!Bare.has_durable_queue);
    // The generated Queue enum carries `.default`; an empty Job enum has no members.
    try std.testing.expectEqualStrings("default", @tagName(@as(Bare.Queue, .default)));
    try std.testing.expectEqual(@as(usize, 0), std.meta.fields(Bare.Job).len);
    // A memory-only app installs NO queue worker/GC jobs.
    for (Bare.jobs) |j| {
        try std.testing.expect(!std.mem.startsWith(u8, j.name, "_queue"));
    }
}

test "App(cfg) lowers .queues/.workers/.jobs and installs durable poller + GC jobs" {
    const A = App(.{
        .queues = .{ .emails = .{ .backend = .durable, .priority = .high } },
        .workers = .{ .mailer = .{ .queues = .{"emails"}, .concurrency = 2 } },
        .jobs = .{ .send = qTestHandler },
    });
    try std.testing.expect(A.has_durable_queue);
    // job_regs = built-ins "mail" (#141) + "webhook" (#144) ++ consumer kinds; built-ins first.
    try std.testing.expectEqual(@as(usize, 3), A.job_regs.len);
    try std.testing.expectEqualStrings("mail", A.job_regs[0].kind);
    try std.testing.expectEqualStrings("webhook", A.job_regs[1].kind);
    try std.testing.expectEqualStrings("send", A.job_regs[2].kind);
    try std.testing.expectEqualStrings("send", @tagName(@as(A.Job, .send)));
    try std.testing.expectEqualStrings("emails", @tagName(@as(A.Queue, .emails)));

    var saw_poller = false;
    var saw_gc = false;
    for (A.jobs) |j| {
        if (std.mem.eql(u8, j.name, "_queue:mailer")) saw_poller = true;
        if (std.mem.eql(u8, j.name, "_queue_gc")) saw_gc = true;
    }
    try std.testing.expect(saw_poller);
    try std.testing.expect(saw_gc);
}

test "App(cfg) keeps legacy .jobs.pool_size working alongside the job registry" {
    // `.jobs.pool_size` is the legacy scheduler-pool lever; it must NOT become a job kind.
    const A = App(.{ .jobs = .{ .pool_size = 3, .resize = qTestHandler } });
    try std.testing.expectEqual(@as(usize, 3), A.job_pool_size);
    // job_regs = built-ins "mail" (#141) + "webhook" (#144) ++ consumer "resize"; pool_size is skipped.
    try std.testing.expectEqual(@as(usize, 3), A.job_regs.len);
    try std.testing.expectEqualStrings("mail", A.job_regs[0].kind);
    try std.testing.expectEqualStrings("webhook", A.job_regs[1].kind);
    try std.testing.expectEqualStrings("resize", A.job_regs[2].kind);
    // The compile-checked Job enum still reflects ONLY the consumer kinds (mail is a
    // built-in reached via ctx.mail().enqueue / ctx.enqueueByName, not the typed enum).
    try std.testing.expectEqual(@as(usize, 1), std.meta.fields(A.Job).len);
}

test "App(cfg) installs the auth-lifecycle dispatcher only for a non-empty .auth group" {
    // No `.auth` at all → null (logout keeps its no-writer fast path).
    try std.testing.expect(App(.{}).dispatch.auth_lifecycle == null);
    // Empty `.auth = .{}` → still null: an empty group must NOT force authLogout onto the
    // writer+authenticate path (the #98 fast-path regression this guards against).
    try std.testing.expect(App(.{ .auth = .{} }).dispatch.auth_lifecycle == null);
    // A registered hook → installed.
    const H = struct {
        fn h(ctx: *@import("ctx.zig").Ctx, ev: *@import("events.zig").AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
        }
    };
    try std.testing.expect(App(.{ .auth = .{ .beforeLogout = H.h } }).dispatch.auth_lifecycle != null);
}

test "App(cfg) wires the realtime canSubscribe guard onto dispatch (#143)" {
    // No `.realtime` → null: custom topics default to PUBLIC signal channels.
    try std.testing.expect(App(.{}).dispatch.realtime_can_subscribe == null);
    // Empty `.realtime = .{}` is allowed and still leaves the guard unset.
    try std.testing.expect(App(.{ .realtime = .{} }).dispatch.realtime_can_subscribe == null);
    // A configured predicate is installed.
    const H = struct {
        fn canSub(ctx: *@import("ctx.zig").Ctx, topic: []const u8) bool {
            _ = topic;
            return ctx.rctx.is_superuser;
        }
    };
    try std.testing.expect(App(.{ .realtime = .{ .canSubscribe = H.canSub } }).dispatch.realtime_can_subscribe != null);
}

test "App(cfg) assembles custom routes onto dispatch" {
    const route_types = @import("route_types.zig");
    const H = struct {
        fn h(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };
    const A = App(.{ .routes = .{.{ .method = .GET, .path = "/api/x", .handler = H.h, .auth = .public }} });
    try std.testing.expectEqual(@as(usize, 1), A.dispatch.routes.len);
    try std.testing.expectEqualStrings("/api/x", A.dispatch.routes[0].pattern);
}

test "App(.{}) has no routes and null lifecycle/auth/file handlers" {
    const A = App(.{});
    try std.testing.expectEqual(@as(usize, 0), A.dispatch.routes.len);
    try std.testing.expect(A.dispatch.on_auth == null);
    try std.testing.expect(A.dispatch.on_bootstrap == null);
}

test "App(cfg) exposes the comptime job table and pool size" {
    const H = struct {
        fn j(ctx: *@import("ctx.zig").Ctx, ev: *@import("events.zig").JobEvent) anyerror!void {
            _ = ctx;
            _ = ev;
        }
    };
    const A = App(.{
        .jobs = .{ .pool_size = 3 },
        .cron = .{.{ .name = "n", .schedule = @import("schedule.zig").Schedule{ .interval = .hourly }, .handler = H.j }},
    });
    try std.testing.expectEqual(@as(usize, 1), A.jobs.len);
    try std.testing.expectEqual(@as(usize, 3), A.job_pool_size);
    const B = App(.{});
    try std.testing.expectEqual(@as(usize, 0), B.jobs.len);
    try std.testing.expectEqual(@as(usize, 2), B.job_pool_size); // default pool size
}

test "App(cfg) registers the internal _ttl_gc job when a collection opts into TTL" {
    // No TTL collection => no internal job, scheduler stays off (jobs empty).
    const Plain = App(.{
        .collections = .{
            .posts = .{ .fields = .{.{ .name = "title", .type = .text }} },
        },
    });
    try std.testing.expect(!Plain.has_ttl_collection);
    try std.testing.expectEqual(@as(usize, 0), Plain.jobs.len);

    // A TTL collection => has_ttl flag set and a single internal `_ttl_gc` job appended.
    const Ttl = App(.{
        .collections = .{
            .sessions = .{ .fields = .{
                .{ .name = "token", .type = .text },
                .{ .name = "expires_at", .type = .date },
            }, .ttl_field = "expires_at" },
        },
    });
    try std.testing.expect(Ttl.has_ttl_collection);
    try std.testing.expectEqual(@as(usize, 1), Ttl.jobs.len);
    try std.testing.expectEqualStrings("_ttl_gc", Ttl.jobs[0].name);
    try std.testing.expect(Ttl.jobs[0].schedule == .interval);
}

test "App(.{}) resolves the default storage + mailer plugins and reader pool" {
    const A = App(.{});
    try std.testing.expectEqual(DefaultStoragePlugin, A.StoragePlugin);
    try std.testing.expectEqual(DefaultMailerPlugin, A.MailerPlugin);
    try std.testing.expectEqual(@as(usize, 16), A.reader_pool_size);
}

test "DefaultMailerPlugin selects Command > SMTP > Log by config" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    // Default config → LogMailer (no SMTP host, no sendmail command).
    {
        var p = try DefaultMailerPlugin.create(a, io, .{});
        defer p.deinit();
        try std.testing.expect(p.command_backend == null);
        try std.testing.expect(p.smtp_backend == null);
    }
    // SMTP host set, no sendmail command → SmtpMailer.
    {
        var p = try DefaultMailerPlugin.create(a, io, .{ .smtp_host = "smtp.example.com" });
        defer p.deinit();
        try std.testing.expect(p.command_backend == null);
        try std.testing.expect(p.smtp_backend != null);
    }
    // sendmail command wins even when SMTP is also configured; argv is split on
    // whitespace and From: defaults from smtp_from.
    {
        var p = try DefaultMailerPlugin.create(a, io, .{
            .smtp_host = "smtp.example.com",
            .sendmail_command = "  msmtp   -t ",
            .smtp_from = "ops@zigbase.dev",
        });
        defer p.deinit();
        try std.testing.expect(p.smtp_backend == null);
        const c = p.command_backend.?;
        try std.testing.expectEqual(@as(usize, 2), c.argv.len);
        try std.testing.expectEqualStrings("msmtp", c.argv[0]);
        try std.testing.expectEqualStrings("-t", c.argv[1]);
        try std.testing.expectEqualStrings("ops@zigbase.dev", c.from);
    }
}

test "App(cfg) carries comptime pool-size levers (readers + jobs)" {
    const A = App(.{ .pools = .{ .readers = 4, .jobs = 2 } });
    try std.testing.expectEqual(@as(usize, 4), A.reader_pool_size);
    try std.testing.expectEqual(@as(usize, 2), A.job_pool_size);
    // readers-only lever; jobs default preserved.
    const B = App(.{ .pools = .{ .readers = 8 } });
    try std.testing.expectEqual(@as(usize, 8), B.reader_pool_size);
    try std.testing.expectEqual(@as(usize, 2), B.job_pool_size);
}

test "App(cfg) carries comptime footprint levers (stack_size + cache_kib) with memory-conscious defaults" {
    // Defaults: 1 MiB job-thread stacks (vs std.Thread's 16 MiB) and 1024 KiB page cache.
    const D = App(.{});
    try std.testing.expectEqual(scheduler.default_job_stack_size, D.job_stack_size);
    try std.testing.expectEqual(@as(usize, 1 << 20), D.job_stack_size);
    try std.testing.expectEqual(db.default_cache_kib, D.cache_kib);
    try std.testing.expectEqual(@as(u32, 1024), D.cache_kib);

    // Both tunable via .pools, independently of the other levers. stack_size RAISES
    // above the 1 MiB default (its real use — deeper handlers); cache_kib shrinks freely.
    const A = App(.{ .pools = .{ .stack_size = 2 << 20, .cache_kib = 256 } });
    try std.testing.expectEqual(@as(usize, 2 << 20), A.job_stack_size);
    try std.testing.expectEqual(@as(u32, 256), A.cache_kib);
    // A below-floor stack request is clamped UP to the safe floor (can't crash the server).
    const C = App(.{ .pools = .{ .stack_size = 64 << 10 } });
    try std.testing.expectEqual(scheduler.min_job_stack_size, C.job_stack_size);
    // Untouched levers keep their defaults alongside the tuned ones.
    try std.testing.expectEqual(@as(usize, 16), A.reader_pool_size);
    try std.testing.expectEqual(@as(usize, 2), A.job_pool_size);
}

test "App(cfg) accepts a custom storage + mailer plugin type override" {
    const MyStorage = struct {
        backend: files_storage.LocalStorage = files_storage.LocalStorage.init("/tmp/x"),
        pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !@This() {
            _ = gpa;
            _ = io;
            _ = cfg;
            return .{};
        }
        pub fn interface(self: *@This()) files_storage.Storage {
            return self.backend.storage();
        }
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };
    const A = App(.{ .storage = MyStorage, .mailer = DefaultMailerPlugin });
    try std.testing.expectEqual(MyStorage, A.StoragePlugin);
    try std.testing.expectEqual(DefaultMailerPlugin, A.MailerPlugin);
}

test "App(cfg) lowers .collections into comptime specs; name-based relation kept by name" {
    const A = App(.{ .collections = .{
        .users = .{ .type = .auth, .fields = .{
            .{ .name = "display_name", .type = .text },
        } },
        .posts = .{ .fields = .{
            .{ .name = "title", .type = .text, .required = true },
            .{ .name = "author", .type = .relation, .target = "users" },
            .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
        }, .rules = .{ .list = "status = \"published\"" } },
    } });
    try std.testing.expectEqual(@as(usize, 2), A.collections.len);
    try std.testing.expectEqualStrings("users", A.collections[0].name);
    try std.testing.expectEqual(schema.CollectionType.auth, A.collections[0].type);
    try std.testing.expectEqualStrings("posts", A.collections[1].name);
    try std.testing.expect(A.collections[1].fields[0].required);
    // relation target stored BY NAME at comptime (resolved to id at provisioning)
    try std.testing.expectEqualStrings("users", A.collections[1].fields[1].options.relation.targetCollectionId);
    try std.testing.expectEqualStrings("status = \"published\"", A.collections[1].listRule.?);
    // stable, 8-char field ids
    try std.testing.expectEqual(@as(usize, 8), A.collections[1].fields[0].id.len);
}

test "App(.{}) has no comptime collections and no provision migrations" {
    const A = App(.{});
    try std.testing.expectEqual(@as(usize, 0), A.collections.len);
    try std.testing.expectEqual(@as(usize, 0), A.provision_migrations.len);
}

test "App(cfg) lowers .flags/.experiments into the registry + generated enums (#128/#129/#130)" {
    const A = App(.{
        .flags = .{
            .checkout_enabled = true,
            .new_dashboard = .{ .default = false, .description = "dark" },
        },
        .experiments = .{
            .checkout_layout = .{ .variants = .{ "control", "compact" }, .weights = .{ 90, 10 } },
        },
    });
    // Metadata slices.
    try std.testing.expectEqual(@as(usize, 2), A.flags.len);
    try std.testing.expectEqualStrings("checkout_enabled", A.flags[0].name);
    try std.testing.expect(A.flags[0].default);
    try std.testing.expectEqual(@as(usize, 1), A.experiments.len);
    try std.testing.expectEqualStrings("checkout_layout", A.experiments[0].name);
    // Static registry mirrors the slices.
    try std.testing.expectEqual(@as(usize, 2), A.features_registry.flags.len);
    try std.testing.expectEqual(@as(usize, 1), A.features_registry.experiments.len);
    // Generated enums: members are the declared names; @intFromEnum indexes the registry.
    try std.testing.expectEqual(@as(usize, 2), std.meta.fields(A.Flag).len);
    try std.testing.expectEqual(@as(usize, 1), std.meta.fields(A.Experiment).len);
    try std.testing.expectEqualStrings("new_dashboard", A.features_registry.flags[@intFromEnum(@field(A.Flag, "new_dashboard"))].name);

    // Empty default: no flags/experiments, empty enums.
    const E = App(.{});
    try std.testing.expectEqual(@as(usize, 0), E.flags.len);
    try std.testing.expectEqual(@as(usize, 0), E.experiments.len);
    try std.testing.expectEqual(@as(usize, 0), std.meta.fields(E.Flag).len);
}

test "App(cfg) lowers the comptime .tenancy config (#156; defaults to disabled)" {
    // Default: tenancy off, default header resolver, default role ladder.
    const D = App(.{});
    try std.testing.expect(!D.tenancy_config.enabled);
    try std.testing.expectEqual(tenancy.Resolver.header, D.tenancy_config.resolver);
    try std.testing.expectEqual(@as(usize, 4), D.role_ranking.roles.len);

    // Explicit: enabled + auth_collection + a custom role ladder.
    const T = App(.{ .tenancy = .{ .enabled = true, .resolver = .header, .auth_collection = "users", .roles = .{ "member", "admin" } } });
    try std.testing.expect(T.tenancy_config.enabled);
    try std.testing.expectEqualStrings("users", T.tenancy_config.auth_collection);
    try std.testing.expectEqual(@as(usize, 2), T.role_ranking.roles.len);
    try std.testing.expect(T.role_ranking.gte("admin", "member"));
    try std.testing.expect(!T.role_ranking.gte("member", "admin"));
}

test "App(cfg) lowers the comptime .abilities config onto the matching collection (#155)" {
    const A = App(.{
        .tenancy = .{ .enabled = true, .auth_collection = "users", .roles = .{ "viewer", "editor", "admin", "owner" } },
        .collections = .{
            .accounts = .{ .fields = .{.{ .name = "name", .type = .text }} },
            .projects = .{ .fields = .{
                .{ .name = "title", .type = .text },
                .{ .name = "account", .type = .relation, .target = "accounts" },
            } },
        },
        .abilities = .{
            .projects = .{
                .view = .{ .relationship = .{ .via = "account" } },
                .update = .{ .relationship = .{ .via = "account", .min_role = .editor } },
            },
        },
    });
    // `accounts` is untouched; `projects` carries the lowered per-action abilities.
    for (A.collections) |c| {
        if (std.mem.eql(u8, c.name, "accounts")) try std.testing.expect(c.options.abilities == null);
        if (std.mem.eql(u8, c.name, "projects")) {
            const ab = c.options.abilities.?;
            try std.testing.expectEqualStrings("account", ab.view.?.relationship.via);
            try std.testing.expectEqualStrings("editor", ab.update.?.relationship.min_role);
            try std.testing.expect(ab.delete == null and ab.create == null);
        }
    }
    // No `.abilities` -> no collection carries any (byte-identical to pre-abilities).
    for (App(.{ .collections = .{ .projects = .{ .fields = .{.{ .name = "title", .type = .text }} } } }).collections) |c|
        try std.testing.expect(c.options.abilities == null);
}

test "App(cfg) resolves the comptime session_store config (#99; defaults to .epoch)" {
    try std.testing.expectEqual(app_mod.SessionStore.epoch, App(.{}).session_store_config);
    try std.testing.expectEqual(app_mod.SessionStore.epoch, App(.{ .session_store = .epoch }).session_store_config);
    try std.testing.expectEqual(app_mod.SessionStore.table, App(.{ .session_store = .table }).session_store_config);
}

test "#114 session-GC job installs in table mode only (absent in epoch); cadence overridable" {
    // Epoch (default): no `_session_gc` job is installed at all — zero-overhead guarantee.
    for (App(.{}).jobs) |j| try std.testing.expect(!std.mem.eql(u8, j.name, "_session_gc"));
    for (App(.{ .session_store = .epoch }).jobs) |j| try std.testing.expect(!std.mem.eql(u8, j.name, "_session_gc"));

    // Table mode: exactly one `_session_gc` job with the default hourly cron.
    {
        var found = false;
        for (App(.{ .session_store = .table }).jobs) |j| if (std.mem.eql(u8, j.name, "_session_gc")) {
            found = true;
            try std.testing.expect(j.schedule == .cron);
            try std.testing.expectEqualStrings("0 * * * *", j.schedule.cron);
        };
        try std.testing.expect(found);
    }

    // `.session_gc_cron` overrides the cadence.
    for (App(.{ .session_store = .table, .session_gc_cron = "*/30 * * * *" }).jobs) |j|
        if (std.mem.eql(u8, j.name, "_session_gc")) try std.testing.expectEqualStrings("*/30 * * * *", j.schedule.cron);

    // Valid combinations compile (the misuse case — session_gc_cron without table — is a
    // @compileError, which can't be unit-tested): default-unset epoch + table-with-override.
    try std.testing.expectEqualStrings("0 * * * *", App(.{}).session_gc_cron);
    try std.testing.expectEqualStrings("*/30 * * * *", App(.{ .session_store = .table, .session_gc_cron = "*/30 * * * *" }).session_gc_cron);
}

test "#129 experiment-GC job installs only when a .sticky experiment is declared" {
    // No experiments / pure-hash experiments: no `_experiment_gc` job — zero-overhead.
    for (App(.{}).jobs) |j| try std.testing.expect(!std.mem.eql(u8, j.name, "_experiment_gc"));
    const PureHash = App(.{ .experiments = .{
        .layout = .{ .variants = .{ "a", "b" }, .weights = .{ 50, 50 } },
    } });
    try std.testing.expect(!PureHash.has_sticky_experiment);
    for (PureHash.jobs) |j| try std.testing.expect(!std.mem.eql(u8, j.name, "_experiment_gc"));

    // A `.sticky` experiment installs exactly one `_experiment_gc` job at the hourly cron.
    const Sticky = App(.{ .experiments = .{
        .layout = .{ .variants = .{ "a", "b" }, .weights = .{ 50, 50 }, .sticky = true },
    } });
    try std.testing.expect(Sticky.has_sticky_experiment);
    {
        var found = false;
        for (Sticky.jobs) |j| if (std.mem.eql(u8, j.name, "_experiment_gc")) {
            found = true;
            try std.testing.expect(j.schedule == .cron);
            try std.testing.expectEqualStrings("0 * * * *", j.schedule.cron);
        };
        try std.testing.expect(found);
    }

    // TTL default is 90 days; the override is honored (the misuse case — TTL without a
    // sticky experiment — is a @compileError, which can't be unit-tested).
    try std.testing.expectEqual(@as(u32, 90), App(.{}).experiment_assignment_ttl);
    try std.testing.expectEqual(@as(u32, 90), Sticky.experiment_assignment_ttl);
    const Custom = App(.{ .experiments = .{
        .layout = .{ .variants = .{ "a", "b" }, .weights = .{ 50, 50 }, .sticky = true },
    }, .experiment_assignment_ttl = 30 });
    try std.testing.expectEqual(@as(u32, 30), Custom.experiment_assignment_ttl);
}

test "App(cfg) resolves the comptime pagination config (defaults + overrides)" {
    // Stock binary: both modes on, stateless tokens.
    const D = App(.{});
    try std.testing.expect(D.pagination_config.offset);
    try std.testing.expect(D.pagination_config.cursor);
    try std.testing.expectEqual(pagination.CursorToken.stateless, D.pagination_config.cursor_token);

    // Token-format selector + enable/disable.
    const S = App(.{ .pagination = .{ .cursor_token = .signed } });
    try std.testing.expectEqual(pagination.CursorToken.signed, S.pagination_config.cursor_token);

    const C = App(.{ .pagination = .{ .offset = false, .cursor_token = .stateful } });
    try std.testing.expect(!C.pagination_config.offset);
    try std.testing.expect(C.pagination_config.cursor);
    try std.testing.expectEqual(pagination.CursorToken.stateful, C.pagination_config.cursor_token);
}

test "App(cfg) static_files modes: default, disabled, dir, embedded (with coercion)" {
    try std.testing.expectEqual(static_files.Mode.default, std.meta.activeTag(App(.{}).static_mode));
    try std.testing.expectEqual(static_files.Mode.disabled, std.meta.activeTag(App(.{ .static_files = .disabled }).static_mode));

    const D = App(.{ .static_files = .{ .dir = "frontend/dist" } });
    try std.testing.expectEqual(static_files.Mode.dir, std.meta.activeTag(D.static_mode));
    try std.testing.expectEqualStrings("frontend/dist", D.static_mode.dir);

    const manifest = struct {
        const F = struct { path: []const u8, bytes: []const u8, etag: []const u8 };
        pub const files = [_]F{.{ .path = "index.html", .bytes = "<p>hi</p>", .etag = "\"abc\"" }};
    };
    const E = App(.{ .static_files = .{ .embedded = &manifest.files } });
    try std.testing.expectEqual(static_files.Mode.embedded, std.meta.activeTag(E.static_mode));
    try std.testing.expectEqual(@as(usize, 1), E.static_mode.embedded.len);
    try std.testing.expectEqualStrings("index.html", E.static_mode.embedded[0].path);
    try std.testing.expectEqualStrings("\"abc\"", E.static_mode.embedded[0].etag);
}

test "App(cfg) static_routes lowering: absent => empty; entries coerced; order preserved" {
    try std.testing.expectEqual(@as(usize, 0), App(.{}).static_routes.len);

    const manifest = struct {
        const F = struct { path: []const u8, bytes: []const u8, etag: []const u8 };
        pub const files = [_]F{
            .{ .path = "index.html", .bytes = "<p>hi</p>", .etag = "\"abc\"" },
            .{ .path = "app/index.html", .bytes = "<p>app</p>", .etag = "\"def\"" },
        };
    };
    const R = App(.{
        .static_files = .{ .embedded = &manifest.files },
        .static_routes = &.{
            .{ .match = "/app/orders/:id", .serve = "/app/index.html" },
            .{ .match = "/app/**", .serve = "/app" }, // directory target -> app/index.html
        },
    });
    try std.testing.expectEqual(@as(usize, 2), R.static_routes.len);
    try std.testing.expectEqualStrings("/app/orders/:id", R.static_routes[0].match);
    try std.testing.expectEqualStrings("/app/index.html", R.static_routes[0].serve);
    try std.testing.expectEqualStrings("/app/**", R.static_routes[1].match);
    try std.testing.expectEqualStrings("/app", R.static_routes[1].serve);

    // Dir mode: no comptime manifest to check against (targets are startup-validated).
    const D = App(.{
        .static_files = .{ .dir = "frontend/dist" },
        .static_routes = &.{.{ .match = "/**", .serve = "/index.html" }},
    });
    try std.testing.expectEqual(@as(usize, 1), D.static_routes.len);
}

test "App(cfg) enable_spa_marker default: true without routes, false with routes, explicit wins" {
    try std.testing.expect(App(.{}).enable_spa_marker);
    try std.testing.expect(!App(.{ .enable_spa_marker = false }).enable_spa_marker);

    const manifest = struct {
        const F = struct { path: []const u8, bytes: []const u8, etag: []const u8 };
        pub const files = [_]F{.{ .path = "index.html", .bytes = "<p>hi</p>", .etag = "\"abc\"" }};
    };
    const WithRoutes = App(.{
        .static_files = .{ .embedded = &manifest.files },
        .static_routes = &.{.{ .match = "/**", .serve = "/index.html" }},
    });
    try std.testing.expect(!WithRoutes.enable_spa_marker); // routes flip the default off

    const Explicit = App(.{
        .static_files = .{ .embedded = &manifest.files },
        .static_routes = &.{.{ .match = "/**", .serve = "/index.html" }},
        .enable_spa_marker = true,
    });
    try std.testing.expect(Explicit.enable_spa_marker); // explicit always wins
}

test "App exposes route metadata for codegen" {
    const route_types = @import("route_types.zig");
    const In = struct { n: u32 };
    const TestApp = App(.{
        .routes = .{
            .{
                .method = .POST,
                .path = "/api/widgets/:id/poke",
                .auth = .authed,
                .handler = struct {
                    fn h(req: *route_types.Req(In)) route_types.RouteError!void {
                        _ = req;
                    }
                }.h,
            },
        },
    });
    try std.testing.expectEqual(@as(usize, 1), TestApp.routes.len);
    try std.testing.expectEqualStrings("widgetsPoke", TestApp.routes[0].name);
    try std.testing.expect(TestApp.routes[0].Input == In);
}

test "anyEncryptedField detects an .encrypted field (drives the startup fail-closed guard)" {
    const none = [_]schema.Collection{.{ .id = "c1", .name = "a", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
    } }};
    try std.testing.expect(!anyEncryptedField(&none));
    const some = [_]schema.Collection{.{ .id = "c2", .name = "b", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "secret", .encrypted = true, .options = .{ .text = .{} } },
    } }};
    try std.testing.expect(anyEncryptedField(&some));
}

test "liveEncryptedCollection detects a RUNTIME-created encrypted collection (drives the #102 startup refusal)" {
    const collections = @import("collections.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A plain collection created at RUNTIME (as via the collections API) — no encrypted
    // field, so the scan finds nothing and serveImpl proceeds even without a key.
    const plain = [_]schema.Field{.{ .id = "", .name = "title", .options = .{ .text = .{} } }};
    _ = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "notes", .fields = &plain });
    try std.testing.expect((try liveEncryptedCollection(a, &d)) == null);

    // Simulate the gap #102 closes: a collection with an encrypted field was created at
    // runtime (while a key was set). It is now DB-resident, invisible to the comptime
    // guard. The scan must surface it so serveImpl refuses to start without a key.
    const enc = [_]schema.Field{.{ .id = "", .name = "secret", .encrypted = true, .options = .{ .text = .{} } }};
    _ = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "vault", .fields = &enc });
    const found = try liveEncryptedCollection(a, &d);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("vault", found.?);
}
