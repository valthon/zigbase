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
//!     via a JOIN + `"<fts>" MATCH ?` + bm25 `"<fts>"."rank"` ordering. The index is (re)populated
//!     with the FTS5 `'rebuild'` command on first provision.
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
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ col_name, suffix });
}

/// The Postgres GIN index name for the tsvector column of `col_name` (`"<col_name>_fts_idx"`).
fn pgIndexName(alloc: std.mem.Allocator, col_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}_idx", .{ col_name, suffix });
}

/// The Postgres text-search configuration used for both the generated `tsvector` and the
/// `plainto_tsquery` at read time (they MUST agree). `'simple'` mirrors SQLite FTS5's default
/// unicode61 tokenizer (no stemming, no stopwords) for the closest cross-backend parity.
const pg_ts_config = "simple";

/// True iff `col` has at least one valid, searchable column AND a valid table identifier — i.e.
/// `ensureIndex` will provision an FTS5 index and `build` can compose a MATCH predicate for it.
pub fn isSearchable(col: schema.Collection) bool {
    if (!schema.isValidIdentifier(col.name)) return false;
    for (col.fields) |f| if (f.searchable and schema.isSearchableType(f.fieldType()) and schema.isValidIdentifier(f.name) and !f.encrypted) return true;
    return false;
}

/// The searchable column names of `col` (valid identifiers, text/editor, non-encrypted), on
/// `alloc`. Empty when the collection is not searchable.
fn searchableColumns(alloc: std.mem.Allocator, col: schema.Collection) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (col.fields) |f| {
        if (f.searchable and schema.isSearchableType(f.fieldType()) and schema.isValidIdentifier(f.name) and !f.encrypted)
            try out.append(alloc, f.name);
    }
    return out.toOwnedSlice(alloc);
}

/// A compiled, parameter-bound full-text search clause AND-ed into the list query by
/// `records.list`. `join_sql` brings the FTS shadow table into the query (no params; **empty on
/// Postgres**, where the tsvector lives on the base table); `where_sql` is the bound search
/// predicate (one trailing `?` — `MATCH` on SQLite, `@@ plainto_tsquery(…)` on Postgres);
/// `order_sql` is the relevance ordering (bm25 `"<fts>"."rank"` on SQLite, `ts_rank(…) DESC` on
/// Postgres). `param` is the bound WHERE term (the SANITIZED FTS5 query on SQLite, the raw term for
/// `plainto_tsquery` on Postgres). `order_param`, when non-null, is the SECOND bound term consumed
/// by `order_sql` (Postgres `ts_rank` re-runs `plainto_tsquery`); it is null on SQLite (bm25 `rank`
/// takes no param), and `records.list` binds it in the ORDER BY position when present.
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
pub const SearchError = error{SearchDisabled} ||
    @typeInfo(@typeInfo(@TypeOf(buildSqliteImpl)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(buildPostgres)).@"fn".return_type.?).error_union.error_set;

/// Build the full-text search clause for `raw_term` on `col` under `dialect`, or null when the
/// collection is not searchable OR the term carries no searchable token. Allocations are on
/// `alloc`. The bound `param`/`order_param` are never interpolated.
pub fn build(alloc: std.mem.Allocator, dialect: db.Dialect, col: schema.Collection, raw_term: []const u8) SearchError!?Search {
    if (!isSearchable(col)) return null;
    return switch (dialect.kind) {
        .sqlite => buildSqlite(alloc, col, raw_term),
        .postgres => buildPostgres(alloc, col, raw_term),
    };
}

/// SQLite lowering: `error.SearchDisabled` when `-Dfts5=false` (this branch folds to comptime-dead
/// there — see `enabled`); otherwise a JOIN onto the FTS5 shadow table + a bound `MATCH` predicate
/// + bm25 `rank` ordering. `param.text` is the SANITIZED, guaranteed-valid FTS5 query (`sanitize`).
fn buildSqlite(alloc: std.mem.Allocator, col: schema.Collection, raw_term: []const u8) SearchError!?Search {
    if (comptime !enabled) return error.SearchDisabled;
    return buildSqliteImpl(alloc, col, raw_term);
}

fn buildSqliteImpl(alloc: std.mem.Allocator, col: schema.Collection, raw_term: []const u8) !?Search {
    const q = (try sanitize(alloc, raw_term)) orelse return null;
    errdefer alloc.free(q); // q ESCAPES into `.param.text` on success; free it only on an error below
    const ft = try tableName(alloc, col.name);
    defer alloc.free(ft); // internal scratch: copied into the SQL strings below, never escapes
    return .{
        .join_sql = try std.fmt.allocPrint(alloc, "JOIN \"{s}\" ON \"{s}\".\"rowid\" = \"{s}\".\"rowid\"", .{ ft, ft, col.name }),
        .where_sql = try std.fmt.allocPrint(alloc, "\"{s}\" MATCH ?", .{ft}),
        .order_sql = try std.fmt.allocPrint(alloc, "\"{s}\".\"rank\"", .{ft}),
        .param = .{ .text = q },
    };
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
    return .{
        .join_sql = "",
        .where_sql = try std.fmt.allocPrint(alloc, "\"{s}\".\"{s}\" @@ plainto_tsquery('{s}', ?)", .{ col.name, tsv, pg_ts_config }),
        .order_sql = try std.fmt.allocPrint(alloc, "ts_rank(\"{s}\".\"{s}\", plainto_tsquery('{s}', ?)) DESC", .{ col.name, tsv, pg_ts_config }),
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
pub const EnsureIndexError = error{SearchDisabled} ||
    @typeInfo(@typeInfo(@TypeOf(ensureIndexSqliteImpl)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(ensureIndexPg)).@"fn".return_type.?).error_union.error_set;

/// Provision (idempotently) the FTS5 external-content index + sync triggers for `col`, repopulating
/// it on first build. A no-op when `col` has no searchable fields (any stale index from a previous
/// schema is dropped). Re-creates the index when its column set drifts OR its sync triggers are
/// missing (e.g. after an additive table rebuild dropped them). Called from `provision.ensureCollection`
/// at startup — NOT a numbered migration. Identifiers are gated through `schema.isValidIdentifier`.
pub fn ensureIndex(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) EnsureIndexError!void {
    // Backend split: the FTS5 external-content vtable + sync triggers + sqlite_master probes below
    // are SQLite-only. Postgres provisions a STORED `tsvector` generated column + GIN index instead
    // (same `?search=` read surface, lowered by `buildPostgres`). Both are idempotent and called
    // from `provision.ensureCollection` at startup — NOT numbered migrations.
    if (db.dbDialect(w).kind == .postgres) return ensureIndexPg(alloc, w, col);
    if (comptime !enabled) {
        // fts5 compiled out (-Dfts5=false): a searchable SQLite schema can't be served — fail
        // LOUDLY here so the caller (provision.zig) can refuse to start, rather than silently
        // skipping the index and letting `?search=` surface as a runtime 500 later. A collection
        // with no searchable fields is unaffected — nothing to provision either way.
        if (isSearchable(col)) return error.SearchDisabled;
        return;
    }
    return ensureIndexSqliteImpl(alloc, w, col);
}

fn ensureIndexSqliteImpl(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) !void {
    if (!schema.isValidIdentifier(col.name)) return;
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
    try create.appendSlice(sa, try std.fmt.allocPrint(sa, "CREATE VIRTUAL TABLE \"{s}\" USING fts5(", .{ft}));
    for (cols, 0..) |cn, i| {
        if (i > 0) try create.appendSlice(sa, ", ");
        try create.appendSlice(sa, try std.fmt.allocPrint(sa, "\"{s}\"", .{cn}));
    }
    try create.appendSlice(sa, try std.fmt.allocPrint(sa, ", content=\"{s}\");", .{col.name}));
    try w.exec(try toZ(sa, create.items));

    // Sync triggers (FTS5 external-content pattern). On delete/update we issue the special 'delete'
    // command so the index discards the old terms before re-indexing the new row.
    const col_list = try columnList(sa, cols, null);
    const new_list = try columnList(sa, cols, "new");
    const old_list = try columnList(sa, cols, "old");

    try w.exec(try toZ(sa, try std.fmt.allocPrint(sa, "CREATE TRIGGER \"{s}_ai\" AFTER INSERT ON \"{s}\" BEGIN INSERT INTO \"{s}\"(rowid, {s}) VALUES (new.rowid, {s}); END;", .{ ft, col.name, ft, col_list, new_list })));
    try w.exec(try toZ(sa, try std.fmt.allocPrint(sa, "CREATE TRIGGER \"{s}_ad\" AFTER DELETE ON \"{s}\" BEGIN INSERT INTO \"{s}\"(\"{s}\", rowid, {s}) VALUES ('delete', old.rowid, {s}); END;", .{ ft, col.name, ft, ft, col_list, old_list })));
    try w.exec(try toZ(sa, try std.fmt.allocPrint(sa, "CREATE TRIGGER \"{s}_au\" AFTER UPDATE ON \"{s}\" BEGIN INSERT INTO \"{s}\"(\"{s}\", rowid, {s}) VALUES ('delete', old.rowid, {s}); INSERT INTO \"{s}\"(rowid, {s}) VALUES (new.rowid, {s}); END;", .{ ft, col.name, ft, ft, col_list, old_list, ft, col_list, new_list })));

    // Repopulate from the content table (no-op on an empty table).
    try w.exec(try toZ(sa, try std.fmt.allocPrint(sa, "INSERT INTO \"{s}\"(\"{s}\") VALUES ('rebuild');", .{ ft, ft })));

    std.log.info("provision: ensured FTS5 search index '{s}' on '{s}' ({d} field(s))", .{ ft, col.name, cols.len });
}

// ---- Postgres provisioning (tsvector generated column + GIN index) ---------

/// Provision (idempotently) the Postgres `tsvector` full-text index for `col`: a STORED generated
/// column `"<col>_fts"` over the searchable columns plus a GIN index on it. A no-op when `col` has
/// no searchable fields (any stale column/index from a prior schema is dropped). Decides off the
/// column's three-state probe (`pgColumnState`): absent → create; present+matching-marker → no-op
/// (or recreate JUST the GIN index if only it is missing, NEVER re-touching the costly generated
/// column); present+mismatched/absent-marker (a searchable-column-SET drift) → drop + recreate. All
/// identifiers are gated through `schema.isValidIdentifier`; the column set is embedded only after
/// that gate, never from user input. Search-path-aware (`to_regclass`) so it targets the
/// collection's table in the active schema.
fn ensureIndexPg(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection) !void {
    if (!schema.isValidIdentifier(col.name)) return;
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
        if (state == .present) try dropIndexPg(alloc, w, col.name, tsv, idx);
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
            // Column present but marker missing/different → drift → DROP the column+index, then
            // recreate below (never `ADD COLUMN` onto the existing one).
            try dropIndexPg(alloc, w, col.name, tsv, idx);
        },
        .absent => {}, // nothing to drop — create below
    }

    // ALTER TABLE "<col>" ADD COLUMN "<tsv>" tsvector
    //   GENERATED ALWAYS AS (to_tsvector('simple', coalesce("c1",'')||' '||coalesce("c2",'')||…)) STORED;
    // The 2-arg to_tsvector(regconfig, text) with a literal config is IMMUTABLE (required for a
    // generated column); coalesce keeps NULL columns from voiding the whole vector.
    var expr: std.ArrayList(u8) = .empty;
    defer expr.deinit(alloc);
    {
        const head = try std.fmt.allocPrint(alloc, "to_tsvector('{s}', ", .{pg_ts_config});
        defer alloc.free(head);
        try expr.appendSlice(alloc, head);
    }
    for (cols, 0..) |cn, i| {
        if (i > 0) try expr.appendSlice(alloc, " || ' ' || ");
        const frag = try std.fmt.allocPrint(alloc, "coalesce(\"{s}\",'')", .{cn});
        defer alloc.free(frag);
        try expr.appendSlice(alloc, frag);
    }
    try expr.appendSlice(alloc, ")");

    {
        const sql = try std.fmt.allocPrintSentinel(alloc, "ALTER TABLE \"{s}\" ADD COLUMN \"{s}\" tsvector GENERATED ALWAYS AS ({s}) STORED;", .{ col.name, tsv, expr.items }, 0);
        defer alloc.free(sql);
        try w.exec(sql);
    }
    try createGinIndexPg(alloc, w, col.name, tsv, idx);
    {
        // Record the searchable column set as a marker comment so a later additive change that adds
        // or removes a `.searchable` field is detected as drift and rebuilds the column.
        const sql = try std.fmt.allocPrintSentinel(alloc, "COMMENT ON COLUMN \"{s}\".\"{s}\" IS '{s}';", .{ col.name, tsv, want_marker }, 0);
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
///   * `.present` with `marker != want` (incl. a missing/empty COMMENT) — drift → DROP + recreate.
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
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT col_description(a.attrelid, a.attnum) FROM pg_attribute a " ++
        "WHERE a.attrelid = to_regclass($1) AND a.attname = $2 AND a.attnum > 0 AND NOT a.attisdropped;", .{}, 0);
    defer alloc.free(sql);
    var st = try w.prepare(sql);
    defer st.finalize();
    const quoted = try std.fmt.allocPrint(alloc, "\"{s}\"", .{col_name});
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
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT to_regclass($1) IS NOT NULL;", .{}, 0);
    defer alloc.free(sql);
    var st = try w.prepare(sql);
    defer st.finalize();
    const quoted = try std.fmt.allocPrint(alloc, "\"{s}\"", .{rel});
    defer alloc.free(quoted); // bindText dupes its arg, so freeing after the bind is safe
    try st.bindText(1, quoted);
    if (!try st.step()) return false;
    return st.columnInt(0) != 0;
}

/// CREATE the GIN index `idx` over the generated tsvector column `tsv` on `col_name`. Used both on
/// a fresh provision and to recreate JUST the index when the column is already correct but the index
/// went missing (so we never drop+rebuild the expensive STORED generated column for an index-only gap).
fn createGinIndexPg(alloc: std.mem.Allocator, w: *db.Db, col_name: []const u8, tsv: []const u8, idx: []const u8) !void {
    const sql = try std.fmt.allocPrintSentinel(alloc, "CREATE INDEX \"{s}\" ON \"{s}\" USING GIN (\"{s}\");", .{ idx, col_name, tsv }, 0);
    defer alloc.free(sql);
    try w.exec(sql);
}

/// DROP the Postgres GIN index + the generated tsvector column if present (idempotent). Dropping
/// the column cascades the index, but the explicit DROP INDEX keeps it robust to either existing
/// alone. (`col_name` is the base table.)
fn dropIndexPg(alloc: std.mem.Allocator, w: *db.Db, col_name: []const u8, tsv: []const u8, idx: []const u8) !void {
    {
        const sql = try std.fmt.allocPrintSentinel(alloc, "DROP INDEX IF EXISTS \"{s}\";", .{idx}, 0);
        defer alloc.free(sql);
        try w.exec(sql);
    }
    {
        const sql = try std.fmt.allocPrintSentinel(alloc, "ALTER TABLE \"{s}\" DROP COLUMN IF EXISTS \"{s}\";", .{ col_name, tsv }, 0);
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
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, p ++ ".\"{s}\"", .{cn}));
        } else {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\"", .{cn}));
        }
    }
    return out.toOwnedSlice(alloc);
}

/// DROP the FTS shadow table + its three sync triggers if present (idempotent).
fn dropIndex(alloc: std.mem.Allocator, w: *db.Db, col_name: []const u8, ft: []const u8) !void {
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc, "DROP TRIGGER IF EXISTS \"{s}_ai\";", .{ft})));
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc, "DROP TRIGGER IF EXISTS \"{s}_ad\";", .{ft})));
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc, "DROP TRIGGER IF EXISTS \"{s}_au\";", .{ft})));
    try w.exec(try toZ(alloc, try std.fmt.allocPrint(alloc, "DROP TABLE IF EXISTS \"{s}\";", .{ft})));
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
    var st = try w.prepare(try toZ(alloc, try std.fmt.allocPrint(alloc, "PRAGMA table_info(\"{s}\");", .{ft})));
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
    try st.bindText(1, try std.fmt.allocPrint(alloc, "{s}_ai", .{ft}));
    try st.bindText(2, try std.fmt.allocPrint(alloc, "{s}_ad", .{ft}));
    try st.bindText(3, try std.fmt.allocPrint(alloc, "{s}_au", .{ft}));
    _ = try st.step();
    return st.columnInt(0) == 3;
}

/// allocPrint helpers hand us `[]u8`; `db.exec`/`db.prepare` want a sentinel-terminated slice.
fn toZ(alloc: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(alloc, "{s}", .{s}, 0);
}

// ---- Tests -----------------------------------------------------------------

const collections = @import("../collections.zig");
const migrations = @import("../migrations.zig");
const records = @import("../records.zig");

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

    const s = (try build(a, db.dbDialect(&d), col, "zig")).?;
    // SQLite `build` returns an owned Search (join/where/order SQL + the sanitized param text), no
    // aliasing (order_param is null on SQLite) — free the four heap slices after use.
    defer {
        a.free(s.join_sql);
        a.free(s.where_sql);
        a.free(s.order_sql);
        a.free(s.param.text);
    }
    const sql = try std.fmt.allocPrintSentinel(a, "SELECT \"articles\".\"title\" FROM \"articles\" {s} WHERE {s};", .{ s.join_sql, s.where_sql }, 0);
    defer a.free(sql);
    var st = try d.prepare(sql);
    defer st.finalize();
    try st.bindText(1, s.param.text);
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("zig programming language", st.columnText(0));
    try std.testing.expect(!try st.step()); // only the one matching row
}
