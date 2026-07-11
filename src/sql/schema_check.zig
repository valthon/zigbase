//! Comptime-checked raw SQL (issue #281, option 1).
//!
//! Apps that drop below the collection/query API to raw SQL — `conn.prepare(sql)`,
//! `data.queryAs(T, conn, alloc, sql, args)`, or `ctx.records().queryAs(T, sql, args)` — get NO
//! compile-time guarantee that the tables/columns they name actually exist in the comptime
//! `.collections` schema. A typo (`FROM postts`, `o.totl`) is invisible until the query runs and
//! errors (or worse, silently returns nothing). This module closes that gap: it validates the
//! identifiers in a SQL string against the lowered schema and `@compileError`s the build on an
//! unknown table or a mistyped *qualified* column.
//!
//! ## THE hard rule: zero false positives
//! A checker that rejects VALID SQL is worse than useless — consumers delete the call. So this
//! validates only a deliberately narrow, high-confidence subset and biases HARD toward NOT
//! flagging when it cannot confidently classify a token:
//!   - TABLE names after `FROM` / `JOIN` / `INTO` / `UPDATE` are validated strictly (the common
//!     typo). CTE names (`WITH x AS (...)`), `<collection>_fts` shadow tables, and `extra_tables`
//!     (internal/migration-owned) all count as known. A subquery `FROM (SELECT ...)` is never
//!     treated as a table.
//!   - QUALIFIED columns `alias.column` / `table.column` are validated ONLY when the qualifier
//!     resolves to a known collection (via the FROM/JOIN alias map). Everything else is skipped:
//!     unqualified columns, function names, computed `AS` aliases, `alias.*`, expression tokens,
//!     string-literal / comment contents, and anything inside a `FROM (subquery)`.
//!
//! ## Usage
//! Name the App type so you can reach its lowered schema, then wrap the SQL:
//! ```zig
//! const Backend = zigbase.App(.{ .collections = .{ ... } });
//! // ergonomic: validate AND return the string handed to queryAs/prepare
//! const rows = try ctx.records().queryAs(Row,
//!     zigbase.checkedSql(Backend.collections, "SELECT p.title FROM posts p WHERE p.status = ?1"),
//!     .{ "published" });
//! // void form, with internal/migration-owned tables opted in:
//! comptime zigbase.checkSqlOpts(Backend.collections,
//!     "INSERT INTO plugin_audit_log(note) VALUES('x')",
//!     .{ .extra_tables = &.{"plugin_audit_log"} });
//! ```
//!
//! ## Testability
//! The analysis core (`analyze`) is a PURE RUNTIME function returning an optional `Finding`, so it
//! is exercised by ordinary unit tests. The `@compileError` path itself cannot be an executable
//! test (a failed comptime check would fail the build) — mirrors the pattern in `data.zig`'s
//! `assertFieldsExist`. The comptime wrappers just run `analyze` at comptime and turn a `Finding`
//! into a `@compileError` naming the offending identifier and the valid options.

const std = @import("std");
const schema = @import("../schema.zig");
const ident = @import("schema_ident.zig");

/// Case-insensitive identifier compare — shared with the query builder (single source of truth).
const eqIC = ident.eqIC;

pub const SqlCheckOptions = struct {
    /// Tables that legitimately appear in raw SQL but are NOT comptime collections: engine
    /// internals (`_kv`, `_events`, `_sessions`, `_queue_jobs`) and migration-owned tables
    /// (e.g. a `plugin_audit_log` the app's own `.migrations` created). Listed here they count
    /// as known instead of being flagged.
    extra_tables: []const []const u8 = &.{},
    /// When true (default), best-effort validation of *qualified* `alias.column` refs whose
    /// qualifier resolves to a known collection. Tables are ALWAYS checked regardless.
    check_columns: bool = true,
};

pub const Finding = union(enum) {
    unknown_table: []const u8,
    unknown_column: struct { table: []const u8, column: []const u8 },
};

// ===========================================================================
// Tokenizer
// ===========================================================================

const Kind = enum { ident, dot, lparen, rparen, comma, star, other, eof };

const Tok = struct {
    kind: Kind,
    text: []const u8 = "",
    /// A quoted identifier (`"x"`, `` `x` ``, `[x]`) is a NAME, never a keyword — so `"from"`
    /// does not start a FROM clause. Tracked so keyword matching can exclude it.
    quoted: bool = false,
};

const Lexer = struct {
    src: []const u8,
    i: usize = 0,

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }
    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn next(self: *Lexer) Tok {
        const s = self.src;
        while (self.i < s.len) {
            const c = s[self.i];
            // whitespace
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.i += 1;
                continue;
            }
            // -- line comment
            if (c == '-' and self.i + 1 < s.len and s[self.i + 1] == '-') {
                self.i += 2;
                while (self.i < s.len and s[self.i] != '\n') self.i += 1;
                continue;
            }
            // /* block comment */
            if (c == '/' and self.i + 1 < s.len and s[self.i + 1] == '*') {
                self.i += 2;
                while (self.i + 1 < s.len and !(s[self.i] == '*' and s[self.i + 1] == '/')) self.i += 1;
                self.i = @min(self.i + 2, s.len);
                continue;
            }
            // '...' string literal ('' is an escaped quote). Skipped entirely.
            if (c == '\'') {
                self.i += 1;
                while (self.i < s.len) {
                    if (s[self.i] == '\'') {
                        if (self.i + 1 < s.len and s[self.i + 1] == '\'') {
                            self.i += 2;
                            continue;
                        }
                        self.i += 1;
                        break;
                    }
                    self.i += 1;
                }
                continue;
            }
            // "..." or `...` quoted identifier
            if (c == '"' or c == '`') {
                const q = c;
                self.i += 1;
                const start = self.i;
                while (self.i < s.len and s[self.i] != q) self.i += 1;
                const text = s[start..self.i];
                if (self.i < s.len) self.i += 1; // closing quote
                return .{ .kind = .ident, .text = text, .quoted = true };
            }
            // [...] bracket-quoted identifier
            if (c == '[') {
                self.i += 1;
                const start = self.i;
                while (self.i < s.len and s[self.i] != ']') self.i += 1;
                const text = s[start..self.i];
                if (self.i < s.len) self.i += 1;
                return .{ .kind = .ident, .text = text, .quoted = true };
            }
            if (isIdentStart(c)) {
                const start = self.i;
                while (self.i < s.len and isIdentChar(s[self.i])) self.i += 1;
                return .{ .kind = .ident, .text = s[start..self.i] };
            }
            self.i += 1;
            return switch (c) {
                '.' => .{ .kind = .dot },
                '(' => .{ .kind = .lparen },
                ')' => .{ .kind = .rparen },
                ',' => .{ .kind = .comma },
                '*' => .{ .kind = .star },
                else => .{ .kind = .other, .text = s[self.i - 1 .. self.i] },
            };
        }
        return .{ .kind = .eof };
    }

    fn peek(self: *Lexer) Tok {
        var copy = self.*;
        return copy.next();
    }
};

/// True if `t` is the (unquoted) keyword `kw`.
fn kwEq(t: Tok, kw: []const u8) bool {
    return t.kind == .ident and !t.quoted and eqIC(t.text, kw);
}

/// Keywords that CANNOT be a table alias (so `FROM posts WHERE` doesn't read `WHERE` as an alias).
/// Erring toward classifying a token as a stopword only loses a column-check (safe); the reverse
/// would poison the alias map, which is why the set is broad.
fn isAliasStopword(t: Tok) bool {
    if (t.kind != .ident or t.quoted) return false;
    const kws = [_][]const u8{
        "on",     "where",  "join",   "inner",     "left",  "right",
        "full",   "outer",  "cross",  "natural",   "using", "group",
        "order",  "having", "limit",  "offset",    "union", "intersect",
        "except", "set",    "values", "returning", "and",   "or",
        "not",    "window", "as",     "when",      "then",  "else",
        "end",    "from",
    };
    for (kws) |k| if (eqIC(t.text, k)) return true;
    return false;
}

/// Consume tokens through the matching close paren. Call with the opening `(` ALREADY consumed.
fn skipBalanced(lex: *Lexer) void {
    var depth: usize = 1;
    while (depth > 0) {
        const t = lex.next();
        switch (t.kind) {
            .eof => return,
            .lparen => depth += 1,
            .rparen => depth -= 1,
            else => {},
        }
    }
}

// ===========================================================================
// Analyzer
// ===========================================================================

const MAXN = 64;

const AliasEntry = struct { alias: []const u8, coll_index: usize };

const Analyzer = struct {
    cols: []const schema.Collection,
    opts: SqlCheckOptions,
    cte: [MAXN][]const u8 = undefined,
    cte_len: usize = 0,
    /// Set when there are more CTE names than we can store. Since a missed CTE name would be a
    /// FALSE POSITIVE (a valid `FROM <cte>` flagged as unknown), we bail to "OK" on overflow.
    cte_overflow: bool = false,
    alias: [MAXN]AliasEntry = undefined,
    alias_len: usize = 0,

    fn addCte(self: *Analyzer, name: []const u8) void {
        if (self.cte_len >= MAXN) {
            self.cte_overflow = true;
            return;
        }
        self.cte[self.cte_len] = name;
        self.cte_len += 1;
    }

    fn addAlias(self: *Analyzer, name: []const u8, idx: usize) void {
        // Overflow just drops the alias — column checks are best-effort, so this is safe.
        if (self.alias_len >= MAXN) return;
        self.alias[self.alias_len] = .{ .alias = name, .coll_index = idx };
        self.alias_len += 1;
    }

    /// Index of the collection whose name matches `name` (real collections only — NOT fts/cte).
    fn collectionIndex(self: *Analyzer, name: []const u8) ?usize {
        return ident.collectionIndexByName(self.cols, name);
    }

    fn isKnownTable(self: *Analyzer, name: []const u8) bool {
        if (self.collectionIndex(name) != null) return true;
        // <collection>_fts shadow table for a searchable collection.
        if (name.len > schema.fts_suffix.len and eqIC(name[name.len - schema.fts_suffix.len ..], schema.fts_suffix)) {
            const base = name[0 .. name.len - schema.fts_suffix.len];
            for (self.cols) |c| {
                if (schema.hasSearchableField(c) and eqIC(base, c.name)) return true;
            }
        }
        for (self.cte[0..self.cte_len]) |t| if (eqIC(name, t)) return true;
        for (self.opts.extra_tables) |t| if (eqIC(name, t)) return true;
        return false;
    }

    /// Resolve a qualifier `name` to its collection index, or null if it isn't a known collection
    /// alias/table — OR if it is AMBIGUOUS. `checkTables`/`checkColumns` scan the whole statement
    /// (CTE bodies, subqueries), so the same alias can be introduced in multiple scopes bound to
    /// DIFFERENT collections; resolving to the first match could validate `name.col` against the
    /// wrong collection → a false positive. So a name defined more than once anywhere is treated as
    /// ambiguous and its columns are not checked (table validation is unaffected).
    fn aliasCollection(self: *Analyzer, name: []const u8) ?usize {
        var found: ?usize = null;
        for (self.alias[0..self.alias_len]) |e| {
            if (eqIC(name, e.alias)) {
                if (found != null) return null; // defined >1× → ambiguous → skip column check
                found = e.coll_index;
            }
        }
        return found;
    }

    /// Whether `name` is a valid column of collection `ci`. Delegates to the shared valid-column
    /// set (built-ins ∪ auth system cols ∪ fields; views accept any column) that the query builder
    /// uses too, so the two features can never disagree on what a collection's columns are.
    fn columnValid(self: *Analyzer, ci: usize, name: []const u8) bool {
        return ident.isValidColumn(self.cols[ci], name);
    }

    // -- pass A: collect CTE names ------------------------------------------
    fn collectCtes(self: *Analyzer, src: []const u8) void {
        var lex = Lexer{ .src = src };
        while (true) {
            const t = lex.next();
            if (t.kind == .eof) break;
            if (!kwEq(t, "with")) continue;
            // optional RECURSIVE
            if (kwEq(lex.peek(), "recursive")) _ = lex.next();
            // <name> [ (cols...) ] AS ( body ) [, <name> ...]
            while (true) {
                const name = lex.next();
                if (name.kind != .ident) break;
                self.addCte(name.text);
                if (lex.peek().kind == .lparen) {
                    _ = lex.next();
                    skipBalanced(&lex);
                }
                if (!kwEq(lex.next(), "as")) break;
                if (lex.next().kind != .lparen) break;
                skipBalanced(&lex);
                if (lex.peek().kind == .comma) {
                    _ = lex.next();
                    continue;
                }
                break;
            }
        }
    }

    // -- pass B: validate tables + build alias map --------------------------
    fn checkTables(self: *Analyzer, src: []const u8) ?Finding {
        var lex = Lexer{ .src = src };
        while (true) {
            const t = lex.next();
            if (t.kind == .eof) break;
            if (kwEq(t, "from")) {
                // comma-separated table list
                while (true) {
                    if (self.parseTableRef(&lex)) |f| return f;
                    if (lex.peek().kind == .comma) {
                        _ = lex.next();
                        continue;
                    }
                    break;
                }
            } else if (kwEq(t, "join") or kwEq(t, "into")) {
                if (self.parseTableRef(&lex)) |f| return f;
            } else if (kwEq(t, "update")) {
                // SQLite allows an optional conflict clause before the table:
                // `UPDATE OR REPLACE|ROLLBACK|ABORT|FAIL|IGNORE <table> SET ...`. Skip the
                // `OR <action>` pair so the table token (not `OR`) is what gets validated.
                // Valid `UPDATE OR ...` always has a real action word after OR, so consuming both
                // tokens unconditionally cannot flag a valid statement. A quoted `"or"` table name
                // is a non-keyword token (kwEq is false for quoted idents) and is left untouched.
                if (kwEq(lex.peek(), "or")) {
                    _ = lex.next(); // OR
                    _ = lex.next(); // conflict action
                }
                if (self.parseTableRef(&lex)) |f| return f;
            }
        }
        return null;
    }

    /// Parse a single table reference at the current position. Returns a Finding for an unknown
    /// table, else null (recording the alias/table→collection mapping on the way).
    fn parseTableRef(self: *Analyzer, lex: *Lexer) ?Finding {
        const p = lex.peek();
        // FROM (subquery) — not a table.
        if (p.kind == .lparen) {
            _ = lex.next();
            skipBalanced(lex);
            self.consumeOptionalAlias(lex, null);
            return null;
        }
        // Only an identifier can be a table name; a number/operator here means "no table".
        if (p.kind != .ident) return null;
        _ = lex.next();
        var name = p.text;
        // schema-qualified `db.table` → the real table is the second part.
        if (lex.peek().kind == .dot) {
            _ = lex.next();
            const n2 = lex.next();
            if (n2.kind == .ident) name = n2.text;
        }
        if (!self.isKnownTable(name)) return .{ .unknown_table = name };
        const ci = self.collectionIndex(name);
        if (ci) |idx| self.addAlias(name, idx); // allow `table.col` without an alias
        self.consumeOptionalAlias(lex, ci);
        return null;
    }

    fn consumeOptionalAlias(self: *Analyzer, lex: *Lexer, ci: ?usize) void {
        const p = lex.peek();
        if (kwEq(p, "as")) {
            _ = lex.next();
            const a = lex.next();
            if (a.kind == .ident) {
                if (ci) |idx| self.addAlias(a.text, idx);
            }
            return;
        }
        if (p.kind == .ident and !isAliasStopword(p)) {
            _ = lex.next();
            if (ci) |idx| self.addAlias(p.text, idx);
        }
    }

    // -- pass C: validate qualified columns ---------------------------------
    fn checkColumns(self: *Analyzer, src: []const u8) ?Finding {
        var lex = Lexer{ .src = src };
        while (true) {
            const a = lex.next();
            if (a.kind == .eof) break;
            if (a.kind != .ident) continue;
            if (lex.peek().kind != .dot) continue;
            _ = lex.next(); // dot
            const b = lex.next();
            if (b.kind == .star) continue; // alias.*
            if (b.kind != .ident) continue;
            // multi-part `a.b.c` (e.g. schema.table.col) — don't flag.
            if (lex.peek().kind == .dot) continue;
            const ci = self.aliasCollection(a.text) orelse continue;
            if (self.columnValid(ci, b.text)) continue;
            return .{ .unknown_column = .{ .table = self.cols[ci].name, .column = b.text } };
        }
        return null;
    }
};

/// Analyze `sql` against `cols`. Returns the first `Finding`, or null when the checked subset is
/// clean. Pure/allocation-free so it runs identically at comptime (the wrappers below) and at
/// runtime (the tests below).
pub fn analyze(cols: []const schema.Collection, sql: []const u8, opts: SqlCheckOptions) ?Finding {
    var a = Analyzer{ .cols = cols, .opts = opts };
    a.collectCtes(sql);
    if (a.cte_overflow) return null; // fail-safe: can't trust table checks, so pass.
    if (a.checkTables(sql)) |f| return f;
    if (opts.check_columns) {
        if (a.checkColumns(sql)) |f| return f;
    }
    return null;
}

// ===========================================================================
// Comptime wrappers
// ===========================================================================

fn knownTablesMsg(comptime cols: []const schema.Collection, comptime opts: SqlCheckOptions) []const u8 {
    comptime {
        var s: []const u8 = "";
        var first = true;
        for (cols) |c| {
            if (!first) s = s ++ ", ";
            s = s ++ c.name;
            first = false;
            if (schema.hasSearchableField(c)) s = s ++ ", " ++ c.name ++ schema.fts_suffix;
        }
        if (opts.extra_tables.len > 0) {
            s = s ++ "; extra_tables: ";
            for (opts.extra_tables, 0..) |e, i| {
                if (i != 0) s = s ++ ", ";
                s = s ++ e;
            }
        }
        return s;
    }
}

fn columnsMsg(comptime cols: []const schema.Collection, comptime table: []const u8) []const u8 {
    comptime {
        const c = ident.collectionByName(cols, table) orelse return "";
        return ident.columnsList(c);
    }
}

/// Comptime-validate `sql`'s table/qualified-column identifiers against `cols`, `@compileError`ing
/// with the offending identifier and the valid options on a finding.
pub fn checkSqlOpts(comptime cols: []const schema.Collection, comptime sql: []const u8, comptime opts: SqlCheckOptions) void {
    comptime {
        @setEvalBranchQuota(200_000);
        const finding = analyze(cols, sql, opts);
        if (finding) |f| switch (f) {
            .unknown_table => |t| @compileError("checkSql: unknown table \"" ++ t ++ "\" in raw SQL (known: " ++ knownTablesMsg(cols, opts) ++ ")"),
            .unknown_column => |cc| @compileError("checkSql: column \"" ++ cc.column ++ "\" does not exist on collection \"" ++ cc.table ++ "\" (columns: " ++ columnsMsg(cols, cc.table) ++ ")"),
        };
    }
}

/// `checkSqlOpts` with default options.
pub fn checkSql(comptime cols: []const schema.Collection, comptime sql: []const u8) void {
    checkSqlOpts(cols, sql, .{});
}

/// Validate `sql` (default options) and RETURN it — the ergonomic form to wrap the string handed
/// to `queryAs`/`prepare`: `try q.queryAs(Row, checkedSql(Backend.collections, "SELECT ..."), .{})`.
pub fn checkedSql(comptime cols: []const schema.Collection, comptime sql: [:0]const u8) [:0]const u8 {
    checkSqlOpts(cols, sql, .{});
    return sql;
}

// ===========================================================================
// Tests — runtime coverage of `analyze` (the @compileError path itself cannot be an
// executable test; see the module comment and data.zig's assertFieldsExist).
// ===========================================================================

const testing = std.testing;

fn testCollections() []const schema.Collection {
    const S = struct {
        const users_fields = [_]schema.Field{
            .{ .id = "u_name", .name = "name", .options = .{ .text = .{} } },
        };
        const posts_fields = [_]schema.Field{
            .{ .id = "p_title", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "p_body", .name = "body", .searchable = true, .options = .{ .text = .{} } },
            .{ .id = "p_status", .name = "status", .options = .{ .text = .{} } },
        };
        const orders_fields = [_]schema.Field{
            .{ .id = "o_total", .name = "total", .options = .{ .number = .{} } },
            .{ .id = "o_note", .name = "note", .options = .{ .text = .{} } },
        };
        const cols = [_]schema.Collection{
            .{ .id = "users", .name = "users", .type = .auth, .fields = &users_fields },
            .{ .id = "posts", .name = "posts", .type = .base, .fields = &posts_fields },
            .{ .id = "orders", .name = "orders", .type = .base, .fields = &orders_fields },
        };
    };
    return &S.cols;
}

fn expectOk(sql: []const u8) !void {
    try testing.expect(analyze(testCollections(), sql, .{}) == null);
}
fn expectOkOpts(sql: []const u8, opts: SqlCheckOptions) !void {
    try testing.expect(analyze(testCollections(), sql, opts) == null);
}

test "positive: plain select, no false positive" {
    try expectOk("SELECT id, title FROM posts WHERE status = ?1");
}

test "positive: join with aliases" {
    try expectOk(
        "SELECT p.title, o.total FROM posts p JOIN orders o ON o.note = p.title WHERE p.status = ?1",
    );
}

test "positive: comma-separated FROM list with aliases" {
    try expectOk("SELECT p.title, o.total FROM posts p, orders o WHERE p.id = o.note");
}

test "positive: quoted identifiers for table and column" {
    try expectOk("SELECT \"posts\".\"title\" FROM \"posts\"");
    // A column literally named after a keyword, quoted, must not trigger FROM logic.
    try expectOk("SELECT * FROM posts WHERE \"from\" IS NOT NULL");
}

test "positive: CTE is a known table (plain and column-list form)" {
    try expectOk("WITH recent AS (SELECT id FROM posts) SELECT * FROM recent");
    try expectOk("WITH recent(x) AS (SELECT id FROM posts) SELECT x FROM recent");
    try expectOk("WITH RECURSIVE t AS (SELECT 1) SELECT * FROM t");
}

test "positive: subquery in FROM is not a table" {
    try expectOk("SELECT sub.n FROM (SELECT count(*) AS n FROM posts) sub");
}

test "positive: string literal containing table-ish words" {
    try expectOk("SELECT id FROM orders WHERE note = 'from orders join posts'");
    try expectOk("SELECT id FROM orders WHERE note = 'it''s from nowhere'");
}

test "positive: comments containing identifiers" {
    try expectOk("SELECT id FROM posts -- from postts join nothing\n WHERE status = ?1");
    try expectOk("SELECT id /* from ordersz */ FROM posts");
}

test "positive: alias.* and function calls" {
    try expectOk("SELECT p.* FROM posts p");
    try expectOk("SELECT count(*), max(o.total) FROM orders o");
}

test "positive: unqualified columns are never flagged" {
    try expectOk("SELECT totl, whatever, madeup FROM posts");
}

test "positive: UPDATE / INSERT INTO / DELETE FROM with valid tables" {
    try expectOk("UPDATE posts SET title = ?1 WHERE id = ?2");
    try expectOk("INSERT INTO orders (total, note) VALUES (?1, ?2)");
    try expectOk("DELETE FROM posts WHERE id = ?1");
}

test "positive: UPDATE OR <conflict-action> <table> is not flagged" {
    // The conflict clause sits between UPDATE and the table; the table (not `OR`/the action) must
    // be what gets validated. Cover every SQLite conflict action, upper- and mixed-case.
    try expectOk("UPDATE OR REPLACE posts SET title = ?1 WHERE id = ?2");
    try expectOk("UPDATE OR ROLLBACK posts SET title = ?1");
    try expectOk("UPDATE OR ABORT posts SET title = ?1");
    try expectOk("UPDATE OR FAIL posts SET title = ?1");
    try expectOk("UPDATE OR IGNORE posts SET title = ?1");
    try expectOk("update or replace posts set title = ?1"); // case-insensitive keywords
}

test "positive: ambiguous alias (same name, two collections) is not column-checked" {
    // `x` is bound to `users` in one CTE body and `orders` in another. Both tables are valid, so
    // table checking passes; `x.total` is valid on orders but NOT users. Resolving `x` to the
    // first binding would falsely flag it — instead a duplicate alias is ambiguous and skipped.
    try expectOk(
        "WITH ca AS (SELECT x.total FROM users x), cb AS (SELECT x.total FROM orders x) SELECT * FROM ca",
    );
}

test "positive: extra_tables opt-out (internal + migration-owned)" {
    try expectOkOpts("SELECT v FROM _kv WHERE k = ?1", .{ .extra_tables = &.{"_kv"} });
    try expectOkOpts(
        "INSERT INTO plugin_audit_log(note) VALUES('x')",
        .{ .extra_tables = &.{"plugin_audit_log"} },
    );
}

test "positive: <collection>_fts for a searchable collection" {
    try expectOk("SELECT rowid FROM posts_fts WHERE posts_fts MATCH ?1");
}

test "positive: auth system columns on an auth collection" {
    try expectOk("SELECT u.email, u.passwordHash, u.verified, u.token_epoch FROM users u");
    try expectOk("SELECT u.id, u.created, u.name FROM users u");
}

test "positive: check_columns=false skips column validation" {
    try expectOkOpts("SELECT o.totl FROM orders o", .{ .check_columns = false });
}

// -- NEGATIVE ---------------------------------------------------------------

fn expectUnknownTable(sql: []const u8, name: []const u8) !void {
    const f = analyze(testCollections(), sql, .{}) orelse return error.ExpectedFinding;
    try testing.expect(f == .unknown_table);
    try testing.expectEqualStrings(name, f.unknown_table);
}

fn expectUnknownColumn(sql: []const u8, table: []const u8, column: []const u8) !void {
    const f = analyze(testCollections(), sql, .{}) orelse return error.ExpectedFinding;
    try testing.expect(f == .unknown_column);
    try testing.expectEqualStrings(table, f.unknown_column.table);
    try testing.expectEqualStrings(column, f.unknown_column.column);
}

test "negative: unknown table after FROM" {
    try expectUnknownTable("SELECT * FROM postts", "postts");
}

test "negative: unknown table after JOIN" {
    try expectUnknownTable("SELECT * FROM posts p JOIN commentts c ON c.x = p.id", "commentts");
}

test "negative: unknown table after INSERT INTO" {
    try expectUnknownTable("INSERT INTO postts (title) VALUES (?1)", "postts");
}

test "negative: unknown table after UPDATE" {
    try expectUnknownTable("UPDATE postts SET title = ?1", "postts");
}

test "negative: UPDATE OR <action> still flags a bad table" {
    // Skipping the conflict clause must not skip validating the table after it.
    try expectUnknownTable("UPDATE OR REPLACE nonexistent SET title = ?1", "nonexistent");
}

test "negative: unknown table after DELETE FROM" {
    try expectUnknownTable("DELETE FROM postts WHERE id = ?1", "postts");
}

test "negative: extra_tables covers only what is listed" {
    try expectUnknownTable("SELECT * FROM _kv", "_kv"); // no extra_tables → flagged
}

test "negative: qualified column that doesn't exist on a resolved table" {
    try expectUnknownColumn("SELECT o.totl FROM orders o", "orders", "totl");
}

test "negative: qualified column via table name (no alias)" {
    try expectUnknownColumn("SELECT orders.nope FROM orders", "orders", "nope");
}

test "negative: auth collection rejects a non-existent qualified column" {
    try expectUnknownColumn("SELECT u.emial FROM users u", "users", "emial");
}
