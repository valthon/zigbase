//! Full-text search (Theme A / #157, Postgres port #159 PR-10) — backend-specific full-text index
//! provisioning + the read-path search predicate that composes INTO `records.list`.
//!
//! A collection becomes SEARCHABLE when at least one of its text/editor fields sets the
//! `.searchable` schema flag (a backend-NEUTRAL property). At startup `ensureIndex` provisions the
//! backend's native full-text index; both lowerings live behind the SAME `?search=` surface and
//! `build` composes the SAME `records.list` WHERE/ORDER stack on either backend:
//!
//!   * **SQLite (FTS5):** an **external-content** shadow table (`"<col>_fts"`, `content='<col>'`)
//!     plus AFTER INSERT/UPDATE/DELETE triggers that keep it in lock-step with the base table, read
//!     via a JOIN + `"<fts>" MATCH ?` + row-local `zb_rank("<fts>") DESC` ordering (NOT bm25, whose
//!     corpus statistics span every tenant's rows — see `rank_fn`, #495). The index is
//!     (re)populated with the FTS5 `'rebuild'` command on first provision.
//!   * **Postgres (tsvector):** a STORED **generated column** `"<col>_fts"` of type `tsvector`
//!     (`to_tsvector('simple', coalesce("c1",'')||' '||…)`) plus a **GIN index**, read via
//!     `"<col>"."<col>_fts" @@ plainto_tsquery('simple', ?)` + `ORDER BY ts_rank(…) DESC`. No JOIN
//!     (the tsvector lives on the base table); the user term binds via `plainto_tsquery`, which
//!     parses plain text safely (no injection, no syntax errors).
//!
//! THE CRITICAL INVARIANT (#157/#159): search is a READ path. `build` returns a (possibly empty)
//! JOIN + a bound search predicate that `records.list` AND-s into the SAME WHERE composition as
//! filter + listRule + ability + tenant-scope + ttl — never a separate, unscoped query. So a search
//! on a tenant-/ability-guarded collection still returns ONLY rows the caller may view, identically
//! on both backends. The user's terms are ALWAYS a BOUND parameter (`?`), never interpolated (on
//! SQLite `sanitize` additionally lowers them to a guaranteed-valid FTS5 query; on Postgres
//! `plainto_tsquery` parses the bound term). Every identifier (the table/column name, each
//! searchable column) is gated through `schema.isValidIdentifier` before interpolation.

const std = @import("std");
const build_options = @import("build_options");
const schema = @import("../schema.zig");
const db = @import("../db.zig");
const compiler = @import("../query/compiler.zig");
const sqlite_c = @import("../c.zig").c;

/// Comptime gate: SQLite FTS5 is compiled in (`-Dfts5`, default ON). When false, the SQLite
/// MATCH/`ensureIndex` paths are comptime-dead and `?search=` fails closed with a clean 400.
/// Postgres full-text search (`buildPostgres`/`ensureIndexPg`) is NOT behind this flag.
pub const enabled = build_options.fts5;

/// Suffix appended to a collection name to form its FTS5 shadow table. Canonical in `schema.zig`
/// (where `schema.validate` reserves it on collection names) — aliased here for the table builder.
pub const suffix = schema.fts_suffix;

/// Defensive cap on a user search term we process (bounds work; longer input is truncated).
pub const max_term_len = 256;

/// Truncate `s` to at most `max` BYTES without splitting a multi-byte UTF-8 codepoint. A bare
/// byte-slice `s[0..max]` can cut mid-sequence, yielding invalid UTF-8 — which Postgres rejects on
/// a bound `text` param (a 500 on a crafted long-unicode search term); SQLite is byte-tolerant but
/// we back off there too for one consistent rule. If the cut lands on a UTF-8 continuation byte
/// (`0b10xxxxxx`), walk back to the start of that codepoint so the returned prefix is always valid
/// UTF-8. ASCII input is unaffected (every byte is its own boundary).
fn utf8SafeCap(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

test "utf8SafeCap never splits a codepoint; passes ASCII + short input through" {
    try std.testing.expectEqualStrings("abc", utf8SafeCap("abc", 8)); // short → unchanged
    try std.testing.expectEqualStrings("abcd", utf8SafeCap("abcdef", 4)); // ASCII cut on boundary
    // "é" is 2 bytes (C3 A9). A cap of 3 over "aéé" (a,C3,A9,C3,A9) would split the 2nd é → back off.
    try std.testing.expectEqualStrings("a\u{E9}", utf8SafeCap("a\u{E9}\u{E9}", 3));
    // A cap landing exactly after a full codepoint keeps it ("aéb" cut at 3 → "aé").
    try std.testing.expectEqualStrings("a\u{E9}", utf8SafeCap("a\u{E9}b", 3));
    // A 4-byte emoji (😀 = F0 9F 98 80) cut at 2 bytes backs off to empty (its lead byte excluded).
    try std.testing.expectEqual(@as(usize, 0), utf8SafeCap("\u{1F600}", 2).len);
}

/// The FTS5 shadow-table name for `col_name` (`"<col_name>_fts"`), on `alloc`. On Postgres the
/// same name identifies the STORED `tsvector` generated column on the base table.
pub fn tableName(alloc: std.mem.Allocator, col_name: []const u8) ![]u8 {
    return alloc.print("{s}{s}", .{ col_name, suffix });
}

/// The Postgres GIN index name for the tsvector column of `col_name` (`"<col_name>_fts_idx"`).
fn pgIndexName(alloc: std.mem.Allocator, col_name: []const u8) ![]u8 {
    return alloc.print("{s}{s}_idx", .{ col_name, suffix });
}

/// The Postgres text-search configuration used for both the generated `tsvector` and the
/// `plainto_tsquery` at read time (they MUST agree). `'simple'` mirrors SQLite FTS5's default
/// unicode61 tokenizer (no stemming, no stopwords) for the closest cross-backend parity.
///
/// MUST stay a comptime literal. Unlike every other identifier interpolated into SQL here, this
/// one lands inside a SINGLE-QUOTED SQL LITERAL (`plainto_tsquery('…')`), an escaping context
/// `schema.isValidIdentifier` does not cover — so a runtime value carrying a `'` would be
/// injection, not a rejected identifier. Every use below concatenates it at COMPTIME (`++`)
/// rather than formatting it with `{s}`, which makes that structural: a runtime value cannot be
/// `++`-ed into a comptime string, so making this configurable (e.g. a per-collection language)
/// fails to COMPILE instead of silently opening an injection. Prefer compile errors to runtime
/// crashes, and runtime crashes to bugs.
const pg_ts_config = "simple";

comptime {
    // Belt-and-braces on the literal itself: the `++` sites below prevent a RUNTIME value, and
    // this prevents an author-written one that would break out of the surrounding single quotes.
    for (pg_ts_config) |c| if (c == '\'' or c == '\\')
        @compileError("pg_ts_config is interpolated into a single-quoted SQL literal and must not contain a quote or backslash");
}

/// True iff `col` DECLARES at least one indexable searchable field — i.e. the schema asks for
/// full-text search — regardless of whether the engine can actually provision an index for the
/// collection. Split out of `isSearchable` deliberately: conflating "the schema asks for search"
/// with "the engine will serve it" is what let the provisioner skip a collection in complete
/// silence. `ensureIndex` needs the first question to decide whether a skip is worth reporting.
fn hasSearchableField(col: schema.Collection) bool {
    for (col.fields) |f| if (isIndexedField(f)) return true;
    return false;
}

/// A field the search index covers: flagged searchable, a text/editor type, a valid identifier,
/// and not encrypted.
pub fn isIndexedField(f: schema.Field) bool {
    return f.searchable and schema.isSearchableType(f.fieldType()) and schema.isValidIdentifier(f.name) and !f.encrypted;
}

/// True iff `col` has at least one valid, searchable column AND a valid table identifier — i.e.
/// `ensureIndex` will provision an FTS5 index and `build` can compose a MATCH predicate for it.
///
/// The table-identifier half is why `records.list` answers `?search=` on a `_`-prefixed system
/// collection with `error.NotSearchable` (loud) instead of quietly dropping the MATCH predicate and
/// returning every row — so this gate must keep failing closed here.
pub fn isSearchable(col: schema.Collection) bool {
    if (!schema.isValidIdentifier(col.name)) return false;
    return hasSearchableField(col);
}

/// The searchable column names of `col` (valid identifiers, text/editor, non-encrypted), on
/// `alloc`. Empty when the collection is not searchable.
fn searchableColumns(alloc: std.mem.Allocator, col: schema.Collection) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (col.fields) |f| if (isIndexedField(f)) try out.append(alloc, f.name);
    return out.toOwnedSlice(alloc);
}

/// A compiled, parameter-bound full-text search clause AND-ed into the list query by
/// `records.list`. `join_sql` brings the FTS shadow table into the query (no params; **empty on
/// Postgres**, where the tsvector lives on the base table); `where_sql` is the bound search
/// predicate (one trailing `?` — `MATCH` on SQLite, `@@ plainto_tsquery(…)` on Postgres);
/// `order_sql` is the relevance ordering (row-local `zb_rank("<fts>") DESC` on SQLite,
/// `ts_rank(…) DESC` on Postgres). `param` is the bound WHERE term (the SANITIZED FTS5 query on
/// SQLite, the raw term for `plainto_tsquery` on Postgres). `order_param`, when non-null, is the
/// SECOND bound term consumed by `order_sql` (Postgres `ts_rank` re-runs `plainto_tsquery`); it is
/// null on SQLite (`zb_rank` takes no param), and `records.list` binds it in the ORDER BY position
/// when present.
pub const Search = struct {
    join_sql: []const u8,
    where_sql: []const u8,
    order_sql: []const u8,
    param: compiler.Param,
    order_param: ?compiler.Param = null,
};

/// `build`'s error set is EXPLICIT (not inferred) so `error.SearchDisabled` is a member
/// regardless of the `-Dfts5` flag's value: when the default (ON) build's `buildSqlite` branch
/// comptime-prunes the guard away, an inferred `!?Search` would silently DROP `SearchDisabled`
/// from the type, breaking every well-typed `error.SearchDisabled => …` handler in a default
/// build. Mirrors `vector.zig`'s `VectorError` for the same reason (opposite default).
pub const SearchError = error{ SearchDisabled, SearchRankUnavailable } ||
    @typeInfo(@typeInfo(@TypeOf(buildSqliteImpl)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(buildPostgres)).@"fn".return_type.?).error_union.error_set;

/// Build the full-text search clause for `raw_term` on `col` for the connection `conn` that will
/// run it, or null when the collection is not searchable OR the term carries no searchable token.
/// Allocations are on `alloc`. The bound `param`/`order_param` are never interpolated.
///
/// Takes the CONNECTION, not just its dialect, because the SQLite ordering calls the row-local
/// rank function (`rank_fn`), which FTS5 keeps per connection: `build` registers it on `conn`
/// (once per connection) before returning SQL that names it. Every SQLite connection that runs a
/// search — the writer, a pooled reader, a fresh overflow reader — therefore has it, with no
/// separate registration step a new connection path could forget.
pub fn build(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, raw_term: []const u8) SearchError!?Search {
    if (!isSearchable(col)) return null;
    return switch (db.dbDialect(conn).kind) {
        .sqlite => buildSqlite(alloc, conn, col, raw_term),
        .postgres => buildPostgres(alloc, col, raw_term),
    };
}

/// SQLite lowering: `error.SearchDisabled` when `-Dfts5=false` (this branch folds to comptime-dead
/// there — see `enabled`); otherwise a JOIN onto the FTS5 shadow table + a bound `MATCH` predicate
/// + row-local `rank_fn` ordering. `param.text` is the SANITIZED, guaranteed-valid FTS5 query
/// (`sanitize`).
fn buildSqlite(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, raw_term: []const u8) SearchError!?Search {
    if (comptime !enabled) return error.SearchDisabled;
    try ensureRankFunction(conn);
    return buildSqliteImpl(alloc, col, raw_term);
}

// ---- Row-local ranking (SQLite) --------------------------------------------
//
// Why not FTS5's built-in bm25 `rank` (#495): the shadow table indexes EVERY row of the
// collection, across tenants, and bm25 weighs each term by corpus statistics — IDF from the
// table's row count and per-term document counts, length normalisation against the table's
// average row length. So the ORDER of one tenant's (correctly scoped) results moved with text
// other tenants had stored: a member of one tenant could rank two of their own records and learn,
// one bit per query, whether another tenant's searchable text contained a word.
//
// `rank_fn` scores a row from that row ALONE. It reads only:
//   * per-phrase hit counts in this row (`xPhraseFirst`/`xPhraseNext` over the row's instances),
//   * this row's token count across the searchable columns (`xColumnSize(-1)`).
// It never calls `xRowCount`, `xColumnTotalSize` or `xQueryPhrase` (the corpus-wide APIs).
//
//   score = ( Σ_p tf_p / (tf_p + 1) ) / log2(1 + L)
//
// where p ranges over the query's phrases (each search token is one phrase), tf_p is the number
// of times phrase p occurs in the row (0 for an OR branch the row does not match) and L is the
// row's total token count. The per-phrase term saturates (1 hit → 0.5, 2 → 0.67, 3 → 0.75), so a
// row matching MORE DISTINCT terms outranks one repeating a single term at comparable length,
// more hits outrank fewer at equal length, and the length divisor prefers a DENSER (shorter) row
// at equal hits. Every searchable field weighs the same (the schema has no per-field weights
// today). Higher is better (`ORDER BY … DESC`); `records.list` breaks equal scores by record id,
// which is itself row-local.

/// The SQL name of the row-local FTS5 rank auxiliary function.
pub const rank_fn = "zb_rank";

/// `sqlite3_get_clientdata` key marking a connection on which `rank_fn` is registered. FTS5's
/// `xCreateFunction` does not deduplicate (each call prepends another entry that lives until the
/// connection closes), so registration must happen at most once per connection.
const rank_clientdata_key = "zigbase.fts.rank";
var rank_marker: u8 = 1; // any non-null pointer marks "registered"; never dereferenced

/// Register `rank_fn` on `conn` unless already registered there. Idempotent and cheap after the
/// first call (one client-data lookup). SQLite-only; `conn` must be a SQLite connection.
pub fn ensureRankFunction(conn: *db.Db) error{SearchRankUnavailable}!void {
    if (comptime !enabled) return;
    const handle = db.sqliteHandle(conn);
    if (sqlite_c.sqlite3_get_clientdata(handle, rank_clientdata_key) != null) return;
    registerRankFunction(handle) catch |err| {
        // The one place this failure is logged; the caller maps it to a clean 500.
        std.log.err("search: cannot register FTS5 rank function '{s}': {s}", .{ rank_fn, std.mem.span(sqlite_c.sqlite3_errmsg(handle)) });
        return err;
    };
}

/// Register `rank_fn` on `handle` and mark the connection. The marker is set FIRST and cleared
/// again if `xCreateFunction` fails, so after a return the marker is set iff the function is
/// registered: a marker failure (OOM) registers nothing, and a registration failure leaves no
/// marker that would skip the next attempt.
fn registerRankFunction(handle: *sqlite_c.sqlite3) error{SearchRankUnavailable}!void {
    const c = sqlite_c;
    // The documented way to reach the FTS5 C API: `SELECT fts5(?1)` with a pointer bound under
    // the "fts5_api_ptr" type tag; FTS5 writes its `fts5_api*` through it.
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(handle, "SELECT fts5(?1);", -1, &stmt, null) != c.SQLITE_OK or stmt == null)
        return error.SearchRankUnavailable;
    defer _ = c.sqlite3_finalize(stmt);
    var api: ?*c.fts5_api = null;
    if (c.sqlite3_bind_pointer(stmt, 1, @ptrCast(&api), "fts5_api_ptr", null) != c.SQLITE_OK)
        return error.SearchRankUnavailable;
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SearchRankUnavailable;
    const fts5 = api orelse return error.SearchRankUnavailable;
    const create = fts5.xCreateFunction orelse return error.SearchRankUnavailable;
    if (c.sqlite3_set_clientdata(handle, rank_clientdata_key, @ptrCast(&rank_marker), null) != c.SQLITE_OK)
        return error.SearchRankUnavailable;
    if (create(fts5, rank_fn, null, rowLocalRank, null) != c.SQLITE_OK) {
        // Clearing an entry (a NULL value) frees it and cannot fail.
        _ = c.sqlite3_set_clientdata(handle, rank_clientdata_key, null, null);
        return error.SearchRankUnavailable;
    }
}

/// The FTS5 auxiliary function behind `rank_fn` — see the formula above. Row-local by
/// construction: it touches only the current row's phrase instances and token count.
fn rowLocalRank(
    api_ptr: [*c]const sqlite_c.Fts5ExtensionApi,
    fts: ?*sqlite_c.Fts5Context,
    ctx: ?*sqlite_c.sqlite3_context,
    n_val: c_int,
    vals: [*c]?*sqlite_c.sqlite3_value,
) callconv(.c) void {
    const c = sqlite_c;
    _ = vals;
    if (n_val != 0) return c.sqlite3_result_error(ctx, rank_fn ++ "() takes no arguments beyond the table", -1);
    const api: *const c.Fts5ExtensionApi = api_ptr; // borrow FTS5's table; no copy
    var tokens: c_int = 0;
    var rc = api.xColumnSize.?(fts, -1, &tokens);
    if (rc != c.SQLITE_OK) return c.sqlite3_result_error_code(ctx, rc);
    const n_phrase = api.xPhraseCount.?(fts);
    var coverage: f64 = 0; // allocation-free: one running sum, one phrase at a time
    var p: c_int = 0;
    while (p < n_phrase) : (p += 1) {
        var it: c.Fts5PhraseIter = undefined;
        var icol: c_int = 0;
        var ioff: c_int = 0;
        rc = api.xPhraseFirst.?(fts, p, &it, &icol, &ioff);
        if (rc != c.SQLITE_OK) return c.sqlite3_result_error_code(ctx, rc);
        var tf: f64 = 0;
        while (icol >= 0) : (api.xPhraseNext.?(fts, &it, &icol, &ioff)) tf += 1;
        coverage += tf / (tf + 1);
    }
    c.sqlite3_result_double(ctx, rowLocalScore(coverage, tokens));
}

/// The pure half of `rowLocalRank`: `coverage` = Σ_p tf_p/(tf_p+1), `tokens` = the row's length.
fn rowLocalScore(coverage: f64, tokens: c_int) f64 {
    const len: f64 = @floatFromInt(@max(tokens, 1));
    return coverage / std.math.log2(1 + len);
}

fn buildSqliteImpl(alloc: std.mem.Allocator, col: schema.Collection, raw_term: []const u8) !?Search {
    const q = (try sanitize(alloc, raw_term)) orelse return null;
    errdefer alloc.free(q); // q ESCAPES into `.param.text` on success; free it only on an error below
    const ft = try tableName(alloc, col.name);
    defer alloc.free(ft); // internal scratch: copied into the SQL strings below, never escapes
    // Build each escaping fragment into an errdefer'd local: if a LATER allocPrint OOMs, the
    // already-built ones are freed. On success they move into the returned Search (errdefer does
    // not fire), where the caller owns them.
    const join_sql = try alloc.print("JOIN \"{s}\" ON \"{s}\".\"rowid\" = \"{s}\".\"rowid\"", .{ ft, ft, col.name });
    errdefer alloc.free(join_sql);
    const where_sql = try alloc.print("\"{s}\" MATCH ?", .{ft});
    errdefer alloc.free(where_sql);
    const order_sql = try alloc.print(rank_fn ++ "(\"{s}\") DESC", .{ft});
    errdefer alloc.free(order_sql); // last today, but errdefer'd too so a future line before the return can't leak it
    return .{ .join_sql = join_sql, .where_sql = where_sql, .order_sql = order_sql, .param = .{ .text = q } };
}

/// Postgres lowering: no JOIN (the `tsvector` is a generated column on the base table), a bound
/// `@@ plainto_tsquery('simple', ?)` predicate, and `ORDER BY ts_rank(…) DESC` (which re-runs
/// `plainto_tsquery` on a SECOND bound copy of the term → `order_param`). The raw, trimmed term is
/// bound directly: `plainto_tsquery` parses plain text safely (no syntax error, no injection), so
/// no FTS5-style `sanitize` is needed. Returns null only when the trimmed term is empty.
fn buildPostgres(alloc: std.mem.Allocator, col: schema.Collection, raw_term: []const u8) !?Search {
    const trimmed = std.mem.trim(u8, raw_term, " \t\r\n");
    const capped = utf8SafeCap(trimmed, max_term_len); // cap on a UTF-8 boundary (never mid-codepoint)
    if (capped.len == 0) return null;
    const term = try alloc.dupe(u8, capped);
    errdefer alloc.free(term); // term ESCAPES into `.param`/`.order_param` (one alloc) on success
    const tsv = try tableName(alloc, col.name); // the generated tsvector column name
    defer alloc.free(tsv); // internal scratch: copied into the SQL strings below, never escapes
    // where_sql into an errdefer'd local so an order_sql OOM frees it (join_sql is a literal).
    const where_sql = try alloc.print("\"{s}\".\"{s}\" @@ plainto_tsquery('" ++ pg_ts_config ++ "', ?)", .{ col.name, tsv });
    errdefer alloc.free(where_sql);
    const order_sql = try alloc.print("ts_rank(\"{s}\".\"{s}\", plainto_tsquery('" ++ pg_ts_config ++ "', ?)) DESC", .{ col.name, tsv });
    errdefer alloc.free(order_sql); // last today, but errdefer'd too so a future line before the return can't leak it
    return .{
        .join_sql = "",
        .where_sql = where_sql,
        .order_sql = order_sql,
        .param = .{ .text = term },
        .order_param = .{ .text = term },
    };
}

/// Lower an arbitrary user search string into a GUARANTEED-VALID FTS5 query, or null if it carries
/// no searchable tokens. Each whitespace-delimited token is wrapped in double quotes (an embedded
/// `"` is doubled to escape it), which neutralizes any FTS5-special characters inside the token, so
/// no input can become a syntax error. The boolean operators `AND`/`OR`/`NOT` are preserved between
/// terms (leading, trailing and doubled operators are dropped so the query is always well-formed),
/// and a trailing `*` keeps prefix-search working. Space-separated terms default to FTS5's implicit
/// AND. This is defense-in-depth ON TOP OF parameter binding (which already prevents injection).
pub fn sanitize(alloc: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const capped = utf8SafeCap(trimmed, max_term_len); // cap on a UTF-8 boundary (never mid-codepoint)

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc); // free the partial buffer if an append OOMs mid-build (the `out.items
    // .len == 0` early return leaves `out` empty/unallocated, so its no-op deinit there is harmless)
    var emitted_term = false;
    var pending_op: ?[]const u8 = null; // an operator seen AFTER a term, applied to the next term
    var it = std.mem.tokenizeAny(u8, capped, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "AND") or std.mem.eql(u8, tok, "OR") or std.mem.eql(u8, tok, "NOT")) {
            if (emitted_term) pending_op = tok; // a leading operator is ignored (no term yet)
            continue;
        }
        // Prefix search: a single trailing '*' is kept as an operator after the quoted token.
        var word = tok;
        var prefix = false;
        if (word.len > 1 and word[word.len - 1] == '*') {
            prefix = true;
            word = word[0 .. word.len - 1];
        }
        if (word.len == 0) continue;

        if (emitted_term) {
            // Implicit AND between adjacent terms; an explicit operator overrides it.
            if (pending_op) |op| {
                try out.append(alloc, ' ');
                try out.appendSlice(alloc, op);
                try out.append(alloc, ' ');
            } else {
                try out.append(alloc, ' ');
            }
        }
        pending_op = null;
        try out.append(alloc, '"');
        for (word) |ch| {
            if (ch == '"') try out.append(alloc, '"'); // double to escape inside an FTS5 string
            try out.append(alloc, ch);
        }
        try out.append(alloc, '"');
        if (prefix) try out.append(alloc, '*');
        emitted_term = true;
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(alloc);
}

// ---- Provisioning ----------------------------------------------------------

/// `ensureIndex`'s error set is EXPLICIT for the same reason as `SearchError` above: the default
/// (`-Dfts5` ON) build comptime-prunes the `SearchDisabled` guard, so an inferred `!void` would
/// silently drop it from the type and break `provision.zig`'s `catch |err| switch (err) { … }`.
pub const EnsureIndexError = error{SearchDisabled} || @import("ownership.zig").Error ||
    @typeInfo(@typeInfo(@TypeOf(ensureIndexSqliteImpl)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(ensureIndexPg)).@"fn".return_type.?).error_union.error_set;

/// Provision (idempotently) the FTS5 external-content index + sync triggers for `col`, repopulating
/// it on first build. A no-op when `col` has no searchable fields (any stale index from a previous
/// schema is dropped). Re-creates the index when its column set drifts OR its sync triggers are
/// missing (e.g. after an additive table rebuild dropped them). Called from `provision.ensureCollection`
/// at startup — NOT a numbered migration. Identifiers are gated through `schema.isValidIdentifier`.
pub fn ensureIndex(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) EnsureIndexError!void {
    return inspectIndex(alloc, w, col, true);
}

/// Self-freeing. Remove `col`'s engine-owned search objects (the SQLite FTS5 shadow table and its
/// sync triggers, or the Postgres tsvector column and GIN index), if any, after the same ownership
/// checks `ensureIndex` applies. `col.name`'s base table must still exist. Used by the runtime
/// schema paths (`collections.update`/`delete`) before DDL that would orphan or break the objects;
/// a no-op when there are none.
///
/// A SQLite build with `-Dfts5=false` cannot drop an FTS5 table (the module is absent), so when
/// one exists this returns `error.SearchDisabled` rather than leave it orphaned.
pub fn dropIndexFor(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) EnsureIndexError!void {
    if (comptime !enabled) {
        if (db.dbDialect(w).kind == .sqlite) {
            if (!schema.isValidIdentifier(col.name)) return;
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            const sa = scratch.allocator();
            if (try tableExists(sa, w, try tableName(sa, col.name))) return error.SearchDisabled;
            return;
        }
    }
    var without_search = col;
    without_search.fields = &.{};
    return ensureIndex(alloc, w, without_search);
}

/// True iff `a` and `b` produce the same search index: the same table name and the same indexed
/// columns with the same stable field ids in the same order (the FTS5 column order and the
/// Postgres tsvector expression order). A new id replaces the column even if its name is unchanged.
/// When true, DDL that leaves those columns' names and storage alone keeps the index valid. When
/// false, the index must be dropped BEFORE the DDL: Postgres refuses to drop or retype a column
/// its generated tsvector reads, and the SQLite ownership check refuses a shadow table naming a
/// column the base table no longer has.
pub fn sameSearchColumns(a: schema.Collection, b: schema.Collection) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.fields.len and !isIndexedField(a.fields[i])) i += 1;
        while (j < b.fields.len and !isIndexedField(b.fields[j])) j += 1;
        if (i == a.fields.len or j == b.fields.len) return i == a.fields.len and j == b.fields.len;
        if (!std.mem.eql(u8, a.fields[i].name, b.fields[j].name)) return false;
        if (!std.mem.eql(u8, a.fields[i].id, b.fields[j].id)) return false;
        i += 1;
        j += 1;
    }
}

/// Remove proven engine search state before a base-table rebuild, while old operands exist.
/// Validation must run before any DROP; a conflicting migration object is never adopted.
pub fn removeForRebuild(alloc: std.mem.Allocator, w: *db.Db, old: schema.Collection) EnsureIndexError!void {
    return dropIndexFor(alloc, w, old);
}

/// Self-freeing. Validate the current physical search objects without reconciling
/// the desired fields, which may not exist until additive provisioning finishes.
pub fn validateIndex(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) EnsureIndexError!void {
    return inspectIndex(alloc, w, col, false);
}

fn inspectIndex(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, reconcile: bool) EnsureIndexError!void {
    // ONE identifier gate for both backends (the per-backend impls below therefore need none). A
    // `_`-prefixed engine-owned name fails `isValidIdentifier`, and the provisioner does not index
    // such a collection — correct, because the read path already refuses `?search=` on it with
    // `error.NotSearchable` rather than silently serving unfiltered rows.
    //
    // What was wrong is that the skip was SILENT even when the schema asked for search: a migration
    // that seeded a searchable system collection would leave `?search=` failing with nothing in the
    // logs pointing at the cause. Skipping a collection with nothing to index stays quiet (every
    // system collection today), but skipping one that DECLARED searchable fields now says so.
    if (!schema.isValidIdentifier(col.name)) {
        if (hasSearchableField(col)) std.log.warn(
            "search: collection '{s}' declares searchable field(s) but was SKIPPED by the full-text " ++
                "provisioner: its name is not a valid identifier (a leading '_' marks an engine-owned " ++
                "collection, which the search provisioner does not index). No index exists for it, so " ++
                "?search= on '{s}' will fail with NotSearchable. To make it searchable, rename the " ++
                "collection to start with a letter; to silence this, drop .searchable from its fields.",
            .{ col.name, col.name },
        );
        return;
    }
    if (comptime !enabled) {
        // SQLite builds without FTS must not pay for a schema transaction on
        // the no-search path. PostgreSQL search is independent of this flag.
        if (db.dbDialect(w).kind == .sqlite) {
            if (isSearchable(col)) return error.SearchDisabled;
            return;
        }
    }
    // Ownership probes and reconciliation share one transaction. A collision or
    // failed rebuild cannot leave partially dropped search objects behind.
    const nested = w.inTransaction();
    if (nested) try w.exec("SAVEPOINT zb_fts_provision;") else try w.begin();
    errdefer {
        if (nested) {
            w.exec("ROLLBACK TO SAVEPOINT zb_fts_provision;") catch |err| std.debug.panic("search provisioning rollback failed: {s}", .{@errorName(err)});
            w.exec("RELEASE SAVEPOINT zb_fts_provision;") catch |err| std.debug.panic("search provisioning cleanup failed: {s}", .{@errorName(err)});
        } else w.rollback() catch |err| std.debug.panic("search provisioning rollback failed: {s}", .{@errorName(err)});
    }
    try @import("ownership.zig").verify(alloc, w, col, null);
    if (reconcile) try ensureIndexImpl(alloc, w, col);
    if (nested) try w.exec("RELEASE SAVEPOINT zb_fts_provision;") else try w.commit();
}

fn ensureIndexImpl(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) EnsureIndexError!void {
    // Backend split: the FTS5 external-content vtable + sync triggers + sqlite_master probes below
    // are SQLite-only. Postgres provisions a STORED `tsvector` generated column + GIN index instead
    // (same `?search=` read surface, lowered by `buildPostgres`). Both are idempotent and called
    // from `provision.ensureCollection` at startup — NOT numbered migrations.
    if (db.dbDialect(w).kind == .postgres) {
        return ensureIndexPg(alloc, w, col);
    }
    if (comptime !enabled) unreachable; // ensureIndex handled SQLite's disabled arm.
    return ensureIndexSqliteImpl(alloc, w, col);
}

fn ensureIndexSqliteImpl(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) !void {
    // Identifier gate: `ensureIndex` (the only caller) already applied it, loudly.
    // Self-freeing (contract 1): every allocation here is scratch — the FTS5 table name, the
    // searchable-column list, the existence/columns/triggers probes, and the CREATE VIRTUAL TABLE /
    // CREATE TRIGGER / rebuild DDL strings — all consumed by `w.exec`/`w.prepare` (SQLite copies the
    // statement text) and none escaping the void return. Build them on a function-local arena so the
    // idempotent per-collection provisioning is leak-correct under any allocator.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const ft = try tableName(sa, col.name);
    const cols = try searchableColumns(sa, col);

    if (cols.len == 0) {
        // Not searchable: only touch the DB if a stale index actually exists (so a non-searchable
        // collection costs one cheap existence check, not four DROPs, at every startup).
        if (try tableExists(sa, w, ft)) try dropIndex(sa, w, col.name, ft);
        return;
    }

    if (try tableExists(sa, w, ft)) {
        if ((try columnsMatch(sa, w, ft, cols)) and (try triggersPresent(sa, w, col.name)))
            return; // up to date — idempotent no-op
        try dropIndex(sa, w, col.name, ft); // drift / missing triggers — rebuild from scratch
    }

    // CREATE VIRTUAL TABLE "<col>_fts" USING fts5(c1, c2, …, content='<col>');
    var create: std.ArrayList(u8) = .empty;
    try create.appendSlice(sa, try sa.print("CREATE VIRTUAL TABLE \"{s}\" USING fts5(", .{ft}));
    for (cols, 0..) |cn, i| {
        if (i > 0) try create.appendSlice(sa, ", ");
        try create.appendSlice(sa, try sa.print("\"{s}\"", .{cn}));
    }
    try create.appendSlice(sa, try sa.print(", content=\"{s}\");", .{col.name}));
    try w.exec(try toZ(sa, create.items));

    // Sync triggers (FTS5 external-content pattern). On delete/update we issue the special 'delete'
    // command so the index discards the old terms before re-indexing the new row.
    const col_list = try columnList(sa, cols, null);
    const new_list = try columnList(sa, cols, "new");
    const old_list = try columnList(sa, cols, "old");

    try w.exec(try toZ(sa, try sa.print("CREATE TRIGGER \"{s}_ai\" AFTER INSERT ON \"{s}\" BEGIN INSERT INTO \"{s}\"(rowid, {s}) VALUES (new.rowid, {s}); END;", .{ ft, col.name, ft, col_list, new_list })));
    try w.exec(try toZ(sa, try sa.print("CREATE TRIGGER \"{s}_ad\" AFTER DELETE ON \"{s}\" BEGIN INSERT INTO \"{s}\"(\"{s}\", rowid, {s}) VALUES ('delete', old.rowid, {s}); END;", .{ ft, col.name, ft, ft, col_list, old_list })));
    try w.exec(try toZ(sa, try sa.print("CREATE TRIGGER \"{s}_au\" AFTER UPDATE ON \"{s}\" BEGIN INSERT INTO \"{s}\"(\"{s}\", rowid, {s}) VALUES ('delete', old.rowid, {s}); INSERT INTO \"{s}\"(rowid, {s}) VALUES (new.rowid, {s}); END;", .{ ft, col.name, ft, ft, col_list, old_list, ft, col_list, new_list })));

    // Repopulate from the content table (no-op on an empty table).
    try w.exec(try toZ(sa, try sa.print("INSERT INTO \"{s}\"(\"{s}\") VALUES ('rebuild');", .{ ft, ft })));

    std.log.info("provision: ensured FTS5 search index '{s}' on '{s}' ({d} field(s))", .{ ft, col.name, cols.len });
}

// ---- Postgres provisioning (tsvector generated column + GIN index) ---------

/// Provision (idempotently) the Postgres `tsvector` full-text index for `col`: a STORED generated
/// column `"<col>_fts"` over the searchable columns plus a GIN index on it. A no-op when `col` has
/// no searchable fields (any stale column/index from a prior schema is dropped). Decides off the
/// column's three-state probe (`pgColumnState`): absent → create; present+matching-marker → no-op
/// (or recreate JUST the GIN index if only it is missing, NEVER re-touching the costly generated
/// column); present+different valid marker (a searchable-column-SET drift) → drop + recreate.
/// The shared ownership preflight rejects missing markers and application-owned objects. All
/// identifiers are gated through `schema.isValidIdentifier`; the column set is embedded only after
/// that gate, never from user input. Search-path-aware (`to_regclass`) so it targets the
/// collection's table in the active schema.
fn ensureIndexPg(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) !void {
    // Identifier gate: `ensureIndex` (the only caller) already applied it, loudly.
    // These provisioning temporaries are explicitly freed (the SQL strings are copied by
    // `prepare`/`exec`, and `bindText` dupes its arg, so freeing after the call is safe). In the
    // startup `applySpecs` path the caller's allocator is an arena reclaimed wholesale, so the
    // frees are no-ops there; they keep this correct under a general-purpose allocator too.
    const tsv = try tableName(alloc, col.name); // "<col>_fts" — the generated tsvector column
    defer alloc.free(tsv);
    const idx = try pgIndexName(alloc, col.name); // "<col>_fts_idx" — the GIN index
    defer alloc.free(idx);
    const cols = try searchableColumns(alloc, col);
    defer alloc.free(cols); // the element strings are borrowed field names; free only the slice
    const want_marker = try pgMarker(alloc, cols);
    defer alloc.free(want_marker);

    const state = try pgColumnState(alloc, w, col.name, tsv);
    defer switch (state) {
        .present => |m| if (m) |mk| alloc.free(mk),
        .absent => {},
    };

    if (cols.len == 0) {
        // Not searchable: drop a stale column/index only if the column actually exists.
        if (state == .present) try dropIndexPg(alloc, w, col.name, tsv);
        return;
    }

    switch (state) {
        .present => |have_marker| {
            const marker_ok = have_marker != null and std.mem.eql(u8, have_marker.?, want_marker);
            if (marker_ok) {
                // The generated column + its marker are correct. If the GIN index is also present,
                // we are fully provisioned — no-op. If ONLY the index is missing, recreate JUST the
                // index: dropping+rebuilding the STORED generated column would take a strong table
                // lock and re-tokenize every row for nothing.
                if (try pgRelExists(alloc, w, idx)) return; // fully up to date — idempotent no-op
                try createGinIndexPg(alloc, w, col.name, tsv, idx);
                std.log.info("provision: recreated missing GIN index '{s}' on '{s}'.'{s}'", .{ idx, col.name, tsv });
                return;
            }
            // Proven engine column with a different marker → drift → DROP column+index, then
            // recreate below (never `ADD COLUMN` onto the existing one).
            try dropIndexPg(alloc, w, col.name, tsv);
        },
        .absent => {}, // nothing to drop — create below
    }

    // ALTER TABLE "<col>" ADD COLUMN "<tsv>" tsvector
    //   GENERATED ALWAYS AS (to_tsvector('simple', coalesce("c1",'')||' '||coalesce("c2",'')||…)) STORED;
    // The 2-arg to_tsvector(regconfig, text) with a literal config is IMMUTABLE (required for a
    // generated column); coalesce keeps NULL columns from voiding the whole vector.
    var expr: std.ArrayList(u8) = .empty;
    defer expr.deinit(alloc);
    // Comptime-concatenated, so there is nothing to format and nothing to free.
    try expr.appendSlice(alloc, "to_tsvector('" ++ pg_ts_config ++ "', ");
    for (cols, 0..) |cn, i| {
        if (i > 0) try expr.appendSlice(alloc, " || ' ' || ");
        const frag = try alloc.print("coalesce(\"{s}\",'')", .{cn});
        defer alloc.free(frag);
        try expr.appendSlice(alloc, frag);
    }
    try expr.appendSlice(alloc, ")");

    {
        const sql = try alloc.printSentinel("ALTER TABLE \"{s}\" ADD COLUMN \"{s}\" tsvector GENERATED ALWAYS AS ({s}) STORED;", .{ col.name, tsv, expr.items }, 0);
        defer alloc.free(sql);
        try w.exec(sql);
    }
    try createGinIndexPg(alloc, w, col.name, tsv, idx);
    {
        // Record the searchable column set as a marker comment so a later additive change that adds
        // or removes a `.searchable` field is detected as drift and rebuilds the column.
        const sql = try alloc.printSentinel("COMMENT ON COLUMN \"{s}\".\"{s}\" IS '{s}';", .{ col.name, tsv, want_marker }, 0);
        defer alloc.free(sql);
        try w.exec(sql);
    }

    std.log.info("provision: ensured tsvector search index '{s}' (GIN '{s}') on '{s}' ({d} field(s))", .{ tsv, idx, col.name, cols.len });
}

/// The drift marker stored as a COMMENT on the generated tsvector column: a stable, comma-joined
/// list of the searchable column names (already identifier-gated, so no quote/`'` escaping needed —
/// a valid SQL identifier contains none). Re-deriving it and comparing detects an added/removed
/// `.searchable` field across startups. The names are SORTED first so the marker is independent of
/// field declaration order — merely REORDERING the same searchable fields does not trip a spurious
/// drop+recreate at startup (only adding/removing one does). The generated-column EXPRESSION still
/// follows field order, which is harmless: it's a different concatenation of the same lexemes.
fn pgMarker(alloc: std.mem.Allocator, cols: []const []const u8) ![]const u8 {
    const sorted = try alloc.dupe([]const u8, cols);
    defer alloc.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "zbfts:");
    for (sorted, 0..) |cn, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, cn);
    }
    return out.toOwnedSlice(alloc);
}

/// The state of the generated `tsvector` column on a collection's table — DISTINGUISHING the three
/// cases the idempotency logic must treat differently (the two-state "marker or null" form silently
/// conflated "absent" with "present-but-no-marker", which made `ensureIndexPg` fall through to
/// `ADD COLUMN` on an already-existing column → a hard "column already exists" startup failure):
///   * `.absent` — no `<col>_fts` column → safe to `ADD COLUMN`.
///   * `.present` with `marker == want` — fully provisioned (only the GIN index might be missing).
///   * `.present` with `marker != want` — drift, only after shared ownership verification.
const PgColumnState = union(enum) {
    absent,
    /// The generated column exists; `marker` is its drift-marker COMMENT (owned by `alloc`), or
    /// null when the column carries no/empty comment.
    present: ?[]const u8,
};

/// Probe the generated `tsvector` column's state on `col`.`tsv`. Resolves the table via
/// `to_regclass` so it respects the active `search_path`. The caller owns `present.?` (frees it).
fn pgColumnState(alloc: std.mem.Allocator, w: *db.Db, col_name: []const u8, tsv: []const u8) !PgColumnState {
    // Postgres-only path → the native `$n` placeholders are written directly (this never flows
    // through the `?`→`$n` ParamSink renumber that the cross-backend CRUD/query producers use).
    const sql = try alloc.printSentinel("SELECT col_description(a.attrelid, a.attnum) FROM pg_attribute a " ++
        "WHERE a.attrelid = to_regclass($1) AND a.attname = $2 AND a.attnum > 0 AND NOT a.attisdropped;", .{}, 0);
    defer alloc.free(sql);
    var st = try w.prepare(sql);
    defer st.finalize();
    const quoted = try alloc.print("\"{s}\"", .{col_name});
    defer alloc.free(quoted); // bindText dupes its arg, so freeing after the bind is safe
    try st.bindText(1, quoted);
    try st.bindText(2, tsv);
    if (!try st.step()) return .absent; // no such column
    if (st.isNull(0)) return .{ .present = null }; // column exists but no marker comment
    return .{ .present = try alloc.dupe(u8, st.columnText(0)) };
}

/// True iff a relation named `rel` is visible on the active `search_path` (used to confirm the GIN
/// index exists). `to_regclass` returns NULL for an absent name instead of raising.
fn pgRelExists(alloc: std.mem.Allocator, w: *db.Db, rel: []const u8) !bool {
    const sql = try alloc.printSentinel("SELECT to_regclass($1) IS NOT NULL;", .{}, 0);
    defer alloc.free(sql);
    var st = try w.prepare(sql);
    defer st.finalize();
    const quoted = try alloc.print("\"{s}\"", .{rel});
    defer alloc.free(quoted); // bindText dupes its arg, so freeing after the bind is safe
    try st.bindText(1, quoted);
    if (!try st.step()) return false;
    return st.columnInt(0) != 0;
}

/// CREATE the GIN index `idx` over the generated tsvector column `tsv` on `col_name`. Used both on
/// a fresh provision and to recreate JUST the index when the column is already correct but the index
/// went missing (so we never drop+rebuild the expensive STORED generated column for an index-only gap).
fn createGinIndexPg(alloc: std.mem.Allocator, w: *db.Db, col_name: []const u8, tsv: []const u8, idx: []const u8) !void {
    const sql = try alloc.printSentinel("CREATE INDEX \"{s}\" ON \"{s}\" USING GIN (\"{s}\");", .{ idx, col_name, tsv }, 0);
    defer alloc.free(sql);
    try w.exec(sql);
}

/// Drop the proved generated column and its dependent GIN index. Ownership checks
/// reject orphan indexes, so never DROP an index by a separately resolved name.
fn dropIndexPg(alloc: std.mem.Allocator, w: *db.Db, col_name: []const u8, tsv: []const u8) !void {
    // Trigger-function bodies can reference NEW.<fts> dynamically, without a
    // pg_depend edge to the column. Proving arbitrary bodies is not possible;
    // reject user triggers only when removing/replacing the generated column.
    // Harmless no-op reconciliation and missing-index repair remain available.
    var triggers = try w.prepare("SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass($1) AND NOT tgisinternal LIMIT 1;");
    defer triggers.finalize();
    const table = try @import("../ddl.zig").quoteIdent(alloc, col_name);
    defer alloc.free(table);
    try triggers.bindText(1, table);
    if (try triggers.step()) return error.Conflict;
    {
        const sql = try alloc.printSentinel("ALTER TABLE \"{s}\" DROP COLUMN IF EXISTS \"{s}\";", .{ col_name, tsv }, 0);
        defer alloc.free(sql);
        try w.exec(sql);
    }
}

/// A comma-separated quoted column list, optionally prefixed (`new.`/`old.`) for trigger bodies.
fn columnList(alloc: std.mem.Allocator, cols: []const []const u8, comptime prefix: ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cols, 0..) |cn, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        if (prefix) |p| {
            try out.appendSlice(alloc, try alloc.print(p ++ ".\"{s}\"", .{cn}));
        } else {
            try out.appendSlice(alloc, try alloc.print("\"{s}\"", .{cn}));
        }
    }
    return out.toOwnedSlice(alloc);
}

/// DROP the FTS shadow table + its three sync triggers if present (idempotent).
fn dropIndex(alloc: std.mem.Allocator, w: *db.Db, col_name: []const u8, ft: []const u8) !void {
    try w.exec(try toZ(alloc, try alloc.print("DROP TRIGGER IF EXISTS \"{s}_ai\";", .{ft})));
    try w.exec(try toZ(alloc, try alloc.print("DROP TRIGGER IF EXISTS \"{s}_ad\";", .{ft})));
    try w.exec(try toZ(alloc, try alloc.print("DROP TRIGGER IF EXISTS \"{s}_au\";", .{ft})));
    try w.exec(try toZ(alloc, try alloc.print("DROP TABLE IF EXISTS \"{s}\";", .{ft})));
    _ = col_name;
}

fn tableExists(alloc: std.mem.Allocator, w: *db.Db, ft: []const u8) !bool {
    var st = try w.prepare(try toZ(alloc, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1;"));
    defer st.finalize();
    try st.bindText(1, ft);
    return st.step();
}

/// True iff the existing FTS table's indexed columns equal `want` (same set + order).
fn columnsMatch(alloc: std.mem.Allocator, w: *db.Db, ft: []const u8, want: []const []const u8) !bool {
    var st = try w.prepare(try toZ(alloc, try alloc.print("PRAGMA table_info(\"{s}\");", .{ft})));
    defer st.finalize();
    var i: usize = 0;
    while (try st.step()) : (i += 1) {
        const name = st.columnText(1); // (cid, name, type, …)
        if (i >= want.len or !std.mem.eql(u8, name, want[i])) return false;
    }
    return i == want.len;
}

/// True iff all three sync triggers (`_ai`, `_ad`, `_au`) currently exist for `col_name`.
fn triggersPresent(alloc: std.mem.Allocator, w: *db.Db, col_name: []const u8) !bool {
    const ft = try tableName(alloc, col_name);
    var st = try w.prepare(try toZ(alloc, "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name IN (?1,?2,?3);"));
    defer st.finalize();
    try st.bindText(1, try alloc.print("{s}_ai", .{ft}));
    try st.bindText(2, try alloc.print("{s}_ad", .{ft}));
    try st.bindText(3, try alloc.print("{s}_au", .{ft}));
    _ = try st.step();
    return st.columnInt(0) == 3;
}

/// Allocator.print helpers hand us `[]u8`; `db.exec`/`db.prepare` want a sentinel-terminated slice.
fn toZ(alloc: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    return alloc.printSentinel("{s}", .{s}, 0);
}

// ---- Tests -----------------------------------------------------------------

const collections = @import("../collections.zig");
const migrations = @import("../migrations.zig");
const records = @import("../records.zig");

test "search no-op gates issue no transaction statements" {
    const c = @import("../c.zig").c;
    const Counter = struct {
        fn authorize(context: ?*anyopaque, action: c_int, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            const count: *usize = @ptrCast(@alignCast(context.?));
            if (action == c.SQLITE_TRANSACTION or action == c.SQLITE_SAVEPOINT) count.* += 1;
            return c.SQLITE_OK;
        }
    };
    var w = try db.Db.openMemory();
    defer w.close();
    const handle = db.sqliteHandle(&w);
    inline for (.{ false, true }) |nested| {
        if (nested) try w.begin();
        defer if (nested) w.rollback() catch unreachable;
        var count: usize = 0;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(handle, Counter.authorize, &count));
        defer std.debug.assert(c.sqlite3_set_authorizer(handle, null, null) == c.SQLITE_OK);
        const a = std.testing.allocator;
        try ensureIndex(a, &w, .{ .id = "c", .name = "_system", .fields = &.{} });
        try ensureIndex(a, &w, .{ .id = "c", .name = "invalid name", .fields = &.{} });
        if (comptime !enabled) {
            try ensureIndex(a, &w, .{ .id = "c", .name = "articles", .fields = &.{} });
            try std.testing.expectError(error.SearchDisabled, ensureIndex(a, &w, .{ .id = "c", .name = "articles", .fields = &.{.{ .id = "t", .name = "title", .searchable = true, .options = .{ .text = .{} } }} }));
        }
        try std.testing.expectEqual(@as(usize, 0), count);
        try std.testing.expectEqual(nested, w.inTransaction());
    }
}

test "additive provisioning creates searchable fields before reconciling SQLite FTS" {
    if (comptime !enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var w = try db.Db.openMemory();
    defer w.close();
    try migrations.run(&w);
    const fields = [_]schema.Field{
        .{ .id = "t", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "b", .name = "body", .searchable = true, .options = .{ .text = .{} } },
    };
    const col = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "articles", .fields = fields[0..1] });
    defer col.deinit(a);
    try ensureIndex(a, &w, col);
    try w.exec("INSERT INTO articles(id,title) VALUES('r1','kept');");
    var desired = col;
    desired.fields = &fields;
    try @import("../provision.zig").applySpecs(a, std.testing.io, &w, &.{desired});
    try w.exec("UPDATE articles SET body='added';");
    var found = try w.prepare("SELECT title FROM articles_fts WHERE articles_fts MATCH 'added';");
    defer found.finalize();
    try std.testing.expect(try found.step());
    try std.testing.expectEqualStrings("kept", found.columnText(0));
}

test "generic search provisioning preserves an application-owned FTS name" {
    if (comptime !enabled) return error.SkipZigTest;
    var w = try db.Db.openMemory();
    defer w.close();
    try migrations.run(&w);
    const a = std.testing.allocator;
    const col = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "articles", .fields = &.{} });
    defer col.deinit(a);
    try w.exec("CREATE TABLE articles_fts(sentinel TEXT); INSERT INTO articles_fts VALUES('must survive');");
    var boot = std.heap.ArenaAllocator.init(a);
    defer boot.deinit();
    try std.testing.expectError(error.Conflict, @import("../provision.zig").ensureCollection(boot.allocator(), std.testing.io, &w, col));
    var searchable = col;
    searchable.fields = &.{.{ .id = "t", .name = "title", .searchable = true, .options = .{ .text = .{} } }};
    try std.testing.expectError(error.Conflict, ensureIndex(a, &w, searchable));
    var row = try w.prepare("SELECT sentinel FROM articles_fts;");
    defer row.finalize();
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings("must survive", row.columnText(0));
}

test "search provisioning preserves a temporary FTS name shadow" {
    if (comptime !enabled) return error.SkipZigTest;
    var w = try db.Db.openMemory();
    defer w.close();
    try migrations.run(&w);
    const a = std.testing.allocator;
    const col = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "articles", .fields = &.{} });
    defer col.deinit(a);
    try w.exec("CREATE TEMP TABLE articles_fts(sentinel TEXT); INSERT INTO temp.articles_fts VALUES('must survive');");
    try std.testing.expectError(error.Conflict, ensureIndex(a, &w, col));
    var row = try w.prepare("SELECT sentinel FROM temp.articles_fts;");
    defer row.finalize();
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings("must survive", row.columnText(0));
}

test "search removal preserves temporary SQL dependents and their target" {
    if (comptime !enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var w = try db.Db.openMemory();
    defer w.close();
    try migrations.run(&w);
    const col = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "articles", .fields = &.{.{ .id = "t", .name = "title", .searchable = true, .options = .{ .text = .{} } }} });
    defer col.deinit(a);
    try ensureIndex(a, &w, col);
    try w.exec("INSERT INTO articles(id,title) VALUES('r1','kept'); CREATE TEMP VIEW keep_search AS SELECT title FROM main.articles_fts;");
    var disabled = col;
    disabled.fields = &.{};
    try std.testing.expectError(error.Conflict, ensureIndex(a, &w, disabled));
    {
        var kept = try w.prepare("SELECT title FROM keep_search;");
        defer kept.finalize();
        try std.testing.expect(try kept.step());
        try std.testing.expectEqualStrings("kept", kept.columnText(0));
    }
    try w.exec("DROP VIEW keep_search; CREATE TEMP TRIGGER keep_search AFTER INSERT ON main.articles BEGIN SELECT title FROM articles_fts; END;");
    try std.testing.expectError(error.Conflict, ensureIndex(a, &w, disabled));
    try w.exec("INSERT INTO articles(id,title) VALUES('r2','retained');");
    var kept = try w.prepare("SELECT title FROM articles_fts WHERE articles_fts MATCH 'retained';");
    defer kept.finalize();
    try std.testing.expect(try kept.step());
    try std.testing.expectEqualStrings("retained", kept.columnText(0));
}

test "SQLite search rejects missing and nontext physical content columns" {
    if (comptime !enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_][:0]const u8{
        "DROP TABLE articles; CREATE TABLE articles(id TEXT,other TEXT); INSERT INTO articles VALUES('r1','kept');",
        "DROP TABLE articles; CREATE TABLE articles(id TEXT,title INTEGER); INSERT INTO articles VALUES('r1',42);",
    }) |replacement| {
        var w = try db.Db.openMemory();
        defer w.close();
        try migrations.run(&w);
        const col = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "articles", .fields = &.{.{ .id = "t", .name = "title", .searchable = true, .options = .{ .text = .{} } }} });
        defer col.deinit(a);
        try ensureIndex(a, &w, col);
        try w.exec("INSERT INTO articles(id,title) VALUES('r1','sentinel');");
        // Leave exact engine-shaped FTS objects behind a migration-owned base
        // shape. Missing sync triggers alone are repairable, invalid operands
        // are not: removal must preserve these unproved indexed terms.
        try w.exec(replacement);
        var disabled = col;
        disabled.fields = &.{};
        try std.testing.expectError(error.Conflict, ensureIndex(a, &w, disabled));
        var kept = try w.prepare("SELECT count(*) FROM articles_fts WHERE articles_fts MATCH 'sentinel';");
        defer kept.finalize();
        try std.testing.expect(try kept.step());
        try std.testing.expectEqual(@as(i64, 1), kept.columnInt(0));
        var row = try w.prepare("SELECT id FROM articles;");
        defer row.finalize();
        try std.testing.expect(try row.step());
        try std.testing.expectEqualStrings("r1", row.columnText(0));
    }
}

test "owned SQLite search survives missing triggers and searchable-set changes" {
    if (comptime !enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var w = try db.Db.openMemory();
    defer w.close();
    try migrations.run(&w);
    const fields = [_]schema.Field{
        .{ .id = "t", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "b", .name = "body", .options = .{ .text = .{} } },
    };
    const col = try collections.create(a, std.testing.io, &w, .{ .id = "", .name = "articles", .fields = &fields });
    defer col.deinit(a);
    try ensureIndex(a, &w, col);
    try w.exec("INSERT INTO articles(id,title,body) VALUES('r1','hello','world'); DROP TRIGGER articles_fts_ai;");
    try ensureIndex(a, &w, col);
    var changed_fields = fields;
    changed_fields[1].searchable = true;
    var changed = col;
    changed.fields = &changed_fields;
    try ensureIndex(a, &w, changed);
    {
        var match = try w.prepare("SELECT count(*) FROM articles_fts WHERE articles_fts MATCH 'world';");
        defer match.finalize();
        try std.testing.expect(try match.step());
        try std.testing.expectEqual(@as(i64, 1), match.columnInt(0));
    }
    changed.fields = &.{};
    try ensureIndex(a, &w, changed);
    {
        var absent = try w.prepare("SELECT 1 FROM sqlite_schema WHERE name='articles_fts';");
        defer absent.finalize();
        try std.testing.expect(!try absent.step());
    }
    var row = try w.prepare("SELECT title,body FROM articles;");
    defer row.finalize();
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings("hello", row.columnText(0));
    try std.testing.expectEqualStrings("world", row.columnText(1));
}

/// sanitize returns an owned `?[]const u8` on the passed allocator; assert then free it, so the
/// test runs under the raw leak detector (sanitize is self-freeing / contract-1 already).
fn expectSanitized(expected: ?[]const u8, input: []const u8) !void {
    const a = std.testing.allocator;
    const got = try sanitize(a, input);
    defer if (got) |g| a.free(g);
    if (expected) |e| try std.testing.expectEqualStrings(e, got.?) else try std.testing.expect(got == null);
}

test "sanitize quotes tokens, preserves operators, drops dangling ones" {
    try expectSanitized("\"foo\" \"bar\"", "foo bar");
    try expectSanitized("\"alpha\" OR \"gamma\"", "alpha OR gamma");
    try expectSanitized("\"foo\"*", "foo*");
    // Leading/trailing/doubled operators are dropped so the query is always well-formed.
    try expectSanitized("\"foo\"", "OR foo OR");
    // Consecutive operators collapse to the last one seen (always well-formed, never doubled).
    try expectSanitized("\"a\" AND \"b\"", "a OR AND b");
    // A double-quote injection attempt is escaped into a literal token, never a syntax break.
    try expectSanitized("\"a\"\"b\"", "a\"b");
    // Empty / operator-only input yields no query.
    try expectSanitized(null, "   ");
    try expectSanitized(null, "AND OR");
}

test "fts5 flag: enabled reflects build_options (default true in the test build)" {
    try std.testing.expect(enabled == build_options.fts5);
}

test "a searchable '_'-named collection is reported, not silently skipped" {
    // `isSearchable` answers "will the engine serve search here?" and must keep failing closed on a
    // `_`-prefixed (engine-owned) name — that is what makes `records.list` reject `?search=` with
    // NotSearchable instead of quietly returning unfiltered rows. What must NOT be conflated with it
    // is "does the schema ASK for search?", which is exactly the case `ensureIndex` now reports
    // instead of skipping in silence. Pin the two apart: collapsing `hasSearchableField` back into
    // the name gate makes this test red.
    const searchable = [_]schema.Field{.{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } }};
    const sys = schema.Collection{ .id = "_probe________", .name = "_probe", .system = true, .fields = &searchable };
    try std.testing.expect(hasSearchableField(sys)); // the schema asks for search…
    try std.testing.expect(!isSearchable(sys)); // …but the engine will not serve it (fail closed)

    // A `_` collection with nothing to index is the ordinary case (every system collection today):
    // both answers are false, so the skip stays quiet and startup logs are not spammed.
    const plain = [_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }};
    const quiet = schema.Collection{ .id = "_quiet________", .name = "_quiet", .system = true, .fields = &plain };
    try std.testing.expect(!hasSearchableField(quiet));
    try std.testing.expect(!isSearchable(quiet));

    // A normal searchable collection is unchanged: both true.
    const ok = schema.Collection{ .id = "articles______", .name = "articles", .fields = &searchable };
    try std.testing.expect(hasSearchableField(ok));
    try std.testing.expect(isSearchable(ok));

    // And the skip is a clean no-op, not an error: provisioning a searchable `_` collection whose
    // table does not even exist must not fail startup.
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    try ensureIndex(std.testing.allocator, &d, sys);
}

test "ensureIndex provisions FTS5, triggers keep it in sync, MATCH search returns rows" {
    if (comptime !enabled) return error.SkipZigTest; // requires SQLite compiled with FTS5
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const io = std.testing.io;
    try migrations.run(&d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "body", .searchable = true, .options = .{ .editor = .{} } },
        .{ .id = "f3", .name = "slug", .options = .{ .text = .{} } },
    };
    const col = try collections.create(a, io, &d, .{ .id = "", .name = "articles", .fields = &fields });
    defer col.deinit(a);

    try ensureIndex(a, &d, col); // first provision (now self-freeing — no leaked DDL scratch)
    try ensureIndex(a, &d, col); // idempotent second call is a no-op (no error)

    // Insert through the records layer so the AFTER INSERT trigger populates the index. Each input
    // ObjectMap and each returned (self-contained) record is freed on the raw allocator.
    inline for (.{
        .{ "zig programming language", "a fast systems language" },
        .{ "cooking pasta", "boil water and add salt" },
    }) |row| {
        var obj: std.json.ObjectMap = .empty;
        defer obj.deinit(a);
        try obj.put(a, "title", .{ .string = row[0] });
        try obj.put(a, "body", .{ .string = row[1] });
        const rec = try records.create(a, io, &d, col, .{ .object = obj });
        records.freeRecord(a, rec);
    }

    const s = (try build(a, &d, col, "zig")).?;
    // SQLite `build` returns an owned Search (join/where/order SQL + the sanitized param text), no
    // aliasing (order_param is null on SQLite) — free the four heap slices after use.
    defer {
        a.free(s.join_sql);
        a.free(s.where_sql);
        a.free(s.order_sql);
        a.free(s.param.text);
    }
    const sql = try a.printSentinel("SELECT \"articles\".\"title\" FROM \"articles\" {s} WHERE {s};", .{ s.join_sql, s.where_sql }, 0);
    defer a.free(sql);
    var st = try d.prepare(sql);
    defer st.finalize();
    try st.bindText(1, s.param.text);
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("zig programming language", st.columnText(0));
    try std.testing.expect(!try st.step()); // only the one matching row
}

test "Postgres lowering emits the exact tsquery SQL, with the ts config as a fixed literal" {
    // `buildPostgres` is pure (allocator + collection + term), so it is testable with no live
    // Postgres — yet nothing asserted its emitted SQL, leaving the whole read-side lowering
    // uncovered in the default build (the `*_pg_test.zig` suites need a real server and skip).
    //
    // Pinning the exact strings does double duty: it covers that lowering, and it holds the
    // `pg_ts_config` interpolation to a FIXED, quote-free literal. The config lands inside a
    // single-quoted SQL literal — an escaping context `schema.isValidIdentifier` does not cover
    // — so if it ever became a runtime value, this asserts the resulting SQL is still exactly
    // what we expect rather than something a stray quote reshaped.
    const a = std.testing.allocator;
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .searchable = true, .options = .{ .text = .{} } },
    };
    const col = schema.Collection{ .id = "c1", .name = "articles", .fields = &fields };

    const got = (try buildPostgres(a, col, "  hello world  ")).?;
    // `param` and `order_param` intentionally alias ONE `term` allocation — free it once.
    defer a.free(got.where_sql);
    defer a.free(got.order_sql);
    defer a.free(got.param.text);

    try std.testing.expectEqualStrings(
        "\"articles\".\"articles_fts\" @@ plainto_tsquery('simple', ?)",
        got.where_sql,
    );
    try std.testing.expectEqualStrings(
        "ts_rank(\"articles\".\"articles_fts\", plainto_tsquery('simple', ?)) DESC",
        got.order_sql,
    );
    // The term is bound, never interpolated — and trimmed, not passed through raw.
    try std.testing.expectEqualStrings("hello world", got.param.text);
    try std.testing.expectEqualStrings("hello world", got.order_param.?.text);
    try std.testing.expectEqualStrings("", got.join_sql);

    // A term that trims to nothing yields no search clause at all (rather than an empty MATCH).
    try std.testing.expect((try buildPostgres(a, col, "   \t\n ")) == null);
}

// ---- Row-local ranking tests (#495) ------------------------------------------

/// Insert one `notes` row through the records layer (so the FTS sync trigger indexes it).
fn addNote(a: std.mem.Allocator, conn: *db.Db, col: schema.Collection, account: []const u8, title: []const u8) !void {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(a);
    try obj.put(a, "account", .{ .string = account });
    try obj.put(a, "title", .{ .string = title });
    const rec = try records.create(a, std.testing.io, conn, col, .{ .object = obj });
    records.freeRecord(a, rec);
}

/// Run `?search=term` (offset mode) scoped by `filter`, returning the titles in result order as
/// one owned `title|title|…|` string (so two orders compare with one `expectEqualStrings`).
fn searchOrder(a: std.mem.Allocator, conn: *db.Db, col: schema.Collection, filter: ?[]const u8, term: []const u8) ![]u8 {
    var res = try records.list(a, conn, col, .{ .filter = filter, .search = term });
    defer res.deinit(a);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (res.items) |item| {
        try out.appendSlice(a, item.object.get("title").?.string);
        try out.append(a, '|');
    }
    return out.toOwnedSlice(a);
}

/// A `notes(account, title searchable)` collection with its FTS index provisioned on `conn`.
fn notesCollection(a: std.mem.Allocator, conn: *db.Db) !schema.Collection {
    try migrations.run(conn);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "account", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "title", .searchable = true, .options = .{ .text = .{} } },
    };
    const col = try collections.create(a, std.testing.io, conn, .{ .id = "", .name = "notes", .fields = &fields });
    errdefer col.deinit(a);
    try ensureIndex(a, conn, col);
    return col;
}

test "search order is row-local: another tenant's text cannot reorder a tenant's results (#495)" {
    if (comptime !enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    const col = try notesCollection(a, &d);
    defer col.deinit(a);
    // Tenant scoping is a WHERE predicate like this filter; the shadow index (the leak's source)
    // holds both accounts' rows either way.
    const scope_a = "account = \"a\"";

    // The issue's first repro: A's two symmetric rows, B's five rows all containing ONE of the
    // two query words. Under bm25 the other word's IDF rises, flipping A's order.
    try addNote(a, &d, col, "a", "alpha alpha bravo");
    try addNote(a, &d, col, "a", "alpha bravo bravo");
    for (0..5) |i| {
        var buf: [32]u8 = undefined;
        try addNote(a, &d, col, "b", try std.mem.print(&buf, "alpha filler{d}", .{i}));
    }
    const case1 = try searchOrder(a, &d, col, scope_a, "alpha bravo");
    defer a.free(case1);
    try d.exec("UPDATE notes SET title = replace(title, 'alpha', 'bravo') WHERE account = 'b';");
    const case2 = try searchOrder(a, &d, col, scope_a, "alpha bravo");
    defer a.free(case2);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, case1, "|"));
    try std.testing.expectEqualStrings(case1, case2);
}

test "search order is not a word-presence oracle for another tenant's text (#495)" {
    if (comptime !enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    const col = try notesCollection(a, &d);
    defer col.deinit(a);
    const scope_a = "account = \"a\"";
    // The issue's 7-row variant: whether B stores `zebrasecret` must not decide which of A's two
    // otherwise-identical rows comes first.
    for (0..4) |i| {
        var buf: [32]u8 = undefined;
        try addNote(a, &d, col, "b", try std.mem.print(&buf, "filler note {d}", .{i}));
    }
    try addNote(a, &d, col, "a", "zebrasecret pad");
    try addNote(a, &d, col, "a", "qqcontrolqq pad");
    try addNote(a, &d, col, "b", "zebrasecret merger plan");
    const with_word = try searchOrder(a, &d, col, scope_a, "zebrasecret OR qqcontrolqq");
    defer a.free(with_word);
    try d.exec("UPDATE notes SET title = 'ordinary merger plan' WHERE account = 'b' AND title = 'zebrasecret merger plan';");
    const without_word = try searchOrder(a, &d, col, scope_a, "zebrasecret OR qqcontrolqq");
    defer a.free(without_word);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, with_word, "|"));
    try std.testing.expectEqualStrings(with_word, without_word);
}

test "row-local rank prefers more distinct terms, more hits, and denser rows" {
    if (comptime !enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var d = try db.Db.openMemory();
    defer d.close();
    const col = try notesCollection(a, &d);
    defer col.deinit(a);
    // Inserted worst-first, so neither insertion order nor rowid can produce the expected order.
    try addNote(a, &d, col, "a", "alpha x y z w v"); // 1 hit, 6 tokens
    try addNote(a, &d, col, "a", "alpha x y"); // 1 hit, 3 tokens: denser
    try addNote(a, &d, col, "a", "alpha alpha x"); // 2 hits of one term, 3 tokens
    try addNote(a, &d, col, "a", "alpha bravo x"); // both terms, 3 tokens
    const got = try searchOrder(a, &d, col, null, "alpha OR bravo");
    defer a.free(got);
    try std.testing.expectEqualStrings("alpha bravo x|alpha alpha x|alpha x y|alpha x y z w v|", got);

    // Prefix: `alp*` is one phrase whose hits are every token it expands to in the row.
    try addNote(a, &d, col, "p", "beta x"); // no match
    try addNote(a, &d, col, "p", "alpaca x y z w v"); // 1 hit, 6 tokens
    try addNote(a, &d, col, "p", "alpha x y"); // 1 hit, 3 tokens
    try addNote(a, &d, col, "p", "alpha alpine x"); // 2 hits (alpha, alpine), 3 tokens
    const prefix = try searchOrder(a, &d, col, "account = \"p\"", "alp*");
    defer a.free(prefix);
    try std.testing.expectEqualStrings("alpha alpine x|alpha x y|alpaca x y z w v|", prefix);

    // NOT: the excluded term's phrase counts 0 hits in every surviving row, so the order is the
    // positive term's alone, and a row containing the excluded term is absent.
    try addNote(a, &d, col, "n", "alpha x y z w v");
    try addNote(a, &d, col, "n", "alpha bravo x"); // excluded by NOT
    try addNote(a, &d, col, "n", "alpha x y");
    try addNote(a, &d, col, "n", "alpha alpha x");
    const not_q = try searchOrder(a, &d, col, "account = \"n\"", "alpha NOT bravo");
    defer a.free(not_q);
    try std.testing.expectEqualStrings("alpha alpha x|alpha x y|alpha x y z w v|", not_q);

    // OR across those rows: the row with BOTH terms now ranks first.
    const or_q = try searchOrder(a, &d, col, "account = \"n\"", "bravo OR alpha");
    defer a.free(or_q);
    try std.testing.expectEqualStrings("alpha bravo x|alpha alpha x|alpha x y|alpha x y z w v|", or_q);

    // Hyphenated term: `well-known` is ONE phrase (the tokenizer splits it into adjacent tokens), so
    // a hit is the adjacent pair, and the reversed / split orders do not match at all.
    try addNote(a, &d, col, "h", "known well x"); // not the phrase
    try addNote(a, &d, col, "h", "well x known"); // not adjacent
    try addNote(a, &d, col, "h", "well known x y"); // 1 phrase hit, 4 tokens
    try addNote(a, &d, col, "h", "well known well known x"); // 2 phrase hits, 5 tokens
    const hyphen = try searchOrder(a, &d, col, "account = \"h\"", "well-known");
    defer a.free(hyphen);
    try std.testing.expectEqualStrings("well known well known x|well known x y|", hyphen);

    // The formula itself (documented in docs/search.md): coverage / log2(1 + tokens).
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), rowLocalScore(1.0, 3), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5 / std.math.log2(7.0)), rowLocalScore(0.5, 6), 1e-12);
}

test "row-local rank is registered on pooled and fresh reader connections" {
    if (comptime !enabled) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir_path);
    const db_path = try a.printSentinel("{s}/rank.db", .{dir_path}, 0);
    defer a.free(db_path);

    var pool = try db.Pool.init(a, std.testing.io, db_path);
    defer pool.deinit();
    const col = blk: {
        const w = pool.acquireWriter();
        defer pool.releaseWriter();
        const col = try notesCollection(a, w);
        errdefer col.deinit(a);
        try addNote(a, w, col, "a", "alpha x y");
        try addNote(a, w, col, "a", "alpha alpha x");
        break :blk col;
    };
    defer col.deinit(a);
    const want = "alpha alpha x|alpha x y|";

    {
        var r = try pool.acquireReader(); // a warm pooled reader the search never opened itself
        defer pool.releaseReader(&r);
        const got = try searchOrder(a, &r, col, null, "alpha");
        defer a.free(got);
        try std.testing.expectEqualStrings(want, got);
        // Registration is once per connection: a second search reuses it.
        const again = try searchOrder(a, &r, col, null, "alpha");
        defer a.free(again);
        try std.testing.expectEqualStrings(want, again);
    }
    {
        var r = try pool.openReader(); // a fresh overflow-style reader
        defer r.close();
        const got = try searchOrder(a, &r, col, null, "alpha");
        defer a.free(got);
        try std.testing.expectEqualStrings(want, got);
    }
}
