//! Vector / nearest-neighbor search (Theme A / #157) — OPT-IN, gated behind the non-default
//! `-Dvector` build flag (`build_options.vector`).
//!
//! When the flag is OFF (the default build) this module is INERT: `enabled` is comptime-false,
//! `build` returns `error.VectorDisabled` (the list handler maps it to a clean 400 "vector search
//! not enabled in this build"), and the sqlite-vec C amalgamation is NOT compiled or linked, so the
//! shipped binary is byte-for-byte unaffected. When the flag is ON, `build.zig` compiles
//! `vendor/sqlite-vec/sqlite-vec.c` into the SQLite build and `db.zig` registers the extension on
//! every connection, exposing the `vec_distance_cosine` / `vec_distance_L2` scalar functions used
//! here to ORDER a list by nearest-neighbor distance to a query embedding (KNN).
//!
//! Like full-text search, vector search is a READ path: `build` returns a WHERE fragment + an
//! ORDER-BY distance expression that `records.list` AND-s / appends into the SAME predicate
//! composition as filter + listRule + ability + tenant-scope + ttl — never a separate, unscoped
//! query. The query embedding is a BOUND parameter (`?`), never interpolated; the target column and
//! collection identifiers are gated through `schema.isValidIdentifier`.
//!
//! Embeddings are stored in an ordinary `json`/`text` field as a JSON array (e.g. `[0.1,0.2,…]`);
//! sqlite-vec parses that JSON directly. The query param form is
//! `vector=<field>[:cosine|:l2]:<json-embedding>` (cosine is the default metric).

const std = @import("std");
const build_options = @import("build_options");
const schema = @import("../schema.zig");
const compiler = @import("../query/compiler.zig");

/// Comptime gate: true only in a `-Dvector=true` build. All vector functionality folds to
/// comptime-dead code (and the sqlite-vec C side is absent) when false.
pub const enabled = build_options.vector;

pub const VectorError = error{ VectorDisabled, BadVector } || std.mem.Allocator.Error;

/// A compiled nearest-neighbor clause AND-ed/appended into the list query by `records.list`.
/// `where_sql` excludes rows with no embedding (no param); `order_sql` is the distance metric
/// against the bound query embedding (`param`), ordered ascending = nearest first (KNN).
pub const Vector = struct {
    where_sql: []const u8,
    order_sql: []const u8,
    param: compiler.Param,
};

/// Build the KNN clause for a `vector=<field>[:metric]:<embedding>` param on `col`, or an error.
/// `error.VectorDisabled` in a default (non-`-Dvector`) build → the handler returns a clean 400.
/// `error.BadVector` for a malformed spec / unknown or non-storable target field. The embedding is
/// bound, never interpolated.
pub fn build(alloc: std.mem.Allocator, col: schema.Collection, raw: []const u8) VectorError!Vector {
    if (comptime !enabled) return error.VectorDisabled;
    if (!schema.isValidIdentifier(col.name)) return error.BadVector;

    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return error.BadVector;
    const field = raw[0..colon];
    var rest = raw[colon + 1 ..];
    if (!schema.isValidIdentifier(field)) return error.BadVector;

    // Optional metric prefix (default cosine). sqlite-vec exposes vec_distance_cosine / _L2.
    var dist_fn: []const u8 = "vec_distance_cosine";
    if (std.mem.startsWith(u8, rest, "cosine:")) {
        rest = rest["cosine:".len..];
    } else if (std.mem.startsWith(u8, rest, "l2:")) {
        dist_fn = "vec_distance_L2";
        rest = rest["l2:".len..];
    }
    if (rest.len == 0) return error.BadVector;

    // The target must be a real, non-encrypted field that stores text/json (the embedding JSON).
    const f = schema.fieldByName(col, field) orelse return error.BadVector;
    if (f.encrypted) return error.BadVector;
    switch (f.fieldType()) {
        .json, .text => {},
        else => return error.BadVector,
    }

    return .{
        .where_sql = try std.fmt.allocPrint(alloc, "\"{s}\".\"{s}\" IS NOT NULL", .{ col.name, field }),
        .order_sql = try std.fmt.allocPrint(alloc, "{s}(\"{s}\".\"{s}\", ?)", .{ dist_fn, col.name, field }),
        .param = .{ .text = rest },
    };
}

// ---- Tests -----------------------------------------------------------------

test "vector build is disabled (clean error) in a default build" {
    if (comptime enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const col = schema.Collection{ .id = "c", .name = "docs", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "embedding", .options = .{ .json = .{} } },
    } };
    try std.testing.expectError(error.VectorDisabled, build(arena.allocator(), col, "embedding:[0.1,0.2]"));
}

test "vector build parses field/metric/embedding and binds the query vector" {
    if (comptime !enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = schema.Collection{ .id = "c", .name = "docs", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "embedding", .options = .{ .json = .{} } },
        .{ .id = "f2", .name = "n", .options = .{ .number = .{} } },
    } };
    const v = try build(a, col, "embedding:[0.1,0.2,0.3]");
    try std.testing.expectEqualStrings("\"docs\".\"embedding\" IS NOT NULL", v.where_sql);
    try std.testing.expectEqualStrings("vec_distance_cosine(\"docs\".\"embedding\", ?)", v.order_sql);
    try std.testing.expectEqualStrings("[0.1,0.2,0.3]", v.param.text);
    // l2 metric prefix selects the L2 distance function.
    const v2 = try build(a, col, "embedding:l2:[1,2,3]");
    try std.testing.expectEqualStrings("vec_distance_L2(\"docs\".\"embedding\", ?)", v2.order_sql);
    // Unknown / non-storable target field is rejected.
    try std.testing.expectError(error.BadVector, build(a, col, "missing:[1,2]"));
    try std.testing.expectError(error.BadVector, build(a, col, "n:[1,2]"));
}

test "sqlite-vec extension is registered and vec_distance functions evaluate (KNN end-to-end)" {
    if (comptime !enabled) return error.SkipZigTest;
    const db = @import("../db.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The extension registered on open() exposes vec_distance_*; identical vectors -> distance 0.
    var st = try d.prepare("SELECT vec_distance_cosine('[1,2,3]', '[1,2,3]');");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expect(st.columnDouble(0) < 1e-6);

    // Nearest-neighbor ordering over a JSON embedding column orders the closest row first.
    try d.exec("CREATE TABLE emb (id TEXT, v TEXT);");
    try d.exec("INSERT INTO emb VALUES ('far','[0,1]'),('near','[1,0]'),('mid','[1,1]');");
    const v = try build(a, schema.Collection{ .id = "e", .name = "emb", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "v", .options = .{ .json = .{} } },
    } }, "v:l2:[1,0]");
    const sql = try std.fmt.allocPrintSentinel(a, "SELECT id FROM emb WHERE {s} ORDER BY {s};", .{ v.where_sql, v.order_sql }, 0);
    var qs = try d.prepare(sql);
    defer qs.finalize();
    try qs.bindText(1, v.param.text);
    try std.testing.expect(try qs.step());
    try std.testing.expectEqualStrings("near", qs.columnText(0)); // closest to [1,0]
}
