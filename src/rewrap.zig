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
// It works on RAW SQL cells (SELECT rowid, "<col>" / UPDATE … WHERE rowid=?),
// deliberately bypassing the value-layer strict decrypt so it can read mixed
// generations and legacy plaintext directly. Decryption uses the resolved
// key-ring (`field_policy.Cipher`): each cell is decrypted with the key of its
// own envelope version, then re-sealed under the primary generation.
//
// FAIL-CLOSED: a cell that cannot be decrypted (unknown/missing generation,
// wrong key, tamper) aborts the run with the offending row reported; the
// per-collection transaction is rolled back so no rows are partially changed and
// no data is lost. Idempotent: cells already at the primary version are skipped.
// ---------------------------------------------------------------------------

pub const Error = error{
    /// A stored cell could not be decrypted with the configured key generations.
    /// Details (collection.field rowid version) are logged before returning.
    RewrapDecryptFailed,
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

const Update = struct { rowid: i64, blob: []const u8 };

/// Details of the cell that triggered a fail-closed abort, filled into the
/// caller's out-param so the caller (not this leaf function) does the logging.
pub const Failure = struct {
    table: []const u8 = "",
    column: []const u8 = "",
    rowid: i64 = 0,
    version: u16 = 0,
};

/// Rewrap a single encrypted column. Reads every non-null cell, decrypts it by
/// its envelope version (or takes legacy plaintext as-is), re-seals under the
/// primary generation, and (unless `dry_run`) writes it back by rowid. All work
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

    const sel = try std.fmt.allocPrintSentinel(arena, "SELECT rowid, {s} FROM {s};", .{ cq, tq }, 0);
    var updates: std.ArrayList(Update) = .empty;

    var stmt = try w.prepare(sel);
    {
        defer stmt.finalize();
        while (try stmt.step()) {
            if (stmt.isNull(1)) continue;
            const rowid = stmt.columnInt(0);
            const stored = try arena.dupe(u8, stmt.columnText(1));
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
                    if (failure) |fp| fp.* = .{ .table = table, .column = col, .rowid = rowid, .version = ver.? };
                    return error.RewrapDecryptFailed;
                };
                stats.rewrapped += 1;
            } else {
                // Legacy plaintext: migrate it into ciphertext under the primary key.
                plaintext = stored;
                stats.plaintext_migrated += 1;
            }

            const blob = try cipher.seal(arena, plaintext);
            try updates.append(arena, .{ .rowid = rowid, .blob = blob });
        }
    }

    // Nothing to write: dry-run, or every cell was already at the primary version
    // (the common idempotent-rerun path). Skip preparing the UPDATE statement.
    if (dry_run or updates.items.len == 0) return stats;

    const upd = try std.fmt.allocPrintSentinel(arena, "UPDATE {s} SET {s}=?1 WHERE rowid=?2;", .{ tq, cq }, 0);
    var ustmt = try w.prepare(upd);
    defer ustmt.finalize();
    for (updates.items) |u| {
        ustmt.reset();
        try ustmt.bindText(1, u.blob);
        try ustmt.bindInt(2, u.rowid);
        _ = try ustmt.step();
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
                if (e == error.RewrapDecryptFailed) {
                    std.log.err(
                        "rewrap: cannot decrypt {s}.{s} rowid={d} (envelope v{d}: missing generation key, wrong key, or tampered) — aborting, no rows changed in this collection",
                        .{ failure.table, failure.column, failure.rowid, failure.version },
                    );
                    std.log.err(
                        "rewrap: configure the missing generation key (ZIGBASE_FIELD_KEY_V{d}) and re-run — rewrap is idempotent, so already-committed collections are not redone",
                        .{failure.version},
                    );
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

fn cellText(a: std.mem.Allocator, d: *db.Db, table: [:0]const u8, rowid: i64) ![]u8 {
    const sql = try std.fmt.allocPrintSentinel(a, "SELECT v FROM {s} WHERE rowid={d};", .{ table, rowid }, 0);
    var s = try d.prepare(sql);
    defer s.finalize();
    _ = try s.step();
    return a.dupe(u8, s.columnText(0));
}

test "rewrapColumn: v1 envelope re-encrypted to primary (v2) and still decrypts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE t (v TEXT);");

    // Seed a v1: cell written by the old single-key build.
    const old = field_policy.Cipher.fromEnv(std.testing.io, "oldkey");
    const v1 = try old.seal(a, "the-secret");
    var ins = try d.prepare("INSERT INTO t (v) VALUES (?1);");
    try ins.bindText(1, v1);
    _ = try ins.step();
    ins.finalize();

    const ring = rotatedRing();
    const cs = try rewrapColumn(a, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 1), cs.rewrapped);
    try std.testing.expectEqual(@as(usize, 0), cs.plaintext_migrated);

    // At rest the cell is now a v2: envelope (version bumped, plaintext absent)…
    const after = try cellText(a, &d, "t", 1);
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
    try d.exec("CREATE TABLE t (v TEXT);");
    try d.exec("INSERT INTO t (v) VALUES ('plain-text-value');");

    const ring = rotatedRing();
    const cs = try rewrapColumn(a, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 1), cs.plaintext_migrated);
    try std.testing.expectEqual(@as(usize, 0), cs.rewrapped);

    const after = try cellText(a, &d, "t", 1);
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
    try d.exec("CREATE TABLE t (v TEXT);");
    try d.exec("INSERT INTO t (v) VALUES ('one');");
    const old = field_policy.Cipher.fromEnv(std.testing.io, "oldkey");
    var ins = try d.prepare("INSERT INTO t (v) VALUES (?1);");
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
    try d.exec("CREATE TABLE t (v TEXT);");

    // Seed two cells already at the primary generation (v2).
    const ring = rotatedRing();
    var ins = try d.prepare("INSERT INTO t (v) VALUES (?1);");
    try ins.bindText(1, try ring.seal(a, "alpha"));
    _ = try ins.step();
    ins.reset();
    try ins.bindText(1, try ring.seal(a, "beta"));
    _ = try ins.step();
    ins.finalize();

    // Capture the exact at-rest bytes so we can assert no UPDATE ran (no re-seal,
    // which would change the nonce/ciphertext even though the version stays v2).
    const before0 = try cellText(a, &d, "t", 1);
    const before1 = try cellText(a, &d, "t", 2);

    const cs = try rewrapColumn(a, &d, &ring, "t", "v", false, null);
    try std.testing.expectEqual(@as(usize, 2), cs.skipped);
    try std.testing.expectEqual(@as(usize, 0), cs.rewrapped + cs.plaintext_migrated);
    try std.testing.expectEqualStrings(before0, try cellText(a, &d, "t", 1));
    try std.testing.expectEqualStrings(before1, try cellText(a, &d, "t", 2));
}

test "rewrapColumn fails closed on an unknown generation (no rows changed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE t (v TEXT);");

    // A v1 cell, but the ring (primary v2) has NO generation-1 key.
    const old = field_policy.Cipher.fromEnv(std.testing.io, "oldkey");
    var ins = try d.prepare("INSERT INTO t (v) VALUES (?1);");
    try ins.bindText(1, try old.seal(a, "unreadable"));
    _ = try ins.step();
    ins.finalize();

    const getter = MapGetter{ .pairs = &.{} };
    const ring = try field_policy.Cipher.resolve(std.testing.io, getter, "newkey", 2);
    try std.testing.expectError(error.RewrapDecryptFailed, rewrapColumn(a, &d, &ring, "t", "v", false, null));

    // The cell is untouched (still the original v1 envelope) — no data loss.
    const after = try cellText(a, &d, "t", 1);
    try std.testing.expect(std.mem.startsWith(u8, after, "v1:"));
}

test "rewrapColumn dry-run reports but writes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try db.Db.openMemory();
    defer d.close();
    try d.exec("CREATE TABLE t (v TEXT);");
    try d.exec("INSERT INTO t (v) VALUES ('plain');");

    const ring = rotatedRing();
    const cs = try rewrapColumn(a, &d, &ring, "t", "v", true, null);
    try std.testing.expectEqual(@as(usize, 1), cs.plaintext_migrated);
    // Dry-run: the cell is still plaintext on disk.
    const after = try cellText(a, &d, "t", 1);
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
