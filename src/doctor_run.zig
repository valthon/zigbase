//! The I/O half of `doctor`: gather real `Facts` (env/config/data-dir/DB),
//! render them as prose or NDJSON, and pick the process exit code.
//!
//! `doctor.zig` is the pure check registry (`Facts` -> `[]Finding` ->
//! `Summary`); this file is everything that touches the filesystem, the
//! database, or stdout. `gather` never fails — an unopenable database or an
//! unwritable data dir is itself a *fact* (`db_reachable = false`,
//! `data_dir_writable = false`), not a reason to abort the whole report.

const std = @import("std");
const config = @import("config.zig");
const provision = @import("provision.zig");
const doctor = @import("doctor.zig");
const db = @import("db.zig");
const migrations = @import("migrations.zig");
const collections = @import("collections.zig");
const rules = @import("rules.zig");
const framework = @import("framework.zig");
const schema = @import("schema.zig");
const ddl = @import("ddl.zig");

/// Probe file created (and immediately deleted) under the data dir to test
/// writability directly, rather than inferring it from whether the database
/// happened to open (the DB file may already exist on a now-read-only mount).
pub const data_dir_probe_filename = ".zigbase-doctor-probe";

/// Read `<data_dir>/.jwt_secret` and stat its permissions. Deliberately does
/// NOT call `framework.resolveJwtSecret`: that function GENERATES and
/// PERSISTS a fresh secret when none exists, which is exactly the kind of
/// mutation a diagnostic command must not perform as a side effect of merely
/// being run. This reads the same file with the same trim rule
/// (`resolveJwtSecret` trims before checking length; disagreeing here would
/// make doctor's "0 = absent/empty" a lie relative to what the server itself
/// decides) and reports absence as a fact instead of fixing it.
fn gatherJwtSecretFile(arena: std.mem.Allocator, io: std.Io, cfg: config.Config, f: *doctor.Facts) void {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ cfg.data_dir, framework.jwt_secret_filename }) catch return;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096))) |contents| {
        f.jwt_secret_file_len = std.mem.trim(u8, contents, " \t\r\n").len;
    } else |_| {
        // Absent, unreadable, or too large to be a real secret: all read as
        // "nothing persisted" (len 0), which is exactly what the severity
        // rules in doctor.zig expect.
    }
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
        f.jwt_secret_file_mode = @intCast(@intFromEnum(st.permissions) & 0o7777);
    } else |_| {
        // Stat failing (most commonly: the file doesn't exist) leaves mode
        // null, which checkJwtSecret already treats as "not 0600".
    }
}

/// Probe the data dir for writability directly: create a throwaway file,
/// write one byte, close it, delete it. NOT inferred from the database open
/// below — an existing, readable `data.db` says nothing about whether the
/// mount is still writable.
fn gatherDataDirWritable(arena: std.mem.Allocator, io: std.Io, cfg: config.Config, f: *doctor.Facts) void {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ cfg.data_dir, data_dir_probe_filename }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "x", .flags = .{ .exclusive = false } }) catch |err| {
        f.data_dir_writable = false;
        f.data_dir_error = @errorName(err);
        return;
    };
    // Best-effort cleanup: whether the delete succeeds does not change the
    // writability verdict above (we already proved we could write).
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    f.data_dir_writable = true;
}

/// Every `@public` rule across every collection, re-walking the same five
/// list/view/create/update/delete pairs `provision.warnPublicRules` logs at
/// boot. That function stays private and log-only (it has no return value to
/// reuse); this is a deliberate, small re-implementation rather than a
/// refactor of boot-time provisioning to serve a CLI report.
///
/// `cols` is fetched once in `gatherDb` and shared with
/// `gatherLegacyPasswordHashes` below — both need the full collection list,
/// and a diagnostic command has no reason to round-trip `collections.list`
/// twice against the same snapshot.
fn gatherPublicRules(arena: std.mem.Allocator, cols: []const schema.Collection) ![]const doctor.RuleFact {
    const Pair = struct { op: []const u8, rule: ?[]const u8, write: bool };
    var out: std.ArrayListUnmanaged(doctor.RuleFact) = .empty;
    for (cols) |c| {
        const pairs = [_]Pair{
            .{ .op = "list", .rule = c.listRule, .write = false },
            .{ .op = "view", .rule = c.viewRule, .write = false },
            .{ .op = "create", .rule = c.createRule, .write = true },
            .{ .op = "update", .rule = c.updateRule, .write = true },
            .{ .op = "delete", .rule = c.deleteRule, .write = true },
        };
        for (pairs) |p| {
            if (rules.isPublic(p.rule)) {
                const auth_signup = c.type == .auth and
                    std.mem.eql(u8, p.op, "create") and
                    !c.system;
                try out.append(arena, .{
                    .collection = c.name,
                    .op = p.op,
                    .write = p.write,
                    .auth_signup = auth_signup,
                });
            }
        }
    }
    return out.toOwnedSlice(arena);
}

test "doctor gather: only non-system auth create is classified as open signup" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cols = [_]schema.Collection{
        .{ .id = "users", .name = "users", .type = .auth, .fields = &.{}, .createRule = "@public" },
        .{ .id = "posts", .name = "posts", .fields = &.{}, .createRule = "@public" },
        .{ .id = "_superusers", .name = "_superusers", .type = .auth, .system = true, .fields = &.{}, .createRule = "@public" },
    };

    const found = try gatherPublicRules(arena, &cols);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expect(found[0].auth_signup);
    try std.testing.expect(!found[1].auth_signup);
    try std.testing.expect(!found[2].auth_signup);
}

/// The exact prefix a legacy (pre-migration) password hash still starts with.
/// See `docs/serve.md` §8 and the `legacy-password-hashes` doctor check: a
/// record carrying one re-hashes to the current scheme automatically on its
/// next successful login, so this is a `LIKE` prefix match, not an exact one.
const legacy_password_hash_like_pattern = "$zblegacy$%";

/// Sum, across every AUTH collection, the count of records whose
/// `passwordHash` column still starts with the legacy prefix.
///
/// The table name is quoted with `ddl.quoteIdent` (doubles any embedded `"`)
/// rather than gated through `schema.isValidIdentifier`: that gate requires
/// an alphabetic first character, which is a POLICY rule that deliberately
/// excludes system collections (leading underscore) from the generic records
/// API — see `records.zig`'s identifier gate. `_superusers` is exactly such a
/// collection, and exactly the one whose legacy hashes matter most (the
/// highest-privilege accounts), so this check must not silently skip it.
/// `quoteIdent` is the injection-safe primitive `ddl.zig` documents for
/// "defensive quoting where escaping might matter" and is safe for any
/// identifier, not just ones matching the API-collection naming policy.
fn gatherLegacyPasswordHashes(arena: std.mem.Allocator, w: *db.Db, cols: []const schema.Collection) !usize {
    const d = db.dbDialect(w);
    var total: usize = 0;
    for (cols) |c| {
        if (c.type != .auth) continue;
        const quoted_table = try ddl.quoteIdent(arena, c.name);
        const raw = try std.fmt.allocPrint(arena, "SELECT COUNT(*) FROM {s} WHERE \"passwordHash\" LIKE ?1;", .{quoted_table});
        var st = try w.prepare(try d.renumberPlaceholders(arena, raw));
        defer st.finalize();
        try st.bindText(1, legacy_password_hash_like_pattern);
        _ = try st.step();
        total += @intCast(st.columnInt(0));
    }
    return total;
}

/// Open the database exactly as `migrateStatusImpl` does and gather the
/// DB-backed facts (public rules, migration status, legacy password hashes).
/// Any failure along the way — open, `ensureLedger`, `collections.list`,
/// `migrationStatus` — leaves `db_reachable = false` and `db_error` set, and
/// the dependent checks in `doctor.zig` report `skipped` rather than a false
/// "clean".
///
/// Opens the DB (and creates the `_migrations` ledger — see below) ONLY when
/// `gatherDataDirWritable` already found the data dir usable. When it did
/// not, this is a no-op: `openPoolSelect` -> `openPool` -> `ensureDataDir`
/// would otherwise try to CREATE directories under a data dir a read-only
/// diagnostic has no business creating anything under, and on some
/// filesystems (procfs-like paths whose `mkdir` returns ENOENT for an
/// unregistered leaf) that recurses forever. `data-dir-writable` already
/// reported the real reason; the two DB-dependent checks just need to know
/// not to bother.
///
/// `migrations.ensureLedger` creates the `_migrations` table if it is
/// missing — the same write `migrate status` already performs. That is the
/// only mutation `doctor` makes; see the `doctor` section of
/// `docs/framework.md`.
fn gatherDb(
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    environ: *const std.process.Environ.Map,
    schema_migrations: []const provision.Migration,
    f: *doctor.Facts,
) void {
    if (!f.data_dir_writable) {
        f.db_error = "data dir not writable (see data-dir-writable)";
        return;
    }
    var pool = framework.openPoolSelect(arena, io, cfg, .{}, environ) catch |err| {
        f.db_error = @errorName(err);
        return;
    };
    defer pool.deinit();
    const w = pool.acquireWriter();
    defer pool.releaseWriter();

    migrations.ensureLedger(w) catch |err| {
        f.db_error = @errorName(err);
        return;
    };

    // collections.list returns fully-owned collections. On an arena that is
    // fine and nothing needs freeing individually — do NOT "fix" this into a
    // deinit loop; the arena already owns every byte and a manual free here
    // would double-free when the arena is torn down. Fetched once and shared
    // by `gatherPublicRules` and `gatherLegacyPasswordHashes` below.
    const cols = collections.list(arena, w) catch |err| {
        f.db_error = @errorName(err);
        return;
    };

    const found_rules = gatherPublicRules(arena, cols) catch |err| {
        f.db_error = @errorName(err);
        return;
    };

    const legacy_hashes = gatherLegacyPasswordHashes(arena, w, cols) catch |err| {
        f.db_error = @errorName(err);
        return;
    };

    // Contract 4 (arena): `MigrationStatus` is fully owned on `arena` and
    // never freed individually — no `.deinit()` call here is intentional,
    // not an oversight.
    const status = provision.migrationStatus(arena, w, schema_migrations) catch |err| {
        f.db_error = @errorName(err);
        return;
    };

    f.db_reachable = true;
    f.rules = found_rules;
    f.migrations_pending = status.pending_count;
    f.migrations_orphaned = status.orphaned.len;
    f.legacy_password_hashes = legacy_hashes;
}

/// Open the pool read-mostly, gather every fact, and hand a `Facts` to
/// `doctor.evaluate`. Never fails: an unopenable database sets
/// `db_reachable = false` + `db_error`, which the dependent checks report as
/// `skipped`. Contract 4: everything is allocated on `arena`.
pub fn gather(
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    environ: *const std.process.Environ.Map,
    schema_migrations: []const provision.Migration,
) doctor.Facts {
    var f: doctor.Facts = .{
        .jwt_secret_env_len = cfg.jwt_secret.len,
        .jwt_secret_file_len = 0,
        .jwt_secret_file_mode = null,
        .cookie_secure = cfg.cookie_secure,
        .http_host = cfg.http_host,
        .trust_proxy = cfg.trust_proxy,
        .public_url = cfg.public_url,
        .sendmail_command = cfg.sendmail_command,
        .smtp_host = cfg.smtp_host,
        .smtp_username = cfg.smtp_username,
        .smtp_tls_resolved = config.Config.resolveSmtpTls(cfg.smtp_tls, cfg.smtp_port),
        .data_dir = cfg.data_dir,
        .data_dir_writable = false,
        .data_dir_error = null,
        .db_reachable = false,
        .db_error = null,
        .rules = &.{},
        .migrations_pending = 0,
        .migrations_orphaned = 0,
        .legacy_password_hashes = 0,
    };
    gatherJwtSecretFile(arena, io, cfg, &f);
    gatherDataDirWritable(arena, io, cfg, &f);
    gatherDb(arena, io, cfg, environ, schema_migrations, &f);
    return f;
}

/// "" for 1 (singular), "s" otherwise. `skipped` in the summary line is not
/// pluralized at all ("N skipped" reads fine for any N), so this is only
/// used for check/error/warning.
fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// The testable core: the exact bytes `render` writes. Contract 4 (arena).
///
/// NDJSON (`json == true`): one compact JSON object per finding, field order
/// `check`/`severity`/`subject`/`message` (== `Finding`'s declaration order),
/// followed by exactly one summary object — `{"summary":true,...}` — whose
/// leading `"summary":true` lets a lazy or line-skipping consumer identify it
/// by content, not by stream position.
///
/// Prose (`json == false`): one severity-labeled line per finding, then a
/// "N checks, X error(s), Y warning(s), Z skipped" summary line.
pub fn renderToSlice(
    arena: std.mem.Allocator,
    findings: []const doctor.Finding,
    summary: doctor.Summary,
    json: bool,
) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    if (json) {
        for (findings) |finding| {
            // Finding's field order (check, severity, subject, message) IS
            // the NDJSON wire contract, so stringifying the struct directly
            // (rather than building a json.Value by hand) can't drift from it.
            std.json.Stringify.value(finding, .{}, w) catch return error.OutOfMemory;
            w.writeAll("\n") catch return error.OutOfMemory;
        }
        // Same reasoning: Summary's field order puts `summary: bool = true`
        // first, which is the discriminator a lazy reader keys on.
        std.json.Stringify.value(summary, .{}, w) catch return error.OutOfMemory;
        w.writeAll("\n") catch return error.OutOfMemory;
    } else {
        for (findings) |finding| {
            w.print("{s:<9}{s}", .{ finding.severity, finding.check }) catch return error.OutOfMemory;
            if (finding.subject) |subject| w.print(" [{s}]", .{subject}) catch return error.OutOfMemory;
            w.print(": {s}\n", .{finding.message}) catch return error.OutOfMemory;
        }
        w.print("{d} check{s}, {d} error{s}, {d} warning{s}, {d} skipped", .{
            summary.checks,   plural(summary.checks),
            summary.errors,   plural(summary.errors),
            summary.warnings, plural(summary.warnings),
            summary.skipped,
        }) catch return error.OutOfMemory;
        if (summary.production) w.writeAll(" (production mode)") catch return error.OutOfMemory;
        w.writeAll("\n") catch return error.OutOfMemory;
    }

    return aw.toOwnedSlice() catch error.OutOfMemory;
}

/// `renderToSlice` + a streaming write to stdout. Streaming (not positional)
/// for the same reason `serve_control.writeStdout` is: under `cmd >f 2>&1`
/// both fds share one open file description, and a positional flush from
/// offset zero would stomp whatever stderr already committed there.
pub fn render(
    io: std.Io,
    arena: std.mem.Allocator,
    findings: []const doctor.Finding,
    summary: doctor.Summary,
    json: bool,
) void {
    const bytes = renderToSlice(arena, findings, summary, json) catch return;
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    fw.interface.writeAll(bytes) catch return;
    fw.interface.flush() catch return;
}

/// 1 on any error finding, 2 on warnings-only, 0 when fully clean. Errors win
/// over warnings. `skipped` never sets a code on its own — a check that could
/// not run is reported, not scored.
pub fn exitCode(summary: doctor.Summary) u8 {
    if (summary.errors > 0) return 1;
    if (summary.warnings > 0) return 2;
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "doctor render: json mode emits one object per finding then exactly one summary" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const findings = [_]doctor.Finding{
        .{ .check = "jwt-secret-persisted", .severity = "ok", .subject = null, .message = "fine" },
        .{ .check = "public-rules-enumerated", .severity = "error", .subject = "posts.createRule", .message = "wide open" },
    };
    const summary = doctor.summarize(&findings, true);
    const out = try renderToSlice(arena, &findings, summary, true);

    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    const l1 = lines.next().?;
    const l2 = lines.next().?;
    const l3 = lines.next().?;
    try std.testing.expect(lines.next() == null);
    // Every line is a standalone JSON object (NDJSON), in declaration order.
    try std.testing.expect(std.mem.startsWith(u8, l1, "{\"check\":\"jwt-secret-persisted\",\"severity\":\"ok\",\"subject\":null,"));
    try std.testing.expect(std.mem.indexOf(u8, l2, "\"subject\":\"posts.createRule\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, l3, "{\"summary\":true,"));
    try std.testing.expect(std.mem.indexOf(u8, l3, "\"errors\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, l3, "\"production\":true") != null);
}

test "doctor render: prose mode labels each severity and names the subject" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const findings = [_]doctor.Finding{
        .{ .check = "host-binding", .severity = "warn", .subject = null, .message = "bound to loopback" },
        .{ .check = "public-rules-enumerated", .severity = "error", .subject = "posts.createRule", .message = "wide open" },
        .{ .check = "migrations-applied", .severity = "skipped", .subject = null, .message = "db unreachable" },
    };
    const out = try renderToSlice(arena, &findings, doctor.summarize(&findings, false), false);
    try std.testing.expect(std.mem.indexOf(u8, out, "warn ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "error ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "skipped ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[posts.createRule]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1 error") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1 warning") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1 skipped") != null);
}

test "doctor render: 0 fully clean, 1 on any error, 2 on warnings only" {
    // Fully clean: nothing to look at.
    const spotless = [_]doctor.Finding{
        .{ .check = "host-binding", .severity = "ok", .subject = null, .message = "m" },
        .{ .check = "mailer-configured", .severity = "info", .subject = null, .message = "m" },
    };
    try std.testing.expectEqual(@as(u8, 0), exitCode(doctor.summarize(&spotless, false)));

    // Warnings only: it RAN correctly and found something needing judgment.
    // This is the distinction a tolerant deploy gate keys on — it must not
    // collapse into 0, or "nothing to see" and "look at this" become the same
    // answer.
    const warned = [_]doctor.Finding{
        .{ .check = "host-binding", .severity = "warn", .subject = null, .message = "m" },
        .{ .check = "migrations-applied", .severity = "skipped", .subject = null, .message = "m" },
    };
    try std.testing.expectEqual(@as(u8, 2), exitCode(doctor.summarize(&warned, false)));

    // A skipped check alone is neither clean nor a warning: it is reported,
    // not scored.
    const only_skipped = [_]doctor.Finding{
        .{ .check = "migrations-applied", .severity = "skipped", .subject = null, .message = "m" },
        .{ .check = "host-binding", .severity = "ok", .subject = null, .message = "m" },
    };
    try std.testing.expectEqual(@as(u8, 0), exitCode(doctor.summarize(&only_skipped, false)));

    // Errors win over warnings.
    const dirty = [_]doctor.Finding{
        .{ .check = "host-binding", .severity = "warn", .subject = null, .message = "m" },
        .{ .check = "data-dir-writable", .severity = "error", .subject = null, .message = "m" },
    };
    try std.testing.expectEqual(@as(u8, 1), exitCode(doctor.summarize(&dirty, true)));
}
