//! Live cross-backend CRUD + query tests for the Postgres arm (issue #159, PR-3). These exercise
//! the record CRUD and `records.list` query path END-TO-END against a real PostgreSQL using the
//! `$n` ParamSink rework + the CRUD/query dialect (now()/ISO timestamps, ILIKE, NULLS FIRST/LAST,
//! RETURNING, the empty-set `IN ()` → constant-false idiom). Where a SQLite comparison makes sense
//! each test runs the IDENTICAL records operation against an in-memory SQLite collection and
//! asserts the two backends agree (cross-backend golden).
//!
//! They run only under `-Dpostgres=true` and require a reachable PostgreSQL. Connection string:
//! `ZIGBASE_PG_TEST_URL` if set, else the SCRAM+TLS default in `tests.zig`. A connectivity/auth
//! failure SKIPS (so the suite still runs where no PG exists); any other error propagates.
//!
//! Schema isolation: each test creates a throwaway `CREATE SCHEMA` + `SET search_path`, provisions
//! its tables there with Postgres column types derived from the same `schema.Collection` the SQLite
//! arm uses (via `Dialect.postgres.sqlType`), and `DROP SCHEMA … CASCADE`s on teardown.

const std = @import("std");
const pg = @import("postgres.zig");
const root = @import("../../root.zig");
const dbm = @import("../../db.zig");
const records = @import("../../records.zig");
const collections = @import("../../collections.zig");
const migrations = @import("../../migrations.zig");
const schema = @import("../../schema.zig");
const dialect_mod = @import("../../sql/dialect.zig");

const Dialect = dialect_mod.Dialect;

// ---- connection plumbing (shared with tests.zig / clock.zig) ----------------

/// `getEnv`/`testUrl`/`default_url` live in `tests.zig` as the single shared definition for
/// the Postgres live-test files (was duplicated per-file).
const pgtests = @import("tests.zig");

/// Open a `db.Db` Postgres handle, or null to signal "no reachable PG → skip". Only a
/// connectivity/auth failure (`OpenFailed`) skips; any other error propagates.
fn openOrSkip(a: std.mem.Allocator, io: std.Io) !?dbm.Db {
    return dbm.Db.openPostgres(a, io, pgtests.testUrl()) catch |e| switch (e) {
        error.OpenFailed => null,
        else => e,
    };
}

var schema_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Create + switch into a throwaway schema; returns its name (caller drops it on teardown).
fn enterTempSchema(a: std.mem.Allocator, d: *dbm.Db) ![:0]const u8 {
    const n = schema_counter.fetchAdd(1, .monotonic);
    // Unique within a process run; `DROP … IF EXISTS` first clears any leftover from a prior run.
    const name = try std.fmt.allocPrint(a, "zb_pr3_{d}", .{n});
    try d.exec(try std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "CREATE SCHEMA \"{s}\";", .{name}, 0));
    try d.exec(try std.fmt.allocPrintSentinel(a, "SET search_path TO \"{s}\";", .{name}, 0));
    return std.fmt.allocPrintSentinel(a, "{s}", .{name}, 0);
}

fn dropTempSchema(a: std.mem.Allocator, d: *dbm.Db, name: []const u8) void {
    const sql = std.fmt.allocPrintSentinel(a, "DROP SCHEMA IF EXISTS \"{s}\" CASCADE;", .{name}, 0) catch return;
    d.exec(sql) catch {};
}

/// Provision `col`'s table on Postgres using the Postgres column types for each field's storage
/// class (BIGINT / DOUBLE PRECISION / TEXT). System columns mirror what `records` reads/writes.
///
/// Every TEXT column gets the dialect's byte-order collation (`Dialect.textCollate()` → `COLLATE
/// "C"` on Postgres) so its ordering matches SQLite's default BINARY collation — the same clause
/// PR-2's REAL provisioning (`ddl.zig`/`provision.zig`, #169) now emits, and that
/// `schema_pg_test.zig` proves end-to-end. Sourcing it from the dialect helper (not a magic
/// string) keeps this hand-rolled CRUD-test DDL in lock-step with production. Without it Postgres
/// sorts text by the database locale (e.g. `en_US.UTF-8`), so an `id` keyset TIEBREAKER among
/// equal sort-key rows would diverge from SQLite. (These CRUD tests assert keyset pagination via
/// collation-independent SCORE sequences, so they don't depend on this; it's correctness hygiene
/// that mirrors the provisioned schema.)
fn provisionPg(a: std.mem.Allocator, d: *dbm.Db, col: schema.Collection) !void {
    const tc = Dialect.postgres.textCollate(); // " COLLATE \"C\"" on Postgres
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(a, try std.fmt.allocPrint(a, "CREATE TABLE \"{s}\" (\"id\" TEXT{s} PRIMARY KEY, \"created\" TEXT{s}, \"updated\" TEXT{s}", .{ col.name, tc, tc, tc }));
    for (col.fields) |f| {
        const ty = Dialect.postgres.sqlType(f.storageClass());
        const collate = if (std.mem.eql(u8, ty, "TEXT")) tc else "";
        try sql.appendSlice(a, try std.fmt.allocPrint(a, ", \"{s}\" {s}{s}", .{ f.name, ty, collate }));
    }
    try sql.appendSlice(a, ");");
    try d.exec(try std.fmt.allocPrintSentinel(a, "{s}", .{sql.items}, 0));
}

// ---- small value helpers ----------------------------------------------------

fn getStr(rec: std.json.Value, key: []const u8) []const u8 {
    return rec.object.get(key).?.string;
}

/// Collect the `id` of every item in a list result, in order.
fn idsOf(a: std.mem.Allocator, items: []std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |it| try out.append(a, it.object.get("id").?.string);
    return out.toOwnedSlice(a);
}

fn obj(a: std.mem.Allocator, pairs: anytype) !std.json.Value {
    var m: std.json.ObjectMap = .empty;
    inline for (pairs) |p| try m.put(a, p[0], p[1]);
    return .{ .object = m };
}

// ---- tests ------------------------------------------------------------------

test "pg: CRUD round-trip (create/read/update/delete) with now()/ISO timestamps + RETURNING" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const col = schema.Collection{ .id = "c1", .name = "people", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "name", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "active", .options = .{ .@"bool" = .{} } },
    } };
    try provisionPg(al, &d, col);

    // CREATE — RETURNING gives back the row incl. server-set id/created/updated (ISO `Z`).
    const created = try records.create(al, io, &d, col, try obj(al, .{
        .{ "name", std.json.Value{ .string = "Ada" } },
        .{ "active", std.json.Value{ .bool = true } },
    }));
    const id = getStr(created, "id");
    try std.testing.expectEqualStrings("Ada", getStr(created, "name"));
    try std.testing.expectEqual(true, created.object.get("active").?.bool);
    // created/updated must be ISO-8601 `Z` text from to_char(now()) — same shape SQLite emits.
    const ts = getStr(created, "created");
    try std.testing.expectEqual(@as(usize, 20), ts.len);
    try std.testing.expectEqual(@as(u8, 'Z'), ts[19]);

    // READ
    const got = (try records.get(al, &d, col, id)).?;
    try std.testing.expectEqualStrings("Ada", getStr(got, "name"));

    // UPDATE (partial)
    const upd = (try records.update(al, &d, col, id, try obj(al, .{
        .{ "name", std.json.Value{ .string = "Ada L" } },
    }))).?;
    try std.testing.expectEqualStrings("Ada L", getStr(upd, "name"));
    try std.testing.expectEqual(true, upd.object.get("active").?.bool); // unchanged

    // DELETE → gone
    try std.testing.expect(try records.delete(al, &d, col, id));
    try std.testing.expect((try records.get(al, &d, col, id)) == null);
    try std.testing.expect(!try records.delete(al, &d, col, id)); // idempotent
}

/// Provision the same collection on an in-memory SQLite for cross-backend golden comparison.
fn sqliteWith(a: std.mem.Allocator, io: std.Io, d: *dbm.Db, col: schema.Collection) !schema.Collection {
    try migrations.run(d);
    return collections.create(a, io, d, .{ .id = "", .name = col.name, .fields = col.fields });
}

test "pg: multi-param filter returns the right rows and matches SQLite" {
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
        .{ .id = "f1", .name = "team", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "score", .options = .{ .number = .{ .mode = .float } } },
    };
    const col = schema.Collection{ .id = "c", .name = "players", .fields = &fields };
    try provisionPg(al, &d, col);

    var sl = try dbm.Db.openMemory();
    defer sl.close();
    const scol = try sqliteWith(al, io, &sl, col);

    const rows = [_]struct { team: []const u8, score: f64 }{
        .{ .team = "red", .score = 3 },  .{ .team = "red", .score = 9 },
        .{ .team = "blue", .score = 7 }, .{ .team = "red", .score = 6 },
    };
    inline for (rows) |r| {
        const data = try obj(al, .{
            .{ "team", std.json.Value{ .string = r.team } },
            .{ "score", std.json.Value{ .float = r.score } },
        });
        _ = try records.create(al, io, &d, col, data);
        _ = try records.create(al, io, &sl, scol, data);
    }

    // Two bound params: team = "red" AND score > 5  → the red rows scoring 9 and 6.
    const q = records.ListQuery{ .filter = "team = \"red\" && score > 5", .sort = "score", .perPage = 50 };
    const pg_res = try records.list(al, &d, col, q);
    const sl_res = try records.list(al, &sl, scol, q);
    try std.testing.expectEqual(@as(usize, 2), pg_res.items.len);
    // Same scores, same order on both backends.
    try std.testing.expectApproxEqAbs(@as(f64, 6), pg_res.items[0].object.get("score").?.float, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 9), pg_res.items[1].object.get("score").?.float, 1e-9);
    try std.testing.expectEqual(sl_res.items.len, pg_res.items.len);
}

test "pg: ILIKE — `~` is case-insensitive on Postgres (matches SQLite LIKE)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const col = schema.Collection{ .id = "c", .name = "docs", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
    } };
    try provisionPg(al, &d, col);

    inline for (.{ "Zig Lang", "rust lang", "ZIGZAG" }) |t|
        _ = try records.create(al, io, &d, col, try obj(al, .{.{ "title", std.json.Value{ .string = t } }}));

    // Lowercase search term must still match the mixed-case titles (ILIKE).
    const res = try records.list(al, &d, col, .{ .filter = "title ~ \"zig\"", .sort = "title", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 2), res.items.len); // "Zig Lang" + "ZIGZAG"
}

test "pg: keyset pagination across a NULL boundary (NULLS FIRST) matches SQLite order" {
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
        .{ .id = "f1", .name = "label", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "score", .options = .{ .number = .{ .mode = .float } } }, // nullable
    };
    const col = schema.Collection{ .id = "c", .name = "items", .fields = &fields };
    try provisionPg(al, &d, col);
    var sl = try dbm.Db.openMemory();
    defer sl.close();
    const scol = try sqliteWith(al, io, &sl, col);

    // Two rows with NULL score, two with values. ASC sort → NULLs first on both backends.
    const rows = [_]struct { label: []const u8, score: ?f64 }{
        .{ .label = "n1", .score = null }, .{ .label = "n2", .score = null },
        .{ .label = "v1", .score = 1.0 },  .{ .label = "v2", .score = 2.0 },
    };
    inline for (rows) |r| {
        const sv: std.json.Value = if (r.score) |s| .{ .float = s } else .null;
        const data = try obj(al, .{ .{ "label", std.json.Value{ .string = r.label } }, .{ "score", sv } });
        _ = try records.create(al, io, &d, col, data);
        _ = try records.create(al, io, &sl, scol, data);
    }

    // Walk the whole set in 2-row pages on BOTH backends and assert the SCORE sequence is identical
    // and complete. The first page straddles the NULL→non-NULL boundary, so a wrong NULLS placement
    // (Postgres defaults NULLs LAST for ASC) or a drifting keyset would diverge here. We compare the
    // score key — not the `label`/`id` — because each backend mints independent random ids, so the
    // tiebreaker order WITHIN the two equal (NULL) rows is legitimately backend-specific; the parity
    // that matters is "NULLs first, then ascending values, every row exactly once".
    const want = collectScoresPaged(al, &sl, scol) catch unreachable;
    const got = try collectScoresPaged(al, &d, col);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    // The boundary is correct: two NULLs first (NULLS FIRST), then 1, then 2.
    try std.testing.expectEqualStrings("NULL", got[0]);
    try std.testing.expectEqualStrings("NULL", got[1]);
    try std.testing.expectEqualStrings("1", got[2]);
    try std.testing.expectEqualStrings("2", got[3]);
}

/// Page through `col` with keyset cursors (2 rows/page, sort score ASC) and return the `score` of
/// every row in traversal order, normalized to "NULL" or its integer text — deterministic across
/// backends regardless of the random `id` tiebreaker.
fn collectScoresPaged(a: std.mem.Allocator, d: *dbm.Db, col: schema.Collection) ![]const []const u8 {
    var scores: std.ArrayList([]const u8) = .empty;
    var cursor: ?[]const u8 = null;
    var guard: usize = 0;
    while (true) : (guard += 1) {
        if (guard > 10) return error.TooManyPages;
        const res = try records.list(a, d, col, .{ .sort = "score", .limit = 2, .cursorMode = true, .cursor = cursor });
        for (res.items) |it| {
            const sv = it.object.get("score").?;
            const s: []const u8 = switch (sv) {
                .null => "NULL",
                .float => |fv| try std.fmt.allocPrint(a, "{d}", .{fv}),
                else => "?",
            };
            try scores.append(a, s);
        }
        if (!res.hasNext or res.nextCursor == null) break;
        cursor = res.nextCursor;
    }
    return scores.toOwnedSlice(a);
}

test "pg: WHERE params + LIMIT/OFFSET bind ordering (multi-param OFFSET page) is correct" {
    // The vector-embedding-in-ORDER-BY position is pinned deterministically by the param_sink
    // unit test (sql/param_sink.zig); this exercises the live OFFSET-mode binding where the WHERE
    // params ($1,$2) precede LIMIT ($3) / OFFSET ($4) — the same renumber chokepoint.
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
        .{ .id = "f1", .name = "team", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "n", .options = .{ .number = .{ .mode = .float } } },
    };
    const col = schema.Collection{ .id = "c", .name = "rows", .fields = &fields };
    try provisionPg(al, &d, col);

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        _ = try records.create(al, io, &d, col, try obj(al, .{
            .{ "team", std.json.Value{ .string = "x" } },
            .{ "n", std.json.Value{ .float = @floatFromInt(i) } },
        }));
    }
    // WHERE team="x" AND n >= 1  (2 bound params) → 5 rows; page 2 of 2/page → the 3rd/4th.
    const res = try records.list(al, &d, col, .{ .filter = "team = \"x\" && n >= 1", .sort = "n", .perPage = 2, .page = 2, .skipTotal = false });
    try std.testing.expectEqual(@as(usize, 2), res.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 3), res.items[0].object.get("n").?.float, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4), res.items[1].object.get("n").?.float, 1e-9);
    try std.testing.expectEqual(@as(?i64, 5), res.totalItems); // WHERE-only COUNT renumbers independently
}

test "pg: boolean round-trip + filter on a bool column" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const col = schema.Collection{ .id = "c", .name = "flags", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "label", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "on", .options = .{ .@"bool" = .{} } },
    } };
    try provisionPg(al, &d, col);

    inline for (.{ .{ "a", true }, .{ "b", false }, .{ "c", true } }) |r|
        _ = try records.create(al, io, &d, col, try obj(al, .{
            .{ "label", std.json.Value{ .string = r[0] } },
            .{ "on", std.json.Value{ .bool = r[1] } },
        }));

    // Stored as 0/1 in a BIGINT column; reads back as a real JSON bool, and `on = true` filters.
    const res = try records.list(al, &d, col, .{ .filter = "on = true", .sort = "label", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 2), res.items.len);
    try std.testing.expectEqual(true, res.items[0].object.get("on").?.bool);
}

test "pg: empty-set IN () is the constant-false predicate → 0 rows (fail closed)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var d = (try openOrSkip(a, io)) orelse return error.SkipZigTest;
    defer d.close();
    const sname = try enterTempSchema(al, &d);
    defer dropTempSchema(al, &d, sname);

    const col = schema.Collection{ .id = "c", .name = "tags", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "name", .options = .{ .text = .{} } },
    } };
    try provisionPg(al, &d, col);
    inline for (.{ "a", "b" }) |t|
        _ = try records.create(al, io, &d, col, try obj(al, .{.{ "name", std.json.Value{ .string = t } }}));

    // An empty membership set compiles to "0" (never `IN ()`, which is a syntax error on both
    // backends) → 0 rows, matching the SQLite arm.
    const res = try records.list(al, &d, col, .{ .filter = "name in ()", .perPage = 50, .skipTotal = false });
    try std.testing.expectEqual(@as(usize, 0), res.items.len);
    try std.testing.expectEqual(@as(?i64, 0), res.totalItems);

    // Sanity: a non-empty set still returns rows (so the "0" path isn't masking a broken IN).
    const res2 = try records.list(al, &d, col, .{ .filter = "name in (\"a\")", .perPage = 50 });
    try std.testing.expectEqual(@as(usize, 1), res2.items.len);
}
