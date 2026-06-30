const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const field_policy = @import("field_policy.zig");
const aead = @import("aead.zig");
const ddl = @import("ddl.zig");

// ---------------------------------------------------------------------------
// Encryption key-rotation rewrap (issue #104).
//
// Re-encrypts every `.encrypted` cell across all collections under the PRIMARY
// key generation, and migrates legacy plaintext into ciphertext. This is the
// supported forward path after a key rotation (bump ZIGBASE_FIELD_KEY_GENERATION
// and supply the old key as ZIGBASE_FIELD_KEY_V<old>) and the supported way to
// enable `.encrypted` on a column that already holds plaintext under strict mode.
//
// It works on RAW SQL cells (SELECT "id", "<col>" / UPDATE … WHERE "id"=?),
// deliberately bypassing the value-layer strict decrypt so it can read mixed
// generations and legacy plaintext directly. Decryption uses the resolved
// key-ring (`field_policy.Cipher`): each cell is decrypted with the key of its
// own envelope version, then re-sealed under the primary generation.
//
// Rows are keyed by the app-generated string PRIMARY KEY `id` — NOT SQLite's
// implicit `rowid` — so the same statements run on both the SQLite and Postgres
// backends (Postgres has no `rowid`). Placeholders flow through the active
// dialect (`?n` → `$n` on Postgres). The AEAD envelope itself is a backend-neutral
// TEXT value, so nothing else in this path is backend-specific.
//
// FAIL-CLOSED: a cell that cannot be decrypted (unknown/missing generation,
// wrong key, tamper) aborts the run with the offending row reported; the
// per-collection transaction is rolled back so no rows are partially changed and
// no data is lost. Idempotent: cells already at the primary version are skipped.
// ---------------------------------------------------------------------------

pub const Error = error{
    /// A stored cell could not be decrypted with the configured key generations.
    /// Details (collection.field id version) are logged before returning.
    RewrapDecryptFailed,
    /// A row carries an empty/NULL `id`, so it cannot be safely re-keyed: a keyed
    /// `UPDATE … WHERE "id"=''` would match zero rows and silently leave the cell at the
    /// OLD generation (permanent data loss once the old key is dropped). Fail closed.
    /// (SQLite permits NULL in a `TEXT PRIMARY KEY`; the records layer never writes one,
    /// so this is a fail-safe against a corrupt/hand-edited row, not an expected state.)
    RewrapRowUnkeyed,
    /// A keyed single-row rewrap `UPDATE` reported that it matched no row (the row vanished
    /// or its `id` did not match). The write did NOT land, so the run fails closed rather
    /// than over-reporting a rewrap that silently lost data.
    RewrapWriteFailed,
    // `collections.EngineError` (which already includes `db.DbError` and
    // `std.mem.Allocator.Error`) is unioned in so enumerating the collection store
    // propagates its real error type instead of being masked.
} || collections.EngineError;

/// Per-column outcome.
pub const ColStats = struct {
    /// Cells that were an older-generation envelope and got re-encrypted to primary.
    rewrapped: usize = 0,
    /// Cells that were legacy plaintext and got sealed into an envelope.
    plaintext_migrated: usize = 0,
    /// Cells already at the primary version (left untouched — idempotency).
    skipped: usize = 0,
};

/// Aggregate outcome across all collections/fields.
pub const Stats = struct {
    collections: usize = 0,
    fields: usize = 0,
    rewrapped: usize = 0,
    plaintext_migrated: usize = 0,
    skipped: usize = 0,
};

const Update = struct { id: []const u8, blob: []const u8 };

/// Details of the cell that triggered a fail-closed abort, filled into the
/// caller's out-param so the caller (not this leaf function) does the logging.
pub const Failure = struct {
    table: []const u8 = "",
    column: []const u8 = "",
    id: []const u8 = "",
    version: u16 = 0,
};

/// Rewrap a single encrypted column. Reads every non-null cell, decrypts it by
/// its envelope version (or takes legacy plaintext as-is), re-seals under the
/// primary generation, and (unless `dry_run`) writes it back keyed by the row's
/// `id` PRIMARY KEY (works on both SQLite and Postgres). All work
/// uses `arena` (caller-scoped). Runs inside the caller's transaction. On a
/// fail-closed decrypt error, `failure` (when non-null) is filled with the
/// offending cell's details and `error.RewrapDecryptFailed` is returned.
pub fn rewrapColumn(
    arena: std.mem.Allocator,
    w: *db.Db,
    cipher: *const field_policy.Cipher,
    table: []const u8,
    col: []const u8,
    dry_run: bool,
    failure: ?*Failure,
) Error!ColStats {
    var stats = ColStats{};
    const tq = try ddl.quoteIdent(arena, table);
    const cq = try ddl.quoteIdent(arena, col);

    const sel = try std.fmt.allocPrintSentinel(arena, "SELECT \"id\", {s} FROM {s};", .{ cq, tq }, 0);
    var updates: std.ArrayList(Update) = .empty;

    var stmt = try w.prepare(sel);
    {
        defer stmt.finalize();
        while (try stmt.step()) {
            if (stmt.isNull(1)) continue;
            // `id` is the app-generated string PRIMARY KEY; dupe it into the arena
            // since columnText borrows the statement's transient row buffer.
            const id = try arena.dupe(u8, stmt.columnText(0));
            const stored = try arena.dupe(u8, stmt.columnText(1));
            // A NULL/empty id cannot be the target of a keyed UPDATE (it would match zero
            // rows and silently drop the rewrite). Fail closed before we count or write it —
            // an encrypted cell on an unkeyable row must be surfaced, not lost.
            if (id.len == 0 or stmt.isNull(0)) {
                if (failure) |fp| fp.* = .{ .table = table, .column = col, .id = id, .version = aead.parseVersion(stored) orelse 0 };
                return error.RewrapRowUnkeyed;
            }
            const ver = aead.parseVersion(stored);

            // Already at the primary version → no-op (this is what makes rewrap idempotent).
            if (ver != null and ver.? == cipher.primary_gen) {
                stats.skipped += 1;
                continue;
            }

            var plaintext: []const u8 = undefined;
            if (ver != null) {
                // Older-generation envelope: decrypt with that generation's key.
                plaintext = cipher.open(arena, stored) catch |err| {
                    // `aead.Error` includes `OutOfMemory`; re-raise it as-is so an
                    // allocation failure is not misreported as a decrypt (bad-key) error.
                    // (Return the narrowed literal — `return err` would carry the whole
                    // aead error set, incl. BadEnvelope, which is not in `Error`.)
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    if (failure) |fp| fp.* = .{ .table = table, .column = col, .id = id, .version = ver.? };
                    return error.RewrapDecryptFailed;
                };
                stats.rewrapped += 1;
            } else {
                // Legacy plaintext: migrate it into ciphertext under the primary key.
                plaintext = stored;
                stats.plaintext_migrated += 1;
            }

            const blob = try cipher.seal(arena, plaintext);
            try updates.append(arena, .{ .id = id, .blob = blob });
        }
    }

    // Nothing to write: dry-run, or every cell was already at the primary version
    // (the common idempotent-rerun path). Skip preparing the UPDATE statement.
    if (dry_run or updates.items.len == 0) return stats;

    // Key the write by the string `id` PK and renumber placeholders for the active
    // backend (`?n` stays `?n` on SQLite, becomes `$n` on Postgres).
    const upd_tmpl = try std.fmt.allocPrint(arena, "UPDATE {s} SET {s}=?1 WHERE \"id\"=?2;", .{ tq, cq });
    const upd = try db.dbDialect(w).renumberPlaceholders(arena, upd_tmpl);
    var ustmt = try w.prepare(upd);
    defer ustmt.finalize();
    for (updates.items) |u| {
        ustmt.reset();
        try ustmt.bindText(1, u.blob);
        try ustmt.bindText(2, u.id);
        _ = try ustmt.step();
        // Self-verify the write LANDED: a unique-`id`-keyed UPDATE must affect exactly one
        // row. Zero rows means the row vanished or the id didn't match — the rewrite did not
        // persist, so fail closed rather than over-report a "rewrapped" cell that is still at
        // the old generation (which would become unreadable once the old key is dropped).
        // `changesCount` is `sqlite3_changes64` / the PG CommandComplete row count — exactly 1
        // for a normal keyed single-row UPDATE on both backends.
        if (w.changesCount() != 1) {
            if (failure) |fp| fp.* = .{ .table = table, .column = col, .id = u.id, .version = cipher.primary_gen };
            return error.RewrapWriteFailed;
        }
    }
    return stats;
}

/// Rewrap every `.encrypted` field of every collection in `_collections`. Each
/// collection's columns are rewrapped inside a single transaction (rolled back on
/// any failure). Progress is logged per column. `dry_run` performs every decrypt
/// (so a missing generation still surfaces) but writes nothing.
pub fn rewrapAll(
    allocator: std.mem.Allocator,
    w: *db.Db,
    cipher: *const field_policy.Cipher,
    dry_run: bool,
) Error!Stats {
    var stats = Stats{};
    var list_arena = std.heap.ArenaAllocator.init(allocator);
    defer list_arena.deinit();
    const cols = collections.list(list_arena.allocator(), w) catch |e| {
        std.log.err("rewrap: could not list collections: {s}", .{@errorName(e)});
        return e;
    };

    for (cols) |c| {
        var has_enc = false;
        for (c.fields) |f| {
            if (f.encrypted) {
                has_enc = true;
                break;
            }
        }
        if (!has_enc) continue;
        stats.collections += 1;

        if (!dry_run) try w.beginImmediate();
        errdefer if (!dry_run) {
            w.rollback() catch {};
        };

        for (c.fields) |f| {
            if (!f.encrypted) continue;
            stats.fields += 1;
            var col_arena = std.heap.ArenaAllocator.init(allocator);
            defer col_arena.deinit();
            var failure: Failure = .{};
            const cs = rewrapColumn(col_arena.allocator(), w, cipher, c.name, f.name, dry_run, &failure) catch |e| {
                switch (e) {
                    error.RewrapDecryptFailed => {
                        std.log.err(
                            "rewrap: cannot decrypt {s}.{s} id={s} (envelope v{d}: missing generation key, wrong key, or tampered) — aborting, no rows changed in this collection",
                            .{ failure.table, failure.column, failure.id, failure.version },
                        );
                        std.log.err(
                            "rewrap: configure the missing generation key (ZIGBASE_FIELD_KEY_V{d}) and re-run — rewrap is idempotent, so already-committed collections are not redone",
                            .{failure.version},
                        );
                    },
                    error.RewrapRowUnkeyed => std.log.err(
                        "rewrap: {s}.{s} has a row with an empty/NULL id — cannot safely re-key it; fix the row's id before rewrapping (aborting, no rows changed in this collection)",
                        .{ failure.table, failure.column },
                    ),
                    error.RewrapWriteFailed => std.log.err(
                        "rewrap: {s}.{s} id={s}: keyed UPDATE matched no row (row vanished or id mismatch) — aborting, no rows changed in this collection",
                        .{ failure.table, failure.column, failure.id },
                    ),
                    else => {},
                }
                return e;
            };
            stats.rewrapped += cs.rewrapped;
            stats.plaintext_migrated += cs.plaintext_migrated;
            stats.skipped += cs.skipped;
            std.log.info(
                "rewrap: {s}.{s}: {d} re-encrypted, {d} plaintext migrated, {d} already current{s}",
                .{ c.name, f.name, cs.rewrapped, cs.plaintext_migrated, cs.skipped, if (dry_run) " (dry-run)" else "" },
            );
        }

        if (!dry_run) try w.commit();
    }
    return stats;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const MapGetter = struct {
    pairs: []const [2][]const u8,
    pub fn get(self: MapGetter, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], key)) return p[1];
        return null;
    }
};

/// Build a rotated key-ring: primary generation 2 ("newkey"), generation 1
/// ("oldkey") available read-only.
fn rotatedRing() field_policy.Cipher {
    const getter = MapGetter{ .pairs = &.{.{ "ZIGBASE_FIELD_KEY_V1", "oldkey" }} };
    return field_policy.Cipher.resolve(std.testing.io, getter, "newkey", 2) catch unreachable;
}

fn cellText(a: std.mem.Allocator, d: *db.Db, table: [:0]const u8, id: []const u8) ![]u8 {
    // Bind `id` (defense-in-depth; never interpolate even a DB-sourced value) and route the
    // placeholder through the dialect renumber like production rewrap does.
    const tmpl = try std.fmt.allocPrint(a, "SELECT v FROM {s} WHERE \"id\"=?1;", .{table});
    const sql = try db.dbDialect(d).renumberPlaceholders(a, tmpl);
    var s = try d.prepare(sql);
    defer s.finalize();
    try s.bindText(1, id);
    if (!try s.step()) return error.RowNotFound;
    return a.dupe(u8, s.columnText(0));
}

test "rewrapColumn: v1 envelope re-encrypted to primary (v2) and still decrypts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE t (id TEXT PRIMARY KEY, v TEXT);");

    // Seed a v1: cell written by the old single-key build.
    const old = field_policy.Cipher.fromEnv(std.testing.io, "oldkey");
    const v1 = try old.seal(a, "the-secret");
    var ins = try d.prepare("INSERT INTO t (id, v) VALUES ('r1', ?1);");
    try ins.bindText(1, v1);
    _ = try ins.step();
    ins.finalize();

    const ring = rotatedRing();
    const cs = try rewrapColumn(a, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 1), cs.rewrapped);
    try std.testing.expectEqual(@as(usize, 0), cs.plaintext_migrated);

    // At rest the cell is now a v2: envelope (version bumped, plaintext absent)…
    const after = try cellText(a, &d, "t", "r1");
    try std.testing.expect(std.mem.startsWith(u8, after, "v2:"));
    try std.testing.expect(std.mem.indexOf(u8, after, "the-secret") == null);
    // …and decrypts under the primary generation.
    try std.testing.expectEqualStrings("the-secret", try ring.open(a, after));
}

test "rewrapColumn: legacy plaintext migrated into a v2 envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE t (id TEXT PRIMARY KEY, v TEXT);");
    try d.exec("INSERT INTO t (id, v) VALUES ('r1', 'plain-text-value');");

    const ring = rotatedRing();
    const cs = try rewrapColumn(a, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 1), cs.plaintext_migrated);
    try std.testing.expectEqual(@as(usize, 0), cs.rewrapped);

    const after = try cellText(a, &d, "t", "r1");
    try std.testing.expect(std.mem.startsWith(u8, after, "v2:"));
    try std.testing.expect(std.mem.indexOf(u8, after, "plain-text-value") == null);
    try std.testing.expectEqualStrings("plain-text-value", try ring.open(a, after));
}

test "rewrapColumn is idempotent: a second pass skips everything" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE t (id TEXT PRIMARY KEY, v TEXT);");
    try d.exec("INSERT INTO t (id, v) VALUES ('r1', 'one');");
    const old = field_policy.Cipher.fromEnv(std.testing.io, "oldkey");
    var ins = try d.prepare("INSERT INTO t (id, v) VALUES ('r2', ?1);");
    try ins.bindText(1, try old.seal(a, "two"));
    _ = try ins.step();
    ins.finalize();

    const ring = rotatedRing();
    const first = try rewrapColumn(a, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 2), first.rewrapped + first.plaintext_migrated);

    const second = try rewrapColumn(a, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 2), second.skipped);
    try std.testing.expectEqual(@as(usize, 0), second.rewrapped);
    try std.testing.expectEqual(@as(usize, 0), second.plaintext_migrated);
}

test "rewrapColumn no-op path: all cells already primary -> nothing written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE t (id TEXT PRIMARY KEY, v TEXT);");

    // Seed two cells already at the primary generation (v2).
    const ring = rotatedRing();
    var ins = try d.prepare("INSERT INTO t (id, v) VALUES (?1, ?2);");
    try ins.bindText(1, "r1");
    try ins.bindText(2, try ring.seal(a, "alpha"));
    _ = try ins.step();
    ins.reset();
    try ins.bindText(1, "r2");
    try ins.bindText(2, try ring.seal(a, "beta"));
    _ = try ins.step();
    ins.finalize();

    // Capture the exact at-rest bytes so we can assert no UPDATE ran (no re-seal,
    // which would change the nonce/ciphertext even though the version stays v2).
    const before0 = try cellText(a, &d, "t", "r1");
    const before1 = try cellText(a, &d, "t", "r2");

    const cs = try rewrapColumn(a, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 2), cs.skipped);
    try std.testing.expectEqual(@as(usize, 0), cs.rewrapped + cs.plaintext_migrated);
    try std.testing.expectEqualStrings(before0, try cellText(a, &d, "t", "r1"));
    try std.testing.expectEqualStrings(before1, try cellText(a, &d, "t", "r2"));
}

test "rewrapColumn fails closed on an unknown generation (no rows changed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE t (id TEXT PRIMARY KEY, v TEXT);");

    // A v1 cell, but the ring (primary v2) has NO generation-1 key.
    const old = field_policy.Cipher.fromEnv(std.testing.io, "oldkey");
    var ins = try d.prepare("INSERT INTO t (id, v) VALUES ('r1', ?1);");
    try ins.bindText(1, try old.seal(a, "unreadable"));
    _ = try ins.step();
    ins.finalize();

    const getter = MapGetter{ .pairs = &.{} };
    const ring = try field_policy.Cipher.resolve(std.testing.io, getter, "newkey", 2);
    try std.testing.expectError(error.RewrapDecryptFailed, rewrapColumn(a, &d, &ring, "t", "v", false, null));

    // The cell is untouched (still the original v1 envelope) — no data loss.
    const after = try cellText(a, &d, "t", "r1");
    try std.testing.expect(std.mem.startsWith(u8, after, "v1:"));
}

test "rewrapColumn fails closed on a row with a NULL/empty id (no silent data loss)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    // SQLite permits NULL in a `TEXT PRIMARY KEY`; seed a row whose id is NULL but whose cell
    // is a legitimate older-generation envelope that WOULD otherwise be rewrapped.
    try d.exec("CREATE TABLE t (id TEXT PRIMARY KEY, v TEXT);");
    const old = field_policy.Cipher.fromEnv(std.testing.io, "oldkey");
    var ins = try d.prepare("INSERT INTO t (id, v) VALUES (NULL, ?1);");
    try ins.bindText(1, try old.seal(a, "stranded"));
    _ = try ins.step();
    ins.finalize();

    // The keyed UPDATE could never match this row, so rewrap must NOT report success — it
    // fails closed (RewrapRowUnkeyed) before counting or writing anything.
    const ring = rotatedRing();
    var failure: Failure = .{};
    try std.testing.expectError(error.RewrapRowUnkeyed, rewrapColumn(a, &d, &ring, "t", "v", false, &failure));
    try std.testing.expectEqualStrings("", failure.id);

    // The cell is untouched (still the original v1 envelope) — no data loss, no over-report.
    var sel = try d.prepare("SELECT v FROM t;");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expect(std.mem.startsWith(u8, sel.columnText(0), "v1:"));
}

test "rewrapColumn dry-run reports but writes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE t (id TEXT PRIMARY KEY, v TEXT);");
    try d.exec("INSERT INTO t (id, v) VALUES ('r1', 'plain');");

    const ring = rotatedRing();
    const cs = try rewrapColumn(a, &d, &ring, "t", "v", true, null);
    try std.testing.expectEqual(@as(usize, 1), cs.plaintext_migrated);
    // Dry-run: the cell is still plaintext on disk.
    const after = try cellText(a, &d, "t", "r1");
    try std.testing.expectEqualStrings("plain", after);
}

test "rewrapAll: end-to-end over the collections store" {
    const migrations = @import("migrations.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);

    // A collection with an encrypted text field.
    const def = schema.Collection{
        .id = "",
        .name = "secrets",
        .fields = &.{.{ .id = "", .name = "body", .encrypted = true, .options = .{ .text = .{} } }},
    };
    _ = try collections.create(a, std.testing.io, &d, def);

    // Seed two v1: rows (as the old single-key build would have) directly via SQL.
    const old = field_policy.Cipher.fromEnv(std.testing.io, "oldkey");
    var ins = try d.prepare("INSERT INTO \"secrets\" (\"id\",\"body\") VALUES (?1, ?2);");
    try ins.bindText(1, "rec1");
    try ins.bindText(2, try old.seal(a, "alpha"));
    _ = try ins.step();
    ins.reset();
    try ins.bindText(1, "rec2");
    try ins.bindText(2, try old.seal(a, "beta"));
    _ = try ins.step();
    ins.finalize();

    const ring = rotatedRing();
    const stats = try rewrapAll(std.testing.allocator, &d, &ring, false);
    try std.testing.expectEqual(@as(usize, 1), stats.collections);
    try std.testing.expectEqual(@as(usize, 1), stats.fields);
    try std.testing.expectEqual(@as(usize, 2), stats.rewrapped);

    // Both rows are now v2: and decrypt to their originals.
    var sel = try d.prepare("SELECT \"id\",\"body\" FROM \"secrets\" ORDER BY \"id\";");
    defer sel.finalize();
    _ = try sel.step();
    try std.testing.expect(std.mem.startsWith(u8, sel.columnText(1), "v2:"));
    try std.testing.expectEqualStrings("alpha", try ring.open(a, try a.dupe(u8, sel.columnText(1))));
}
