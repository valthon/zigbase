const std = @import("std");

// ---- Public API (grows over this plan) -------------------------------------
pub const App = @import("framework.zig").App; // comptime application builder
pub const Runtime = @import("app.zig").App; // runtime app context struct
pub const Config = @import("config.zig").Config;
pub const Server = @import("server.zig").Server;
pub const http = @import("http.zig");
pub const events = @import("events.zig");
pub const schedule = @import("schedule.zig");
// Pagination: the comptime `.pagination` config types + the cursor token-format selector,
// so a consumer can name `zigbase.CursorToken` when configuring `App(.{ .pagination = ... })`.
pub const CursorToken = @import("pagination.zig").CursorToken;
pub const PaginationConfig = @import("pagination.zig").Config;
pub const RecordEvent = events.RecordEvent;
pub const ErrorEvent = events.ErrorEvent;
pub const JobEvent = events.JobEvent; // cron/interval/reactive job + app.submit handlers
pub const AuthEvent = events.AuthEvent;
pub const AuthHandler = events.AuthHandler;
pub const AuthSuccessEvent = events.AuthSuccessEvent; // beforeAuthSuccess hook (writable, abortable)
pub const AuthSuccessHandler = events.AuthSuccessHandler;
pub const ExposureEvent = events.ExposureEvent; // .onFeatureExposure analytics hook
pub const ExposureKind = events.ExposureKind;
pub const ExposureHandler = events.ExposureHandler;
pub const Req = @import("route_types.zig").Req;
pub const RouteError = @import("route_types.zig").RouteError;
// Route-guard pipeline (#139/#142): a consumer writes the guard inline as an anonymous
// literal (`.auth = .{ .path_secret = .{ … } }`, `.rate_limit = .{ .custom = … }`), but these
// re-exports let one name the lowered types (e.g. for a helper that builds route specs).
pub const RouteAuthGuard = events.RouteAuthGuard;
pub const PathSecretGuard = events.PathSecretGuard;
pub const RateLimitKeyFn = events.RateLimitKeyFn;

// ---- Plugin / schema / migration consumer types ---------------------------
// Types an external consumer must be able to NAME to write a custom storage or
// mailer plugin, an explicit migration, or to reference the built-in plugins.

// Storage plugin: a custom storage plugin's `interface()` returns this vtable.
pub const Storage = @import("files/storage.zig").Storage;
pub const LocalStorage = @import("files/storage.zig").LocalStorage;
/// Opt-in S3-compatible storage backend (`-Ds3`; §D). A stub type in a default build —
/// naming it compiles, constructing it requires `-Ds3=true` (the PG-gated pattern).
pub const S3Storage = if (@import("build_options").s3) @import("files/s3.zig").S3Storage else struct {};

// Mailer plugin: a custom mailer plugin's `interface()` returns `Mailer`, whose
// `send` is handed an `Email`. `SmtpTls` lets a consumer pick a TLS mode in code.
pub const Mailer = @import("mail/mailer.zig").Mailer;
pub const Email = @import("mail/mailer.zig").Email;
pub const LogMailer = @import("mail/mailer.zig").LogMailer;
pub const SmtpMailer = @import("mail/mailer.zig").SmtpMailer;
pub const CommandMailer = @import("mail/mailer.zig").CommandMailer;
pub const SmtpTls = @import("config.zig").SmtpTls;
// Outbound application mail (#141): `ctx.mail().send`/`.enqueue` take a `MailMessage`.
pub const MailMessage = @import("mail/send.zig").MailMessage;
// Email subsystem (#154): HTTP-API providers, in-memory capture (tests), template engine, config.
pub const SesMailer = @import("mail/ses.zig").SesMailer;
pub const PostmarkMailer = @import("mail/postmark.zig").PostmarkMailer;
pub const CaptureMailer = @import("mail/capture.zig").CaptureMailer;
pub const MailConfig = @import("mail/config.zig").Runtime;
pub const mail_template = @import("mail/template.zig");

// Built-in plugins (for composition / overriding only one side of the pair).
pub const DefaultStoragePlugin = @import("framework.zig").DefaultStoragePlugin;
pub const DefaultMailerPlugin = @import("framework.zig").DefaultMailerPlugin;

// Migration: the `up` fn for an explicit migration receives a `*Migrator` carrying the active
// SQL dialect (so raw SQL can branch per backend); the `.migrations` config is a list of
// `Migration` entries. See `src/migrator.zig` for the cross-backend migration contract (#159).
pub const Db = @import("db.zig").Db;
/// The active database backend tag (sqlite | postgres) and the SQL `Dialect` selected for it.
/// `-Dpostgres=false` builds are always `.sqlite`; Postgres is opt-in (#159).
pub const DbBackend = @import("db.zig").Backend;
pub const Dialect = @import("sql/dialect.zig").Dialect;
pub const Migration = @import("provision.zig").Migration;
/// The dialect-aware handle a migration's `up` fn receives (#159, PR-2).
pub const Migrator = @import("migrator.zig").Migrator;

// Static files: the entry type of a build-generated embedded manifest (see
// build.zig embedStaticDir) and of `.static_files = .{ .embedded = ... }`.
pub const StaticFile = @import("static_files.zig").StaticFile;

// ---- Feature flags + experiments (#128/#129/#130) --------------------------
// Types a consumer names when declaring `.flags`/`.experiments` or building a
// registry. The typed accessors (App.flag/experiment/setFlag) and the generated
// Flag/Experiment enums live on the App(cfg) type; the runtime read paths are
// ctx.flagByName / ctx.flags().resolveAll.
pub const FlagDef = @import("features.zig").FlagDef;
pub const ExperimentDef = @import("features.zig").ExperimentDef;
pub const FeatureRegistry = @import("features.zig").Registry;

// ---- CAPTCHA verification (#140) ------------------------------------------
// Consumer-facing types for `ctx.verifyCaptcha(provider, token)`.
// The provider and result are the only externally-named types; the verify
// function is internal (reached via ctx).
pub const CaptchaProvider = @import("captcha.zig").Provider;
pub const CaptchaResult = @import("captcha.zig").Result;

// ---- Background jobs & queues (#137) ---------------------------------------
// Types a consumer names when declaring `.queues`/`.workers`/`.jobs`. The typed,
// compile-checked accessor (App.enqueue) and the generated Queue/Job enums live on
// the App(cfg) type; the runtime escape hatch is ctx.enqueue / ctx.enqueueByName.
pub const QueueDef = @import("queue/queue.zig").QueueDef;
pub const WorkerDef = @import("queue/queue.zig").WorkerDef;
pub const RetryPolicy = @import("queue/queue.zig").RetryPolicy;
pub const Backend = @import("queue/queue.zig").Backend;
pub const Priority = @import("queue/queue.zig").Priority;
pub const Backoff = @import("queue/queue.zig").Backoff;
pub const QueueRegistry = @import("queue/queue.zig").Registry;
// Outbound webhooks (#144): `ctx.webhook(url, payload, .{…})` enqueues a managed,
// retrying delivery via the built-in `"webhook"` job kind.
pub const WebhookOpts = @import("webhook.zig").WebhookOpts;
pub const WebhookHmac = @import("webhook.zig").Hmac;

// ---- Multi-tenancy / authorization foundation (#156/#155) ------------------
// `Membership` is the account+role pair a consumer names when populating a request's account
// scope (PR1 foundation; the resolver + tenant scoping land in later PRs). The `@request.account.*`
// rule macros and the additive `in` operator read it.
pub const Membership = @import("request.zig").Membership;
// Tenancy (#156, PR2): the role total-order a consumer names when configuring `.tenancy.roles`,
// and the runtime tenancy knobs / resolver enum. The tenant-scope predicate is composed
// internally by `policy.zig`; consumers configure tenancy via `App(.{ .tenancy = .{ … } })`.
pub const RoleRanking = @import("tenancy/roles.zig").Ranking;
pub const TenancyResolver = @import("tenancy/tenancy.zig").Resolver;
/// Build a cross-tenant request context (superuser/admin tooling) that suppresses tenant scoping.
pub const crossTenant = @import("tenancy/tenancy.zig").crossTenant;
// Abilities (#155, PR3): relationship-based row authorization configured via
// `App(.{ .abilities = .{ .<col> = .{ .view = .{ .relationship = .{ .via, .min_role } } } } })`.
// `policy.zig` composes the lowered predicate into the same guard stack as the access rule and
// tenant scope; `ctx.can(.action, "col", id)` authorizes a record through that same path.
pub const Ability = @import("authz/abilities.zig").Ability;
pub const Abilities = @import("authz/abilities.zig").Abilities;
pub const PolicyAction = @import("policy.zig").Action;

// ---- Ctx capability object -------------------------------------------------
pub const Ctx = @import("ctx.zig").Ctx;
/// The transaction scope passed to a `ctx.tx(T, fn(*Tx) ...)` callback — `t.records()`
/// runs writes on the in-transaction connection and `t.arena()` is the invocation arena.
/// See the `ctx.tx()` section of docs/framework.md.
pub const Tx = @import("ctx.zig").Tx;
/// Decoded URL query string returned by `ctx.query()` — `q.get("k") -> ?[]const u8`.
pub const QueryParams = @import("query/params.zig").Params;
/// Options for `ctx.subjectCookie(name, opts)` (read-or-mint opaque visitor id, #137).
pub const SubjectCookieOpts = @import("ctx.zig").SubjectCookieOpts;

// ---- General outbound HTTP client -----------------------------------------
// HttpMethod/HttpHeader use the Http-prefix to avoid collision with http.zig's
// Method/Header enums (which are already accessible via `zigbase.http.Method`).
pub const HttpClient = @import("http_client.zig").HttpClient;
pub const HttpMethod = @import("http_client.zig").Method;
pub const HttpHeader = @import("http_client.zig").Header;
pub const HttpResponse = @import("http_client.zig").HttpResponse;
pub const HttpRequestOptions = @import("http_client.zig").RequestOptions;
pub const HttpPostOptions = @import("http_client.zig").PostOptions;

// ---- Dev-only test-mode capture (#96) -------------------------------------
// Assert what the framework SENT in e2e/integration tests: an in-memory mail outbox
// (`testcapture.mail`) and outbound `ctx.http()` capture + canned-response mocking
// (`testcapture.http`). Gated by the same comptime flag as the test clock — compiled out
// of any release build (`testcapture.enabled == false`), so production is unaffected.
pub const testcapture = @import("testcapture.zig");

// ---- Auth helper surface (consumer-facing magic-link building blocks) ------
pub const auth = @import("auth_helpers.zig");

// ---- Pluggable auth method contract types ----------------------------------
// Types a consumer names when implementing a custom auth method plugin.
pub const AuthMethod = @import("auth/method.zig").AuthMethod;
pub const AuthCtx = @import("auth/method.zig").AuthCtx;
pub const InitiateResult = @import("auth/method.zig").InitiateResult;
pub const Resolution = @import("auth/method.zig").Resolution;

// ---- Code-generation modules (pure-Zig TS client generator) ---------------
pub const codegen = struct {
    pub const ts_type = @import("codegen/ts_type.zig");
    pub const identifiers = @import("codegen/identifiers.zig");
    pub const guards = @import("codegen/guards.zig");
    pub const emit = @import("codegen/emit.zig");
    /// The generator core + mainWithCollections entry-point used by gen_main.zig.
    pub const gen_client = @import("codegen/gen_client.zig");
    /// Comptime Zig-type → TypeScript emitter for route I/O types (SP2.2b).
    pub const rpc_ts = @import("codegen/rpc_ts.zig");
    /// RPC section renderer: assembles the three TS fragments from a []const RouteMeta (SP2.2b).
    pub const rpc = @import("codegen/rpc.zig");
    /// Source-agnostic schema acquisition core: RawRow → Collection, auth-strip, name-sort.
    pub const acquire = @import("codegen/acquire.zig");
    /// Data-dir acquisition adapter: reads _collections from an open db handle or a data dir path.
    pub const acquire_datadir = @import("codegen/acquire_datadir.zig");
    /// HTTP acquisition adapter: superuser auth → GET /api/collections → parse.
    pub const acquire_http = @import("codegen/acquire_http.zig");
    /// CLI orchestrator: acquire → generate → write/check (data-dir + runtime equivalence).
    pub const typegen_cli = @import("codegen/typegen_cli.zig");
};

// ---- Test discovery --------------------------------------------------------
// The unit-test runner is rooted at THIS module. Reference every internal file
// so its `test {}` blocks are analyzed and run (matches pre-restructure behavior
// where main.zig's import graph reached them).
test {
    _ = @import("app.zig");
    _ = @import("config.zig");
    _ = @import("ratelimit.zig");
    _ = @import("regex.zig");
    _ = @import("cli.zig");
    _ = @import("datetime.zig");
    _ = @import("db.zig");
    _ = @import("sql/param_sink.zig");
    _ = @import("http.zig");
    _ = @import("router.zig");
    _ = @import("request.zig");
    _ = @import("server.zig");
    _ = @import("schema.zig");
    _ = @import("collections.zig");
    _ = @import("colcache.zig");
    _ = @import("records.zig");
    _ = @import("values.zig");
    _ = @import("ddl.zig");
    _ = @import("migrations.zig");
    _ = @import("migrator.zig");
    _ = @import("rules.zig");
    _ = @import("policy.zig");
    _ = @import("tenancy/roles.zig");
    _ = @import("tenancy/tenancy.zig");
    _ = @import("authz/abilities.zig");
    _ = @import("search/fts.zig");
    _ = @import("search/vector.zig");
    _ = @import("api/accounts.zig");
    _ = @import("analytics/analytics.zig");
    _ = @import("analytics/config.zig");
    _ = @import("analytics/api.zig");
    _ = @import("crypto.zig");
    _ = @import("aead.zig");
    _ = @import("field_policy.zig");
    _ = @import("rewrap.zig");
    _ = @import("jwt.zig");
    _ = @import("auth.zig");
    _ = @import("id.zig");
    _ = @import("admin.zig");
    _ = @import("static_files.zig");
    _ = @import("api/error.zig");
    _ = @import("api/health.zig");
    _ = @import("api/collections.zig");
    _ = @import("api/records.zig");
    _ = @import("api/auth.zig");
    _ = @import("api/oauth.zig");
    _ = @import("api/files.zig");
    _ = @import("api/settings.zig");
    _ = @import("api/features.zig");
    _ = @import("api/state.zig");
    _ = @import("oauth/secrets.zig");
    _ = @import("oauth/providers.zig");
    _ = @import("oauth/client.zig");
    _ = @import("query/params.zig");
    _ = @import("query/lexer.zig");
    _ = @import("query/parser.zig");
    _ = @import("query/joiner.zig");
    _ = @import("query/compiler.zig");
    _ = @import("query/sort.zig");
    _ = @import("query/keyset.zig");
    _ = @import("query/expand.zig");
    _ = @import("pagination.zig");
    _ = @import("realtime/protocol.zig");
    _ = @import("realtime/connection.zig");
    _ = @import("realtime/hub.zig");
    _ = @import("realtime/ws.zig");
    _ = @import("realtime/pg_bridge.zig");
    _ = @import("files/naming.zig");
    _ = @import("files/mime.zig");
    _ = @import("files/storage.zig");
    _ = @import("files/plan.zig");
    _ = @import("files/multipart.zig");
    _ = @import("files/serve_file.zig");
    _ = @import("data.zig");
    _ = @import("events.zig");
    _ = @import("sentry.zig");
    _ = @import("framework.zig");
    _ = @import("provision.zig");
    _ = @import("dumpload.zig");
    _ = @import("records_hooks_test.zig");
    _ = @import("schedule.zig");
    _ = @import("scheduler.zig");
    _ = @import("mail/mailer.zig");
    _ = @import("mail/send.zig");
    _ = @import("mail/template.zig");
    _ = @import("mail/addr.zig");
    _ = @import("aws/sigv4.zig");
    _ = @import("mail/ses.zig");
    _ = @import("mail/postmark.zig");
    _ = @import("mail/capture.zig");
    _ = @import("mail/config.zig");
    _ = @import("mail/senders.zig");
    _ = @import("mail/suppression.zig");
    _ = @import("mail/inbound.zig");
    _ = @import("api/senders.zig");
    _ = @import("codegen/ts_type.zig");
    _ = @import("codegen/identifiers.zig");
    _ = @import("codegen/guards.zig");
    _ = @import("codegen/emit.zig");
    _ = @import("codegen/gen_client.zig");
    _ = @import("codegen/rpc_ts.zig");
    _ = @import("codegen/rpc.zig");
    _ = @import("codegen/acquire.zig");
    _ = @import("codegen/acquire_datadir.zig");
    _ = @import("codegen/acquire_http.zig");
    _ = @import("codegen/typegen_cli.zig");
    _ = @import("route_types.zig");
    _ = @import("auth_helpers.zig");
    _ = @import("auth/method.zig");
    _ = @import("auth/methods/password.zig");
    _ = @import("auth/methods/magic_link.zig");
    _ = @import("auth/methods/otp.zig");
    _ = @import("auth/registry.zig");
    _ = @import("api/auth_methods.zig");
    _ = @import("api/magic_link_consume.zig");
    _ = @import("auth/methods/oauth2.zig");
    _ = @import("auth/challenge_store.zig");
    _ = @import("auth/webauthn/cbor.zig");
    _ = @import("auth/webauthn/cose.zig");
    _ = @import("auth/webauthn/authdata.zig");
    _ = @import("auth/webauthn/verify_sig.zig");
    _ = @import("auth/webauthn/client_data.zig");
    _ = @import("auth/webauthn/store.zig");
    _ = @import("auth/webauthn/register.zig");
    _ = @import("auth/webauthn/authenticate.zig");
    _ = @import("auth/methods/webauthn.zig");
    _ = @import("api/webauthn_register.zig");
    _ = @import("clock.zig");
    _ = @import("clock_sql.zig");
    _ = @import("clock_vfs.zig");
    _ = @import("clock_test.zig");
    _ = @import("entropy.zig");
    _ = @import("ctx.zig");
    _ = @import("features.zig");
    _ = @import("features_resolver.zig");
    _ = @import("queue/queue.zig");
    _ = @import("queue/config.zig");
    _ = @import("queue/durable.zig");
    _ = @import("queue/memory.zig");
    _ = @import("session.zig");
    _ = @import("http_client.zig");
    _ = @import("testcapture.zig");
    _ = @import("captcha.zig");
    _ = @import("webhook.zig");
    // Opt-in pure-Zig PostgreSQL backend (#159). The `build_options.postgres` condition is
    // comptime-known, so when it is false (the default) these `@import`s are never analyzed —
    // the driver compiles to nothing and the default build stays byte-identical.
    if (@import("build_options").postgres) {
        _ = @import("backend/postgres/postgres.zig");
        // PR-1b: the end-to-end seam smoke (db.Db union → real Postgres). Skips if no PG.
        _ = @import("backend/seam_test.zig");
        // PR-2: live-PG schema/DDL + migration parity (all 16 migrations, full provision,
        // additive-rebuild ALTER). Skips if no PG.
        _ = @import("backend/postgres/schema_pg_test.zig");
        // Wave B: live-PG auth / oauth / analytics / challenge / session end-to-end. Skips if no PG.
        _ = @import("backend/postgres/auth_pg_test.zig");
    }
    // Opt-in S3 backend (§D): compiled/tested only under -Ds3 (the postgres pattern above).
    if (@import("build_options").s3) {
        _ = @import("files/s3.zig");
    }
}
