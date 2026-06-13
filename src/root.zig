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
pub const RecordEvent = events.RecordEvent;
pub const ErrorEvent = events.ErrorEvent;
pub const RouteEvent = events.RouteEvent;
pub const JobEvent = events.JobEvent; // cron/interval/reactive job + app.submit handlers

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

// ---- Test discovery --------------------------------------------------------
// The unit-test runner is rooted at THIS module. Reference every internal file
// so its `test {}` blocks are analyzed and run (matches pre-restructure behavior
// where main.zig's import graph reached them).
test {
    _ = @import("app.zig");
    _ = @import("config.zig");
    _ = @import("ratelimit.zig");
    _ = @import("cli.zig");
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
    _ = @import("query/expand.zig");
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
}
