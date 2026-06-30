//! Live vector / nearest-neighbor search parity tests for the Postgres arm (issue #159, PR-11).
//! These exercise the pgvector `<=>`/`<->` KNN lowering END-TO-END against a real PostgreSQL behind
//! the SAME `?vector=` surface the SQLite sqlite-vec path uses: provision a collection with a JSON
//! embedding field, insert embeddings through the records layer, and run `records.list` KNN queries.
//! The CRITICAL access-control tests prove the KNN composes with the FULL authz stack — a
//! tenant-scoped / ability-scoped vector search returns ONLY rows the caller may view (a scalar
//! distance ORDER BY over the WHERE-filtered set, NOT a pre-WHERE k-NN that bounds rows before
//! scoping), identical to the SQLite chokepoint requirement.
//!
//! They run only under BOTH `-Dpostgres=true` AND `-Dvector=true`, and require a reachable
//! PostgreSQL that has the **pgvector** extension AVAILABLE (e.g. the `pgvector/pgvector:pgNN`
//! image). A `-Dvector=false` build skips (vector is comptime-disabled); a connectivity/auth failure
//! skips; a PG without pgvector installed skips (the `CREATE EXTENSION` fails). Connection string:
//! `ZIGBASE_PG_TEST_URL` if set, else the SCRAM+TLS default in `tests.zig`.
//!
//! Schema isolation: each test creates a throwaway `CREATE SCHEMA` + `SET search_path` (INCLUDING
//! `public` so the pgvector type/operators — installed into `public` — resolve), provisions its
//! table there, and `DROP SCHEMA … CASCADE`s on teardown.

const std = @import("std");
const dbm = @import("../../db.zig");
const records = @import("../../records.zig");
const collections = @import("../../collections.zig");
const migrations = @import("../../migrations.zig");
const schema = @import("../../schema.zig");
const vector = @import("../../search/vector.zig");
const request = @import("../../request.zig");
const abilities = @import("../../authz/abilities.zig");
const dialect_mod = @import("../../sql/dialect.zig");
const pgtests = @import("tests.zig");

const Dialect = dialect_mod.Dialect;

// ---- connection + schema plumbing (mirrors fts_pg_test.zig) ------------------

fn openOrSkip(a: std.mem.Allocator, io: std.Io) !?dbm.Db {
    return dbm.Db.openPostgres(a, io, pgtests.testUrl()) catch |e| switch (e) {
        error.OpenFailed => null,
        else => e,
    };
}

var schema_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Enter a throwaway schema. The search_path INCLUDES `public` so the pgvector `vector` type +
/// `<=>`/`<->` operators (installed into `public` by `CREATE EXTENSION`) resolve while the test's
/// own table lives in the (first, writable) temp schema.
fn enterTempSchema(a: std.mem.Allocator, d: *dbm.Db) ![:0]const u8 {
    const n = schema_counter.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(a, "zb_vec_{d}", .{n});
    try d.exec(try std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA \"{s}\";", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "SET search_path TO \"{s}\", public;", .{name}, 0));
    return std.fmt.allocPrintSentinel(a, "{s}", .{name}, 0);
}

fn dropTempSchema(a: std.mem.Allocator, d: *dbm.Db, name: []const u8) void {
    const sql = std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0) catch return;
    d.exec(sql) catch {};
}

/// Ensure the pgvector extension is installed (into `public`), or return `error.SkipZigTest` so a
/// PostgreSQL that doesn't ship pgvector skips rather than fails. `vector.ensureExtension` is
/// best-effort (it never errors); here we want the EXPLICIT skip, so we exec directly.
fn ensureVectorOrSkip(d: *dbm.Db) !void {
    d.exec("CREATE EXTENSION IF NOT EXISTS vector;") catch return error.SkipZigTest;
}

/// Provision `col`'s base table with Postgres column types (`COLLATE "C"` on TEXT like production).
/// The JSON embedding field stores as a TEXT column — the `?vector=` lowering casts it to `vector`
/// at query time, exactly as production does (no special column type, symmetric with sqlite-vec).
fn provisionTable(a: std.mem.Allocator, d: *dbm.Db, col: schema.Collection) !void {
    const tc = Dialect.postgres.textCollate();
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(a);
    {
        const head = try std.fmt.allocPrint(a, "CREATE TABLE \"{s}\" (\"id\" TEXT{s} PRIMARY KEY, \"created\" TEXT{s}, \"updated\" TEXT{s}", .{ col.name, tc, tc, tc });
        defer a.free(head);
        try sql.appendSlice(a, head);
    }
    for (col.fields) |f| {
        const ty = Dialect.postgres.sqlType(f.storageClass());
        const collate = if (std.mem.eql(u8, ty, "TEXT")) tc else "";
        const frag = try std.fmt.allocPrint(a, ", \"{s}\" {s}{s}", .{ f.name, ty, collate });
        defer a.free(frag);
        try sql.appendSlice(a, frag);
    }
    try sql.appendSlice(a, ");");
    const ddl = try std.fmt.allocPrintSentinel(a, "{s}", .{sql.items}, 0);
    defer a.free(ddl);
    try d.exec(ddl);
}

fn getStr(rec: std.json.Value, key: []const u8) []const u8 {
    return rec.object.get(key).?.string;
}

/// Build a record object from `(key, json.Value)` pairs (e.g. an embedding array + a text field).
fn obj(a: std.mem.Allocator, pairs: anytype) !std.json.Value {
    var m: std.json.ObjectMap = .empty;
    inline for (pairs) |p| try m.put(a, p[0], p[1]);
    return .{ .object = m };
}

/// A JSON-array embedding value (`[n0,n1,…]`) — the byte-identical text pgvector parses as a vector.
fn emb(a: std.mem.Allocator, comptime nums: anytype) !std.json.Value {
    var arr = std.json.Array.init(a);
    inline for (nums) |n| try arr.append(.{ .integer = n });
    return .{ .array = arr };
}

// ---- tests ------------------------------------------------------------------

test "pg-vector: ?vector= ranks nearest-neighbor order via pgvector <-> (parity with SQLite)" {
    if (comptime !vector.enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    try ensureVectorOrSkip(&d);
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "embedding", .options = .{ .json = .{} } },
        .{ .id = "f2", .name = "slug", .options = .{ .text = .{} } },
    };
    const col = schema.Collection{ .id = "c1", .name = "docs", .fields = &fields };
    try provisionTable(al, &d, col);

    // 2-D embeddings: distance from the query [1,0] is near=0, mid=1, far=√2 (L2).
    const rows = .{
        .{ "near", [_]i64{ 1, 0 } },
        .{ "mid", [_]i64{ 1, 1 } },
        .{ "far", [_]i64{ 0, 1 } },
    };
    inline for (rows) |r|
        _ = try records.create(al, io, &d, col, try obj(al, .{
            .{ "embedding", try emb(al, r[1]) },
            .{ "slug", std.json.Value{ .string = r[0] } },
        }));

    // KNN (L2) on Postgres: nearest-first order near, mid, far.
    const pg_res = try records.list(al, &d, col, .{ .vectorSpec = "embedding:l2:[1,0]", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 3), pg_res.items.len);
    try std.testing.expectEqualStrings("near", getStr(pg_res.items[0], "slug"));
    try std.testing.expectEqualStrings("mid", getStr(pg_res.items[1], "slug"));
    try std.testing.expectEqualStrings("far", getStr(pg_res.items[2], "slug"));

    // Cross-backend golden: the SAME rows + query on in-memory SQLite (sqlite-vec) yield the SAME
    // exact-L2 order (both backends compute true Euclidean distance, no approximation).
    var sl = try dbm.Db.openMemory();
    defer sl.close();
    try migrations.run(&sl);
    const scol = try collections.create(al, io, &sl, .{ .id = "", .name = "docs", .fields = &fields });
    inline for (rows) |r|
        _ = try records.create(al, io, &sl, scol, try obj(al, .{
            .{ "embedding", try emb(al, r[1]) },
            .{ "slug", std.json.Value{ .string = r[0] } },
        }));
    const sl_res = try records.list(al, &sl, scol, .{ .vectorSpec = "embedding:l2:[1,0]", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 3), sl_res.items.len);
    for (pg_res.items, sl_res.items) |p, s|
        try std.testing.expectEqualStrings(getStr(p, "slug"), getStr(s, "slug"));

    // Cosine metric (default) also orders nearest-first: [1,0] is most similar to itself (near).
    const cos = try records.list(al, &d, col, .{ .vectorSpec = "embedding:[1,0]", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 3), cos.items.len);
    try std.testing.expectEqualStrings("near", getStr(cos.items[0], "slug"));
}

test "pg-vector: KNN composes with TENANT scoping — only the active account's rows (CHOKEPOINT)" {
    if (comptime !vector.enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    try ensureVectorOrSkip(&d);
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "embedding", .options = .{ .json = .{} } },
        .{ .id = "f2", .name = "account", .options = .{ .text = .{} } },
    };
    var col = schema.Collection{ .id = "c1", .name = "posts", .fields = &fields };
    col.options.tenant_field = "account"; // tenant-owned
    try provisionTable(al, &d, col);

    // The NEAREST embedding to the query [1,0] belongs to acc2 — so a pre-WHERE k-NN would surface
    // it for acc1. Correct (post-scoping) KNN must return only acc1's two rows.
    const rows = .{
        .{ [_]i64{ 0, 1 }, "acc1" }, // far
        .{ [_]i64{ 1, 1 }, "acc1" }, // mid
        .{ [_]i64{ 1, 0 }, "acc2" }, // nearest, but NOT acc1's
    };
    inline for (rows) |r|
        _ = try records.create(al, io, &d, col, try obj(al, .{
            .{ "embedding", try emb(al, r[0]) },
            .{ "account", std.json.Value{ .string = r[1] } },
        }));

    // acc1's KNN → ONLY its 2 rows, even though acc2 owns the globally-nearest vector.
    const member = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };
    const r1 = try records.list(al, &d, col, .{ .vectorSpec = "embedding:l2:[1,0]", .rctx = &member, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 2), r1.items.len);
    try std.testing.expectEqual(@as(?i64, 2), r1.totalItems);
    for (r1.items) |it| try std.testing.expectEqualStrings("acc1", getStr(it, "account"));

    // No account context → fail closed: zero rows despite every row having an embedding.
    const noacct = request.RequestContext{ .tenancy_enabled = true, .account_id = "" };
    const r2 = try records.list(al, &d, col, .{ .vectorSpec = "embedding:l2:[1,0]", .rctx = &noacct, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 0), r2.items.len);

    // Superuser bypasses scoping → all 3 (nearest acc2 row first).
    const su = request.RequestContext{ .tenancy_enabled = true, .is_superuser = true, .account_id = "acc1" };
    const r3 = try records.list(al, &d, col, .{ .vectorSpec = "embedding:l2:[1,0]", .rctx = &su, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 3), r3.items.len);
    try std.testing.expectEqualStrings("acc2", getStr(r3.items[0], "account"));
}

test "pg-vector: KNN composes with ABILITY scoping — only membership-authorized rows (CHOKEPOINT)" {
    if (comptime !vector.enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    try ensureVectorOrSkip(&d);
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "embedding", .options = .{ .json = .{} } },
        .{ .id = "f2", .name = "account", .options = .{ .text = .{} } },
    };
    var col = schema.Collection{ .id = "c1", .name = "embeds", .fields = &fields };
    // view-ability: a row is visible only when the caller holds a membership of the row's `account`.
    col.options.abilities = abilities.Abilities{ .view = .{ .relationship = .{ .via = "account", .min_role = "" } } };
    try provisionTable(al, &d, col);

    const rows = .{
        .{ [_]i64{ 1, 0 }, "acc2" }, // nearest, but NOT the caller's
        .{ [_]i64{ 1, 1 }, "acc1" },
        .{ [_]i64{ 0, 1 }, "acc1" },
    };
    inline for (rows) |r|
        _ = try records.create(al, io, &d, col, try obj(al, .{
            .{ "embedding", try emb(al, r[0]) },
            .{ "account", std.json.Value{ .string = r[1] } },
        }));

    // Caller is a member of acc1 only → KNN returns only the two acc1 rows (acc2's nearer row is
    // ability-denied), proving the distance ORDER BY runs over the authz-filtered set.
    const mem = [_]request.Membership{.{ .account = "acc1", .role = "viewer" }};
    const rctx = request.RequestContext{ .memberships = &mem };
    const res = try records.list(al, &d, col, .{ .vectorSpec = "embedding:l2:[1,0]", .rctx = &rctx, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 2), res.items.len);
    for (res.items) |it| try std.testing.expectEqualStrings("acc1", getStr(it, "account"));

    // No memberships → fail closed: zero rows even though every row has an embedding.
    const empty_rctx = request.RequestContext{};
    const none = try records.list(al, &d, col, .{ .vectorSpec = "embedding:l2:[1,0]", .rctx = &empty_rctx, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
}
