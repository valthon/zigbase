const std = @import("std");
const RequestArena = @import("request_arena.zig").RequestArena;
const builtin = @import("builtin");
const build_options = @import("build_options");
const static_files = @import("static_files.zig");
const app_mod = @import("app.zig");
const events = @import("events.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const logging = @import("logging.zig");
const scaffold = @import("scaffold.zig");
const devtools = @import("devtools.zig");
const server = @import("server.zig");
const serve_control = @import("serve_control.zig");
const serve_session = @import("serve_session.zig");
const migrations = @import("migrations.zig");
const files_storage = @import("files/storage.zig");
const db = @import("db.zig");
const crypto = @import("crypto.zig");
const id_gen = @import("id.zig");
const scheduler = @import("scheduler.zig");
const schema_gen = @import("schema_gen.zig");
const schedule = @import("schedule.zig");
const clock = @import("clock.zig");
const entropy_mod = @import("entropy.zig");
const dev = @import("dev.zig");
const mail = @import("mail/mailer.zig");
const report_reporter = @import("report/reporter.zig");
const report_log = @import("report/log.zig");
const report_sentry = @import("report/sentry.zig");
const report_dedup = @import("report/dedup.zig");
const report_send = @import("report/send.zig");
const provision = @import("provision.zig");
const oauth_client = @import("oauth/client.zig");
const migrator = @import("migrator.zig");
const schema_dump = @import("schema_dump.zig");
const schema_doc = @import("schema_doc.zig");
const openapi = @import("openapi.zig");
const openapi_cli = @import("openapi_cli.zig");
const schema_diff = @import("schema_diff.zig");
const schema = @import("schema.zig");
// Named `collections_mod` (not `collections`): `App(cfg)` declares its own `pub const
// collections` (the lowered comptime collection list), and that name is ambiguous with a
// same-named file-level decl from inside the struct.
const collections_mod = @import("collections.zig");
const collections_api = @import("api/collections.zig");
const ratelimit = @import("ratelimit.zig");
const pagination = @import("pagination.zig");
const registry = @import("auth/registry.zig");
const field_policy = @import("field_policy.zig");
const rewrap = @import("rewrap.zig");
const import_mod = @import("import.zig");
const import_manifest = @import("import_manifest.zig");
const features = @import("features.zig");
const doctor = @import("doctor.zig");
const doctor_run = @import("doctor_run.zig");
const rules_lint = @import("rules_lint.zig");
const ctx_mod = @import("ctx.zig");
const queue = @import("queue/queue.zig");
const error_codes = @import("error_codes.zig");
const queue_config = @import("queue/config.zig");
const queue_durable = @import("queue/durable.zig");
const queue_memory = @import("queue/memory.zig");
const mail_send = @import("mail/send.zig");
const mail_bulk = @import("mail/bulk.zig");
const mail_cfg = @import("mail/config.zig");
const sms_mod = @import("sms/sender.zig");
const sms_twilio = @import("sms/twilio.zig");
const sms_send = @import("sms/send.zig");
const sms_cfg = @import("sms/config.zig");
const files_cfg = @import("files/config.zig");
const webhook = @import("webhook.zig");
const push_send = @import("push/send.zig");
const push_cfg = @import("push/config.zig");
const captcha = @import("captcha.zig");
const tenancy = @import("tenancy/tenancy.zig");
const roles = @import("tenancy/roles.zig");
const abilities_mod = @import("authz/abilities.zig");
const analytics = @import("analytics/analytics.zig");
const analytics_config = @import("analytics/config.zig");
const colcache = @import("colcache.zig");
const feature_cache = @import("feature_cache.zig");
// Opt-in S3-compatible storage backend (`-Ds3`; §D). A stub type when off — the
// db.zig:27 postgres pattern — so `DefaultStoragePlugin` below always compiles, and
// only `-Ds3=true` makes `s3mod.S3Storage` a real, constructible type.
const s3mod = if (build_options.s3) @import("files/s3.zig") else struct {};

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
/// Self-freeing (contract 1): `collections.list`'s returned graph is scratch — freed here on
/// every return — and only an owned dupe of the matched collection's name escapes on `alloc`.
/// Production always calls this with a startup scan arena (see `serveImpl`), so the dupe/free
/// here is just extra bookkeeping reclaimed wholesale like everything else; it also lets a
/// non-arena caller (e.g. a test) use the raw leak-detecting allocator directly.
fn liveEncryptedCollection(alloc: std.mem.Allocator, w: *db.Db) !?[]const u8 {
    const live = try @import("collections.zig").list(alloc, w);
    defer {
        for (live) |c| c.deinit(alloc);
        alloc.free(live);
    }
    for (live) |c| if (schema.hasEncryptedField(c)) return try alloc.dupe(u8, c.name);
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

/// Default storage plugin, config-driven with no code change to switch backends
/// (the DefaultMailerPlugin precedent):
///   1. `cfg.s3_bucket` non-empty AND the binary was built with -Ds3 → `S3Storage`.
///   2. else → `LocalStorage` rooted at `<data_dir>/storage` (unchanged default).
/// A stock (no -Ds3) binary with ZIGBASE_S3_BUCKET set warns LOUDLY and falls back
/// to local — never silent, never fatal (the ZIGBASE_DB_URL postgres:// contract).
pub const DefaultStoragePlugin = struct {
    gpa: std.mem.Allocator,
    root: []const u8,
    backend: Backend,

    const Backend = if (build_options.s3) union(enum) {
        local: files_storage.LocalStorage,
        s3: s3mod.S3Storage,
    } else union(enum) {
        local: files_storage.LocalStorage,
    };

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !DefaultStoragePlugin {
        const root = try std.fmt.allocPrint(gpa, "{s}/storage", .{cfg.data_dir});
        errdefer gpa.free(root);
        if (cfg.s3_bucket.len > 0) {
            if (comptime build_options.s3) {
                return .{ .gpa = gpa, .root = root, .backend = .{ .s3 = try s3mod.S3Storage.create(gpa, io, cfg) } };
            } else {
                std.log.warn(
                    "ZIGBASE_S3_BUCKET is set but this binary was built without -Ds3; " ++
                        "falling back to local storage at {s}/storage (build with -Ds3=true to use S3)",
                    .{cfg.data_dir},
                );
            }
        }
        return .{ .gpa = gpa, .root = root, .backend = .{ .local = files_storage.LocalStorage.init(root) } };
    }

    pub fn interface(self: *DefaultStoragePlugin) files_storage.Storage {
        switch (self.backend) {
            inline else => |*b| return b.storage(),
        }
    }

    pub fn deinit(self: *DefaultStoragePlugin) void {
        if (comptime build_options.s3) {
            switch (self.backend) {
                .s3 => |*s| s.deinit(),
                else => {},
            }
        }
        self.gpa.free(self.root);
    }
};

test "DefaultStoragePlugin: ZIGBASE_S3_BUCKET without -Ds3 warns and falls back to LocalStorage" {
    if (comptime build_options.s3) return error.SkipZigTest; // this test pins the STOCK binary
    const a = std.testing.allocator;
    var p = try DefaultStoragePlugin.create(a, std.testing.io, .{ .data_dir = "/tmp/zb-s3-fallback", .s3_bucket = "prod-bucket" });
    defer p.deinit();
    try std.testing.expect(p.backend == .local); // fail-loud (warn), not fatal, not S3
}

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

/// Default error-reporter plugin (#244), config-driven with no code change to switch backends
/// (the DefaultMailerPlugin precedent):
///   1. `cfg.sentry_dsn` non-empty → `SentryReporter` (POSTs a Sentry envelope).
///   2. else                       → `LogReporter` (the dev/CI + no-Sentry default; logs a
///      structured backstop line `[phase] err_name: message` — see `report_log.formatLine`).
pub const DefaultReporterPlugin = struct {
    log_backend: report_log.LogReporter = .{},
    sentry_backend: ?report_sentry.SentryReporter = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !DefaultReporterPlugin {
        if (cfg.sentry_dsn.len > 0) {
            return .{ .sentry_backend = try report_sentry.SentryReporter.create(gpa, io, cfg) };
        }
        return .{};
    }

    pub fn interface(self: *DefaultReporterPlugin) report_reporter.Reporter {
        if (self.sentry_backend) |*s| return s.interface();
        return self.log_backend.interface();
    }

    pub fn deinit(self: *DefaultReporterPlugin) void {
        if (self.sentry_backend) |*s| s.deinit();
    }
};

test "DefaultReporterPlugin selects Sentry when a DSN is set, else LogReporter" {
    const a = std.testing.allocator;
    var p = try DefaultReporterPlugin.create(a, std.testing.io, .{ .sentry_dsn = "https://pub@o1.ingest.sentry.io/42" });
    defer p.deinit();
    try std.testing.expect(p.sentry_backend != null);

    var p2 = try DefaultReporterPlugin.create(a, std.testing.io, .{});
    defer p2.deinit();
    try std.testing.expect(p2.sentry_backend == null); // log-only (structured backstop line)
}

/// Default SMS provider plugin (#224), config-driven with no code change to switch backends
/// (the DefaultMailerPlugin precedent):
///   1. `cfg.twilio_account_sid` + `twilio_auth_token` + `twilio_from` all set → `TwilioSender`.
///   2. else → `LogSmsSender` (logs the message; the network-free dev/CI/test default so no
///      Twilio credentials are needed).
pub const DefaultSmsPlugin = struct {
    log_backend: sms_mod.LogSmsSender = .{},
    twilio_backend: ?sms_twilio.TwilioSender = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !DefaultSmsPlugin {
        _ = gpa;
        _ = io;
        if (cfg.twilio_account_sid.len > 0 and cfg.twilio_auth_token.len > 0 and cfg.twilio_from.len > 0) {
            return .{ .twilio_backend = sms_twilio.TwilioSender.init(
                cfg.twilio_account_sid,
                cfg.twilio_auth_token,
                cfg.twilio_from,
            ) };
        }
        return .{};
    }

    pub fn interface(self: *DefaultSmsPlugin) sms_mod.SmsSender {
        if (self.twilio_backend) |*t| return t.sender();
        return self.log_backend.sender();
    }

    pub fn deinit(self: *DefaultSmsPlugin) void {
        _ = self;
    }
};

test "DefaultSmsPlugin selects Twilio when all env vars are set, else LogSmsSender" {
    const a = std.testing.allocator;
    // All three set → TwilioSender.
    var p = try DefaultSmsPlugin.create(a, std.testing.io, .{
        .twilio_account_sid = "ACxxx",
        .twilio_auth_token = "tok",
        .twilio_from = "+15550000000",
    });
    defer p.deinit();
    try std.testing.expect(p.twilio_backend != null);

    // Missing any one → LogSmsSender (no network default).
    var p2 = try DefaultSmsPlugin.create(a, std.testing.io, .{ .twilio_account_sid = "ACxxx", .twilio_auth_token = "tok" });
    defer p2.deinit();
    try std.testing.expect(p2.twilio_backend == null);

    var p3 = try DefaultSmsPlugin.create(a, std.testing.io, .{});
    defer p3.deinit();
    try std.testing.expect(p3.twilio_backend == null);
}

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

/// Comptime-validate a migration's forward/reverse-step shape: exactly one of `.change`
/// or `.up` (a `.change` is auto-reversible; an `.up` is explicit-forward), and a `.down`
/// (explicit reverse) requires a forward step to pair with. `id` is threaded only for the
/// error message. Shared by the bare-tuple lowering and the typed-slice branch.
fn validateMigration(comptime id: []const u8, comptime has_change: bool, comptime has_up: bool, comptime has_down: bool) void {
    if (has_change == has_up) @compileError("migration '" ++ id ++ "': set exactly one of .change or .up");
    if (has_down and !has_up and !has_change) @compileError("migration '" ++ id ++ "': .down needs a forward step");
}

/// Comptime-check that every migration id is non-empty and unique across the whole list.
/// `runMigrations` records each entry under `prov:<id>` and skips an already-applied name,
/// so two entries sharing an id (or an empty id, all colliding under `prov:`) would make the
/// second one silently skipped on EVERY environment forever — the whole list is comptime-known,
/// so we reject it at build time like the duplicate-route-name guard (events.zig).
fn validateMigrationIds(comptime migs: []const provision.Migration) void {
    comptime {
        for (migs, 0..) |m, i| {
            if (m.id.len == 0)
                @compileError("migration at index " ++ std.fmt.comptimePrint("{d}", .{i}) ++ " has an empty .id (ids are recorded as 'prov:<id>' and must be non-empty and unique)");
            for (migs[0..i]) |prev| {
                if (std.mem.eql(u8, prev.id, m.id))
                    @compileError("duplicate migration id '" ++ m.id ++ "'; each '.migrations' entry needs a distinct .id (it keys the applied-ledger row, so a duplicate is silently skipped forever)");
            }
        }
    }
}

/// §C.2: one rule for the comptime default AND the runtime override — non-empty,
/// <= 256 bytes, CR/LF-free (header-injection guard; the value goes on the wire
/// verbatim as the Cache-Control header value).
fn validCacheControl(v: []const u8) bool {
    if (v.len == 0 or v.len > 256) return false;
    for (v) |c| if (c == '\r' or c == '\n') return false;
    return true;
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
            const allowed = .{ "hooks", "onError", "routes", "onAuth", "beforeAuthSuccess", "auth", "onFileServe", "onFileUpload", "onBootstrap", "onBeforeServe", "onBeforeTerminate", "cron", "jobs", "storage", "mailer", "reporter", "reporter_dedup", "pools", "collections", "migrations", "static_files", "pagination", "enable_typegen", "flags", "experiments", "features", "onFeatureExposure", "experiment_assignment_ttl", "queues", "workers", "realtime", "tenancy", "abilities", "mail", "analytics", "static_routes", "enable_spa_marker", "static_cache_control", "admin", "webhooks", "ttl_gc_interval", "files", "push", "sms", "sms_provider", "collections_frozen", "app_context" };
            const allowed_list = blk2: {
                var s: []const u8 = "";
                for (allowed, 0..) |name, i| s = s ++ (if (i == 0) "" else "/") ++ name;
                break :blk2 s;
            };
            // Keys that moved under the `.auth` group (E3). Detected BEFORE the generic
            // unknown-key error so a consumer on the old spelling gets a pointed migration
            // message naming the new location instead of a bare "unknown field".
            const moved = .{
                .{ "auth_methods", ".auth = .{ .methods = ... }" },
                .{ "captcha", ".auth = .{ .captcha = ... }" },
                .{ "session_store", ".auth = .{ .session = .{ .store = ... } }" },
                .{ "session_gc_cron", ".auth = .{ .session = .{ .gc_cron = ... } }" },
            };
            for (std.meta.fields(@TypeOf(cfg))) |f| {
                for (moved) |mv| {
                    if (std.mem.eql(u8, f.name, mv[0]))
                        @compileError("'." ++ mv[0] ++ "' moved in the auth config grouping: use '" ++ mv[1] ++ "'");
                }
                var ok = false;
                for (allowed) |name| {
                    if (std.mem.eql(u8, f.name, name)) ok = true;
                }
                if (!ok) @compileError("unknown App cfg field '" ++ f.name ++ "'; expected one of " ++ allowed_list);
            }
            // Validate the `.auth` group's own sub-keys (E3): only `hooks`/`methods`/
            // `captcha`/`session`. A field named like an old FLAT lifecycle hook (the
            // pre-grouping spelling `.auth = .{ .beforeRegister = fn }`) gets a pointed
            // "moved under .auth.hooks" message; anything else is a loud unknown-key error.
            if (@hasField(@TypeOf(cfg), "auth")) {
                const AuthT = @TypeOf(cfg.auth);
                if (@typeInfo(AuthT) != .@"struct")
                    @compileError(".auth must be a config group struct: .auth = .{ .hooks = ..., .methods = ..., .captcha = ..., .session = ... }");
                const hook_names = .{ "beforeRegister", "afterRegister", "beforeLogout", "afterLogout", "beforeRefresh", "afterRefresh", "beforePasswordChange", "afterPasswordChange" };
                for (std.meta.fields(AuthT)) |f| {
                    for (hook_names) |hn| {
                        if (std.mem.eql(u8, f.name, hn))
                            @compileError(".auth hook groups moved under .auth.hooks = .{ ... } (e.g. .auth = .{ .hooks = .{ ." ++ hn ++ " = fn } })");
                    }
                    const sub_ok = std.mem.eql(u8, f.name, "hooks") or std.mem.eql(u8, f.name, "methods") or
                        std.mem.eql(u8, f.name, "captcha") or std.mem.eql(u8, f.name, "session");
                    if (!sub_ok) @compileError(".auth: unknown key '." ++ f.name ++ "' (recognized: .hooks, .methods, .captcha, .session)");
                }
                if (@hasField(AuthT, "hooks")) {
                    const HT = @TypeOf(cfg.auth.hooks);
                    if (@typeInfo(HT) != .@"struct")
                        @compileError(".auth.hooks must be a struct of lifecycle hook functions: .hooks = .{ .beforeRegister = fn, ... }");
                }
                if (@hasField(AuthT, "session")) {
                    const ST = @TypeOf(cfg.auth.session);
                    if (@typeInfo(ST) != .@"struct")
                        @compileError(".auth.session must be a struct: .session = .{ .store = .epoch|.table, .gc_cron = \"...\", .rotation_grace_s = N }");
                    for (std.meta.fields(ST)) |sf| {
                        if (!std.mem.eql(u8, sf.name, "store") and !std.mem.eql(u8, sf.name, "gc_cron") and !std.mem.eql(u8, sf.name, "rotation_grace_s"))
                            @compileError(".auth.session: unknown key '." ++ sf.name ++ "' (recognized: .store, .gc_cron, .rotation_grace_s)");
                    }
                }
            }
            // Validate the `.pools` group's own sub-keys: only the four tuning knobs are read
            // (via `@hasField`), so a typo (e.g. `.stack_sizes`, `.reader`, `.cache_kb`) would
            // otherwise be silently dropped and the default kept — mirror the sibling groups.
            if (@hasField(@TypeOf(cfg), "pools")) {
                const PT = @TypeOf(cfg.pools);
                if (@typeInfo(PT) != .@"struct")
                    @compileError(".pools must be a config group struct: .pools = .{ .jobs = N, .readers = N, .stack_size = N, .cache_kib = N }");
                for (std.meta.fields(PT)) |pf| {
                    const pok = std.mem.eql(u8, pf.name, "jobs") or std.mem.eql(u8, pf.name, "readers") or
                        std.mem.eql(u8, pf.name, "stack_size") or std.mem.eql(u8, pf.name, "cache_kib");
                    if (!pok) @compileError(".pools: unknown key '." ++ pf.name ++ "' (recognized: .jobs, .readers, .stack_size, .cache_kib)");
                }
            }
            var d = events.Dispatch{};
            if (@hasField(@TypeOf(cfg), "hooks")) d.record = events.buildRecordDispatcher(cfg.hooks);
            if (@hasField(@TypeOf(cfg), "onError")) d.on_error = cfg.onError;
            if (@hasField(@TypeOf(cfg), "routes")) {
                d.routes = events.buildRoutes(cfg.routes);
                // #243: every route with a `.auth = .{ .authed = "<col>" }` gate must name a
                // DECLARED auth collection (exists + `.type = .auth`). buildRoutes can't check this
                // (it never sees the collections); `collections` is the lowered set for this App.
                events.assertAuthedCollectionRoutes(d.routes, collections);
            }
            if (@hasField(@TypeOf(cfg), "onAuth")) d.on_auth = cfg.onAuth;
            if (@hasField(@TypeOf(cfg), "beforeAuthSuccess")) d.before_auth_success = cfg.beforeAuthSuccess;
            // Only install the lifecycle dispatcher when `.auth.hooks` has ≥1 hook — an
            // empty (or hook-less) `.auth = .{}` must NOT make `hasAuthLifecycle()` true
            // (that would force authLogout onto the writer+authenticate path for nothing).
            if (@hasField(@TypeOf(cfg), "auth") and @hasField(@TypeOf(cfg.auth), "hooks") and
                std.meta.fields(@TypeOf(cfg.auth.hooks)).len > 0)
                d.auth_lifecycle = events.buildAuthLifecycleDispatcher(cfg.auth.hooks);
            if (@hasField(@TypeOf(cfg), "onFileServe")) d.on_file_serve = cfg.onFileServe;
            if (@hasField(@TypeOf(cfg), "onFileUpload")) d.on_file_upload = cfg.onFileUpload;
            if (@hasField(@TypeOf(cfg), "onBootstrap")) d.on_bootstrap = cfg.onBootstrap;
            // #245 app-scoped context: `.app_context = T` declares a typed handle the
            // consumer sets once in onBootstrap (`ctx.setAppData`) and reads via
            // `ctx.appData(T)`. Validate it is a TYPE at comptime; record its @typeName so
            // serveImpl can fail fast at boot if it was declared but never set.
            if (@hasField(@TypeOf(cfg), "app_context")) {
                if (@TypeOf(cfg.app_context) != type)
                    @compileError("`.app_context` must be a type (e.g. `.app_context = MyAppData`), got a value of type " ++ @typeName(@TypeOf(cfg.app_context)));
                d.app_context_type = @typeName(cfg.app_context);
            }
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
                .{ .name = "_ttl_gc", .schedule = schedule.Schedule{ .interval = ttl_gc_interval }, .handler = ttlGcJob },
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
        /// the `MailMessage` payload and delivers it via `mail/send.zig`. `"mail_batch_item"`
        /// (#154 round 2) backs `ctx.mail().sendBulk` — see `mail/bulk.zig`; it rides the same
        /// mail gate. `"webhook"` (#144) backs `ctx.webhook`. R2-5: each is registered ONLY
        /// when its capability is configured (`enable_mail_job` / `enable_webhooks` above) — an
        /// unconfigured built-in's code does not get pulled into the binary.
        const builtin_job_regs: []const queue.JobReg = blk: {
            var t: []const queue.JobReg = &.{};
            // "report" (#244 stage 2) backs non-blocking error-report delivery. Registered
            // UNCONDITIONALLY — a reporter is always wired (SentryReporter or LogReporter) —
            // and reserved below so a consumer job can never collide. `dispatchError` enqueues
            // it on the memory backend directly (bypassing the registry) so reports never hit
            // the DB writer; the registration reserves the kind + keeps mail/push parity.
            t = t ++ &[_]queue.JobReg{.{ .kind = report_send.job_kind, .handler = report_send.jobHandler }};
            if (enable_mail_job) t = t ++ &[_]queue.JobReg{.{ .kind = "mail", .handler = mail_send.jobHandler }};
            if (enable_mail_job) t = t ++ &[_]queue.JobReg{.{ .kind = mail_bulk.job_kind, .handler = mail_bulk.jobHandler }};
            if (enable_webhooks) t = t ++ &[_]queue.JobReg{.{ .kind = webhook.job_kind, .handler = webhook.webhookJobHandler }};
            if (enable_push_job) t = t ++ &[_]queue.JobReg{.{ .kind = push_send.job_kind, .handler = push_send.jobHandler }};
            if (enable_sms_job) t = t ++ &[_]queue.JobReg{.{ .kind = "sms", .handler = sms_send.jobHandler }};
            break :blk t;
        };

        /// Reserved built-in kind names — reserved UNCONDITIONALLY (even when the
        /// built-in is gated off) so enabling a capability later never collides
        /// with a consumer job kind.
        const reserved_job_kinds: []const []const u8 = &.{ "report", "mail", "mail_batch_item", "webhook", "push", "sms" };

        /// Declared job-kind → handler registry: the built-in kinds followed by the consumer
        /// `.jobs` bindings (the legacy `.jobs.pool_size` key is a compile error — see
        /// `queue_config.reserved_pool_size_key`). `jobByKind` resolves built-ins first so
        /// `"mail"` always reaches the framework handler — and the `assertNoReservedJobKinds`
        /// guard rejects a consumer `.jobs` entry that would collide with a built-in kind (it
        /// would be dead config, never dispatched).
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
        /// `analyticsRollupRun` is `anyerror!void` (non-reactive); `RuntimeJob.run` requires the
        /// uniform `anyerror!?schedule.Reactive` signature, so it is wrapped the same way
        /// `scheduler.buildJobs` wraps non-reactive handlers.
        const analytics_jobs: []const scheduler.RuntimeJob = blk: {
            if (analytics_rollups.len == 0) break :blk &.{};
            const Wrap = struct {
                fn run(ctx: *ctx_mod.Ctx, ev: *events.JobEvent) anyerror!?schedule.Reactive {
                    try analyticsRollupRun(ctx, ev);
                    return null;
                }
            };
            const Holder = struct {
                const table: [analytics_rollups.len]scheduler.RuntimeJob = tbl: {
                    var t: [analytics_rollups.len]scheduler.RuntimeJob = undefined;
                    for (analytics_rollups, 0..) |r, i| t[i] = .{
                        .name = "_rollup:" ++ r.name,
                        .schedule = r.every,
                        .run = Wrap.run,
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
        /// Worker pool size for the scheduler: `.pools = .{ .jobs = N }` (default 2).
        /// The pre-0.10 `.jobs = .{ .pool_size = N }` spelling is a compile error.
        pub const job_pool_size: usize = blk: {
            if (@hasField(@TypeOf(cfg), "jobs") and @hasField(@TypeOf(cfg.jobs), "pool_size"))
                @compileError("'.jobs.pool_size' was removed; set '.pools = .{ .jobs = N }' instead");
            if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "jobs")) break :blk cfg.pools.jobs;
            break :blk 2;
        };

        /// Comptime warm-reader-pool cap (the `.pools.readers` lever). Defaults to 16,
        /// the historical hardcoded value; shrink it to reduce the connection footprint.
        pub const reader_pool_size: usize = if (@hasField(@TypeOf(cfg), "pools") and @hasField(@TypeOf(cfg.pools), "readers")) cfg.pools.readers else 16;

        /// Whether to compile the `typegen` CLI subcommand into the binary.
        /// Off by default so production builds carry no codegen weight.
        pub const enable_typegen: bool = if (@hasField(@TypeOf(cfg), "enable_typegen")) cfg.enable_typegen else false;

        /// R2-5: `.webhooks = true` registers the built-in "webhook" job kind
        /// (managed outbound deliveries via ctx.webhook). Unset → webhook.zig is
        /// not compiled into your binary and ctx.webhook fails at enqueue time.
        pub const enable_webhooks: bool = blk: {
            if (!@hasField(@TypeOf(cfg), "webhooks")) break :blk false;
            if (@TypeOf(cfg.webhooks) != bool)
                @compileError(".webhooks must be a bool; got '" ++ @typeName(@TypeOf(cfg.webhooks)) ++ "'");
            break :blk cfg.webhooks;
        };

        /// R2-5: the "mail" job kind (ctx.mail().enqueue) registers when mail is
        /// configured — a `.mailer` plugin or the `.mail` policy key (use `.mail = .{}`
        /// to enable background delivery with the default env-configured mailer).
        const enable_mail_job: bool = @hasField(@TypeOf(cfg), "mailer") or @hasField(@TypeOf(cfg), "mail");

        /// #223: the "push" job kind (`ctx.push().enqueue`) registers when `.push` is
        /// configured. Unset → `push/send.zig`'s job handler is not compiled into the binary
        /// and `ctx.push().enqueue` fails at enqueue with `error.UnknownJobKind`.
        const enable_push_job: bool = @hasField(@TypeOf(cfg), "push");

        /// The "sms" job kind (ctx.sms().enqueue) registers when SMS is configured — a
        /// `.sms_provider` plugin or the `.sms` policy key (use `.sms = .{}` to enable background
        /// delivery with the default env-configured provider). Unset → sms/send.zig's jobHandler is
        /// not compiled in and ctx.sms().enqueue fails at enqueue time.
        const enable_sms_job: bool = @hasField(@TypeOf(cfg), "sms_provider") or @hasField(@TypeOf(cfg), "sms");

        /// R2-2: `.admin = .disabled` removes the embedded admin SPA (route dispatch
        /// AND the @embedFile'd assets) from the binary. Default: served at /_/ .
        pub const enable_admin: bool = blk: {
            if (!@hasField(@TypeOf(cfg), "admin")) break :blk true;
            const a = cfg.admin;
            if (@TypeOf(a) != @TypeOf(.enum_literal))
                @compileError(".admin: expected the enum literal .disabled (the admin UI is on by default; omit the key to keep it)");
            if (std.mem.eql(u8, @tagName(a), "disabled")) break :blk false;
            @compileError(".admin: unknown value '." ++ @tagName(a) ++ "'; only .disabled is recognized");
        };

        /// True iff `T` is in the assembled auth-method set.
        fn hasAuthMethod(comptime T: type) bool {
            for (auth_method_types) |M| if (M == T) return true;
            return false;
        }

        /// R2-3/R2-4: comptime route gates derived from cfg. The webauthn/magic_link/
        /// oauth2 gates are derived from the assembled `.auth_methods` set (Task 5) —
        /// a deselected built-in's route (and its ~thousands of LOC) never gets pulled
        /// into the binary by Zig's lazy analysis.
        pub const route_gates: server.Gates = .{
            .admin = enable_admin,
            .analytics = @hasField(@TypeOf(cfg), "analytics"),
            .senders = @hasField(@TypeOf(cfg), "mail"),
            .mail_webhook = @hasField(@TypeOf(cfg), "mail"),
            .mail_unsubscribe = @hasField(@TypeOf(cfg), "mail"),
            .tenancy = tenancy_config.enabled,
            .webauthn = hasAuthMethod(@import("auth/methods/webauthn.zig").WebAuthnMethod),
            .magic_link = hasAuthMethod(@import("auth/methods/magic_link.zig").MagicLinkMethod),
            .oauth2 = hasAuthMethod(@import("auth/methods/oauth2.zig").OAuth2Method),
        };

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

        // ── The `.auth` config group (E3) ─────────────────────────────────────
        // All auth config lives under one `.auth = .{ .hooks, .methods, .captcha,
        // .session }` key. These private accessors resolve each sub-group (or its
        // empty-struct default when absent) so the lowerings below read one place.

        /// The `.auth.session` sub-group (`.{ .store, .gc_cron }`) or `.{}` when absent.
        const auth_session_cfg = if (@hasField(@TypeOf(cfg), "auth") and @hasField(@TypeOf(cfg.auth), "session"))
            cfg.auth.session
        else
            .{};

        /// The `.auth.methods` sub-group (tuple or `.{ .builtins, .custom }`) or `.{}` when absent.
        const auth_methods_cfg = if (@hasField(@TypeOf(cfg), "auth") and @hasField(@TypeOf(cfg.auth), "methods"))
            cfg.auth.methods
        else
            .{};

        /// True when `.auth.captcha` is configured.
        const has_captcha = @hasField(@TypeOf(cfg), "auth") and @hasField(@TypeOf(cfg.auth), "captcha");

        /// Comptime session-management model resolved from `.auth.session.store` (#99). Defaults
        /// to `.epoch` (stateless token-epoch revocation). `.table` opts into the server-side
        /// `_sessions` store for per-device list/revoke (DESIGNED-but-STUBBED). An unknown
        /// value is a `@compileError`.
        pub const session_store_config: app_mod.SessionStore = blk: {
            if (!@hasField(@TypeOf(auth_session_cfg), "store")) break :blk .epoch;
            const ss = auth_session_cfg.store;
            if (@TypeOf(ss) != @TypeOf(.enum_literal))
                @compileError(".auth.session.store: expected the enum literal .epoch or .table");
            if (std.mem.eql(u8, @tagName(ss), "epoch")) break :blk .epoch;
            if (std.mem.eql(u8, @tagName(ss), "table")) break :blk .table;
            @compileError(".auth.session.store: unknown value '." ++ @tagName(ss) ++ "'; expected .epoch or .table");
        };

        /// Cadence (UTC, minute-granularity cron) for the table-mode expired-`_sessions` GC
        /// sweep (#114). Default hourly; override with `.auth.session.gc_cron = "..."`. Only
        /// consumed when `.auth.session.store == .table` (otherwise no GC job is installed).
        pub const session_gc_cron: []const u8 = blk: {
            // Fail loudly on misuse: setting the cadence without enabling the table store is a
            // silent no-op otherwise (the GC job is only installed in table mode). Only triggers
            // when the user EXPLICITLY set the key — the default-unset case stays fine.
            if (@hasField(@TypeOf(auth_session_cfg), "gc_cron") and session_store_config != .table)
                @compileError(".auth.session.gc_cron has no effect without .auth.session.store = .table");
            const c = if (@hasField(@TypeOf(auth_session_cfg), "gc_cron")) auth_session_cfg.gc_cron else "0 * * * *";
            // Validate the cron grammar at build time: a malformed override (wrong field count,
            // a full day name, a trailing space) would otherwise make the GC job boot-fire once
            // and then silently retire, so the expired-session sweep never runs on schedule.
            schedule.validateCron(c, ".auth.session.gc_cron");
            break :blk c;
        };

        /// Predecessor-session grace (seconds) after an HTTP auth-refresh rotation — the old
        /// row's expiry is clamped to now+grace instead of being deleted, so requests already
        /// in flight with the old cookie don't 403 through the rotation window. Default 30;
        /// `.auth.session.rotation_grace_s = 0` restores the immediate delete. Table mode only.
        pub const session_rotation_grace_config: i64 = blk: {
            if (@hasField(@TypeOf(auth_session_cfg), "rotation_grace_s") and session_store_config != .table)
                @compileError(".auth.session.rotation_grace_s has no effect without .auth.session.store = .table");
            if (!@hasField(@TypeOf(auth_session_cfg), "rotation_grace_s")) break :blk 30;
            const g: i64 = auth_session_cfg.rotation_grace_s;
            if (g < 0) @compileError(".auth.session.rotation_grace_s must be >= 0");
            break :blk g;
        };

        // Force analysis of `session_gc_cron` (and the rotation-grace guard) so their misuse
        // `@compileError`s (setting `.auth.session.gc_cron`/`.rotation_grace_s` without
        // `.auth.session.store = .table`) actually fire. `session_gc_cron` is otherwise a lazy
        // `pub const` referenced only by the conditionally-installed `_session_gc` job (see
        // `session_gc_jobs`), which is absent in `.epoch` mode — exactly the misuse case — so
        // the const was never analyzed and the guard was silently dead. Referencing them here
        // makes the guards live on every `App(...)`; the valid default and `.store = .table`
        // cases resolve with no error.
        comptime {
            _ = session_gc_cron;
            _ = session_rotation_grace_config;
        }

        /// Cadence for the framework-internal TTL garbage-collection sweep (`_ttl_gc`), which
        /// reaps rows whose `.ttl_field` timestamp has passed. Default `.{ .minutes = 5 }`;
        /// override with `.ttl_gc_interval = .hourly` (or any `schedule.Interval`). Only
        /// consumed when at least one collection declares a `.ttl_field` (otherwise no GC job
        /// is installed). Expired rows are hidden from reads immediately regardless of cadence.
        pub const ttl_gc_interval: schedule.Interval = blk: {
            // Fail loudly on misuse: setting the cadence without a `.ttl_field` collection is a
            // silent no-op otherwise (the `_ttl_gc` job is only installed when has_ttl_collection).
            // Only triggers when the user EXPLICITLY set the key — the default-unset case stays fine.
            if (!@hasField(@TypeOf(cfg), "ttl_gc_interval")) break :blk schedule.Interval{ .minutes = 5 };
            if (!has_ttl_collection)
                @compileError(".ttl_gc_interval set but no collection declares .ttl_field");
            // Config values arrive as untyped literals (`.hourly` enum literal or
            // `.{ .minutes = N }` anon struct); coerce each form to the union explicitly.
            const raw = cfg.ttl_gc_interval;
            const R = @TypeOf(raw);
            const iv: schedule.Interval = if (R == schedule.Interval)
                raw
            else if (R == @TypeOf(.enum_literal))
                @unionInit(schedule.Interval, @tagName(raw), {})
            else if (@typeInfo(R) == .@"struct" and @hasField(R, "minutes"))
                schedule.Interval{ .minutes = raw.minutes }
            else
                @compileError(".ttl_gc_interval must be a schedule.Interval (.weekly / .daily / .hourly / .{ .minutes = N })");
            if (iv == .minutes and iv.minutes == 0)
                @compileError(".ttl_gc_interval must not be zero (.{ .minutes = 0 })");
            break :blk iv;
        };

        // Force analysis of `ttl_gc_interval` so its misuse `@compileError` actually fires. It
        // is otherwise a lazy `pub const` only referenced by the conditionally-installed
        // `_ttl_gc` job (see `ttl_jobs`) — so a consumer that sets `.ttl_gc_interval` WITHOUT a
        // `.ttl_field` collection never installs that job, the const is never analyzed, and the
        // guard is silently dead. Referencing it in this always-analyzed comptime block makes
        // the guard live on every `App(...)` instantiation (the default-unset case resolves to
        // the 5-minute default with no error).
        comptime {
            _ = ttl_gc_interval;
        }

        /// Comptime-selected mailer plugin type (defaults to `DefaultMailerPlugin`).
        /// A custom type missing a contract method fails with a contract-specific message.
        pub const MailerPlugin: type = blk: {
            const P = if (@hasField(@TypeOf(cfg), "mailer")) cfg.mailer else DefaultMailerPlugin;
            assertPluginContract(P, "mailer");
            break :blk P;
        };

        /// Comptime-selected error-reporter plugin type (#244; defaults to `DefaultReporterPlugin`,
        /// which picks `SentryReporter` when a DSN is set, else `LogReporter`). A custom type
        /// missing a contract method fails with a contract-specific message.
        pub const ReporterPlugin: type = blk: {
            const P = if (@hasField(@TypeOf(cfg), "reporter")) cfg.reporter else DefaultReporterPlugin;
            assertPluginContract(P, "reporter");
            break :blk P;
        };

        /// #244 stage 2 — error-report TTL dedup window, in SECONDS. 0 = disabled
        /// (`.reporter_dedup = .off`). Key omitted → the default (`report_dedup.default_window_s`,
        /// 60s): dedup is ON by default. `.reporter_dedup = .{ .window_s = N }` sets a custom
        /// window. Loud `@compileError` on a bad literal/shape/non-positive window. Threaded onto
        /// `ServeOpts.report_dedup_window_s`; serveImpl installs the dedup map only when > 0, so
        /// `.off` compiles out to no map / a single null-pointer branch in `dispatchError`.
        pub const report_dedup_window_s: i64 = blk: {
            if (!@hasField(@TypeOf(cfg), "reporter_dedup")) break :blk report_dedup.default_window_s;
            const rd = cfg.reporter_dedup;
            const T = @TypeOf(rd);
            if (T == @TypeOf(.enum_literal)) {
                if (rd == .off) break :blk 0;
                @compileError(".reporter_dedup: unknown value '." ++ @tagName(rd) ++
                    "'; expected .off or .{ .window_s = N } (seconds)");
            }
            if (@typeInfo(T) != .@"struct")
                @compileError(".reporter_dedup must be .off or .{ .window_s = N } (seconds)");
            for (std.meta.fields(T)) |f| {
                if (!std.mem.eql(u8, f.name, "window_s"))
                    @compileError(".reporter_dedup: unknown key '." ++ f.name ++ "' (recognized: .window_s)");
            }
            if (!@hasField(T, "window_s"))
                @compileError(".reporter_dedup struct must have a .window_s field (seconds), or use .off");
            const w: i64 = rd.window_s;
            if (w <= 0) @compileError(".reporter_dedup.window_s must be > 0 (use .off to disable dedup)");
            break :blk w;
        };

        /// Comptime-selected SMS provider plugin type (#224); defaults to `DefaultSmsPlugin`
        /// (Twilio when the env vars are set, else LogSmsSender). A custom type missing a contract
        /// method fails with a contract-specific message.
        pub const SmsProviderPlugin: type = blk: {
            const P = if (@hasField(@TypeOf(cfg), "sms_provider")) cfg.sms_provider else DefaultSmsPlugin;
            assertPluginContract(P, "sms_provider");
            break :blk P;
        };

        /// Comptime-assembled list of auth method TYPES (built-ins ++ consumer types from
        /// `.auth.methods`). Each type in the list is validated against the auth-method
        /// contract (create/method/deinit) at compile time. Used in serveImpl to
        /// instantiate the Registry stack vars.
        pub const auth_method_types: []const type = blk: {
            const am = @import("auth/method.zig");
            const types = registry.assembleTypes(auth_methods_cfg);
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

        /// §C.2 comptime DEFAULT for the static Cache-Control knob (null = not configured).
        pub const static_cache_control: ?[]const u8 = blk: {
            if (!@hasField(@TypeOf(cfg), "static_cache_control")) break :blk null;
            const v: []const u8 = cfg.static_cache_control;
            if (!validCacheControl(v))
                @compileError(".static_cache_control must be a non-empty, CR/LF-free Cache-Control value of at most 256 bytes");
            break :blk v;
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

        /// Frozen-collection-metadata mode (issue #234). When true the app asserts its
        /// collections do not change after boot + migrations: the collection-metadata cache
        /// runs on ALL backends (incl. Postgres, otherwise skipped for cross-instance-DDL
        /// safety) and the runtime collection create/update/delete endpoints return 403.
        /// Schema then evolves only via `.migrations` + a redeploy. Default: false.
        pub const collections_frozen: bool = blk: {
            if (@hasField(@TypeOf(cfg), "collections_frozen")) {
                if (@TypeOf(cfg.collections_frozen) != bool)
                    @compileError(".collections_frozen must be a bool; got '" ++ @typeName(@TypeOf(cfg.collections_frozen)) ++ "'");
                break :blk cfg.collections_frozen;
            }
            break :blk false;
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
        /// `.migrations` accepts either a bare tuple (`.{ .{ .id = "...", .up = fn }, ... }`,
        /// lowered here like every other list-shaped config key — see `.static_routes`) or a
        /// TYPED slice `&[_]zigbase.Migration{ ... }` (which coerces directly and needs no
        /// lowering). Anything else is a loud `@compileError` naming the PUBLIC type.
        pub const provision_migrations: []const provision.Migration = blk: {
            if (!@hasField(@TypeOf(cfg), "migrations")) break :blk &.{};
            const raw = cfg.migrations;
            if (migrationsCoerce(@TypeOf(raw))) {
                // Typed slice / array ptr — no lowering, but run the same forward-step
                // validation (exactly one of .change/.up; .down needs a forward step).
                for (raw) |entry| validateMigration(entry.id, entry.change != null, entry.up != null, entry.down != null);
                validateMigrationIds(raw);
                break :blk raw;
            }
            // Bare-tuple form (E1): lower each entry to a Migration, mirroring .static_routes.
            const RT = @TypeOf(raw);
            const info = @typeInfo(RT);
            if (info != .@"struct" or !info.@"struct".is_tuple)
                @compileError("'.migrations' must be a tuple of '.{ .id = \"...\", .change = fn }' (or '.up = fn') entries or a typed slice '&[_]zigbase.Migration{ ... }'; got '" ++ @typeName(RT) ++ "'");
            const n = std.meta.fields(RT).len;
            var out: [n]provision.Migration = undefined;
            for (0..n) |i| {
                const entry = raw[i];
                const ET = @TypeOf(entry);
                // Reject a typo'd key (`.transational`, `.donw`, `.chnage`) at compile time
                // rather than silently dropping it — the same unknown-key gate every other
                // list-shaped config key carries (see `.static_routes` above).
                if (@typeInfo(ET) != .@"struct")
                    @compileError(".migrations: each entry must be '.{ .id = \"...\", .change = fn }' (or '.up = fn')");
                for (std.meta.fields(ET)) |mf| {
                    const known = std.mem.eql(u8, mf.name, "id") or std.mem.eql(u8, mf.name, "change") or
                        std.mem.eql(u8, mf.name, "up") or std.mem.eql(u8, mf.name, "down") or
                        std.mem.eql(u8, mf.name, "transactional");
                    if (!known)
                        @compileError(".migrations: unknown key '." ++ mf.name ++ "' (recognized: .id, .change, .up, .down, .transactional)");
                }
                if (!@hasField(ET, "id"))
                    @compileError(".migrations: each entry needs an .id (a stable unique string)");
                const has_change = @hasField(ET, "change");
                const has_up = @hasField(ET, "up");
                const has_down = @hasField(ET, "down");
                validateMigration(entry.id, has_change, has_up, has_down);
                out[i] = provision.Migration{
                    .id = entry.id,
                    .change = if (has_change) entry.change else null,
                    .up = if (has_up) entry.up else null,
                    .down = if (has_down) entry.down else null,
                    .transactional = if (@hasField(ET, "transactional")) entry.transactional else true,
                };
            }
            const final = out;
            validateMigrationIds(&final);
            break :blk &final;
        };

        // ── CAPTCHA (#140 PR6) ────────────────────────────────────────────────
        // Lower `.auth.captcha = .{ .provider = .<provider>, .secret = "..." }` into
        // the serve opts. The only required sub-key is `.provider`; `.secret` defaults
        // to `""` which activates the dev-bypass in `ctx.verifyCaptcha`. Unknown sub-keys
        // are a `@compileError` (mirror the `.features` guard). `has_captcha` (above) is
        // true when the group is configured; here we do the actual lowering.

        /// The comptime-lowered CAPTCHA provider (null when `.auth.captcha` is absent).
        pub const captcha_provider: ?captcha.Provider = blk: {
            if (!has_captcha) break :blk null;
            const cc = cfg.auth.captcha;
            const CT = @TypeOf(cc);
            if (@typeInfo(CT) != .@"struct")
                @compileError(".auth.captcha must be a struct, e.g. '.auth = .{ .captcha = .{ .provider = .recaptcha_v3, .secret = \"...\" } }'");
            for (std.meta.fields(CT)) |f| {
                const ok = blk2: {
                    for (.{ "provider", "secret" }) |k| {
                        if (std.mem.eql(u8, f.name, k)) break :blk2 true;
                    }
                    break :blk2 false;
                };
                if (!ok) @compileError(".auth.captcha: unknown key '." ++ f.name ++ "' (recognized: .provider, .secret)");
            }
            if (!@hasField(CT, "provider"))
                @compileError(".auth.captcha: missing required key .provider — set e.g. .provider = .recaptcha_v3");
            break :blk cc.provider;
        };

        /// The comptime-lowered CAPTCHA secret (`""` = dev-bypass, no network call).
        pub const captcha_secret: []const u8 = blk: {
            if (!has_captcha) break :blk "";
            const cc = cfg.auth.captcha;
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
                    std.mem.eql(u8, f.name, "check_suppression") or std.mem.eql(u8, f.name, "webhook_secret") or
                    std.mem.eql(u8, f.name, "unsubscribe_base_url") or std.mem.eql(u8, f.name, "max_message_bytes");
                if (!ok) @compileError(".mail: unknown key '." ++ f.name ++ "' (recognized: .require_verified_sender, .check_suppression, .webhook_secret, .unsubscribe_base_url, .max_message_bytes)");
            }
            var rt = mail_cfg.Runtime{};
            if (@hasField(MC, "require_verified_sender")) rt.require_verified_sender = mc.require_verified_sender;
            if (@hasField(MC, "check_suppression")) rt.check_suppression = mc.check_suppression;
            if (@hasField(MC, "webhook_secret")) rt.webhook_secret = mc.webhook_secret;
            if (@hasField(MC, "unsubscribe_base_url")) {
                const u = mc.unsubscribe_base_url;
                if (u.len > 0) {
                    if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://"))
                        @compileError(".mail.unsubscribe_base_url must start with http:// or https://");
                    for (u) |c| if (c <= ' ' or c == 127)
                        @compileError(".mail.unsubscribe_base_url must not contain whitespace or control characters");
                }
                rt.unsubscribe_base_url = u;
            }
            if (@hasField(MC, "max_message_bytes")) {
                if (mc.max_message_bytes == 0) @compileError(".mail.max_message_bytes must be > 0");
                rt.max_message_bytes = mc.max_message_bytes;
            }
            break :blk rt;
        };

        /// The comptime-lowered SMS-subsystem knobs (#224), threaded into `app.sms`. Validates
        /// `.sms` keys with a loud `@compileError`; absent → `.{}` (US default region).
        pub const sms_config: sms_cfg.Runtime = blk: {
            if (!@hasField(@TypeOf(cfg), "sms")) break :blk .{};
            const sc = cfg.sms;
            const SC = @TypeOf(sc);
            if (@typeInfo(SC) != .@"struct")
                @compileError(".sms must be a struct, e.g. '.{ .default_region = .us, .queue = \"texts\" }'");
            for (std.meta.fields(SC)) |f| {
                const ok = std.mem.eql(u8, f.name, "default_region") or std.mem.eql(u8, f.name, "queue");
                if (!ok) @compileError(".sms: unknown key '." ++ f.name ++ "' (recognized: .default_region, .queue)");
            }
            var rt = sms_cfg.Runtime{};
            if (@hasField(SC, "default_region")) rt.default_region = sc.default_region;
            if (@hasField(SC, "queue")) rt.queue = sc.queue;
            break :blk rt;
        };

        /// The comptime-lowered file-serving knobs, threaded into `app.files`. Validates the
        /// `.files` group's sub-keys with a loud `@compileError` (unknown key / bad ttl range);
        /// absent → `.{}` (proxy-only, back-compat).
        pub const files_config: files_cfg.Runtime =
            if (@hasField(@TypeOf(cfg), "files")) files_cfg.lower(cfg.files) else .{};

        /// The comptime-lowered Web Push config (#223), threaded into `app.push`. Carries the
        /// VAPID `subject` (the `.push.subject` key); the VAPID KEYPAIR is resolved from env at
        /// startup in serveImpl (`configured` stays false here). Validates the `.push` sub-keys
        /// with a loud `@compileError`; absent → `.{}` (push is a no-op until keys are set).
        pub const push_config: push_cfg.Runtime = blk: {
            if (!@hasField(@TypeOf(cfg), "push")) break :blk .{};
            const pc = cfg.push;
            const PC = @TypeOf(pc);
            for (std.meta.fields(PC)) |f| {
                if (!std.mem.eql(u8, f.name, "subject"))
                    @compileError(".push: unknown key '." ++ f.name ++ "' (recognized: .subject)");
            }
            var rt = push_cfg.Runtime{};
            if (@hasField(PC, "subject")) rt.subject = pc.subject;
            break :blk rt;
        };

        /// Bundle of comptime-resolved knobs threaded into the serve path: the
        /// selected storage/mailer plugin TYPES, the auth method type list,
        /// and the reader-pool cap. Public so the `zigbase.testing` in-process
        /// harness (#239) can name the booted-holder type (`Booted`) it owns.
        pub const Opts = ServeOpts{
            .StoragePlugin = StoragePlugin,
            .MailerPlugin = MailerPlugin,
            .ReporterPlugin = ReporterPlugin,
            .report_dedup_window_s = report_dedup_window_s,
            .SmsProviderPlugin = SmsProviderPlugin,
            .auth_method_types = auth_method_types,
            .reader_pool_size = reader_pool_size,
            .job_stack_size = job_stack_size,
            .cache_kib = cache_kib,
            .static_mode = static_mode,
            .static_routes = static_routes,
            .enable_spa_marker = enable_spa_marker,
            .collections_frozen = collections_frozen,
            .pagination = pagination_config,
            .session_store = session_store_config,
            .session_rotation_grace_s = session_rotation_grace_config,
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
            .sms = sms_config,
            .files = files_config,
            .push = push_config,
            .static_cache_control = static_cache_control,
            .gates = route_gates,
        };

        /// Parse argv and dispatch the CLI (serve / migrate / superuser create / help),
        /// wiring this app's `dispatch` into the runtime context for `serve`.
        pub fn runCli(init: std.process.Init) !void {
            return runCliImpl(init, &dispatch, jobs, job_pool_size, collections, provision_migrations, routes, Opts);
        }

        /// Start the HTTP server directly with an explicit config (no CLI parsing).
        pub fn run(init: std.process.Init, cfg_runtime: config.Config) !void {
            // This path never touches `loadCfg`, which is where the CLI installs the
            // resolved logging config — so apply it here, or an embedding consumer's
            // `cfg.log_format`/`log_level`/`log_requests` would be silently ignored.
            // Exactly one `logging.apply` per entry point: CLI in `loadCfg`, embedded here.
            logging.apply(cfg_runtime.log_format, cfg_runtime.log_level, cfg_runtime.log_requests);
            // Untracked: session management lives in the CLI `.serve` arm only.
            return serveImpl(init.gpa, init.io, cfg_runtime, &dispatch, jobs, job_pool_size, collections, provision_migrations, Opts, init.environ_map, null);
        }

        // ---- In-process test harness seams (#239 stage 3) ----------------------------
        // These expose the socketless boot + route seams for `zigbase.testing`. They are
        // `pub` (part of the App's public surface) but analyzed only when referenced, so a
        // production consumer that never touches `zigbase.testing` pays nothing for them.

        /// The heap-allocated holder type returned by `bootForTest`, parameterized by THIS
        /// app's comptime `Opts` (storage/mailer/sms plugin types + auth-method registry).
        /// `zigbase.testing.Harness` owns a `*Booted` and calls `Booted.deinit()` on teardown.
        pub const Booted = BootedApp(Opts);

        /// Boot the full application against `cfg` WITHOUT binding a socket — runs migrations,
        /// comptime provisioning, and fires `onBootstrap` — returning an owned `*Booted`. The
        /// caller (the `zigbase.testing` harness) must eventually call `holder.deinit()`.
        /// `onBeforeServe` / `onBeforeTerminate` and the scheduler/memory-pool are NOT started;
        /// those belong to the "serve" half. Deterministic-clock/entropy overrides are taken
        /// from `cfg.fake_now_unix` / `cfg.fake_seed`.
        pub fn bootForTest(
            allocator: std.mem.Allocator,
            io: std.Io,
            cfg_runtime: config.Config,
            environ: *const std.process.Environ.Map,
        ) !*Booted {
            return bootApp(allocator, io, cfg_runtime, &dispatch, jobs, job_pool_size, collections, provision_migrations, Opts, environ);
        }

        /// Run the COMPLETE socketless routing/fallback chain (Stage 2's `Server(gates).route`)
        /// for a request context whose `ctx.app` points at a `bootForTest` App. Bound to THIS
        /// app's comptime `route_gates`, so admin/optional route groups match the real binary.
        pub fn routeForTest(ctx: *@import("http.zig").RequestCtx) anyerror!@import("http.zig").Response {
            return server.Server(route_gates).route(ctx);
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
    _ = try @import("records.zig").gcExpiredRecords(ctx.arena.a, w);
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
    try analytics.runRollup(w, ctx.arena.a, spec);
}

/// Comptime knobs threaded from `App(cfg)` into the serve path: which storage /
/// mailer plugin TYPES to instantiate, the assembled auth method type list,
/// and the warm-reader-pool cap.
pub const ServeOpts = struct {
    StoragePlugin: type,
    MailerPlugin: type,
    /// Comptime-selected error-reporter plugin TYPE (#244); defaults to `DefaultReporterPlugin`.
    ReporterPlugin: type = DefaultReporterPlugin,
    /// Comptime-selected SMS provider plugin TYPE (#224); defaults to `DefaultSmsPlugin`.
    SmsProviderPlugin: type = DefaultSmsPlugin,
    /// #244 stage 2 — error-report TTL dedup window in seconds; 0 = disabled. serveImpl
    /// installs the dedup map (on `app.report_dedup`) only when > 0. Default: 60s (on).
    report_dedup_window_s: i64 = report_dedup.default_window_s,
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
    /// Frozen-collection-metadata mode (issue #234); threaded into `app.collections_frozen`.
    /// Installs the collection-metadata cache on ALL backends and 403s the runtime
    /// collection-DDL endpoints.
    collections_frozen: bool = false,
    pagination: pagination.Config = .{},
    /// Selected session-management model (#99); threaded into `App.session_store`.
    session_store: app_mod.SessionStore = .epoch,
    /// Predecessor grace after an auth-refresh rotation (table mode); threaded into
    /// `App.session_rotation_grace_s`.
    session_rotation_grace_s: i64 = 30,
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
    /// SMS-subsystem knobs (#224), threaded into `app.sms`. Default `.{}` = US default region.
    sms: sms_cfg.Runtime = .{},
    /// File-serving knobs, threaded into `app.files`. Default `.{}` is proxy-only (presigned
    /// redirect off) — the byte-identical historical path.
    files: files_cfg.Runtime = .{},
    /// Web Push config (#223), threaded into `app.push`. Carries the VAPID `subject`; the VAPID
    /// keypair is resolved from env in serveImpl. Default `.{}` = push is a no-op.
    push: push_cfg.Runtime = .{},
    /// §C.2: comptime default for the static Cache-Control knob; runtime flag/env override it.
    static_cache_control: ?[]const u8 = null,
    /// Comptime route gates (R2-2/R2-3): which optional built-in route groups + the admin
    /// SPA get compiled in. Default `.{}` (all true) is the historical, byte-identical table.
    gates: server.Gates = .{},
};

/// Zig 0.16 entry point body: parse argv from `init.minimal.args` and dispatch.
fn runCliImpl(init: std.process.Init, dispatch: *const events.Dispatch, jobs: []const scheduler.RuntimeJob, pool_size: usize, schema_collections: []const schema.Collection, schema_migrations: []const provision.Migration, comptime route_meta: []const events.RouteMeta, comptime opts: ServeOpts) !void {
    // Boot-ordering chicken-and-egg (docs/observability.md "Log output"): a bad
    // ZIGBASE_LOG_FORMAT/LEVEL must be reported BY the logger it configures. This
    // pre-pass reads only those two vars and silently ignores an invalid value —
    // the real, fail-fast validation happens moments later in Config.loadDiag,
    // which produces the actionable error. Exactly one validation path.
    logging.preinstallFromEnv(init.environ_map);
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    // cli.parse wants []const []const u8; argv is []const [:0]const u8. Copy
    // the (sentinel-bearing) slices into plain []const u8 views.
    const args = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| args[i] = a;

    const cmd = cli.parse(args[1..], .{
        .serve_static = std.meta.activeTag(opts.static_mode) == .default,
        .static_cache_control = std.meta.activeTag(opts.static_mode) != .disabled,
    }) catch |err| {
        if (err == cli.ParseError.DevToolsDisabled) {
            // Distinguishable from a plain usage error (docs the caller — often an
            // agent that read a doc written for the default, dev-tools-on binary —
            // straight at the fix) instead of falling into the generic "argument
            // error: UnknownCommand" + full-usage-dump path below.
            const verb = if (args.len >= 2) args[1] else "?";
            std.log.err("zigbase {s}: {s}", .{ verb, devtools.disabled_note });
            std.process.exit(1);
        }
        std.log.err("argument error: {s}", .{@errorName(err)});
        printUsage(init.io, std.Io.File.stderr(), std.meta.activeTag(opts.static_mode) == .default, std.meta.activeTag(opts.static_mode) != .disabled);
        // Carried defect fix (SP-1 Task 9, independently also SP-3): a usage error
        // (bad flag/value/unknown command) must exit 1 per the frozen CLI exit-code
        // scheme (docs/observability.md convention 2) — this used to fall through
        // and return normally, exiting 0 on a rejected invocation.
        std.process.exit(1);
    };

    switch (cmd) {
        .help => |topic| switch (topic) {
            .top => printUsage(init.io, std.Io.File.stdout(), std.meta.activeTag(opts.static_mode) == .default, std.meta.activeTag(opts.static_mode) != .disabled),
            .serve => printServeUsage(init.io, std.Io.File.stdout(), std.meta.activeTag(opts.static_mode) == .default, std.meta.activeTag(opts.static_mode) != .disabled),
            .migrate => printMigrateUsage(init.io, std.Io.File.stdout()),
            .rewrap => printRewrapUsage(init.io, std.Io.File.stdout()),
            .superuser_create => printSuperuserUsage(init.io, std.Io.File.stdout()),
            .typegen => printTypegenUsage(init.io, std.Io.File.stdout()),
            .migrate_db => printMigrateDbUsage(init.io, std.Io.File.stdout()),
            .vapid_keygen => printVapidKeygenUsage(init.io, std.Io.File.stdout()),
            .import => printImportUsage(init.io, std.Io.File.stdout()),
            .schema => printSchemaUsage(init.io, std.Io.File.stdout()),
            .openapi => printOpenApiUsage(init.io, std.Io.File.stdout()),
            .explain_code => printExplainCodeUsage(init.io, std.Io.File.stdout()),
            .serve_control => printServeControlUsage(init.io, std.Io.File.stdout()),
            .doctor => printDoctorUsage(init.io, std.Io.File.stdout()),
            .init => printInitUsage(init.io, std.Io.File.stdout()),
            .agents_md => printAgentsMdUsage(init.io, std.Io.File.stdout()),
        },
        .version => |va| if (va.json) printVersionJson(init.io, std.Io.File.stdout()) else printVersion(init.io, std.Io.File.stdout()),
        .serve => |sa_in| {
            var sa = sa_in;
            // --ephemeral fills in ONLY what the user did not specify. This one
            // rule is what makes it compose with --background: the parent
            // resolves both, re-execs the child with them explicit, and the
            // child (seeing them set) allocates nothing.
            //
            // `ephemeral_dir` tracks CLEANUP OWNERSHIP, which is not quite the
            // same question as "did THIS invocation just allocate it": a
            // `--background` child receives its data dir explicitly via a
            // forwarded `--data-dir` (see below), so from the child's own
            // parse it looks exactly like a user-supplied path. It is
            // distinguished from a REAL user `--data-dir` (which must never be
            // deleted, even with `--ephemeral` also set) by the same
            // `ephemeral_prefix` trust boundary `sweepOrphan`/
            // `removeEphemeralDir` already use cross-process to tell "ours"
            // from "someone's real data" — a name no human would pick.
            var ephemeral_dir: ?[]const u8 = null;
            if (sa.ephemeral) {
                if (sa.data_dir == null) {
                    const d = try serve_control.makeEphemeralDir(init.io, arena, init.environ_map);
                    ephemeral_dir = d;
                    sa.data_dir = d;
                } else if (std.mem.indexOf(u8, sa.data_dir.?, serve_control.ephemeral_prefix) != null) {
                    ephemeral_dir = sa.data_dir;
                }
                if (sa.http_port == null) {
                    sa.http_port = try serve_control.pickFreePort(init.io, sa.http_host orelse "127.0.0.1");
                }
            }
            // Registered FIRST so LIFO runs it LAST: after serveImpl returns,
            // after session.shutdown() has removed serve.json and dropped the
            // flock, and after holder.deinit() closed the pool. Unreachable on
            // the --background PARENT's path below, because background()
            // never returns — the CHILD process runs this same arm again (see
            // the forwarded --data-dir below) and registers its OWN copy of
            // this defer, which is what actually deletes the dir.
            defer if (ephemeral_dir) |d| serve_control.removeEphemeralDir(init.io, d);

            const cfg = try loadCfg(init.environ_map, sa);
            // The data dir must exist before the lock file can be created in it.
            ensureDataDir(init.io, cfg.data_dir);
            const data_dir_abs = try std.Io.Dir.cwd().realPathFileAlloc(init.io, cfg.data_dir, arena);

            // `--background` (explicit, agent-detected, or opted out of) is
            // decided BEFORE `--ignore-lock` is consulted: an agent-detected
            // background run still honors an explicit `--ignore-lock` (see
            // `decideBackground`'s precedence), so this must run first.
            const decision = serve_control.decideBackground(
                sa.background,
                init.environ_map.contains(serve_control.background_child_env),
                sa.ignore_lock,
                init.environ_map,
            );
            if (decision.background) {
                if (decision.detected_provider) |p| {
                    std.debug.print(
                        "serve: {s} environment detected — starting in the background (set {s}=0 to disable)\n",
                        .{ p, serve_control.background_optout_env },
                    );
                }
                var child_env = try init.environ_map.clone(arena);
                // A freshly allocated ephemeral dir exists only in THIS
                // process's `sa`, not in the user's original argv — the
                // re-exec'd child must receive it explicitly via --data-dir,
                // or (by the composition rule above) it would independently
                // allocate a DIFFERENT tempdir of its own, and this process's
                // readiness poll — which watches THIS resolved data_dir_abs
                // for serve.json — would never see the child's serve.json
                // appear there. The picked --http-port needs no such
                // forwarding: nothing downstream of this branch uses this
                // process's own pick, and the child reports whatever port IT
                // actually bound in its own serve.json.
                var bg_args: std.ArrayListUnmanaged([]const u8) = .empty;
                try bg_args.appendSlice(arena, args[1..]);
                if (ephemeral_dir) |d| {
                    try bg_args.append(arena, "--data-dir");
                    try bg_args.append(arena, d);
                }
                // `ephemeral_dir`, again: non-null only when THIS process
                // owns the tempdir (freshly allocated it, or it already bore
                // our own naming prefix), never for a real user `--data-dir`.
                // On a failed handoff (the child never becomes ready) this
                // process — not the child — is the one that deletes it; see
                // `background`'s doc comment for why that's a NEW leak surface
                // Task 7 introduced, not the same case as an external
                // `kill -9` of a RUNNING server.
                serve_control.background(init.io, allocator, sa, data_dir_abs, ephemeral_dir, bg_args.items, &child_env);
                // unreachable: background() never returns
            }

            if (sa.ignore_lock) {
                std.log.warn("serve: --ignore-lock: this instance is UNTRACKED (no {s}/{s} is written; 'zigbase serve status/stop/logs' will not find it)", .{ data_dir_abs, serve_session.data_name });
                try serveImpl(allocator, init.io, cfg, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts, init.environ_map, null);
                return;
            }

            // A refused start is an OPERATIONAL condition, not a program fault,
            // so both failure arms below exit with the failure code rather than
            // propagating an error. Returning one made `main` print Zig's
            // generic `error: …` trailer plus a source-annotated stack trace on
            // top of the actionable message — noise that also injects non-JSON
            // lines into a `--log-format json` stream, which no amount of
            // logging configuration can fix because it comes from the runtime,
            // not the log system. Mirrors the parse-error path and the control
            // verbs, where the exit code IS the contract.
            //
            // `std.process.exit` skips deferred cleanup, so the ephemeral
            // tempdir (if this invocation owns one) is removed explicitly in
            // each arm; the registered defer simply never runs.
            var session = switch (try serve_control.openSession(init.io, allocator, .{
                .data_dir_abs = data_dir_abs,
                .host = cfg.http_host,
                .port = cfg.http_port,
                // Derived from the recursion guard, NOT from sa.background: by
                // the time a backgrounded server actually runs it IS the child,
                // and filterBackgroundArgs already stripped --background from
                // its argv. Conflating the two env vars is precisely what
                // corrupts this field in Astro's implementation.
                .background = init.environ_map.contains(serve_control.background_child_env),
                .ephemeral = sa.ephemeral,
            })) {
                .opened => |s| s,
                .held => {
                    std.log.err("refusing to start: another zigbase serve session already owns the data dir '{s}'. Inspect it with `zigbase serve status`, stop it with `zigbase serve stop`, or start an untracked instance with `zigbase serve --ignore-lock`.", .{data_dir_abs});
                    if (ephemeral_dir) |d| serve_control.removeEphemeralDir(init.io, d);
                    std.process.exit(1);
                },
                // Distinct from `.held` on purpose: there is no session here to
                // inspect or stop, so naming one would send an operator chasing
                // a process that does not exist. The cause is the data dir
                // itself, and so is the remedy.
                .unavailable => |e| {
                    std.log.err("refusing to start: cannot create the session lock file '{s}/{s}': {s}. The data dir must exist and be writable by this user — a read-only mount, wrong ownership, or a stray directory of that name are the usual causes. To run without session tracking entirely, pass `zigbase serve --ignore-lock`.", .{ data_dir_abs, serve_session.lock_name, @errorName(e) });
                    if (ephemeral_dir) |d| serve_control.removeEphemeralDir(init.io, d);
                    std.process.exit(1);
                },
            };
            defer session.shutdown();
            try serveImpl(allocator, init.io, cfg, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts, init.environ_map, &session);
        },
        .serve_control => |ca| try serveControlImpl(allocator, init.io, init.environ_map, ca),
        // schema_migrations is threaded from the start, even though the Task 3
        // stub ignores it: Task 9's real doctor needs the binary's compiled-in
        // `.migrations` to judge the migrations check, and settling the call
        // shape now means this dispatch line is written once.
        .doctor => |da| try doctorImpl(allocator, init.io, init.environ_map, da, schema_migrations),
        .migrate => |ma| switch (ma.action) {
            .apply => try migrateImpl(allocator, init.io, init.environ_map, ma, schema_migrations),
            .status => try migrateStatusImpl(allocator, init.io, init.environ_map, ma, schema_migrations),
            .rollback => try migrateRollbackImpl(allocator, init.io, init.environ_map, ma, schema_migrations),
            .dump => try migrateDumpImpl(allocator, init.io, init.environ_map, ma),
        },
        .schema => |sa| switch (sa.action) {
            .dump => try schemaDumpImpl(allocator, init.io, init.environ_map, sa),
            .apply => try schemaApplyImpl(allocator, init.io, init.environ_map, sa, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts),
            .check_rules => try schemaCheckRulesImpl(allocator, init.io, init.environ_map, sa),
        },
        .openapi => |oa| try openApiImpl(route_meta, allocator, init.io, init.environ_map, oa),
        .rewrap => |ra| try rewrapImpl(allocator, init.io, init.environ_map, ra),
        .import => |ia| try importImpl(allocator, init.io, init.environ_map, ia, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts),
        .migrate_db => |ma| try migrateDbImpl(allocator, init.io, ma),
        .superuser_create => |sa| try superuserCreateImpl(allocator, init.io, init.environ_map, sa),
        .vapid_keygen => try vapidKeygenImpl(allocator, init.io),
        .explain_code => |ea| explainCodeImpl(init.io, ea),
        .init => |ia| try initImpl(allocator, init.io, ia),
        .agents_md => |aa| try agentsMdImpl(allocator, init.io, aa),
        .typegen => |ta| {
            if (!devtools.enabled) {
                // Unreachable via the CLI in practice: cli.parse rejects `typegen`
                // with ParseError.DevToolsDisabled before dispatch ever reaches
                // here in a `-Ddev-tools=false` build. Kept only so this arm's
                // analyzed body never references codegen/typegen_cli.zig (and the
                // ~24-file codegen/** subtree behind it) in a stripped binary.
                std.log.err("zigbase typegen: {s}", .{devtools.disabled_note});
                std.process.exit(1);
            }
            if (opts.enable_typegen) {
                const tgen = @import("codegen/typegen_cli.zig");
                var arena_state = std.heap.ArenaAllocator.init(init.gpa);
                defer arena_state.deinit();
                const a = arena_state.allocator();
                const out = ta.out orelse {
                    std.log.err("typegen: --out <path> is required", .{});
                    return error.MissingOut;
                };
                const lang = tgen.parseLang(ta.lang) catch return error.BadLang;
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
                    .lang = lang,
                    .kotlin_package = ta.package,
                });
            } else {
                std.log.err("typegen: this binary was not built with .enable_typegen = true", .{});
                // Same swallowed-failure shape the parse-error catch above had:
                // a bare `return;` here would exit 0 despite refusing to run.
                // `return error.X` matches this arm's own idiom two branches up
                // (MissingOut / BadLang) and — like those — yields a non-zero
                // exit via the top-level `!void` main's normal error handling.
                return error.TypegenNotEnabled;
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
/// `show_static_cache_control` mirrors the broader --static-cache-control gate:
/// available in every mode except `.disabled`.
fn printUsage(io: std.Io, file: std.Io.File, show_serve_static: bool, show_static_cache_control: bool) void {
    emit(io, file,
        \\zigbase — a single-binary backend (REST + WebSocket + admin UI)
        \\Docs & source: https://github.com/valthon/zigbase
        \\
        \\USAGE:
        \\  zigbase <command> [flags]
        \\
        \\COMMANDS:
        \\  serve               Start the HTTP server (REST + WebSocket + admin UI at /_/).
        \\  serve stop|status|logs   Manage a background `serve` session (see `zigbase serve status --help`).
        \\  doctor              Preflight checks; --production escalates, --json emits NDJSON. Exits 1 on any error.
        \\  migrate             Apply database migrations, then exit. `status` reports; `rollback [N]` reverses; `dump` dumps the live schema.
        \\  rewrap              Re-encrypt all encrypted fields under the primary key (key rotation).
        \\  migrate-db          Copy an existing SQLite instance into PostgreSQL (requires -Dpostgres).
        \\  import              Bulk-import NDJSON records offline (through the engine: validation + encryption).
        \\  schema              Dump the collection model as JSON, apply a schema document, or
        \\                      `check-rules` to lint access-rule expressions before they ship.
        \\  openapi             Export collection and consumer-route contracts as OpenAPI JSON.
        \\  superuser create    Create an admin (superuser) account.
        \\  vapid-keygen        Generate a VAPID (Web Push) keypair for ctx.push().
        \\  explain-code        Explain a frozen API error code, or list them all. Add --json for one JSON object.
        \\
    , .{});
    // init/agents-md/typegen are pure development-time surfaces (see src/devtools.zig); a
    // `-Ddev-tools=false` binary doesn't compile them in, so help must not advertise
    // them there. Every published zigbase artifact builds at the default (dev-tools
    // on), so this only ever hides these lines for a consumer's own custom build.
    if (devtools.enabled) emit(io, file,
        \\  init                Scaffold a starting-point project (--box or --framework).
        \\  agents-md           Write AGENTS.md + CLAUDE.md for an existing project.
        \\  typegen             Generate a typed client from the collection schema (see `zigbase typegen --help`).
        \\
    , .{});
    emit(io, file,
        \\  help                Show this help. Also: --help, -h, or no arguments.
        \\  version             Print version + build provenance. Also: --version, -V. Add --json for one JSON object.
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
        \\  --sse-heartbeat-seconds N  SSE heartbeat (": ping") interval in seconds (serve only).
        \\                      0 = inherit the 40s listener timeout. [env ZIGBASE_SSE_HEARTBEAT_SECONDS]
        \\  --realtime-outbound-hwm N  Disconnect a slow WS/SSE consumer once its queued outbound
        \\                      frames exceed N (serve only). 0 disables. [env ZIGBASE_REALTIME_OUTBOUND_HWM]
        \\  --log-format F      text|json (serve only). json emits one JSON object per line on
        \\                      stderr. [env ZIGBASE_LOG_FORMAT, default text]
        \\  --log-level L       debug|info|warn|error (serve only). [env ZIGBASE_LOG_LEVEL, default info]
        \\  --no-request-log    Suppress per-request access lines (serve only). [env ZIGBASE_LOG_REQUESTS]
        \\
    , .{});
    if (show_serve_static) emit(io, file,
        \\  --serve-static DIR  Serve static files from DIR at the root path (serve only;
        \\                      available unless the app hardcodes static files at comptime).
        \\
    , .{});
    if (show_static_cache_control) emit(io, file,
        \\  --static-cache-control V  Cache-Control value for static responses (also ZIGBASE_STATIC_CACHE_CONTROL). [default max-age=3600]
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
        \\  ZIGBASE_DB_URL           postgres://… routes storage to Postgres (-Dpostgres builds);
        \\                           unset = embedded SQLite in the data dir.
        \\  ZIGBASE_COOKIE_SECURE     Secure flag on auth cookies (true/1). Secure by default; set
        \\                           false only for plain-HTTP local dev. [default true]
        \\  ZIGBASE_TRUST_PROXY       Trust X-Forwarded-For/X-Real-IP (true/1). Set ONLY behind a
        \\                           trusted reverse proxy.          [default false]
        \\  ZIGBASE_SERVE_BACKGROUND  Set 1 to force `serve` into the background; any other value
        \\                           disables the auto-backgrounding a detected AI-agent
        \\                           environment triggers.           [default: auto-detect]
        \\  ZIGBASE_SENTRY_DSN        Sentry DSN for error reporting; empty logs errors to stderr.
        \\                           [default empty]
        \\  ZIGBASE_REALTIME_ORIGINS  CSV of allowed WebSocket Origins. Empty DENIES cross-origin
        \\                           browser upgrades.               [default empty]
        \\  ZIGBASE_SSE_HEARTBEAT_SECONDS  SSE keep-alive comment interval, 0 or 1..=255; 0 inherits
        \\                           the 40s listener timeout.       [default 0]
        \\  ZIGBASE_REALTIME_OUTBOUND_HWM  Disconnect a slow WS/SSE consumer once its queued outbound
        \\                           frames exceed this; 0 disables.  [default 1024]
        \\  ZIGBASE_MAX_UPLOAD_SIZE   Max request body for uploads, in bytes. [default 52428800 = 50 MiB]
        \\  ZIGBASE_AUTH_TOKEN_TTL    Auth token lifetime, seconds.  [default 1209600 = 14 days]
        \\  ZIGBASE_VERIFICATION_TTL  Email-verification token TTL, seconds. [default 604800 = 7 days]
        \\  ZIGBASE_PASSWORD_RESET_TTL Password-reset token TTL, seconds.    [default 3600 = 1 hour]
        \\  ZIGBASE_FILE_TOKEN_TTL    Short-lived file-access token TTL, seconds. [default 120 = 2 min]
        \\  ZIGBASE_STATIC_CACHE_CONTROL  Cache-Control for static responses (embedded + dir). Flag
        \\                           --static-cache-control wins over env. [default max-age=3600]
        \\  ZIGBASE_FIELD_KEY         Key for at-rest field encryption (.encrypted fields). Never
        \\                           auto-generated/persisted/logged. Required if any field is encrypted.
        \\  ZIGBASE_FIELD_KEY_GENERATION  Generation of the primary key = envelope version written
        \\                           (v<N>:). Bump to rotate; then run `zigbase rewrap`. [default 1]
        \\  ZIGBASE_FIELD_KEY_V<n>    Older read-only key for generation <n> (decrypts existing v<n>: data).
        \\  ZIGBASE_FIELD_CRYPTO     DEV BUILDS ONLY (-Ddev-mode): set "fake" to store .encrypted fields
        \\                           as readable fake:<key>:<value> instead of AES-GCM. Compiled out of
        \\                           release binaries; never read there.       [default real]
        \\  ZIGBASE_PUBLIC_URL       Public base URL for user-facing links (magic-link emails).
        \\  ZIGBASE_UNSUBSCRIBE_BASE_URL Public base URL for the RFC 8058 one-click unsubscribe
        \\                           endpoint. Empty disables the feature. [default: off]
        \\  ZIGBASE_RATE_LIMIT_MAX    Max sensitive-auth attempts per window per client; 0 disables.
        \\                           [default 10]
        \\  ZIGBASE_RATE_LIMIT_WINDOW Rate-limit window length, seconds. [default 60]
        \\  ZIGBASE_OAUTH_STATE_SERVER Server-side OAuth state (CSRF) store (true/1). [default true]
        \\  ZIGBASE_OAUTH_STATE_TTL  Server-side OAuth state lifetime, seconds. [default 600 = 10 min]
        \\  ZIGBASE_SMTP_HOST        SMTP server host; unset logs mail instead of sending. [default: log]
        \\  ZIGBASE_SMTP_PORT        SMTP server port.             [default 25]
        \\  ZIGBASE_SMTP_USERNAME    SMTP username; non-empty enables AUTH LOGIN.
        \\  ZIGBASE_SMTP_PASSWORD    SMTP password.
        \\  ZIGBASE_SMTP_FROM        Envelope + From: address.     [default noreply@zigbase.dev]
        \\  ZIGBASE_SMTP_TLS         Transport security: none/starttls/implicit/auto. [default auto]
        \\  ZIGBASE_SMTP_INSECURE    Skip TLS cert verification (self-signed relays only). [default false]
        \\  ZIGBASE_SENDMAIL_COMMAND Pipe outbound mail to this command instead of SMTP; takes
        \\                           precedence over ZIGBASE_SMTP_HOST.
        \\  ZIGBASE_TWILIO_ACCOUNT_SID  Twilio Account SID; set (with token+from) to send ctx.sms()
        \\                           via Twilio instead of logging. [default: log]
        \\  ZIGBASE_TWILIO_AUTH_TOKEN   Twilio auth token (HTTP Basic auth).
        \\  ZIGBASE_TWILIO_FROM      Twilio sender number, E.164 (e.g. +15551234567).
        \\  ZIGBASE_S3_BUCKET        Opt-in S3-compatible storage (needs -Ds3=true build); non-empty
        \\                           selects S3 instead of local disk. [default: off]
        \\  ZIGBASE_S3_REGION        AWS region (SigV4 + default endpoint). [default us-east-1]
        \\  ZIGBASE_S3_ENDPOINT      Custom endpoint (MinIO/R2/…); empty → s3.<region>.amazonaws.com.
        \\  ZIGBASE_S3_ACCESS_KEY_ID     SigV4 access key id (required with ZIGBASE_S3_BUCKET).
        \\  ZIGBASE_S3_SECRET_ACCESS_KEY SigV4 secret access key (required with ZIGBASE_S3_BUCKET).
        \\  ZIGBASE_S3_FORCE_PATH_STYLE  Force path-style addressing (true/1); unset auto-selects.
        \\  ZIGBASE_S3_KEY_PREFIX    Prefix prepended to every object key (namespace one bucket).
        \\  ZIGBASE_S3_CACHE_DIR     Local spool-cache dir; empty → <data-dir>/storage_cache.
        \\  ZIGBASE_S3_CACHE_MAX_BYTES   Spool-cache size cap, bytes. [default 1073741824 = 1 GiB]
        \\  ZIGBASE_VAPID_PUBLIC_KEY  Web Push VAPID public key (base64url) for ctx.push(); also the
        \\                           browser applicationServerKey. Generate with `zigbase vapid-keygen`.
        \\  ZIGBASE_VAPID_PRIVATE_KEY Web Push VAPID private key (base64url) — SECRET. Both keys unset
        \\                           → ctx.push() is a no-op. [default: off]
        \\  ZIGBASE_LOG_FORMAT          text|json — log line encoding (json = one object per line). Default text.
        \\  ZIGBASE_LOG_LEVEL           debug|info|warn|error — minimum severity. Default info.
        \\  ZIGBASE_LOG_REQUESTS        true|false — per-request access lines. Default true.
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
        \\  # Start detached and use it immediately (exits 0 only once it answers):
        \\  zigbase serve --background --data-dir ./zb_data && zigbase serve status --json --data-dir ./zb_data
        \\
        \\  # A throwaway backend for a test run — one JSON line, then it is yours:
        \\  zigbase serve --background --ephemeral
        \\
        \\  # Preflight before shipping:
        \\  zigbase doctor --production --data-dir /var/lib/zigbase
        \\
        \\After `serve` starts, open http://127.0.0.1:8090/_/ for the admin UI.
        \\More docs: README.md, docs/api.md, docs/framework.md, docs/tutorial.md.
        \\
    , .{});
}

/// Human-readable note on whether the sqlite-vec amalgamation is actually linked into
/// this binary (it is compiled in ONLY with `-Dvector`), so `--version` never implies a
/// vendored version is active when the default build folds it away.
const sqlite_vec_note = if (build_options.vector) "linked" else "not linked; build -Dvector to enable";

/// Print build provenance + baked-in component versions (for `--version`) to stdout (#282).
/// emit() keeps it prefix-free. The component block mirrors the `versions:` startup log line
/// and the `versions` object on `GET /api/health` — one source of truth (build_options).
fn printVersion(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase {s}
        \\commit:      {s}
        \\build:       {s}
        \\target:      {s}-{s}-{s}
        \\zig:         {s}
        \\
        \\Vendored/native components:
        \\  sqlite:     {s} (source {s})
        \\  sqlite-vec: {s} ({s})
        \\  zap:        {s} (commit {s})
        \\  facil.io:   {s}
        \\
    , .{
        build_options.version,
        build_options.commit,
        @tagName(builtin.mode),
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
        builtin.zig_version_string,
        build_options.sqlite_version,
        build_options.sqlite_source_id,
        build_options.sqlite_vec_version,
        sqlite_vec_note,
        build_options.zap_version,
        build_options.zap_commit,
        build_options.facil_version,
    });
}

/// `zigbase version --json` (SP-1). Exactly one object on stdout; same build_options
/// source of truth as `printVersion` and `GET /api/health`'s `versions`, so the three
/// can never disagree. Key order is contract.
fn printVersionJson(io: std.Io, file: std.Io.File) void {
    emit(io, file, "{{\"zigbase\":{f},\"commit\":{f},\"build\":\"{s}\",\"target\":\"{s}-{s}-{s}\",\"zig\":{f}," ++
        "\"components\":{{\"sqlite\":{f},\"sqlite_source_id\":{f},\"sqlite_vec\":{f},\"sqlite_vec_linked\":{}," ++ "\"zap\":{f},\"zap_commit\":{f},\"facil\":{f}}}}}\n", .{
        std.json.fmt(build_options.version, .{}),
        std.json.fmt(build_options.commit, .{}),
        @tagName(builtin.mode),
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
        std.json.fmt(builtin.zig_version_string, .{}),
        std.json.fmt(build_options.sqlite_version, .{}),
        std.json.fmt(build_options.sqlite_source_id, .{}),
        std.json.fmt(build_options.sqlite_vec_version, .{}),
        build_options.vector,
        std.json.fmt(build_options.zap_version, .{}),
        std.json.fmt(build_options.zap_commit, .{}),
        std.json.fmt(build_options.facil_version, .{}),
    });
}

fn printServeUsage(io: std.Io, file: std.Io.File, show_serve_static: bool, show_static_cache_control: bool) void {
    emit(io, file,
        \\zigbase serve — start the HTTP server (REST API + WebSocket + admin UI at /_/).
        \\
        \\USAGE:
        \\  zigbase serve [--http-host H] [--http-port N] [--data-dir PATH]
        \\                [--insecure-cookies] [--trust-proxy] [--realtime-origins CSV]
        \\                [--sse-heartbeat-seconds N] [--realtime-outbound-hwm N]
        \\                [--log-format F] [--log-level L] [--no-request-log]{s}
        \\                [--background] [--ephemeral] [--ignore-lock] [--force]
        \\
        \\FLAGS:
        \\  --http-host H    Address to bind; loopback by default. Pass 0.0.0.0 for all
        \\                   interfaces.        [env ZIGBASE_HTTP_HOST, default 127.0.0.1]
        \\  --http-port N    TCP port to listen. [env ZIGBASE_HTTP_PORT, default 8090]
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\  --insecure-cookies   Drop the Secure cookie flag (plain-HTTP local dev only).
        \\  --trust-proxy        Trust X-Forwarded-For/X-Real-IP (behind a trusted proxy only).
        \\  --realtime-origins CSV  Allowed WebSocket Origins; empty denies cross-origin upgrades.
        \\  --sse-heartbeat-seconds N  SSE heartbeat interval in seconds; 0 inherits the 40s
        \\                         listener timeout. [env ZIGBASE_SSE_HEARTBEAT_SECONDS]
        \\  --realtime-outbound-hwm N  Disconnect a slow WS/SSE consumer past N queued outbound
        \\                         frames; 0 disables. [env ZIGBASE_REALTIME_OUTBOUND_HWM]
        \\  --log-format F      text|json. json emits one JSON object per line on stderr.
        \\  --log-level L       debug|info|warn|error. Default info.
        \\  --no-request-log    Suppress the per-request access lines.
        \\
        \\  The three logging knobs also work as ZIGBASE_LOG_FORMAT / ZIGBASE_LOG_LEVEL /
        \\  ZIGBASE_LOG_REQUESTS, which apply to every subcommand (these flags are serve-only).
        \\
        \\  --background     Detach into a new process group; write output to
        \\                   <data-dir>/serve.log and exit 0 once the server answers.
        \\                   Automatic in a detected AI-agent environment.
        \\                   [env ZIGBASE_SERVE_BACKGROUND]
        \\  --ephemeral      Use a fresh temp data dir and a free port (only for whichever
        \\                   of --data-dir/--http-port you did not pass), and print
        \\                   {{"url","port","data_dir","pid"}} on stdout when ready.
        \\  --ignore-lock    Start an UNTRACKED instance: take no session lock and write no
        \\                   serve.json. Invisible to `serve status/stop/logs`.
        \\                   Cannot be combined with --background.
        \\  --force          --background only: stop an existing session first instead of
        \\                   reporting it and exiting 0.
        \\
    , .{if (show_serve_static) " [--serve-static DIR]" else ""});
    if (show_serve_static) emit(io, file,
        \\  --serve-static DIR  Serve static files from DIR at the root path (anything
        \\                      not matching /api/, /_/, or custom routes). [default: off]
        \\
    , .{});
    if (show_static_cache_control) emit(io, file,
        \\  --static-cache-control V  Cache-Control value for static responses (also ZIGBASE_STATIC_CACHE_CONTROL). [default max-age=3600]
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
        \\  zigbase migrate [--data-dir PATH]           Apply pending migrations (default).
        \\  zigbase migrate status [--data-dir PATH]    Report applied/pending migrations; apply nothing.
        \\  zigbase migrate rollback [N] [--data-dir P]  Reverse the N most-recent migrations (default 1).
        \\  zigbase migrate dump [--out FILE]           Dump the live DB structure as SQL (stdout by default).
        \\
        \\FLAGS:
        \\  --data-dir PATH  SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\  --out FILE       (dump only) Write the SQL to FILE instead of stdout; parent dirs are created.
        \\  --json           (status only) Emit one JSON object on stdout instead of the text report.
        \\
        \\  `migrate status` exits 1 when any migration is pending or orphaned, so it can
        \\  gate a deploy: `zigbase migrate status || zigbase migrate`.
        \\
        \\WHAT IT DOES:
        \\  `migrate` applies pending SYSTEM migrations and then the app's comptime `.migrations`
        \\  (the same forward pass `serve` runs at boot), recording each in the `_migrations`
        \\  ledger so it runs exactly once. `migrate status` reads that ledger and lists the
        \\  compiled-in migrations as applied or pending (in declared order), flagging any
        \\  ORPHANED rows (applied migrations no longer present in the binary). It changes nothing.
        \\  `migrate rollback [N]` reverses the N most-recently-applied consumer migrations,
        \\  newest first (N defaults to 1). The reverse of a migration is `down orelse change`
        \\  (an explicit `down` runs; otherwise a `change` re-runs inverted). It fails loudly and
        \\  changes nothing it cannot undo: a migration with only an `up`, or one whose `change`
        \\  reverses into an irreversible op (records()/raw/a `.was`-less drop), or an ORPHANED
        \\  ledger row, is refused and named.
        \\  `migrate dump` introspects the LIVE database and writes a canonical, dialect-native
        \\  `structure.sql` (SQLite reads the exact stored DDL; Postgres reconstructs it from the
        \\  system catalogs — NO external pg_dump). The output is deterministic (no timestamps), so
        \\  it diffs cleanly, and it re-runs to recreate the schema for a fast test DB. It is a
        \\  snapshot for inspection/diffing/test-setup — NOT a schema source (that is `.collections`),
        \\  and it is never loaded at boot.
        \\
        \\Note: `zigbase serve` also runs migrations on startup; use `migrate` to apply
        \\them ahead of time (e.g. in a deploy step) without starting the server.
        \\
        \\EXAMPLES:
        \\  zigbase migrate --data-dir ./zb_data
        \\  zigbase migrate status --data-dir ./zb_data
        \\  zigbase migrate rollback --data-dir ./zb_data
        \\  zigbase migrate rollback 3 --data-dir ./zb_data
        \\  zigbase migrate dump --data-dir ./zb_data
        \\  zigbase migrate dump --out db/structure.sql --data-dir ./zb_data
        \\
    , .{});
}

fn printSchemaUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase schema — declarative schema: dump the live collection model, apply a document,
        \\lint access rules.
        \\
        \\USAGE:
        \\  zigbase schema dump  [--json] [--out FILE] [--data-dir PATH]
        \\  zigbase schema apply <schema.json> [--dry-run] [--allow-destructive] [--prune]
        \\                       [--data-dir PATH]
        \\  zigbase schema check-rules [schema.json] [--json] [--data-dir PATH]
        \\
        \\DUMP:
        \\  Writes a canonical JSON document describing every NON-SYSTEM collection: fields
        \\  (with their stable ids), indexes, access rules, and collection options. It is
        \\  deterministic (collections name-sorted, stable key order) so it diffs cleanly in
        \\  git. Collection ids are omitted (they are instance-local) and OAuth client secrets
        \\  are REDACTED — the document is not a secrets backup. Output goes to stdout unless
        \\  --out is given. --json is accepted (symmetry with `import --json`) and ignored —
        \\  the dumped document is already the one JSON object printed.
        \\
        \\APPLY:
        \\  Diffs the document against the live schema and executes the difference through the
        \\  same validation + DDL path as the REST collections API. Only collections named in
        \\  the document are touched; live collections absent from it are reported as
        \\  "untracked" and left alone (--prune deletes them instead). Refused when the app
        \\  sets `.collections_frozen`.
        \\
        \\  A server already running against this data dir picks the change up on its own
        \\  within about five seconds: it polls the `_schema_state` generation marker this
        \\  apply bumps, then drops its collection cache. Requests landing in that window
        \\  still see the pre-change view, so restart it if the cutover must be immediate.
        \\
        \\  RULE SYNTAX GATE: before anything is written, every access rule the document
        \\  declares is run through the filter lexer + parser. If any one of them fails to
        \\  parse, the WHOLE document is refused — nothing is written, the offending
        \\  collection/rule/error code is printed on stderr, and the exit is 1 (in --dry-run
        \\  too, and ahead of the destructive check, so an unparseable document exits 1 even
        \\  when it is also destructive). There is no flag to skip it. It is syntax ONLY:
        \\  field and relation names are NOT resolved, because a rule may legitimately name a
        \\  field this same apply is about to add. `@public` is NOT reported here either —
        \\  that judgment lives in `check-rules`, whose exit 2 means "needs judgment", and
        \\  apply's exit 2 is frozen as "dry-run found destructive changes".
        \\
        \\  --dry-run             Print the plan and apply no schema change. NOT a true no-op:
        \\                        booting to compute the plan still runs system migrations
        \\                        and comptime collection provisioning, which write.
        \\  --allow-destructive   Permit drops and retypes (refused otherwise).
        \\  --prune               Delete live collections absent from the document.
        \\                        Requires --allow-destructive.
        \\  --json                Accepted, ignored (stdout is already one JSON object).
        \\
        \\CHECK-RULES:
        \\  Lints the five access rules (listRule/viewRule/createRule/updateRule/deleteRule)
        \\  of every non-system collection through the REAL rule pipeline. Nothing validates
        \\  a rule when it is written — the first parse happens at request time, where a
        \\  malformed rule fails CLOSED (500). This is the preflight for that.
        \\
        \\  TWO MODES, TWO DEPTHS:
        \\    no FILE          LIVE mode, depth "full". Every rule is compiled against the
        \\                     database at --data-dir through the same entry point a request
        \\                     uses, so unknown fields and bad relation traversals are caught
        \\                     as well as syntax.
        \\    FILE             DOCUMENT mode, depth "syntax". Lexer + parser ONLY. Resolving a
        \\                     field or relation name needs a live schema and a connection,
        \\                     which a document does not carry, so a rule naming a field that
        \\                     does not exist passes here. The summary always says which depth
        \\                     ran; do not read a clean "syntax" run as a clean bill of health.
        \\
        \\  Blank rules (null or "") mean Locked (superusers only) and are never reported.
        \\  A rule of exactly "@public" is reported as a WARNING — it is the one allow-all,
        \\  and opening a collection to everyone is a judgment a human should confirm. (This
        \\  deliberately overlaps `doctor`'s public-rules-enumerated check, at a different
        \\  lifecycle stage: doctor asks what a running server exposes, check-rules asks what
        \\  a document or schema is about to expose.)
        \\
        \\  Output is NDJSON on stdout — one object per finding, then exactly one summary
        \\  object whose first key is "summary" — same shape as `doctor`. Clean rules emit
        \\  no line at all; the summary's rules_checked carries the coverage. --json is
        \\  accepted and ignored (NDJSON is the only format).
        \\
        \\EXIT CODES (dump / apply):
        \\  0  success, or --dry-run with no destructive changes
        \\  1  the command failed (bad document, an unparseable access rule, refused
        \\     operation, DB error)
        \\  2  --dry-run found DESTRUCTIVE changes (needs --allow-destructive)
        \\
        \\EXIT CODES (check-rules):
        \\  0  no findings
        \\  1  at least one rule failed to parse or compile
        \\  2  no errors, but at least one warning (an "@public" rule)
        \\
        \\EXAMPLES:
        \\  zigbase schema dump --out db/schema.json --data-dir ./zb_data
        \\  zigbase schema apply db/schema.json --dry-run
        \\  zigbase schema apply db/schema.json --allow-destructive
        \\  zigbase schema check-rules db/schema.json        # offline, syntax depth
        \\  zigbase schema check-rules --data-dir ./zb_data  # live, full depth
        \\
    , .{});
}

fn printOpenApiUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\Usage: zigbase openapi [--data-dir <path>] [--out <file>]
        \\                        [--title <text>] [--api-version <version>]
        \\                        [--server <url>]
        \\
        \\Exports deterministic OpenAPI 3.1.2 JSON for live non-system collections
        \\and this framework binary's declared consumer routes. Writes stdout by
        \\default; --out writes the artifact to a file.
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

fn printImportUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase import — offline, encryption-aware bulk NDJSON record import.
        \\
        \\USAGE:
        \\  zigbase import --collection NAME [--upsert-key FIELD] [--batch-size N]
        \\                 [--data-dir PATH] <file.ndjson>
        \\  (use - as the file path to read NDJSON from stdin)
        \\
        \\FLAGS:
        \\  --collection NAME  Target collection (required). Must already exist (declared in
        \\                     .collections or created via the admin UI).
        \\  --upsert-key FIELD Match each row on FIELD and UPDATE it if present, else create
        \\                     (idempotent re-import). FIELD must be a scalar, non-encrypted,
        \\                     existing field; a unique constraint is recommended.
        \\  --batch-size N     Rows per transaction (default 500; must be >= 1).
        \\  --data-dir PATH    SQLite db + file storage directory. [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\  --dry-run          Validate + execute every row, then roll back — no record data
        \\                     is written. NOT a true no-op: booting to import still runs
        \\                     system migrations and comptime collection provisioning, which
        \\                     write, same as any other startup.
        \\                     (An --upsert-key lookup sees no rows created in the same dry run.)
        \\  --continue-on-error  Skip a failing row instead of aborting. Exit code becomes 3 if any
        \\                     row was skipped — a lossy import is never reported as success.
        \\  --error-log FILE   NDJSON sink for per-row failures: {{"line":N,"code":…,"detail":…}}.
        \\  --progress N       Print a progress line to stderr every N rows (0 = off).
        \\  --json             Print the summary as one JSON object on stdout.
        \\  --manifest FILE    Load several collections in relation order from a manifest:
        \\                     {{"zigbaseImportManifest":1,"collections":[
        \\                       {{"collection":"authors","file":"authors.ndjson"}},
        \\                       {{"collection":"posts","file":"posts.ndjson","upsertKey":"slug"}}]}}
        \\                     File paths resolve against the MANIFEST's directory. Relation cycles
        \\                     and self-relations are loaded with the offending values stripped and
        \\                     patched afterwards by record id (those rows must carry their own id).
        \\                     Excludes --collection/--upsert-key and the positional file.
        \\  --legacy-hashes ALG  Import each row's `passwordHash` as a SOURCE hash produced by ALG
        \\                     (currently: bcrypt) instead of ignoring it. The value is stored tagged
        \\                     as $zblegacy$ALG$<hash> and is replaced with argon2id on the user's
        \\                     first successful login. Requires an auth collection, refuses
        \\                     _superusers, and requires every row to carry its own `id`. Under this
        \\                     flag a row's `verified` flag is carried over too. A row carrying BOTH
        \\                     `password` and `passwordHash` is refused. CREATE-ONLY: it cannot be
        \\                     combined with --upsert-key (nor with a manifest entry's `upsertKey`),
        \\                     because an updated row would land with no credential installed.
        \\                     The flag applies uniformly to EVERY manifest entry, so a legacy-hash
        \\                     import must be its own single-collection run.
        \\  --preserve-timestamps  Preserve each row's source `created` and `updated` values.
        \\                     Requires a provided id on every row and is CREATE-ONLY: it cannot
        \\                     be combined with --upsert-key or a manifest entry's `upsertKey`.
        \\                     This operator-only seam never applies to HTTP/client writes.
        \\
        \\WHAT IT DOES:
        \\  Streams an NDJSON file (one JSON object per line) into the collection THROUGH THE
        \\  RECORD ENGINE, WITHOUT starting the HTTP server. Every row therefore gets field
        \\  validation, autodate/required defaults, the `.encrypted` at-rest envelope (the same
        \\  ZIGBASE_FIELD_KEY is required — plaintext is never written), and, for an auth
        \\  collection, the credential transforms (password hashing, tokenKey, verified=false).
        \\  Rows commit in batches; a bad row (malformed JSON, validation failure, duplicate id)
        \\  FAILS FAST — the in-flight batch is rolled back and the offending line is named.
        \\  Batches committed before the failure persist (a resumable checkpoint).
        \\
        \\  By default each row's own `id` is PRESERVED (so relations across an exported dataset
        \\  stay intact). This is import-only: the HTTP/route/hook create path never honors a
        \\  client-supplied id.
        \\
        \\  Blank lines are skipped. A single record line must fit the 1 MiB line buffer.
        \\
        \\EXIT CODES:
        \\  0  every row imported
        \\  1  the import failed (fatal error; batches committed before it persist)
        \\  3  the import completed but skipped rows (--continue-on-error)
        \\
        \\EXAMPLES:
        \\  zigbase import --collection posts --data-dir ./zb_data seed.ndjson
        \\  zigbase import --collection users --upsert-key email users.ndjson
        \\  cat dump.ndjson | zigbase import --collection posts -
        \\  zigbase import --collection posts --continue-on-error --error-log errs.ndjson \
        \\    --progress 1000 --json seed.ndjson
        \\
    , .{});
}

fn printServeControlUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase serve stop|status|logs — manage a background `zigbase serve` session.
        \\
        \\USAGE:
        \\  zigbase serve stop   [--data-dir PATH]            Stop the session owning this data dir.
        \\  zigbase serve status [--json] [--data-dir PATH]   Report the session; exit 0 running, 1 not.
        \\  zigbase serve logs   [--json] [--follow|-f] [--data-dir P]
        \\                                                   Print (and optionally tail) serve.log.
        \\
        \\  `logs --json` keeps only the NDJSON records, dropping the plain-text lines
        \\  facil.io writes into serve.log itself — so `serve logs --json | jq` works on a
        \\  real log file. Start the session with --log-format json for records to exist.
        \\
        \\Each verb resolves its session from the data dir, exactly like `serve` itself
        \\[env ZIGBASE_DATA_DIR, default ./zb_data]. See docs/serve.md for the JSON contract.
        \\
    , .{});
}

fn printDoctorUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase doctor — preflight checks over this deployment's config, data dir, and schema.
        \\
        \\USAGE:
        \\  zigbase doctor [--production] [--json] [--data-dir PATH]
        \\
        \\FLAGS:
        \\  --production   Judge the config as a PRODUCTION deployment: several warnings
        \\                 become errors (see docs/serve.md for the per-check table).
        \\  --json         NDJSON findings on stdout, one per line, then one summary object.
        \\  --data-dir PATH  [env ZIGBASE_DATA_DIR, default ./zb_data]
        \\
        \\EXIT CODES:
        \\  0  fully clean — no errors, no warnings
        \\  1  at least one error-severity finding
        \\  2  ran correctly, warnings only (something needs judgment)
        \\
        \\  Strict deploy gate:    zigbase doctor --production && deploy
        \\  Tolerant deploy gate:  zigbase doctor --production; case $? in 0|2) deploy ;; esac
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

fn printVapidKeygenUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase vapid-keygen — generate a VAPID (Web Push) keypair.
        \\
        \\USAGE:
        \\  zigbase vapid-keygen
        \\
        \\Prints a fresh P-256 keypair (base64url). Wire it into the server environment to
        \\enable ctx.push():
        \\
        \\  ZIGBASE_VAPID_PUBLIC_KEY   the application-server public key (also the browser's
        \\                             applicationServerKey for pushManager.subscribe).
        \\  ZIGBASE_VAPID_PRIVATE_KEY  the signing private key — SECRET; never commit or log it.
        \\
        \\Without both keys configured, ctx.push() is a network-free logging no-op.
        \\
    , .{});
}

fn printExplainCodeUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase explain-code [CODE] [--json] — explain a frozen API error code.
        \\
        \\USAGE:
        \\  zigbase explain-code                list every registered code, one per line.
        \\  zigbase explain-code CODE           print CODE's summary + long-form explanation.
        \\  zigbase explain-code [CODE] --json  emit the same information as one JSON object.
        \\
        \\CODE is the wire string ZigBase puts in an envelope's `code` (or a field error's
        \\`data.<field>.code`) — e.g. `validation_required`, `not_found`, `collections_frozen`.
        \\A CODE ZigBase never registered exits 1 (`--json` still prints one object, with
        \\`"known":false`); a consumer route may legitimately emit its own strings via
        \\ctx.jsonError, so this is not a ZigBase bug report.
        \\
    , .{});
}

fn printInitUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase init — scaffold a starting-point project.
        \\
        \\USAGE:
        \\  zigbase init [--box | --framework] [--dir PATH] [--name NAME]
        \\
        \\MODES:
        \\  --box         (default) No Zig toolchain. Emits docker-compose.yml, a
        \\                schema/collections.json starting point (apply it with
        \\                `zigbase schema apply`), AGENTS.md + CLAUDE.md, .gitignore,
        \\                and a README.
        \\  --framework   A Zig package that embeds ZigBase as a library. Emits
        \\                build.zig (wired with zigbase.addTo + zigbase.addTest),
        \\                build.zig.zon, src/main.zig with a comptime schema and
        \\                in-process tests, AGENTS.md + CLAUDE.md, .gitignore, README.
        \\
        \\FLAGS:
        \\  --dir PATH    Target directory, created if missing. [default .]
        \\  --name NAME   Package/executable name (framework mode).
        \\                [default: the directory name, sanitized]
        \\
        \\Existing files are NEVER overwritten — they are reported as skipped and left
        \\alone. There is no --force.
        \\
        \\In framework mode, run `zig fetch --save git+https://github.com/valthon/zigbase`
        \\afterwards: that is what writes the dependency URL and its content hash into
        \\build.zig.zon.
        \\
    , .{});
}

fn printAgentsMdUsage(io: std.Io, file: std.Io.File) void {
    emit(io, file,
        \\zigbase agents-md — write AGENTS.md + CLAUDE.md for an existing project.
        \\
        \\USAGE:
        \\  zigbase agents-md [--box | --framework] [--dir PATH] [--stdout]
        \\
        \\FLAGS:
        \\  --dir PATH    Target directory. [default .]
        \\  --box         Force the no-Zig content set.
        \\  --framework   Force the library-embedding content set.
        \\  --stdout      Print AGENTS.md instead of writing it (diff-friendly).
        \\
        \\With neither mode flag, the mode is inferred: a build.zig.zon in the target
        \\directory means framework, otherwise box.
        \\
        \\Existing files are never overwritten. To refresh one, delete it (or diff
        \\against --stdout) first.
        \\
    , .{});
}

fn loadCfg(environ: *const std.process.Environ.Map, sa: cli.ServeArgs) !config.Config {
    var diag: config.LoadDiag = .{};
    var cfg = config.Config.loadDiag(config.EnvGetter{ .environ = environ }, &diag) catch |e| switch (e) {
        error.InvalidEnvValue => {
            std.log.err(
                "invalid value for {s}: '{s}' — expected {s}. Fix the variable (or unset it to use the default) and start again.",
                .{ diag.var_name, diag.value, diag.expected },
            );
            // EXIT rather than return the error. Propagating it to `main` makes Zig
            // print its own `error: InvalidEnvValue` line plus a source-annotated
            // stack trace through std.fmt's parseInt internals — thirty lines of
            // noise on top of the one actionable sentence above, which is the whole
            // point of this diagnostic. There is nothing for a caller to recover
            // from: a malformed knob is fatal by design (fail fast at boot).
            // `logging.write` flushes stderr on every record, so the message is
            // already out before this call skips the deferred cleanup.
            // Exit 1 = "bad input", per the CLI exit-code scheme.
            std.process.exit(1);
        },
    };
    if (sa.http_host) |v| cfg.http_host = v;
    if (sa.http_port) |v| cfg.http_port = v;
    if (sa.data_dir) |v| cfg.data_dir = v;
    if (sa.serve_static) |v| cfg.static_dir = v;
    if (sa.static_cache_control) |v| cfg.static_cache_control = v;
    // Secure-by-default opt-outs/opt-ins (flags override toward the explicit choice).
    if (sa.insecure_cookies) cfg.cookie_secure = false;
    if (sa.trust_proxy) cfg.trust_proxy = true;
    if (sa.realtime_origins) |v| cfg.realtime_allowed_origins = v;
    if (sa.sse_heartbeat_seconds) |v| cfg.sse_heartbeat_seconds = v;
    if (sa.realtime_outbound_hwm) |v| cfg.realtime_outbound_hwm = v;
    // The `.?` is safe only because cli.parse already validated the spelling
    // (logging.parseFormat/parseLevel) at parse time — an invalid value never
    // reaches here as a ServeArgs field.
    if (sa.log_format) |v| cfg.log_format = logging.parseFormat(v).?;
    if (sa.log_level) |v| cfg.log_level = logging.parseLevel(v).?;
    if (sa.log_requests) |v| cfg.log_requests = v;

    // Install the FULLY resolved logging config (env, then flags) here — the single
    // `logging.apply` on every command path — before anything below is logged. It used
    // to live at the top of `serveImpl`, which was too late: `warnUnknownVars` runs
    // next, and under `--log-format json` (a flag, with no matching env var) its
    // warning was still formatted by the env-only pre-pass, dropping a plain-text line
    // into a stream the docs promise is NDJSON, unsuppressable by `--log-level`.
    // Still ordered before `bootApp`/the pool opens, which is the guarantee that
    // matters — just one frame earlier.
    logging.apply(cfg.log_format, cfg.log_level, cfg.log_requests);
    // Warn AFTER the logger is configured, so the warning honors --log-format and
    // --log-level like every other record.
    config.warnUnknownVars(environ);
    return cfg;
}

/// Ensure the data dir exists before opening files under it. A genuine failure (EACCES on a
/// system path, a read-only filesystem, ENOSPC) would otherwise be swallowed and later surface
/// only as an opaque `OpenFailed` with no path — log the actionable cause here so boot
/// diagnostics name the real problem. Best-effort: the subsequent open reports the fatal error.
fn ensureDataDir(io: std.Io, data_dir: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch |e|
        std.log.warn("cannot create data dir '{s}': {s} (the database/secret open below will fail)", .{ data_dir, @errorName(e) });
}

fn openPool(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, options: db.PoolOptions) !db.Pool {
    ensureDataDir(io, cfg.data_dir);
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
/// `pub` (rather than the `fn` every other CLI-impl helper here is) because
/// `doctor_run.gather` — a different file, opening the same pool the same
/// way for the same reason `migrateStatusImpl` does — needs it too.
pub fn openPoolSelect(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, options: db.PoolOptions, environ: *const std.process.Environ.Map) !db.Pool {
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

/// `zigbase migrate`: apply pending SYSTEM migrations, then the consumer `.migrations` (the same
/// forward pass `serve` runs at boot — `provision.runMigrations`), then exit. Idempotent: an
/// already-applied migration is skipped via its `_migrations` ledger row. Threading
/// `schema_migrations` (the compiled-in `.migrations`) makes the CLI coherent with `migrate status`.
fn migrateImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, ma: cli.MigrateArgs, schema_migrations: []const provision.Migration) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = ma.data_dir });
    var pool = try openPoolSelect(allocator, io, cfg, .{}, environ);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.run(w);
    if (schema_migrations.len > 0) {
        try provision.runMigrations(allocator, io, w, schema_migrations);
    }
    std.log.info("migrations applied", .{});
}

/// `zigbase migrate status`: read the `_migrations` ledger and report the compiled-in consumer
/// `.migrations` as applied/pending (in DECLARED order), plus any ORPHANED ledger rows (applied
/// `prov:` rows whose migration was deleted from the binary). Does not apply anything — it only
/// ensures the ledger table exists so the read succeeds on a fresh database.
fn migrateStatusImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, ma: cli.MigrateArgs, schema_migrations: []const provision.Migration) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = ma.data_dir });
    var pool = try openPoolSelect(allocator, io, cfg, .{}, environ);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.ensureLedger(w);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const status = try provision.migrationStatus(arena.allocator(), w, schema_migrations);

    const out = std.Io.File.stdout();
    if (ma.json) {
        migrateStatusJson(io, out, status);
    } else {
        emit(io, out, "Consumer migrations ({d} declared):\n", .{schema_migrations.len});
        if (schema_migrations.len == 0) emit(io, out, "  (none declared)\n", .{});
        for (status.declared) |e| {
            if (e.applied_at) |at|
                emit(io, out, "  {s}  applied (at {s})\n", .{ e.id, at })
            else
                emit(io, out, "  {s}  pending\n", .{e.id});
        }
        if (status.orphaned.len > 0) {
            emit(io, out, "\nOrphaned (in ledger, not in binary):\n", .{});
            for (status.orphaned) |o| emit(io, out, "  {s}  applied (at {s})\n", .{ o.name, o.applied_at });
        }
        emit(io, out, "\n{d} applied, {d} pending, {d} orphaned\n", .{ status.applied_count, status.pending_count, status.orphaned.len });
    }

    // Exit 1 when the database is not up to date, so `migrate status` can gate a
    // deploy script. `ok` in the JSON body carries the same signal. `emit` flushes
    // on every call, so nothing is buffered when `std.process.exit` skips the
    // deferred `arena`/`pool` cleanup below.
    if (status.pending_count != 0 or status.orphaned.len != 0) std.process.exit(1);
}

/// `zigbase migrate status --json`. One object, stdout only; the text renderer's
/// prose stays on the text path so the two never interleave.
fn migrateStatusJson(io: std.Io, out: std.Io.File, status: provision.MigrationStatus) void {
    emit(io, out, "{{\"migrations\":[", .{});
    for (status.declared, 0..) |e, i| {
        if (i > 0) emit(io, out, ",", .{});
        if (e.applied_at) |at|
            emit(io, out, "{{\"id\":{f},\"applied\":true,\"applied_at\":{f}}}", .{ std.json.fmt(e.id, .{}), std.json.fmt(at, .{}) })
        else
            emit(io, out, "{{\"id\":{f},\"applied\":false,\"applied_at\":null}}", .{std.json.fmt(e.id, .{})});
    }
    emit(io, out, "],\"orphaned\":[", .{});
    for (status.orphaned, 0..) |o, i| {
        if (i > 0) emit(io, out, ",", .{});
        emit(io, out, "{{\"id\":{f},\"applied_at\":{f}}}", .{ std.json.fmt(o.name, .{}), std.json.fmt(o.applied_at, .{}) });
    }
    emit(io, out, "],\"summary\":{{\"declared\":{d},\"applied\":{d},\"pending\":{d},\"orphaned\":{d}}},\"ok\":{}}}\n", .{
        status.declared.len,                                    status.applied_count,
        status.pending_count,                                   status.orphaned.len,
        status.pending_count == 0 and status.orphaned.len == 0,
    });
}

/// `zigbase migrate dump [--out <file>]`: introspect the LIVE database and write a canonical,
/// dialect-native `structure.sql` — for inspection, review-diffing, and fast test-DB setup. It is
/// NOT a schema source and is never loaded at boot (that is `.collections`). Output goes to stdout by
/// default; `--out <path>` creates/overwrites a file (parent dirs are created). Mirrors
/// `migrateStatusImpl`'s read-only pool-open; it does not need the ledger table to exist.
fn migrateDumpImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, ma: cli.MigrateArgs) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = ma.data_dir });
    var pool = try openPoolSelect(allocator, io, cfg, .{}, environ);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();

    const sql = try schema_dump.schemaDump(allocator, w, db.dbDialect(w));
    defer allocator.free(sql);

    if (ma.out) |path| {
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = sql });
        std.log.info("schema dumped to {s} ({d} bytes)", .{ path, sql.len });
    } else {
        var buf: [4096]u8 = undefined;
        var wr = std.Io.File.stdout().writer(io, &buf);
        try wr.interface.writeAll(sql);
        try wr.interface.flush();
    }
}

/// `zigbase schema dump [--json] [--out <file>]`: write the canonical JSON schema document
/// for every non-system collection. Mirrors `migrateDumpImpl`'s read-only pool-open. Unlike
/// `migrate dump` (a dialect-native structure.sql snapshot of the PHYSICAL database), this
/// is the LOGICAL collection model — the artifact `schema apply` consumes.
fn schemaDumpImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, sa: cli.SchemaArgs) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = sa.data_dir });
    var pool = try openPoolSelect(allocator, io, cfg, .{}, environ);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();

    const doc = try schema_doc.dump(allocator, w);
    defer allocator.free(doc);

    if (sa.out) |path| {
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = doc });
        // Progress goes to stderr so stdout stays a clean JSON channel.
        std.log.info("schema document written to {s} ({d} bytes)", .{ path, doc.len });
    } else {
        var buf: [4096]u8 = undefined;
        var wr = std.Io.File.stdout().writer(io, &buf);
        try wr.interface.writeAll(doc);
        try wr.interface.flush();
    }
}

/// `zigbase openapi`: inspect the live logical collection model through a direct
/// read-only connection and combine it with this binary's comptime consumer routes. It
/// deliberately bypasses server boot, migrations, provisioning, and the SQLite pool's
/// journal-mode setup, so exporting cannot mutate the database it describes.
fn openApiImpl(comptime route_meta: []const events.RouteMeta, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, oa: cli.OpenApiArgs) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = oa.data_dir });
    const db_url = (config.EnvGetter{ .environ = environ }).get("ZIGBASE_DB_URL");
    const target: []const u8 = switch (db.chooseBackend(db_url)) {
        .postgres => db_url.?,
        .postgres_url_without_build => blk: {
            std.log.warn(
                "ZIGBASE_DB_URL is a postgres:// URL but this binary was built without -Dpostgres; " ++
                    "exporting the SQLite database at {s}/data.db instead",
                .{cfg.data_dir},
            );
            break :blk try std.fmt.allocPrint(allocator, "{s}/data.db", .{cfg.data_dir});
        },
        .sqlite => try std.fmt.allocPrint(allocator, "{s}/data.db", .{cfg.data_dir}),
    };
    defer if (db.chooseBackend(db_url) != .postgres) allocator.free(target);

    // Fail before SQLite's open if the live database does not exist. This makes the
    // no-create guarantee explicit and yields the filesystem's useful FileNotFound error.
    if (db.chooseBackend(db_url) != .postgres) {
        _ = std.Io.Dir.cwd().statFile(io, target, .{}) catch |e| {
            std.log.err("cannot inspect ZigBase database at {s}: {s}", .{ target, @errorName(e) });
            std.process.exit(1);
        };
    }
    var conn = try db.openInspectionConnection(allocator, io, target);
    defer conn.close();

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const cols = try collections_mod.list(scratch.allocator(), &conn);
    const doc = try openapi.generate(route_meta, allocator, cols, .{
        .title = oa.title,
        .api_version = oa.api_version orelse build_options.version,
        .server = oa.server,
    });
    defer allocator.free(doc);
    if (oa.out) |path| {
        try openapi_cli.writeAtomic(allocator, io, path, doc);
        std.log.info("OpenAPI document written to {s} ({d} bytes)", .{ path, doc.len });
    } else {
        var buf: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buf);
        try writer.interface.writeAll(doc);
        try writer.interface.flush();
    }
}

/// `zigbase schema check-rules [FILE] [--data-dir PATH]`: lint access-rule expressions.
///
/// Closes a real gap: nothing validates a rule when it is WRITTEN. `schema.parseCollectionInput`
/// takes the five rule fields as opaque strings and `collections.create`/`update` bind them
/// straight into `_collections`; the first parse happens at request time, where a parse failure
/// fails closed (500). A typo therefore ships silently and breaks the first request.
///
/// Two modes, two depths — see `rules_lint.zig`:
///   * no FILE  -> LIVE, `"depth":"full"`. Opens the pool exactly as `schemaDumpImpl` does
///     (read-only intent; it never boots the app or provisions) and runs every rule through
///     `rules.compileGuard`, the request path's own entry point. Catches unknown fields and
///     bad relation traversals as well as syntax.
///   * a FILE   -> DOCUMENT, `"depth":"syntax"`. Lexer + parser only: resolving a field name
///     needs a live schema and a connection, which a document does not carry.
///
/// Output is NDJSON on stdout (findings, then exactly one summary), matching `doctor`; the
/// exit code is doctor's mapping (1 error / 2 warnings-only / 0 clean). `--json` is accepted
/// and ignored, as on `dump` and `apply`.
fn schemaCheckRulesImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, sa: cli.SchemaArgs) !void {
    // Scoped so the arena and (in live mode) the pool are torn down BEFORE the exit —
    // `std.process.exit` does not run deferred code.
    const code = blk: {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        if (sa.file) |file| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(64 << 20)) catch |e| {
                std.log.err("schema check-rules: cannot read '{s}': {s}", .{ file, @errorName(e) });
                return e;
            };
            const doc = schema_doc.parse(arena, bytes) catch |e| {
                std.log.err("schema check-rules: '{s}' is not a valid schema document: {s}", .{ file, @errorName(e) });
                return e;
            };
            const report = try rules_lint.checkDocument(arena, doc);
            const summary = rules_lint.summarize(report, .syntax);
            rules_lint.render(io, arena, report.findings, summary);
            // Progress/interpretation on stderr only; stdout stays a clean NDJSON channel.
            std.log.info("schema check-rules: {d} rule(s) across {d} collection(s), SYNTAX depth only — field and relation names are not resolved offline; re-run without a FILE against a data dir for the full check", .{ summary.rules_checked, summary.collections });
            break :blk rules_lint.exitCode(summary);
        }

        const cfg = try loadCfg(environ, .{ .data_dir = sa.data_dir });
        var pool = try openPoolSelect(allocator, io, cfg, .{}, environ);
        defer pool.deinit();
        const w = pool.acquireWriter();
        defer pool.releaseWriter();

        const live = try collections_mod.list(arena, w);
        const report = try rules_lint.checkLive(arena, w, live);
        const summary = rules_lint.summarize(report, .full);
        rules_lint.render(io, arena, report.findings, summary);
        std.log.info("schema check-rules: {d} rule(s) across {d} collection(s) at FULL depth", .{ summary.rules_checked, summary.collections });
        break :blk rules_lint.exitCode(summary);
    };
    std.process.exit(code);
}

/// `zigbase schema apply <schema.json> [--dry-run] [--allow-destructive] [--prune]`.
///
/// Boots the FULL application offline via `bootApp` (migrations + comptime provisioning +
/// field-cipher stamping) so the live schema it diffs against is the one `serve` would see,
/// then executes the difference through `collections.create/update/delete` — the exact
/// functions `src/api/collections.zig` calls. There is no second DDL implementation.
///
/// Every access rule in the document is syntax-checked (via `rules_lint.checkDocument`) before
/// any write derived from the document happens; one unparseable rule refuses the whole apply.
/// The gate, and why it is syntax-only, is documented at the gate itself below.
///
/// Refused when the app sets `.collections_frozen`: frozen means this deployment's schema is
/// owned by the comptime `.collections` + `.migrations`, and a CLI write would silently
/// diverge from that source at the next boot (provisioning would fight it).
///
/// NOT atomic across collections — `collections.create`/`update` each open their own
/// transaction and cannot join an outer one. Each collection is therefore all-or-nothing on
/// its own, and the emitted `applied` list names exactly which ones landed before a failure.
fn schemaApplyImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    sa_args: cli.SchemaArgs,
    dispatch: *const events.Dispatch,
    jobs: []const scheduler.RuntimeJob,
    pool_size: usize,
    schema_collections: []const schema.Collection,
    schema_migrations: []const provision.Migration,
    comptime opts: ServeOpts,
) !void {
    const file = sa_args.file orelse {
        std.log.err("schema apply: a <schema.json> path is required", .{});
        return error.MissingSchemaFile;
    };
    if (sa_args.prune and !sa_args.allow_destructive) {
        std.log.err("schema apply: --prune deletes collections and requires --allow-destructive", .{});
        return error.DestructiveRefused;
    }

    const cfg = try loadCfg(environ, .{ .data_dir = sa_args.data_dir });
    const holder = try bootApp(allocator, io, cfg, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts, environ);
    defer holder.deinit();

    if (holder.app.collections_frozen) {
        std.log.err("schema apply: collections are frozen (`.collections_frozen`); change the comptime `.collections` / add a `.migrations` entry and redeploy", .{});
        return error.CollectionsFrozen;
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(64 << 20)) catch |e| {
        std.log.err("schema apply: cannot read '{s}': {s}", .{ file, @errorName(e) });
        return e;
    };
    const doc = schema_doc.parse(a, bytes) catch |e| {
        std.log.err("schema apply: '{s}' is not a valid schema document: {s}", .{ file, @errorName(e) });
        return e;
    };

    // ---- Rule syntax gate -------------------------------------------------------------
    // Every access rule the document declares is parsed BEFORE a single write derived from
    // the document happens. Nothing else in the engine validates a rule at write time:
    // `schema.parseCollectionInput` decodes the five rule fields as opaque strings and
    // `collections.create`/`update` bind them straight into `_collections`. The first thing
    // that parses a rule is the request that has to evaluate it — where a parse failure
    // fails CLOSED (500, and on a write the write never runs). `apply` is the last
    // chokepoint before a typo becomes a production outage, so a document with an
    // unparseable rule is refused WHOLE: nothing is written, not even the collections whose
    // rules are fine.
    //
    // WHY SYNTAX ONLY — this deliberately runs `checkDocument` (lexer + parser) and reports
    // nothing but hard parse errors:
    //
    //   * Exit code 2 is frozen as "dry-run found destructive changes". Emitting `@public`
    //     warnings or full-resolution findings from `apply` would force them onto exit 2,
    //     and an agent branching on 2 must never have to disambiguate "you opened a
    //     collection to the public" from "destructive schema change pending". Overloading a
    //     frozen exit code to save a flag is a bad trade.
    //   * Full field resolution would false-positive on rules that are correct in the
    //     document's own terms: a rule referencing a field added later in the same apply, or
    //     a relation created in pass 2, resolves against a live schema that does not exist
    //     yet. A linter that cries wolf during apply gets suppressed, and a suppressed
    //     linter protects nothing.
    //   * Judgment-shaped findings therefore live in `schema check-rules`, where exit 2
    //     already means "needs judgment" and where the operator asked for an opinion.
    //
    // There is no flag and no opt-out: an unparseable rule is not a judgment call, it is a
    // document that cannot mean anything.
    {
        // Scratch only. The report, its findings buffer, and every token/AST the checker
        // builds live and die on this arena; the finding strings are static literals or
        // borrowed from `doc`, so nothing that survives the block is owned by it. The
        // refusal path returns an error rather than calling `std.process.exit`, so this
        // `defer` — and the caller's `arena_state`/`holder` teardown — actually run.
        var lint_arena = std.heap.ArenaAllocator.init(allocator);
        defer lint_arena.deinit();
        const report = try rules_lint.checkDocument(lint_arena.allocator(), doc);

        var bad: usize = 0;
        for (report.findings) |f| {
            // Errors only. `checkDocument` also emits one "PublicRule" WARNING per `@public`
            // rule; `apply` stays silent about those on purpose (see above).
            if (!std.mem.eql(u8, f.severity, "error")) continue;
            bad += 1;
            // stderr, like every other pre-plan refusal here (`--prune` without
            // `--allow-destructive`, `.collections_frozen`, an unreadable or invalid
            // document): there is no plan yet, so there is no `emitApplyJson` object to
            // attach this to, and stdout stays a clean JSON channel.
            std.log.err("schema apply: collection '{s}' {s} does not parse: {s} ({s})", .{ f.collection, f.rule, f.message, f.code });
        }
        if (bad > 0) {
            std.log.err("schema apply: {d} unparseable access rule(s) in '{s}'; the whole document is refused and nothing was written", .{ bad, file });
            return error.InvalidRule;
        }
    }

    const w = holder.pool.acquireWriter();
    defer holder.pool.releaseWriter();

    const all_live = try collections_mod.list(a, w);
    var live: std.ArrayList(schema.Collection) = .empty;
    for (all_live) |c| if (!c.system) try live.append(a, c);

    var plan = try schema_diff.compute(allocator, live.items, doc, .{ .prune = sa_args.prune });
    defer plan.deinit();

    // A dry run reports and stops. Exit 2 (not 1) when destructive changes are present: the
    // command SUCCEEDED, it just found something a human or an agent must decide about.
    if (sa_args.dry_run) {
        try emitApplyJson(allocator, io, plan, doc, sa_args, &.{});
        if (plan.hasDestructive()) {
            std.log.warn("schema apply --dry-run: {d} destructive change(s); re-run with --allow-destructive to execute", .{countDestructive(plan)});
            std.process.exit(2);
        }
        return;
    }

    if (plan.hasDestructive() and !sa_args.allow_destructive) {
        try emitApplyJson(allocator, io, plan, doc, sa_args, &.{});
        std.log.err("schema apply: {d} destructive change(s) refused; pass --allow-destructive to execute them", .{countDestructive(plan)});
        return error.DestructiveRefused;
    }

    var applied: std.ArrayList([]const u8) = .empty;
    // Report what DID land even when a later collection fails, so a partial apply is
    // diagnosable rather than mysterious.
    errdefer emitApplyJson(allocator, io, plan, doc, sa_args, applied.items) catch {};

    // Pass 1 — creates and updates, in dependency order, with cycle back-edges omitted.
    for (plan.order) |idx| {
        const want = doc[idx];
        const existing = try collections_mod.get(a, w, want.name);

        // A collection the diff found nothing to do for is already converged: skip the
        // write entirely. `collections_mod.update` -> `ddl.rebuildPlan` always does a full
        // SQLite table rebuild and bumps `_collections.updated`, even when the incoming def
        // is byte-for-byte what's live — calling it unconditionally would make re-applying
        // an already-converged document rebuild every table every time. `create_collection`
        // changes don't gate here; they're handled by the `existing == null` branch below.
        if (existing != null and !hasPendingChange(plan, want.name)) continue;

        var def = want;

        // Break relation cycles: create without the back-edge field, add it in pass 2.
        var deferred_here: std.ArrayList([]const u8) = .empty;
        for (want.fields) |f| {
            if (f.options == .relation and plan.isDeferred(want.name, f.name))
                try deferred_here.append(a, f.name);
        }
        if (deferred_here.items.len > 0 and existing == null)
            def = try schema_diff.withoutFields(a, want, deferred_here.items);

        if (schema.hasEncryptedField(def) and db.poolFieldCipher(&holder.pool) == null) {
            std.log.err("schema apply: collection '{s}' declares an encrypted field but ZIGBASE_FIELD_KEY is unset", .{def.name});
            return error.FieldKeyRequired;
        }
        // One rule for OAuth secrets, shared with the REST handlers: an empty incoming
        // secret preserves the stored one (the document redacts them).
        collections_api.mergeOAuthConfig(holder.app.io, a, holder.app.jwt_secret, &def, existing) catch |e| return reportOAuthError(def.name, e);

        if (existing) |_| {
            _ = collections_mod.update(a, holder.app.io, w, want.name, def) catch |e| return reportCollectionError(want.name, e);
        } else {
            _ = collections_mod.create(a, holder.app.io, w, def) catch |e| return reportCollectionError(want.name, e);
        }
        try applied.append(a, want.name);
    }

    // Pass 2 — add the relation fields held back to break a cycle. Every target now exists.
    //
    // Gated per collection on whether the LIVE row is still missing a deferred field:
    // `plan.deferred` is structural (derived from the document's relation graph, not the
    // diff), so a converged cyclic pair still has a non-empty `plan.deferred` on every
    // re-apply. Without this gate, `update` (-> `ddl.rebuildPlan`, a full table rebuild +
    // `_collections.updated` bump) would fire for the back-edge collection on every re-run
    // even when nothing changed. A field that already exists live and differs structurally
    // from the document was already caught by `schema_diff.compute` (it diffs every field
    // by name/id regardless of deferred status) and already rewritten by Pass 1's
    // unconditional-on-`existing`-def update (Pass 1 only omits deferred fields when
    // CREATING, i.e. `existing == null`) — so this pass's only job is filling in a field
    // that plan.order intentionally left out when the collection didn't exist yet.
    if (plan.deferred.len > 0) {
        for (plan.order) |idx| {
            const want = doc[idx];
            const existing = try collections_mod.get(a, w, want.name);

            var needs_backfill = false;
            for (want.fields) |f| {
                if (f.options != .relation or !plan.isDeferred(want.name, f.name)) continue;
                const live_has_field = if (existing) |e| fieldPresent(e.fields, f.name) else false;
                if (!live_has_field) needs_backfill = true;
            }
            if (!needs_backfill) continue;

            var def = want;
            collections_api.mergeOAuthConfig(holder.app.io, a, holder.app.jwt_secret, &def, existing) catch |e| return reportOAuthError(def.name, e);
            _ = collections_mod.update(a, holder.app.io, w, want.name, def) catch |e| return reportCollectionError(want.name, e);
        }
    }

    // Pass 3 — prune, last, so a dropped collection can never be a live relation target of
    // something still being created (`collections_mod.delete` refuses that anyway, with Conflict).
    for (plan.changes) |c| {
        if (c.kind != .drop_collection) continue;
        collections_mod.delete(a, w, c.collection) catch |e| return reportCollectionError(c.collection, e);
        try applied.append(a, c.collection);
    }

    if (holder.app.col_cache) |cc| cc.invalidate();
    try emitApplyJson(allocator, io, plan, doc, sa_args, applied.items);
    std.log.info("schema apply: {d} change(s) across {d} collection(s)", .{ plan.changes.len, applied.items.len });
}

fn countDestructive(plan: schema_diff.Plan) usize {
    var n: usize = 0;
    for (plan.changes) |c| if (schema_diff.isDestructive(c.kind)) {
        n += 1;
    };
    return n;
}

/// True when `plan.changes` names at least one change for `name` other than
/// `create_collection` — i.e. an EXISTING collection has something Pass 1 must actually
/// write. `create_collection` never gates this: it's handled by Pass 1's `existing == null`
/// branch regardless of this helper.
fn hasPendingChange(plan: schema_diff.Plan, name: []const u8) bool {
    for (plan.changes) |c| {
        if (c.kind == .create_collection) continue;
        if (std.mem.eql(u8, c.collection, name)) return true;
    }
    return false;
}

/// True when `fields` already has a field named `name` — existence only, by name. Pass 2
/// uses this to decide whether a deferred back-edge field still needs to be created; any
/// STRUCTURAL difference in an already-present field is `schema_diff.compute`'s and Pass
/// 1's job, not this pass's.
fn fieldPresent(fields: []const schema.Field, name: []const u8) bool {
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return true;
    return false;
}

/// Present a `collections_mod.create/update/delete` failure, surfacing the engine's own
/// field-level validation details (the same `last_errors` the REST layer renders) instead
/// of a bare error name. `last_errors` is allocated on the SAME arena the caller passed as
/// `collections_mod.create`/`update`'s `alloc` (this function's caller always passes the
/// request-scoped arena, never the raw GPA) — it is reclaimed wholesale when that arena is
/// torn down, so this only resets the threadlocal, it never frees the slice itself (freeing
/// arena memory through a different allocator would be a mismatched-free bug).
fn reportCollectionError(name: []const u8, e: anyerror) anyerror {
    if (e == error.Validation) {
        if (collections_mod.last_errors) |errs| {
            defer collections_mod.last_errors = null;
            for (errs) |ve|
                std.log.err("schema apply: collection '{s}' field '{s}': {s} ({s})", .{ name, ve.field, ve.message, ve.code });
            return e;
        }
    }
    std.log.err("schema apply: collection '{s}' failed: {s}", .{ name, @errorName(e) });
    return e;
}

/// Present a `mergeOAuthConfig` failure at the CLI boundary (the REST handlers render a 400;
/// the CLI has no response to render, so it logs and fails the run instead).
fn reportOAuthError(name: []const u8, e: collections_api.OAuthPrepError) anyerror {
    if (e == error.BadOAuthConfig)
        std.log.err("schema apply: collection '{s}' has an invalid OAuth2 provider config (endpoints must be https, and an enabled provider needs a client secret)", .{name})
    else
        std.log.err("schema apply: collection '{s}' OAuth2 config failed: {s}", .{ name, @errorName(e) });
    return e;
}

/// The single JSON object on stdout. Emitted for dry runs, successful applies, and partial
/// applies alike, so an agent parses exactly one shape.
fn emitApplyJson(
    alloc: std.mem.Allocator,
    io: std.Io,
    plan: schema_diff.Plan,
    doc: []const schema.Collection,
    args: cli.SchemaArgs,
    applied: []const []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var changes: std.json.Array = .init(a);
    for (plan.changes) |c| {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "kind", .{ .string = @tagName(c.kind) });
        try o.put(a, "collection", .{ .string = c.collection });
        try o.put(a, "field", if (c.field) |f| .{ .string = f } else .null);
        try o.put(a, "detail", .{ .string = c.detail });
        try changes.append(.{ .object = o });
    }
    var untracked: std.json.Array = .init(a);
    for (plan.untracked) |u| try untracked.append(.{ .string = u });
    var deferred: std.json.Array = .init(a);
    for (plan.deferred) |d| {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "collection", .{ .string = d.collection });
        try o.put(a, "field", .{ .string = d.field });
        try deferred.append(.{ .object = o });
    }
    var applied_arr: std.json.Array = .init(a);
    for (applied) |n| try applied_arr.append(.{ .string = n });
    var order_arr: std.json.Array = .init(a);
    for (plan.order) |i| try order_arr.append(.{ .string = doc[i].name });

    // Stdout is the settled snake_case convention for everything this command PRINTS (the
    // schema document FILE format stays camelCase — see schema_doc.zig). Do not mix styles.
    var root: std.json.ObjectMap = .empty;
    try root.put(a, "zigbase_schema_apply", .{ .integer = 1 });
    try root.put(a, "dry_run", .{ .bool = args.dry_run });
    try root.put(a, "allow_destructive", .{ .bool = args.allow_destructive });
    try root.put(a, "destructive", .{ .bool = plan.hasDestructive() });
    try root.put(a, "changes", .{ .array = changes });
    try root.put(a, "untracked", .{ .array = untracked });
    try root.put(a, "deferred_relations", .{ .array = deferred });
    try root.put(a, "applied", .{ .array = applied_arr });
    try root.put(a, "apply_order", .{ .array = order_arr });

    const body = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});
    var buf: [4096]u8 = undefined;
    var wr = std.Io.File.stdout().writer(io, &buf);
    try wr.interface.writeAll(body);
    try wr.interface.writeAll("\n");
    // Flush BEFORE any std.process.exit — an unflushed buffer is a silently empty stdout.
    try wr.interface.flush();
}

/// `zigbase migrate rollback [N]`: reverse the N most-recently-applied consumer migrations (newest
/// first; N defaults to 1). The reverse of a migration is `down orelse change` (an explicit `down`
/// runs forward; a bare `change` runs inverted). Each migration's reverse body + its ledger-row
/// delete commit atomically. Fails loudly and changes nothing it cannot undo: an orphaned row, a
/// lone-`up` migration, or a non-transactional `change` is refused up front; a transactional
/// `change` that reverses into an irreversible op is rolled back by its tx and named. `N` exceeding
/// the applied count rolls back all applied consumer migrations (PocketBase-style `min(N, applied)`).
fn migrateRollbackImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, ma: cli.MigrateArgs, schema_migrations: []const provision.Migration) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = ma.data_dir });
    var pool = try openPoolSelect(allocator, io, cfg, .{}, environ);
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    try migrations.ensureLedger(w);

    const out = std.Io.File.stdout();
    const outcome = try provision.rollbackMigrations(allocator, io, w, schema_migrations, ma.rollback_count);
    switch (outcome) {
        .ok => |reversed| {
            if (reversed.len == 0) {
                emit(io, out, "No consumer migrations to roll back.\n", .{});
            } else {
                emit(io, out, "Rolled back {d} migration(s), newest first:\n", .{reversed.len});
                for (reversed) |id| emit(io, out, "  {s}\n", .{id});
            }
            freeIdList(allocator, reversed);
        },
        .irreversible => |r| {
            // Report what WAS reversed+committed before the offender (per-migration atomicity holds,
            // but the stop point must be honest — earlier NEWER migrations may already be undone).
            reportPartialRollback(io, out, r.reversed);
            std.log.err("migrate rollback: '{s}' is not reversible — stopped ({d} rolled back). Add a `down`, or avoid records()/raw/.was-less drops in a `change`.", .{ r.id, r.reversed.len });
            freeIdList(allocator, r.reversed);
            allocator.free(r.id);
            return error.MigrationNotReversible;
        },
        .orphaned => |r| {
            reportPartialRollback(io, out, r.reversed); // always empty (orphan is pre-flight), kept for symmetry
            std.log.err("migrate rollback: '{s}' is applied but no longer compiled into the binary — cannot reverse it; rolled back nothing.", .{r.id});
            freeIdList(allocator, r.reversed);
            allocator.free(r.id);
            return error.OrphanedMigration;
        },
    }
}

/// Print the ids reversed+committed before a mid-batch stop, so a partial rollback is never silent.
fn reportPartialRollback(io: std.Io, out: std.Io.File, reversed: [][]const u8) void {
    if (reversed.len == 0) return;
    emit(io, out, "Rolled back {d} migration(s), newest first:\n", .{reversed.len});
    for (reversed) |id| emit(io, out, "  {s}\n", .{id});
}

fn freeIdList(allocator: std.mem.Allocator, ids: [][]const u8) void {
    for (ids) |id| allocator.free(id);
    allocator.free(ids);
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

/// `zigbase import --collection <name> [--upsert-key <field>] [--batch-size N] <file.ndjson>`:
/// offline, encryption-aware bulk NDJSON record import (issue #283). Boots the FULL application
/// WITHOUT binding a socket via `bootApp` — so migrations run, the comptime `.collections` are
/// provisioned (the target collection is guaranteed present), and the `.encrypted` field cipher
/// is stamped on every pooled connection — then streams the file (or stdin when the path is `-`)
/// through the record engine on the writer connection. Every row gets validation, defaults, the
/// `.encrypted` at-rest envelope, and (for an auth collection) password hashing. See
/// `src/import.zig` for the streaming/batch/txn/id-preservation/upsert contract.
fn importImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    ia: cli.ImportArgs,
    dispatch: *const events.Dispatch,
    jobs: []const scheduler.RuntimeJob,
    pool_size: usize,
    schema_collections: []const schema.Collection,
    schema_migrations: []const provision.Migration,
    comptime opts: ServeOpts,
) !void {
    if (ia.manifest) |mpath| return importManifestImpl(allocator, io, environ, ia, mpath, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts);
    const collection = ia.collection orelse {
        std.log.err("import: --collection <name> is required", .{});
        return error.MissingCollection;
    };
    const file = ia.file orelse {
        std.log.err("import: a <file.ndjson> path is required (use - to read stdin)", .{});
        return error.MissingImportFile;
    };
    const cfg = try loadCfg(environ, .{ .data_dir = ia.data_dir });

    // Full offline boot: migrations + comptime provisioning + field-cipher stamping, socket-free.
    const holder = try bootApp(allocator, io, cfg, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts, environ);
    defer holder.deinit();

    const w = holder.pool.acquireWriter();
    defer holder.pool.releaseWriter();

    // Findings sink: created/truncated up front so a re-run never appends to a stale log.
    var err_file: ?std.Io.File = null;
    defer if (err_file) |f| f.close(io);
    var err_buf: [8192]u8 = undefined;
    var err_writer: ?std.Io.File.Writer = null;
    if (ia.error_log) |path| {
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        err_file = f;
        err_writer = f.writer(io, &err_buf);
    }
    // Flush on every exit path, including a fail-fast `run()` error below (which returns
    // early via `reportImportError`) — otherwise the one finding logged right before that
    // error would sit in the buffer and never reach disk, the opposite of what an
    // --error-log is for. A broken/full sink loses the finding, never the import result
    // (matches `logFinding`'s own best-effort contract), so this is caught, not `try`'d.
    defer if (err_writer) |*ew| ew.interface.flush() catch {};
    var prog_buf: [256]u8 = undefined;
    var prog_writer = std.Io.File.stderr().writer(io, &prog_buf);

    const run_opts = import_mod.Options{
        .collection = collection,
        .upsert_key = ia.upsert_key,
        .batch_size = ia.batch_size,
        .dry_run = ia.dry_run,
        .continue_on_error = ia.continue_on_error,
        .error_log = if (err_writer) |*ew| &ew.interface else null,
        .progress_every = ia.progress,
        .progress = if (ia.progress > 0) &prog_writer.interface else null,
        .legacy_hash_algorithm = ia.legacy_hashes,
        .preserve_timestamps = ia.preserve_timestamps,
    };

    // A generous heap line buffer (a single NDJSON record must fit it). Heap, not stack — 1 MiB.
    const line_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(line_buf);

    const report = blk: {
        if (std.mem.eql(u8, file, "-")) {
            var fr = std.Io.File.stdin().readerStreaming(io, line_buf);
            break :blk import_mod.run(&holder.app, w, io, &fr.interface, run_opts) catch |e| return reportImportError(collection, e);
        } else {
            const f = std.Io.Dir.cwd().openFile(io, file, .{}) catch |e| {
                std.log.err("import: cannot open '{s}': {s}", .{ file, @errorName(e) });
                return e;
            };
            defer f.close(io);
            var fr = f.readerStreaming(io, line_buf);
            break :blk import_mod.run(&holder.app, w, io, &fr.interface, run_opts) catch |e| return reportImportError(collection, e);
        }
    };

    if (ia.json) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var root: std.json.ObjectMap = .empty;
        // Stdout is the settled snake_case convention for everything this command PRINTS.
        try root.put(a, "zigbase_import", .{ .integer = 1 });
        try root.put(a, "collection", .{ .string = collection });
        try root.put(a, "dry_run", .{ .bool = ia.dry_run });
        try root.put(a, "preserve_timestamps", .{ .bool = ia.preserve_timestamps });
        try root.put(a, "created", .{ .integer = @intCast(report.created) });
        try root.put(a, "updated", .{ .integer = @intCast(report.updated) });
        try root.put(a, "failed", .{ .integer = @intCast(report.failed) });
        try root.put(a, "total", .{ .integer = @intCast(report.total) });
        try root.put(a, "error_log", if (ia.error_log) |p| .{ .string = p } else .null);
        const body = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});
        var out_buf: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &out_buf);
        try out.interface.writeAll(body);
        try out.interface.writeAll("\n");
        try out.interface.flush();
    }
    // Keeps the pre-existing "N created, M updated, K total" substring intact (the browser
    // suite greps for it) by appending the new `failed` count after `total` rather than
    // splicing it into the middle.
    std.log.info("import {s}: {d} created, {d} updated, {d} total, {d} failed (collection '{s}')", .{
        if (ia.dry_run) "dry-run complete (nothing written)" else "complete",
        report.created,
        report.updated,
        report.total,
        report.failed,
        collection,
    });
    // A lossy import is NOT a success. Exit 3 so an agent cannot mistake it for one. Flush the
    // findings sink explicitly first: `std.process.exit` does not run deferred cleanup (unlike
    // a normal `return`, which is why the fatal-error path above stays correct via the defer
    // above), so without this the NDJSON findings would sit in the buffer and vanish.
    if (report.failed > 0) {
        if (err_writer) |*ew| ew.interface.flush() catch {};
        std.process.exit(3);
    }
}

/// `zigbase import --manifest <m.json>`: load several collections in relation order,
/// deferring the values that cannot be ordered (cycles, self-relations). Relative `file`
/// paths in the manifest resolve against the MANIFEST's directory, not the cwd, so a
/// migration bundle is relocatable. Repeats `importImpl`'s boot + writer-acquire + sink
/// setup, then delegates to `import_manifest.run`, which drives `import.run` per collection —
/// there is no forked import logic.
fn importManifestImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    ia: cli.ImportArgs,
    mpath: []const u8,
    dispatch: *const events.Dispatch,
    jobs: []const scheduler.RuntimeJob,
    pool_size: usize,
    schema_collections: []const schema.Collection,
    schema_migrations: []const provision.Migration,
    comptime opts: ServeOpts,
) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = ia.data_dir });
    const holder = try bootApp(allocator, io, cfg, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts, environ);
    defer holder.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, mpath, a, .limited(8 << 20)) catch |e| {
        std.log.err("import: cannot read manifest '{s}': {s}", .{ mpath, @errorName(e) });
        return e;
    };
    var manifest = import_manifest.parseManifest(a, bytes) catch |e| {
        std.log.err("import: '{s}' is not a valid import manifest: {s}", .{ mpath, @errorName(e) });
        return e;
    };
    defer manifest.deinit();

    const base_dir = std.fs.path.dirname(mpath) orelse ".";

    // Same sinks as the single-collection path (Task 6).
    var err_file: ?std.Io.File = null;
    defer if (err_file) |f| f.close(io);
    var err_buf: [8192]u8 = undefined;
    var err_writer: ?std.Io.File.Writer = null;
    if (ia.error_log) |path| {
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        err_file = f;
        err_writer = f.writer(io, &err_buf);
    }
    // Flush on every exit path, including a fail-fast `run()` error below (mirrors
    // `importImpl`'s own findings-sink discipline).
    defer if (err_writer) |*ew| ew.interface.flush() catch {};
    var prog_buf: [256]u8 = undefined;
    var prog_writer = std.Io.File.stderr().writer(io, &prog_buf);

    const w = holder.pool.acquireWriter();
    defer holder.pool.releaseWriter();

    const report = import_manifest.run(&holder.app, w, io, allocator, manifest, .{
        .base_dir = base_dir,
        .import = .{
            .collection = "", // supplied per entry
            .batch_size = ia.batch_size,
            .dry_run = ia.dry_run,
            .continue_on_error = ia.continue_on_error,
            .error_log = if (err_writer) |*ew| &ew.interface else null,
            .progress_every = ia.progress,
            .progress = if (ia.progress > 0) &prog_writer.interface else null,
            .legacy_hash_algorithm = ia.legacy_hashes,
            .preserve_timestamps = ia.preserve_timestamps,
        },
    }) catch |e| return reportImportError(mpath, e);
    defer allocator.free(report.entries);

    if (ia.json) {
        var cols: std.json.Array = .init(a);
        for (report.entries) |er| {
            var o: std.json.ObjectMap = .empty;
            try o.put(a, "collection", .{ .string = er.collection });
            try o.put(a, "created", .{ .integer = @intCast(er.created) });
            try o.put(a, "updated", .{ .integer = @intCast(er.updated) });
            try o.put(a, "failed", .{ .integer = @intCast(er.failed) });
            try cols.append(.{ .object = o });
        }
        var root: std.json.ObjectMap = .empty;
        try root.put(a, "zigbase_import_manifest", .{ .integer = 1 });
        try root.put(a, "manifest", .{ .string = mpath });
        try root.put(a, "dry_run", .{ .bool = ia.dry_run });
        try root.put(a, "preserve_timestamps", .{ .bool = ia.preserve_timestamps });
        try root.put(a, "patched", .{ .integer = @intCast(report.patched) });
        try root.put(a, "failed", .{ .integer = @intCast(report.failed) });
        try root.put(a, "collections", .{ .array = cols });
        const body = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});
        var out_buf: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &out_buf);
        try out.interface.writeAll(body);
        try out.interface.writeAll("\n");
        try out.interface.flush();
    }
    std.log.info("import manifest complete: {d} collection(s), {d} deferred relation(s) patched, {d} failed", .{
        report.entries.len, report.patched, report.failed,
    });
    if (report.failed > 0) {
        if (err_writer) |*ew| ew.interface.flush() catch {};
        std.process.exit(3);
    }
}

/// Present an `import.run` failure at the CLI boundary (the library itself emits no `.err`
/// logs). Uses `import_mod.last_error_line` for the offending row and the pre-captured
/// `import_mod.last_error_detail` for extra context (e.g. the failing field on a validation
/// error) — never dereferencing the engine's arena-freed `records.last_errors`. Re-returns the
/// error so the process exits non-zero. Batches committed before the failing one persist (a
/// resumable checkpoint).
fn reportImportError(collection: []const u8, e: anyerror) anyerror {
    const line = import_mod.last_error_line;
    const detail = import_mod.last_error_detail;
    if (line > 0) {
        if (detail.len > 0)
            std.log.err("import into '{s}' failed at line {d}: {s} — {s}", .{ collection, line, @errorName(e), detail })
        else
            std.log.err("import into '{s}' failed at line {d}: {s}", .{ collection, line, @errorName(e) });
    } else {
        if (detail.len > 0)
            std.log.err("import into '{s}' failed: {s} — {s}", .{ collection, @errorName(e), detail })
        else
            std.log.err("import into '{s}' failed: {s}", .{ collection, @errorName(e) });
    }
    return e;
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

/// `zigbase serve stop|status|logs` — resolve the data dir exactly as `serve`
/// does, then hand off to the control plane, which owns the exit code.
fn serveControlImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, ca: cli.ServeControlArgs) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = ca.data_dir });
    // A missing data dir means "no session", not a hard error — resolve against
    // cwd so the verbs still report truthfully instead of failing to start.
    const abs = std.Io.Dir.cwd().realPathFileAlloc(io, cfg.data_dir, allocator) catch {
        if (ca.verb == .status) {
            var buf: [64]u8 = undefined;
            var fw = std.Io.File.stdout().writerStreaming(io, &buf);
            fw.interface.writeAll(if (ca.json)
                serve_control.status_json_none
            else
                "No zigbase serve session is running.\n") catch {};
            fw.interface.flush() catch {};
            std.process.exit(1);
        }
        std.log.err("serve {s}: no such data dir '{s}'", .{ @tagName(ca.verb), cfg.data_dir });
        return error.NoDataDir;
    };
    defer allocator.free(abs);
    const verb: serve_control.Verb = switch (ca.verb) {
        .stop => .stop,
        .status => .status,
        .logs => .logs,
    };
    serve_control.runVerb(io, allocator, verb, abs, ca.json, ca.follow);
}

/// `zigbase doctor [--production] [--json] [--data-dir PATH]`.
///
/// Reads config from env exactly as `serve` would, probes the data dir, and
/// opens the database read-mostly (it does create the `_migrations` ledger if
/// absent — the same write `migrate status` performs, and nothing else).
/// `schema_migrations` is the binary's compiled-in `.migrations`: without it,
/// the migrations check would report a clean bill of health for a binary that
/// has pending work.
///
/// One arena for the whole call: `doctor_run.gather`, `doctor.evaluate`, and
/// `doctor_run.renderToSlice` are all Contract 4 against it, so nothing below
/// is freed individually — the arena's `deinit()` is the only cleanup.
fn doctorImpl(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, da: cli.DoctorArgs, schema_migrations: []const provision.Migration) !void {
    const cfg = try loadCfg(environ, .{ .data_dir = da.data_dir });
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const facts = doctor_run.gather(arena, io, cfg, environ, schema_migrations);
    const findings = try doctor.evaluate(arena, facts, da.production);
    const summary = doctor.summarize(findings, da.production);
    doctor_run.render(io, arena, findings, summary, da.json);
    std.process.exit(doctor_run.exitCode(summary));
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
    ensureDataDir(io, cfg.data_dir);
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

/// #245 app-scoped context boot contract (pure). When the App declared `.app_context = T`
/// (`declared_type` = its `@typeName`, else null), `onBootstrap` MUST have installed the
/// handle (`context_ptr` non-null) via `ctx.setAppData`. A declared-but-null handle returns
/// `error.AppContextNotSet` (serveImpl logs the actionable message + fails startup); an
/// undeclared context (null `declared_type`) is always ok. Kept pure (no logging) so the
/// contract is unit-testable without a full server boot or captured log noise.
fn checkAppContextInitialized(declared_type: ?[]const u8, context_ptr: ?*anyopaque) error{AppContextNotSet}!void {
    if (declared_type != null and context_ptr == null) return error.AppContextNotSet;
}

test "checkAppContextInitialized enforces the app-context boot contract (#245)" {
    var payload: u32 = 0;
    const ptr: *anyopaque = @ptrCast(&payload);
    // Declared + a handle installed → ok.
    try checkAppContextInitialized("AppData", ptr);
    // Declared but never set (null handle) → the headline "refuses to start" guarantee.
    try std.testing.expectError(error.AppContextNotSet, checkAppContextInitialized("AppData", null));
    // Undeclared (null type) → always ok, whether or not a stray ptr is present.
    try checkAppContextInitialized(null, null);
    try checkAppContextInitialized(null, ptr);
}

/// Owned holder for a fully-booted `App` and every instance the App holds an INTERIOR
/// POINTER into. Heap-allocated by `bootApp` and filled IN PLACE so `&holder.pool`,
/// `&holder.storage_iface`, `&holder.am_registry`, `&holder.rate_limiter`, … all have
/// STABLE addresses that outlive the boot function — the App's `.pool` / `.storage` /
/// `.mailer` / `.sms_sender` / `.auth_methods` / `.rate_limiter` / `.col_cache` /
/// `.feature_cache` fields point straight at these sibling fields. Nothing here may be
/// a stack local (that is precisely the dangling-pointer bug this refactor exists to avoid).
///
/// The type is parameterized by the comptime `opts` because the storage/mailer/sms plugin
/// instances and the auth-method registry storage are comptime-selected types.
///
/// `deinit` tears everything down in the reverse order the fields were initialized (mirroring
/// the `defer` LIFO the monolithic `serveImpl` used), then frees the owned jwt secret and
/// finally destroys the heap box. The scheduler and background memory pool are NOT owned here
/// — they live in `serveImpl` (the "serve" half) and must be stopped/joined BEFORE `deinit`
/// runs, because their worker threads touch `pool`/`storage`.
fn BootedApp(comptime opts: ServeOpts) type {
    const am_types = opts.auth_method_types;
    const AuthMethod = @import("auth/method.zig").AuthMethod;
    const SmsSender = @import("sms/sender.zig").SmsSender;
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// Resolved config (jwt_secret already stamped). String slices still borrow the
        /// caller-owned backing exactly as the App fields do; this copy is a convenience so
        /// `serveImpl` can read http_host/http_port after boot.
        cfg: config.Config,
        /// Owned by the holder (freed last, after pool). The App's `.jwt_secret` borrows it.
        jwt_secret: []const u8,
        pool: db.Pool,
        /// Only meaningful when `cfg.field_key.len > 0`; the pool holds a pointer into it.
        field_cipher: field_policy.Cipher,
        storage_inst: opts.StoragePlugin,
        storage_iface: files_storage.Storage,
        mailer_inst: opts.MailerPlugin,
        mailer_iface: mail.Mailer,
        reporter_inst: opts.ReporterPlugin,
        reporter_iface: report_reporter.Reporter,
        /// #244 stage 2 — error-report TTL dedup. Always declared (a `Dedup` with an empty map
        /// costs no heap until used); `app.report_dedup` is pointed here ONLY when the configured
        /// window is > 0, so `.off` never allocates a map and leaves the pointer null.
        report_dedup_inst: report_dedup.Dedup,
        sms_inst: opts.SmsProviderPlugin,
        sms_iface: SmsSender,
        /// Registry storage: `am_registry.methods` points into `am_views`, which is built
        /// from `am_insts`. All three must keep stable addresses across the App's lifetime.
        am_insts: registry.Instances(am_types),
        am_views: [am_types.len]AuthMethod,
        am_registry: registry.Registry,
        rate_limiter: ratelimit.RateLimiter,
        /// Heap-allocated root set (embedded mode) or empty; freed by `freeSpaRoots`.
        spa_roots: []const []const u8,
        col_cache_inst: ?colcache.Cache,
        feature_cache_inst: feature_cache.FeatureOverrideCache,
        /// The fully-assembled application. Interior pointers reference the sibling fields
        /// above. `serveImpl` takes `&self.app` for the server/scheduler/mem-pool.
        app: app_mod.App,

        pub fn deinit(self: *Self) void {
            self.report_dedup_inst.deinit();
            self.feature_cache_inst.deinit();
            if (self.col_cache_inst) |*c| c.deinit();
            static_files.freeSpaRoots(self.allocator, self.spa_roots);
            self.rate_limiter.deinit();
            registry.deinit(am_types, &self.am_insts);
            self.sms_inst.deinit();
            self.reporter_inst.deinit();
            self.mailer_inst.deinit();
            self.storage_inst.deinit();
            self.pool.deinit();
            self.allocator.free(self.jwt_secret);
            const alloc = self.allocator;
            alloc.destroy(self);
        }
    };
}

/// Boot the full application WITHOUT binding a socket, returning an owned `*BootedApp(opts)`.
///
/// This is the reusable seam extracted out of `serveImpl` (Stage 1 of the in-process test
/// harness, #239): it runs everything the monolithic serve path did before `srv.listen()` —
/// jwt resolution, dev-mode clock/entropy install, pool open, field-cipher resolution, migrations +
/// comptime provisioning, startup GC sweeps, storage/mailer/sms plugin creation, the auth-method
/// registry, the rate limiter, static-source resolution, and the App assembly (+ metadata /
/// feature caches and the captcha/unsubscribe/VAPID validations) — in the SAME order.
///
/// It ALSO fires `onBootstrap` (bootstrap is part of "boot" — the harness will want it to have
/// run) and enforces the app-context boot contract. It does NOT fire `onBeforeServe` /
/// `onBeforeTerminate`, nor start the scheduler / memory pool — those are the "serve" half and
/// stay in `serveImpl` (or, in Stage 3, the harness) after `bootApp` returns a ready App.
///
/// The holder is heap-allocated and every field is filled IN PLACE so the App's interior
/// pointers reference stable sibling fields (never a stack local). On any failure the errdefers
/// unwind exactly the resources initialized so far; on success ownership transfers to the caller,
/// who must eventually call `holder.deinit()`.
/// When the built-in webhook job kind is registered, warn about every declared queue whose
/// `visibility_timeout_s` sits below `webhook.minSafeVisibilityTimeoutS()` — the worst-case time a
/// default webhook delivery can occupy a worker (in-handler retry backoff + all HTTP attempts). A
/// shorter timeout lets `reclaimStale` re-dispatch an in-flight delivery as a concurrent DUPLICATE.
/// The active queue's timeout is not reachable from the delivery's job `Ctx`, so this startup check
/// (fail-open: warn, never refuse) is the seam where a low value is surfaced. See the FOLLOW-UP note
/// on `webhook.deliver`.
fn warnUnsafeWebhookQueues(reg: *const queue.Registry) void {
    if (reg.jobByKind(webhook.job_kind) == null) return; // webhooks not compiled in
    const floor_s = webhook.minSafeVisibilityTimeoutS();
    for (reg.queues) |q| {
        if (q.visibility_timeout_s < floor_s) {
            std.log.warn(
                "queue '{s}' has visibility_timeout_s={d}s, below the {d}s a webhook delivery can occupy a worker (in-handler retry backoff up to {d}ms + HTTP attempts). If you deliver webhooks on it, reclaimStale may re-dispatch an in-flight delivery as a concurrent DUPLICATE. Raise this queue's visibility_timeout_s, or lower the per-webhook retries/backoff.",
                .{ q.name, q.visibility_timeout_s, floor_s, webhook.max_total_backoff_ms },
            );
        }
    }
}

fn bootApp(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg_in: config.Config,
    dispatch: *const events.Dispatch,
    jobs: []const scheduler.RuntimeJob,
    pool_size: usize,
    schema_collections: []const schema.Collection,
    schema_migrations: []const provision.Migration,
    comptime opts: ServeOpts,
    environ: *const std.process.Environ.Map,
) !*BootedApp(opts) {
    // jobs / pool_size are consumed by the scheduler (the "serve" half in serveImpl); they are
    // accepted here only to keep the boot entry point's signature stable for the Stage-3 harness.
    _ = jobs;
    _ = pool_size;

    const Holder = BootedApp(opts);
    const holder = try allocator.create(Holder);
    errdefer allocator.destroy(holder);
    holder.allocator = allocator;

    var cfg = cfg_in;
    const jwt_secret = try resolveJwtSecret(allocator, io, cfg);
    errdefer allocator.free(jwt_secret);
    cfg.jwt_secret = jwt_secret;
    holder.jwt_secret = jwt_secret;
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
    // When the built-in webhook job kind is compiled in, warn at startup about any declared queue
    // whose `visibility_timeout_s` is too small to safely host a webhook delivery's in-handler
    // retry backoff (else `reclaimStale` can re-dispatch an in-flight delivery as a concurrent
    // duplicate — see `webhook.minSafeVisibilityTimeoutS`). Fail-open (warn, never refuse): the
    // queue may never actually carry a webhook, and the delivery's own budget still abandons rather
    // than overrunning unboundedly.
    if (opts.queues) |reg| warnUnsafeWebhookQueues(reg);
    if (cfg.sse_heartbeat_seconds != 0 and cfg.sse_heartbeat_seconds > 255) {
        std.log.err("refusing to start: ZIGBASE_SSE_HEARTBEAT_SECONDS/--sse-heartbeat-seconds must be 0 (inherit) or 1..=255, got {d}", .{cfg.sse_heartbeat_seconds});
        return error.InvalidSseHeartbeat;
    }
    holder.pool = try openPoolSelect(allocator, io, cfg, .{ .reader_cap = opts.reader_pool_size, .cache_kib = opts.cache_kib }, environ);
    errdefer holder.pool.deinit();
    // Transparent at-rest field encryption (Theme B1). Resolve the cipher ONCE from
    // ZIGBASE_FIELD_KEY and stamp it onto the pool so every acquired connection carries
    // it (db.zig). FAIL-CLOSED: if any collection declares an `.encrypted` field but no
    // key is configured, refuse to start rather than silently storing plaintext. The
    // cipher lives in the holder (stable address); the pool points at it.
    if (dev.enabled and cfg.field_crypto == .fake) {
        // Dev-only readable at-rest crypto (build-gated: dead on a release binary).
        const label = if (cfg.field_key.len > 0) cfg.field_key else "@test@";
        holder.field_cipher = field_policy.Cipher.fake(io, label);
        db.poolSetFieldCipher(&holder.pool, @ptrCast(&holder.field_cipher));
        // Only shout when the app actually declares an `.encrypted` field — otherwise the
        // stamped cipher is inert and the notice would be pure noise (e.g. every harness test).
        if (anyEncryptedField(schema_collections))
            std.log.warn("FAKE FIELD CRYPTO ACTIVE (ZIGBASE_FIELD_CRYPTO=fake, label \"{s}\") — .encrypted values are stored READABLE as `fake:<label>:<plaintext>`. This must NEVER appear on a production build.", .{label});
    } else if (cfg.field_key.len > 0) {
        holder.field_cipher = field_policy.Cipher.resolve(io, config.EnvGetter{ .environ = environ }, cfg.field_key, cfg.field_key_generation) catch |e| {
            std.log.err("refusing to start: invalid field-encryption key config ({s}); see ZIGBASE_FIELD_KEY_GENERATION / ZIGBASE_FIELD_KEY_V<n>", .{@errorName(e)});
            return e;
        };
        db.poolSetFieldCipher(&holder.pool, @ptrCast(&holder.field_cipher));
        if (cfg.field_key_generation != 1)
            std.log.info("field encryption: primary generation v{d} (writes); older generations read from ZIGBASE_FIELD_KEY_V<n>. Run `zigbase rewrap` to migrate old data forward.", .{cfg.field_key_generation});
    } else if (anyEncryptedField(schema_collections)) {
        std.log.err("refusing to start: a collection declares an .encrypted field but ZIGBASE_FIELD_KEY is not set (encrypted data would be unreadable / stored as plaintext)", .{});
        return error.FieldKeyRequired;
    }
    {
        const w = holder.pool.acquireWriter();
        defer holder.pool.releaseWriter();
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
            // OIDC discovery (spec §F4): startup-only, HTTPS-only, issuer-checked; ANY
            // failure refuses to start (fail closed — no silently-dead login).
            const hc = try oauth_client.httpContext(prov_arena.allocator(), io);
            const resolved2 = provision.resolveDiscoveryProviders(
                prov_arena.allocator(),
                oauth_client.httpTransport(hc),
                resolved,
            ) catch |e| {
                std.log.err("refusing to start: OIDC discovery failed ({s}); fix the provider's .discoveryURL / network and restart", .{@errorName(e)});
                return e;
            };
            try provision.applySpecs(allocator, io, w, resolved2);
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
        if (db.poolFieldCipher(&holder.pool) == null) {
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
    // Instantiate the comptime-selected storage + mailer plugins into the holder (stable
    // addresses that outlive boot), and build the vtable handles pointing at them.
    holder.storage_inst = try opts.StoragePlugin.create(allocator, io, cfg);
    errdefer holder.storage_inst.deinit();
    holder.storage_iface = holder.storage_inst.interface();

    holder.mailer_inst = try opts.MailerPlugin.create(allocator, io, cfg);
    errdefer holder.mailer_inst.deinit();
    holder.mailer_iface = holder.mailer_inst.interface();

    // Error-reporter plugin (#244): the terminal backstop `dispatchError` routes every
    // framework-swallowed error through. Instantiated INTO the holder (stable address that
    // outlives boot) so `reporter_iface` captures `&holder.reporter_inst` at its final
    // location — exactly like storage/mailer.
    holder.reporter_inst = try opts.ReporterPlugin.create(allocator, io, cfg);
    errdefer holder.reporter_inst.deinit();
    holder.reporter_iface = holder.reporter_inst.interface();

    holder.sms_inst = try opts.SmsProviderPlugin.create(allocator, io, cfg);
    errdefer holder.sms_inst.deinit();
    holder.sms_iface = holder.sms_inst.interface();

    // Instantiate the comptime-assembled auth method registry. `am_insts` and `am_views` live
    // in the holder (stable addresses that outlive boot). The Registry value points into
    // `am_views`, so all three must remain valid for the App's lifetime.
    const am_types = comptime opts.auth_method_types;
    holder.am_insts = undefined;
    holder.am_views = undefined;
    holder.am_registry = try registry.build(am_types, &holder.am_insts, &holder.am_views, allocator, io, cfg);
    errdefer registry.deinit(am_types, &holder.am_insts);

    // In-memory rate limiter for sensitive auth endpoints; lives in the holder (stable
    // address); no-ops when disabled.
    holder.rate_limiter = ratelimit.RateLimiter.init(allocator, cfg.rate_limit_max, cfg.rate_limit_window_s);
    errdefer holder.rate_limiter.deinit();

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

    // §C.2: flag/env (cfg) wins over the comptime default; unset everywhere = null,
    // and the PRE_START callback is then never registered — facil.io's stock
    // max-age=3600 stays byte-identical to today.
    const static_cc: ?[]const u8 = if (cfg.static_cache_control.len > 0)
        cfg.static_cache_control
    else
        opts.static_cache_control;
    if (static_cc) |v| {
        if (!validCacheControl(v)) {
            std.log.err("refusing to start: ZIGBASE_STATIC_CACHE_CONTROL / --static-cache-control is invalid (empty, longer than 256 bytes, or contains CR/LF)", .{});
            return error.InvalidStaticCacheControl;
        }
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
    holder.spa_roots = if (opts.enable_spa_marker) blk: {
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
    errdefer static_files.freeSpaRoots(allocator, holder.spa_roots);

    holder.app = app_mod.App{
        .allocator = allocator,
        .io = io,
        .pool = &holder.pool,
        .jwt_secret = cfg.jwt_secret,
        .public_url = cfg.public_url,
        .cookie_secure = cfg.cookie_secure,
        .auth_token_ttl_s = cfg.auth_token_ttl_s,
        .session_store = opts.session_store,
        .session_rotation_grace_s = opts.session_rotation_grace_s,
        .verification_ttl_s = cfg.verification_ttl_s,
        .password_reset_ttl_s = cfg.password_reset_ttl_s,
        .oauth_state_server = cfg.oauth_state_server,
        .oauth_state_ttl_s = cfg.oauth_state_ttl_s,
        .realtime_allowed_origins = cfg.realtime_allowed_origins,
        .sse_heartbeat_seconds = @intCast(cfg.sse_heartbeat_seconds),
        .realtime_outbound_hwm = cfg.realtime_outbound_hwm,
        .trust_proxy = cfg.trust_proxy,
        .max_upload_size = cfg.max_upload_size,
        .file_token_ttl_s = cfg.file_token_ttl_s,
        .sentry_dsn = cfg.sentry_dsn,
        .static_source = static_source,
        .static_routes = opts.static_routes,
        .static_cache_control = static_cc,
        .spa_roots = holder.spa_roots,
        .spa_marker_enabled = opts.enable_spa_marker,
        .collections_frozen = opts.collections_frozen,
        .gates = opts.gates,
        .pagination = .{
            .offset_enabled = opts.pagination.offset,
            .cursor_enabled = opts.pagination.cursor,
            .cursor_token = opts.pagination.cursor_token,
        },
        .tenancy = opts.tenancy,
        .role_ranking = opts.role_ranking,
        .mail = opts.mail,
        .sms = opts.sms,
        .sms_sender = &holder.sms_iface,
        .files = opts.files,
        .push = opts.push,
        .storage = &holder.storage_iface,
        .storage_info = .{
            .backend = if (comptime build_options.s3) (if (cfg.s3_bucket.len > 0) .s3 else .local) else .local,
            .dir = "storage",
            .bucket = cfg.s3_bucket,
            .region = cfg.s3_region,
            .endpoint = cfg.s3_endpoint,
            .key_prefix = cfg.s3_key_prefix,
        },
        .mailer = &holder.mailer_iface,
        .reporter = &holder.reporter_iface,
        .auth_methods = @ptrCast(&holder.am_registry),
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
        .rate_limiter = &holder.rate_limiter,
    };
    const app = &holder.app;
    // Collection-metadata cache (R1-4): installed for SQLite (single-process, so the in-process
    // invalidation on the admin DDL endpoints is complete) OR when `collections_frozen` is set.
    // Frozen mode asserts collections never change after boot + migrations, so the cache is
    // coherent for the process lifetime on ANY backend (incl. Postgres): no invalidation ever
    // fires (the DDL endpoints 403), and provisioning/migrations run before serving. Without
    // freeze, Postgres multi-instance deployments skip it (another instance's DDL would be
    // unseen, so reads stay direct). Held in the holder so LIFO teardown (deinit) tears it down
    // LAST — realtime and record handlers borrow leases from it until zap stops.
    holder.col_cache_inst = if (db.poolDialect(&holder.pool).kind == .sqlite or opts.collections_frozen)
        colcache.Cache.init(allocator)
    else
        null;
    errdefer if (holder.col_cache_inst) |*c| c.deinit();
    if (holder.col_cache_inst) |*c| app.col_cache = c;
    // Feature-override cache (#230): installed on BOTH backends. Same-instance override
    // writes invalidate it instantly (the ctx/settings write sites call `invalidate()`,
    // NOT gated on the realtime reactor); a Postgres cross-instance write self-heals within
    // the snapshot TTL (≤5s). The two caches are independent, so teardown order between them
    // does not matter.
    holder.feature_cache_inst = feature_cache.FeatureOverrideCache.init(allocator);
    errdefer holder.feature_cache_inst.deinit();
    app.feature_cache = &holder.feature_cache_inst;
    // #244 stage 2 — error-report TTL dedup. Always CONSTRUCT the holder value (an empty map,
    // no heap), but point `app.report_dedup` at it ONLY when the comptime window is > 0. When
    // `.reporter_dedup = .off`, `opts.report_dedup_window_s == 0` folds this branch away, the
    // pointer stays null, and `dispatchError` skips dedup entirely (no map ever allocated). The
    // `deinit()` on an untouched empty map is a no-op, so unconditional construction is safe.
    holder.report_dedup_inst = report_dedup.Dedup.init(
        allocator,
        if (opts.report_dedup_window_s > 0) opts.report_dedup_window_s else report_dedup.default_window_s,
    );
    if (comptime opts.report_dedup_window_s > 0) app.report_dedup = &holder.report_dedup_inst;
    // Loud startup warning for the captcha dev-bypass: a configured provider with an empty
    // secret silently passes EVERY verifyCaptcha (the dev-bypass), a prod footgun. Mirrors
    // the `@public`-rule startup warning so operators catch it before deploying.
    if (opts.captcha_provider != null and opts.captcha_secret.len == 0) {
        std.log.warn("captcha: provider configured but secret is empty — dev-bypass active, ALL captchas will pass; set the secret before deploying", .{});
    }
    // One-click unsubscribe (#154 round 2): env overrides the comptime .mail key so the
    // stock binary is configurable at runtime (and e2e-testable). Validate the EFFECTIVE
    // value fail-fast — a malformed base URL would mint dead links into outbound mail.
    if (cfg.unsubscribe_base_url.len > 0) app.mail.unsubscribe_base_url = cfg.unsubscribe_base_url;
    if (app.mail.unsubscribe_base_url.len > 0) {
        const u = app.mail.unsubscribe_base_url;
        var bad = !std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://");
        for (u) |c| {
            if (c <= ' ' or c == 127) bad = true;
        }
        if (bad) {
            std.log.err("refusing to start: ZIGBASE_UNSUBSCRIBE_BASE_URL / .mail.unsubscribe_base_url must be an http(s) URL with no whitespace/control chars (got \"{s}\")", .{u});
            return error.InvalidUnsubscribeBaseUrl;
        }
    }
    // Web Push (#223): resolve the VAPID keypair from env (base64url). Absent → push stays a
    // network-free logging no-op (`configured = false`, the default). Present-but-invalid or
    // half-configured fails fast at boot with an actionable error — never silently minting
    // invalid VAPID headers post-boot.
    if (cfg.vapid_public_key.len > 0 or cfg.vapid_private_key.len > 0) {
        app.push = push_cfg.resolve(app.push.subject, cfg.vapid_public_key, cfg.vapid_private_key) catch |e| {
            std.log.err("refusing to start: invalid VAPID keys ({s}) — generate a matched pair with `zigbase vapid-keygen` and set ZIGBASE_VAPID_PUBLIC_KEY/ZIGBASE_VAPID_PRIVATE_KEY", .{@errorName(e)});
            return e;
        };
        std.log.info("web push: VAPID keys configured; ctx.push() will deliver notifications", .{});
    }
    const Ctx = @import("ctx.zig").Ctx;
    // onBootstrap is part of "boot": it runs here (inside bootApp) so a booted App — including
    // the in-process test harness in Stage 3 — is fully bootstrapped before use. Each lifecycle
    // hook gets a per-invocation arena owning any ctx.records() results, declared before cx so
    // its deinit runs last (LIFO).
    if (dispatch.on_bootstrap) |h| {
        var ev = events.LifecycleEvent{ .app = app };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cx = Ctx{ .app = app, .arena = RequestArena.from(&arena), .rctx = .{}, .request = null, .bound_conn = null };
        defer cx.deinit();
        h(&cx, &ev) catch |e| {
            std.log.err("refusing to start: onBootstrap hook failed: {s}", .{@errorName(e)});
            return e;
        };
    }
    // #245: a config that DECLARES `.app_context = T` MUST install the handle in onBootstrap
    // (`ctx.setAppData`). Enforce the contract at boot — fail fast with an actionable error,
    // never post-boot (a null handle would only surface as an assert on the first appData read).
    checkAppContextInitialized(dispatch.app_context_type, app.app_context) catch |e| {
        std.log.err("refusing to start: config declared `.app_context = {s}` but `ctx.setAppData` was never called — set it in your `onBootstrap` hook", .{dispatch.app_context_type.?});
        return e;
    };

    // Persist the resolved cfg (with jwt_secret stamped) so serveImpl can read host/port.
    holder.cfg = cfg;
    return holder;
}

fn serveImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg_in: config.Config,
    dispatch: *const events.Dispatch,
    jobs: []const scheduler.RuntimeJob,
    pool_size: usize,
    schema_collections: []const schema.Collection,
    schema_migrations: []const provision.Migration,
    comptime opts: ServeOpts,
    environ: *const std.process.Environ.Map,
    /// The tracked session, or null for an untracked run (`--ignore-lock`, or
    /// `App.run`'s explicit-config embedding entry). Borrowed: the caller owns
    /// it and calls `shutdown` after this returns.
    session: ?*serve_control.Session,
) !void {
    // NOTE: the logging config is already installed — `loadCfg` applies it as soon as
    // env and flags are merged (one `logging.apply` per run, no double-install), which
    // is still before any worker thread exists or the db pool opens, so provisioning
    // and migration output inside `bootApp` uses it exactly as before. It is also now
    // early enough to cover the CLI arm's own pre-boot records (the `--ignore-lock`
    // notice, the duplicate-session refusal), which never reach this function.
    //
    // Boot the full application (everything before the socket bind), then fire onBeforeServe,
    // start the scheduler + background pool, and listen. `holder` OWNS the pool / storage /
    // mailer / registry / caches the App points into; its deinit runs LAST (LIFO), after the
    // scheduler and memory pool have been stopped and joined below.
    const holder = try bootApp(allocator, io, cfg_in, dispatch, jobs, pool_size, schema_collections, schema_migrations, opts, environ);
    defer holder.deinit();
    const app = &holder.app;
    const cfg = holder.cfg;

    // Emit the baked-in component versions once at boot (#282) — the same block `--version`
    // and `GET /api/health` report, so an operator can see (and audit) what a running binary
    // vendors straight from the logs. sqlite is the LIVE linked version; the rest come from
    // build_options (single source of truth).
    std.log.info(
        "versions: zigbase {s} ({s}) | sqlite {s} | sqlite-vec {s} ({s}) | zap {s} | facil.io {s} | zig {s}",
        .{
            build_options.version,
            build_options.commit,
            db.libVersion(),
            build_options.sqlite_vec_version,
            sqlite_vec_note,
            build_options.zap_version,
            build_options.facil_version,
            builtin.zig_version_string,
        },
    );

    const Ctx = @import("ctx.zig").Ctx;
    if (dispatch.on_before_serve) |h| {
        var ev = events.LifecycleEvent{ .app = app };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cx = Ctx{ .app = app, .arena = RequestArena.from(&arena), .rctx = .{}, .request = null, .bound_conn = null };
        defer cx.deinit();
        h(&cx, &ev) catch |e| {
            std.log.err("refusing to start: onBeforeServe hook failed: {s}", .{@errorName(e)});
            return e;
        };
    }
    // before_terminate fires when listen() returns (graceful shutdown / error). Declared after
    // holder.deinit's defer, so (LIFO) it runs BEFORE the holder is torn down — the hook may
    // still touch app.pool / records.
    defer if (dispatch.on_before_terminate) |h| {
        var ev = events.LifecycleEvent{ .app = app };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cx = Ctx{ .app = app, .arena = RequestArena.from(&arena), .rctx = .{}, .request = null, .bound_conn = null };
        defer cx.deinit();
        h(&cx, &ev) catch |e| std.log.err("onBeforeTerminate hook failed: {s}", .{@errorName(e)});
    };
    const host_z = try allocator.dupeZ(u8, cfg.http_host);
    defer allocator.free(host_z);
    const Srv = server.Server(opts.gates);
    var srv = Srv{ .app = app, .host = host_z, .port = cfg.http_port };
    if (session) |s| {
        srv.on_listening = .{ .call = serve_control.Session.onListening, .ctx = s };
    }
    // Bounded background pool for memory-queue jobs + app.submit (R1-2). Worker threads
    // spawn lazily on first use (zero overhead when unused) and stop() drains + joins.
    // Its defer is registered BEFORE the scheduler's, so (LIFO) the scheduler stops FIRST
    // — a cron handler may still enqueue/submit during its final run.
    var mem_pool = queue_memory.Pool.init(app);
    mem_pool.install(app);
    defer mem_pool.stop();
    // Start the scheduler only when jobs are configured. Registered LAST among the teardown
    // defers, so (LIFO) its stop()+deinit() runs FIRST on return — joining worker threads
    // before holder.deinit() frees pool/storage, since workers touch app.pool/storage.
    var sched: ?scheduler.Scheduler = if (jobs.len > 0) try scheduler.Scheduler.initSized(allocator, app, jobs, pool_size, opts.job_stack_size) else null;
    if (sched) |*s| try s.start();
    defer if (sched) |*s| {
        s.stop();
        s.deinit();
    };
    // Schema-generation observer: polls the `_schema_state` marker and drops the collection cache
    // when another process (a `zigbase migrate`/`import` against the same data dir, or another
    // instance) changed collection metadata. Gated on the cache existing, which makes it an exact
    // no-op wherever no cache is installed. It DOES run under `.collections_frozen`: frozen mode
    // is precisely the multi-instance deployment where a rolling-deploy migration on another
    // instance silently violates frozen mode's "metadata never changes after boot" premise, so
    // noticing is more valuable there, not less.
    var schema_watcher: ?schema_gen.Watcher = if (app.col_cache) |cc|
        .{ .io = app.io, .pool = app.pool, .cache = cc }
    else
        null;
    if (schema_watcher) |*sw| try sw.start();
    defer if (schema_watcher) |*sw| sw.stop();
    try srv.listen();
}

/// `zigbase vapid-keygen` — generate a fresh VAPID (Web Push) keypair and print both keys
/// base64url, with a hint to wire them via env. The private key is a SECRET; the public key is
/// the browser's `applicationServerKey`.
fn vapidKeygenImpl(allocator: std.mem.Allocator, io: std.Io) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const kp = try push_cfg.generateKeypair(arena.allocator(), io);
    emit(io, std.Io.File.stdout(),
        \\Generated a fresh VAPID (Web Push) keypair.
        \\
        \\  ZIGBASE_VAPID_PUBLIC_KEY={s}
        \\  ZIGBASE_VAPID_PRIVATE_KEY={s}
        \\
        \\Set both in the server's environment to enable ctx.push(). The PUBLIC key is also the
        \\browser's applicationServerKey (pass it to pushManager.subscribe). Keep the PRIVATE key
        \\secret — anyone with it can send notifications as you.
        \\
    , .{ kp.public_b64, kp.private_b64 });
}

/// `zigbase explain-code [CODE] [--json]` (SP-1). Exactly ONE JSON object reaches
/// stdout under `--json`; prose diagnostics go to stderr. Exit 0 when the code is
/// registered (or when listing), 1 when it is not.
fn explainCodeImpl(io: std.Io, ea: cli.ExplainCodeArgs) void {
    const out = std.Io.File.stdout();

    const code_str = ea.code orelse {
        if (ea.json) {
            emit(io, out, "{{\"codes\":[", .{});
            inline for (@typeInfo(error_codes.Code).@"enum".fields, 0..) |field, idx| {
                const c: error_codes.Code = @enumFromInt(field.value);
                emit(io, out, "{s}{{\"code\":{f},\"summary\":{f}}}", .{
                    if (idx == 0) "" else ",",
                    std.json.fmt(error_codes.s(c), .{}),
                    std.json.fmt(error_codes.info(c).summary, .{}),
                });
            }
            emit(io, out, "]}}\n", .{});
        } else {
            inline for (@typeInfo(error_codes.Code).@"enum".fields) |field| {
                const c: error_codes.Code = @enumFromInt(field.value);
                emit(io, out, "{s}\t{s}\n", .{ error_codes.s(c), error_codes.info(c).summary });
            }
        }
        return;
    };

    const code = error_codes.parse(code_str) orelse {
        if (ea.json) {
            emit(io, out, "{{\"code\":{f},\"known\":false}}\n", .{std.json.fmt(code_str, .{})});
        } else {
            emit(io, std.Io.File.stderr(), "unknown error code '{s}'\n\n" ++
                "ZigBase never registered this code. If a consumer route produced it\n" ++
                "(ctx.jsonError takes an arbitrary string), ask that application.\n" ++
                "Run `zigbase explain-code` with no argument to list every ZigBase code.\n", .{code_str});
        }
        std.process.exit(1);
    };

    const i = error_codes.info(code);
    if (ea.json) {
        emit(io, out, "{{\"code\":{f},\"known\":true,\"summary\":{f},\"explanation\":{f}}}\n", .{
            std.json.fmt(error_codes.s(code), .{}),
            std.json.fmt(i.summary, .{}),
            std.json.fmt(i.explanation, .{}),
        });
    } else {
        emit(io, out, "{s}\n{s}\n\n{s}\n", .{ error_codes.s(code), i.summary, i.explanation });
    }
}

/// Print a scaffold report: one line per file, then the next commands to run.
fn printReport(io: std.Io, rep: scaffold.Report) void {
    for (rep.entries) |e| switch (e.outcome) {
        .created => emit(io, std.Io.File.stdout(), "  created  {s}\n", .{e.path}),
        .skipped => emit(io, std.Io.File.stdout(), "  skipped  {s} (already exists)\n", .{e.path}),
    };
}

fn initImpl(allocator: std.mem.Allocator, io: std.Io, ia: cli.InitArgs) !void {
    if (devtools.enabled) {
        const mode: scaffold.Mode = switch (ia.mode) {
            .box => .box,
            .framework => .framework,
        };
        const rep = try scaffold.run(allocator, io, .{ .mode = mode, .dir = ia.dir, .name = ia.name });
        defer scaffold.freeReport(allocator, rep);

        emit(io, std.Io.File.stdout(), "zigbase init: {s} mode in {s}\n\n", .{ @tagName(ia.mode), ia.dir });
        printReport(io, rep);
        if (rep.skipped > 0) emit(io, std.Io.File.stdout(),
            \\
            \\{d} file(s) already existed and were left untouched. init never overwrites.
            \\
        , .{rep.skipped});

        switch (mode) {
            .box => emit(io, std.Io.File.stdout(),
                \\
                \\NEXT:
                \\  cd {s}
                \\  docker compose up -d
                \\  docker compose exec zigbase /zigbase superuser create \
                \\    --email you@example.com --password 'change-me-please' --data-dir /data
                \\  docker compose exec zigbase /zigbase schema apply /schema/collections.json
                \\
                \\Before you ship:
                \\  docker compose exec zigbase /zigbase doctor --production --data-dir /data
                \\
                \\Read AGENTS.md before you ship. Blank access rules mean LOCKED, not public.
                \\
            , .{ia.dir}),
            .framework => emit(io, std.Io.File.stdout(),
                \\
                \\NEXT:
                \\  cd {s}
                \\  zig fetch --save git+https://github.com/valthon/zigbase
                \\  zig build test
                \\  zig build run -- serve --insecure-cookies
                \\
                \\`zig fetch --save` writes the dependency URL AND its content hash into
                \\build.zig.zon. Do not hand-write either.
                \\
                \\Before you ship:
                \\  zig build run -- doctor --production
                \\
                \\Read AGENTS.md before you ship. Blank access rules mean LOCKED, not public.
                \\
            , .{ia.dir}),
        }
    } else {
        // Unreachable via the CLI in practice: cli.parse rejects `init` with
        // ParseError.DevToolsDisabled before dispatch ever reaches here in a
        // `-Ddev-tools=false` build. Kept only so this branch's analyzed body
        // never references scaffold.zig (and scaffold/**) in a stripped binary.
        emit(io, std.Io.File.stderr(), "zigbase init: {s}\n", .{devtools.disabled_note});
        std.process.exit(1);
    }
}

fn agentsMdImpl(allocator: std.mem.Allocator, io: std.Io, aa: cli.AgentsMdArgs) !void {
    if (devtools.enabled) {
        const mode: ?scaffold.Mode = if (aa.mode) |m| switch (m) {
            .box => .box,
            .framework => .framework,
        } else null;

        if (aa.to_stdout) {
            const resolved = mode orelse blk: {
                var d = std.Io.Dir.cwd().openDir(io, aa.dir, .{}) catch break :blk scaffold.Mode.box;
                defer d.close(io);
                break :blk scaffold.detectMode(io, d);
            };
            emit(io, std.Io.File.stdout(), "{s}", .{scaffold.agentsMdText(resolved)});
            return;
        }

        const rep = try scaffold.agentsMd(allocator, io, .{ .mode = mode, .dir = aa.dir });
        defer scaffold.freeReport(allocator, rep);
        printReport(io, rep);
        if (rep.skipped > 0) emit(io, std.Io.File.stdout(),
            \\
            \\Nothing was overwritten. Delete the file(s) first, or use --stdout and diff.
            \\
        , .{});
    } else {
        // Unreachable via the CLI in practice: cli.parse rejects `agents-md`
        // with ParseError.DevToolsDisabled before dispatch ever reaches here
        // in a `-Ddev-tools=false` build. Kept only so this branch's analyzed
        // body never references scaffold.zig (and scaffold/**) in a stripped binary.
        emit(io, std.Io.File.stderr(), "zigbase agents-md: {s}\n", .{devtools.disabled_note});
        std.process.exit(1);
    }
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
        \\                     [--lang ts|dart|python|kotlin]
        \\                     [--api-prefix <prefix>] [--client-name <name>] [--check]
        \\                     [--package <name>]                        (--lang kotlin only)
        \\                     [--admin-email <e> --admin-password <p>]   (with --url)
        \\
        \\Generates a typed client from a running instance's schema. --lang selects
        \\the target language (default ts). --package overrides the Kotlin `package`
        \\declaration (default io.github.valthon.zigbase.codegen.dating); ignored for
        \\every other --lang.
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
        .mail = .{},
        .webhooks = true,
        .queues = .{ .emails = .{ .backend = .durable, .priority = .high } },
        .workers = .{ .mailer = .{ .queues = .{"emails"}, .concurrency = 2 } },
        .jobs = .{ .send = qTestHandler },
    });
    try std.testing.expect(A.has_durable_queue);
    // job_regs = built-ins "report" (#244, always) + "mail" (#141) + "mail_batch_item" (#154r2)
    // + "webhook" (#144, all enabled here via R2-5's .mail/.webhooks gates) ++ consumer kinds;
    // built-ins first.
    try std.testing.expectEqual(@as(usize, 5), A.job_regs.len);
    try std.testing.expectEqualStrings("report", A.job_regs[0].kind);
    try std.testing.expectEqualStrings("mail", A.job_regs[1].kind);
    try std.testing.expectEqualStrings("mail_batch_item", A.job_regs[2].kind);
    try std.testing.expectEqualStrings("webhook", A.job_regs[3].kind);
    try std.testing.expectEqualStrings("send", A.job_regs[4].kind);
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

test "App(cfg) sets the scheduler pool size via .pools.jobs alongside the job registry" {
    // `.pools = .{ .jobs = N }` is the ONE way to set the scheduler-pool size (N1); it
    // must NOT become a job kind.
    const A = App(.{ .jobs = .{ .resize = qTestHandler }, .pools = .{ .jobs = 3 }, .mail = .{}, .webhooks = true });
    try std.testing.expectEqual(@as(usize, 3), A.job_pool_size);
    // job_regs = built-ins "report" (#244, always) + "mail" (#141) + "mail_batch_item" (#154r2)
    // + "webhook" (#144, all enabled here via R2-5's .mail/.webhooks gates) ++ consumer "resize";
    // pool_size is skipped.
    try std.testing.expectEqual(@as(usize, 5), A.job_regs.len);
    try std.testing.expectEqualStrings("report", A.job_regs[0].kind);
    try std.testing.expectEqualStrings("mail", A.job_regs[1].kind);
    try std.testing.expectEqualStrings("mail_batch_item", A.job_regs[2].kind);
    try std.testing.expectEqualStrings("webhook", A.job_regs[3].kind);
    try std.testing.expectEqualStrings("resize", A.job_regs[4].kind);
    // The compile-checked Job enum still reflects ONLY the consumer kinds (mail is a
    // built-in reached via ctx.mail().enqueue / ctx.enqueueByName, not the typed enum).
    try std.testing.expectEqual(@as(usize, 1), std.meta.fields(A.Job).len);
}

test "R2-5: built-in job kinds register only when their capability is configured" {
    // "report" (#244) is ALWAYS registered (a reporter is always wired), so every app has it
    // first; the capability-gated built-ins follow only when their config is present.
    const Bare = App(.{});
    try std.testing.expectEqual(@as(usize, 1), Bare.job_regs.len);
    try std.testing.expectEqualStrings("report", Bare.job_regs[0].kind);

    const WithMail = App(.{ .mail = .{} });
    // report ++ the mail gate's "mail" + its bulk sibling "mail_batch_item" (#154r2).
    try std.testing.expectEqual(@as(usize, 3), WithMail.job_regs.len);
    try std.testing.expectEqualStrings("report", WithMail.job_regs[0].kind);
    try std.testing.expectEqualStrings("mail", WithMail.job_regs[1].kind);
    try std.testing.expectEqualStrings("mail_batch_item", WithMail.job_regs[2].kind);

    const WithHooks = App(.{ .webhooks = true });
    try std.testing.expectEqual(@as(usize, 2), WithHooks.job_regs.len);
    try std.testing.expectEqualStrings("report", WithHooks.job_regs[0].kind);
    try std.testing.expectEqualStrings("webhook", WithHooks.job_regs[1].kind);
}

test "R2-5: mail/webhook kind names stay reserved even when unregistered" {
    // Must @compileError if uncommented — probed manually per the R2-5 task brief
    // (assertNoReservedJobKinds still rejects a consumer .jobs entry named "webhook"
    // even though .webhooks is unset here and the built-in isn't registered):
    // _ = App(.{ .jobs = .{ .webhook = qTestHandler } }).job_regs;
    try std.testing.expect(true);
}

test "App(cfg) installs the auth-lifecycle dispatcher only for a non-empty .auth.hooks group" {
    // No `.auth` at all → null (logout keeps its no-writer fast path).
    try std.testing.expect(App(.{}).dispatch.auth_lifecycle == null);
    // Empty `.auth = .{}` and hook-less `.auth = .{ .hooks = .{} }` → still null: an empty
    // group must NOT force authLogout onto the writer+authenticate path (the #98 fast-path
    // regression this guards against).
    try std.testing.expect(App(.{ .auth = .{} }).dispatch.auth_lifecycle == null);
    try std.testing.expect(App(.{ .auth = .{ .hooks = .{} } }).dispatch.auth_lifecycle == null);
    // A registered hook → installed.
    const H = struct {
        fn h(ctx: *@import("ctx.zig").Ctx, ev: *@import("events.zig").AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
        }
    };
    try std.testing.expect(App(.{ .auth = .{ .hooks = .{ .beforeLogout = H.h } } }).dispatch.auth_lifecycle != null);
}

test "E3: grouped .auth lowers hooks/methods/captcha/session" {
    const H = struct {
        fn onBeforeRegister(ctx: *@import("ctx.zig").Ctx, ev: *@import("events.zig").AuthLifecycleEvent) anyerror!void {
            _ = ctx;
            _ = ev;
        }
    };
    const A = App(.{ .auth = .{
        .hooks = .{ .beforeRegister = H.onBeforeRegister },
        .methods = .{ .builtins = .{ .password, .otp } },
        .captcha = .{ .provider = .recaptcha_v3 },
        .session = .{ .store = .table, .gc_cron = "30 * * * *" },
    } });
    try std.testing.expect(A.dispatch.auth_lifecycle != null);
    try std.testing.expectEqual(@as(usize, 2), A.auth_method_types.len);
    try std.testing.expectEqual(app_mod.SessionStore.table, A.session_store_config);
    try std.testing.expectEqualStrings("30 * * * *", A.session_gc_cron);
    try std.testing.expect(A.captcha_provider != null);
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

test "App(cfg): .auth = .{ .authed = collection } gate assembles + comptime-validates (#243)" {
    const route_types = @import("route_types.zig");
    const H = struct {
        fn me(req: *route_types.Req(void)) route_types.RouteError!void {
            _ = req;
        }
    };
    // A declared `customers` auth collection + a route gated to it assembles cleanly and the
    // lowered `authed_collection` gate rides on the RuntimeRoute with `.auth = .authed`.
    const A = App(.{
        .collections = .{ .customers = .{ .type = .auth, .fields = .{.{ .name = "name", .type = .text }} } },
        .routes = .{
            .{ .method = .GET, .path = "/api/portal/me", .handler = H.me, .auth = .{ .authed = "customers" } },
            .{ .method = .GET, .path = "/api/ops/x", .handler = H.me, .auth = .{ .authed = "customers", .allow_superuser = true } },
        },
    });
    try std.testing.expectEqual(@as(usize, 2), A.dispatch.routes.len);
    try std.testing.expectEqual(events.AuthLevel.authed, A.dispatch.routes[0].auth);
    try std.testing.expect(A.dispatch.routes[0].authed_collection != null);
    try std.testing.expectEqualStrings("customers", A.dispatch.routes[0].authed_collection.?.collection);
    try std.testing.expect(!A.dispatch.routes[0].authed_collection.?.allow_superuser);
    try std.testing.expect(A.dispatch.routes[1].authed_collection.?.allow_superuser);

    // NOTE: a negative case cannot be an inline test (it would fail the build). The following
    // would each be a loud `@compileError` if uncommented:
    //   compile-error: .auth = .{ .authed = "nope" }        // unknown/undeclared collection
    //   compile-error: .auth = .{ .authed = "posts" }       // exists but .type != .auth
    //   compile-error: .auth = .{ .authed = "customers", .bogus = true }  // unknown sibling key
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
        .pools = .{ .jobs = 3 },
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

    // Default cadence is `.{ .minutes = 5 }` (the misuse case — setting the interval
    // without a `.ttl_field` collection — is a @compileError, which can't be unit-tested).
    try std.testing.expectEqual(schedule.Interval{ .minutes = 5 }, App(.{}).ttl_gc_interval);
    try std.testing.expectEqual(schedule.Interval{ .minutes = 5 }, Ttl.ttl_gc_interval);
    try std.testing.expectEqual(schedule.Interval{ .minutes = 5 }, Ttl.jobs[0].schedule.interval);

    // `.ttl_gc_interval` overrides the cadence, and the resolved job carries it.
    const TtlFast = App(.{
        .collections = .{
            .sessions = .{ .fields = .{
                .{ .name = "token", .type = .text },
                .{ .name = "expires_at", .type = .date },
            }, .ttl_field = "expires_at" },
        },
        .ttl_gc_interval = .hourly,
    });
    try std.testing.expectEqual(schedule.Interval.hourly, TtlFast.ttl_gc_interval);
    try std.testing.expectEqual(schedule.Interval.hourly, TtlFast.jobs[0].schedule.interval);

    const TtlTen = App(.{
        .collections = .{
            .sessions = .{ .fields = .{
                .{ .name = "token", .type = .text },
                .{ .name = "expires_at", .type = .date },
            }, .ttl_field = "expires_at" },
        },
        .ttl_gc_interval = .{ .minutes = 10 },
    });
    try std.testing.expectEqual(schedule.Interval{ .minutes = 10 }, TtlTen.ttl_gc_interval);
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

test "E1: .migrations accepts a bare tuple (lowered like .static_routes)" {
    const M = struct {
        fn up(_: *migrator.Migrator) anyerror!void {}
    };
    const A = App(.{ .migrations = .{
        .{ .id = "0001_tuple_form", .up = M.up },
    } });
    try std.testing.expectEqual(@as(usize, 1), A.provision_migrations.len);
    try std.testing.expectEqualStrings("0001_tuple_form", A.provision_migrations[0].id);

    const B = App(.{ .migrations = &[_]provision.Migration{
        .{ .id = "0001_slice_form", .up = M.up },
    } });
    try std.testing.expectEqual(@as(usize, 1), B.provision_migrations.len);
}

test "migrations: change/up/transactional fields resolve (bare tuple + typed)" {
    const H = struct {
        fn ch(m: *migrator.Migrator) anyerror!void {
            _ = m;
        }
    };
    // bare-tuple form with the new fields
    const A = App(.{ .migrations = .{.{ .id = "0001_x", .change = H.ch }} });
    try std.testing.expectEqual(@as(usize, 1), A.provision_migrations.len);
    try std.testing.expect(A.provision_migrations[0].change != null);
    try std.testing.expect(A.provision_migrations[0].transactional); // default true
    // legacy up-only still lowers
    const B = App(.{ .migrations = .{.{ .id = "0001_y", .up = H.ch }} });
    try std.testing.expect(B.provision_migrations[0].up != null);
    try std.testing.expect(B.provision_migrations[0].change == null);
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

test "App(cfg) .admin defaults to enabled; .admin = .disabled flips it off (R2-2)" {
    const D = App(.{});
    try std.testing.expect(D.enable_admin);
    try std.testing.expect(D.route_gates.admin);

    const NoAdmin = App(.{ .admin = .disabled });
    try std.testing.expect(!NoAdmin.enable_admin);
    try std.testing.expect(!NoAdmin.route_gates.admin);
}

test "App(cfg) route_gates: analytics/senders/mail_webhook/tenancy follow their config keys (R2-3)" {
    // No .analytics/.mail/.tenancy keys => those route groups are gated off.
    const D = App(.{});
    try std.testing.expect(!D.route_gates.analytics);
    try std.testing.expect(!D.route_gates.senders);
    try std.testing.expect(!D.route_gates.mail_webhook);
    try std.testing.expect(!D.route_gates.tenancy);

    const A = App(.{ .analytics = .{} });
    try std.testing.expect(A.route_gates.analytics);

    const M = App(.{ .mail = .{} });
    try std.testing.expect(M.route_gates.senders);
    try std.testing.expect(M.route_gates.mail_webhook);

    const T = App(.{ .tenancy = .{ .enabled = true, .auth_collection = "users" } });
    try std.testing.expect(T.route_gates.tenancy);
}

test "R2-4: deselecting a built-in drops its method-specific routes" {
    const A = App(.{ .auth = .{ .methods = .{ .builtins = .{.password} } } });
    try std.testing.expect(!A.route_gates.webauthn);
    try std.testing.expect(!A.route_gates.magic_link);
    try std.testing.expect(!A.route_gates.oauth2);
    const B = App(.{});
    try std.testing.expect(B.route_gates.webauthn);
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

test "App(cfg) resolves the comptime .auth.session.store config (#99; defaults to .epoch)" {
    try std.testing.expectEqual(app_mod.SessionStore.epoch, App(.{}).session_store_config);
    try std.testing.expectEqual(app_mod.SessionStore.epoch, App(.{ .auth = .{ .session = .{ .store = .epoch } } }).session_store_config);
    try std.testing.expectEqual(app_mod.SessionStore.table, App(.{ .auth = .{ .session = .{ .store = .table } } }).session_store_config);
}

test "#114 session-GC job installs in table mode only (absent in epoch); cadence overridable" {
    // Epoch (default): no `_session_gc` job is installed at all — zero-overhead guarantee.
    for (App(.{}).jobs) |j| try std.testing.expect(!std.mem.eql(u8, j.name, "_session_gc"));
    for (App(.{ .auth = .{ .session = .{ .store = .epoch } } }).jobs) |j| try std.testing.expect(!std.mem.eql(u8, j.name, "_session_gc"));

    // Table mode: exactly one `_session_gc` job with the default hourly cron.
    {
        var found = false;
        for (App(.{ .auth = .{ .session = .{ .store = .table } } }).jobs) |j| if (std.mem.eql(u8, j.name, "_session_gc")) {
            found = true;
            try std.testing.expect(j.schedule == .cron);
            try std.testing.expectEqualStrings("0 * * * *", j.schedule.cron);
        };
        try std.testing.expect(found);
    }

    // `.auth.session.gc_cron` overrides the cadence.
    for (App(.{ .auth = .{ .session = .{ .store = .table, .gc_cron = "*/30 * * * *" } } }).jobs) |j|
        if (std.mem.eql(u8, j.name, "_session_gc")) try std.testing.expectEqualStrings("*/30 * * * *", j.schedule.cron);

    // Valid combinations compile (the misuse case — gc_cron without table — is a
    // @compileError, which can't be unit-tested): default-unset epoch + table-with-override.
    try std.testing.expectEqualStrings("0 * * * *", App(.{}).session_gc_cron);
    try std.testing.expectEqualStrings("*/30 * * * *", App(.{ .auth = .{ .session = .{ .store = .table, .gc_cron = "*/30 * * * *" } } }).session_gc_cron);
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

test "App(cfg) collections_frozen: default false, explicit true resolves (#234)" {
    try std.testing.expect(!App(.{}).collections_frozen);
    try std.testing.expect(App(.{ .collections_frozen = true }).collections_frozen);
    try std.testing.expect(!App(.{ .collections_frozen = false }).collections_frozen);
    // The comptime const threads into the ServeOpts bundle unchanged, so the value that
    // reaches serveImpl (and thence `app.collections_frozen`) matches the config.
    try std.testing.expect(App(.{ .collections_frozen = true }).Opts.collections_frozen);
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

test "App route metadata preserves collection-scoped auth without secrets" {
    const route_types = @import("route_types.zig");
    const TestApp = App(.{
        .collections = .{
            .members = .{ .type = .auth, .fields = .{} },
        },
        .routes = .{
            .{
                .method = .GET,
                .path = "/api/member-area",
                .auth = .{ .authed = "members", .allow_superuser = true },
                .handler = struct {
                    fn h(req: *route_types.Req(void)) route_types.RouteError!void {
                        _ = req;
                    }
                }.h,
            },
        },
    });
    const gate = TestApp.routes[0].authed_collection.?;
    try std.testing.expectEqualStrings("members", gate.collection);
    try std.testing.expect(gate.allow_superuser);
    try std.testing.expect(TestApp.routes[0].path_secret == null);
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
    const a = std.testing.allocator;

    // A plain collection created at RUNTIME (as via the collections API) — no encrypted
    // field, so the scan finds nothing and serveImpl proceeds even without a key.
    const plain = [_]schema.Field{.{ .id = "", .name = "title", .options = .{ .text = .{} } }};
    const notes = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "notes", .fields = &plain });
    defer notes.deinit(a);
    try std.testing.expect((try liveEncryptedCollection(a, &d)) == null);

    // Simulate the gap #102 closes: a collection with an encrypted field was created at
    // runtime (while a key was set). It is now DB-resident, invisible to the comptime
    // guard. The scan must surface it so serveImpl refuses to start without a key.
    const enc = [_]schema.Field{.{ .id = "", .name = "secret", .encrypted = true, .options = .{ .text = .{} } }};
    const vault = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "vault", .fields = &enc });
    defer vault.deinit(a);
    const found = try liveEncryptedCollection(a, &d);
    defer if (found) |f| a.free(f);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("vault", found.?);
}
