//! ParamSink — the single source-of-truth placeholder counter for the `$n` rework (issue #159,
//! PR-3).
//!
//! ## The problem
//! ZigBase's SQL producers (the query `compiler`/`keyset`, the FTS/vector search builders, the
//! ability/tenant predicates, and the hand-written CRUD statements in `records.zig`) emit the
//! SQLite anonymous placeholder `?` (auto-numbered by position) and, in the write paths, the
//! numbered `?1..?N` form. SQLite assigns each anonymous `?` its position implicitly; the binder
//! (`records.bindParams`) then binds values positionally with a running 1-based index. PostgreSQL
//! has no anonymous placeholder — it requires the explicit `$1..$n` — so the same statements must
//! carry `$n` whose number equals the 1-based index the binder will bind that value at.
//!
//! ## The contract this preserves
//! Across **every** call site the binder's rule is identical: *a value bound at 1-based index `i`
//! reads back as `$i`.* So the renumbering only has to make the SQL text agree with that:
//!   * an anonymous `?` is the next value in bind order → `$next`, `next += 1`;
//!   * a numbered `?N` is bound explicitly at index `N` → `$N` (PostgreSQL accepts `$N` in any
//!     textual order and allows reuse, exactly like SQLite's `?N`), and the running counter is
//!     advanced past `N` so a later anonymous `?` continues after it.
//! Because the binder visits values in the **same left-to-right textual order** the SQL fragments
//! were assembled in (see `records.list`: WHERE params, then the vector embedding in ORDER BY,
//! then LIMIT/OFFSET), renumbering the final assembled SQL left-to-right yields exactly the bind
//! indices the binder uses. This is why a single post-assembly pass is correct AND why it
//! reproduces the fragile vector-embedding-between-WHERE-and-LIMIT coupling without each producer
//! having to know its offset.
//!
//! ## Default build is byte-identical
//! The renumber is only ever taken on the Postgres arm. On the SQLite dialect `renumber`/`renumberZ`
//! return the input verbatim (the same slice — no allocation, no copy), so a `-Dpostgres=false`
//! binary — and a SQLite-backed connection inside a `-Dpostgres=true` binary — emit byte-identical
//! SQL to before.

const std = @import("std");
const dialect_mod = @import("dialect.zig");

pub const Dialect = dialect_mod.Dialect;

/// The error set `rewrite` can produce beyond an allocator failure. A numbered `?N` whose N
/// overflows a `usize` or exceeds the PostgreSQL bind-parameter cap cannot be rendered as a valid
/// `$n`, so it is surfaced as a value here instead of panicking. See `max_param_index`.
pub const RewriteError = std.mem.Allocator.Error || error{BadPlaceholder};

/// The error set the public prepare-boundary helpers (`renumber`/`renumberZ`/`lowerStmtZ`) can
/// produce. A malformed placeholder is translated to `error.PrepareFailed` — the domain error every
/// prepare call site already handles — because a `?N` this pass cannot render is exactly a statement
/// that will not prepare. Keeping the public surface within `Allocator.Error || DbError.PrepareFailed`
/// is what lets the existing `try`/`catch` call sites keep compiling unchanged.
pub const PrepareError = std.mem.Allocator.Error || error{PrepareFailed};

/// The largest numbered placeholder `?N` this pass can render as `$N`. PostgreSQL's Bind message
/// counts parameters in an `i16`, so `$32767` is the ceiling (and "$32767" is 6 bytes, inside
/// `Dialect.placeholder_buf_len` = 8). A larger — or `usize`-overflowing — N can only come from a
/// developer typo in raw SQL and is a bad statement, not grounds to panic or overflow the buffer.
pub const max_param_index: usize = 32767;

/// Translate a `rewrite` failure at the prepare boundary: OOM stays OOM; a malformed placeholder
/// becomes `error.PrepareFailed` (see `PrepareError`).
fn toPrepareError(e: RewriteError) PrepareError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadPlaceholder => error.PrepareFailed,
    };
}

/// A running placeholder counter bound to a dialect. The whole `$n` rework funnels through one of
/// these per prepared statement, so emission (the rewritten SQL) and binding (the positional
/// `bindParams`) share a single source of truth for the next placeholder number.
pub const ParamSink = struct {
    dialect: Dialect,
    /// Next 1-based number an anonymous `?` will receive.
    next: usize = 1,

    pub fn init(d: Dialect) ParamSink {
        return .{ .dialect = d };
    }

    /// Rewrite `sql`'s placeholders into the sink's dialect form, advancing `next`. SQLite returns
    /// a verbatim copy (`?` unchanged). String literals (`'...'`, with `''` escapes) are copied
    /// through untouched so a literal that happens to contain `?` is never mistaken for a
    /// placeholder. Identifiers (`"..."`) cannot contain `?` (gated by `schema.isValidIdentifier`),
    /// so they need no special handling.
    ///
    /// SECURITY-RELEVANT SCANNER ASSUMPTIONS — keep these invariants true when adding SQL producers:
    ///   1. The scanner only understands SINGLE-quoted string literals (`'...'` with `''` escapes).
    ///      It does NOT understand: PostgreSQL JSON/hstore operators that spell `?` (`?`, `?|`,
    ///      `?&`), a `??` literal-question-mark escape, `E'...'` backslash escapes, or `$tag$…$tag$`
    ///      dollar-quoted bodies. ZigBase's generated SQL uses NONE of these today, so every `?`
    ///      outside a `'...'` literal IS a bind placeholder. If a future producer emits any of them,
    ///      this scanner MUST be extended first — an unhandled `?` inside e.g. a JSON operator or a
    ///      dollar-quoted body would be miscounted as a placeholder and shift every later `$n`.
    ///   2. Safety ALSO rests on the broader invariant that all user-supplied values are BOUND, never
    ///      interpolated — so no attacker-controlled `?` (or `'`) ever reaches this generated SQL.
    ///      The scanner is a syntactic renumber, not a sanitizer; it relies on that binding discipline.
    pub fn rewrite(self: *ParamSink, alloc: std.mem.Allocator, sql: []const u8) RewriteError![]u8 {
        if (self.dialect.kind == .sqlite) return alloc.dupe(u8, sql);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var pbuf: [Dialect.placeholder_buf_len]u8 = undefined;

        var i: usize = 0;
        while (i < sql.len) {
            const c = sql[i];
            if (c == '\'') {
                // Copy a single-quoted string literal verbatim, honoring '' escapes.
                try out.append(alloc, c);
                i += 1;
                while (i < sql.len) {
                    const ch = sql[i];
                    try out.append(alloc, ch);
                    i += 1;
                    if (ch == '\'') {
                        if (i < sql.len and sql[i] == '\'') {
                            try out.append(alloc, '\''); // escaped quote — stays in the literal
                            i += 1;
                            continue;
                        }
                        break; // end of literal
                    }
                }
                continue;
            }
            if (c == '?') {
                // Numbered `?N`? Collect the trailing digit run.
                var j = i + 1;
                while (j < sql.len and sql[j] >= '0' and sql[j] <= '9') : (j += 1) {}
                if (j > i + 1) {
                    // The digit run is non-empty ASCII digits, but that does NOT prove it fits a
                    // `usize` (a 20+-digit run overflows) or the PostgreSQL param cap — so reject an
                    // unrenderable N as a value rather than `catch unreachable`-panicking (overflow)
                    // or overflowing the fixed placeholder buffer (`$10000000` is 9 bytes).
                    const num = std.fmt.parseInt(usize, sql[i + 1 .. j], 10) catch return error.BadPlaceholder;
                    if (num < 1 or num > max_param_index) return error.BadPlaceholder;
                    try out.appendSlice(alloc, self.dialect.placeholder(&pbuf, num));
                    if (num + 1 > self.next) self.next = num + 1;
                    i = j;
                } else {
                    // The anonymous running counter is bounded by the SAME cap as a numbered `?N`:
                    // once `next` exceeds `max_param_index` the value cannot be a valid `$n` (PG's
                    // i16 param cap) AND `$10000000` (9 bytes) would overflow the 8-byte placeholder
                    // buffer, panicking `dialect.placeholder`'s `catch unreachable`. Reject it as a
                    // value instead — the same fix the numbered path already has. This guard is what
                    // makes that `catch unreachable` genuinely provable: `next <= 32767` ⇒ "$32767"
                    // (6 bytes) always fits.
                    if (self.next > max_param_index) return error.BadPlaceholder;
                    try out.appendSlice(alloc, self.dialect.placeholder(&pbuf, self.next));
                    self.next += 1;
                    i += 1;
                }
                continue;
            }
            try out.append(alloc, c);
            i += 1;
        }
        return out.toOwnedSlice(alloc);
    }
};

/// One-shot convenience: renumber `sql` for `dialect` with a fresh counter. SQLite returns the
/// input slice unchanged (no allocation). Most call sites prepare one statement and want exactly
/// this.
pub fn renumber(alloc: std.mem.Allocator, dialect: Dialect, sql: []const u8) PrepareError![]const u8 {
    if (dialect.kind == .sqlite) return sql;
    var sink = ParamSink.init(dialect);
    return sink.rewrite(alloc, sql) catch |e| return toPrepareError(e);
}

/// Sentinel-terminated variant for `db.prepare`, which wants a `[:0]const u8`. SQLite returns the
/// input slice unchanged (zero-cost in the default build); Postgres allocates the rewritten,
/// NUL-terminated string.
pub fn renumberZ(alloc: std.mem.Allocator, dialect: Dialect, sql: [:0]const u8) PrepareError![:0]const u8 {
    if (dialect.kind == .sqlite) return sql;
    var sink = ParamSink.init(dialect);
    const rewritten = sink.rewrite(alloc, sql) catch |e| return toPrepareError(e);
    defer alloc.free(rewritten);
    return std.fmt.allocPrintSentinel(alloc, "{s}", .{rewritten}, 0);
}

/// Lower a curated auth/oauth/analytics/session DML statement from the SQLite flavor to
/// `dialect`, returning a NUL-terminated string ready for `Db.prepare`. Two transforms, both
/// no-ops on SQLite (so the SQLite result is byte-identical — the input slice is returned
/// unchanged, zero-cost):
///   1. the two server-`now` expressions these subsystems use — `datetime('now')` (a TEXT
///      timestamp column) and `strftime('%Y-%m-%dT%H:%M:%SZ','now')` (an ISO-8601 capture) — are
///      replaced with the dialect's `nowTextExpr()` / `nowIso8601Expr()` (the same ISO `Z` text
///      on both backends);
///   2. `?N`/`?` placeholders are renumbered to `$n` (`ParamSink`, document-order, mixed-form).
///
/// These are the ONLY SQLite-isms in the curated auth/session/token/oauth/analytics/webauthn/
/// challenge statements; the DDL-keyword / `GLOB` / `INSERT OR IGNORE` isms live in the system
/// migrations (lowered by `Dialect.lowerMigrationSql`). A `strftime` over a COLUMN (e.g. the
/// analytics time-bucket `strftime('%Y-%m-%d',"occurred_at")`) is NOT a `now` form, is left
/// untouched here, and its caller dialect-branches it directly. The placeholder renumber relies
/// on the same scanner invariants documented on `ParamSink.rewrite`.
pub fn lowerStmtZ(alloc: std.mem.Allocator, dialect: Dialect, sql: [:0]const u8) PrepareError![:0]const u8 {
    if (dialect.kind == .sqlite) return sql; // byte-identical — nothing to lower
    // Substitute the two server-`now` expressions, but ONLY when actually present:
    // `std.mem.replaceOwned` allocates + copies the whole string even on zero matches, so an
    // unconditional pass costs two full-string copies on every prepare — including the
    // placeholder-only statements on the hot auth-VERIFY path, which carry NEITHER `now` form.
    // A cheap `indexOf` guard skips the copy when the pattern is absent. `cur` tracks the live
    // string; `owned` is non-null only when `cur` is a copy we own and must free.
    var cur: []const u8 = sql;
    var owned: ?[]u8 = null;
    defer if (owned) |o| alloc.free(o);
    inline for (.{
        .{ "strftime('%Y-%m-%dT%H:%M:%SZ','now')", dialect.nowIso8601Expr() },
        .{ "datetime('now')", dialect.nowTextExpr() },
    }) |pair| {
        if (std.mem.indexOf(u8, cur, pair[0]) != null) {
            const next = try std.mem.replaceOwned(u8, alloc, cur, pair[0], pair[1]);
            if (owned) |o| alloc.free(o); // free the prior intermediate before re-pointing
            owned = next;
            cur = next;
        }
    }
    // The placeholder renumber always runs on the Postgres arm.
    var sink = ParamSink.init(dialect);
    const renumbered = sink.rewrite(alloc, cur) catch |e| return toPrepareError(e);
    defer alloc.free(renumbered);
    return std.fmt.allocPrintSentinel(alloc, "{s}", .{renumbered}, 0);
}

// ---------------------------------------------------------------------------
// Tests — pure string assertions; run in EVERY build (no backend needed).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "param_sink: lowerStmtZ is identity on SQLite (same slice, no alloc)" {
    const sql: [:0]const u8 = "INSERT INTO \"_sessions\" (\"id\",\"created\") VALUES (?1,datetime('now'));";
    const out = try lowerStmtZ(testing.allocator, Dialect.sqlite, sql);
    try testing.expectEqual(sql.ptr, out.ptr); // unchanged slice, nothing to free
}

test "param_sink: lowerStmtZ lowers datetime('now') + renumbers on Postgres" {
    const sql: [:0]const u8 =
        "INSERT INTO \"_sessions\" (\"id\",\"created\",\"lastSeen\",\"expires\") VALUES (?1,datetime('now'),datetime('now'),?2);";
    const out = try lowerStmtZ(testing.allocator, Dialect.postgres, sql);
    defer testing.allocator.free(out);
    const now_pg = Dialect.postgres.nowTextExpr();
    const want = std.fmt.allocPrint(testing.allocator, "INSERT INTO \"_sessions\" (\"id\",\"created\",\"lastSeen\",\"expires\") VALUES ($1,{s},{s},$2);", .{ now_pg, now_pg }) catch unreachable;
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, out);
    try testing.expectEqual(@as(u8, 0), out.ptr[out.len]); // NUL-terminated
}

test "param_sink: lowerStmtZ lowers the strftime ISO 'now' capture on Postgres" {
    const sql: [:0]const u8 = "SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now');";
    const out = try lowerStmtZ(testing.allocator, Dialect.postgres, sql);
    defer testing.allocator.free(out);
    // The strftime-now becomes the to_char ISO form; no placeholders to renumber.
    try testing.expect(std.mem.indexOf(u8, out, "to_char(now()") != null);
    try testing.expect(std.mem.indexOf(u8, out, "strftime") == null);
}

test "param_sink: sqlite is identity (byte-for-byte, same slice)" {
    const sql = "SELECT * FROM t WHERE a = ? AND b IN (?,?,?)";
    const out = try renumber(testing.allocator, Dialect.sqlite, sql);
    // SQLite returns the very same slice — no allocation, so nothing to free.
    try testing.expectEqual(sql.ptr, out.ptr);
    try testing.expectEqualStrings(sql, out);
}

test "param_sink: anonymous ? become $1..$n in left-to-right order" {
    const out = try renumber(testing.allocator, Dialect.postgres, "WHERE a = ? AND b = ? OR c IN (?,?,?)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("WHERE a = $1 AND b = $2 OR c IN ($3,$4,$5)", out);
}

test "param_sink: numbered ?N map to $N and advance the anonymous counter past them" {
    // guardPasses shape: `?1` (the id) then anonymous `?` fragments bound starting at index 2.
    const out = try renumber(testing.allocator, Dialect.postgres, "WHERE \"id\"=?1 AND (\"x\" = ? AND \"y\" = ?)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("WHERE \"id\"=$1 AND (\"x\" = $2 AND \"y\" = $3)", out);
}

test "param_sink: update SET-before-WHERE keeps numbered identity (\\$2 may precede \\$1)" {
    // updateInTxn shape: the SET clause's `?2` appears textually BEFORE the WHERE's `?1`. PG `$N`
    // is order-independent, so the value bound at index 1 (id) still reads as $1 wherever it sits.
    const out = try renumber(testing.allocator, Dialect.postgres, "UPDATE t SET \"updated\"=now(),\"f\"=?2 WHERE \"id\"=?1");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("UPDATE t SET \"updated\"=now(),\"f\"=$2 WHERE \"id\"=$1", out);
}

test "param_sink: FRAGILE — WHERE params, then vector embedding in ORDER BY, then LIMIT/OFFSET" {
    // This pins the designer-flagged coupling (records.zig ~1996-2004): in OFFSET mode the vector
    // embedding `?` sits BETWEEN the WHERE params and LIMIT/OFFSET, so its $n must land exactly
    // there. The bind order is: WHERE (1,2) -> vector embedding (3) -> LIMIT (4) -> OFFSET (5).
    const offset_sql =
        "SELECT \"id\" FROM \"docs\" WHERE (\"docs\".\"title\" = ?) AND (\"docs\".\"embedding\" IS NOT NULL) " ++
        "ORDER BY vec_distance_cosine(\"docs\".\"embedding\", ?), \"docs\".\"created\" DESC LIMIT ? OFFSET ?;";
    const out = try renumber(testing.allocator, Dialect.postgres, offset_sql);
    defer testing.allocator.free(out);
    const want =
        "SELECT \"id\" FROM \"docs\" WHERE (\"docs\".\"title\" = $1) AND (\"docs\".\"embedding\" IS NOT NULL) " ++
        "ORDER BY vec_distance_cosine(\"docs\".\"embedding\", $2), \"docs\".\"created\" DESC LIMIT $3 OFFSET $4;";
    try testing.expectEqualStrings(want, out);
    // Independently assert the embedding placeholder is numbered AFTER the WHERE param and BEFORE
    // LIMIT — the exact property a drifting counter would violate.
    const emb = std.mem.indexOf(u8, out, "vec_distance_cosine(\"docs\".\"embedding\", $2)").?;
    const where_p = std.mem.indexOf(u8, out, "= $1").?;
    const limit_p = std.mem.indexOf(u8, out, "LIMIT $3").?;
    try testing.expect(where_p < emb and emb < limit_p);
}

test "param_sink: a ? inside a string literal is NOT a placeholder" {
    const out = try renumber(testing.allocator, Dialect.postgres, "WHERE note = 'huh? really??' AND a = ?");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("WHERE note = 'huh? really??' AND a = $1", out);
}

test "param_sink: '' escape inside a literal is handled, placeholder after it still counts" {
    const out = try renumber(testing.allocator, Dialect.postgres, "WHERE a = 'O''Brien?' AND b = ? AND c = ?");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("WHERE a = 'O''Brien?' AND b = $1 AND c = $2", out);
}

test "param_sink: stateful sink runs one counter across rewrite calls" {
    var sink = ParamSink.init(Dialect.postgres);
    const a = try sink.rewrite(testing.allocator, "a = ?, b = ?");
    defer testing.allocator.free(a);
    const b = try sink.rewrite(testing.allocator, "c = ?");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("a = $1, b = $2", a);
    try testing.expectEqualStrings("c = $3", b);
}

test "param_sink: a valid boundary ?N (max_param_index) still renders as $N" {
    const sql = "WHERE \"id\"=?32767";
    const out = try renumber(testing.allocator, Dialect.postgres, sql);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("WHERE \"id\"=$32767", out);
}

test "param_sink: an overflowing ?N (21+ digits) errors instead of panicking (BadPlaceholder)" {
    // usize max is 20 digits on 64-bit; a 21-digit run overflows parseInt. Previously a
    // `catch unreachable` here panicked the process; now it is a value (rewrite: BadPlaceholder;
    // public boundary: PrepareFailed).
    var sink = ParamSink.init(Dialect.postgres);
    try testing.expectError(error.BadPlaceholder, sink.rewrite(testing.allocator, "WHERE a = ?99999999999999999999999"));
    try testing.expectError(error.PrepareFailed, renumber(testing.allocator, Dialect.postgres, "WHERE a = ?99999999999999999999999"));
}

test "param_sink: an out-of-range ?N (> max_param_index / == 0) errors (buffer-overflow guard)" {
    // `$10000000` is 9 bytes and would overflow the 8-byte placeholder buffer; `?0` is not a
    // valid 1-based bind index. Both are rejected rather than rendered.
    var sink = ParamSink.init(Dialect.postgres);
    try testing.expectError(error.BadPlaceholder, sink.rewrite(testing.allocator, "WHERE a = ?10000000"));
    try testing.expectError(error.PrepareFailed, renumberZ(testing.allocator, Dialect.postgres, "WHERE a = ?0"));
    // SQLite is verbatim (early return) — the same pathological text never reaches the parser.
    const lite = try renumberZ(testing.allocator, Dialect.sqlite, "WHERE a = ?10000000");
    try testing.expectEqual(@as(usize, "WHERE a = ?10000000".len), lite.len);
}

test "param_sink: the ANONYMOUS running counter is bounded too (no buffer-overflow panic past the cap)" {
    // A numbered `?32767` advances the anonymous counter to 32768; the very next anonymous `?`
    // would render as `$32768` — over PG's i16 param cap — and, further out (>=$10000000), would
    // overflow the 8-byte placeholder buffer and panic `dialect.placeholder`'s `catch unreachable`.
    // The guard rejects it as a value (BadPlaceholder / PrepareFailed) exactly like the numbered
    // path, rather than the previous unguarded anonymous emission.
    var sink = ParamSink.init(Dialect.postgres);
    try testing.expectError(error.BadPlaceholder, sink.rewrite(testing.allocator, "\"id\"=?32767 AND \"x\"=?"));
    try testing.expectError(error.PrepareFailed, renumber(testing.allocator, Dialect.postgres, "\"id\"=?32767 AND \"x\"=?"));
    // SQLite is verbatim (early return) — the pathological counter never runs.
    const lite = try renumber(testing.allocator, Dialect.sqlite, "\"id\"=?32767 AND \"x\"=?");
    try testing.expectEqualStrings("\"id\"=?32767 AND \"x\"=?", lite);
}

test "param_sink: renumberZ produces a NUL-terminated string on PG, same slice on SQLite" {
    const sql: [:0]const u8 = "WHERE a = ? AND b = ?";
    const pg = try renumberZ(testing.allocator, Dialect.postgres, sql);
    defer testing.allocator.free(pg);
    try testing.expectEqualStrings("WHERE a = $1 AND b = $2", pg);
    try testing.expectEqual(@as(u8, 0), pg.ptr[pg.len]);

    const lite = try renumberZ(testing.allocator, Dialect.sqlite, sql);
    try testing.expectEqual(sql.ptr, lite.ptr); // unchanged slice, no free needed
}
