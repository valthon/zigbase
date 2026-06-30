//! Live full-text-search parity tests for the Postgres arm (issue #159, PR-10). These exercise the
//! tsvector/`@@`/`ts_rank` lowering END-TO-END against a real PostgreSQL behind the SAME `?search=`
//! surface the SQLite FTS5 path uses: provision a searchable collection (which `fts.ensureIndex`
//! lowers to a STORED `tsvector` generated column + a GIN index), insert rows through the records
//! layer, and run ranked `records.list` searches. The CRITICAL access-control tests prove a search
//! composes with the FULL authz stack — a tenant-scoped / ability-scoped search returns ONLY rows
//! the caller may view, identical to the SQLite chokepoint requirement.
//!
//! They run only under `-Dpostgres=true` and require a reachable PostgreSQL. Connection string:
//! `ZIGBASE_PG_TEST_URL` if set, else the SCRAM+TLS default in `tests.zig`. A connectivity/auth
//! failure SKIPS (so the suite still runs where no PG exists); any other error propagates.
//!
//! Schema isolation: each test creates a throwaway `CREATE SCHEMA` + `SET search_path`, provisions
//! its table + tsvector index there, and `DROP SCHEMA … CASCADE`s on teardown.

const std = @import("std");
const dbm = @import("../../db.zig");
const records = @import("../../records.zig");
const collections = @import("../../collections.zig");
const migrations = @import("../../migrations.zig");
const schema = @import("../../schema.zig");
const fts = @import("../../search/fts.zig");
const request = @import("../../request.zig");
const abilities = @import("../../authz/abilities.zig");
const dialect_mod = @import("../../sql/dialect.zig");
const pgtests = @import("tests.zig");

const Dialect = dialect_mod.Dialect;

// ---- connection + schema plumbing (mirrors crud_tests.zig) ------------------

fn openOrSkip(a: std.mem.Allocator, io: std.Io) !?dbm.Db {
    return dbm.Db.openPostgres(a, io, pgtests.testUrl()) catch |e| switch (e) {
        error.OpenFailed => null,
        else => e,
    };
}

var schema_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn enterTempSchema(a: std.mem.Allocator, d: *dbm.Db) ![:0]const u8 {
    const n = schema_counter.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(a, "zb_fts_{d}", .{n});
    try d.exec(try std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA \"{s}\";", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "SET search_path TO \"{s}\";", .{name}, 0));
    return std.fmt.allocPrintSentinel(a, "{s}", .{name}, 0);
}

fn dropTempSchema(a: std.mem.Allocator, d: *dbm.Db, name: []const u8) void {
    const sql = std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0) catch return;
    d.exec(sql) catch {};
}

/// Provision `col`'s base table (Postgres column types, `COLLATE "C"` on TEXT like production) AND
/// its tsvector full-text index via the SAME `fts.ensureIndex` the startup provisioner runs — so
/// the generated column + GIN index under test are built by production code, not the test.
fn provisionFts(a: std.mem.Allocator, d: *dbm.Db, col: schema.Collection) !void {
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
    try fts.ensureIndex(a, d, col); // build the tsvector generated column + GIN index
}

fn getStr(rec: std.json.Value, key: []const u8) []const u8 {
    return rec.object.get(key).?.string;
}

fn obj(a: std.mem.Allocator, pairs: anytype) !std.json.Value {
    var m: std.json.ObjectMap = .empty;
    inline for (pairs) |p| try m.put(a, p[0], p[1]);
    return .{ .object = m };
}

/// The set of `key` field values present in a list result (order-independent membership).
fn valueSet(a: std.mem.Allocator, items: []std.json.Value, key: []const u8) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    for (items) |it| try set.put(it.object.get(key).?.string, {});
    return set;
}

// ---- tests ------------------------------------------------------------------

test "pg-fts: provisions a tsvector index and ranks `?search=` matches (parity with SQLite)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "body", .searchable = true, .options = .{ .editor = .{} } },
        .{ .id = "f3", .name = "slug", .options = .{ .text = .{} } }, // NOT searchable
    };
    const col = schema.Collection{ .id = "c1", .name = "articles", .fields = &fields };
    try provisionFts(al, &d, col);

    // The generated tsvector column + its GIN index are now present (idempotent re-run is a no-op).
    try fts.ensureIndex(al, &d, col);

    // Cross-backend golden: same collection + rows on in-memory SQLite (FTS5).
    var sl = try dbm.Db.openMemory();
    defer sl.close();
    try migrations.run(&sl);
    const scol = try collections.create(al, io, &sl, .{ .id = "", .name = "articles", .fields = &fields });
    try fts.ensureIndex(al, &sl, scol);

    // Row "high" mentions zig three times (ranks highest); "low" once; "miss" never.
    const rows = .{
        .{ "high", "zig zig zig programming", "a fast systems language" },
        .{ "low", "zig lang", "general notes" },
        .{ "miss", "cooking pasta", "boil water and add salt" },
    };
    inline for (rows) |r| {
        const data = try obj(al, .{
            .{ "title", std.json.Value{ .string = r[1] } },
            .{ "body", std.json.Value{ .string = r[2] } },
            .{ "slug", std.json.Value{ .string = r[0] } },
        });
        _ = try records.create(al, io, &d, col, data);
        _ = try records.create(al, io, &sl, scol, data);
    }

    // Ranked search on Postgres: only the two zig rows, "high" before "low" (ts_rank DESC).
    const pg_res = try records.list(al, &d, col, .{ .search = "zig", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 2), pg_res.items.len);
    try std.testing.expectEqualStrings("high", getStr(pg_res.items[0], "slug"));
    try std.testing.expectEqualStrings("low", getStr(pg_res.items[1], "slug"));
    try std.testing.expectEqual(@as(?i64, 2), pg_res.totalItems);

    // Parity: SQLite (FTS5) surfaces the SAME matched SET, never "miss". (Exact rank ORDER is
    // algorithm-specific — FTS5 bm25 length-normalizes, so it favors the shorter "low" doc, while
    // Postgres ts_rank (no length normalization) favors the 3-occurrence "high" doc — so we assert
    // set parity, not identical ordering across backends.)
    const sl_res = try records.list(al, &sl, scol, .{ .search = "zig", .perPage = 50 });
    try std.testing.expectEqual(pg_res.items.len, sl_res.items.len);
    var pg_slugs = try valueSet(al, pg_res.items, "slug");
    for (sl_res.items) |it| try std.testing.expect(pg_slugs.contains(getStr(it, "slug")));

    // A body-only term matches via the multi-column tsvector (title || body).
    const body_res = try records.list(al, &d, col, .{ .search = "salt", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 1), body_res.items.len);
    try std.testing.expectEqualStrings("miss", getStr(body_res.items[0], "slug"));

    // A term in a NON-searchable column ("slug" values like "high") never matches.
    const nores = try records.list(al, &d, col, .{ .search = "high", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 0), nores.items.len);

    // A non-matching term yields no rows on both backends.
    const empty_pg = try records.list(al, &d, col, .{ .search = "nonexistentword", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 0), empty_pg.items.len);
}

test "pg-fts: search composes with TENANT scoping — only the active account's matches (CHOKEPOINT)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "account", .options = .{ .text = .{} } },
    };
    var col = schema.Collection{ .id = "c1", .name = "posts", .fields = &fields };
    col.options.tenant_field = "account"; // tenant-owned
    try provisionFts(al, &d, col);

    // Three rows ALL match "zig": two owned by acc1, one by acc2.
    const rows = .{ .{ "zig one", "acc1" }, .{ "zig two", "acc1" }, .{ "zig three", "acc2" } };
    inline for (rows) |r|
        _ = try records.create(al, io, &d, col, try obj(al, .{
            .{ "title", std.json.Value{ .string = r[0] } },
            .{ "account", std.json.Value{ .string = r[1] } },
        }));

    // acc1 searches "zig" -> ONLY its 2 rows, even though acc2's row also matches the tsquery.
    const member = request.RequestContext{ .tenancy_enabled = true, .account_id = "acc1" };
    const r1 = try records.list(al, &d, col, .{ .search = "zig", .rctx = &member, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 2), r1.items.len);
    try std.testing.expectEqual(@as(?i64, 2), r1.totalItems);
    for (r1.items) |it| try std.testing.expectEqualStrings("acc1", getStr(it, "account"));

    // No account context -> fail closed: zero matches despite the tsquery hitting every row.
    const noacct = request.RequestContext{ .tenancy_enabled = true, .account_id = "" };
    const r2 = try records.list(al, &d, col, .{ .search = "zig", .rctx = &noacct, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 0), r2.items.len);

    // Superuser bypasses scoping -> all 3 matches.
    const su = request.RequestContext{ .tenancy_enabled = true, .is_superuser = true, .account_id = "acc1" };
    const r3 = try records.list(al, &d, col, .{ .search = "zig", .rctx = &su, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 3), r3.items.len);
}

test "pg-fts: search composes with ABILITY scoping — only membership-authorized matches (CHOKEPOINT)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "account", .options = .{ .text = .{} } },
    };
    var col = schema.Collection{ .id = "c1", .name = "docs", .fields = &fields };
    // view-ability: a row is visible only when the caller holds a membership of the row's `account`.
    col.options.abilities = abilities.Abilities{ .view = .{ .relationship = .{ .via = "account", .min_role = "" } } };
    try provisionFts(al, &d, col);

    const rows = .{ .{ "zig alpha", "acc1" }, .{ "zig beta", "acc2" }, .{ "zig gamma", "acc1" } };
    inline for (rows) |r|
        _ = try records.create(al, io, &d, col, try obj(al, .{
            .{ "title", std.json.Value{ .string = r[0] } },
            .{ "account", std.json.Value{ .string = r[1] } },
        }));

    // Caller is a member of acc1 only -> search "zig" returns only the two acc1 rows.
    const mem = [_]request.Membership{.{ .account = "acc1", .role = "viewer" }};
    const rctx = request.RequestContext{ .memberships = &mem };
    const res = try records.list(al, &d, col, .{ .search = "zig", .rctx = &rctx, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 2), res.items.len);
    for (res.items) |it| try std.testing.expectEqualStrings("acc1", getStr(it, "account"));

    // No memberships -> fail closed: zero matches even though all three rows hit the tsquery.
    const empty_rctx = request.RequestContext{};
    const none = try records.list(al, &d, col, .{ .search = "zig", .rctx = &empty_rctx, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
}

test "pg-fts: ensureIndex rebuilds the index when the searchable column SET drifts" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    // v1: only `title` searchable.
    const f1 = [_]schema.Field{
        .{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "body", .options = .{ .editor = .{} } },
    };
    const c1 = schema.Collection{ .id = "c", .name = "notes", .fields = &f1 };
    try provisionFts(al, &d, c1);
    _ = try records.create(al, io, &d, c1, try obj(al, .{
        .{ "title", std.json.Value{ .string = "alpha" } },
        .{ "body", std.json.Value{ .string = "zebra" } },
    }));
    // "zebra" lives in the non-searchable body -> no match under v1.
    try std.testing.expectEqual(@as(usize, 0), (try records.list(al, &d, c1, .{ .search = "zebra", .perPage = 50 })).items.len);

    // v2: body is now ALSO searchable -> ensureIndex must detect drift and rebuild the column.
    const f2 = [_]schema.Field{
        .{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "body", .searchable = true, .options = .{ .editor = .{} } },
    };
    const c2 = schema.Collection{ .id = "c", .name = "notes", .fields = &f2 };
    try fts.ensureIndex(al, &d, c2); // drift -> drop + recreate generated column + GIN

    // The existing row's body is re-indexed by the rebuilt STORED generated column.
    const res = try records.list(al, &d, c2, .{ .search = "zebra", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 1), res.items.len);
    try std.testing.expectEqualStrings("alpha", getStr(res.items[0], "title"));
}

test "pg-fts: a >256-byte search term ending mid-codepoint does not error (UTF-8-safe cap)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const fields = [_]schema.Field{.{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } }};
    const col = schema.Collection{ .id = "c1", .name = "items", .fields = &fields };
    try provisionFts(al, &d, col);
    _ = try records.create(al, io, &d, col, try obj(al, .{.{ "title", std.json.Value{ .string = "hello world" } }}));

    // Craft a term longer than the byte cap whose byte at the cut index is a UTF-8 CONTINUATION
    // byte: (max_term_len-1) ASCII bytes + a 2-byte 'é'. A naive `term[0..max_term_len]` would slice
    // through the 'é' → invalid UTF-8 → Postgres rejects the bound text param → 500. The UTF-8-safe
    // cap backs off to the codepoint boundary, so the search runs cleanly (and simply matches
    // nothing here).
    var term: std.ArrayList(u8) = .empty;
    try term.appendNTimes(al, 'a', fts.max_term_len - 1);
    try term.appendSlice(al, "\u{E9}"); // C3 A9 — the cut at max_term_len lands on the A9 byte
    try std.testing.expect(term.items.len > fts.max_term_len);

    const res = try records.list(al, &d, col, .{ .search = term.items, .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 0), res.items.len); // no row contains the long token
}
