//! Live-PostgreSQL schema/DDL + migration parity tests (issue #159, PR-2). These run only under
//! `-Dpostgres=true` (gated from `root.zig`) and require a reachable PostgreSQL — they read
//! `ZIGBASE_PG_TEST_URL` and SKIP when none is configured, exactly like the driver's own live
//! tests. CI's `postgres` job points them at its service container so they actually execute.
//!
//! Isolation: each test runs inside a freshly created, per-test SCHEMA (`SET search_path`) which
//! is dropped CASCADE on teardown, so the non-TEMP system tables (`_migrations`, `_collections`,
//! …) never collide across tests or runs without needing N databases.

const std = @import("std");
const db = @import("../../db.zig");
const migrations = @import("../../migrations.zig");
const provision = @import("../../provision.zig");
const schema = @import("../../schema.zig");
const ddl = @import("../../ddl.zig");

fn testUrlZ() ?[:0]const u8 {
    return std.testing.environ.getPosix("ZIGBASE_PG_TEST_URL");
}

/// Open a live PG `db.Db` on a private, freshly created schema, or null to skip. The returned
/// `Ctx` must be `deinit`'d (drops the schema + closes the connection).
const Ctx = struct {
    conn: db.Db,
    drop_sql: [:0]const u8,

    fn open(a: std.mem.Allocator, io: std.Io, comptime tag: []const u8) !?Ctx {
        const url = testUrlZ() orelse return null;
        var conn = db.Db.openPostgres(a, io, url) catch return null;
        errdefer conn.close();
        const sn = "zb_pr2_" ++ tag;
        // Fresh, empty namespace for this test (drop a stale one from a crashed prior run first).
        try conn.exec("DROP SCHEMA IF EXISTS " ++ sn ++ " CASCADE;");
        try conn.exec("CREATE SCHEMA " ++ sn ++ ";");
        try conn.exec("SET search_path TO " ++ sn ++ ";");
        return Ctx{ .conn = conn, .drop_sql = "DROP SCHEMA IF EXISTS " ++ sn ++ " CASCADE;" };
    }

    fn deinit(self: *Ctx) void {
        self.conn.exec(self.drop_sql) catch {};
        self.conn.close();
    }

    fn w(self: *Ctx) *db.Db {
        return &self.conn;
    }
};

/// COUNT(*) of a no-parameter aggregate query (helper for the assertions below).
fn scalarCount(w: *db.Db, sql: [:0]const u8) !i64 {
    var st = try w.prepare(sql);
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

test "pg: all 16 system migrations apply on a fresh database (tables + seeds + ledger)" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "mig")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();

    try migrations.run(w);
    // Idempotent: a second run is a clean no-op (the ledger guard + ON CONFLICT seeds).
    try migrations.run(w);

    // The ledger recorded exactly the 16 system migrations.
    try std.testing.expectEqual(@as(i64, migrations.all.len), try scalarCount(w,
        "SELECT count(*) FROM \"_migrations\";"));

    // Every system table provisioned (information_schema is the portable catalog).
    inline for (.{
        "_collections", "_superusers",       "_externalAuths",  "_consumedTokens",
        "_oauthStates", "_cursorStates",      "_authChallenges", "_webauthnCredentials",
        "_kv",          "_sessions",          "_experiment_assignments", "_queue_jobs",
        "_accounts",    "_memberships",       "_invitations",    "_events",
        "_sender_identities", "_suppressions",
    }) |t| {
        const n = try scalarCount(w,
            "SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = '" ++ t ++ "';");
        if (n != 1) {
            std.log.err("pg migration: expected table '{s}' to exist", .{t});
            return error.TestUnexpectedResult;
        }
    }

    // Seeds landed: _superusers + the tenancy/email/events system collections.
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w,
        "SELECT count(*) FROM \"_collections\" WHERE name='_superusers' AND system=1;"));
    try std.testing.expectEqual(@as(i64, 6), try scalarCount(w,
        "SELECT count(*) FROM \"_collections\" WHERE name IN " ++
        "('_accounts','_memberships','_invitations','_events','_sender_identities','_suppressions') AND system=1;"));

    // token_epoch identity column (0010) is BIGINT on PG and reads back 0 by default.
    try w.exec("INSERT INTO \"_superusers\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('s1','','','a@b.c');");
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(w,
        "SELECT token_epoch FROM \"_superusers\" WHERE id='s1';"));

    // A UNIQUE constraint from a migration index actually enforces on PG (0014 slug).
    try w.exec("INSERT INTO \"_accounts\" (\"id\",\"created\",\"updated\",\"slug\") VALUES ('a1','','','acme');");
    try std.testing.expectError(error.ExecFailed, w.exec(
        "INSERT INTO \"_accounts\" (\"id\",\"created\",\"updated\",\"slug\") VALUES ('a2','','','acme');"));
}

test "pg: full comptime schema provisions on a fresh database" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "prov")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();

    try migrations.run(w);

    // A representative comptime schema: a base collection (text/number/bool fields + an index),
    // an auth collection (identity uniqueness via a partial unique index), and a relation FK.
    const specs = comptime provision.buildCollections(.{
        .authors = .{ .type = .auth, .fields = .{
            .{ .name = "bio", .type = .text },
        } },
        .posts = .{ .fields = .{
            .{ .name = "title", .type = .text },
            .{ .name = "views", .type = .number },
            .{ .name = "published", .type = .@"bool" },
            .{ .name = "author", .type = .relation, .target = "authors", .maxSelect = 1 },
        }, .indexes = .{
            .{ .name = "idx_posts_title", .fields = .{"title"} },
        } },
    });
    try provision.applySpecs(a, std.testing.io, w, specs);
    // Idempotent second pass.
    try provision.applySpecs(a, std.testing.io, w, specs);

    // The physical tables + the _collections metadata rows exist.
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w,
        "SELECT count(*) FROM information_schema.tables WHERE table_schema=current_schema() AND table_name='posts';"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w,
        "SELECT count(*) FROM information_schema.tables WHERE table_schema=current_schema() AND table_name='authors';"));
    try std.testing.expectEqual(@as(i64, 2), try scalarCount(w,
        "SELECT count(*) FROM \"_collections\" WHERE name IN ('posts','authors');"));

    // The number field is BIGINT and the bool field is integer storage (0/1) — both insertable.
    try w.exec("INSERT INTO \"authors\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('au1','','','a@x.io');");
    try w.exec("INSERT INTO \"posts\" (\"id\",\"created\",\"updated\",\"title\",\"views\",\"published\",\"author\") " ++
        "VALUES ('p1','','','hello',42,1,'au1');");
    try std.testing.expectEqual(@as(i64, 42), try scalarCount(w, "SELECT views FROM \"posts\" WHERE id='p1';"));

    // The relation FK enforces: deleting the referenced author SET NULLs the post's author.
    try w.exec("DELETE FROM \"authors\" WHERE id='au1';");
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w,
        "SELECT count(*) FROM \"posts\" WHERE id='p1' AND author IS NULL;"));
}

test "pg: additive field-add rebuild (ALTER) preserves existing data" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "rebuild")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();

    try migrations.run(w);

    // v1: posts(title). Seed a row.
    const v1 = comptime provision.buildCollections(.{
        .posts = .{ .fields = .{.{ .name = "title", .type = .text }} },
    });
    try provision.applySpecs(a, std.testing.io, w, v1);
    try w.exec("INSERT INTO \"posts\" (\"id\",\"created\",\"updated\",\"title\") VALUES ('r1','t','t','hello');");

    // v2: posts(title, views) — an additive field-add. On PG this lowers to ALTER TABLE ADD COLUMN
    // (no table rebuild), so the existing row's data survives and the new column is NULL.
    const v2 = comptime provision.buildCollections(.{
        .posts = .{ .fields = .{
            .{ .name = "title", .type = .text },
            .{ .name = "views", .type = .number },
        } },
    });
    try provision.applySpecs(a, std.testing.io, w, v2);

    var st = try w.prepare("SELECT title, views FROM \"posts\" WHERE id='r1';");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("hello", st.columnText(0)); // preserved
    try std.testing.expect(st.isNull(1)); // new column defaults NULL
}

test "pg: provisioned TEXT columns order by byte value (COLLATE \"C\"), matching SQLite BINARY" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "collate")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();

    try migrations.run(w);
    const specs = comptime provision.buildCollections(.{
        .notes = .{ .fields = .{.{ .name = "label", .type = .text }} },
    });
    try provision.applySpecs(a, std.testing.io, w, specs);

    // The provisioned text columns carry an explicit "C" collation (locale-independent proof of the
    // DDL pin — this DB may itself be C.UTF-8, which would order by bytes anyway).
    {
        var cq = try w.prepare("SELECT collation_name FROM information_schema.columns " ++
            "WHERE table_schema=current_schema() AND table_name='notes' AND column_name IN ('id','label') AND collation_name='C';");
        defer cq.finalize();
        var pinned: usize = 0;
        while (try cq.step()) pinned += 1;
        try std.testing.expectEqual(@as(usize, 2), pinned); // both id + label pinned to COLLATE "C"
    }

    // 'B' (0x42) sorts BEFORE 'a' (0x61) in byte order, but AFTER it under a typical case-folding
    // locale collation. SQLite's default is BINARY (byte order), so cross-backend keyset/ORDER BY
    // determinism requires PG to agree — which COLLATE "C" on the provisioned column delivers.
    try w.exec("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"label\") VALUES ('n1','','','B');");
    try w.exec("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"label\") VALUES ('n2','','','a');");

    var st = try w.prepare("SELECT label FROM \"notes\" ORDER BY label ASC;");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("B", st.columnText(0)); // byte order: 'B' < 'a'
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("a", st.columnText(0));

    // The `id` keyset tiebreaker column is likewise byte-ordered: 'Z' (0x5A) < 'a' (0x61).
    try w.exec("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"label\") VALUES ('Zzz','','','x');");
    try w.exec("INSERT INTO \"notes\" (\"id\",\"created\",\"updated\",\"label\") VALUES ('aaa','','','x');");
    var idq = try w.prepare("SELECT id FROM \"notes\" WHERE label='x' ORDER BY id ASC;");
    defer idq.finalize();
    try std.testing.expect(try idq.step());
    try std.testing.expectEqualStrings("Zzz", idq.columnText(0)); // 'Z' < 'a' in byte order
}

test "pg: a consumer .nocase UNIQUE index provisions case-SENSITIVELY (warned weakening)" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "nocase")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();

    try migrations.run(w);
    // Provisioning logs a prominent std.log.warn for this .nocase index under PG (see
    // provision.warnNocaseIndexesUnderPg) — visible in the test output.
    const specs = comptime provision.buildCollections(.{
        .contacts = .{ .fields = .{.{ .name = "addr", .type = .text }}, .indexes = .{
            .{ .name = "idx_contacts_addr", .fields = .{"addr"}, .unique = true, .collation = .nocase },
        } },
    });
    try provision.applySpecs(a, std.testing.io, w, specs);

    // The .nocase-indexed column is left at the DB default collation (NOT pinned to "C"), so the
    // case-insensitive follow-up can take it over.
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(w,
        "SELECT count(*) FROM information_schema.columns WHERE table_schema=current_schema() " ++
        "AND table_name='contacts' AND column_name='addr' AND collation_name='C';"));

    // The known (warned, pre-GA follow-up) weakening: case-variant values are NOT deduped on PG,
    // because PG has no NOCASE collation yet — so both rows insert.
    try w.exec("INSERT INTO \"contacts\" (\"id\",\"created\",\"updated\",\"addr\") VALUES ('c1','','','Bob@x.com');");
    try w.exec("INSERT INTO \"contacts\" (\"id\",\"created\",\"updated\",\"addr\") VALUES ('c2','','','bob@x.com');");
    try std.testing.expectEqual(@as(i64, 2), try scalarCount(w, "SELECT count(*) FROM \"contacts\";"));
    // The exact-duplicate IS still rejected (the index is unique, just case-sensitive).
    try std.testing.expectError(error.ExecFailed, w.exec(
        "INSERT INTO \"contacts\" (\"id\",\"created\",\"updated\",\"addr\") VALUES ('c3','','','bob@x.com');"));
}
