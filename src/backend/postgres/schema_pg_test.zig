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

test "pg: auth convergence and updates retain main uniqueness" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "auth_unique_main")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);
    const collections = @import("../../collections.zig");
    const fields: []const schema.Field = &.{
        .{ .id = "accountid", .name = "account", .options = .{ .text = .{} } },
        .{ .id = "slugid", .name = "slug", .unique = true, .options = .{ .text = .{} } },
        .{ .id = "tagid", .name = "tag", .options = .{ .text = .{} } },
    };
    const old = try collections.create(a, std.testing.io, w, .{
        .id = "",
        .name = "members",
        .type = .auth,
        .fields = fields,
        .options = .{ .tenant_field = "account" },
    });
    defer old.deinit(a);
    try w.exec("INSERT INTO members(id,email,username,account,slug,tag) VALUES('a','a@example.com','same','one','first','same'),('b','b@example.com','same','two','second','same');");
    try collections.ensureUniqueScopes(a, std.testing.io, w, old.id);
    try collections.ensureAllUniqueScopes(a, std.testing.io, w);
    try std.testing.expectEqual(@as(i64, 3), try scalarCount(w, "SELECT count(*) FROM pg_indexes WHERE schemaname=current_schema() AND tablename='members';"));
    var changed = [_]schema.Field{ fields[0], fields[1], fields[2] };
    changed[1].unique = false;
    changed[2].unique = true;
    const updated = try collections.update(a, std.testing.io, w, old.id, .{
        .id = old.id,
        .name = old.name,
        .type = .auth,
        .fields = &changed,
        .options = .{ .tenant_field = "account", .auth = .{ .identityFields = &.{"slug"} } },
    });
    defer updated.deinit(a);
    // main's in-place PG update leaves existing field constraints and identity indexes
    // alone, and creates the newly configured identity index. Flag changes are metadata only.
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM pg_indexes WHERE schemaname=current_schema() AND indexname='idx_auth_members_email';"));
    try std.testing.expectEqual(@as(i64, 4), try scalarCount(w, "SELECT count(*) FROM pg_indexes WHERE schemaname=current_schema() AND tablename='members';"));
    try w.exec("INSERT INTO members(id,email,username,account,slug,tag) VALUES('c','c@example.com','same','three','third','same');");
    try std.testing.expectError(error.ExecFailed, w.exec("INSERT INTO members(id,email,slug) VALUES('d','a@example.com','fourth');"));
}

test "pg: changing identity preserves a newly declared matching unique index" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "declared_identity")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);
    const collections = @import("../../collections.zig");
    const fields: []const schema.Field = &.{.{ .id = "slugid", .name = "slug", .options = .{ .text = .{} } }};
    const old = try collections.create(a, std.testing.io, w, .{
        .id = "",
        .name = "slugs",
        .type = .auth,
        .fields = fields,
        .options = .{ .auth = .{ .identityFields = &.{"slug"} } },
    });
    defer old.deinit(a);
    const updated = try collections.update(a, std.testing.io, w, old.id, .{
        .id = old.id,
        .name = old.name,
        .type = .auth,
        .fields = fields,
        .options = .{ .auth = .{ .identityFields = &.{"email"} } },
        .indexes = &.{.{ .name = "idx_auth_slugs_slug", .fields = &.{"slug"}, .unique = true, .where = "\"slug\" != ''" }},
    });
    defer updated.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), updated.options.auth.identityFields.len);
    try std.testing.expectEqualStrings("email", updated.options.auth.identityFields[0]);
    try std.testing.expectEqual(@as(usize, 1), updated.indexes.len);
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM pg_indexes WHERE schemaname=current_schema() AND indexname='idx_auth_slugs_slug';"));
    try w.exec("INSERT INTO slugs(id,slug) VALUES('a','shared');");
    try std.testing.expectError(error.ExecFailed, w.exec("INSERT INTO slugs(id,slug) VALUES('b','shared');"));
    try w.exec("INSERT INTO slugs(id,slug) VALUES('c',''),('d','');");
}

test "pg: auth rename rotates all principal tokens with bounded bindings" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "rename_auth_tokens")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);
    const collections = @import("../../collections.zig");
    const old = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "users", .type = .auth, .fields = &.{} });
    defer old.deinit(a);
    try w.exec("INSERT INTO users(id,\"tokenKey\",token_epoch) SELECT 'u'||n::text,'old',0 FROM generate_series(1,777) n;");
    try @import("../../collection_rename.zig").rename(a, std.testing.io, w, "users", "people");
    try std.testing.expectEqual(@as(i64, 777), try scalarCount(w, "SELECT count(*) FROM people WHERE length(\"tokenKey\")=32 AND \"tokenKey\"<>'old' AND token_epoch=1;"));
    try std.testing.expectEqual(@as(i64, 777), try scalarCount(w, "SELECT count(DISTINCT \"tokenKey\") FROM people;"));
}

test "pg: offline rename rejects dangling destination relation metadata" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "rename_dangling_metadata")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);
    const collections = @import("../../collections.zig");
    const old = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "posts", .fields = &.{} });
    defer old.deinit(a);
    try w.exec("UPDATE _collections SET schema='[{\"id\":\"targetid\",\"name\":\"target\",\"type\":\"relation\",\"options\":{\"targetCollectionId\":\"articles\",\"maxSelect\":1}}]' WHERE name='posts';");
    const gen = @import("../../schema_gen.zig");
    const before = try gen.read(w);
    try std.testing.expectError(error.Conflict, @import("../../collection_rename.zig").rename(a, std.testing.io, w, "posts", "articles"));
    try std.testing.expectEqual(before, try gen.read(w));
    try std.testing.expect(!w.inTransaction());
    try std.testing.expect((try collections.getByName(a, w, "articles")) == null);
    const unchanged = (try collections.getByName(a, w, "posts")).?;
    defer unchanged.deinit(a);
    try std.testing.expectEqual(@as(i64, 0), unchanged.rename_epoch);
    try std.testing.expectEqualStrings("articles", unchanged.fields[0].options.relation.targetCollectionId);
    try w.exec("INSERT INTO posts(id) VALUES ('still_posts');");
}

test "pg: offline collection rename preserves relations search and caller rollback" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "rename")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);
    const collections = @import("../../collections.zig");
    const fields = [_]schema.Field{.{ .id = "title_id", .name = "title", .searchable = true, .options = .{ .text = .{} } }};
    const old = try collections.create(a, std.testing.io, w, .{ .id = "", .name = "posts", .fields = &fields });
    defer old.deinit(a);
    try @import("../../search/fts.zig").ensureIndex(a, w, old);
    try w.exec("CREATE TABLE comments(id TEXT PRIMARY KEY, parent TEXT REFERENCES posts(id));");
    try w.exec("INSERT INTO posts(id,title) VALUES ('r1','before');");
    try w.exec("INSERT INTO comments(id,parent) VALUES ('c1','r1');");
    try @import("../../collection_rename.zig").rename(a, std.testing.io, w, "posts", "articles");
    const renamed = (try collections.get(a, w, "articles")).?;
    defer renamed.deinit(a);
    try std.testing.expectEqualStrings(old.id, renamed.id);
    try std.testing.expectEqualStrings("title_id", renamed.fields[0].id);
    try w.exec("UPDATE articles SET title='after' WHERE id='r1';");
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT COUNT(*) FROM articles WHERE articles_fts @@ plainto_tsquery('simple','after');"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT COUNT(*) FROM articles JOIN comments ON articles.id=comments.parent;"));
    try w.begin();
    try @import("../../collection_rename.zig").rename(a, std.testing.io, w, "articles", "stories");
    try w.rollback();
    try std.testing.expect((try collections.get(a, w, "stories")) == null);
    const restored = (try collections.get(a, w, "articles")).?;
    defer restored.deinit(a);
    try std.testing.expectEqualStrings(old.id, restored.id);
}

test "pg: all system migrations apply on a fresh database (tables + seeds + ledger)" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "mig")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();

    try migrations.run(w);
    // Idempotent: a second run is a clean no-op (the ledger guard + ON CONFLICT seeds).
    try migrations.run(w);

    // The ledger recorded exactly the full set of system migrations.
    try std.testing.expectEqual(@as(i64, migrations.all.len), try scalarCount(w, "SELECT count(*) FROM \"_migrations\";"));

    // Every system table provisioned (information_schema is the portable catalog).
    inline for (.{
        "_collections",       "_superusers",   "_externalAuths",          "_consumedTokens",
        "_oauthStates",       "_cursorStates", "_authChallenges",         "_webauthnCredentials",
        "_kv",                "_sessions",     "_experiment_assignments", "_queue_jobs",
        "_accounts",          "_memberships",  "_invitations",            "_events",
        "_sender_identities", "_suppressions", "_mail_batches",           "_mail_batch_recipients",
    }) |t| {
        const n = try scalarCount(w, "SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = '" ++ t ++ "';");
        if (n != 1) {
            std.log.err("pg migration: expected table '{s}' to exist", .{t});
            return error.TestUnexpectedResult;
        }
    }

    // Seeds landed: _superusers + the tenancy/email/events/bulk-mail system collections.
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM \"_collections\" WHERE name='_superusers' AND system=1;"));
    try std.testing.expectEqual(@as(i64, 8), try scalarCount(w, "SELECT count(*) FROM \"_collections\" WHERE name IN " ++
        "('_accounts','_memberships','_invitations','_events','_sender_identities','_suppressions'," ++
        "'_mail_batches','_mail_batch_recipients') AND system=1;"));

    // token_epoch identity column (0010) is BIGINT on PG and reads back 0 by default.
    try w.exec("INSERT INTO \"_superusers\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('s1','','','a@b.c');");
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(w, "SELECT token_epoch FROM \"_superusers\" WHERE id='s1';"));

    // A UNIQUE constraint from a migration index actually enforces on PG (0014 slug).
    try w.exec("INSERT INTO \"_accounts\" (\"id\",\"created\",\"updated\",\"slug\") VALUES ('a1','','','acme');");
    try std.testing.expectError(error.ExecFailed, w.exec("INSERT INTO \"_accounts\" (\"id\",\"created\",\"updated\",\"slug\") VALUES ('a2','','','acme');"));
}

test "pg: index-only provisioning replaces constraints atomically and preserves external indexes" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "index_only")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);
    const fields = [_]schema.Field{.{ .id = "title_id", .name = "title", .options = .{ .text = .{} } }};
    var specs = [_]schema.Collection{.{ .id = "", .name = "posts", .fields = &fields }};
    try provision.applySpecs(a, std.testing.io, w, &specs);
    try w.exec("CREATE INDEX migration_owned ON posts(created);");
    try w.exec("INSERT INTO posts(id,title) VALUES ('p1','same'),('p2','same');");
    specs[0].indexes = &.{.{ .name = "idx_title", .fields = &.{"title"} }};
    try w.exec("CREATE INDEX idx_title ON posts(title);"); // prior migration workaround
    try provision.applySpecs(a, std.testing.io, w, &specs);
    const generation = try @import("../../schema_gen.zig").read(w);
    try provision.applySpecs(a, std.testing.io, w, &specs);
    try std.testing.expectEqual(generation, try @import("../../schema_gen.zig").read(w));
    specs[0].indexes = &.{.{ .name = "idx_title", .fields = &.{"title"}, .unique = true }};
    try std.testing.expectError(error.ExecFailed, provision.applySpecs(a, std.testing.io, w, &specs));
    try std.testing.expectEqual(generation, try @import("../../schema_gen.zig").read(w));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM pg_indexes WHERE schemaname=current_schema() AND indexname='idx_title' AND indexdef NOT LIKE '%UNIQUE%';"));
    try w.exec("DELETE FROM posts WHERE id='p2';");
    try provision.applySpecs(a, std.testing.io, w, &specs);
    try std.testing.expectError(error.ExecFailed, w.exec("INSERT INTO posts(id,title) VALUES ('p3','same');"));
    specs[0].indexes = &.{};
    try provision.applySpecs(a, std.testing.io, w, &specs);
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM pg_indexes WHERE schemaname=current_schema() AND indexname='migration_owned';"));
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(w, "SELECT count(*) FROM pg_indexes WHERE schemaname=current_schema() AND indexname='idx_title';"));
    specs[0].indexes = &.{.{ .name = "migration_owned", .fields = &.{"title"} }};
    try std.testing.expectError(error.ExecFailed, provision.applySpecs(a, std.testing.io, w, &specs));
    try w.exec("CREATE INDEX partial_title ON posts(title) WHERE title != ''; CREATE INDEX desc_title ON posts(title DESC);");
    specs[0].indexes = &.{.{ .name = "partial_title", .fields = &.{"title"} }};
    try std.testing.expectError(error.ExecFailed, provision.applySpecs(a, std.testing.io, w, &specs));
    specs[0].indexes = &.{.{ .name = "desc_title", .fields = &.{"title"} }};
    try std.testing.expectError(error.ExecFailed, provision.applySpecs(a, std.testing.io, w, &specs));
    try w.exec("CREATE INDEX pattern_title ON posts(title text_pattern_ops); CREATE INDEX case_title ON posts(lower(title));");
    specs[0].indexes = &.{.{ .name = "pattern_title", .fields = &.{"title"} }};
    try std.testing.expectError(error.ExecFailed, provision.applySpecs(a, std.testing.io, w, &specs));
    specs[0].indexes = &.{.{ .name = "case_title", .fields = &.{"title"}, .collation = .nocase }};
    try provision.applySpecs(a, std.testing.io, w, &specs);
    if (try scalarCount(w, "SELECT current_setting('server_version_num')::bigint;") >= 150000) {
        try w.exec("DELETE FROM posts WHERE id='p3'; CREATE UNIQUE INDEX null_title ON posts(title) NULLS NOT DISTINCT;");
        const before_nulls = try @import("../../schema_gen.zig").read(w);
        specs[0].indexes = &.{.{ .name = "null_title", .fields = &.{"title"}, .unique = true }};
        try std.testing.expectError(error.ExecFailed, provision.applySpecs(a, std.testing.io, w, &specs));
        try std.testing.expectEqual(before_nulls, try @import("../../schema_gen.zig").read(w));
        try w.exec("INSERT INTO posts(id,title) VALUES ('null1',NULL);");
        try std.testing.expectError(error.ExecFailed, w.exec("INSERT INTO posts(id,title) VALUES ('null2',NULL);"));
        // The refused adoption neither deletes the external constraint nor commits
        // the earlier planned removal of the metadata-owned case-insensitive index.
        try std.testing.expectEqual(@as(i64, 2), try scalarCount(w, "SELECT count(*) FROM pg_indexes WHERE schemaname=current_schema() AND indexname IN ('case_title','null_title');"));
    }
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
            .{ .name = "published", .type = .bool },
            .{ .name = "author", .type = .relation, .target = "authors", .maxSelect = 1 },
        }, .indexes = .{
            .{ .name = "idx_posts_title", .fields = .{"title"} },
        } },
    });
    try provision.applySpecs(a, std.testing.io, w, specs);
    // Idempotent second pass.
    try provision.applySpecs(a, std.testing.io, w, specs);

    // The physical tables + the _collections metadata rows exist.
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM information_schema.tables WHERE table_schema=current_schema() AND table_name='posts';"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM information_schema.tables WHERE table_schema=current_schema() AND table_name='authors';"));
    try std.testing.expectEqual(@as(i64, 2), try scalarCount(w, "SELECT count(*) FROM \"_collections\" WHERE name IN ('posts','authors');"));

    // The number field is BIGINT and the bool field is integer storage (0/1) — both insertable.
    try w.exec("INSERT INTO \"authors\" (\"id\",\"created\",\"updated\",\"email\") VALUES ('au1','','','a@x.io');");
    try w.exec("INSERT INTO \"posts\" (\"id\",\"created\",\"updated\",\"title\",\"views\",\"published\",\"author\") " ++
        "VALUES ('p1','','','hello',42,1,'au1');");
    try std.testing.expectEqual(@as(i64, 42), try scalarCount(w, "SELECT views FROM \"posts\" WHERE id='p1';"));

    // The relation FK enforces: deleting the referenced author SET NULLs the post's author.
    try w.exec("DELETE FROM \"authors\" WHERE id='au1';");
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM \"posts\" WHERE id='p1' AND author IS NULL;"));
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

test "pg: a consumer .nocase UNIQUE index provisions case-INSENSITIVELY via lower() (#159)" {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "nocase")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();

    try migrations.run(w);
    const specs = comptime provision.buildCollections(.{
        .contacts = .{ .fields = .{.{ .name = "addr", .type = .text }}, .indexes = .{
            .{ .name = "idx_contacts_addr", .fields = .{"addr"}, .unique = true, .collation = .nocase },
        } },
    });
    try provision.applySpecs(a, std.testing.io, w, specs);

    // The .nocase index provisions as a `lower(addr)` FUNCTIONAL index (an expression index, so
    // it carries no column collation — the column itself stays at the DB default, NOT pinned "C").
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(w, "SELECT count(*) FROM information_schema.columns WHERE table_schema=current_schema() " ++
        "AND table_name='contacts' AND column_name='addr' AND collation_name='C';"));
    // A functional `lower()` index over `addr` really exists (pg_indexes records its definition).
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM pg_indexes WHERE schemaname=current_schema() AND tablename='contacts' " ++
        "AND indexname='idx_contacts_addr' AND indexdef ILIKE '%lower%';"));

    // PARITY (#159): case-variant values are now REJECTED — `Bob@x.com` then `bob@x.com` collide on
    // `lower(addr)`, exactly like SQLite's COLLATE NOCASE. Only the first row inserts.
    try w.exec("INSERT INTO \"contacts\" (\"id\",\"created\",\"updated\",\"addr\") VALUES ('c1','','','Bob@x.com');");
    try std.testing.expectError(error.ExecFailed, w.exec("INSERT INTO \"contacts\" (\"id\",\"created\",\"updated\",\"addr\") VALUES ('c2','','','bob@x.com');"));
    // The exact-duplicate is likewise rejected.
    try std.testing.expectError(error.ExecFailed, w.exec("INSERT INTO \"contacts\" (\"id\",\"created\",\"updated\",\"addr\") VALUES ('c3','','','Bob@x.com');"));
    try std.testing.expectEqual(@as(i64, 1), try scalarCount(w, "SELECT count(*) FROM \"contacts\";"));
}

test "pg: enabling unique over duplicates returns Constraint and rolls back" {
    try expectUniqueConflict(false);
}

test "pg: removing tenancy over cross-tenant duplicates returns Constraint and rolls back" {
    try expectUniqueConflict(true);
}

fn expectUniqueConflict(remove_tenancy: bool) !void {
    const a = std.testing.allocator;
    var ctx = (try Ctx.open(a, std.testing.io, "unique_conflict")) orelse return error.SkipZigTest;
    defer ctx.deinit();
    const w = ctx.w();
    try migrations.run(w);
    const collections = @import("../../collections.zig");
    var fields = [_]schema.Field{
        .{ .id = "accountid", .name = "account", .options = .{ .text = .{} } },
        .{ .id = "slugid", .name = "slug", .unique = remove_tenancy, .options = .{ .text = .{} } },
    };
    const old = try collections.create(a, std.testing.io, w, .{
        .id = "",
        .name = "conflict_slugs",
        .fields = &fields,
        .options = .{ .tenant_field = if (remove_tenancy) "account" else null },
    });
    defer old.deinit(a);
    try w.exec("INSERT INTO conflict_slugs(id,account,slug) VALUES('a','one','shared'),('b','two','shared');");
    const generation = try @import("../../schema_gen.zig").read(w);
    const constraints = try scalarCount(w, "SELECT count(*) FROM pg_constraint WHERE conrelid='conflict_slugs'::regclass AND contype='u';");
    fields[1].unique = true;
    // A preceding ADD COLUMN must also roll back on the later uniqueness violation.
    const changed = [_]schema.Field{ fields[0], fields[1], .{ .id = "extraid", .name = "extra", .options = .{ .text = .{} } } };
    try std.testing.expectError(error.Constraint, collections.update(a, std.testing.io, w, old.id, .{
        .id = old.id,
        .name = old.name,
        .fields = &changed,
    }));
    try std.testing.expect(!w.inTransaction());
    try std.testing.expectEqual(generation, try @import("../../schema_gen.zig").read(w));
    const unchanged = (try collections.get(a, w, old.id)).?;
    defer unchanged.deinit(a);
    try std.testing.expectEqual(remove_tenancy, schema.fieldByName(unchanged, "slug").?.unique);
    try std.testing.expectEqual(remove_tenancy, unchanged.options.tenant_field != null);
    try std.testing.expectEqual(constraints, try scalarCount(w, "SELECT count(*) FROM pg_constraint WHERE conrelid='conflict_slugs'::regclass AND contype='u';"));
    try std.testing.expectEqual(@as(i64, 0), try scalarCount(w, "SELECT count(*) FROM information_schema.columns WHERE table_schema=current_schema() AND table_name='conflict_slugs' AND column_name='extra';"));
    try std.testing.expectEqual(@as(i64, 2), try scalarCount(w, "SELECT count(*) FROM conflict_slugs WHERE slug='shared';"));
    // The connection remains usable and the original tenant scope still applies.
    try w.exec("INSERT INTO conflict_slugs(id,account,slug) VALUES('c','three','shared');");
}
