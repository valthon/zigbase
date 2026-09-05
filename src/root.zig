const std = @import("std");

// Force the compile-time Zig-version guard on every build. Building against an
// unsupported compiler fails here with a clear required-vs-actual message rather
// than a confusing deep-compilation error downstream (see src/zig_compat.zig).
comptime {
    _ = @import("zig_compat.zig");
}

// ---- Public API (grows over this plan) -------------------------------------
pub const App = @import("framework.zig").App; // comptime application builder
pub const Runtime = @import("app.zig").App; // runtime app context struct
pub const Config = @import("config.zig").Config;
pub const Server = @import("server.zig").Server;
pub const http = @import("http.zig");
pub const events = @import("events.zig");
pub const schedule = @import("schedule.zig");
// JWT signing/verification and the HMAC key-derivation helper it uses — named here so
// bench/main.zig (and any consumer needing to mint/verify tokens directly) can `@import("zigbase")`
// rather than reach into internal source paths.
pub const jwt = @import("jwt.zig");
pub const crypto = @import("crypto.zig");
// Pagination: the comptime `.pagination` config types + the cursor token-format selector,
// so a consumer can name `zigbase.CursorToken` when configuring `App(.{ .pagination = ... })`.
pub const CursorToken = @import("pagination.zig").CursorToken;
pub const PaginationConfig = @import("pagination.zig").Config;
pub const RecordEvent = events.RecordEvent;
pub const ErrorEvent = events.ErrorEvent;
pub const JobEvent = events.JobEvent; // cron/interval/reactive job + app.submit handlers
pub const AuthEvent = events.AuthEvent;
pub const TwoFactorPolicyContext = @import("auth/two_factor.zig").PolicyContext;
pub const AuthHandler = events.AuthHandler;
pub const AuthSuccessEvent = events.AuthSuccessEvent; // beforeAuthSuccess hook (writable, abortable)
pub const AuthSuccessHandler = events.AuthSuccessHandler;
pub const ExposureEvent = events.ExposureEvent; // .onFeatureExposure analytics hook
pub const EventInput = @import("analytics/analytics.zig").EventInput;
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
/// The frozen error-code registry (`code` in the API error envelope and in each
/// `data.<field>` entry). Match on these; never on `message`.
pub const error_codes = @import("error_codes.zig");
pub const ErrorCode = error_codes.Code;

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
// Bulk / list mail (#154 round 2): `ctx.mail().sendBulk`/`.cancelBatch`/`.batchStatus`.
pub const BulkSend = @import("mail/bulk.zig").BulkSend;
pub const BulkRecipient = @import("mail/bulk.zig").BulkRecipient;
pub const BatchReport = @import("mail/bulk.zig").BatchReport;
// Email subsystem (#154): HTTP-API providers, in-memory capture (tests), template engine, config.
pub const SesMailer = @import("mail/ses.zig").SesMailer;
pub const PostmarkMailer = @import("mail/postmark.zig").PostmarkMailer;
pub const CaptureMailer = @import("mail/capture.zig").CaptureMailer;
pub const MailConfig = @import("mail/config.zig").Runtime;
pub const FilesConfig = @import("files/config.zig").Runtime;
pub const mail_template = @import("mail/template.zig");

// Outbound transactional SMS (#224): `ctx.sms().send`/`.enqueue` take an `SmsMessage`. A custom
// SMS provider plugin's `interface()` returns `SmsSender`, whose `send` is handed an `Sms`.
pub const SmsSender = @import("sms/sender.zig").SmsSender;
pub const Sms = @import("sms/sender.zig").Sms;
pub const LogSmsSender = @import("sms/sender.zig").LogSmsSender;
pub const TwilioSender = @import("sms/twilio.zig").TwilioSender;
pub const CaptureSms = @import("sms/capture.zig").CaptureSms;
pub const SmsMessage = @import("sms/send.zig").SmsMessage;
pub const SmsConfig = @import("sms/config.zig").Runtime;
pub const SmsRegion = @import("sms/e164.zig").Region;
pub const normalizeE164 = @import("sms/e164.zig").normalizeE164;

// Error-reporter plugin (#244): a custom reporter plugin's `interface()` returns `Reporter`,
// whose `report` is handed a `Report`. ZigBase ships `LogReporter` (the default when no Sentry
// DSN is set) and `SentryReporter` (POSTs a Sentry envelope when `ZIGBASE_SENTRY_DSN` is set).
pub const Reporter = @import("report/reporter.zig").Reporter;
pub const Report = @import("report/reporter.zig").Report;
pub const LogReporter = @import("report/log.zig").LogReporter;
pub const SentryReporter = @import("report/sentry.zig").SentryReporter;

// Built-in plugins (for composition / overriding only one side of the pair).
pub const DefaultStoragePlugin = @import("framework.zig").DefaultStoragePlugin;
pub const DefaultMailerPlugin = @import("framework.zig").DefaultMailerPlugin;
pub const DefaultReporterPlugin = @import("framework.zig").DefaultReporterPlugin;

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
pub const Rate = @import("queue/queue.zig").Rate;
pub const Backend = @import("queue/queue.zig").Backend;
pub const Priority = @import("queue/queue.zig").Priority;
pub const Backoff = @import("queue/queue.zig").Backoff;
pub const QueueRegistry = @import("queue/queue.zig").Registry;
// Outbound webhooks (#144): `ctx.webhook(url, payload, .{…})` enqueues a managed,
// retrying delivery via the built-in `"webhook"` job kind.
pub const WebhookOpts = @import("webhook.zig").WebhookOpts;
// Web Push (#223): `ctx.push().send`/`.enqueue`. A consumer names the subscription/message
// shapes and the tri-state result via these re-exports.
pub const PushSubscription = @import("push/sender.zig").PushSubscription;
pub const PushMessage = @import("push/sender.zig").PushMessage;
pub const PushResult = @import("push/sender.zig").PushResult;
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
/// A bound value for a `?` placeholder in a `ctx.records().list(...)` filter (`.filter_args`).
/// Binds as a literal SQL parameter (never re-parsed as filter grammar) — the injection-safe way
/// to splice a runtime value into a filter. See the `ctx.records()` section of docs/framework.md.
pub const FilterArg = @import("records.zig").FilterArg;

/// A request-scoped arena, constructible only from a real `*std.heap.ArenaAllocator`.
/// Contract 4 of the allocator-ownership design
/// (docs/superpowers/specs/2026-07-19-allocator-ownership-design.md): taking this type
/// instead of a plain `std.mem.Allocator` makes an arena-only dependency a compile-time
/// fact instead of an unstated assumption. See `src/request_arena.zig` for the full
/// justification requirement before a function may take one.
pub const RequestArena = @import("request_arena.zig").RequestArena;

/// The `data` facade module. Holds `data.queryAs(T, conn, alloc, sql, args)` — name-mapped
/// raw-SQL row decoding (#240): each result row is decoded into a struct `T` by matching fields
/// to result columns BY NAME (not position), so a reordered/inserted SELECT column can't misalign.
/// Get a `conn` from `ctx.connForRead()` (reader) or `ctx.app.pool.acquireWriter()`; the ergonomic
/// wrapper is `ctx.records().queryAs(T, sql, args)`. See docs/framework.md.
pub const data = @import("data.zig");

/// Comptime-checked raw SQL (#281). `checkSql`/`checkedSql`/`checkSqlOpts` validate the table and
/// qualified-column identifiers in a raw-SQL string against `App(cfg).collections`, failing the
/// build on an unknown table or a mistyped qualified column. Name the App type to reach its lowered
/// schema: `const Backend = zigbase.App(.{...}); checkedSql(Backend.collections, "SELECT ...")`.
/// Best-effort by design (tables strict; qualified columns checked; unqualified columns/functions
/// untouched) so it never rejects valid SQL. `.extra_tables` opts internal/migration-owned tables
/// (`_kv`, a migration's own table) into the known set. See docs/framework.md.
pub const checkSql = @import("sql/schema_check.zig").checkSql;
pub const checkedSql = @import("sql/schema_check.zig").checkedSql;
pub const checkSqlOpts = @import("sql/schema_check.zig").checkSqlOpts;
pub const SqlCheckOptions = @import("sql/schema_check.zig").SqlCheckOptions;

/// Typed single-table SELECT builder (#281, option 2). `Query.select(App(cfg).collections,
/// "table", .{ .columns, .where, .order, .limit, .offset, .distinct })` returns a type whose
/// `.sql` is a comptime-validated `[:0]const u8` (`?N`-parameterized) and whose `.bind_count`
/// is the number of positional binds — feed both to `queryAs`/`prepare`. Unknown table/column
/// is a build error. SELECT-only, single-table in v1 (joins/writes/`in` are future). See
/// docs/framework.md. Namespaced under `Query` to keep `select`/`Op`/`Dir` off the root.
pub const Query = @import("sql/query_builder.zig");

/// Offline, encryption-aware bulk NDJSON record import (issue #283). Backs the `zigbase import`
/// CLI subcommand and is usable directly from a small consumer migration/seed binary:
/// `zigbase.Import.run(app, writer, io, reader, .{ .collection = "posts" })` streams NDJSON
/// through the record engine (validation + defaults + `.encrypted` envelope + auth hashing),
/// batching on the writer connection, with optional `--upsert-key` idempotency and source-id
/// preservation. See `Import.Options` / `Import.Report` and docs/framework.md.
pub const Import = @import("import.zig");
// ---- General outbound HTTP client -----------------------------------------
// HttpMethod/HttpHeader use the Http-prefix to avoid collision with http.zig's
// Method/Header enums (which are already accessible via `zigbase.http.Method`).
pub const HttpClient = @import("http_client.zig").HttpClient;
pub const HttpMethod = @import("http_client.zig").Method;
pub const HttpHeader = @import("http_client.zig").Header;
pub const HttpResponse = @import("http_client.zig").HttpResponse;
pub const HttpRequestOptions = @import("http_client.zig").RequestOptions;
pub const HttpPostOptions = @import("http_client.zig").PostOptions;

// ---- Structured logging ----------------------------------------------------
// A consumer binary opts in from its own root: `pub const std_options = zigbase.std_options;`.
// This routes every `std.log` call through the same encoder as request logging. Access
// lines and `--log-format`/`--log-level` work either way (the server logs them directly);
// omitting the line just leaves std.log output in Zig's default format, mixed with JSON
// access lines under `--log-format json`.
pub const logging = @import("logging.zig");
pub const std_options = logging.std_options;

// ---- Dev-only test-mode capture (#96) -------------------------------------
// Assert what the framework SENT in e2e/integration tests: an in-memory mail outbox
// (`testcapture.mail`) and outbound `ctx.http()` capture + canned-response mocking
// (`testcapture.http`). Gated by the same comptime flag as the test clock — compiled out
// of any release build (`testcapture.enabled == false`), so production is unaffected.
pub const testcapture = @import("testcapture.zig");

// ---- In-process test harness (#239) ---------------------------------------
// Boot an `App(.{...})` against a tempdir data dir and inject requests through the REAL
// pipeline (router + rules + auth + hooks + custom routes) with NO socket. Auth helpers
// (`mintSession` direct-JWT, `loginSuperuser`/`loginPassword` real-endpoint), record/superuser
// seeding, and a swappable `CaptureMailer`. See `docs/framework.md` — "Testing your app".
pub const testing = @import("testing.zig");

// ---- Benchmark-only internals ---------------------------------------------
// The lower-level record read path + schema types are exposed only to the private module
// constructed for `zig build bench`. Shipped and consumer modules always set internal_api=false,
// independently of dev_mode, while benchmarks keep the fake clock/entropy/capture seams off.
// This is module access for the harness, not a public API surface.
pub const internal = if (@import("build_options").internal_api) struct {
    pub const dev_mode_enabled = @import("build_options").dev_mode;
    pub const records = @import("records.zig");
    pub const schema = @import("schema.zig");
    pub const db = @import("db.zig");
    pub const query = struct {
        pub const lexer = @import("query/lexer.zig");
        pub const parser = @import("query/parser.zig");
        pub const compiler = @import("query/compiler.zig");
        pub const joiner = @import("query/joiner.zig");
    };
} else struct {};

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
    /// Field → Dart type mapper (the Dart counterpart of ts_type.zig).
    pub const dart_type = @import("codegen/dart_type.zig");
    /// Per-fragment Dart emitters (the Dart counterpart of emit.zig).
    pub const emit_dart = @import("codegen/emit_dart.zig");
    /// The Dart generator core (the Dart counterpart of gen_client.generate).
    pub const gen_dart = @import("codegen/gen_dart.zig");
    /// Source-agnostic schema acquisition core: RawRow → Collection, auth-strip, name-sort.
    pub const acquire = @import("codegen/acquire.zig");
    /// Data-dir acquisition adapter: reads _collections from an open db handle or a data dir path.
    pub const acquire_datadir = @import("codegen/acquire_datadir.zig");
    /// HTTP acquisition adapter: superuser auth → GET /api/collections → parse.
    pub const acquire_http = @import("codegen/acquire_http.zig");
    /// CLI orchestrator: acquire → generate → write/check (data-dir + runtime equivalence).
    pub const typegen_cli = @import("codegen/typegen_cli.zig");
    /// Field → Python type mapper (the Python counterpart of dart_type.zig).
    pub const python_type = @import("codegen/python_type.zig");
    /// Per-fragment Python emitters (the Python counterpart of emit_dart.zig).
    pub const emit_python = @import("codegen/emit_python.zig");
    /// The Python generator core (the Python counterpart of gen_dart.generate).
    pub const gen_python = @import("codegen/gen_python.zig");
    /// Field → Kotlin type mapper (the Kotlin counterpart of dart_type.zig/python_type.zig).
    pub const kotlin_type = @import("codegen/kotlin_type.zig");
    /// Per-fragment Kotlin emitters (the Kotlin counterpart of emit_python.zig).
    pub const emit_kotlin = @import("codegen/emit_kotlin.zig");
    /// The Kotlin generator core (the Kotlin counterpart of gen_python.generate).
    pub const gen_kotlin = @import("codegen/gen_kotlin.zig");
};

// ---- Test discovery --------------------------------------------------------
// The unit-test runner is rooted at THIS module. Reference every internal file
// so its `test {}` blocks are analyzed and run (matches pre-restructure behavior
// where main.zig's import graph reached them).
test {
    _ = @import("zig_compat.zig");
    _ = @import("app.zig");
    _ = @import("config.zig");
    _ = @import("ratelimit.zig");
    _ = @import("regex.zig");
    _ = @import("cli.zig");
    _ = @import("serve_session.zig");
    _ = @import("serve_control.zig");
    _ = @import("datetime.zig");
    _ = @import("db.zig");
    _ = @import("sql/param_sink.zig");
    _ = @import("http.zig");
    _ = @import("router.zig");
    _ = @import("route_path.zig");
    _ = @import("request.zig");
    _ = @import("server.zig");
    _ = @import("schema.zig");
    _ = @import("collections.zig");
    _ = @import("colcache.zig");
    _ = @import("schema_gen.zig");
    _ = @import("feature_cache.zig");
    _ = @import("records.zig");
    _ = @import("values.zig");
    _ = @import("ddl.zig");
    _ = @import("migrations.zig");
    _ = @import("migrator.zig");
    _ = @import("schema_dump.zig");
    _ = @import("schema_doc.zig");
    _ = @import("openapi.zig");
    _ = @import("openapi_cli.zig");
    _ = @import("schema_diff.zig");
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
    _ = @import("import.zig");
    _ = @import("import_manifest.zig");
    _ = @import("jwt.zig");
    _ = @import("push/encrypt.zig");
    _ = @import("push/vapid.zig");
    _ = @import("push/config.zig");
    _ = @import("push/sender.zig");
    _ = @import("push/send.zig");
    _ = @import("push/capture.zig");
    _ = @import("auth.zig");
    _ = @import("id.zig");
    _ = @import("admin.zig");
    _ = @import("static_files.zig");
    _ = @import("api/error.zig");
    _ = @import("api/health.zig");
    _ = @import("api/meta.zig");
    _ = @import("api/collections.zig");
    _ = @import("api/records.zig");
    _ = @import("api/realtime.zig");
    _ = @import("api/auth.zig");
    _ = @import("api/sessions.zig");
    _ = @import("api/oauth.zig");
    _ = @import("api/files.zig");
    _ = @import("api/files_config.zig");
    _ = @import("api/settings.zig");
    _ = @import("api/features.zig");
    _ = @import("api/state.zig");
    _ = @import("oauth/secrets.zig");
    _ = @import("oauth/providers.zig");
    _ = @import("oauth/client.zig");
    _ = @import("oauth/discovery.zig");
    _ = @import("query/params.zig");
    _ = @import("query/lexer.zig");
    _ = @import("query/parser.zig");
    _ = @import("query/joiner.zig");
    _ = @import("query/compiler.zig");
    _ = @import("query/sort.zig");
    _ = @import("query/keyset.zig");
    _ = @import("query/expand.zig");
    _ = @import("query/fields.zig");
    _ = @import("pagination.zig");
    _ = @import("realtime/protocol.zig");
    _ = @import("realtime/connection.zig");
    _ = @import("realtime/hub.zig");
    _ = @import("realtime/ws.zig");
    _ = @import("realtime/pg_bridge.zig");
    _ = @import("realtime/sse_fio.zig");
    _ = @import("realtime/sse.zig");
    _ = @import("files/naming.zig");
    _ = @import("files/mime.zig");
    _ = @import("files/storage.zig");
    _ = @import("files/info.zig");
    _ = @import("files/plan.zig");
    _ = @import("files/multipart.zig");
    _ = @import("files/serve_file.zig");
    _ = @import("files/config.zig");
    _ = @import("data.zig");
    _ = @import("sql/schema_ident.zig");
    _ = @import("sql/schema_check.zig");
    _ = @import("sql/query_builder.zig");
    _ = @import("events.zig");
    _ = @import("report/reporter.zig");
    _ = @import("report/log.zig");
    _ = @import("report/sentry.zig");
    _ = @import("report/dedup.zig");
    _ = @import("report/send.zig");
    _ = @import("framework.zig");
    _ = @import("provision.zig");
    _ = @import("doctor.zig");
    _ = @import("doctor_run.zig");
    _ = @import("rules_lint.zig");
    _ = @import("dumpload.zig");
    _ = @import("records_hooks_test.zig");
    _ = @import("schedule.zig");
    _ = @import("scheduler.zig");
    _ = @import("mail/mailer.zig");
    _ = @import("mail/send.zig");
    _ = @import("mail/bulk.zig");
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
    _ = @import("mail/unsubscribe.zig");
    _ = @import("sms/sender.zig");
    _ = @import("sms/e164.zig");
    _ = @import("sms/twilio.zig");
    _ = @import("sms/capture.zig");
    _ = @import("sms/send.zig");
    _ = @import("sms/config.zig");
    _ = @import("api/senders.zig");
    _ = @import("api/mail_unsubscribe.zig");
    _ = @import("api/mail_config.zig");
    _ = @import("api/realtime_stats.zig");
    _ = @import("codegen/ts_type.zig");
    _ = @import("codegen/identifiers.zig");
    _ = @import("codegen/guards.zig");
    _ = @import("codegen/emit.zig");
    _ = @import("codegen/gen_client.zig");
    _ = @import("codegen/rpc_ts.zig");
    _ = @import("codegen/rpc.zig");
    _ = @import("codegen/dart_type.zig");
    _ = @import("codegen/emit_dart.zig");
    _ = @import("codegen/gen_dart.zig");
    _ = @import("codegen/acquire.zig");
    _ = @import("codegen/acquire_datadir.zig");
    _ = @import("codegen/acquire_http.zig");
    _ = @import("codegen/typegen_cli.zig");
    _ = @import("codegen/python_type.zig");
    _ = @import("codegen/emit_python.zig");
    _ = @import("codegen/gen_python.zig");
    _ = @import("codegen/kotlin_type.zig");
    _ = @import("codegen/emit_kotlin.zig");
    _ = @import("codegen/gen_kotlin.zig");
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
    _ = @import("auth/totp.zig");
    _ = @import("auth/two_factor_attempt.zig");
    _ = @import("auth/two_factor_policy.zig");
    _ = @import("auth/two_factor_config.zig");
    _ = @import("auth/two_factor_store.zig");
    _ = @import("auth/two_factor.zig");
    _ = @import("api/two_factor.zig");
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
    _ = @import("testing.zig");
    _ = @import("captcha.zig");
    _ = @import("webhook.zig");
    _ = @import("request_arena.zig");
    _ = @import("error_codes.zig");
    _ = @import("logging.zig");
    _ = @import("scaffold/agents_md.zig");
    _ = @import("scaffold/templates.zig");
    _ = @import("scaffold.zig");
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
