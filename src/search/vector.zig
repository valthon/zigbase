//! Vector / nearest-neighbor search (Theme A / #157; Postgres port #159 PR-11) — OPT-IN, gated
//! behind the non-default `-Dvector` build flag (`build_options.vector`). The SAME flag enables
//! vector search on BOTH backends: on SQLite it compiles the sqlite-vec amalgamation; on Postgres
//! it emits the pgvector lowering (no extra C — pgvector is a server EXTENSION). One flag, symmetric
//! semantics ("vector search is opt-in"), and a default build that is byte-for-byte unaffected.
//!
//! When the flag is OFF (the default build) this module is INERT: `enabled` is comptime-false,
//! `build` returns `error.VectorDisabled` (the list handler maps it to a clean 400 "vector search
//! not enabled in this build"), and the sqlite-vec C amalgamation is NOT compiled or linked, so the
//! shipped binary is byte-for-byte unaffected. When the flag is ON, `build` lowers the `?vector=`
//! KNN per the active dialect:
//!
//!   * **SQLite (sqlite-vec):** `build.zig` compiles `vendor/sqlite-vec/sqlite-vec.c` and `db.zig`
//!     registers the extension on every connection, exposing the `vec_distance_cosine` /
//!     `vec_distance_L2` scalar functions used to ORDER a list by distance to the query embedding.
//!   * **Postgres (pgvector):** the embedding column + the bound query embedding are cast to the
//!     `vector` type at query time (PostgreSQL's text→type I/O cast), ordered by the native pgvector
//!     KNN operators `<=>` (cosine distance) / `<->` (L2 distance). The `vector` type + operators
//!     come from the pgvector server extension, which `ensureExtension` provisions
//!     (`CREATE EXTENSION IF NOT EXISTS vector`) at startup. This is a brute-force scan — exactly
//!     symmetric with sqlite-vec's scalar `vec_distance_*` (no ANN index either side); a `vector(N)`
//!     column + ivfflat/hnsw ANN index is a documented future enhancement that would need a `dims`
//!     field option.
//!
//! Like full-text search, vector search is a READ path: `build` returns a WHERE fragment + an
//! ORDER-BY distance expression that `records.list` AND-s / appends into the SAME predicate
//! composition as filter + listRule + ability + tenant-scope + ttl — never a separate, unscoped
//! query. So a vector search on a tenant-/ability-guarded collection still returns ONLY rows the
//! caller may view, identically on both backends. The query embedding is ALWAYS a BOUND parameter
//! (`?` → `$n` on Postgres via the records.list ParamSink renumber), never interpolated; the target
//! column and collection identifiers are gated through `schema.isValidIdentifier`.
//!
//! Embeddings are stored in an ordinary `json`/`text` field as a JSON array (e.g. `[0.1,0.2,…]`);
//! sqlite-vec parses that JSON directly, and pgvector's `vector` text input format is byte-identical
//! to a JSON array (`[0.1,0.2,…]`), so the same stored value casts cleanly on Postgres. The query
//! param form is `vector=<field>[:cosine|:l2]:<json-embedding>` (cosine is the default metric).

const std = @import("std");
const build_options = @import("build_options");
const schema = @import("../schema.zig");
const compiler = @import("../query/compiler.zig");
const db = @import("../db.zig");

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

    /// Free the two OWNED SQL fragments (`where_sql` and `order_sql`, each an `allocPrint` on the
    /// caller allocator). `param.text` is deliberately NOT freed: it BORROWS from the caller-owned
    /// `raw` query-string input passed to `build` (it is a sub-slice of it), so freeing it here
    /// would free memory this struct never owned. In production `records.list` passes the request
    /// arena and reclaims the whole graph wholesale; this `deinit` lets a raw-allocator caller (the
    /// tests) free exactly the owned slices.
    pub fn deinit(self: Vector, alloc: std.mem.Allocator) void {
        alloc.free(self.where_sql);
        alloc.free(self.order_sql);
    }
};

/// The nearest-neighbor distance metric a `?vector=` query selects (default cosine).
const Metric = enum { cosine, l2 };

/// Build the KNN clause for a `vector=<field>[:metric]:<embedding>` param on `col` under `dialect`,
/// or an error. `error.VectorDisabled` in a default (non-`-Dvector`) build → the handler returns a
/// clean 400. `error.BadVector` for a malformed spec / unknown or non-storable target field. The
/// embedding is bound, never interpolated.
pub fn build(alloc: std.mem.Allocator, dialect: db.Dialect, col: schema.Collection, raw: []const u8) VectorError!Vector {
    if (comptime !enabled) return error.VectorDisabled;
    if (!schema.isValidIdentifier(col.name)) return error.BadVector;

    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return error.BadVector;
    const field = raw[0..colon];
    var rest = raw[colon + 1 ..];
    if (!schema.isValidIdentifier(field)) return error.BadVector;

    // Optional metric prefix (default cosine).
    var metric: Metric = .cosine;
    if (std.mem.startsWith(u8, rest, "cosine:")) {
        rest = rest["cosine:".len..];
    } else if (std.mem.startsWith(u8, rest, "l2:")) {
        metric = .l2;
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

    // Validate the query embedding is a non-empty JSON array of finite numbers BEFORE it reaches the
    // backend — a malformed or non-numeric body would otherwise surface as a runtime error (500).
    // (A dimension MISMATCH can only be caught at query time, since dims aren't part of the field
    // schema; the list handler maps that runtime error to a clean 400.)
    if (!try validEmbedding(alloc, rest)) return error.BadVector;

    // The WHERE fragment ("has an embedding") is identical on both backends; only the distance
    // ORDER-BY expression differs. The single bound `?` (the query embedding) is renumbered to `$n`
    // on Postgres by the records.list ParamSink pass.
    const where_sql = try std.fmt.allocPrint(alloc, "\"{s}\".\"{s}\" IS NOT NULL", .{ col.name, field });
    errdefer alloc.free(where_sql); // free the first fragment if the second allocPrint OOMs
    const order_sql = switch (dialect.kind) {
        // sqlite-vec scalar distance functions over the JSON-array column.
        .sqlite => try std.fmt.allocPrint(alloc, "{s}(\"{s}\".\"{s}\", ?)", .{
            switch (metric) {
                .cosine => "vec_distance_cosine",
                .l2 => "vec_distance_L2",
            },
            col.name,
            field,
        }),
        // pgvector: cast the stored column + the bound embedding to `vector` (text→type I/O cast)
        // and order by the native KNN operator (`<=>` cosine distance, `<->` L2). Smaller = nearer,
        // so ASC ordering yields nearest-first. `?::vector` renumbers to `$n::vector` (the `:` after
        // `?` is not a digit, so the ParamSink treats it as the anonymous placeholder).
        .postgres => try std.fmt.allocPrint(alloc, "(\"{s}\".\"{s}\")::vector {s} ?::vector", .{
            col.name,
            field,
            switch (metric) {
                .cosine => "<=>",
                .l2 => "<->",
            },
        }),
    };

    return .{
        .where_sql = where_sql,
        .order_sql = order_sql,
        .param = .{ .text = rest },
    };
}

/// Provision the pgvector server extension so the Postgres KNN lowering's `vector` type + `<=>`/
/// `<->` operators exist. A no-op unless `-Dvector` is compiled in AND the active backend is
/// Postgres. BEST-EFFORT: a role lacking `CREATE EXTENSION` privilege (or a managed Postgres where
/// the extension must be pre-installed by an admin) logs a warning rather than aborting startup — a
/// `?vector=` query then surfaces a clean runtime error at request time instead of taking the whole
/// server down. Called once from `provision.applySpecs` at startup. The target Postgres must have
/// the pgvector extension AVAILABLE (e.g. the `pgvector/pgvector:pgNN` image); see docs/api.md.
pub fn ensureExtension(w: *db.Db) void {
    if (comptime !enabled) return;
    if (db.dbDialect(w).kind != .postgres) return;
    w.exec("CREATE EXTENSION IF NOT EXISTS vector;") catch |e| {
        std.log.warn(
            "provision: could not ensure pgvector extension ({s}) — vector search (?vector=) will be unavailable until a privileged role runs 'CREATE EXTENSION vector'",
            .{@errorName(e)},
        );
    };
}

/// True iff `s` is a JSON array of one-or-more finite numbers (the only well-formed query embedding).
/// Rejects malformed JSON, a non-array, an empty array, or any non-numeric / non-finite element.
fn validEmbedding(alloc: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error!bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, s, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false, // any parse/syntax error => not a valid embedding
    };
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return false,
    };
    if (arr.items.len == 0) return false;
    for (arr.items) |it| switch (it) {
        .integer => {},
        .float => |fv| if (!std.math.isFinite(fv)) return false,
        else => return false,
    };
    return true;
}

// ---- Tests -----------------------------------------------------------------

test "vector build is disabled (clean error) in a default build" {
    if (comptime enabled) return error.SkipZigTest;
    // `build` returns `error.VectorDisabled` on its first line before allocating anything, so the
    // raw leak-detecting allocator is safe here (no owned graph escapes).
    const a = std.testing.allocator;
    const col = schema.Collection{ .id = "c", .name = "docs", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "embedding", .options = .{ .json = .{} } },
    } };
    try std.testing.expectError(error.VectorDisabled, build(a, db.Dialect.sqlite, col, "embedding:[0.1,0.2]"));
    try std.testing.expectError(error.VectorDisabled, build(a, db.Dialect.postgres, col, "embedding:[0.1,0.2]"));
}

test "vector build parses field/metric/embedding and binds the query vector (SQLite)" {
    if (comptime !enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    const col = schema.Collection{ .id = "c", .name = "docs", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "embedding", .options = .{ .json = .{} } },
        .{ .id = "f2", .name = "n", .options = .{ .number = .{} } },
    } };
    const v = try build(a, db.Dialect.sqlite, col, "embedding:[0.1,0.2,0.3]");
    defer v.deinit(a);
    try std.testing.expectEqualStrings("\"docs\".\"embedding\" IS NOT NULL", v.where_sql);
    try std.testing.expectEqualStrings("vec_distance_cosine(\"docs\".\"embedding\", ?)", v.order_sql);
    try std.testing.expectEqualStrings("[0.1,0.2,0.3]", v.param.text);
    // l2 metric prefix selects the L2 distance function.
    const v2 = try build(a, db.Dialect.sqlite, col, "embedding:l2:[1,2,3]");
    defer v2.deinit(a);
    try std.testing.expectEqualStrings("vec_distance_L2(\"docs\".\"embedding\", ?)", v2.order_sql);
    // Unknown / non-storable target field is rejected.
    try std.testing.expectError(error.BadVector, build(a, db.Dialect.sqlite, col, "missing:[1,2]"));
    try std.testing.expectError(error.BadVector, build(a, db.Dialect.sqlite, col, "n:[1,2]"));
    // A malformed / non-numeric embedding is rejected at build time (-> 400, never a SQLite 500).
    try std.testing.expectError(error.BadVector, build(a, db.Dialect.sqlite, col, "embedding:not-json"));
    try std.testing.expectError(error.BadVector, build(a, db.Dialect.sqlite, col, "embedding:[1,\"x\"]"));
    try std.testing.expectError(error.BadVector, build(a, db.Dialect.sqlite, col, "embedding:{\"a\":1}"));
    try std.testing.expectError(error.BadVector, build(a, db.Dialect.sqlite, col, "embedding:[]"));
}

test "vector build lowers to pgvector operators under the Postgres dialect" {
    if (comptime !enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    const col = schema.Collection{ .id = "c", .name = "docs", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "embedding", .options = .{ .json = .{} } },
    } };
    // Cosine (default) → `<=>`; both operands cast to `vector`. WHERE fragment is backend-identical.
    const v = try build(a, db.Dialect.postgres, col, "embedding:[0.1,0.2,0.3]");
    defer v.deinit(a);
    try std.testing.expectEqualStrings("\"docs\".\"embedding\" IS NOT NULL", v.where_sql);
    try std.testing.expectEqualStrings("(\"docs\".\"embedding\")::vector <=> ?::vector", v.order_sql);
    try std.testing.expectEqualStrings("[0.1,0.2,0.3]", v.param.text);
    // l2 metric → `<->`.
    const v2 = try build(a, db.Dialect.postgres, col, "embedding:l2:[1,2,3]");
    defer v2.deinit(a);
    try std.testing.expectEqualStrings("(\"docs\".\"embedding\")::vector <-> ?::vector", v2.order_sql);
    // Same validation as SQLite: unknown field / malformed embedding rejected at build time.
    try std.testing.expectError(error.BadVector, build(a, db.Dialect.postgres, col, "missing:[1,2]"));
    try std.testing.expectError(error.BadVector, build(a, db.Dialect.postgres, col, "embedding:[]"));
    // The `?::vector` placeholder renumbers to `$n::vector` under the Postgres ParamSink.
    const param_sink = @import("../sql/param_sink.zig");
    const rn = try param_sink.renumber(a, db.Dialect.postgres, v.order_sql);
    defer a.free(rn); // owned: postgres renumber rewrites onto a fresh buffer
    try std.testing.expectEqualStrings("(\"docs\".\"embedding\")::vector <=> $1::vector", rn);
}

test "validEmbedding accepts numeric arrays and rejects malformed input (build-independent)" {
    // `validEmbedding` allocates its parse tree on `alloc` and frees it via `parsed.deinit` before
    // returning a bool, so nothing escapes — the raw leak detector verifies that.
    const a = std.testing.allocator;
    try std.testing.expect(try validEmbedding(a, "[1,2,3]"));
    try std.testing.expect(try validEmbedding(a, "[0.1, -2.5, 3e2]"));
    try std.testing.expect(!try validEmbedding(a, "[]"));
    try std.testing.expect(!try validEmbedding(a, "not json"));
    try std.testing.expect(!try validEmbedding(a, "[1, \"two\"]"));
    try std.testing.expect(!try validEmbedding(a, "{\"v\":[1,2]}"));
    try std.testing.expect(!try validEmbedding(a, "42"));
}

test "sqlite-vec extension is registered and vec_distance functions evaluate (KNN end-to-end)" {
    if (comptime !enabled) return error.SkipZigTest;
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    // The extension registered on open() exposes vec_distance_*; identical vectors -> distance 0.
    var st = try d.prepare("SELECT vec_distance_cosine('[1,2,3]', '[1,2,3]');");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expect(st.columnDouble(0) < 1e-6);

    // Nearest-neighbor ordering over a JSON embedding column orders the closest row first.
    try d.exec("CREATE TABLE emb (id TEXT, v TEXT);");
    try d.exec("INSERT INTO emb VALUES ('far','[0,1]'),('near','[1,0]'),('mid','[1,1]');");
    const v = try build(a, db.Dialect.sqlite, schema.Collection{ .id = "e", .name = "emb", .fields = &[_]schema.Field{
        .{ .id = "f1", .name = "v", .options = .{ .json = .{} } },
    } }, "v:l2:[1,0]");
    defer v.deinit(a);
    const sql = try std.fmt.allocPrintSentinel(a, "SELECT id FROM emb WHERE {s} ORDER BY {s};", .{ v.where_sql, v.order_sql }, 0);
    defer a.free(sql);
    var qs = try d.prepare(sql);
    defer qs.finalize();
    try qs.bindText(1, v.param.text);
    try std.testing.expect(try qs.step());
    try std.testing.expectEqualStrings("near", qs.columnText(0)); // closest to [1,0]
}
