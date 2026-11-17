//! PostgreSQL parity for mail suppression and bulk list sends.
//!
//! `mail/suppression.zig` and `mail/bulk.zig` sent SQLite `?N` placeholders and `datetime('now')`
//! to PostgreSQL unlowered, so on `-Dpostgres=true` the bounce/complaint webhook, the one-click
//! unsubscribe endpoint, send-time suppression enforcement and every bulk-send step (submit, the
//! `mail_batch_item` job handler, `batchStatus`, `cancelBatch`) failed at prepare.
//!
//! One scenario drives the real handlers and the bulk lifecycle through a `db.Pool` and asserts
//! exact outcomes. It runs against SQLite (the reference) and against a live PostgreSQL, so the two
//! backends must agree. The PostgreSQL arm uses a dedicated, per-run database (pool connections
//! cannot inherit a per-test `search_path`), dropped on teardown. Skips when `ZIGBASE_PG_TEST_URL`
//! is unset or unreachable, or when its role may not CREATE DATABASE.

const std = @import("std");
const db = @import("../../db.zig");
const migrations = @import("../../migrations.zig");
const http = @import("../../http.zig");
const RequestArena = @import("../../request_arena.zig").RequestArena;
const App = @import("../../app.zig").App;
const clock = @import("../../clock.zig");
const queue_mod = @import("../../queue/queue.zig");
const durable = @import("../../queue/durable.zig");
const report_log = @import("../../report/log.zig");
const mailer_mod = @import("../../mail/mailer.zig");
const capture = @import("../../mail/capture.zig");
const mail_send = @import("../../mail/send.zig");
const suppression = @import("../../mail/suppression.zig");
const inbound = @import("../../mail/inbound.zig");
const unsubscribe = @import("../../mail/unsubscribe.zig");
const bulk = @import("../../mail/bulk.zig");
const crypto = @import("../../crypto.zig");
const unsubscribe_api = @import("../../api/mail_unsubscribe.zig");

const testing = std.testing;
const secret = "pg-mail-parity-secret-0123456789ab";
const webhook_secret = "relay-secret";

const registry = queue_mod.Registry{
    .queues = &.{.{ .name = "emails", .backend = .durable }},
    .jobs = &.{.{ .kind = bulk.job_kind, .handler = bulk.jobHandler }},
};
/// Two attempts, no backoff: the second poll is the terminal one.
const failing_registry = queue_mod.Registry{
    .queues = &.{.{ .name = "emails", .backend = .durable, .retry = .{ .max_attempts = 2, .base_ms = 0, .jitter = false } }},
    .jobs = &.{.{ .kind = bulk.job_kind, .handler = bulk.jobHandler }},
};
const worker = queue_mod.WorkerDef{ .name = "w1", .queues = &.{"emails"}, .concurrency = 5 };

/// A mailer whose every send fails: the bulk handler's retryable backend-error path.
const FailMailer = struct {
    fn sendFail(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: mailer_mod.Email) anyerror!void {
        _ = ptr;
        _ = io;
        _ = alloc;
        _ = email;
        return error.Boom;
    }
    const vtable = mailer_mod.Mailer.VTable{ .send = sendFail };
    var instance: u8 = 0;
    fn mailer() mailer_mod.Mailer {
        return .{ .ptr = @ptrCast(&instance), .vtable = &vtable, .from = "fail@x.io" };
    }
};

fn noopLogSink(_: []const u8) void {}

/// POST a signed SES notification to `webhook_handler` for `account`; returns the status.
fn postWebhook(app: *App, account: []const u8, body: []const u8) !u16 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try std.fmt.allocPrint(a, "{d}", .{clock.nowUnix(testing.io)});
    const sig = try inbound.signMailInbound(a, webhook_secret, ts, "ses", account, body);
    const headers = [_]http.Param{
        .{ .key = inbound.sig_header, .value = sig },
        .{ .key = inbound.ts_header, .value = ts },
        .{ .key = inbound.account_header, .value = account },
    };
    var ctx = http.RequestCtx{
        .method = .POST,
        .path = "/api/mail/webhooks/ses",
        .allocator = RequestArena.from(&arena),
        .app = app,
        .body = body,
        .params = &.{.{ .key = "provider", .value = "ses" }},
        .headers = &headers,
    };
    return (try inbound.webhook_handler(&ctx)).status;
}

/// POST the one-click unsubscribe endpoint with a token for (account, list, recipient).
fn postUnsubscribe(app: *App, account: []const u8, list: []const u8, recipient: []const u8) !u16 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const token = try unsubscribe.mint(a, secret, account, list, recipient);
    const query = try std.fmt.allocPrint(a, "t={s}", .{token});
    var ctx = http.RequestCtx{ .method = .POST, .path = "/api/mail/unsubscribe", .query = query, .allocator = RequestArena.from(&arena), .app = app };
    return (try unsubscribe_api.post(&ctx)).status;
}

fn suppressed(pool: *db.Pool, account: []const u8, email: []const u8, kind: suppression.Kind) !bool {
    var r = try pool.acquireReader();
    defer pool.releaseReader(&r);
    return suppression.isSuppressed(testing.allocator, &r, account, email, kind);
}

/// Assert the `_suppressions` rows for `email`, each as "account|reason|source", ordered by
/// account. The addresses are test literals, so interpolating them keeps this probe independent of
/// the code under test; all scratch is on the stack.
fn expectSuppressionRows(pool: *db.Pool, email: []const u8, want: []const []const u8) !void {
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    var sql_buf: [256]u8 = undefined;
    const sql = try std.mem.printSentinel(&sql_buf, "SELECT \"account\",\"reason\",\"source\" FROM \"_suppressions\" WHERE \"email\"='{s}' ORDER BY \"account\";", .{email}, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    var n: usize = 0;
    while (try st.step()) : (n += 1) {
        try testing.expect(n < want.len);
        var row_buf: [128]u8 = undefined;
        const got = try std.fmt.bufPrint(&row_buf, "{s}|{s}|{s}", .{ st.columnText(0), st.columnText(1), st.columnText(2) });
        try testing.expectEqualStrings(want[n], got);
    }
    try testing.expectEqual(want.len, n);
}

const WantRow = struct { status: []const u8, last_error: []const u8 = "", attempts: i64 = 0, sent: bool = false };

/// Assert one recipient's report row. `batch` is a server-minted base36 id and `email` a test
/// literal. `sent` asserts `sent_at` is stamped (its text format differs per backend) or empty.
fn expectRecipient(pool: *db.Pool, batch: []const u8, email: []const u8, want: WantRow) !void {
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    var sql_buf: [256]u8 = undefined;
    const sql = try std.mem.printSentinel(&sql_buf, "SELECT \"status\",\"last_error\",\"attempts\",\"sent_at\" FROM \"_mail_batch_recipients\" WHERE \"batch\"='{s}' AND \"email\"='{s}';", .{ batch, email }, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try testing.expect(try st.step());
    try testing.expectEqualStrings(want.status, st.columnText(0));
    try testing.expectEqualStrings(want.last_error, st.columnText(1));
    try testing.expectEqual(want.attempts, st.columnInt(2));
    try testing.expectEqual(want.sent, st.columnText(3).len > 0);
}

fn expectBatchRowStatus(pool: *db.Pool, batch: []const u8, want: []const u8) !void {
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    var sql_buf: [128]u8 = undefined;
    const sql = try std.mem.printSentinel(&sql_buf, "SELECT \"status\" FROM \"_mail_batches\" WHERE \"id\"='{s}';", .{batch}, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try testing.expect(try st.step());
    try testing.expectEqualStrings(want, st.columnText(0));
}

fn pendingJobs(pool: *db.Pool) !i64 {
    const w = pool.acquireWriter();
    defer pool.releaseWriter();
    var st = try w.prepare("SELECT COUNT(*) FROM \"_queue_jobs\" WHERE \"kind\"='" ++ bulk.job_kind ++ "' AND \"status\"='pending';");
    defer st.finalize();
    try testing.expect(try st.step());
    return st.columnInt(0);
}

fn submit(app: *App, alloc: std.mem.Allocator, reg: *const queue_mod.Registry, b: bulk.BulkSend, account: []const u8) ![]const u8 {
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    return bulk.sendBulk(app, alloc, reg, w, true, b, account);
}

fn cancel(app: *App, batch: []const u8) !usize {
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    return bulk.cancelBatch(app, w, true, batch);
}

fn drain(app: *App, reg: *const queue_mod.Registry) !void {
    while (try durable.pollOnce(app, reg, worker) != 0) {}
}

fn expectReport(want: bulk.BatchReport, got: bulk.BatchReport) !void {
    try testing.expectEqualDeep(want, got);
}

/// The whole scenario. `pool` is a freshly migrated, empty database on either backend.
fn runScenario(pool: *db.Pool) !void {
    // Everything outside the two request arenas runs on the raw testing allocator, so a leak in
    // the suppression/send/bulk paths fails this test on either backend.
    const ga = testing.allocator;

    var cap = capture.CaptureMailer.init(testing.allocator);
    defer cap.deinit();
    const cap_mailer = cap.mailer();
    var app = App{
        .allocator = testing.allocator,
        .io = testing.io,
        .pool = pool,
        .jwt_secret = secret,
        .mailer = &cap_mailer,
        .mail = .{ .check_suppression = true, .webhook_secret = webhook_secret, .unsubscribe_base_url = "https://app.example" },
    };
    app.queues = @ptrCast(&registry);

    // ---- bounce/complaint webhook: insert, then upsert in place (one row per account+email) ----
    {
        const bounce =
            \\{"notificationType":"Bounce","bounce":{"bounceType":"Permanent","bouncedRecipients":[{"emailAddress":"Bad@X.io"}]}}
        ;
        try testing.expectEqual(@as(u16, 200), try postWebhook(&app, "acc1", bounce));
        try expectSuppressionRows(pool, "bad@x.io", &.{"acc1|hard_bounce|ses"});

        const complaint =
            \\{"notificationType":"Complaint","complaint":{"complainedRecipients":[{"emailAddress":"bad@x.io"}]}}
        ;
        try testing.expectEqual(@as(u16, 200), try postWebhook(&app, "acc1", complaint));
        try expectSuppressionRows(pool, "bad@x.io", &.{"acc1|complaint|ses"});

        // A global (account '') suppression is its own row and blocks every account.
        const global =
            \\{"notificationType":"Bounce","bounce":{"bounceType":"Permanent","bouncedRecipients":[{"emailAddress":"gone@x.io"}]}}
        ;
        try testing.expectEqual(@as(u16, 200), try postWebhook(&app, "", global));

        try testing.expect(try suppressed(pool, "acc1", "BAD@x.io", .transactional));
        try testing.expect(!try suppressed(pool, "acc2", "bad@x.io", .transactional));
        try testing.expect(try suppressed(pool, "acc2", "gone@x.io", .transactional));
        try testing.expect(!try suppressed(pool, "acc1", "fine@x.io", .list));
    }

    // ---- one-click unsubscribe: list mail only, idempotent ----
    {
        try testing.expectEqual(@as(u16, 204), try postUnsubscribe(&app, "acc1", "news", "u@x.io"));
        try testing.expectEqual(@as(u16, 204), try postUnsubscribe(&app, "acc1", "news", "u@x.io"));
        try expectSuppressionRows(pool, "u@x.io", &.{"acc1|unsubscribe|one_click:news"});
        try testing.expect(try suppressed(pool, "acc1", "u@x.io", .list));
        try testing.expect(!try suppressed(pool, "acc1", "u@x.io", .transactional));
    }

    // ---- send-time enforcement (check_suppression) ----
    {
        try testing.expectError(error.RecipientSuppressed, mail_send.send(&app, ga, .{ .to = "bad@x.io", .subject = "s", .text = "t", .account = "acc1" }));
        try testing.expectError(error.RecipientSuppressed, mail_send.send(&app, ga, .{ .to = "gone@x.io", .subject = "s", .text = "t", .account = "acc2" }));
        // An unsubscribe does not block transactional mail.
        try mail_send.send(&app, ga, .{ .to = "u@x.io", .subject = "reset", .text = "t", .account = "acc1" });
        try testing.expectEqual(@as(usize, 1), cap.count());
    }

    // ---- bulk: submit (dedup), drain (sent + suppressed), report ----
    {
        const batch = try submit(&app, ga, &registry, .{
            .subject = "Hi {{ name }}",
            .text = "Hello {{ name }}",
            .list = "news",
            .queue = "emails",
            .recipients = &.{
                .{ .to = "a@x.io", .vars = &.{.{ .key = "name", .value = "Ann" }} },
                .{ .to = "b@x.io", .vars = &.{.{ .key = "name", .value = "Bo" }} },
                .{ .to = "a@x.io", .vars = &.{.{ .key = "name", .value = "Dup" }} },
                .{ .to = "u@x.io", .vars = &.{.{ .key = "name", .value = "Unsub" }} },
            },
        }, "acc1");
        defer ga.free(batch);
        try expectReport(.{ .total = 3, .pending = 3 }, try bulk.batchStatus(&app, ga, batch));
        try testing.expectEqual(@as(i64, 3), try pendingJobs(pool));

        try drain(&app, &registry);
        try expectReport(.{ .total = 3, .sent = 2, .suppressed = 1 }, try bulk.batchStatus(&app, ga, batch));
        try testing.expectEqual(@as(usize, 3), cap.count()); // the reset above + a + b
        try testing.expectEqual(@as(usize, 1), cap.countTo("a@x.io"));
        try testing.expectEqual(@as(usize, 1), cap.countTo("b@x.io"));
        for (cap.all()) |msg| {
            if (std.mem.eql(u8, msg.to, "a@x.io")) try testing.expectEqualStrings("Hi Ann", msg.subject);
        }
        try expectRecipient(pool, batch, "a@x.io", .{ .status = "sent", .sent = true });
        try expectRecipient(pool, batch, "b@x.io", .{ .status = "sent", .sent = true });
        try expectRecipient(pool, batch, "u@x.io", .{ .status = "suppressed" });

        // Redelivery is a no-op: a second drain finds nothing pending.
        try testing.expectEqual(@as(i64, 0), try pendingJobs(pool));
        try testing.expectError(error.BatchNotFound, bulk.batchStatus(&app, ga, "nope"));
    }

    // ---- bulk: cancel before delivery, stray jobs drain as no-ops, idempotent ----
    {
        const batch = try submit(&app, ga, &registry, .{
            .subject = "Later",
            .text = "body",
            .queue = "emails",
            .recipients = &.{ .{ .to = "c@x.io" }, .{ .to = "d@x.io" } },
        }, "acc1");
        defer ga.free(batch);
        try testing.expectEqual(@as(usize, 2), try cancel(&app, batch));
        try expectBatchRowStatus(pool, batch, "canceled");
        try expectRecipient(pool, batch, "c@x.io", .{ .status = "canceled" });
        try drain(&app, &registry);
        try testing.expectEqual(@as(usize, 3), cap.count());
        try testing.expectEqual(@as(usize, 0), try cancel(&app, batch));
        try expectReport(.{ .total = 2, .canceled = 2 }, try bulk.batchStatus(&app, ga, batch));
    }

    // ---- bulk: backend failure mirrors attempts, terminal attempt marks the row failed ----
    {
        const fail_mailer = FailMailer.mailer();
        app.mailer = &fail_mailer;
        app.queues = @ptrCast(&failing_registry);
        report_log.log_sink = noopLogSink; // the terminal failure logs at .err by design
        defer report_log.log_sink = null;

        const batch = try submit(&app, ga, &failing_registry, .{
            .subject = "Hi",
            .text = "body",
            .queue = "emails",
            .recipients = &.{.{ .to = "e@x.io" }},
        }, "");
        defer ga.free(batch);
        _ = try durable.pollOnce(&app, &failing_registry, worker);
        try expectRecipient(pool, batch, "e@x.io", .{ .status = "pending", .last_error = "Boom", .attempts = 1 });

        _ = try durable.pollOnce(&app, &failing_registry, worker);
        try expectRecipient(pool, batch, "e@x.io", .{ .status = "failed", .last_error = "Boom", .attempts = 2 });
        try expectReport(.{ .total = 1, .failed = 1 }, try bulk.batchStatus(&app, ga, batch));
    }
}

test "mail suppression + bulk: SQLite reference run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/mail.db", .{dir}, 0);
    defer testing.allocator.free(path);
    var pool = try db.Pool.init(testing.allocator, testing.io, path);
    defer pool.deinit();
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
    }
    try runScenario(&pool);
}

/// `url` with its database path segment replaced by `name` (query string kept).
fn withDatabase(a: std.mem.Allocator, url: []const u8, name: []const u8) ![:0]u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const slash = std.mem.lastIndexOfScalar(u8, url[0..q], '/') orelse return error.BadTestUrl;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}{s}", .{ url[0..slash], name, url[q..] }, 0);
}

/// Whether the connected role may run CREATE DATABASE (a superuser or CREATEDB role).
fn canCreateDatabase(conn: *db.Db) !bool {
    var st = try conn.prepare("SELECT 1 FROM pg_roles WHERE rolname = current_user AND (rolsuper OR rolcreatedb);");
    defer st.finalize();
    return st.step();
}

test "mail suppression + bulk: PostgreSQL matches SQLite" {
    const url = testing.environ.getPosix("ZIGBASE_PG_TEST_URL") orelse return error.SkipZigTest;
    var admin = db.Db.openPostgres(testing.allocator, testing.io, url) catch return error.SkipZigTest;
    defer admin.close();
    if (!try canCreateDatabase(&admin)) return error.SkipZigTest;

    // A per-run name, so concurrent runs against one server never drop each other's database.
    const suffix = try crypto.genHex(testing.io, testing.allocator, 12);
    defer testing.allocator.free(suffix);
    const name = try std.fmt.allocPrint(testing.allocator, "zb_pgmail_{s}", .{suffix});
    defer testing.allocator.free(name);
    const create = try std.fmt.allocPrintSentinel(testing.allocator, "CREATE DATABASE {s};", .{name}, 0);
    defer testing.allocator.free(create);
    const drop = try std.fmt.allocPrintSentinel(testing.allocator, "DROP DATABASE IF EXISTS {s} WITH (FORCE);", .{name}, 0);
    defer testing.allocator.free(drop);

    try admin.exec(create);
    defer admin.exec(drop) catch |err| std.log.err("pg mail cleanup failed: {s}", .{@errorName(err)});

    const target = try withDatabase(testing.allocator, url, name);
    defer testing.allocator.free(target);
    var pool = try db.Pool.init(testing.allocator, testing.io, target);
    defer pool.deinit();
    try testing.expectEqual(db.Backend.postgres, db.poolBackend(&pool));
    {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        try migrations.run(w);
    }
    try runScenario(&pool);
}
