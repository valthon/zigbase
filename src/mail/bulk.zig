//! Bulk / throttled personalized list sends (#154 round 2). One `sendBulk` call writes
//! ONE `_mail_batches` row (the templates live once there) plus one
//! `_mail_batch_recipients` row per DISTINCT recipient, and enqueues one durable
//! `"mail_batch_item"` job per distinct recipient with the tiny payload
//! `{"batch":"…","to":"…"}`. N jobs (not one driver job) buys per-recipient
//! retry/backoff, priority ordering, visibility-timeout crash recovery, and queue rate
//! throttling from the EXISTING engine with zero new machinery.
//!
//! IDEMPOTENCY (at-least-once queue): the recipient row's `status` is the dedup
//! record. The handler returns SUCCESS without sending whenever the row is not
//! `pending` (or the batch is `canceled`) — a redelivered/reclaimed job is a no-op.
//! The one unavoidable window: a crash between backend-accept and the `sent` row
//! update replays as ONE duplicate send (identical to the "mail" kind; documented).
//!
//! SUPPRESSION for list mail is ALWAYS ON here (not gated by `check_suppression`):
//! sending list mail past a suppression is a compliance violation, not a tuning knob.
//! A suppressed recipient is a REPORTED OUTCOME (row status `suppressed`), not a job
//! failure. Tenancy: the batch's `account` scopes both the verified-sender assertion
//! and the suppression check, exactly like `send()`.

const std = @import("std");
const RequestArena = @import("../request_arena.zig").RequestArena;
const db = @import("../db.zig");
const id_gen = @import("../id.zig");
const clock = @import("../clock.zig");
const queue_mod = @import("../queue/queue.zig");
const durable = @import("../queue/durable.zig");
const mail_send = @import("send.zig");
const mailer_mod = @import("mailer.zig");
const template = @import("template.zig");
const senders = @import("senders.zig");
const suppression = @import("suppression.zig");
const unsubscribe = @import("unsubscribe.zig");
const App = @import("../app.zig").App;
const Ctx = @import("../ctx.zig").Ctx;

/// The built-in durable job kind backing bulk delivery (registered in framework.zig).
pub const job_kind = "mail_batch_item";

/// One list recipient: the address plus its personalization vars (rendered into the
/// batch's subject/text/html templates at DELIVERY time — vars differ per recipient,
/// so render errors are a delivery-time outcome, not a submit-time one).
pub const BulkRecipient = struct { to: []const u8, vars: []const template.Var = &.{} };

/// A bulk send: template SOURCES (rendered per recipient) + the recipient list.
pub const BulkSend = struct {
    subject: []const u8,
    text: ?[]const u8 = null, // >=1 of text/html required (error.EmptyBody)
    html: ?[]const u8 = null,
    from: ?[]const u8 = null,
    reply_to: ?[]const u8 = null,
    recipients: []const BulkRecipient, // non-empty (error.NoRecipients)
    /// List name — recorded on the batch (unsubscribe audit scoping). "" is fine.
    list: []const u8 = "",
    /// MUST name a durable queue (error.BulkRequiresDurable) — memory jobs cannot
    /// survive restart, carry run_at, or be rate-throttled.
    queue: []const u8 = "default",
    /// Unix seconds; earliest delivery for EVERY item job (default: now).
    at: ?i64 = null,
    /// Sending-account override. `null` = the request's active account scope (the
    /// same withScope attribution as `send()`); "" = an explicit system send.
    account: ?[]const u8 = null,
};

/// Durable per-recipient send-report counters (from the report rows).
pub const BatchReport = struct {
    total: u32 = 0,
    pending: u32 = 0,
    sent: u32 = 0,
    suppressed: u32 = 0,
    invalid: u32 = 0,
    failed: u32 = 0,
    canceled: u32 = 0,
};

pub const BulkError = error{
    NoRecipients,
    UnknownQueue,
    BulkRequiresDurable,
    BatchNotFound,
};

/// Serialize `vars` as a flat JSON object (last duplicate key wins). Stored on the
/// recipient row; parsed back by the handler.
fn varsToJson(alloc: std.mem.Allocator, vars: []const template.Var) ![]const u8 {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(alloc);
    for (vars) |v| try obj.put(alloc, v.key, .{ .string = v.value });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = obj }, .{});
}

/// Parse a stored vars_json object back into template vars (arena-owned). String
/// values pass through; non-string values are re-serialized as their JSON text.
/// The parse itself is scratch: `parsed` is deinit'd before returning, so every key
/// and string value is DUPED onto `arena` first — the returned slice must own its
/// bytes, not point into the freed parse arena.
fn varsFromJson(arena: std.mem.Allocator, json_text: []const u8) ![]template.Var {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadVars;
    var out: std.ArrayList(template.Var) = .empty;
    var it = parsed.value.object.iterator();
    while (it.next()) |e| {
        const key = try arena.dupe(u8, e.key_ptr.*);
        const val: []const u8 = switch (e.value_ptr.*) {
            .string => |s| try arena.dupe(u8, s),
            else => try std.json.Stringify.valueAlloc(arena, e.value_ptr.*, .{}),
        };
        try out.append(arena, .{ .key = key, .value = val });
    }
    return out.toOwnedSlice(arena);
}

/// Submit a bulk send. Fail-fast validation happens HERE at the call site — a bad
/// recipient anywhere fails the whole call with NOTHING persisted. `w` is the writer
/// connection; `own_txn` is false when the caller already holds an open transaction
/// (ctx.tx's bound_conn) so we never nest BEGIN. Returns the batch id (duped on `arena`).
pub fn sendBulk(
    app: *App,
    arena: std.mem.Allocator,
    reg: *const queue_mod.Registry,
    w: *db.Db,
    own_txn: bool,
    b: BulkSend,
    account: []const u8,
) ![]const u8 {
    // 1. Validate everything up front (template SOURCES; rendered values are
    //    re-validated at delivery by mail_send.send — fail closed twice, cheap).
    if (b.recipients.len == 0) return error.NoRecipients;
    if (b.text == null and b.html == null) return error.EmptyBody;
    const q = reg.queueByName(b.queue) orelse return error.UnknownQueue;
    if (q.backend != .durable) return error.BulkRequiresDurable;
    try mailer_mod.rejectControlChars(b.subject);
    try mailer_mod.rejectControlChars(b.list);
    try mailer_mod.rejectControlChars(account);
    if (b.from) |f| try mail_send.validateAddress(f);
    if (b.reply_to) |rt| try mail_send.validateAddress(rt);
    for (b.recipients) |r| try mail_send.validateAddress(r.to);

    // 2. Verified-sender assertion ONCE at submit when enforcement is on and the
    //    batch is account-scoped (delivery re-checks via send() anyway).
    if (app.mail.require_verified_sender and account.len > 0) {
        const from = b.from orelse return error.SenderNotVerified;
        var rd = try app.pool.acquireReader();
        defer app.pool.releaseReader(&rd);
        try senders.assertVerified(arena, &rd, account, from);
    }

    const io = app.io;
    const run_at = b.at orelse clock.nowUnix(io);
    const batch_id_buf = id_gen.collectionId(io);
    const batch_id = try arena.dupe(u8, &batch_id_buf);

    // 3. One writer transaction: batch row + all recipient rows (duplicates collapse
    //    via ON CONFLICT DO NOTHING on the UNIQUE (batch,email)) + one durable job
    //    per DISTINCT recipient.
    if (own_txn) try w.begin();
    errdefer if (own_txn) w.rollback() catch {};
    {
        var st = try w.prepare(
            \\INSERT INTO "_mail_batches"
            \\ ("id","created","updated","account","list","queue","from_addr","reply_to","subject_tpl","text_tpl","html_tpl","total","status")
            \\ VALUES (?1,datetime('now'),datetime('now'),?2,?3,?4,?5,?6,?7,?8,?9,0,'active');
        );
        defer st.finalize();
        try st.bindText(1, batch_id);
        try st.bindText(2, account);
        try st.bindText(3, b.list);
        try st.bindText(4, b.queue);
        try st.bindText(5, b.from orelse "");
        try st.bindText(6, b.reply_to orelse "");
        try st.bindText(7, b.subject);
        try st.bindText(8, b.text orelse "");
        try st.bindText(9, b.html orelse "");
        _ = try st.step();
    }
    var total: i64 = 0;
    {
        var st = try w.prepare(
            \\INSERT INTO "_mail_batch_recipients" ("id","created","updated","batch","email","vars_json")
            \\ VALUES (?1,datetime('now'),datetime('now'),?2,?3,?4)
            \\ ON CONFLICT("batch","email") DO NOTHING
            \\ RETURNING "id";
        );
        defer st.finalize();
        for (b.recipients) |r| {
            const rid = id_gen.collectionId(io);
            st.reset();
            try st.bindText(1, &rid);
            try st.bindText(2, batch_id);
            try st.bindText(3, r.to);
            // bindText copies (SQLITE_TRANSIENT), so vars_json is pure scratch once
            // `step()` returns — free it every iteration rather than letting it ride
            // on the caller's arena for the whole batch.
            const vars_json = try varsToJson(arena, r.vars);
            defer arena.free(vars_json);
            try st.bindText(4, vars_json);
            if (try st.step()) {
                // Distinct recipient: enqueue exactly one item job. Small constant
                // payload — the template lives once on the batch row. `enqueue`'s
                // bindText also copies, so this is scratch too.
                total += 1;
                const payload = try std.json.Stringify.valueAlloc(arena, .{ .batch = batch_id, .to = r.to }, .{});
                defer arena.free(payload);
                _ = try durable.enqueue(w, io, q, job_kind, payload, run_at);
            }
        }
    }
    {
        var st = try w.prepare("UPDATE \"_mail_batches\" SET \"total\"=?2, \"updated\"=datetime('now') WHERE \"id\"=?1;");
        defer st.finalize();
        try st.bindText(1, batch_id);
        try st.bindInt(2, total);
        _ = try st.step();
    }
    if (own_txn) try w.commit();
    return batch_id;
}

/// Cancel every still-pending recipient of `batch_id`. The stray item jobs are NOT
/// hunted down in `_queue_jobs` (payload LIKE-matching is fragile) — the handler's
/// batch-canceled / row-status check makes them drain as instant no-op successes,
/// and a job claimed mid-cancel finishes or no-ops. Returns the number of recipient
/// rows transitioned pending→canceled (0 for an unknown/already-canceled batch —
/// idempotent). Wrap in a txn only when we own the connection.
pub fn cancelBatch(app: *App, w: *db.Db, own_txn: bool, batch_id: []const u8) !usize {
    _ = app;
    if (own_txn) try w.begin();
    errdefer if (own_txn) w.rollback() catch {};
    {
        var st = try w.prepare("UPDATE \"_mail_batches\" SET \"status\"='canceled', \"updated\"=datetime('now') WHERE \"id\"=?1 AND \"status\"='active';");
        defer st.finalize();
        try st.bindText(1, batch_id);
        _ = try st.step();
    }
    var st = try w.prepare(
        \\UPDATE "_mail_batch_recipients" SET "status"='canceled', "updated"=datetime('now')
        \\ WHERE "batch"=?1 AND "status"='pending';
    );
    defer st.finalize();
    try st.bindText(1, batch_id);
    _ = try st.step();
    // changes() counts trigger-touched rows too, so this COUNT is advisory-accurate
    // only on trigger-free tables (ours are); no-match is still reliably ==0.
    const n: usize = @intCast(@max(w.changesCount(), 0));
    if (own_txn) try w.commit();
    return n;
}

/// Read the durable send-report counters for `batch_id` (error.BatchNotFound when
/// the batch row does not exist).
pub fn batchStatus(app: *App, alloc: std.mem.Allocator, batch_id: []const u8) !BatchReport {
    _ = alloc;
    var rd = try app.pool.acquireReader();
    defer app.pool.releaseReader(&rd);
    var rep = BatchReport{};
    {
        var st = try rd.prepare("SELECT \"total\" FROM \"_mail_batches\" WHERE \"id\"=?1;");
        defer st.finalize();
        try st.bindText(1, batch_id);
        if (!try st.step()) return error.BatchNotFound;
        rep.total = @intCast(@max(st.columnInt(0), 0));
    }
    var st = try rd.prepare("SELECT \"status\", COUNT(*) FROM \"_mail_batch_recipients\" WHERE \"batch\"=?1 GROUP BY \"status\";");
    defer st.finalize();
    try st.bindText(1, batch_id);
    while (try st.step()) {
        const s = st.columnText(0);
        const c: u32 = @intCast(@max(st.columnInt(1), 0));
        if (std.mem.eql(u8, s, "pending")) rep.pending = c else if (std.mem.eql(u8, s, "sent")) rep.sent = c else if (std.mem.eql(u8, s, "suppressed")) rep.suppressed = c else if (std.mem.eql(u8, s, "invalid")) rep.invalid = c else if (std.mem.eql(u8, s, "failed")) rep.failed = c else if (std.mem.eql(u8, s, "canceled")) rep.canceled = c;
    }
    return rep;
}

const ItemPayload = struct { batch: []const u8, to: []const u8 };
const BatchRow = struct {
    account: []const u8,
    list: []const u8,
    queue: []const u8,
    from_addr: []const u8,
    reply_to: []const u8,
    subject_tpl: []const u8,
    text_tpl: []const u8,
    html_tpl: []const u8,
    status: []const u8,
};

fn markStatus(app: *App, rcpt_id: []const u8, status: []const u8, last_error: []const u8) !void {
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    var st = try w.prepare(
        \\UPDATE "_mail_batch_recipients"
        \\ SET "status"=?2, "last_error"=?3, "updated"=datetime('now'),
        \\     "sent_at"=CASE WHEN ?2='sent' THEN datetime('now') ELSE "sent_at" END
        \\ WHERE "id"=?1;
    );
    defer st.finalize();
    try st.bindText(1, rcpt_id);
    try st.bindText(2, status);
    try st.bindText(3, last_error);
    _ = try st.step();
}

/// The `"mail_batch_item"` durable job handler. IDEMPOTENT BY ROW STATUS (step 1) —
/// see the file doc comment. Registered beside the `"mail"` kind in framework.zig.
pub fn jobHandler(ctx: *Ctx, payload: []const u8) anyerror!void {
    const app = ctx.app;
    // Everything this handler allocates is pure internal scratch — nothing escapes
    // the function (it returns void). Route it through a private arena layered on
    // top of `ctx.arena.a` rather than `ctx.arena.a` directly: the handler must not
    // leak under ANY allocator (see RequestArena's doc comment — a raw GPA is a
    // valid, harsher execution), and freeing ~9 duped fields individually across
    // this function's many early-return branches would be pure duplication. One
    // `defer scratch.deinit()` reclaims all of it on every path, including under a
    // real per-request arena in production (layering an arena on an arena is fine).
    var scratch = std.heap.ArenaAllocator.init(ctx.arena.a);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const parsed = try std.json.parseFromSlice(ItemPayload, sa, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const p = parsed.value;

    // 1. Load recipient + batch. Anything already resolved → SUCCESS no-op (dedup).
    var rcpt_id: []const u8 = undefined;
    var rcpt_attempts: i64 = 0;
    var vars_json: []const u8 = undefined;
    var batch: BatchRow = undefined;
    {
        var rd = try app.pool.acquireReader();
        defer app.pool.releaseReader(&rd);
        var st = try rd.prepare("SELECT \"id\",\"status\",\"vars_json\",\"attempts\" FROM \"_mail_batch_recipients\" WHERE \"batch\"=?1 AND \"email\"=?2;");
        defer st.finalize();
        try st.bindText(1, p.batch);
        try st.bindText(2, p.to);
        if (!try st.step()) return; // row gone — nothing to deliver
        if (!std.mem.eql(u8, st.columnText(1), "pending")) return; // at-least-once dedup
        rcpt_id = try sa.dupe(u8, st.columnText(0));
        vars_json = try sa.dupe(u8, st.columnText(2));
        rcpt_attempts = st.columnInt(3);

        var bst = try rd.prepare(
            \\SELECT "account","list","queue","from_addr","reply_to","subject_tpl","text_tpl","html_tpl","status"
            \\ FROM "_mail_batches" WHERE "id"=?1;
        );
        defer bst.finalize();
        try bst.bindText(1, p.batch);
        if (!try bst.step()) return; // orphaned job — no-op
        batch = .{
            .account = try sa.dupe(u8, bst.columnText(0)),
            .list = try sa.dupe(u8, bst.columnText(1)),
            .queue = try sa.dupe(u8, bst.columnText(2)),
            .from_addr = try sa.dupe(u8, bst.columnText(3)),
            .reply_to = try sa.dupe(u8, bst.columnText(4)),
            .subject_tpl = try sa.dupe(u8, bst.columnText(5)),
            .text_tpl = try sa.dupe(u8, bst.columnText(6)),
            .html_tpl = try sa.dupe(u8, bst.columnText(7)),
            .status = try sa.dupe(u8, bst.columnText(8)),
        };
    }
    if (std.mem.eql(u8, batch.status, "canceled")) return; // canceled batches drain as no-ops

    // 2. Per-recipient render — HTML part escaped by default (renderHtml), subject/
    //    text via renderText. A render failure is hopeless across retries (same vars
    //    every time) → status 'invalid', job SUCCESS (never burn the queue on it).
    const vars = varsFromJson(sa, vars_json) catch {
        return markStatus(app, rcpt_id, "invalid", "BadVarsJson");
    };
    const subject = template.renderText(sa, batch.subject_tpl, vars, &.{}) catch |e| {
        return markStatus(app, rcpt_id, "invalid", @errorName(e));
    };
    const text: ?[]const u8 = if (batch.text_tpl.len > 0)
        template.renderText(sa, batch.text_tpl, vars, &.{}) catch |e| {
            return markStatus(app, rcpt_id, "invalid", @errorName(e));
        }
    else
        null;
    const html: ?[]const u8 = if (batch.html_tpl.len > 0)
        template.renderHtml(sa, batch.html_tpl, vars, &.{}) catch |e| {
            return markStatus(app, rcpt_id, "invalid", @errorName(e));
        }
    else
        null;

    // 3. Suppression — ALWAYS ON for list mail (see file doc comment). A suppressed
    //    recipient is a reported outcome, not a job failure.
    {
        var rd = try app.pool.acquireReader();
        defer app.pool.releaseReader(&rd);
        if (try suppression.isSuppressed(sa, &rd, batch.account, p.to, .list)) {
            return markStatus(app, rcpt_id, "suppressed", "");
        }
    }

    // 4. Deliver through the ONE send path — inherits verified-sender enforcement,
    //    the CRLF backstop on RENDERED values, and the CaptureMailer/testcapture seams.
    // RFC 8058 headers ride ONLY list mail, and only when the feature is configured.
    // Emitted even when batch.list == "" (the token just carries an empty list).
    const list_unsub: ?[]const u8 = if (app.mail.unsubscribe_base_url.len > 0)
        try unsubscribe.buildUrl(sa, app.mail.unsubscribe_base_url, app.jwt_secret, batch.account, batch.list, p.to)
    else
        null;
    const msg = mail_send.MailMessage{
        .to = p.to,
        .subject = subject,
        .text = text,
        .html = html,
        .reply_to = if (batch.reply_to.len > 0) batch.reply_to else null,
        .from = if (batch.from_addr.len > 0) batch.from_addr else null,
        .account = if (batch.account.len > 0) batch.account else null,
        .list_unsubscribe = list_unsub,
    };
    mail_send.send(app, sa, msg) catch |e| switch (e) {
        error.RecipientSuppressed => return markStatus(app, rcpt_id, "suppressed", @errorName(e)),
        // Validation outcomes are hopeless across retries (vars/templates won't change).
        error.InvalidAddress, error.HeaderInjection, error.EmptyBody, error.SenderNotVerified => {
            return markStatus(app, rcpt_id, "invalid", @errorName(e));
        },
        else => {
            // Backend failure → RETRYABLE. Mirror attempts onto the report row, mark
            // 'failed' on the terminal attempt (per the queue's RetryPolicy, read from
            // the registry by the batch's queue name — no JobHandler signature change),
            // and PROPAGATE so the queue applies its normal backoff/terminal policy.
            const policy = blk: {
                if (queue_mod.registryFromApp(app)) |reg| {
                    if (reg.queueByName(batch.queue)) |q| break :blk q.retry;
                }
                break :blk queue_mod.RetryPolicy{};
            };
            const new_attempts = rcpt_attempts + 1;
            const terminal = new_attempts >= policy.max_attempts;
            const w = app.pool.acquireWriter();
            defer app.pool.releaseWriter();
            var st = try w.prepare(
                \\UPDATE "_mail_batch_recipients"
                \\ SET "attempts"=?2, "last_error"=?3, "updated"=datetime('now'),
                \\     "status"=CASE WHEN ?4=1 THEN 'failed' ELSE "status" END
                \\ WHERE "id"=?1;
            );
            defer st.finalize();
            try st.bindText(1, rcpt_id);
            try st.bindInt(2, new_attempts);
            try st.bindText(3, @errorName(e));
            try st.bindInt(4, if (terminal) 1 else 0);
            _ = try st.step();
            return e;
        },
    };
    // 5. Success. (Crash between backend-accept and this update ⇒ one duplicate send
    //    on redelivery — standard at-least-once; documented.)
    try markStatus(app, rcpt_id, "sent", "");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const migrations = @import("../migrations.zig");
const capture = @import("capture.zig");

/// Shared test env: tmp-dir pool + migrations + App, mirroring send.zig's EnforceEnv.
const BulkEnv = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    pool: db.Pool,
    app: App,

    fn init(mail_cfg: @import("config.zig").Runtime) !*BulkEnv {
        const ga = std.testing.allocator;
        const env = try ga.create(BulkEnv);
        errdefer ga.destroy(env);
        env.tmp = std.testing.tmpDir(.{});
        errdefer env.tmp.cleanup();
        const dir_path = try env.tmp.dir.realPathFileAlloc(std.testing.io, ".", ga);
        defer ga.free(dir_path);
        env.db_path = try std.fmt.allocPrintSentinel(ga, "{s}/bulk.db", .{dir_path}, 0);
        errdefer ga.free(env.db_path);
        env.pool = try db.Pool.init(ga, std.testing.io, env.db_path);
        errdefer env.pool.deinit();
        {
            const w = env.pool.acquireWriter();
            defer env.pool.releaseWriter();
            try migrations.run(w);
        }
        env.app = App{ .allocator = ga, .io = std.testing.io, .pool = &env.pool, .mail = mail_cfg };
        return env;
    }
    fn deinit(env: *BulkEnv) void {
        const ga = std.testing.allocator;
        env.pool.deinit();
        ga.free(env.db_path);
        env.tmp.cleanup();
        ga.destroy(env);
    }

    /// Acquire the pool writer, run `sendBulk` owning its transaction, release. The
    /// pool writer mutex is NOT reentrant, so every writer touch in these tests is a
    /// scoped acquire/release (mirroring send.zig's tests).
    fn submit(env: *BulkEnv, arena: std.mem.Allocator, reg: *const queue_mod.Registry, b: BulkSend, account: []const u8) ![]const u8 {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        return sendBulk(&env.app, arena, reg, w, true, b, account);
    }

    fn cancel(env: *BulkEnv, batch_id: []const u8) !usize {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        return cancelBatch(&env.app, w, true, batch_id);
    }

    fn countTable(env: *BulkEnv, comptime table: []const u8) !i64 {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var st = try w.prepare("SELECT COUNT(*) FROM \"" ++ table ++ "\";");
        defer st.finalize();
        _ = try st.step();
        return st.columnInt(0);
    }

    fn countJobsOfKind(env: *BulkEnv, kind: []const u8) !i64 {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var st = try w.prepare("SELECT COUNT(*) FROM \"_queue_jobs\" WHERE \"kind\"=?1 AND \"status\"='pending';");
        defer st.finalize();
        try st.bindText(1, kind);
        _ = try st.step();
        return st.columnInt(0);
    }

    /// One recipient row's report fields, duped onto `arena`. Caller frees via `deinit`.
    const Row = struct {
        status: []const u8,
        last_error: []const u8,
        attempts: i64,
        sent_at: []const u8,

        fn deinit(self: Row, alloc: std.mem.Allocator) void {
            alloc.free(self.status);
            alloc.free(self.last_error);
            alloc.free(self.sent_at);
        }
    };
    fn row(env: *BulkEnv, arena: std.mem.Allocator, batch_id: []const u8, email: []const u8) !Row {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var st = try w.prepare("SELECT \"status\",\"last_error\",\"attempts\",\"sent_at\" FROM \"_mail_batch_recipients\" WHERE \"batch\"=?1 AND \"email\"=?2;");
        defer st.finalize();
        try st.bindText(1, batch_id);
        try st.bindText(2, email);
        try testing.expect(try st.step());
        return .{
            .status = try arena.dupe(u8, st.columnText(0)),
            .last_error = try arena.dupe(u8, st.columnText(1)),
            .attempts = st.columnInt(2),
            .sent_at = try arena.dupe(u8, st.columnText(3)),
        };
    }

    /// Assert every `_queue_jobs` row of `kind` has `status` (and that some exist).
    fn expectAllJobs(env: *BulkEnv, kind: []const u8, status: []const u8) !void {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var st = try w.prepare("SELECT \"status\" FROM \"_queue_jobs\" WHERE \"kind\"=?1;");
        defer st.finalize();
        try st.bindText(1, kind);
        var n: usize = 0;
        while (try st.step()) : (n += 1) try testing.expectEqualStrings(status, st.columnText(0));
        try testing.expect(n > 0);
    }
};

const test_registry = queue_mod.Registry{
    .queues = &.{
        .{ .name = "emails", .backend = .durable },
        .{ .name = "default" },
    },
    .jobs = &.{.{ .kind = job_kind, .handler = jobHandler }},
};

const test_worker = queue_mod.WorkerDef{ .name = "w1", .queues = &.{"emails"}, .concurrency = 5 };

/// Drive pollOnce until a cycle processes nothing (drains everything ready now).
fn drain(env: *BulkEnv, reg: *const queue_mod.Registry) !void {
    while (try durable.pollOnce(&env.app, reg, test_worker) != 0) {}
}

test "sendBulk validation fails fast and persists NOTHING" {
    const env = try BulkEnv.init(.{});
    defer env.deinit();
    env.app.queues = @ptrCast(&test_registry);
    // Every branch below errors before sendBulk allocates anything (validation is
    // fail-fast, ahead of the batch-id alloc) — plain testing.allocator, nothing to free.
    const arena = std.testing.allocator;

    const good = BulkRecipient{ .to = "good@x.io" };
    // A bad recipient ANYWHERE fails the whole call.
    try testing.expectError(error.InvalidAddress, BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{ good, .{ .to = "no-at-sign" } },
        .queue = "emails",
    }, ""));
    try testing.expectEqual(@as(i64, 0), try BulkEnv.countTable(env, "_mail_batches"));
    try testing.expectEqual(@as(i64, 0), try BulkEnv.countTable(env, "_mail_batch_recipients"));
    try testing.expectEqual(@as(i64, 0), try BulkEnv.countTable(env, "_queue_jobs"));

    try testing.expectError(error.NoRecipients, BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{},
        .queue = "emails",
    }, ""));
    try testing.expectError(error.EmptyBody, BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .recipients = &.{good},
        .queue = "emails",
    }, ""));
    try testing.expectError(error.BulkRequiresDurable, BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{good},
        .queue = "default", // memory queue
    }, ""));
    try testing.expectError(error.UnknownQueue, BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{good},
        .queue = "nope",
    }, ""));
    try testing.expectEqual(@as(i64, 0), try BulkEnv.countTable(env, "_mail_batches"));
}

test "sendBulk dedups byte-identical recipients (UNIQUE batch,email): total==2, 2 rows, 2 jobs" {
    const env = try BulkEnv.init(.{});
    defer env.deinit();
    env.app.queues = @ptrCast(&test_registry);
    const arena = std.testing.allocator;

    const batch_id = try BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{
            .{ .to = "a@x.io" },
            .{ .to = "b@x.io" },
            .{ .to = "a@x.io" }, // byte-identical duplicate collapses
        },
        .queue = "emails",
    }, "");
    defer arena.free(batch_id);

    try testing.expectEqual(@as(i64, 2), try BulkEnv.countTable(env, "_mail_batch_recipients"));
    try testing.expectEqual(@as(i64, 2), try BulkEnv.countJobsOfKind(env, job_kind));
    const rep = try batchStatus(&env.app, arena, batch_id);
    try testing.expectEqual(@as(u32, 2), rep.total);
    try testing.expectEqual(@as(u32, 2), rep.pending);
}

test "fan-out + personalization: pollOnce drains, per-recipient render, html-escape, sent rows, batchStatus" {
    const env = try BulkEnv.init(.{});
    defer env.deinit();
    var cap = capture.CaptureMailer.init(testing.allocator);
    defer cap.deinit();
    const m = cap.mailer();
    env.app.mailer = &m;
    env.app.queues = @ptrCast(&test_registry);
    const arena = std.testing.allocator;

    const batch_id = try BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi {{ name }}",
        .html = "<b>{{ name }}</b>",
        .recipients = &.{
            .{ .to = "a@x.io", .vars = &.{.{ .key = "name", .value = "Ann" }} },
            .{ .to = "b@x.io", .vars = &.{.{ .key = "name", .value = "<Bo>" }} },
        },
        .queue = "emails",
    }, "");
    defer arena.free(batch_id);

    try drain(env, &test_registry);

    try testing.expectEqual(@as(usize, 2), cap.count());
    try testing.expectEqual(@as(usize, 1), cap.countTo("a@x.io"));
    try testing.expectEqual(@as(usize, 1), cap.countTo("b@x.io"));
    for (cap.all()) |msg| {
        if (std.mem.eql(u8, msg.to, "a@x.io")) {
            try testing.expectEqualStrings("Hi Ann", msg.subject);
            try testing.expectEqualStrings("<b>Ann</b>", msg.html.?);
        } else {
            // The var containing markup is HTML-escaped by default in the html part…
            try testing.expectEqualStrings("<b>&lt;Bo&gt;</b>", msg.html.?);
            // …and NOT escaped in the (text-rendered) subject.
            try testing.expectEqualStrings("Hi <Bo>", msg.subject);
        }
    }

    const ra = try BulkEnv.row(env, arena, batch_id, "a@x.io");
    defer ra.deinit(arena);
    const rb = try BulkEnv.row(env, arena, batch_id, "b@x.io");
    defer rb.deinit(arena);
    try testing.expectEqualStrings("sent", ra.status);
    try testing.expectEqualStrings("sent", rb.status);
    try testing.expect(ra.sent_at.len > 0);
    try testing.expect(rb.sent_at.len > 0);

    const rep = try batchStatus(&env.app, arena, batch_id);
    try testing.expectEqual(@as(u32, 2), rep.total);
    try testing.expectEqual(@as(u32, 2), rep.sent);
    try testing.expectEqual(@as(u32, 0), rep.pending);
}

test "jobHandler wires the RFC 8058 List-Unsubscribe URL when configured (round-trips to the batch's account/list/recipient); unset -> null; transactional send() never carries it" {
    const env = try BulkEnv.init(.{ .unsubscribe_base_url = "https://app.example" });
    defer env.deinit();
    env.app.jwt_secret = "s";
    var cap = capture.CaptureMailer.init(testing.allocator);
    defer cap.deinit();
    const m = cap.mailer();
    env.app.mailer = &m;
    env.app.queues = @ptrCast(&test_registry);
    // Raw leak-detecting allocator: `unsubscribe.verify` now returns an owned `Parts`
    // (contract-2) freed via `parts.deinit`, and every submit/payload/send allocation
    // below is individually freed. Each `jobHandler` runs under its own
    // `RequestArena.forTest`.
    const arena = std.testing.allocator;

    const batch_id = try BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{.{ .to = "a@x.io" }},
        .queue = "emails",
        .list = "news",
    }, "acc1");
    defer arena.free(batch_id);
    const payload = try std.json.Stringify.valueAlloc(arena, .{ .batch = batch_id, .to = "a@x.io" }, .{});
    defer arena.free(payload);
    {
        var cx = Ctx{ .app = &env.app, .arena = RequestArena.forTest(std.testing.allocator), .rctx = .{} };
        defer cx.deinit();
        try jobHandler(&cx, payload);
    }

    const captured = cap.last() orelse return error.TestExpectedNonNull;
    const lu = captured.list_unsubscribe orelse return error.TestExpectedNonNull;
    try testing.expect(std.mem.startsWith(u8, lu, "https://app.example/api/mail/unsubscribe?t="));
    const marker = "?t=";
    const token = lu[std.mem.indexOf(u8, lu, marker).? + marker.len ..];
    var parts = unsubscribe.verify(arena, "s", token) orelse return error.TestExpectedNonNull;
    defer parts.deinit(arena);
    try testing.expectEqualStrings("acc1", parts.account);
    try testing.expectEqualStrings("news", parts.list);
    try testing.expectEqualStrings("a@x.io", parts.recipient);

    // Feature unset on the SAME app -> no header on a fresh batch.
    cap.clear();
    env.app.mail.unsubscribe_base_url = "";
    const batch_id2 = try BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{.{ .to = "b@x.io" }},
        .queue = "emails",
        .list = "news",
    }, "acc1");
    defer arena.free(batch_id2);
    const payload2 = try std.json.Stringify.valueAlloc(arena, .{ .batch = batch_id2, .to = "b@x.io" }, .{});
    defer arena.free(payload2);
    {
        var cx = Ctx{ .app = &env.app, .arena = RequestArena.forTest(std.testing.allocator), .rctx = .{} };
        defer cx.deinit();
        try jobHandler(&cx, payload2);
    }
    const captured2 = cap.last() orelse return error.TestExpectedNonNull;
    try testing.expect(captured2.list_unsubscribe == null);

    // Transactional send() never carries the header, even with the feature configured.
    cap.clear();
    env.app.mail.unsubscribe_base_url = "https://app.example";
    try mail_send.send(&env.app, arena, .{ .to = "c@x.io", .subject = "hi", .text = "body", .account = "acc1" });
    const captured3 = cap.last() orelse return error.TestExpectedNonNull;
    try testing.expect(captured3.list_unsubscribe == null);
}

test "jobHandler is idempotent by row status: same payload twice sends once" {
    const env = try BulkEnv.init(.{});
    defer env.deinit();
    var cap = capture.CaptureMailer.init(testing.allocator);
    defer cap.deinit();
    const m = cap.mailer();
    env.app.mailer = &m;
    env.app.queues = @ptrCast(&test_registry);
    const arena = std.testing.allocator;

    const batch_id = try BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{.{ .to = "a@x.io" }},
        .queue = "emails",
    }, "");
    defer arena.free(batch_id);
    const payload = try std.json.Stringify.valueAlloc(arena, .{ .batch = batch_id, .to = "a@x.io" }, .{});
    defer arena.free(payload);

    {
        var cx = Ctx{ .app = &env.app, .arena = RequestArena.forTest(arena), .rctx = .{} };
        defer cx.deinit();
        try jobHandler(&cx, payload);
    }
    {
        var cx = Ctx{ .app = &env.app, .arena = RequestArena.forTest(arena), .rctx = .{} };
        defer cx.deinit();
        try jobHandler(&cx, payload); // redelivery — must be a no-op
    }

    try testing.expectEqual(@as(usize, 1), cap.count());
    const r = try BulkEnv.row(env, arena, batch_id, "a@x.io");
    defer r.deinit(arena);
    try testing.expectEqualStrings("sent", r.status);
}

test "suppressed recipient is a REPORTED OUTCOME (row suppressed, job done, nothing sent to it)" {
    const env = try BulkEnv.init(.{});
    defer env.deinit();
    var cap = capture.CaptureMailer.init(testing.allocator);
    defer cap.deinit();
    const m = cap.mailer();
    env.app.mailer = &m;
    env.app.queues = @ptrCast(&test_registry);
    const arena = std.testing.allocator;

    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try suppression.upsert(env.app.io, testing.allocator, w, "", "blocked@x.io", suppression.reason_hard_bounce, "ses");
    }

    const batch_id = try BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{ .{ .to = "blocked@x.io" }, .{ .to = "ok@x.io" } },
        .queue = "emails",
    }, "");
    defer arena.free(batch_id);

    try drain(env, &test_registry);

    try testing.expectEqual(@as(usize, 0), cap.countTo("blocked@x.io"));
    try testing.expectEqual(@as(usize, 1), cap.countTo("ok@x.io"));
    const rblocked = try BulkEnv.row(env, arena, batch_id, "blocked@x.io");
    defer rblocked.deinit(arena);
    try testing.expectEqualStrings("suppressed", rblocked.status);
    const rok = try BulkEnv.row(env, arena, batch_id, "ok@x.io");
    defer rok.deinit(arena);
    try testing.expectEqualStrings("sent", rok.status);
    // A suppressed recipient is NOT a job failure — every item job is 'done'.
    try BulkEnv.expectAllJobs(env, job_kind, "done");
}

test "unsubscribe suppression blocks .list delivery but NOT a transactional send to the same address" {
    const env = try BulkEnv.init(.{ .check_suppression = true });
    defer env.deinit();
    var cap = capture.CaptureMailer.init(testing.allocator);
    defer cap.deinit();
    const m = cap.mailer();
    env.app.mailer = &m;
    env.app.queues = @ptrCast(&test_registry);
    const arena = std.testing.allocator;

    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try suppression.upsert(env.app.io, testing.allocator, w, "", "opted-out@x.io", suppression.reason_unsubscribe, "one_click:news");
    }

    const batch_id = try BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{.{ .to = "opted-out@x.io" }},
        .queue = "emails",
    }, "");
    defer arena.free(batch_id);

    try drain(env, &test_registry);

    // .list delivery honors the unsubscribe row: reported as 'suppressed', nothing captured.
    try testing.expectEqual(@as(usize, 0), cap.countTo("opted-out@x.io"));
    const row = try BulkEnv.row(env, arena, batch_id, "opted-out@x.io");
    defer row.deinit(arena);
    try testing.expectEqualStrings("suppressed", row.status);

    // A transactional send() to the SAME address (check_suppression on) is UNAFFECTED — a
    // newsletter opt-out must not silently swallow a password reset.
    try mail_send.send(&env.app, testing.allocator, .{ .to = "opted-out@x.io", .subject = "Reset", .text = "body" });
    try testing.expectEqual(@as(usize, 1), cap.countTo("opted-out@x.io"));
}

test "render error marks the row invalid and the job still SUCCEEDS (never retried)" {
    const env = try BulkEnv.init(.{});
    defer env.deinit();
    var cap = capture.CaptureMailer.init(testing.allocator);
    defer cap.deinit();
    const m = cap.mailer();
    env.app.mailer = &m;
    env.app.queues = @ptrCast(&test_registry);
    const arena = std.testing.allocator;

    const batch_id = try BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "{{ broken", // UnterminatedTag at render time
        .text = "body",
        .recipients = &.{.{ .to = "a@x.io" }},
        .queue = "emails",
    }, "");
    defer arena.free(batch_id);

    try drain(env, &test_registry);

    try testing.expectEqual(@as(usize, 0), cap.count());
    const r = try BulkEnv.row(env, arena, batch_id, "a@x.io");
    defer r.deinit(arena);
    try testing.expectEqualStrings("invalid", r.status);
    try testing.expectEqualStrings("UnterminatedTag", r.last_error);
    try BulkEnv.expectAllJobs(env, job_kind, "done");
}

/// A vtable mailer whose send always fails (backend error → the RETRYABLE path).
const FailMailer = struct {
    fn sendFail(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: mailer_mod.Email) anyerror!void {
        _ = ptr;
        _ = io;
        _ = alloc;
        _ = email;
        return error.Boom;
    }
    const vtable = mailer_mod.Mailer.VTable{ .send = sendFail };
    var instance: u8 = 0; // never dereferenced; a stable non-null ptr for the vtable
    fn mailer() mailer_mod.Mailer {
        return .{ .ptr = @ptrCast(&instance), .vtable = &vtable, .from = "fail@x.io" };
    }
};

test "backend error: attempts mirrored, error propagates, terminal attempt marks row failed" {
    const env = try BulkEnv.init(.{});
    defer env.deinit();
    const fm = FailMailer.mailer();
    env.app.mailer = &fm;
    report_log.log_sink = noopLogSink; // swallow the intentional terminal-failure .err log
    defer report_log.log_sink = null;
    const arena = std.testing.allocator;

    const reg = queue_mod.Registry{
        .queues = &.{.{ .name = "emails", .backend = .durable, .retry = .{ .max_attempts = 2, .base_ms = 0, .jitter = false } }},
        .jobs = &.{.{ .kind = job_kind, .handler = jobHandler }},
    };
    env.app.queues = @ptrCast(&reg);

    const batch_id = try BulkEnv.submit(env, arena, &reg, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{.{ .to = "a@x.io" }},
        .queue = "emails",
    }, "");
    defer arena.free(batch_id);

    // First poll: attempt 1 fails → row mirrors attempts=1, still pending; job retried (pending).
    _ = try durable.pollOnce(&env.app, &reg, test_worker);
    const r1 = try BulkEnv.row(env, arena, batch_id, "a@x.io");
    defer r1.deinit(arena);
    try testing.expectEqualStrings("pending", r1.status);
    try testing.expectEqual(@as(i64, 1), r1.attempts);
    try testing.expectEqualStrings("Boom", r1.last_error);
    try BulkEnv.expectAllJobs(env, job_kind, "pending");

    // Second poll: attempt 2 is terminal (max_attempts=2) → row failed, job failed.
    _ = try durable.pollOnce(&env.app, &reg, test_worker);
    const r2 = try BulkEnv.row(env, arena, batch_id, "a@x.io");
    defer r2.deinit(arena);
    try testing.expectEqualStrings("failed", r2.status);
    try testing.expectEqual(@as(i64, 2), r2.attempts);
    try BulkEnv.expectAllJobs(env, job_kind, "failed");
}

test "cancelBatch: pending rows -> canceled, stray jobs drain as no-ops, idempotent" {
    const env = try BulkEnv.init(.{});
    defer env.deinit();
    var cap = capture.CaptureMailer.init(testing.allocator);
    defer cap.deinit();
    const m = cap.mailer();
    env.app.mailer = &m;
    env.app.queues = @ptrCast(&test_registry);
    const arena = std.testing.allocator;

    const batch_id = try BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{ .{ .to = "a@x.io" }, .{ .to = "b@x.io" } },
        .queue = "emails",
    }, "");
    defer arena.free(batch_id);

    try testing.expectEqual(@as(usize, 2), try BulkEnv.cancel(env, batch_id));
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        var st = try w.prepare("SELECT \"status\" FROM \"_mail_batches\" WHERE \"id\"=?1;");
        defer st.finalize();
        try st.bindText(1, batch_id);
        _ = try st.step();
        try testing.expectEqualStrings("canceled", st.columnText(0));
    }
    const ra = try BulkEnv.row(env, arena, batch_id, "a@x.io");
    defer ra.deinit(arena);
    const rb = try BulkEnv.row(env, arena, batch_id, "b@x.io");
    defer rb.deinit(arena);
    try testing.expectEqualStrings("canceled", ra.status);
    try testing.expectEqualStrings("canceled", rb.status);

    // The still-queued item jobs drain as instant no-op SUCCESSES (nothing sent).
    try drain(env, &test_registry);
    try testing.expectEqual(@as(usize, 0), cap.count());
    try BulkEnv.expectAllJobs(env, job_kind, "done");

    // Idempotent: a second cancel transitions nothing.
    try testing.expectEqual(@as(usize, 0), try BulkEnv.cancel(env, batch_id));
    const rep = try batchStatus(&env.app, arena, batch_id);
    try testing.expectEqual(@as(u32, 2), rep.canceled);
}

test "tenancy: unverified sender rejected at submit (nothing persisted); verified passes; suppression is account-scoped" {
    const env = try BulkEnv.init(.{ .require_verified_sender = true });
    defer env.deinit();
    var cap = capture.CaptureMailer.init(testing.allocator);
    defer cap.deinit();
    const m = cap.mailer();
    env.app.mailer = &m;
    env.app.queues = @ptrCast(&test_registry);
    const arena = std.testing.allocator;

    // Unverified From for an account-scoped batch → rejected at submit; nothing persisted.
    try testing.expectError(error.SenderNotVerified, BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .from = "from@acct.com",
        .recipients = &.{.{ .to = "a@x.io" }},
        .queue = "emails",
    }, "acc1"));
    // A scoped batch with NO From is rejected too (would fall back to the global From).
    try testing.expectError(error.SenderNotVerified, BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .recipients = &.{.{ .to = "a@x.io" }},
        .queue = "emails",
    }, "acc1"));
    try testing.expectEqual(@as(i64, 0), try BulkEnv.countTable(env, "_mail_batches"));

    // Verify the identity for acc1, then the same submit succeeds.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        const req = try senders.requestVerification(env.app.io, testing.allocator, w, "acc1", "from@acct.com");
        defer testing.allocator.free(req.id);
        defer testing.allocator.free(req.token);
        defer testing.allocator.free(req.email);
        try testing.expect(try senders.confirm(testing.allocator, w, "acc1", req.id, req.token));
    }
    // A suppression scoped to a DIFFERENT account must not suppress acc1's recipient.
    {
        const w = env.pool.acquireWriter();
        defer env.pool.releaseWriter();
        try suppression.upsert(env.app.io, testing.allocator, w, "acc2", "shared@x.io", suppression.reason_hard_bounce, "ses");
    }

    const batch_id = try BulkEnv.submit(env, arena, &test_registry, .{
        .subject = "Hi",
        .text = "body",
        .from = "from@acct.com",
        .recipients = &.{.{ .to = "shared@x.io" }},
        .queue = "emails",
    }, "acc1");
    defer arena.free(batch_id);

    try drain(env, &test_registry);
    try testing.expectEqual(@as(usize, 1), cap.countTo("shared@x.io"));
    const r = try BulkEnv.row(env, arena, batch_id, "shared@x.io");
    defer r.deinit(arena);
    try testing.expectEqualStrings("sent", r.status);
}

const report_log = @import("../report/log.zig");
fn noopLogSink(_: []const u8) void {}
