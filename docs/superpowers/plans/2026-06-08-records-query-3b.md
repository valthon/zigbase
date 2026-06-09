# ZigBase SP3 Plan 3b: Query & List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A record list endpoint with a filter language (relation-path joins), sort, pagination, and nested relation `expand`, all compiled to parameterized SQL.

**Architecture:** A small query package: `params` (query-string parsing), `lexer`/`parser` (filter → AST), `compiler` (AST + a `Joiner` for relation-path `LEFT JOIN`s → parameterized SQL WHERE + bound params), `sort` (reuses the `Joiner`); `records.list` assembles FROM/JOIN/WHERE/ORDER/LIMIT/OFFSET + a COUNT; `expand` recursively nests related records. Every literal is bound; every identifier comes from validated schema. Builds on Plan 3a (merged conceptually; same `records` branch).

**Tech Stack:** Zig 0.16.0 (mise), the 3a record engine (`records`, `values`, `schema`, `collections`, `ddl.quoteIdent`), `std.json`.

---

## Toolchain (read once)
Run zig via the pinned toolchain from repo root: `mise exec zig@0.16.0 -- zig <args>`. Do NOT use `mise -C`. Built on branch `records` (3a done; ~69 tests pass).

## Verified facts (grounding)
- `std.Uri.percentDecodeInPlace(buf) []u8` decodes `%XX` in place. `std.fmt.parseInt(u32, s, 10)`.
- `std.ArrayList(T)` unmanaged (`.empty`, `append(alloc,v)`, `appendSlice(alloc,s)`, `toOwnedSlice(alloc)`); `std.mem.splitScalar(u8,s,c)` / `std.mem.tokenizeScalar`.
- 3a provides: `records.get(alloc,*db.Db,col,id) !?Value`, `records.columnList`/`rowToObject` (private — this plan adds a base-qualified variant), `values.decimalToScaledInt(s,scale)`, `schema.fieldByName(col,name) ?Field`, `schema.Field{options,...}`, `schema.Field.fieldType()`/`.isMultiValue()`, `collections.get(alloc,*db.Db,idOrName) !?schema.Collection`, `ddl.quoteIdent(alloc,name) ![]u8`, `db.Stmt.bindText/bindInt/bindDouble/columnInt`, `db.Db.prepare`.
- 3a record JSON shape: `{id,created,updated,<fields>}`; relation fields hold an id string (single) or JSON array of ids (multi).

## File Structure
| File | Responsibility |
|---|---|
| `src/query/params.zig` | parse a raw query string into key→value (percent-decoded) |
| `src/query/lexer.zig` | tokenize a filter string |
| `src/query/parser.zig` | tokens → filter AST |
| `src/query/joiner.zig` | resolve dotted relation paths → column refs + `LEFT JOIN`s |
| `src/query/compiler.zig` | filter AST + Joiner → parameterized WHERE + params |
| `src/query/sort.zig` | sort string + Joiner → `ORDER BY` fragment |
| `src/query/expand.zig` | nested relation expansion into `record.expand` |
| `src/records.zig` (modify) | `list(...)` assembling the full query + COUNT; base-qualified column helpers |
| `src/api/records.zig` (modify) | `list` handler: parse params, run list, expand, fields projection |
| `src/server.zig` (modify) | register `GET /api/collections/:col/records` |
| `src/main.zig` (modify) | test aggregator |

---

## Task 1: `query/params.zig` — query-string parsing

**Files:** Create `src/query/params.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Write tests + implementation** in `src/query/params.zig`:

```zig
const std = @import("std");

pub const Params = struct {
    pairs: []const Pair,
    pub const Pair = struct { key: []const u8, value: []const u8 };

    pub fn get(self: Params, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }
};

/// Parse a raw URL query string ("a=1&b=hello%20world") into decoded key/value pairs.
/// '+' is treated as space; '%XX' is percent-decoded. Values are owned by `alloc`.
pub fn parse(alloc: std.mem.Allocator, query: []const u8) !Params {
    var list: std.ArrayList(Params.Pair) = .empty;
    errdefer list.deinit(alloc);
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, seg, '=');
        const raw_key = if (eq) |i| seg[0..i] else seg;
        const raw_val = if (eq) |i| seg[i + 1 ..] else "";
        try list.append(alloc, .{ .key = try decode(alloc, raw_key), .value = try decode(alloc, raw_val) });
    }
    return .{ .pairs = try list.toOwnedSlice(alloc) };
}

fn decode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = if (c == '+') ' ' else c;
    return std.Uri.percentDecodeInPlace(buf);
}

test "parse decodes pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "filter=name%3D%22x%22&page=2&q=a+b");
    try std.testing.expectEqualStrings("name=\"x\"", p.get("filter").?);
    try std.testing.expectEqualStrings("2", p.get("page").?);
    try std.testing.expectEqualStrings("a b", p.get("q").?);
    try std.testing.expect(p.get("missing") == null);
}
```

- [ ] **Step 2: Aggregate** — add `_ = @import("query/params.zig");` to `src/main.zig`'s `test {}`. Run `mise exec zig@0.16.0 -- zig build test` (expect +1). If `percentDecodeInPlace`'s return/signature differs, adjust minimally. Commit:
```bash
git add src/query/params.zig src/main.zig
git commit -m "feat(query): query-string parsing with percent-decode"
```

---

## Task 2: `query/lexer.zig` — filter tokenizer

**Files:** Create `src/query/lexer.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Write tests + implementation** in `src/query/lexer.zig`:

```zig
const std = @import("std");

pub const TokKind = enum { ident, string, number, eq, ne, gt, ge, lt, le, like, nlike, l_and, l_or, lparen, rparen, eof };
pub const Token = struct { kind: TokKind, text: []const u8 };
pub const LexError = error{ UnexpectedChar, UnterminatedString } || std.mem.Allocator.Error;

/// Tokenize a filter expression. Identifiers may contain '.' (relation paths).
/// Strings are single- or double-quoted; numbers are -?digits(.digits)?.
pub fn lex(alloc: std.mem.Allocator, input: []const u8) LexError![]Token {
    var toks: std.ArrayList(Token) = .empty;
    errdefer toks.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') { i += 1; continue; }
        switch (c) {
            '(' => { try toks.append(alloc, .{ .kind = .lparen, .text = "(" }); i += 1; },
            ')' => { try toks.append(alloc, .{ .kind = .rparen, .text = ")" }); i += 1; },
            '=' => { try toks.append(alloc, .{ .kind = .eq, .text = "=" }); i += 1; },
            '~' => { try toks.append(alloc, .{ .kind = .like, .text = "~" }); i += 1; },
            '>' => { if (i + 1 < input.len and input[i + 1] == '=') { try toks.append(alloc, .{ .kind = .ge, .text = ">=" }); i += 2; } else { try toks.append(alloc, .{ .kind = .gt, .text = ">" }); i += 1; } },
            '<' => { if (i + 1 < input.len and input[i + 1] == '=') { try toks.append(alloc, .{ .kind = .le, .text = "<=" }); i += 2; } else { try toks.append(alloc, .{ .kind = .lt, .text = "<" }); i += 1; } },
            '!' => {
                if (i + 1 < input.len and input[i + 1] == '=') { try toks.append(alloc, .{ .kind = .ne, .text = "!=" }); i += 2; }
                else if (i + 1 < input.len and input[i + 1] == '~') { try toks.append(alloc, .{ .kind = .nlike, .text = "!~" }); i += 2; }
                else return error.UnexpectedChar;
            },
            '&' => { if (i + 1 < input.len and input[i + 1] == '&') { try toks.append(alloc, .{ .kind = .l_and, .text = "&&" }); i += 2; } else return error.UnexpectedChar; },
            '|' => { if (i + 1 < input.len and input[i + 1] == '|') { try toks.append(alloc, .{ .kind = .l_or, .text = "||" }); i += 2; } else return error.UnexpectedChar; },
            '"', '\'' => {
                const quote = c;
                const start = i + 1;
                var j = start;
                while (j < input.len and input[j] != quote) : (j += 1) {}
                if (j >= input.len) return error.UnterminatedString;
                try toks.append(alloc, .{ .kind = .string, .text = input[start..j] });
                i = j + 1;
            },
            else => {
                if (c == '-' or (c >= '0' and c <= '9')) {
                    const start = i;
                    i += 1;
                    while (i < input.len and ((input[i] >= '0' and input[i] <= '9') or input[i] == '.')) : (i += 1) {}
                    try toks.append(alloc, .{ .kind = .number, .text = input[start..i] });
                } else if (isIdentStart(c)) {
                    const start = i;
                    while (i < input.len and isIdentChar(input[i])) : (i += 1) {}
                    try toks.append(alloc, .{ .kind = .ident, .text = input[start..i] });
                } else return error.UnexpectedChar;
            },
        }
    }
    try toks.append(alloc, .{ .kind = .eof, .text = "" });
    return toks.toOwnedSlice(alloc);
}

fn isIdentStart(c: u8) bool { return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'; }
fn isIdentChar(c: u8) bool { return isIdentStart(c) or (c >= '0' and c <= '9') or c == '.'; }

test "lex a relation-path comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try lex(a, "author.name ~ \"ab\" && price >= 10.5");
    const kinds = [_]TokKind{ .ident, .like, .string, .l_and, .ident, .ge, .number, .eof };
    try std.testing.expectEqual(kinds.len, toks.len);
    for (kinds, 0..) |k, i| try std.testing.expectEqual(k, toks[i].kind);
    try std.testing.expectEqualStrings("author.name", toks[0].text);
    try std.testing.expectEqualStrings("ab", toks[2].text);
    try std.testing.expectEqualStrings("10.5", toks[6].text);
}
```

- [ ] **Step 2: Aggregate + run + commit**
```bash
git add src/query/lexer.zig src/main.zig
git commit -m "feat(query): filter lexer"
```
(add `_ = @import("query/lexer.zig");` to main's test block; run tests.)

---

## Task 3: `query/parser.zig` — tokens → AST

**Files:** Create `src/query/parser.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Write tests + implementation** in `src/query/parser.zig`:

```zig
const std = @import("std");
const lexer = @import("lexer.zig");

pub const Operand = union(enum) {
    path: []const u8,
    str: []const u8,
    num: []const u8,
    boolean: bool,
    nul,
};

pub const Node = union(enum) {
    cmp: struct { lhs: Operand, op: lexer.TokKind, rhs: Operand },
    logic: struct { op: lexer.TokKind, l: *Node, r: *Node }, // op is .l_and or .l_or
};

pub const ParseError = error{ UnexpectedToken, BadOperand, Empty } || std.mem.Allocator.Error;

const Parser = struct {
    alloc: std.mem.Allocator,
    toks: []const lexer.Token,
    pos: usize = 0,

    fn peek(self: *Parser) lexer.TokKind { return self.toks[self.pos].kind; }
    fn next(self: *Parser) lexer.Token { const t = self.toks[self.pos]; self.pos += 1; return t; }

    fn parseOr(self: *Parser) ParseError!*Node {
        var left = try self.parseAnd();
        while (self.peek() == .l_or) {
            _ = self.next();
            const right = try self.parseAnd();
            left = try self.mk(.{ .logic = .{ .op = .l_or, .l = left, .r = right } });
        }
        return left;
    }
    fn parseAnd(self: *Parser) ParseError!*Node {
        var left = try self.parsePrimary();
        while (self.peek() == .l_and) {
            _ = self.next();
            const right = try self.parsePrimary();
            left = try self.mk(.{ .logic = .{ .op = .l_and, .l = left, .r = right } });
        }
        return left;
    }
    fn parsePrimary(self: *Parser) ParseError!*Node {
        if (self.peek() == .lparen) {
            _ = self.next();
            const inner = try self.parseOr();
            if (self.peek() != .rparen) return error.UnexpectedToken;
            _ = self.next();
            return inner;
        }
        const lhs = try self.operand();
        const op = self.next().kind;
        switch (op) {
            .eq, .ne, .gt, .ge, .lt, .le, .like, .nlike => {},
            else => return error.UnexpectedToken,
        }
        const rhs = try self.operand();
        return self.mk(.{ .cmp = .{ .lhs = lhs, .op = op, .rhs = rhs } });
    }
    fn operand(self: *Parser) ParseError!Operand {
        const t = self.next();
        return switch (t.kind) {
            .string => .{ .str = t.text },
            .number => .{ .num = t.text },
            .ident => if (std.mem.eql(u8, t.text, "true")) .{ .boolean = true } else if (std.mem.eql(u8, t.text, "false")) .{ .boolean = false } else if (std.mem.eql(u8, t.text, "null")) .nul else .{ .path = t.text },
            else => error.BadOperand,
        };
    }
    fn mk(self: *Parser, n: Node) !*Node {
        const p = try self.alloc.create(Node);
        p.* = n;
        return p;
    }
};

pub fn parse(alloc: std.mem.Allocator, toks: []const lexer.Token) ParseError!*Node {
    if (toks.len == 0 or toks[0].kind == .eof) return error.Empty;
    var p = Parser{ .alloc = alloc, .toks = toks };
    const node = try p.parseOr();
    if (p.peek() != .eof) return error.UnexpectedToken;
    return node;
}

test "parse precedence: a = 1 && b = 2 || c = 3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try lexer.lex(a, "a = 1 && b = 2 || c = 3");
    const root = try parse(a, toks);
    // top is OR; left is (a=1 && b=2), right is c=3
    try std.testing.expectEqual(lexer.TokKind.l_or, root.logic.op);
    try std.testing.expectEqual(lexer.TokKind.l_and, root.logic.l.logic.op);
    try std.testing.expectEqualStrings("c", root.logic.r.cmp.lhs.path);
}

test "parse a parenthesized relation comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try lexer.lex(a, "(author.name = \"x\")");
    const root = try parse(a, toks);
    try std.testing.expectEqualStrings("author.name", root.cmp.lhs.path);
    try std.testing.expectEqualStrings("x", root.cmp.rhs.str);
}
```

- [ ] **Step 2: Aggregate + run + commit**
```bash
git add src/query/parser.zig src/main.zig
git commit -m "feat(query): filter parser (recursive descent, precedence)"
```

---

## Task 4: `query/joiner.zig` + `query/compiler.zig` — paths → SQL

**Files:** Create `src/query/joiner.zig`, `src/query/compiler.zig`; Modify `src/main.zig`.

This is the crux. The `Joiner` resolves a dotted path to a SQL column reference, emitting `LEFT JOIN`s for relation segments (de-duplicated by path prefix). The compiler walks the AST, emits parameterized SQL, and binds literals converted to the resolved column's type.

- [ ] **Step 1: `src/query/joiner.zig`** — write this:

```zig
const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const ddl = @import("../ddl.zig");

pub const JoinError = error{ UnknownField, NotARelation, MultiRelationTraversal } || db.DbError || std.mem.Allocator.Error || @typeInfo(@typeInfo(@TypeOf(collections.get)).@"fn".return_type.?).error_union.error_set;

pub const ColumnRef = struct { sql: []const u8, field: ?schema.Field };

/// Builds LEFT JOINs for relation-path traversal and resolves a dotted path to a column ref.
pub const Joiner = struct {
    alloc: std.mem.Allocator,
    conn: *db.Db,
    base: schema.Collection,
    joins: std.ArrayList([]const u8) = .empty,
    // dedup: each entry maps a resolved path-prefix to its alias + target collection
    seen: std.ArrayList(Seen) = .empty,
    counter: usize = 0,

    const Seen = struct { prefix: []const u8, alias: []const u8, col: schema.Collection };

    pub fn init(alloc: std.mem.Allocator, conn: *db.Db, base: schema.Collection) Joiner {
        return .{ .alloc = alloc, .conn = conn, .base = base };
    }

    /// Resolve "a.b.c": non-final segments must be single-value relations; final is a column.
    pub fn resolve(self: *Joiner, path: []const u8) JoinError!ColumnRef {
        var cur_col = self.base;
        var cur_alias = try std.fmt.allocPrint(self.alloc, "\"{s}\"", .{self.base.name}); // base table ref
        var prefix_buf: std.ArrayList(u8) = .empty;

        var it = std.mem.splitScalar(u8, path, '.');
        var seg = it.next().?;
        while (true) {
            const nxt = it.next();
            if (nxt == null) {
                // final segment: a column on cur_col (or a system column id/created/updated)
                const field = schema.fieldByName(cur_col, seg);
                if (field == null and !isSystemCol(seg)) return error.UnknownField;
                const ref = try std.fmt.allocPrint(self.alloc, "{s}.\"{s}\"", .{ cur_alias, seg });
                return .{ .sql = ref, .field = field };
            }
            // non-final: seg must be a single-value relation on cur_col
            const rf = schema.fieldByName(cur_col, seg) orelse return error.UnknownField;
            if (rf.fieldType() != .relation) return error.NotARelation;
            if (rf.isMultiValue()) return error.MultiRelationTraversal;
            // grow the prefix and reuse an existing join if present
            if (prefix_buf.items.len > 0) try prefix_buf.append(self.alloc, '.');
            try prefix_buf.appendSlice(self.alloc, seg);
            const prefix = prefix_buf.items;
            if (self.find(prefix)) |s| {
                cur_alias = try self.alloc.dupe(u8, s.alias);
                cur_col = s.col;
            } else {
                const target = (try collections.get(self.alloc, self.conn, rf.options.relation.targetCollectionId)) orelse return error.UnknownField;
                self.counter += 1;
                const alias = try std.fmt.allocPrint(self.alloc, "j{d}", .{self.counter});
                const join = try std.fmt.allocPrint(self.alloc, "LEFT JOIN \"{s}\" AS {s} ON {s}.\"{s}\" = {s}.\"id\"", .{ target.name, alias, cur_alias, seg, alias });
                try self.joins.append(self.alloc, join);
                try self.seen.append(self.alloc, .{ .prefix = try self.alloc.dupe(u8, prefix), .alias = alias, .col = target });
                cur_alias = alias;
                cur_col = target;
            }
            seg = nxt.?;
        }
    }

    fn find(self: *Joiner, prefix: []const u8) ?Seen {
        for (self.seen.items) |s| { if (std.mem.eql(u8, s.prefix, prefix)) return s; }
        return null;
    }
};

fn isSystemCol(s: []const u8) bool {
    return std.mem.eql(u8, s, "id") or std.mem.eql(u8, s, "created") or std.mem.eql(u8, s, "updated");
}
```

- [ ] **Step 2: `src/query/compiler.zig`** — write the compiler with its test table. The tests build real collections (so `Joiner` can resolve relations) and assert the WHERE SQL + params.

```zig
const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const joiner = @import("joiner.zig");
const values = @import("../values.zig");

pub const Param = union(enum) { text: []const u8, int: i64, double: f64 };
pub const CompileError = error{ BadFilter, BadValue } || joiner.JoinError || values.ValueError;

pub const Compiled = struct { where_sql: []const u8, params: []const Param };

/// Compile a filter AST into a parameterized WHERE fragment, accumulating joins into `j`.
pub fn compile(alloc: std.mem.Allocator, j: *joiner.Joiner, node: *parser.Node) CompileError!Compiled {
    var params: std.ArrayList(Param) = .empty;
    const sql = try emit(alloc, j, node, &params);
    return .{ .where_sql = sql, .params = try params.toOwnedSlice(alloc) };
}

fn emit(alloc: std.mem.Allocator, j: *joiner.Joiner, node: *parser.Node, params: *std.ArrayList(Param)) CompileError![]u8 {
    switch (node.*) {
        .logic => |lg| {
            const l = try emit(alloc, j, lg.l, params);
            const r = try emit(alloc, j, lg.r, params);
            const conj = if (lg.op == .l_and) "AND" else "OR";
            return std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ l, conj, r });
        },
        .cmp => |c| return emitCmp(alloc, j, c, params),
    }
}

const sql_op = std.StaticStringMap([]const u8); // not needed; use a switch below

fn opSql(op: lexer.TokKind) []const u8 {
    return switch (op) {
        .eq => "=", .ne => "!=", .gt => ">", .ge => ">=", .lt => "<", .le => "<=",
        .like => "LIKE", .nlike => "NOT LIKE", else => "=",
    };
}

fn emitCmp(alloc: std.mem.Allocator, j: *joiner.Joiner, c: anytype, params: *std.ArrayList(Param)) CompileError![]u8 {
    // Resolve which side is a path. Support: path OP literal, literal OP path, path OP path.
    const lhs_path = (c.lhs == .path);
    const rhs_path = (c.rhs == .path);
    if (lhs_path and rhs_path) {
        const lc = try j.resolve(c.lhs.path);
        const rc = try j.resolve(c.rhs.path);
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ lc.sql, opSql(c.op), rc.sql });
    }
    const col_operand = if (lhs_path) c.lhs else c.rhs;
    const lit_operand = if (lhs_path) c.rhs else c.lhs;
    if (col_operand != .path) return error.BadFilter; // both literals: unsupported
    const col = try j.resolve(col_operand.path);

    // LIKE wraps the literal with %...%; require a text-ish column (no field or text-family)
    if (c.op == .like or c.op == .nlike) {
        const term = try literalToText(alloc, lit_operand);
        try params.append(alloc, .{ .text = try std.fmt.allocPrint(alloc, "%{s}%", .{term}) });
        return std.fmt.allocPrint(alloc, "{s} {s} ?", .{ col.sql, opSql(c.op) });
    }

    try params.append(alloc, try literalToParam(alloc, col.field, lit_operand));
    // keep operand order stable for non-commutative ops
    if (lhs_path) return std.fmt.allocPrint(alloc, "{s} {s} ?", .{ col.sql, opSql(c.op) });
    return std.fmt.allocPrint(alloc, "? {s} {s}", .{ opSql(c.op), col.sql });
}

fn literalToText(alloc: std.mem.Allocator, op: parser.Operand) ![]const u8 {
    return switch (op) {
        .str => op.str,
        .num => op.num,
        .boolean => |b| if (b) "true" else "false",
        .nul => "",
        .path => error.BadFilter,
    };
}

fn literalToParam(alloc: std.mem.Allocator, field: ?schema.Field, op: parser.Operand) CompileError!Param {
    // Convert per the resolved column's field type.
    if (field) |f| switch (f.options) {
        .number => |o| switch (o.mode) {
            .float => if (op == .num) return .{ .double = std.fmt.parseFloat(f64, op.num) catch return error.BadValue } else return error.BadValue,
            .int => if (op == .num) return .{ .int = try values.decimalToScaledInt(op.num, 0) } else return error.BadValue,
            .fixed => if (op == .num) return .{ .int = try values.decimalToScaledInt(op.num, o.scale orelse 0) } else return error.BadValue,
        },
        .@"bool" => if (op == .boolean) return .{ .int = if (op.boolean) 1 else 0 } else return error.BadValue,
        else => {},
    };
    // default: bind as text (system columns id/created/updated, text fields, etc.)
    return switch (op) {
        .str => .{ .text = op.str },
        .num => .{ .text = op.num },
        .boolean => |b| .{ .text = if (b) "true" else "false" },
        .nul => .{ .text = "" },
        .path => error.BadFilter,
    };
}

// ---- tests ----
fn setup(d: *db.Db, a: std.mem.Allocator) !struct { posts: schema.Collection } {
    const migrations = @import("../migrations.zig");
    const collections = @import("../collections.zig");
    try migrations.run(d);
    const users = try collections.create(a, std.testing.io, d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }} });
    const pf = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
        .{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } },
    };
    const posts = try collections.create(a, std.testing.io, d, .{ .id = "", .name = "posts", .fields = &pf });
    return .{ .posts = posts };
}

fn compileFilter(a: std.mem.Allocator, d: *db.Db, posts: schema.Collection, filter: []const u8) !struct { c: Compiled, j: joiner.Joiner } {
    const toks = try lexer.lex(a, filter);
    const ast = try parser.parse(a, toks);
    var j = joiner.Joiner.init(a, d, posts);
    const c = try compile(a, &j, ast);
    return .{ .c = c, .j = j };
}

test "compile text equality binds the literal" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try setup(&d, a);
    const r = try compileFilter(a, &d, s.posts, "title = \"hi\"");
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", r.c.where_sql);
    try std.testing.expectEqual(@as(usize, 1), r.c.params.len);
    try std.testing.expectEqualStrings("hi", r.c.params[0].text);
}

test "compile fixed comparison scales the numeric literal to an int param" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try setup(&d, a);
    const r = try compileFilter(a, &d, s.posts, "price >= 10.50");
    try std.testing.expectEqualStrings("\"posts\".\"price\" >= ?", r.c.where_sql);
    try std.testing.expectEqual(@as(i64, 1050), r.c.params[0].int);
}

test "compile LIKE wraps the term in percents" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try setup(&d, a);
    const r = try compileFilter(a, &d, s.posts, "title ~ \"ab\"");
    try std.testing.expectEqualStrings("\"posts\".\"title\" LIKE ?", r.c.where_sql);
    try std.testing.expectEqualStrings("%ab%", r.c.params[0].text);
}

test "compile a relation-path filter emits a join and uses the alias" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try setup(&d, a);
    const r = try compileFilter(a, &d, s.posts, "author.name = \"x\"");
    try std.testing.expectEqual(@as(usize, 1), r.j.joins.items.len);
    try std.testing.expect(std.mem.indexOf(u8, r.j.joins.items[0], "LEFT JOIN \"users\" AS j1 ON \"posts\".\"author\" = j1.\"id\"") != null);
    try std.testing.expectEqualStrings("j1.\"name\" = ?", r.c.where_sql);
    try std.testing.expectEqualStrings("x", r.c.params[0].text);
}

test "compile an injection-y literal stays a bound param" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try setup(&d, a);
    const r = try compileFilter(a, &d, s.posts, "title = \"x\\\" OR \\\"1\\\"=\\\"1\"");
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", r.c.where_sql);
    // the dangerous text is the bound param, not interpolated SQL
    try std.testing.expect(std.mem.indexOf(u8, r.c.params[0].text, "OR") != null);
}

test "compile logical grouping" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try setup(&d, a);
    const r = try compileFilter(a, &d, s.posts, "title = \"a\" && price > 1.00");
    try std.testing.expectEqualStrings("(\"posts\".\"title\" = ? AND \"posts\".\"price\" > ?)", r.c.where_sql);
    try std.testing.expectEqual(@as(usize, 2), r.c.params.len);
}
```

Implementation guidance: the `emitCmp` parameter `c: anytype` is the `cmp` payload struct from `parser.Node` — give it the concrete type if you prefer (`@TypeOf(node.cmp)`). The lexer string-escape test uses Zig escapes for the embedded quotes; the lexer currently does NOT process backslash escapes inside strings (it scans to the next quote) — for the injection test the important property is that whatever text lands in the param is bound, not interpolated. If exact escape handling matters, keep it simple: the lexer treats the string body verbatim. Adjust the injection test's expectation to match the lexer's verbatim slice if needed (the security property — bound not interpolated — is what must hold).

- [ ] **Step 3: Aggregate + run + commit**
```bash
git add src/query/joiner.zig src/query/compiler.zig src/main.zig
git commit -m "feat(query): relation-path joiner + filter compiler (parameterized)"
```

---

## Task 5: `query/sort.zig` — ORDER BY

**Files:** Create `src/query/sort.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Write tests + implementation** in `src/query/sort.zig`:

```zig
const std = @import("std");
const joiner = @import("joiner.zig");

pub const SortError = error{ BadSort } || joiner.JoinError;

/// Compile a comma-separated sort spec ("-created,author.name") into an ORDER BY fragment
/// (without the "ORDER BY" keywords), resolving relation paths via `j`. Empty -> "".
pub fn compile(alloc: std.mem.Allocator, j: *joiner.Joiner, spec: []const u8) SortError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, spec, ',');
    var first = true;
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, " ");
        if (term.len == 0) continue;
        const desc = term[0] == '-';
        const path = if (desc or term[0] == '+') term[1..] else term;
        if (path.len == 0) return error.BadSort;
        const col = try j.resolve(path);
        if (!first) try out.appendSlice(alloc, ", ");
        first = false;
        try out.appendSlice(alloc, col.sql);
        try out.appendSlice(alloc, if (desc) " DESC" else " ASC");
    }
    return out.toOwnedSlice(alloc);
}

test "sort compiles direction and relation paths" {
    const db = @import("../db.zig");
    const schema = @import("../schema.zig");
    const migrations = @import("../migrations.zig");
    const collections = @import("../collections.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }} });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });
    var j = joiner.Joiner.init(a, &d, posts);
    const ob = try compile(a, &j, "-created,author.name");
    try std.testing.expectEqualStrings("\"posts\".\"created\" DESC, j1.\"name\" ASC", ob);
}
```

- [ ] **Step 2: Aggregate + run + commit**
```bash
git add src/query/sort.zig src/main.zig
git commit -m "feat(query): sort compiler"
```

---

## Task 6: `records.list` — assemble the list query + pagination

**Files:** Modify `src/records.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Write tests first** in `src/records.zig`:

```zig
const compiler = @import("query/compiler.zig");
const lexer = @import("query/lexer.zig");
const parser = @import("query/parser.zig");
const joiner = @import("query/joiner.zig");
const sort = @import("query/sort.zig");

test "list filters, sorts, and paginates" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a); // posts(title text, price fixed/2)
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','2026-01-01T00:00:00Z','t','aaa',100),('r2','2026-01-02T00:00:00Z','t','bbb',200),('r3','2026-01-03T00:00:00Z','t','ccc',300);");

    const res = try list(a, &d, col, .{ .filter = "price >= 2.00", .sort = "-created", .page = 1, .perPage = 1 });
    try std.testing.expectEqual(@as(i64, 2), res.totalItems); // r2,r3 match
    try std.testing.expectEqual(@as(usize, 1), res.items.len); // perPage 1
    try std.testing.expectEqualStrings("r3", res.items[0].object.get("id").?.string); // -created => newest first
}
```

- [ ] **Step 2: Implement `list` + `ListResult`/`ListQuery` + base-qualified column helpers** in `src/records.zig`:

```zig
pub const ListQuery = struct { filter: ?[]const u8 = null, sort: ?[]const u8 = null, page: u32 = 1, perPage: u32 = 30 };
pub const ListResult = struct { page: u32, perPage: u32, totalItems: i64, items: []std.json.Value };

/// Base-qualified, comma-joined select list: "base"."id","base"."created",... so it is
/// unambiguous when joins are present. Reads map 1:1 with rowToObject's index order.
fn baseColumnList(alloc: std.mem.Allocator, col: schema.Collection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"{s}\".\"id\",\"{s}\".\"created\",\"{s}\".\"updated\"", .{ col.name, col.name, col.name }));
    for (col.fields) |f| {
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ",\"{s}\".{s}", .{ col.name, try ddl.quoteIdent(alloc, f.name) }));
    }
    return out.toOwnedSlice(alloc);
}

pub fn list(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, q: ListQuery) !ListResult {
    var j = joiner.Joiner.init(alloc, conn, col);
    // WHERE
    var where_sql: []const u8 = "";
    var params: []const compiler.Param = &.{};
    if (q.filter) |fstr| if (fstr.len > 0) {
        const toks = try lexer.lex(alloc, fstr);
        const ast = try parser.parse(alloc, toks);
        const compiled = try compiler.compile(alloc, &j, ast);
        where_sql = compiled.where_sql;
        params = compiled.params;
    };
    // ORDER BY (default: created DESC)
    var order_sql: []const u8 = try std.fmt.allocPrint(alloc, "\"{s}\".\"created\" DESC", .{col.name});
    if (q.sort) |sstr| if (sstr.len > 0) {
        const ob = try sort.compile(alloc, &j, sstr);
        if (ob.len > 0) order_sql = ob;
    };
    // JOINs
    var joins_sql: std.ArrayList(u8) = .empty;
    for (j.joins.items) |jn| { try joins_sql.append(alloc, ' '); try joins_sql.appendSlice(alloc, jn); }

    const where_clause = if (where_sql.len > 0) try std.fmt.allocPrint(alloc, " WHERE {s}", .{where_sql}) else "";

    // COUNT
    const count_sql = try std.fmt.allocPrintSentinel(alloc, "SELECT COUNT(*) FROM \"{s}\"{s}{s};", .{ col.name, joins_sql.items, where_clause }, 0);
    var cst = try conn.prepare(count_sql);
    defer cst.finalize();
    try bindParams(&cst, params, 1);
    _ = try cst.step();
    const total = cst.columnInt(0);

    // PAGE
    const per: u32 = if (q.perPage == 0) 30 else @min(q.perPage, 500);
    const page: u32 = if (q.page == 0) 1 else q.page;
    const offset: i64 = @as(i64, (page - 1)) * @as(i64, per);
    const bcols = try baseColumnList(alloc, col);
    const page_sql = try std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM \"{s}\"{s}{s} ORDER BY {s} LIMIT ? OFFSET ?;", .{ bcols, col.name, joins_sql.items, where_clause, order_sql }, 0);
    var pst = try conn.prepare(page_sql);
    defer pst.finalize();
    const after = try bindParams(&pst, params, 1);
    try pst.bindInt(after, @intCast(per));
    try pst.bindInt(after + 1, offset);

    var items: std.ArrayList(std.json.Value) = .empty;
    while (try pst.step()) try items.append(alloc, try rowToObject(alloc, &pst, col));
    return .{ .page = page, .perPage = per, .totalItems = total, .items = try items.toOwnedSlice(alloc) };
}

/// Bind filter params starting at 1-based `start`; returns the next free index.
fn bindParams(st: *db.Stmt, params: []const compiler.Param, start: c_int) !c_int {
    var idx = start;
    for (params) |p| {
        switch (p) {
            .text => |t| try st.bindText(idx, t),
            .int => |n| try st.bindInt(idx, n),
            .double => |dv| try st.bindDouble(idx, dv),
        }
        idx += 1;
    }
    return idx;
}
```
Note: `list`'s error set is inferred (`!ListResult`) — it unions lexer/parser/compiler/joiner/db/json errors. If a caller needs a named set, widen via reflection as elsewhere. `rowToObject` reads columns by index 0..n which matches `baseColumnList`'s order.

- [ ] **Step 3: Aggregate** (records.zig already imported) — run `mise exec zig@0.16.0 -- zig build test`. Expect PASS. Commit:
```bash
git add src/records.zig src/main.zig
git commit -m "feat(records): list with filter, sort, and pagination"
```

---

## Task 7: `query/expand.zig` — nested relation expansion

**Files:** Create `src/query/expand.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Write tests first** in `src/query/expand.zig`:

```zig
const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const migrations = @import("../migrations.zig");

test "expand nests a single relation under record.expand" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }} });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });
    try d.exec("INSERT INTO users (id,created,updated,name) VALUES ('u_1','t','t','Ada');");
    try d.exec("INSERT INTO posts (id,created,updated,author) VALUES ('p_1','t','t','u_1');");

    var rec = (try records.get(a, &d, posts, "p_1")).?;
    try expand(a, &d, posts, &rec, "author", 0);
    const exp = rec.object.get("expand").?.object;
    try std.testing.expectEqualStrings("Ada", exp.get("author").?.object.get("name").?.string);
}
```

- [ ] **Step 2: Implement `expand`** in `src/query/expand.zig`. Structure (make the test pass; nested sub-paths recurse):

```zig
const ddl = @import("../ddl.zig");

const max_depth = 6;

/// Expand the given expand-spec ("author,tags.owner") into `rec.object`'s "expand" key.
/// `rec` must be a `.object`. Single relations nest an object; multi nest an array.
pub fn expand(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, rec: *std.json.Value, spec: []const u8, depth: usize) !void {
    if (depth >= max_depth or rec.* != .object) return;
    // group spec into top-level keys with optional remainder: "a.b,a.c,d" -> a:[b,c], d:[]
    var it = std.mem.splitScalar(u8, spec, ',');
    var expand_obj: std.json.ObjectMap = .empty;
    var any = false;
    while (it.next()) |raw| {
        const path = std.mem.trim(u8, raw, " ");
        if (path.len == 0) continue;
        const dot = std.mem.indexOfScalar(u8, path, '.');
        const head = if (dot) |i| path[0..i] else path;
        const rest = if (dot) |i| path[i + 1 ..] else "";
        const field = schema.fieldByName(col, head) orelse continue;
        if (field.fieldType() != .relation) continue;
        const target = (try collections.get(alloc, conn, field.options.relation.targetCollectionId)) orelse continue;
        const id_val = rec.object.get(head) orelse continue;
        const nested = try expandField(alloc, conn, target, id_val, rest, depth);
        try expand_obj.put(alloc, head, nested);
        any = true;
    }
    if (any) try rec.object.put(alloc, "expand", .{ .object = expand_obj });
}

/// Fetch the related record(s) for a relation value (id string or array of ids), recursing `rest`.
fn expandField(alloc: std.mem.Allocator, conn: *db.Db, target: schema.Collection, id_val: std.json.Value, rest: []const u8, depth: usize) !std.json.Value {
    switch (id_val) {
        .string => |id| {
            var sub = (try records.get(alloc, conn, target, id)) orelse return .null;
            if (rest.len > 0) try expand(alloc, conn, target, &sub, rest, depth + 1);
            return sub;
        },
        .array => |arr| {
            var out = std.json.Array.init(alloc);
            for (arr.items) |it| if (it == .string) {
                var sub = (try records.get(alloc, conn, target, it.string)) orelse continue;
                if (rest.len > 0) try expand(alloc, conn, target, &sub, rest, depth + 1);
                try out.append(sub);
            };
            return .{ .array = out };
        },
        else => return .null,
    }
}
```
Note: `records.get` is imported — `query/expand.zig` depends on `records.zig`, and `records.zig` imports `query/*` for `list`. That's a cycle between `records` and `query/expand`. Avoid it: `expand` is only used by the `api/records.zig` handler, so put `expand` OUTSIDE the `records`↔`query` dependency by having the handler call `expand.expand(...)` with `records.get` passed in, OR keep `expand` importing `records` and ensure `records.zig` does NOT import `query/expand.zig` (it imports compiler/lexer/parser/joiner/sort, not expand). Since `records.list` does not need `expand`, there is no cycle as long as `records.zig` never imports `query/expand.zig`. Confirm this import boundary holds.

- [ ] **Step 3: Aggregate + run + commit**
```bash
git add src/query/expand.zig src/main.zig
git commit -m "feat(query): nested relation expand"
```

---

## Task 8: list handler + fields projection + route + smoke

**Files:** Modify `src/api/records.zig`, `src/server.zig`, `src/main.zig`.

- [ ] **Step 1: Write a handler test first** in `src/api/records.zig` (extend the existing TestEnv; seed a couple records):

```zig
test "list handler returns the page envelope" {
    var env = try TestEnv.init();
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col_param = [_]http.Param{.{ .key = "col", .value = "posts" }};
    // create two records via the handler
    var c1 = ctxFor(env, a, .POST, "{\"title\":\"a\"}", &col_param);
    _ = try create(&c1);
    var c2 = ctxFor(env, a, .POST, "{\"title\":\"b\"}", &col_param);
    _ = try create(&c2);

    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "perPage=1", .allocator = a, .app = &env.app, .params = &col_param };
    const res = try list(&lctx);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"totalItems\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"page\":1") != null);
}
```

- [ ] **Step 2: Implement the `list` handler** in `src/api/records.zig`:

```zig
const records_mod = @import("../records.zig"); // if not already imported as `records`
const params_mod = @import("../query/params.zig");
const expand_mod = @import("../query/expand.zig");

pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.openReader();
    defer r.close();
    const col = (try resolveCollection(ctx, &r)) orelse return ApiError.notFound().toResponse(ctx.allocator);

    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    const page = parseU32(qp.get("page"), 1);
    const perPage = parseU32(qp.get("perPage"), 30);

    const result = records.list(ctx.allocator, &r, col, .{
        .filter = qp.get("filter"),
        .sort = qp.get("sort"),
        .page = page,
        .perPage = perPage,
    }) catch |e| switch (e) {
        error.UnknownField, error.NotARelation, error.MultiRelationTraversal, error.BadFilter, error.BadSort, error.BadValue, error.UnexpectedToken, error.BadOperand, error.Empty, error.UnexpectedChar, error.UnterminatedString =>
            return ApiError.badRequest("Invalid filter or sort.").toResponse(ctx.allocator),
        else => return e,
    };

    // expand each item, if requested
    if (qp.get("expand")) |exp| if (exp.len > 0) {
        for (result.items) |*item| try expand_mod.expand(ctx.allocator, &r, col, item, exp, 0);
    };

    const total_pages = if (result.perPage == 0) 0 else @divTrunc(result.totalItems + @as(i64, result.perPage) - 1, @as(i64, result.perPage));
    var root: std.json.ObjectMap = .empty;
    try root.put(ctx.allocator, "page", .{ .integer = @intCast(result.page) });
    try root.put(ctx.allocator, "perPage", .{ .integer = @intCast(result.perPage) });
    try root.put(ctx.allocator, "totalItems", .{ .integer = result.totalItems });
    try root.put(ctx.allocator, "totalPages", .{ .integer = total_pages });
    var arr = std.json.Array.init(ctx.allocator);
    for (result.items) |it| try arr.append(it);
    try root.put(ctx.allocator, "items", .{ .array = arr });
    return jsonResponse(ctx, 200, .{ .object = root });
}

fn parseU32(s: ?[]const u8, default: u32) u32 {
    const v = s orelse return default;
    return std.fmt.parseInt(u32, v, 10) catch default;
}
```
(Use whatever local import name `records` already has in this file; if it's `records`, drop the `records_mod` alias. The `catch` switch lists the filter/sort error variants → 400; everything else propagates to the 500 fallback.)

- [ ] **Step 3: Register the list route in `src/server.zig`** — add to `routes`:
```zig
    .{ .method = .GET, .pattern = "/api/collections/:col/records", .handler = records_api.list },
```

- [ ] **Step 4: Aggregate + build + unit tests** — `mise exec zig@0.16.0 -- zig build && mise exec zig@0.16.0 -- zig build test`. Expect clean build + all tests pass.

- [ ] **Step 5: Manual smoke (filter on a relation path + nested expand + pagination).**
```bash
rm -rf ./zb_data
mise exec zig@0.16.0 -- zig build
./zig-out/bin/zigbase serve --http-port 8090 --data-dir ./zb_data >/tmp/zb_3b.log 2>&1 &
SP=$!; sleep 1.5
# users + posts(author->users)
curl -s -X POST http://127.0.0.1:8090/api/collections -H 'content-type: application/json' -d '{"name":"users","fields":[{"id":"","name":"name","type":"text","options":{}}]}' >/dev/null
UID=$(curl -s -X POST http://127.0.0.1:8090/api/collections/users/records -H 'content-type: application/json' -d '{"name":"Ada"}' | sed -n 's/.*"id":"\([a-z0-9]*\)".*/\1/p')
curl -s -X POST http://127.0.0.1:8090/api/collections -H 'content-type: application/json' -d "{\"name\":\"posts\",\"fields\":[{\"id\":\"\",\"name\":\"title\",\"type\":\"text\",\"options\":{}},{\"id\":\"\",\"name\":\"author\",\"type\":\"relation\",\"options\":{\"targetCollectionId\":\"$(curl -s http://127.0.0.1:8090/api/collections/users | sed -n 's/.*"id":"\([a-z0-9]*\)".*/\1/p' | head -1)\",\"maxSelect\":1}}]}" >/dev/null
curl -s -X POST http://127.0.0.1:8090/api/collections/posts/records -H 'content-type: application/json' -d "{\"title\":\"Hello\",\"author\":\"$UID\"}" >/dev/null
curl -s -X POST http://127.0.0.1:8090/api/collections/posts/records -H 'content-type: application/json' -d "{\"title\":\"World\",\"author\":\"$UID\"}" >/dev/null
echo "--- list page1 perPage1 sort -created ---"; curl -s "http://127.0.0.1:8090/api/collections/posts/records?perPage=1&sort=-created"
echo; echo "--- filter on relation path author.name='Ada' + expand=author ---"; curl -s "http://127.0.0.1:8090/api/collections/posts/records?filter=author.name%3D%22Ada%22&expand=author"
echo; echo "--- bad filter (expect 400) ---"; curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8090/api/collections/posts/records?filter=nonsuch%20%3D%201"
kill $SP 2>/dev/null; wait $SP 2>/dev/null
```
Expected: list → `{"page":1,"perPage":1,"totalItems":2,"totalPages":2,"items":[...]}` with newest first; the relation-path filter returns both posts with `expand.author.name == "Ada"` nested; the unknown-field filter → 400. **Always kill the server.**

- [ ] **Step 6: Commit**
```bash
git add src/api/records.zig src/server.zig src/main.zig
git commit -m "feat(api): record list endpoint with filter/sort/pagination/expand"
```

---

## Self-Review (completed by plan author)

**Spec coverage (SP3 design §5 + §6 list):**
- query-string parsing → Task 1 ✓
- filter language: lexer/parser/compiler, comparison + pattern (`~`→LIKE) + logical + grouping → Tasks 2,3,4 ✓
- relation-path traversal via `LEFT JOIN` (de-duplicated), every literal bound, paths validated → Task 4 (Joiner + compiler) ✓
- sort incl. relation paths → Task 5 ✓
- pagination + COUNT + `{page,perPage,totalItems,totalPages,items}` → Tasks 6,8 ✓
- nested expand with depth guard → Task 7 ✓
- list endpoint + reader connection + filter/sort error → 400 → Task 8 ✓
- **Deferred per spec:** `fields=` projection is OMITTED from this plan to keep scope bounded (the spec lists it as optional "trims top-level keys"); add it as a follow-up if wanted. Multi-relation filter traversal errors out (single-relation only), per spec. Batched expand (N+1 accepted).

**Type consistency:** `lexer.{Token,TokKind,lex}`; `parser.{Operand,Node,parse}`; `joiner.{Joiner,ColumnRef,JoinError}` (`Joiner.init/resolve/joins`); `compiler.{Param,Compiled,compile}`; `sort.compile`; `records.{list,ListQuery,ListResult,baseColumnList,bindParams}` reusing `rowToObject`; `params.{Params,parse}`; `expand.expand`. Import boundary: `records.zig` imports query compiler/lexer/parser/joiner/sort (NOT expand); `query/expand.zig` imports `records` — no cycle.

**Placeholder scan:** Tasks 1-3, 5, 6 contain complete code. Tasks 4 (compiler) and 7 (expand) give complete code with explicit notes where 0.16 specifics (the `cmp` payload type for `emitCmp`, lexer string-escape handling, the records↔query import boundary) may need a minimal touch — the test tables pin the required behavior, especially the security property that every filter literal is a bound parameter.
