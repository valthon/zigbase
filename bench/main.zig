const std = @import("std");
const harness = @import("harness.zig");
const zigbase = @import("zigbase");
const jwt = zigbase.jwt;
const crypto = zigbase.crypto;
const data = zigbase.data;
const Db = zigbase.Db;

// A representative record row: an id + two text columns + a number. `data.queryAs` decodes
// each result column BY NAME into these fields, allocating a copy of every text value per row
// — the per-row read/coerce cost that runs on every list/query request.
const Row = struct {
    id: []const u8,
    title: []const u8,
    body: []const u8,
    views: i64,
};

const records = zigbase.internal.records;
const schema = zigbase.internal.schema;

const QueryCtx = struct { conn: *Db };

// The JSON record-read path: a record decodes into a std.json.Value object (id +
// created/updated + each field via values.readValue) — the shape every REST read returns and
// serializes. The result is an interlinked ObjectMap (arena-lifetime, contract-4), so these
// are measured under runArena only; the DebugAllocator `run` would (correctly) leak-flag it.
const RecCtx = struct { conn: *Db, col: schema.Collection, id0: []const u8 };

// Single-record read (the findById shape): one prepare + one row -> one json.Value object.
fn benchFindByIdJson(c: RecCtx, a: std.mem.Allocator) anyerror!void {
    const rec = try records.get(a, c.conn, c.col, c.id0);
    std.mem.doNotOptimizeAway(&rec);
}

// List read (the list-endpoint shape): ONE query returns the first page (perPage=30) as json
// records. This is the batched path — contrast with N individual findById calls.
fn benchListJson(c: RecCtx, a: std.mem.Allocator) anyerror!void {
    const res = try records.list(a, c.conn, c.col, .{});
    std.mem.doNotOptimizeAway(&res);
}

// SELECT the whole seeded table and decode every row into `Row`. Measures the allocation
// profile of the row-mapping hot path: N rows x (id/title/body dupes) per call.
fn benchQueryRows(c: QueryCtx, a: std.mem.Allocator) anyerror!void {
    const rows = try data.queryAs(Row, c.conn, a, "SELECT \"id\",\"title\",\"body\",\"views\" FROM \"bench_posts\";", .{});
    // queryAs is contract-1: each row's text fields are owned dupes. Free them (and the slice)
    // so the harness measures queryAs's allocation profile without the result leaking.
    defer {
        for (rows) |r| {
            a.free(r.id);
            a.free(r.title);
            a.free(r.body);
        }
        a.free(rows);
    }
    std.mem.doNotOptimizeAway(&rows);
}

fn benchNoop(_: void, a: std.mem.Allocator) anyerror!void {
    const b = try a.alloc(u8, 16);
    defer a.free(b);
}

const JwtCtx = struct { key: [32]u8, token: []const u8 };

fn benchJwtSign(c: JwtCtx, a: std.mem.Allocator) anyerror!void {
    const claims = jwt.Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 9999999999 };
    const t = try jwt.sign(a, claims, &c.key);
    defer a.free(t);
}

fn benchJwtVerify(c: JwtCtx, _: std.mem.Allocator) anyerror!void {
    var scratch: [jwt.scratch_size]u8 = undefined;
    _ = try jwt.verifyInto(&scratch, c.token, &c.key, 2000);
}

/// Zig 0.16 entry point: argv comes from `init.minimal.args` (NOT `std.process.argsAlloc`,
/// which this Zig does not provide), and stdout is `std.Io.File.stdout()` written through
/// an `Io` writer — the same shape `src/framework.zig:1838` and its `emit` helper use.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    var json = false;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json = true;
    }

    var results: std.ArrayList(harness.Result) = .empty;
    defer results.deinit(alloc);
    try results.append(alloc, try harness.run("smoke/alloc-16", 100, 1000, init.io, {}, benchNoop));

    const key = crypto.deriveKey("bench-secret", "tk1");
    const jwt_claims = jwt.Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 9999999999 };
    const jwt_token = try jwt.sign(alloc, jwt_claims, &key);
    defer alloc.free(jwt_token);
    const jctx = JwtCtx{ .key = key, .token = jwt_token };

    try results.append(alloc, try harness.run("jwt/sign", 100, 2000, init.io, jctx, benchJwtSign));
    try results.append(alloc, try harness.run("jwt/verify", 100, 2000, init.io, jctx, benchJwtVerify));

    // Seed a 50-row table once, then benchmark the row-read/coerce path (data.queryAs).
    var qdb = try Db.openMemory();
    defer qdb.close();
    try qdb.exec("CREATE TABLE \"bench_posts\" (\"id\" TEXT, \"title\" TEXT, \"body\" TEXT, \"views\" INTEGER);");
    {
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO \"bench_posts\" VALUES ('id{d}','Post number {d} title','Body text for post {d}, a sentence or so of content.',{d});", .{ i, i, i, i * 7 }, 0);
            try qdb.exec(sql);
        }
    }
    const qctx = QueryCtx{ .conn = &qdb };
    // Same op measured two ways: `run` = raw-malloc cost (leak-checked); `runArena` = the
    // production request-arena cost. The allocs/bytes/buckets match; the ns gap is the malloc
    // overhead the arena erases — i.e. how cheap these ~150 small per-row dupes are in prod.
    try results.append(alloc, try harness.run("data/queryAs-50rows", 50, 1000, init.io, qctx, benchQueryRows));
    try results.append(alloc, try harness.runArena("data/queryAs-50rows-arena", 50, 1000, init.io, qctx, benchQueryRows));

    // The JSON record-read path (records.get -> std.json.Value), the REST read shape. Table
    // matches columnList: id,created,updated + the collection's fields.
    var rdb = try Db.openMemory();
    defer rdb.close();
    try rdb.exec("CREATE TABLE \"posts\" (\"id\" TEXT, \"created\" TEXT, \"updated\" TEXT, \"title\" TEXT, \"body\" TEXT, \"views\" INTEGER);");
    var ids: std.ArrayList([]const u8) = .empty;
    {
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            const id = try std.fmt.allocPrint(arena, "id{d}", .{i});
            try ids.append(arena, id);
            const sql = try std.fmt.allocPrintSentinel(arena, "INSERT INTO \"posts\" VALUES ('{s}','2026-01-01 00:00:00','2026-01-01 00:00:00','Post number {d} title','Body text for post {d}, a sentence or so of content.',{d});", .{ id, i, i, i * 7 }, 0);
            try rdb.exec(sql);
        }
    }
    const post_fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "body", .options = .{ .text = .{} } },
        .{ .id = "f3", .name = "views", .options = .{ .number = .{ .mode = .int } } },
    };
    const post_col = schema.Collection{ .id = "c1", .name = "posts", .type = .base, .fields = &post_fields };
    const rctx = RecCtx{ .conn = &rdb, .col = post_col, .id0 = ids.items[0] };
    // Single-record read vs a batched 30-record list — both the JSON (std.json.Value) shape,
    // measured under the request arena. Contrast with data/queryAs (typed struct) above.
    try results.append(alloc, try harness.runArena("records/findById-json", 100, 2000, init.io, rctx, benchFindByIdJson));
    try results.append(alloc, try harness.runArena("records/list-json-30", 50, 1000, init.io, rctx, benchListJson));

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try harness.report(results.items, json, &w.interface);
    try w.interface.flush();
}
