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
//!   3. COMPTIME SCHEMA via `.collections` — THREE related collections:
//!      `authors`, `posts` (relation → authors), and `comments` (relation →
//!      posts + author-name text). Access rules are applied per-collection
//!      (list/view/create/update/delete).
//!
//!   4. EXPLICIT MIGRATIONS via `.migrations` — two `zigbase.Migration` entries:
//!      - `0001_create_audit_log`: creates a side table via `w.exec`.
//!      - `0002_index_audit_note`: multi-statement migration — creates an index
//!        on the migration-owned `plugin_audit_log` table AND seeds a metadata
//!        row (DDL + DML in one transaction). Targets a migration-owned table
//!        because comptime-provisioned collection columns are id-named, not
//!        field-name-named (see the note on `addAuditNoteIndex`).
//!
//!   5. `onError` HANDLER — `.onError = handleError`, receiving a
//!      `*zigbase.ErrorEvent` whose `.phase` field identifies where the error
//!      originated (.request / .cron / .job / .file_serve …).
//!
//!   6. CRON JOB — a `* * * * *` (every-minute) job that reads the DB via
//!      `ev.reader()` to count published posts, then writes an audit log row
//!      via `ev.writer()`. Demonstrates both DB-access handles in one handler.
//!
//!   7. POOL LEVERS via `.pools` — reader/job pool sizes + page-cache budget.
//!
//!   8. FULLY EMBEDDED STATIC FRONTEND via `embedStaticDir` — the Astro build
//!      output in `frontend/dist` is compiled into the binary at build time;
//!      there is no runtime dependency on the frontend directory.
//!
//! The whole point: this package compiles against the PUBLISHED `zigbase`
//! module, proving the documented plugin/schema/migration/cron/error features
//! are usable by an external consumer.

const std = @import("std");
const zigbase = @import("zigbase");

// ---------------------------------------------------------------------------
// 1. Custom storage plugin.
//
//    The plugin contract (mirrors the built-in DefaultStoragePlugin):
//      - create(gpa, io, cfg) !Self       — construct from runtime config.
//      - interface(*Self) zigbase.Storage — hand back the vtable the app calls.
//      - deinit(*Self) void               — release anything `create` allocated.
//
//    `AuditStorage` wraps a `zigbase.LocalStorage` backend (rooted at
//    `<cfg.data_dir>/storage`), intercepting every vtable call to emit a
//    structured log line BEFORE delegating to the inner backend.
//
//    The `zigbase.Storage.VTable` has exactly four function pointers (verified
//    by reading src/files/storage.zig — all four must be present; a missing
//    entry leaves a null fn pointer and crashes on the first file operation):
//
//      put(ctx, io, col, record_id, filename, bytes) anyerror!void
//      localPath(ctx, alloc, col, record_id, filename) anyerror!?[]const u8
//      delete(ctx, io, col, record_id, filename) anyerror!void
//      deleteRecord(ctx, io, col, record_id) anyerror!void
//
//    Each wrapper: @ptrCast/@alignCast `ctx` → *AuditStorage, logs, delegates.
// ---------------------------------------------------------------------------
const AuditStorage = struct {
    /// Backing LocalStorage; held by value so it has a stable address here.
    local: zigbase.LocalStorage,
    /// Cached vtable-view of `local`; refreshed by interface() after placement.
    inner: zigbase.Storage,
    /// GPA used in create(); freed in deinit().
    gpa: std.mem.Allocator,
    /// Root path string (heap-allocated by create(); freed by deinit()).
    root: []const u8,
    /// Running operation counters, one per vtable method.
    puts: usize = 0,
    deletes: usize = 0,
    delete_records: usize = 0,
    local_paths: usize = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !AuditStorage {
        _ = io;
        // Mirror DefaultStoragePlugin: root at <data_dir>/storage.
        const root = try std.fmt.allocPrint(gpa, "{s}/storage", .{cfg.data_dir});
        var local = zigbase.LocalStorage.init(root);
        // Snapshot the inner vtable; interface() re-snaps using the stable
        // struct-field address once the struct is placed on the stack of serveImpl.
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

    // ---- Static VTable (all four methods required) --------------------------

    const vtable = zigbase.Storage.VTable{
        .put = auditPut,
        .localPath = auditLocalPath,
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

    fn auditLocalPath(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        col: []const u8,
        record_id: []const u8,
        filename: []const u8,
    ) anyerror!?[]const u8 {
        const self: *AuditStorage = @ptrCast(@alignCast(ctx));
        self.local_paths += 1;
        std.log.debug("[audit-storage] localPath col={s} id={s} file={s}", .{
            col, record_id, filename,
        });
        return self.inner.vtable.localPath(self.inner.ctx, alloc, col, record_id, filename);
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
//    The plugin contract (mirrors the built-in DefaultMailerPlugin):
//      - create(gpa, io, cfg) !Self     — construct from runtime config.
//      - interface(*Self) zigbase.Mailer — hand back the vtable the app calls.
//      - deinit(*Self) void             — release anything `create` allocated.
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
// 5. onError handler.
//
//    `zigbase.ErrorEvent` fields:
//      .app     — *zigbase.Runtime
//      .ctx     — ?*RequestContext (null for cron/job/lifecycle phases)
//      .err     — anyerror
//      .phase   — .request | .before_hook | .after_hook | .cron | .job | .file_serve
//      .message — []const u8 (human-readable, always safe to log)
//
//    This handler emits a structured one-liner so operators can distinguish
//    request errors from background-job failures at a glance.
// ---------------------------------------------------------------------------
fn handleError(ev: *zigbase.ErrorEvent) void {
    const phase_name = switch (ev.phase) {
        .request => "request",
        .before_hook => "before_hook",
        .after_hook => "after_hook",
        .cron => "cron",
        .job => "job",
        .file_serve => "file_serve",
    };
    std.log.err("[onError] phase={s} err={s} msg={s}", .{
        phase_name, @errorName(ev.err), ev.message,
    });
}

// ---------------------------------------------------------------------------
// 6. Cron / interval job: "audit-sweep".
//
//    Fires every minute (cron "* * * * *", UTC, numeric 5-field format).
//    Demonstrates the correct DB-access pattern for job handlers:
//      - reads  use ev.reader() — checked out of the warm reader pool.
//      - writes use ev.writer() — the single mutex-guarded pool writer.
//    Both RAII handles must be defer'd to avoid a pool leak.
//
//    The handler counts published posts (read), then appends a row to
//    plugin_audit_log (write) — a realistic "heartbeat audit" pattern.
//
//    NOTE: jobs have no request arena. The handler uses a stack buffer for the
//    formatted INSERT SQL (no heap allocation required).
// ---------------------------------------------------------------------------
fn auditSweepJob(ev: *zigbase.events.JobEvent) anyerror!void {
    // --- read phase: count published posts via a pooled reader connection ----
    var r = try ev.reader();
    defer r.deinit();
    const result = try r.data().list("posts", .{
        .filter = "status = \"published\"",
        .perPage = 1, // we only need totalItems, not all rows
    });
    // totalItems is optional (cursor mode may skip the COUNT); offset mode always sets it.
    const published_count = result.totalItems orelse 0;
    std.log.info("[audit-sweep] published_posts={d}", .{published_count});

    // --- write phase: append an audit row ------------------------------------
    var w = ev.writer();
    defer w.deinit();

    // Db.exec takes [:0]const u8 — use bufPrintZ into a local stack buffer.
    var buf: [256]u8 = undefined;
    const insert_sql = std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO plugin_audit_log(note) VALUES('sweep: published_posts={d}');",
        .{published_count},
    ) catch return; // truncation is not expected at 256 bytes
    w.conn.exec(insert_sql) catch |e| {
        // Non-fatal: warn and continue if the table is somehow unavailable.
        std.log.warn("[audit-sweep] audit insert failed: {s}", .{@errorName(e)});
    };
}

// ---------------------------------------------------------------------------
// 4a. Migration 0001 — create the plugin audit-log side table.
//
//     This table lives outside the comptime-managed `.collections` schema;
//     it is a good example of the migration escape hatch for ad-hoc DDL that
//     the additive auto-provisioner won't produce on its own.
// ---------------------------------------------------------------------------
fn createAuditLog(alloc: std.mem.Allocator, io: std.Io, w: *zigbase.Db) anyerror!void {
    _ = alloc;
    _ = io;
    try w.exec(
        \\CREATE TABLE IF NOT EXISTS plugin_audit_log (
        \\  id INTEGER PRIMARY KEY,
        \\  note TEXT NOT NULL DEFAULT ''
        \\);
    );
}

// ---------------------------------------------------------------------------
// 4b. Migration 0002 — multi-statement migration: index + seeded metadata row.
//
//     A more realistic migration demonstrating two statements in one `up` call:
//       (a) Creates an index on the `plugin_audit_log` table (created by 0001).
//       (b) Seeds a metadata row into plugin_audit_log so operators can confirm
//           this migration ran by inspecting the table.
//
//     CRITICAL LESSON — raw SQL migrations and comptime collections:
//       A migration is hand-written SQL, so it can only safely reference columns
//       whose names it KNOWS. The comptime `.collections` provisioner names each
//       collection's SQLite columns by its STABLE FIELD ID (an 8-char hex string
//       from `stableFieldId`), NOT by the human-readable field name. So a posts
//       row's "status" lives in a column like "a1b2c3d4" — there is no literal
//       `status` column, and `CREATE INDEX ... ON posts (status)` fails with
//       ExecFailed, aborting startup. The safe target for a raw migration is a
//       table the MIGRATION ITSELF owns (here `plugin_audit_log`, whose column
//       names we chose), where the names are known. (To index a provisioned
//       column you would have to resolve its field id first.)
//
//     Both statements run inside the single transaction that ZigBase opens
//     around every migration's `up` call — either both succeed or neither does.
// ---------------------------------------------------------------------------
fn addAuditNoteIndex(alloc: std.mem.Allocator, io: std.Io, w: *zigbase.Db) anyerror!void {
    _ = alloc;
    _ = io;

    // (a) Index on plugin_audit_log.note — a migration-owned table, so the
    //     column name is known. IF NOT EXISTS is defensive; ZigBase already
    //     guards against re-runs.
    try w.exec(
        \\CREATE INDEX IF NOT EXISTS idx_audit_note
        \\  ON plugin_audit_log (note);
    );

    // (b) Seed a bootstrapping audit row for operator visibility.
    try w.exec(
        \\INSERT INTO plugin_audit_log(note)
        \\  VALUES ('schema v2: idx_audit_note created');
    );
}

// ---------------------------------------------------------------------------
// Wire it all together. One `App(...)` registers both custom plugins, the
// three-collection comptime schema, two explicit migrations, the error handler,
// the cron job, and the pool levers, then `runCli` exposes `serve` / `migrate`
// / `help`.
// ---------------------------------------------------------------------------
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        // 1. Custom storage plugin — wraps LocalStorage with audit logging.
        //    Intercepts all four vtable methods: put / localPath / delete /
        //    deleteRecord. Registered the same way as the mailer plugin.
        .storage = AuditStorage,

        // 2. Custom mailer plugin — logs + counts every outbound email.
        .mailer = AuditMailer,

        // 3. Comptime schema: THREE related collections.
        //
        //    Relation graph (resolved by name at provision time):
        //      posts.author → authors    (many posts per author, cascade-delete)
        //      comments.post → posts     (many comments per post, cascade-delete)
        //
        //    Access rules demonstrate per-collection policy:
        //      authors  — publicly listable + viewable.
        //      posts    — only status="published" rows visible in list.
        //      comments — approved=true rows are public; anyone can submit.
        .collections = .{
            .authors = .{
                .type = .base,
                .fields = .{
                    .{ .name = "name", .type = .text, .required = true },
                    // "email" is reserved for auth collections; base collections
                    // must pick a different field name.
                    .{ .name = "contact_email", .type = .email },
                    .{ .name = "bio", .type = .text, .max = 500 },
                },
                // Authors are publicly readable ("@public"); empty "" is now LOCKED.
                .rules = .{ .list = "@public", .view = "@public" },
            },
            .posts = .{
                .type = .base,
                .fields = .{
                    .{ .name = "title", .type = .text, .required = true, .max = 200 },
                    .{ .name = "body", .type = .text },
                    // Relation field: target is the collection NAME ("authors").
                    // ZigBase resolves the name → collection id at provision time.
                    .{ .name = "author", .type = .relation, .target = "authors", .cascadeDelete = true },
                    .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
                },
                // Comptime list rule — the API enforces this without handler code.
                .rules = .{ .list = "status = \"published\"" },
            },
            // NEW: comments collection — adds a SECOND cross-collection relation.
            // comments.post → posts; cascade-delete propagates post removal.
            .comments = .{
                .type = .base,
                .fields = .{
                    .{ .name = "body", .type = .text, .required = true, .max = 2000 },
                    // Relation to the parent post (cascade-delete).
                    .{ .name = "post", .type = .relation, .target = "posts", .cascadeDelete = true },
                    // Display name for the commenter (guests are welcome).
                    .{ .name = "author_name", .type = .text, .max = 100 },
                    .{ .name = "approved", .type = .bool },
                },
                // Approved comments are publicly readable; anyone can submit ("@public" create —
                // an empty "" would now LOCK creation to superusers).
                .rules = .{
                    .list = "approved = true",
                    .view = "approved = true",
                    .create = "@public",
                },
            },
        },
        .enable_typegen = true,

        // 4. Explicit migrations — escape hatch for non-additive / seeding changes.
        //    ZigBase records each migration by id in `_migrations` and runs it
        //    exactly once, in id order, inside an individual transaction.
        .migrations = &[_]zigbase.Migration{
            .{ .id = "0001_create_audit_log", .up = createAuditLog },
            .{ .id = "0002_index_audit_note", .up = addAuditNoteIndex },
        },

        // 5. onError handler — logs phase + message for every caught error.
        .onError = handleError,

        // 6. Cron job — fires every minute (UTC, 5-field numeric cron).
        //    .pools.jobs = 1 is sufficient for this single light job.
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
    }).runCli(init);
}
