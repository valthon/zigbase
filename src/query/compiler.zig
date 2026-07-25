const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const joiner = @import("joiner.zig");
const values = @import("../values.zig");
const request = @import("../request.zig");
const dialect_mod = @import("../sql/dialect.zig");
const Dialect = dialect_mod.Dialect;

pub const Param = union(enum) { text: []const u8, int: i64, double: f64, null };
pub const CompileError = error{ BadFilter, BadValue } || joiner.JoinError || values.ValueError;

pub const Compiled = struct { where_sql: []const u8, params: []const Param };

/// A bound value supplied via `filter_args` for a `?` placeholder in a filter string. Unlike a
/// grammar literal, a `FilterArg` is NEVER re-parsed as filter grammar — it is bound as a literal
/// SQL parameter (exactly like a SQL bind parameter), so a value containing filter metacharacters
/// (quotes, `||`, `(`, …) is compared as its literal bytes. Field-type coercion still applies (via
/// `coerceScalar`), so a placeholder for field F binds identically to writing the value inline as a
/// literal on F (e.g. `.float = 5.0` on a `fixed` scale-2 column scales to the same int as `5.00`).
/// `.null` binds SQL NULL regardless of field type (so `col = ?` with a null arg matches nothing,
/// per SQL three-valued logic — mirrors `values.bindValue`).
pub const FilterArg = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    null,
};

/// Bind a placeholder's `FilterArg` through the SAME field-type coercion the grammar-literal path
/// uses (`coerceScalar`), so the two can never diverge. Numeric args (`.int`/`.float`) are rendered
/// to a decimal string and funneled through the identical scale/parse logic as a `.num` literal;
/// `.null` short-circuits to SQL NULL. The result is always a bound param, never SQL text.
fn filterArgToParam(alloc: std.mem.Allocator, field: ?schema.Field, arg: FilterArg) CompileError!Param {
    return switch (arg) {
        .null => .null, // SQL NULL regardless of the field's type (unchanged).
        .string => |s| coerceScalar(field, .{ .text = s }),
        .bool => |b| coerceScalar(field, .{ .boolean = b }),
        // Render the native number to a decimal string so it flows through the exact same
        // scale/parse path (`values.decimalToScaledInt`/`parseFloat`) as an inline numeric literal.
        .int => |n| coerceScalar(field, .{ .num = try std.fmt.allocPrint(alloc, "{d}", .{n}) }),
        .float => |f| coerceScalar(field, .{ .num = try std.fmt.allocPrint(alloc, "{d}", .{f}) }),
    };
}

/// Total number of `?` placeholder operands in the AST — used to validate that the count of
/// supplied `filter_args` matches exactly (a mismatch is a loud `error.BadFilter`).
fn countPlaceholders(node: *const parser.Node) usize {
    return switch (node.*) {
        .logic => |lg| countPlaceholders(lg.l) + countPlaceholders(lg.r),
        .cmp => |c| countOperandPlaceholders(c.lhs) + countOperandPlaceholders(c.rhs),
    };
}

fn countOperandPlaceholders(op: parser.Operand) usize {
    return switch (op) {
        .placeholder => 1,
        .list => |items| blk: {
            var n: usize = 0;
            for (items) |it| n += countOperandPlaceholders(it);
            break :blk n;
        },
        else => 0,
    };
}

/// Compile a filter/rule AST into a parameter-bound WHERE fragment. `dialect` selects the
/// case-insensitive `LIKE` spelling (SQLite `LIKE` is ASCII-case-insensitive; Postgres needs
/// `ILIKE` to match) — every other operator is portable. Placeholders are still emitted as the
/// anonymous `?`; the `$n` renumber happens once at the prepare boundary (`sql/param_sink.zig`).
pub fn compile(alloc: std.mem.Allocator, j: *joiner.Joiner, node: *parser.Node, rctx: ?*const request.RequestContext, dialect: Dialect, filter_args: []const FilterArg) CompileError!Compiled {
    // Arg-count validation is a LOUD, fail-closed error: the number of `?` placeholders MUST
    // equal filter_args.len. This also means a filter STRING that smuggles a `?` on the REST path
    // (which supplies no filter_args) fails safely here rather than binding an unbound placeholder.
    if (countPlaceholders(node) != filter_args.len) return error.BadFilter;
    // Everything `emit` builds is SCRATCH: the child-string wrapping (`(l AND r)`), the
    // nocase-operand wrappers, the `IN (…)` buffer, and the transient decimal strings the
    // placeholder path funnels through `coerceScalar` are all consumed to produce the final
    // `where_sql` + `params`. Build them on a function-local arena; only the final SQL (duped) and
    // the params (each `.text` duped) escape on `alloc`. This makes `compile` self-freeing
    // (contract 1) under ANY allocator — including the test leak detector — instead of leaning on
    // the caller passing an arena. In production `alloc` IS an arena, so the dupes are a cheap
    // extra copy reclaimed at request end, and the returned params no longer alias the lexer's
    // token/unescape buffers (they own their bytes).
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var params: std.ArrayList(Param) = .empty;
    const sql = try emit(sa, j, node, &params, rctx, dialect, filter_args);

    const owned_sql = try alloc.dupe(u8, sql);
    errdefer alloc.free(owned_sql);
    const owned_params = try alloc.alloc(Param, params.items.len);
    errdefer alloc.free(owned_params);
    // Track how many `.text` dupes have landed so a mid-loop OOM frees exactly those (and no more).
    var filled: usize = 0;
    errdefer for (owned_params[0..filled]) |p| {
        if (p == .text) alloc.free(p.text);
    };
    for (params.items, 0..) |p, i| {
        owned_params[i] = switch (p) {
            .text => |t| .{ .text = try alloc.dupe(u8, t) },
            else => p,
        };
        filled = i + 1;
    }
    return .{ .where_sql = owned_sql, .params = owned_params };
}

/// Free a `Compiled` produced by `compile` on the SAME allocator `compile` was given. `compile`
/// returns a fully self-contained result (`where_sql` plus a `params` slice whose every `.text`
/// is duped onto that allocator), so freeing is uniform — the one place a non-arena caller frees
/// a compiled filter.
pub fn freeCompiled(a: std.mem.Allocator, c: Compiled) void {
    a.free(c.where_sql);
    for (c.params) |p| if (p == .text) a.free(p.text);
    a.free(c.params);
}

fn emit(alloc: std.mem.Allocator, j: *joiner.Joiner, node: *parser.Node, params: *std.ArrayList(Param), rctx: ?*const request.RequestContext, dialect: Dialect, filter_args: []const FilterArg) CompileError![]u8 {
    switch (node.*) {
        .logic => |lg| {
            const l = try emit(alloc, j, lg.l, params, rctx, dialect, filter_args);
            const r = try emit(alloc, j, lg.r, params, rctx, dialect, filter_args);
            const conj = if (lg.op == .l_and) "AND" else "OR";
            return std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ l, conj, r });
        },
        .cmp => |c| return emitCmp(alloc, j, c, params, rctx, dialect, filter_args),
    }
}

fn opSql(op: lexer.TokKind, dialect: Dialect) []const u8 {
    return switch (op) {
        .eq => "=",
        .ne => "!=",
        .gt => ">",
        .ge => ">=",
        .lt => "<",
        .le => "<=",
        // `~`/`!~` are case-insensitive "contains" matches (the value is wrapped in `%…%` by the
        // caller). To realize case-insensitivity on each backend: SQLite's `LIKE` is already
        // ASCII-case-insensitive, while Postgres's `LIKE` is case-sensitive, so Postgres emits
        // `ILIKE`/`NOT ILIKE` (SQLite keeps `LIKE`/`NOT LIKE`).
        .like => dialect.likeOp(true),
        .nlike => if (dialect.kind == .postgres) "NOT ILIKE" else "NOT LIKE",
        else => unreachable, // parser only produces comparison ops in a cmp node
    };
}

/// `=`/`!=` are the equality family whose result must agree with a `.nocase` column's
/// case-insensitive uniqueness; only these get `lower()`-wrapped (#159). Ordering ops keep their
/// historical (binary on SQLite) semantics; `~`/`!~` are already case-insensitive (ILIKE on PG).
fn isEqNe(op: lexer.TokKind) bool {
    return op == .eq or op == .ne;
}

/// LIKE only makes sense on text-stored columns; reject it on number/bool fields.
fn likeAllowed(field: ?schema.Field) bool {
    const f = field orelse return true; // system columns (id/created/updated) are text
    return switch (f.options) {
        .number, .bool => false,
        else => true,
    };
}

const Cmp = @TypeOf(@as(parser.Node, undefined).cmp);

fn isColPath(op: parser.Operand) bool {
    return op == .path and (op.path.len == 0 or op.path[0] != '@');
}

fn operandToText(op: parser.Operand, rctx: ?*const request.RequestContext, filter_args: []const FilterArg) CompileError![]const u8 {
    switch (op) {
        .path => |p| {
            if (p.len > 0 and p[0] == '@') {
                const rc = rctx orelse return error.BadFilter;
                return rc.resolveMacro(p) orelse return error.BadFilter;
            }
            return error.BadFilter;
        },
        // A placeholder used where TEXT is required (e.g. a LIKE term) must be a string arg.
        .placeholder => |idx| return switch (filter_args[idx]) {
            .string => |s| s,
            else => error.BadValue,
        },
        else => return literalToText(op),
    }
}

fn operandToParam(alloc: std.mem.Allocator, field: ?schema.Field, op: parser.Operand, rctx: ?*const request.RequestContext, filter_args: []const FilterArg) CompileError!Param {
    switch (op) {
        .path => |p| {
            if (p.len > 0 and p[0] == '@') {
                const rc = rctx orelse return error.BadFilter;
                return .{ .text = rc.resolveMacro(p) orelse return error.BadFilter };
            }
            return error.BadFilter;
        },
        // A `?` placeholder binds the caller's value through the SAME field-type coercion a literal
        // gets (so it behaves identically to writing the value inline), and is NEVER re-parsed as
        // grammar — the injection-safe SQL-bind-parameter contract.
        .placeholder => |idx| return filterArgToParam(alloc, field, filter_args[idx]),
        else => return literalToParam(field, op),
    }
}

fn emitCmp(alloc: std.mem.Allocator, j: *joiner.Joiner, c: Cmp, params: *std.ArrayList(Param), rctx: ?*const request.RequestContext, dialect: Dialect, filter_args: []const FilterArg) CompileError![]u8 {
    if (c.op == .in) return emitIn(alloc, j, c, params, rctx, dialect, filter_args);

    const l_col = isColPath(c.lhs);
    const r_col = isColPath(c.rhs);

    if (l_col and r_col) {
        const lc = try j.resolve(c.lhs.path);
        const rc = try j.resolve(c.rhs.path);
        // Column-vs-column equality on a `.nocase` column lowers BOTH sides so the compare matches
        // its case-insensitive uniqueness (PG `lower()`; SQLite unchanged) (#159).
        const ci = (lc.nocase or rc.nocase) and isEqNe(c.op);
        const lsql = if (ci) try dialect.nocaseEqOperand(alloc, lc.sql) else lc.sql;
        const rsql = if (ci) try dialect.nocaseEqOperand(alloc, rc.sql) else rc.sql;
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ lsql, opSql(c.op, dialect), rsql });
    }

    if (l_col or r_col) {
        const col = if (l_col) try j.resolve(c.lhs.path) else try j.resolve(c.rhs.path);
        const val_op = if (l_col) c.rhs else c.lhs;
        if (c.op == .like or c.op == .nlike) {
            if (!likeAllowed(col.field)) return error.BadValue;
            const term = try operandToText(val_op, rctx, filter_args);
            try params.append(alloc, .{ .text = try std.fmt.allocPrint(alloc, "%{s}%", .{term}) });
            return std.fmt.allocPrint(alloc, "{s} {s} ?", .{ col.sql, opSql(c.op, dialect) });
        }
        try params.append(alloc, try operandToParam(alloc, col.field, val_op, rctx, filter_args));
        // Case-insensitive equality against a `.nocase` column: lower the column AND the placeholder
        // so it uses the `lower()` functional index and agrees with uniqueness (PG only; SQLite
        // returns the operand unchanged, keeping the SQL byte-identical) (#159).
        const ci = col.nocase and isEqNe(c.op);
        const col_sql = if (ci) try dialect.nocaseEqOperand(alloc, col.sql) else col.sql;
        const ph = if (ci) try dialect.nocaseEqOperand(alloc, "?") else "?";
        if (l_col) return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ col_sql, opSql(c.op, dialect), ph });
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ ph, opSql(c.op, dialect), col_sql });
    }

    // neither side is a column: both are macros/literals -> bind both as text
    if (c.op == .like or c.op == .nlike) {
        const lt = try operandToText(c.lhs, rctx, filter_args);
        const rt = try operandToText(c.rhs, rctx, filter_args);
        try params.append(alloc, .{ .text = lt });
        try params.append(alloc, .{ .text = try std.fmt.allocPrint(alloc, "%{s}%", .{rt}) });
        return std.fmt.allocPrint(alloc, "? {s} ?", .{opSql(c.op, dialect)});
    }
    try params.append(alloc, .{ .text = try operandToText(c.lhs, rctx, filter_args) });
    try params.append(alloc, .{ .text = try operandToText(c.rhs, rctx, filter_args) });
    return std.fmt.allocPrint(alloc, "? {s} ?", .{opSql(c.op, dialect)});
}

/// Emit a set-membership predicate `<col> IN (?,?,…)`, binding each element as a parameter.
/// The left side MUST be a column path. The right side is either an explicit literal list
/// (`("a","b")`) or a list-valued macro (`@request.account.ids`), whose elements are read from the
/// request context. An EMPTY list (`()` or an empty membership set) compiles to the constant-false
/// predicate `0` — fail-closed, and avoids SQLite's `IN ()` syntax error.
fn emitIn(alloc: std.mem.Allocator, j: *joiner.Joiner, c: Cmp, params: *std.ArrayList(Param), rctx: ?*const request.RequestContext, dialect: Dialect, filter_args: []const FilterArg) CompileError![]u8 {
    if (!isColPath(c.lhs)) return error.BadFilter; // `<literal> in (...)` is meaningless
    const col = try j.resolve(c.lhs.path);
    var n: usize = 0;
    switch (c.rhs) {
        .list => |items| for (items) |it| {
            try params.append(alloc, try operandToParam(alloc, col.field, it, rctx, filter_args));
            n += 1;
        },
        .list_macro => |m| {
            const rc = rctx orelse return error.BadFilter;
            // `try` so OutOfMemory propagates (a real 500) instead of being masked as a
            // BadFilter 400; an unknown list macro is the only BadFilter case here.
            const ids = (try rc.resolveMacroList(alloc, m)) orelse return error.BadFilter;
            for (ids) |idv| {
                try params.append(alloc, .{ .text = idv });
                n += 1;
            }
        },
        else => return error.BadFilter, // parser only yields list/list_macro on the RHS of `in`
    }
    if (n == 0) return alloc.dupe(u8, dialect.constFalse()); // empty set -> constant-false, fail-closed
    // IN is set-equality, so a `.nocase` column makes the column AND every placeholder
    // case-insensitive so each membership test matches the case-insensitive uniqueness (PG
    // `lower()`; SQLite COLLATE NOCASE) (#159). `ph` is computed ONCE and reused for all n
    // placeholders (it is loop-invariant), avoiding n allocations.
    const ci = col.nocase;
    const ph = if (ci) try dialect.nocaseEqOperand(alloc, "?") else "?";
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, if (ci) try dialect.nocaseEqOperand(alloc, col.sql) else col.sql);
    try buf.appendSlice(alloc, " IN (");
    for (0..n) |i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, ph);
    }
    try buf.append(alloc, ')');
    return buf.toOwnedSlice(alloc);
}

fn literalToText(op: parser.Operand) CompileError![]const u8 {
    return switch (op) {
        .str => op.str,
        .num => op.num,
        .boolean => |b| if (b) "true" else "false",
        // NULL has no TEXT representation. In a text context (a LIKE term, or a literal-vs-literal
        // text bind) a null operand must FAIL CLOSED — binding `""` would make `col ~ null` a
        // match-everything `"%%"` term (fail-open). Reject with the same `error.BadValue` the LIKE
        // path already uses for a non-string placeholder there. (A column `= null` never reaches
        // here — it binds SQL NULL via coerceScalar.)
        .nul => error.BadValue,
        // A placeholder is bound by operandToText/operandToParam before reaching here.
        .path, .list, .list_macro, .placeholder => error.BadFilter,
    };
}

/// A scalar value normalized out of its source syntax (a grammar literal token or a bound
/// `FilterArg`), before field-type coercion. Both paths converge here so `coerceScalar` is the
/// single place that maps a value to its stored `Param` shape — the literal and placeholder paths
/// can never diverge on how a value binds for a given field.
const Scalar = union(enum) {
    /// A numeric value as a decimal string (e.g. "5.00", "5", "-3.2"); scaled by the field scale.
    num: []const u8,
    /// A text value bound as-is for text-family fields (and the generic non-typed fallback).
    text: []const u8,
    boolean: bool,
    nul,
};

/// Field-aware value coercion shared by the grammar-literal path and the `?` placeholder path.
/// Numeric fields scale/parse the decimal string exactly as before; a bool field maps to 0/1; any
/// non-typed field binds the value's textual form. A value whose kind is incompatible with a typed
/// field (e.g. a text value for a numeric column, a number for a bool column) is a loud
/// `error.BadValue` — never a silent misbind. Injection-safe: always returns a bound param.
fn coerceScalar(field: ?schema.Field, s: Scalar) CompileError!Param {
    // An inline `= null` literal binds SQL NULL regardless of the field type, IDENTICALLY to a
    // bound `FilterArg.null` (`filterArgToParam` short-circuits the same way). Under SQL's
    // three-valued logic this matches nothing — never the empty string, and never a typed-field
    // BadValue. Short-circuit BEFORE the field switch so a null on a number/bool column is SQL
    // NULL, not a coercion error.
    if (s == .nul) return .null;
    if (field) |f| switch (f.options) {
        .number => |o| {
            if (s != .num) return error.BadValue;
            return switch (o.mode) {
                .float => .{ .double = std.fmt.parseFloat(f64, s.num) catch return error.BadValue },
                .int => .{ .int = try values.decimalToScaledInt(s.num, 0) },
                .fixed => .{ .int = try values.decimalToScaledInt(s.num, o.scale orelse 0) },
            };
        },
        .bool => {
            if (s != .boolean) return error.BadValue;
            return .{ .int = if (s.boolean) 1 else 0 };
        },
        else => {},
    };
    return switch (s) {
        .num => |n| .{ .text = n },
        .text => |t| .{ .text = t },
        .boolean => |b| .{ .text = if (b) "true" else "false" },
        .nul => unreachable, // handled by the early SQL-NULL short-circuit above
    };
}

fn literalToParam(field: ?schema.Field, op: parser.Operand) CompileError!Param {
    const s: Scalar = switch (op) {
        .str => |v| .{ .text = v },
        .num => |v| .{ .num = v },
        .boolean => |b| .{ .boolean = b },
        .nul => .nul,
        .path, .list, .list_macro, .placeholder => return error.BadFilter,
    };
    return coerceScalar(field, s);
}

fn setup(d: *db.Db, a: std.mem.Allocator) !schema.Collection {
    const migrations = @import("../migrations.zig");
    const collections = @import("../collections.zig");
    try migrations.run(d);
    const users = try collections.create(a, std.testing.io, d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }} });
    // `posts` dupes the relation target id it needs, so the intermediate `users` graph is freed
    // here (the caller only receives + owns `posts`). Runs on the error path too (a no-op leak-free).
    defer users.deinit(a);
    const pf = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
        .{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } },
        .{ .id = "f4", .name = "active", .options = .{ .bool = .{} } },
    };
    return collections.create(a, std.testing.io, d, .{ .id = "", .name = "posts", .fields = &pf });
}

// `a` drives the SUT (lex/parse/compile) so its OWN allocations are leak-checked; the tokens and
// AST are transient scratch freed here (compile duped everything it keeps), and the returned
// `Compiled` is owned by `a`. Every test now runs the whole pipeline on the raw testing allocator:
// the created collections free via `Collection.deinit` and the joiner via `Joiner.deinit`.
fn compileFilter(a: std.mem.Allocator, d: *db.Db, posts: schema.Collection, filter: []const u8, j: *joiner.Joiner) !Compiled {
    _ = d;
    _ = posts;
    const toks = try lexer.lex(a, filter);
    defer lexer.freeTokens(a, filter, toks);
    const ast = try parser.parse(a, toks);
    defer parser.freeNode(a, ast);
    return compile(a, j, ast, null, Dialect.sqlite, &.{});
}

/// Like `compileFilter` but with bound `?` placeholder values.
fn compileFilterArgs(a: std.mem.Allocator, filter: []const u8, j: *joiner.Joiner, filter_args: []const FilterArg) !Compiled {
    const toks = try lexer.lex(a, filter);
    defer lexer.freeTokens(a, filter, toks);
    const ast = try parser.parse(a, toks);
    defer parser.freeNode(a, ast);
    return compile(a, j, ast, null, Dialect.sqlite, filter_args);
}

test "compile text equality binds the literal" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilter(a, &d, posts, "title = \"hi\"", &j);
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    try std.testing.expectEqual(@as(usize, 1), c.params.len);
    try std.testing.expectEqualStrings("hi", c.params[0].text);
}

test "compile makes a .nocase column equality/IN case-insensitive on BOTH backends (#159)" {
    const migrations = @import("../migrations.zig");
    const collections = @import("../collections.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    try migrations.run(&d);
    const idx = [_]schema.Index{.{ .name = "idx_people_addr", .fields = &.{"addr"}, .unique = true, .collation = .nocase }};
    const people = try collections.create(a, std.testing.io, &d, .{
        .id = "",
        .name = "people",
        .fields = &[_]schema.Field{
            .{ .id = "e1", .name = "addr", .options = .{ .text = .{} } }, // .nocase-indexed (case-insensitive)
            .{ .id = "n1", .name = "label", .options = .{ .text = .{} } }, // plain text (case-sensitive)
        },
        .indexes = &idx,
    });
    defer people.deinit(a);
    const Case = struct { filter: []const u8, dia: Dialect, want: []const u8 };
    const cases = [_]Case{
        // SQLite: BOTH sides get COLLATE NOCASE so the compare is case-insensitive and uses the
        // COLLATE NOCASE index — parity with Postgres (no per-backend divergence).
        .{ .filter = "addr = \"Bob@x.com\"", .dia = Dialect.sqlite, .want = "\"people\".\"addr\" COLLATE NOCASE = ? COLLATE NOCASE" },
        // Postgres: lower() BOTH sides so the compare matches the lower(addr) functional index.
        .{ .filter = "addr = \"Bob@x.com\"", .dia = Dialect.postgres, .want = "lower(\"people\".\"addr\") = lower(?)" },
        // != is wrapped too (the equality family); a NON-nocase column (label) is unchanged.
        .{ .filter = "addr != \"Bob@x.com\"", .dia = Dialect.sqlite, .want = "\"people\".\"addr\" COLLATE NOCASE != ? COLLATE NOCASE" },
        .{ .filter = "addr != \"Bob@x.com\"", .dia = Dialect.postgres, .want = "lower(\"people\".\"addr\") != lower(?)" },
        .{ .filter = "label = \"Bob\"", .dia = Dialect.sqlite, .want = "\"people\".\"label\" = ?" },
        .{ .filter = "label = \"Bob\"", .dia = Dialect.postgres, .want = "\"people\".\"label\" = ?" },
        // IN wraps the column + every placeholder on both backends.
        .{ .filter = "addr in (\"A@x\", \"b@x\")", .dia = Dialect.sqlite, .want = "\"people\".\"addr\" COLLATE NOCASE IN (? COLLATE NOCASE,? COLLATE NOCASE)" },
        .{ .filter = "addr in (\"A@x\", \"b@x\")", .dia = Dialect.postgres, .want = "lower(\"people\".\"addr\") IN (lower(?),lower(?))" },
    };
    for (cases) |cs| {
        const toks = try lexer.lex(a, cs.filter);
        defer lexer.freeTokens(a, cs.filter, toks);
        const ast = try parser.parse(a, toks);
        defer parser.freeNode(a, ast);
        var j = joiner.Joiner.init(a, &d, people);
        defer j.deinit();
        const c = try compile(a, &j, ast, null, cs.dia, &.{});
        defer freeCompiled(a, c);
        try std.testing.expectEqualStrings(cs.want, c.where_sql);
    }
}

test "compile fixed comparison scales the numeric literal to an int param" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilter(a, &d, posts, "price >= 10.50", &j);
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"price\" >= ?", c.where_sql);
    try std.testing.expectEqual(@as(i64, 1050), c.params[0].int);
}

test "compile LIKE wraps the term in percents" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilter(a, &d, posts, "title ~ \"ab\"", &j);
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"title\" LIKE ?", c.where_sql);
    try std.testing.expectEqualStrings("%ab%", c.params[0].text);
}

test "compile a relation-path filter emits a join and uses the alias" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilter(a, &d, posts, "author.name = \"x\"", &j);
    defer freeCompiled(a, c);
    try std.testing.expectEqual(@as(usize, 1), j.joins.items.len);
    try std.testing.expect(std.mem.indexOf(u8, j.joins.items[0], "LEFT JOIN \"users\" AS j1 ON \"posts\".\"author\" = j1.\"id\"") != null);
    try std.testing.expectEqualStrings("j1.\"name\" = ?", c.where_sql);
    try std.testing.expectEqualStrings("x", c.params[0].text);
}

test "compile logical grouping" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilter(a, &d, posts, "title = \"a\" && price > 1.00", &j);
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("(\"posts\".\"title\" = ? AND \"posts\".\"price\" > ?)", c.where_sql);
    try std.testing.expectEqual(@as(usize, 2), c.params.len);
}

test "compile a dedup of a repeated relation prefix uses one join" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilter(a, &d, posts, "author.name = \"x\" || author.id = \"y\"", &j);
    defer freeCompiled(a, c);
    try std.testing.expectEqual(@as(usize, 1), j.joins.items.len); // single join reused
}

test "compile rejects an unknown field" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    try std.testing.expectError(error.UnknownField, compileFilter(a, &d, posts, "nonsuch = 1", &j));
}

test "SQL injection: string literal with metacharacters stays in params, never in where_sql" {
    // The dangerous literal contains SQL metacharacters that could break out of a
    // parameter position if ever interpolated directly.  The correct behaviour is:
    // where_sql must be exactly `"posts"."title" = ?` and the raw dangerous string
    // must appear verbatim in params[0].text.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    // Use single-quotes in the filter so the double-quote inside the value is not
    // the filter string delimiter, letting us embed " characters in the value.
    const dangerous = "x\" OR \"1\"=\"1; DROP TABLE posts;--";
    const filter = "title = 'x\" OR \"1\"=\"1; DROP TABLE posts;--'";
    const c = try compileFilter(a, &d, posts, filter, &j);
    defer freeCompiled(a, c);
    // (a) where_sql must be exactly the parameterised form — no injected SQL
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    // (b) the dangerous text must be bound as the first (and only) parameter
    try std.testing.expectEqual(@as(usize, 1), c.params.len);
    try std.testing.expectEqualStrings(dangerous, c.params[0].text);
}

test "compile binds an escaped string literal's unescaped value as a param" {
    // A value containing BOTH quote characters is only representable via backslash
    // escaping (the SDK can no longer dodge by switching quote kinds). The compiler
    // must bind the real, unescaped O'Brien-style value into params.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilter(a, &d, posts, "title = 'O\\'Brien \\\"Jr\\\"'", &j);
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    try std.testing.expectEqual(@as(usize, 1), c.params.len);
    try std.testing.expectEqualStrings("O'Brien \"Jr\"", c.params[0].text);
}

test "compile a macro rule binds the auth id as a param" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var auth: std.json.ObjectMap = .empty;
    try auth.put(a, "id", .{ .string = "u1" });
    defer auth.deinit(a);
    const rctx = request.RequestContext{ .auth = .{ .object = auth } };
    const src = "title = @request.auth.id";
    const toks = try lexer.lex(a, src);
    defer lexer.freeTokens(a, src, toks);
    const ast = try parser.parse(a, toks);
    defer parser.freeNode(a, ast);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compile(a, &j, ast, &rctx, Dialect.sqlite, &.{});
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    try std.testing.expectEqualStrings("u1", c.params[0].text);
}

test "compile @ path without a context errors" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    const src = "title = @request.auth.id";
    const toks = try lexer.lex(a, src);
    defer lexer.freeTokens(a, src, toks);
    const ast = try parser.parse(a, toks);
    defer parser.freeNode(a, ast);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    try std.testing.expectError(error.BadFilter, compile(a, &j, ast, null, Dialect.sqlite, &.{}));
}

test "compile `in` with a literal list emits placeholders and binds each element" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilter(a, &d, posts, "title in (\"a\", \"b\", \"c\")", &j);
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"title\" IN (?,?,?)", c.where_sql);
    try std.testing.expectEqual(@as(usize, 3), c.params.len);
    try std.testing.expectEqualStrings("a", c.params[0].text);
    try std.testing.expectEqualStrings("c", c.params[2].text);
}

test "compile `in` coerces list elements to the column type" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilter(a, &d, posts, "price in (1.00, 2.50)", &j);
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"price\" IN (?,?)", c.where_sql);
    try std.testing.expectEqual(@as(i64, 100), c.params[0].int);
    try std.testing.expectEqual(@as(i64, 250), c.params[1].int);
}

test "compile `in @request.account.ids` binds each membership id" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    const mem = [_]request.Membership{ .{ .account = "acc1" }, .{ .account = "acc2" } };
    const rctx = request.RequestContext{ .memberships = &mem };
    const src = "author in @request.account.ids";
    const toks = try lexer.lex(a, src);
    defer lexer.freeTokens(a, src, toks);
    const ast = try parser.parse(a, toks);
    defer parser.freeNode(a, ast);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compile(a, &j, ast, &rctx, Dialect.sqlite, &.{});
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"author\" IN (?,?)", c.where_sql);
    try std.testing.expectEqualStrings("acc1", c.params[0].text);
    try std.testing.expectEqualStrings("acc2", c.params[1].text);
}

test "compile `in` with an empty set is a constant-false predicate (fail-closed)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    // Empty literal list.
    var j1 = joiner.Joiner.init(a, &d, posts);
    defer j1.deinit();
    const c1 = try compileFilter(a, &d, posts, "title in ()", &j1);
    defer freeCompiled(a, c1);
    try std.testing.expectEqualStrings("0", c1.where_sql);
    try std.testing.expectEqual(@as(usize, 0), c1.params.len);
    // Empty membership set via the macro.
    const rctx = request.RequestContext{}; // no memberships
    const src = "author in @request.account.ids";
    const toks = try lexer.lex(a, src);
    defer lexer.freeTokens(a, src, toks);
    const ast = try parser.parse(a, toks);
    defer parser.freeNode(a, ast);
    var j2 = joiner.Joiner.init(a, &d, posts);
    defer j2.deinit();
    const c2 = try compile(a, &j2, ast, &rctx, Dialect.sqlite, &.{});
    defer freeCompiled(a, c2);
    try std.testing.expectEqualStrings("0", c2.where_sql);
}

test "compile a relation-path macro rule (account.owner_user = @request.auth.id) still compiles" {
    // PR1 confirms relationship traversal + macros compose (the foundation for ability rules).
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a); // posts.author -> users
    defer posts.deinit(a);
    var auth: std.json.ObjectMap = .empty;
    try auth.put(a, "id", .{ .string = "u1" });
    defer auth.deinit(a);
    const rctx = request.RequestContext{ .auth = .{ .object = auth } };
    const src = "author.name = @request.auth.id";
    const toks = try lexer.lex(a, src);
    defer lexer.freeTokens(a, src, toks);
    const ast = try parser.parse(a, toks);
    defer parser.freeNode(a, ast);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compile(a, &j, ast, &rctx, Dialect.sqlite, &.{});
    defer freeCompiled(a, c);
    try std.testing.expectEqual(@as(usize, 1), j.joins.items.len);
    try std.testing.expectEqualStrings("j1.\"name\" = ?", c.where_sql);
    try std.testing.expectEqualStrings("u1", c.params[0].text);
}

test "compile a method-vs-literal rule binds both as text" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    const rctx = request.RequestContext{ .method = "GET" };
    const src = "@request.method = \"GET\"";
    const toks = try lexer.lex(a, src);
    defer lexer.freeTokens(a, src, toks);
    const ast = try parser.parse(a, toks);
    defer parser.freeNode(a, ast);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compile(a, &j, ast, &rctx, Dialect.sqlite, &.{});
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("? = ?", c.where_sql);
    try std.testing.expectEqualStrings("GET", c.params[0].text);
    try std.testing.expectEqualStrings("GET", c.params[1].text);
}

test "filter_args: a `?` placeholder binds each scalar arg type, coerced to the field's type" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a); // title:text, price:fixed(2), active:bool
    defer posts.deinit(a);

    // string on a text field -> bound as text
    {
        var j = joiner.Joiner.init(a, &d, posts);
        defer j.deinit();
        const c = try compileFilterArgs(a, "title = ?", &j, &.{.{ .string = "hello" }});
        defer freeCompiled(a, c);
        try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
        try std.testing.expectEqual(@as(usize, 1), c.params.len);
        try std.testing.expectEqualStrings("hello", c.params[0].text);
    }
    // int on a fixed(scale=2) column -> scaled int (5 -> 500), same as the literal path
    {
        var j = joiner.Joiner.init(a, &d, posts);
        defer j.deinit();
        const c = try compileFilterArgs(a, "price = ?", &j, &.{.{ .int = 5 }});
        defer freeCompiled(a, c);
        try std.testing.expectEqual(@as(i64, 500), c.params[0].int);
    }
    // float on a fixed(scale=2) column -> scaled int (3.5 -> 350)
    {
        var j = joiner.Joiner.init(a, &d, posts);
        defer j.deinit();
        const c = try compileFilterArgs(a, "price = ?", &j, &.{.{ .float = 3.5 }});
        defer freeCompiled(a, c);
        try std.testing.expectEqual(@as(i64, 350), c.params[0].int);
    }
    // bool on a bool field -> 0/1 int
    {
        var j = joiner.Joiner.init(a, &d, posts);
        defer j.deinit();
        const c = try compileFilterArgs(a, "active = ?", &j, &.{.{ .bool = true }});
        defer freeCompiled(a, c);
        try std.testing.expectEqual(@as(i64, 1), c.params[0].int);
        var j2 = joiner.Joiner.init(a, &d, posts);
        defer j2.deinit();
        const c2 = try compileFilterArgs(a, "active = ?", &j2, &.{.{ .bool = false }});
        defer freeCompiled(a, c2);
        try std.testing.expectEqual(@as(i64, 0), c2.params[0].int);
    }
    // null -> SQL NULL param regardless of field type
    {
        var j = joiner.Joiner.init(a, &d, posts);
        defer j.deinit();
        const c = try compileFilterArgs(a, "title = ?", &j, &.{.null});
        defer freeCompiled(a, c);
        try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
        try std.testing.expect(c.params[0] == .null);
    }
}

test "filter_args: a placeholder coerces by field type identically to an inline literal" {
    // Regression for the silent-empty-result footgun: `price = ?` with a numeric arg must produce
    // the SAME scaled-int param as the inline literal `price = 5.00`, not a raw unscaled value.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a); // price is fixed(scale=2)
    defer posts.deinit(a);

    var jl = joiner.Joiner.init(a, &d, posts);
    defer jl.deinit();
    const lit = try compileFilter(a, &d, posts, "price = 5.00", &jl);
    defer freeCompiled(a, lit);
    try std.testing.expectEqual(@as(i64, 500), lit.params[0].int);

    // float arg matches the inline literal
    var jf = joiner.Joiner.init(a, &d, posts);
    defer jf.deinit();
    const cf = try compileFilterArgs(a, "price = ?", &jf, &.{.{ .float = 5.0 }});
    defer freeCompiled(a, cf);
    try std.testing.expectEqual(lit.params[0].int, cf.params[0].int);

    // int arg matches too
    var ji = joiner.Joiner.init(a, &d, posts);
    defer ji.deinit();
    const ci = try compileFilterArgs(a, "price = ?", &ji, &.{.{ .int = 5 }});
    defer freeCompiled(a, ci);
    try std.testing.expectEqual(lit.params[0].int, ci.params[0].int);
}

test "filter_args: an incompatible arg/field pairing is a loud BadValue" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    // A non-numeric arg for a numeric column errors (never silently binds garbage) — mirrors the
    // literal path (`price = "x"` also errors). A number for a bool column likewise errors.
    var j1 = joiner.Joiner.init(a, &d, posts);
    defer j1.deinit();
    try std.testing.expectError(error.BadValue, compileFilterArgs(a, "price = ?", &j1, &.{.{ .string = "5.00" }}));
    var j2 = joiner.Joiner.init(a, &d, posts);
    defer j2.deinit();
    try std.testing.expectError(error.BadValue, compileFilterArgs(a, "active = ?", &j2, &.{.{ .int = 1 }}));
}

test "filter_args: a bound string with filter metacharacters stays literal (injection-safe)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    // The value is full of filter grammar: quotes, `||`, `(`, `--`, a stray `?`. NONE of it is
    // re-lexed — the whole string is bound verbatim as the single param.
    const dangerous = "a\" || 1=1 -- ) ? (";
    const c = try compileFilterArgs(a, "title = ?", &j, &.{.{ .string = dangerous }});
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    try std.testing.expectEqual(@as(usize, 1), c.params.len);
    try std.testing.expectEqualStrings(dangerous, c.params[0].text);
}

test "filter_args: multiple placeholders bind left-to-right by index" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilterArgs(a, "title = ? && price >= ?", &j, &.{
        .{ .string = "first" },
        .{ .int = 100 },
    });
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("(\"posts\".\"title\" = ? AND \"posts\".\"price\" >= ?)", c.where_sql);
    try std.testing.expectEqual(@as(usize, 2), c.params.len);
    try std.testing.expectEqualStrings("first", c.params[0].text);
    // price is fixed(scale=2): the int arg 100 scales to 10000 (same as the literal `price >= 100`).
    try std.testing.expectEqual(@as(i64, 10000), c.params[1].int);
}

test "filter_args: placeholders work inside an `in (...)` list" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilterArgs(a, "title in (?, ?)", &j, &.{
        .{ .string = "x" },
        .{ .string = "y" },
    });
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"title\" IN (?,?)", c.where_sql);
    try std.testing.expectEqualStrings("x", c.params[0].text);
    try std.testing.expectEqualStrings("y", c.params[1].text);
}

test "filter_args: a bound string is usable as a LIKE term" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilterArgs(a, "title ~ ?", &j, &.{.{ .string = "ab" }});
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"title\" LIKE ?", c.where_sql);
    try std.testing.expectEqualStrings("%ab%", c.params[0].text);
}

test "filter_args: a non-string arg in a LIKE term is a loud BadValue" {
    // LIKE needs a text term; a placeholder there must be a string arg (non-string is rejected,
    // never coerced into a `%…%` pattern).
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    try std.testing.expectError(error.BadValue, compileFilterArgs(a, "title ~ ?", &j, &.{.{ .int = 5 }}));
}

test "filter_args: arg-count mismatch is a loud BadFilter (both directions)" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    // Two placeholders, one arg.
    var j1 = joiner.Joiner.init(a, &d, posts);
    defer j1.deinit();
    try std.testing.expectError(error.BadFilter, compileFilterArgs(a, "title = ? && price = ?", &j1, &.{.{ .int = 1 }}));
    // Zero placeholders, one arg.
    var j2 = joiner.Joiner.init(a, &d, posts);
    defer j2.deinit();
    try std.testing.expectError(error.BadFilter, compileFilterArgs(a, "price = 1", &j2, &.{.{ .int = 1 }}));
    // One placeholder, zero args.
    var j3 = joiner.Joiner.init(a, &d, posts);
    defer j3.deinit();
    try std.testing.expectError(error.BadFilter, compileFilterArgs(a, "title = ?", &j3, &.{}));
}

test "filter_args: REST safety — a `?` in the filter with no filter_args fails closed" {
    // The REST `?filter=` path supplies NO filter_args, so a filter string containing a `?`
    // cannot smuggle an unbound placeholder — it hits the same count-mismatch guard.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    try std.testing.expectError(error.BadFilter, compileFilter(a, &d, posts, "title = ?", &j));
}

test "filter_args: back-compat — a filter with no `?` and no args compiles unchanged" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilterArgs(a, "title = \"hi\"", &j, &.{});
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    try std.testing.expectEqualStrings("hi", c.params[0].text);
}

test "inline `= null` binds SQL NULL, identical to a bound FilterArg.null" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);

    // Inline literal `title = null` -> a bound `.null` param (SQL NULL), NOT the empty string.
    var j = joiner.Joiner.init(a, &d, posts);
    defer j.deinit();
    const c = try compileFilterArgs(a, "title = null", &j, &.{});
    defer freeCompiled(a, c);
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    try std.testing.expect(c.params[0] == .null);

    // A null literal on a TYPED (numeric) column also binds SQL NULL — not a coercion BadValue.
    var jn = joiner.Joiner.init(a, &d, posts);
    defer jn.deinit();
    const cn = try compileFilterArgs(a, "price = null", &jn, &.{});
    defer freeCompiled(a, cn);
    try std.testing.expect(cn.params[0] == .null);

    // The bound-placeholder path (`title = ?` + FilterArg.null) produces the identical param.
    var jp = joiner.Joiner.init(a, &d, posts);
    defer jp.deinit();
    const cp = try compileFilterArgs(a, "title = ?", &jp, &.{.null});
    defer freeCompiled(a, cp);
    try std.testing.expect(cp.params[0] == .null);
}

test "LIKE with a null operand is rejected (fail closed), never a match-everything %% term" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const posts = try setup(&d, a);
    defer posts.deinit(a);
    // Inline `title ~ null`: a null has no TEXT representation, so it must be a loud BadValue rather
    // than binding `"%%"` (which would match every row).
    var j1 = joiner.Joiner.init(a, &d, posts);
    defer j1.deinit();
    try std.testing.expectError(error.BadValue, compileFilterArgs(a, "title ~ null", &j1, &.{}));
    // Bound `title ~ ?` + FilterArg.null is likewise rejected (a non-string placeholder in a LIKE).
    var j2 = joiner.Joiner.init(a, &d, posts);
    defer j2.deinit();
    try std.testing.expectError(error.BadValue, compileFilterArgs(a, "title ~ ?", &j2, &.{.null}));
}
