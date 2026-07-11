//! ZigBase "plugins" example — the ADVANCED framework surface.
//!
//! Where examples/blog is a bare packaging proof and examples/golfsim builds a
//! realistic app on top of ZigBase, THIS example exercises the comptime-config
//! surface a framework integrator reaches for — using ONLY the public
//! `zigbase.*` exports (no reaching into ZigBase internals):
//!
//!   1. A CUSTOM STORAGE PLUGIN (`AuditStorage`) wrapping `zigbase.LocalStorage`.
//!      Implements the plugin contract `create(gpa, io, cfg) !Self` /
//!      `interface(*Self) zigbase.Storage` / `deinit(*Self) void`, returning a
//!      `zigbase.Storage` vtable whose four methods LOG each operation before
//!      delegating to the inner `LocalStorage` backend. Registered via
//!      `App(.{ .storage = AuditStorage })`.
//!
//!   2. A CUSTOM MAILER PLUGIN (`AuditMailer`) implementing the same plugin
//!      contract for `zigbase.Mailer` / `zigbase.Email`. Logs + counts every
//!      outbound email. Registered via `App(.{ .mailer = AuditMailer })`.
//!
//!   3. COMPTIME SCHEMA via `.collections` -- FOUR related collections:
//!      `authors` (auth: webauthn + api_token), `commenters` (auth: magic_link),
//!      `posts` (relation -> authors), and `comments` (relation -> posts +
//!      commenters). Access rules are applied per-collection.
//!
//!   4. EXPLICIT MIGRATIONS via `.migrations` -- two `zigbase.Migration` entries:
//!      - `0001_create_audit_log`: creates a side table via `w.exec`.
//!      - `0002_index_audit_note`: multi-statement migration -- creates an index
//!        on the migration-owned `plugin_audit_log` table AND seeds a metadata
//!        row (DDL + DML in one transaction). Targets a migration-owned table to
//!        demonstrate the escape-hatch pattern; for comptime-managed collections
//!        use `.indexes` in the collection spec (see `authors`).
//!
//!   5. `onError` HANDLER -- `.onError = handleError`, receiving a
//!      `*zigbase.ErrorEvent` whose `.phase` field identifies where the error
//!      originated (.request / .cron / .job / .file_serve ...).
//!
//!   6. CRON JOB -- a `* * * * *` (every-minute) job that reads the DB via
//!      `ctx.records()` to count published posts, then writes an audit log row to a
//!      migration-owned table with raw SQL on the pooled writer (`ctx.app.pool`).
//!
//!   7. POOL LEVERS via `.pools` -- reader/job pool sizes + page-cache budget.
//!
//!   8. FULLY EMBEDDED STATIC FRONTEND via `embedStaticDir` -- the Astro build
//!      output in `frontend/dist` is compiled into the binary at build time;
//!      there is no runtime dependency on the frontend directory.
//!
//!   9. `onAuth` HOOK -- logs collection + method for every successful session
//!      mint. With two auth collections and three methods in use, log lines show:
//!      `[onAuth] collection=authors method=webauthn`, `method=custom` (api_token),
//!      and `collection=commenters method=magic_link`.
//!
//!  10. CUSTOM `AuthMethod` PLUGIN (`ApiTokenMethod`) via `.auth = .{ .methods = ... }`.
//!      Demonstrates the auth-method plugin contract alongside storage + mailer.
//!      Enabled on `authors` via `.auth.methods.custom = .{"api_token"}`.
//!
//!  11. COMPTIME `.indexes` with `.collation = .nocase` on `authors.contact_email`.
//!      Demonstrates the correct tool for indexing comptime-managed collections
//!      (field columns are human-named, not id-named -- see migration 0002 comment).
//!
//!  12. TIER-2 SPA FALLBACK ROUTING via `.static_routes` (issue #183): a `/app/**`
//!      catch-all serves the embedded frontend shell for any static miss below
//!      `/app/`. The serve target is validated against the embedded manifest AT
//!      COMPTIME. Declaring routes flips the Tier-1 `.spa` marker default OFF.

const std = @import("std");
const zigbase = @import("zigbase");

// ---------------------------------------------------------------------------
// 1. Custom storage plugin.
//
//    The plugin contract (mirrors the built-in DefaultStoragePlugin):
//      - create(gpa, io, cfg) !Self       -- construct from runtime config.
//      - interface(*Self) zigbase.Storage -- hand back the vtable the app calls.
//      - deinit(*Self) void               -- release anything `create` allocated.
//
//    `AuditStorage` wraps a `zigbase.LocalStorage` backend (rooted at
//    `<cfg.data_dir>/storage`), intercepting every vtable call to emit a
//    structured log line BEFORE delegating to the inner backend.
//
//    The `zigbase.Storage.VTable` has exactly four function pointers:
//      put(ctx, io, col, record_id, filename, bytes) anyerror!void
//      fetch(ctx, io, alloc, col, record_id, filename) anyerror!?[]const u8
//      delete(ctx, io, col, record_id, filename) anyerror!void
//      deleteRecord(ctx, io, col, record_id) anyerror!void
// ---------------------------------------------------------------------------
const AuditStorage = struct {
    local: zigbase.LocalStorage,
    inner: zigbase.Storage,
    gpa: std.mem.Allocator,
    root: []const u8,
    puts: usize = 0,
    deletes: usize = 0,
    delete_records: usize = 0,
    fetches: usize = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !AuditStorage {
        _ = io;
        const root = try std.fmt.allocPrint(gpa, "{s}/storage", .{cfg.data_dir});
        var local = zigbase.LocalStorage.init(root);
        const inner = local.storage();
        return .{ .gpa = gpa, .root = root, .local = local, .inner = inner };
    }

    /// Called by the framework to obtain the `zigbase.Storage` vtable used at
    /// runtime. Re-obtain `inner` from `self.local` so `inner.ctx` points into
    /// THIS struct (not a now-gone stack frame from `create`).
    pub fn interface(self: *AuditStorage) zigbase.Storage {
        self.inner = self.local.storage();
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn deinit(self: *AuditStorage) void {
        self.gpa.free(self.root);
    }

    const vtable = zigbase.Storage.VTable{
        .put = auditPut,
        .fetch = auditFetch,
        .delete = auditDelete,
        .deleteRecord = auditDeleteRecord,
    };

    fn auditPut(
        ctx: *anyopaque,
        io: std.Io,
        col: []const u8,
        record_id: []const u8,
        filename: []const u8,
        bytes: []const u8,
    ) anyerror!void {
        const self: *AuditStorage = @ptrCast(@alignCast(ctx));
        self.puts += 1;
        std.log.info("[audit-storage] put  col={s} id={s} file={s} bytes={d}", .{
            col, record_id, filename, bytes.len,
        });
        return self.inner.vtable.put(self.inner.ctx, io, col, record_id, filename, bytes);
    }

    fn auditFetch(
        ctx: *anyopaque,
        io: std.Io,
        alloc: std.mem.Allocator,
        col: []const u8,
        record_id: []const u8,
        filename: []const u8,
    ) anyerror!?[]const u8 {
        const self: *AuditStorage = @ptrCast(@alignCast(ctx));
        self.fetches += 1;
        std.log.debug("[audit-storage] fetch col={s} id={s} file={s}", .{ col, record_id, filename });
        return self.inner.vtable.fetch(self.inner.ctx, io, alloc, col, record_id, filename);
    }

    fn auditDelete(
        ctx: *anyopaque,
        io: std.Io,
        col: []const u8,
        record_id: []const u8,
        filename: []const u8,
    ) anyerror!void {
        const self: *AuditStorage = @ptrCast(@alignCast(ctx));
        self.deletes += 1;
        std.log.info("[audit-storage] delete col={s} id={s} file={s}", .{
            col, record_id, filename,
        });
        return self.inner.vtable.delete(self.inner.ctx, io, col, record_id, filename);
    }

    fn auditDeleteRecord(
        ctx: *anyopaque,
        io: std.Io,
        col: []const u8,
        record_id: []const u8,
    ) anyerror!void {
        const self: *AuditStorage = @ptrCast(@alignCast(ctx));
        self.delete_records += 1;
        std.log.info("[audit-storage] deleteRecord col={s} id={s}", .{ col, record_id });
        return self.inner.vtable.deleteRecord(self.inner.ctx, io, col, record_id);
    }
};

// ---------------------------------------------------------------------------
// 2. Custom mailer plugin.
//
//    `AuditMailer` logs every outbound `zigbase.Email` (to / subject) and
//    counts sends. Demonstrates compiling against the public
//    `zigbase.Mailer` / `zigbase.Email` vtable types.
// ---------------------------------------------------------------------------
const AuditMailer = struct {
    sent: usize = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !AuditMailer {
        _ = gpa;
        _ = io;
        _ = cfg;
        return .{};
    }

    pub fn interface(self: *AuditMailer) zigbase.Mailer {
        return .{ .ptr = self, .vtable = &mailer_vtable };
    }

    pub fn deinit(self: *AuditMailer) void {
        _ = self;
    }

    const mailer_vtable = zigbase.Mailer.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: zigbase.Email) anyerror!void {
        _ = io;
        _ = alloc;
        const self: *AuditMailer = @ptrCast(@alignCast(ptr));
        self.sent += 1;
        std.log.info("[audit-mail #{d}] to={s} subject={s}", .{ self.sent, email.to, email.subject });
    }
};

// ---------------------------------------------------------------------------
// 10. Custom AuthMethod plugin: "api_token"
//
// Demonstrates the zigbase.AuthMethod plugin contract. An author authenticates
// by sending their API token (a shared secret stored in the record's `bio` field
// for simplicity -- a real app would use a dedicated hashed-token field) in the
// request body as `{ "identity": "<email>", "token": "..." }`.
//
// Plugin contract (mirrors AuditStorage / AuditMailer):
//   create(gpa, io, cfg) !Self       -- construct; gpa/cfg available if needed.
//   method(*Self) zigbase.AuthMethod -- return the vtable the auth dispatch calls.
//   deinit(*Self) void               -- release any resources.
//
// The framework validates this contract at comptime via assertAuthMethodContract.
// Registered app-level via `.auth = .{ .methods = .{ApiTokenMethod} }` and enabled on
// the `authors` collection via `.auth.methods.custom = .{"api_token"}`.
//
// AuthCtx helpers used here (all via public zigbase.AuthCtx):
//   ac.findByIdentity(conn, identity)  -- looks up record_id by the auth identity.
//   ac.rateLimit(scope, ident)         -- returns ?Response; non-null means limited.
//   ac.reader()                        -- RAII read-only connection handle.
//
// Resolution variants:
//   .record = id_string              -- framework mints session + fires onAuth(.custom).
//   .fail = { .status, .message }    -- framework returns the status code + body.
// ---------------------------------------------------------------------------
// Typed I/O for the custom method (issue #119). Declaring these comptime structs
// in the `.auth.methods.custom` struct form (below) lets `zig build gen-client`
// reflect them into precise TS interfaces named by the Zig type — instead of the
// untyped `Record<string, unknown>` stub. Initiate takes no input (void); complete
// exchanges an identity+token for a session.
const ApiTokenInitiateOutput = struct { flow: []const u8 };
const ApiTokenCompleteInput = struct { identity: []const u8, token: []const u8 };
const ApiTokenCompleteOutput = struct { token: []const u8 };

const ApiTokenMethod = struct {
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        cfg: zigbase.Config,
    ) !ApiTokenMethod {
        _ = gpa;
        _ = io;
        _ = cfg;
        return .{};
    }

    pub fn method(self: *ApiTokenMethod) zigbase.AuthMethod {
        return .{
            .slug = "api_token",
            .ctx = self,
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *ApiTokenMethod) void {
        _ = self;
    }

    const vtable = zigbase.AuthMethod.VTable{
        .initiate = initiate,
        .complete = complete,
    };

    // initiate: called by POST /api/collections/authors/auth/api_token/initiate.
    // For a simple token-exchange method, initiate is a no-op (everything in complete).
    fn initiate(ctx: *anyopaque, ac: *zigbase.AuthCtx) anyerror!zigbase.InitiateResult {
        _ = ctx;
        _ = ac;
        return .{ .status = 200, .body = "{\"flow\":\"direct\"}" };
    }

    // complete: called by POST /api/collections/authors/auth/api_token/complete.
    // Expects JSON body: { "identity": "<email>", "token": "<api_token>" }
    // The "token" is compared to the record's `bio` field (demo simplification:
    // in a real app use a dedicated hashed-token field, not a human-visible text field).
    fn complete(ctx: *anyopaque, ac: *zigbase.AuthCtx) anyerror!zigbase.Resolution {
        _ = ctx;

        // Rate-limit by IP before any DB access.
        if (try ac.rateLimit("api_token", "ip")) |_| {
            return .{ .fail = .{ .status = 429, .message = "rate limited" } };
        }

        // ac.ctx is *http.RequestCtx; .body is a []const u8 field (empty string = no body).
        const body = ac.ctx.body;
        if (body.len == 0) return .{ .fail = .{ .status = 400, .message = "missing body" } };

        const parsed = std.json.parseFromSlice(
            ApiTokenCompleteInput,
            ac.ctx.allocator,
            body,
            .{},
        ) catch return .{ .fail = .{ .status = 400, .message = "invalid JSON" } };
        defer parsed.deinit();

        // Look up the record by identity (system email field).
        var r = try ac.reader();
        defer r.deinit();
        const record_id = try ac.findByIdentity(&r.conn, parsed.value.identity) orelse
            return .{ .fail = .{ .status = 401, .message = "unknown identity" } };

        // Fetch the record to verify the token against `bio` (demo: bio IS the token).
        const rec = try r.data().findById("authors", record_id) orelse
            return .{ .fail = .{ .status = 401, .message = "record not found" } };
        const stored_token = switch (rec.object.get("bio") orelse .null) {
            .string => |s| s,
            else => "",
        };
        // Guard against empty tokens: an author with no bio would match any empty client token.
        if (parsed.value.token.len == 0 or stored_token.len == 0) {
            return .{ .fail = .{ .status = 401, .message = "invalid token" } };
        }
        // Note: this compare is not constant-time; acceptable for a demo.
        if (!std.mem.eql(u8, stored_token, parsed.value.token)) {
            return .{ .fail = .{ .status = 401, .message = "invalid token" } };
        }

        std.log.info("[api_token] authenticated author id={s}", .{record_id});
        return .{ .record = record_id };
    }
};

// ---------------------------------------------------------------------------
// 5. onError handler.
// ---------------------------------------------------------------------------
fn handleError(ev: *zigbase.ErrorEvent) void {
    const phase_name = switch (ev.phase) {
        .request => "request",
        .before_hook => "before_hook",
        .after_hook => "after_hook",
        .cron => "cron",
        .job => "job",
        .file_serve => "file_serve",
        .webhook => "webhook",
        .app => "app",
    };
    std.log.err("[onError] phase={s} err={s} msg={s}", .{
        phase_name, @errorName(ev.err), ev.message,
    });
}

// ---------------------------------------------------------------------------
// 9. onAuth hook -- fires after every successful session mint across all collections.
//
// This binary issues sessions for TWO collections via THREE distinct methods:
//   authors    -> webauthn (passkey)
//   authors    -> custom / api_token (programmatic)
//   commenters -> magic_link (emailed link)
//
// `ev.method` is a `zigbase.events.AuthMethod` enum (password/oauth2/magic_link/
// otp/webauthn/custom/refresh). `ev.record` is ?std.json.Value -- null only for
// OAuth2 provider-unknown paths. Extract the record id via `.object.get("id")`.
// ---------------------------------------------------------------------------
fn handleAuth(ev: *zigbase.AuthEvent) void {
    const method_name = switch (ev.method) {
        .password => "password",
        .oauth2 => "oauth2",
        .magic_link => "magic_link",
        .otp => "otp",
        .webauthn => "webauthn",
        .custom => "custom",
        .refresh => "refresh",
    };
    const record_id = if (ev.record) |r|
        if (r.object.get("id")) |v| switch (v) {
            .string => |s| s,
            else => "(non-string id)",
        } else "(no id field)"
    else
        "(unknown)";
    std.log.info("[onAuth] collection={s} method={s} record={s}", .{
        ev.collection, method_name, record_id,
    });
}

// ---------------------------------------------------------------------------
// beforeCreate hook for comments -- auto-populate `commenter` from session.
//
//    The create rule (@request.auth.id != "") already gated access, so ev.rctx
//    is guaranteed to carry a valid auth identity at this point. We populate
//    `commenter` from the session so the frontend does not need to pass it
//    explicitly (and so the relation is always authoritative).
//
//    ev.rctx is *const request.RequestContext which carries:
//      .auth: ?std.json.Value  -- the authenticated record object
//    There is no direct `auth_id` shortcut; extract it from the JSON object.
//    Allocate with ev.arena (the request-scoped allocator that owns ev.record's
//    JSON storage) -- need the app itself? Use ctx.app.
// ---------------------------------------------------------------------------
fn beforeCreateComment(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void {
    _ = ctx;
    // Populate `commenter` from the session identity if not provided by the client.
    if (ev.record.object.get("commenter") == null) {
        const auth = ev.rctx.auth orelse return; // should never be null (rule gated)
        const auth_id = switch (auth.object.get("id") orelse .null) {
            .string => |s| s,
            else => return, // malformed auth object -- skip silently
        };
        try ev.record.object.put(ev.arena, "commenter", .{ .string = auth_id });
    }
}

// ---------------------------------------------------------------------------
// 6. Cron / interval job: "audit-sweep".
//
//    Fires every minute (cron "* * * * *", UTC, numeric 5-field format).
//    Signature: fn(*zigbase.Ctx, *zigbase.events.JobEvent) anyerror!void.
//    Demonstrates the DB-access pattern for ctx-first job handlers:
//      - collection reads use ctx.records() -- the pooled reader is managed for you.
//      - raw SQL on a migration-owned table uses the pooled writer via ctx.app.pool
//        (acquireWriter / releaseWriter), since it is not a comptime collection.
// ---------------------------------------------------------------------------
fn auditSweepJob(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void {
    _ = ev;
    // Complex read via raw SQL, comptime-checked against the schema (#281). `zigbase.checkedSql`
    // validates the raw-SQL table / qualified-column identifiers against `Backend.collections`
    // and returns the string unchanged -- so a typo (`FROM postts`, `p.titel`, `p.stauts`) fails
    // the BUILD with a message naming the bad identifier, instead of erroring at runtime. The
    // pooled reader + invocation arena are managed for us by the ctx capability object.
    const CountRow = struct { n: i64 };
    const rows = try ctx.records().queryAs(
        CountRow,
        zigbase.checkedSql(
            Backend.collections,
            "SELECT count(*) AS n FROM posts p WHERE p.status = ?1",
        ),
        .{"published"},
    );
    const published_count: i64 = if (rows.len > 0) rows[0].n else 0;
    std.log.info("[audit-sweep] published_posts={d}", .{published_count});

    // The typed SELECT builder (#281, option 2) is the "constructed SQL" counterpart to the
    // hand-written `checkedSql` above: `zigbase.Query.select` VALIDATES every table/column against
    // `Backend.collections` at comptime and EMITS the SQL + positional binds, so a typo'd column
    // (`.col = "titel"`) or table is a build error, and the `?N` binds are positional by
    // construction. `RecentPosts.sql` here is
    //   SELECT "id", "title" FROM "posts" WHERE "status" = ?1 ORDER BY "created" DESC LIMIT 5
    // and `RecentPosts.bind_count == 1`, matching the single-element `.{ "published" }` tuple.
    const PostRow = struct { id: []const u8, title: []const u8 };
    const RecentPosts = zigbase.Query.select(Backend.collections, "posts", .{
        .columns = &.{ "id", "title" },
        .where = &.{.{ .col = "status", .op = .eq }},
        .order = &.{.{ .col = "created", .dir = .desc }},
        .limit = 5,
    });
    const recent = try ctx.records().queryAs(PostRow, RecentPosts.sql, .{"published"});
    if (recent.len > 0) std.log.info("[audit-sweep] most-recent published post: {s}", .{recent[0].title});

    // `plugin_audit_log` is a migration-owned table (not a comptime collection), so it
    // is written with raw SQL on the pooled writer rather than via `ctx.records()`. It is
    // unknown to the schema, so the comptime check needs `.extra_tables` to opt it in --
    // the motivating case for that option. (The `{d}` lives inside a '...' string literal,
    // which the checker skips, so the format string checks cleanly.)
    const insert_fmt = "INSERT INTO plugin_audit_log(note) VALUES('sweep: published_posts={d}');";
    comptime zigbase.checkSqlOpts(Backend.collections, insert_fmt, .{ .extra_tables = &.{"plugin_audit_log"} });

    const w = ctx.app.pool.acquireWriter();
    defer ctx.app.pool.releaseWriter();

    var buf: [256]u8 = undefined;
    const insert_sql = std.fmt.bufPrintZ(&buf, insert_fmt, .{published_count}) catch return;
    w.exec(insert_sql) catch |e| {
        std.log.warn("[audit-sweep] audit insert failed: {s}", .{@errorName(e)});
    };
}

// ---------------------------------------------------------------------------
// 4a. Migration 0001 -- create the plugin audit-log side table.
// ---------------------------------------------------------------------------
fn createAuditLog(m: *zigbase.Migrator) anyerror!void {
    // A consumer migration's `up` receives a `*zigbase.Migrator` carrying the active SQL dialect
    // (#159). `m.execLowered` runs SQLite-flavor SQL, lowering the portable SQLite-isms (here the
    // `INTEGER` type keyword) to the active backend; raw `m.exec` would be backend-specific. Branch
    // on `m.dialect.kind` (or `m.rawFor(.postgres, …)`) when a statement truly differs per backend.
    try m.execLowered(
        \\CREATE TABLE IF NOT EXISTS plugin_audit_log (
        \\  id INTEGER PRIMARY KEY,
        \\  note TEXT NOT NULL DEFAULT ''
        \\);
    );
}

// ---------------------------------------------------------------------------
// 4b. Migration 0002 -- multi-statement migration: index + seeded metadata row.
//
//     WHEN TO USE RAW SQL MIGRATIONS vs. COMPTIME .indexes:
//       For comptime-managed collections, use `.indexes` in the collection literal --
//       those are lowered at provision time and reference columns by their human
//       field name (e.g. `contact_email`). The `stableFieldId` is an internal
//       rebuild-matching key, never used as a SQL column name. So `CREATE INDEX ...
//       ON posts (status)` DOES work in a raw migration if you own the query.
//
//       The reason THIS migration targets `plugin_audit_log` -- a migration-owned
//       table -- is that the migration is demonstrating the escape-hatch pattern
//       for non-additive DDL on tables the migration itself creates. For a
//       comptime-managed collection, prefer `.indexes = .{ ... }` in the collection
//       spec (see the `authors` collection for a working example).
//
//     Both statements run inside the single transaction that ZigBase opens
//     around every migration's `up` call -- either both succeed or neither does.
// ---------------------------------------------------------------------------
fn addAuditNoteIndex(m: *zigbase.Migrator) anyerror!void {
    // (a) Index on plugin_audit_log.note -- a migration-owned table.
    try m.execLowered(
        \\CREATE INDEX IF NOT EXISTS idx_audit_note
        \\  ON plugin_audit_log (note);
    );

    // (b) Seed a bootstrapping audit row for operator visibility.
    try m.execLowered(
        \\INSERT INTO plugin_audit_log(note)
        \\  VALUES ('schema v2: idx_audit_note created');
    );
}

// ---------------------------------------------------------------------------
// Wire it all together. One `App(...)` registers both custom plugins, the
// four-collection comptime schema, two explicit migrations, the error handler,
// the auth handler, the record hooks, the cron job, and the pool levers, then
// `runCli` exposes `serve` / `migrate` / `help`.
// ---------------------------------------------------------------------------
// The App type is named `Backend` (rather than built inline in `main`) so its lowered comptime
// schema is reachable as `Backend.collections` -- which the audit-sweep job passes to
// `zigbase.checkedSql` / `checkSqlOpts` (#281) to comptime-check its raw SQL against the schema.
const Backend = zigbase.App(.{
        // 1. Custom storage plugin -- wraps LocalStorage with audit logging.
        .storage = AuditStorage,

        // 2. Custom mailer plugin -- logs + counts every outbound email.
        .mailer = AuditMailer,

        // 10. App-level custom auth method registry.
        //     ApiTokenMethod is enabled on `authors` via the collection's `.auth.methods.custom`.
        .auth = .{ .methods = .{ApiTokenMethod} },

        // 3. Comptime schema: FOUR related collections.
        //    Relation graph:
        //      posts.author       -> authors     (cascade-delete)
        //      comments.post      -> posts       (cascade-delete)
        //      comments.commenter -> commenters
        .collections = .{
            .authors = .{
                // Auth collection: system fields (email, passwordHash, verified, ...) are
                // injected automatically. contact_email and bio are user-defined fields.
                // NOTE: "email" is a reserved system field name on auth collections.
                .type = .auth,
                .fields = .{
                    .{ .name = "name", .type = .text, .required = true },
                    .{ .name = "contact_email", .type = .email },
                    .{ .name = "bio", .type = .text, .max = 500 },
                    // At-rest encryption (Theme B1): stored AES-256-GCM-encrypted in
                    // SQLite, transparent plaintext to handlers/API. Requires the
                    // ZIGBASE_FIELD_KEY env var (the server refuses to start without it
                    // when an .encrypted field is declared). Encrypted fields cannot be
                    // indexed / .unique / filtered / sorted.
                    .{ .name = "private_notes", .type = .text, .encrypted = true },
                },
                // webauthn: passkey login for human authors.
                // custom:   "api_token" slug enables ApiTokenMethod for programmatic auth.
                .auth = .{
                    .methods = .{
                        .webauthn = .{
                            .rp_id = "localhost",
                            .rp_name = "ZigBase Plugins Example",
                            .origin = "http://localhost:8090",
                        },
                        // Typed custom method (issue #119): the struct form declares
                        // comptime I/O types so `zig build gen-client` emits precise TS
                        // interfaces (ApiTokenInitiateOutput / ApiTokenCompleteInput /
                        // ApiTokenCompleteOutput) instead of the untyped Record stub.
                        .custom = &.{
                            .{
                                .slug = "api_token",
                                .Initiate = .{ .Output = ApiTokenInitiateOutput },
                                .Complete = .{ .Input = ApiTokenCompleteInput, .Output = ApiTokenCompleteOutput },
                            },
                        },
                    },
                },
                .rules = .{ .list = "@public", .view = "@public" },
                // Comptime index: NOCASE on contact_email so lookups are case-insensitive.
                // Contrast: migration 0002 indexes plugin_audit_log.note (a migration-owned table)
                // because that table is outside the comptime schema. For comptime-managed
                // collections, .indexes is the right tool -- columns are human-named (field.name).
                .indexes = .{
                    .{ .name = "idx_authors_contact_email", .fields = .{"contact_email"}, .collation = .nocase },
                },
            },
            .commenters = .{
                // Lightweight passwordless auth collection for casual readers who want to comment.
                // magic_link with auto_create = true: account is created on first login
                // (no separate sign-up step). Set ZIGBASE_PUBLIC_URL for clickable email links;
                // in local dev the token also appears in the server log.
                .type = .auth,
                .fields = .{
                    .{ .name = "display_name", .type = .text, .max = 80 },
                },
                .auth = .{
                    .methods = .{
                        // Comptime per-method rate limit: cap magic-link requests at 5 per 60s
                        // per client key (vs the runtime `ac.rateLimit(...)` the custom api_token
                        // method calls imperatively). `.rate_limit = .default` uses the global
                        // ZIGBASE_RATE_LIMIT_* config; `.custom` overrides it for this method only.
                        .magic_link = .{
                            .ttl_s = 900,
                            .auto_create = true,
                            .rate_limit = .{ .custom = .{ .max = 5, .window_s = 60 } },
                        },
                    },
                },
                // Publicly listable (frontend can render display_name on comments);
                // full record view is gated on authentication.
                .rules = .{
                    .list = "@public",
                    .view = "@request.auth.id != \"\"",
                },
            },
            .posts = .{
                .type = .base,
                .fields = .{
                    .{ .name = "title", .type = .text, .required = true, .max = 200 },
                    .{ .name = "body", .type = .text },
                    .{ .name = "author", .type = .relation, .target = "authors", .cascadeDelete = true },
                    .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
                },
                .rules = .{ .list = "status = \"published\"" },
            },
            .comments = .{
                .type = .base,
                .fields = .{
                    .{ .name = "body", .type = .text, .required = true, .max = 2000 },
                    .{ .name = "post", .type = .relation, .target = "posts", .cascadeDelete = true },
                    // commenter relation replaces the old free-text author_name field.
                    // The beforeCreateComment hook auto-populates this from the session.
                    .{ .name = "commenter", .type = .relation, .target = "commenters" },
                    .{ .name = "approved", .type = .bool },
                },
                .rules = .{
                    .list = "approved = true",
                    .view = "approved = true",
                    // Gate: requester must have a valid session (any collection).
                    .create = "@request.auth.id != \"\"",
                },
            },
        },
        .enable_typegen = true,

        // 4. Explicit migrations -- escape hatch for non-additive / seeding changes.
        .migrations = &[_]zigbase.Migration{
            .{ .id = "0001_create_audit_log", .up = createAuditLog },
            .{ .id = "0002_index_audit_note", .up = addAuditNoteIndex },
        },

        // 5. onError handler -- logs phase + message for every caught error.
        .onError = handleError,

        // 9. onAuth hook -- fires after any successful session mint across all collections.
        .onAuth = handleAuth,

        // Record hooks -- beforeCreate on comments auto-populates the `commenter`
        // relation from the session identity.
        .hooks = .{
            .comments = .{ .beforeCreate = beforeCreateComment },
        },

        // 6. Cron job -- fires every minute (UTC, 5-field numeric cron).
        .cron = .{
            .{
                .name = "audit-sweep",
                .schedule = zigbase.schedule.Schedule{ .cron = "* * * * *" },
                .handler = auditSweepJob,
            },
        },

        // 7. Pool footprint tuning levers.
        .pools = .{ .readers = 4, .jobs = 1, .cache_kib = 512 },

        // 8. Fully embedded static frontend (see build.zig embedStaticDir).
        .static_files = .{ .embedded = &@import("static_assets").files },

        // 12. Tier-2 SPA fallback routing (issue #183): any GET/HEAD static MISS below
        //     /app/ serves the embedded frontend shell. The serve target is validated
        //     against the embedded manifest AT COMPTIME — misspell it and the build
        //     fails. Declaring routes also flips the Tier-1 `.spa` marker default OFF
        //     (set `.enable_spa_marker = true` to combine both).
        .static_routes = &.{
            .{ .match = "/app/**", .serve = "/index.html" },
        },
});

pub fn main(init: std.process.Init) !void {
    return Backend.runCli(init);
}
