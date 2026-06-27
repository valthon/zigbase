const std = @import("std");

// ---- Public API (grows over this plan) -------------------------------------
pub const App = @import("framework.zig").App; // comptime application builder
pub const Runtime = @import("app.zig").App; // runtime app context struct
pub const Config = @import("config.zig").Config;
pub const Server = @import("server.zig").Server;
pub const http = @import("http.zig");
pub const Data = @import("data.zig").Data;
pub const events = @import("events.zig");
pub const schedule = @import("schedule.zig");
// Pagination: the comptime `.pagination` config types + the cursor token-format selector,
// so a consumer can name `zigbase.CursorToken` when configuring `App(.{ .pagination = ... })`.
pub const CursorToken = @import("pagination.zig").CursorToken;
pub const PaginationConfig = @import("pagination.zig").Config;
pub const RecordEvent = events.RecordEvent;
pub const ErrorEvent = events.ErrorEvent;
pub const RouteEvent = events.RouteEvent;
pub const JobEvent = events.JobEvent; // cron/interval/reactive job + app.submit handlers
pub const AuthEvent = events.AuthEvent;
pub const AuthHandler = events.AuthHandler;
pub const Req = @import("route_types.zig").Req;
pub const RouteError = @import("route_types.zig").RouteError;

// ---- Plugin / schema / migration consumer types ---------------------------
// Types an external consumer must be able to NAME to write a custom storage or
// mailer plugin, an explicit migration, or to reference the built-in plugins.

// Storage plugin: a custom storage plugin's `interface()` returns this vtable.
pub const Storage = @import("files/storage.zig").Storage;
pub const LocalStorage = @import("files/storage.zig").LocalStorage;

// Mailer plugin: a custom mailer plugin's `interface()` returns `Mailer`, whose
// `send` is handed an `Email`. `SmtpTls` lets a consumer pick a TLS mode in code.
pub const Mailer = @import("mail/mailer.zig").Mailer;
pub const Email = @import("mail/mailer.zig").Email;
pub const LogMailer = @import("mail/mailer.zig").LogMailer;
pub const SmtpMailer = @import("mail/mailer.zig").SmtpMailer;
pub const CommandMailer = @import("mail/mailer.zig").CommandMailer;
pub const SmtpTls = @import("config.zig").SmtpTls;

// Built-in plugins (for composition / overriding only one side of the pair).
pub const DefaultStoragePlugin = @import("framework.zig").DefaultStoragePlugin;
pub const DefaultMailerPlugin = @import("framework.zig").DefaultMailerPlugin;

// Migration: the `up` fn for an explicit migration receives a `*Db` writer; the
// `.migrations` config is a list of `Migration` entries.
pub const Db = @import("db.zig").Db;
pub const Migration = @import("provision.zig").Migration;

// Static files: the entry type of a build-generated embedded manifest (see
// build.zig embedStaticDir) and of `.static_files = .{ .embedded = ... }`.
pub const StaticFile = @import("static_files.zig").StaticFile;

// ---- Ctx capability object -------------------------------------------------
pub const Ctx = @import("ctx.zig").Ctx;

// ---- General outbound HTTP client -----------------------------------------
pub const HttpResponse = @import("http_client.zig").HttpResponse;

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
    _ = @import("http.zig");
    _ = @import("router.zig");
    _ = @import("request.zig");
    _ = @import("server.zig");
    _ = @import("schema.zig");
    _ = @import("collections.zig");
    _ = @import("records.zig");
    _ = @import("values.zig");
    _ = @import("ddl.zig");
    _ = @import("migrations.zig");
    _ = @import("rules.zig");
    _ = @import("crypto.zig");
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
    _ = @import("files/naming.zig");
    _ = @import("files/mime.zig");
    _ = @import("files/storage.zig");
    _ = @import("files/plan.zig");
    _ = @import("files/multipart.zig");
    _ = @import("data.zig");
    _ = @import("events.zig");
    _ = @import("sentry.zig");
    _ = @import("framework.zig");
    _ = @import("provision.zig");
    _ = @import("records_hooks_test.zig");
    _ = @import("schedule.zig");
    _ = @import("scheduler.zig");
    _ = @import("mail/mailer.zig");
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
    _ = @import("clock_test.zig");
    _ = @import("ctx.zig");
    _ = @import("http_client.zig");
}
