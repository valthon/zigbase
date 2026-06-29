const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const joiner = @import("joiner.zig");
const values = @import("../values.zig");
const request = @import("../request.zig");

pub const Param = union(enum) { text: []const u8, int: i64, double: f64 };
pub const CompileError = error{ BadFilter, BadValue } || joiner.JoinError || values.ValueError;

pub const Compiled = struct { where_sql: []const u8, params: []const Param };

pub fn compile(alloc: std.mem.Allocator, j: *joiner.Joiner, node: *parser.Node, rctx: ?*const request.RequestContext) CompileError!Compiled {
    var params: std.ArrayList(Param) = .empty;
    const sql = try emit(alloc, j, node, &params, rctx);
    return .{ .where_sql = sql, .params = try params.toOwnedSlice(alloc) };
}

fn emit(alloc: std.mem.Allocator, j: *joiner.Joiner, node: *parser.Node, params: *std.ArrayList(Param), rctx: ?*const request.RequestContext) CompileError![]u8 {
    switch (node.*) {
        .logic => |lg| {
            const l = try emit(alloc, j, lg.l, params, rctx);
            const r = try emit(alloc, j, lg.r, params, rctx);
            const conj = if (lg.op == .l_and) "AND" else "OR";
            return std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ l, conj, r });
        },
        .cmp => |c| return emitCmp(alloc, j, c, params, rctx),
    }
}

fn opSql(op: lexer.TokKind) []const u8 {
    return switch (op) {
        .eq => "=",
        .ne => "!=",
        .gt => ">",
        .ge => ">=",
        .lt => "<",
        .le => "<=",
        .like => "LIKE",
        .nlike => "NOT LIKE",
        else => unreachable, // parser only produces comparison ops in a cmp node
    };
}

/// LIKE only makes sense on text-stored columns; reject it on number/bool fields.
fn likeAllowed(field: ?schema.Field) bool {
    const f = field orelse return true; // system columns (id/created/updated) are text
    return switch (f.options) {
        .number, .@"bool" => false,
        else => true,
    };
}

const Cmp = @TypeOf(@as(parser.Node, undefined).cmp);

fn isColPath(op: parser.Operand) bool {
    return op == .path and (op.path.len == 0 or op.path[0] != '@');
}

fn operandToText(op: parser.Operand, rctx: ?*const request.RequestContext) CompileError![]const u8 {
    switch (op) {
        .path => |p| {
            if (p.len > 0 and p[0] == '@') {
                const rc = rctx orelse return error.BadFilter;
                return rc.resolveMacro(p) orelse return error.BadFilter;
            }
            return error.BadFilter;
        },
        else => return literalToText(op),
    }
}

fn operandToParam(field: ?schema.Field, op: parser.Operand, rctx: ?*const request.RequestContext) CompileError!Param {
    switch (op) {
        .path => |p| {
            if (p.len > 0 and p[0] == '@') {
                const rc = rctx orelse return error.BadFilter;
                return .{ .text = rc.resolveMacro(p) orelse return error.BadFilter };
            }
            return error.BadFilter;
        },
        else => return literalToParam(field, op),
    }
}

fn emitCmp(alloc: std.mem.Allocator, j: *joiner.Joiner, c: Cmp, params: *std.ArrayList(Param), rctx: ?*const request.RequestContext) CompileError![]u8 {
    if (c.op == .in) return emitIn(alloc, j, c, params, rctx);

    const l_col = isColPath(c.lhs);
    const r_col = isColPath(c.rhs);

    if (l_col and r_col) {
        const lc = try j.resolve(c.lhs.path);
        const rc = try j.resolve(c.rhs.path);
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ lc.sql, opSql(c.op), rc.sql });
    }

    if (l_col or r_col) {
        const col = if (l_col) try j.resolve(c.lhs.path) else try j.resolve(c.rhs.path);
        const val_op = if (l_col) c.rhs else c.lhs;
        if (c.op == .like or c.op == .nlike) {
            if (!likeAllowed(col.field)) return error.BadValue;
            const term = try operandToText(val_op, rctx);
            try params.append(alloc, .{ .text = try std.fmt.allocPrint(alloc, "%{s}%", .{term}) });
            return std.fmt.allocPrint(alloc, "{s} {s} ?", .{ col.sql, opSql(c.op) });
        }
        try params.append(alloc, try operandToParam(col.field, val_op, rctx));
        if (l_col) return std.fmt.allocPrint(alloc, "{s} {s} ?", .{ col.sql, opSql(c.op) });
        return std.fmt.allocPrint(alloc, "? {s} {s}", .{ opSql(c.op), col.sql });
    }

    // neither side is a column: both are macros/literals -> bind both as text
    if (c.op == .like or c.op == .nlike) {
        const lt = try operandToText(c.lhs, rctx);
        const rt = try operandToText(c.rhs, rctx);
        try params.append(alloc, .{ .text = lt });
        try params.append(alloc, .{ .text = try std.fmt.allocPrint(alloc, "%{s}%", .{rt}) });
        return std.fmt.allocPrint(alloc, "? {s} ?", .{opSql(c.op)});
    }
    try params.append(alloc, .{ .text = try operandToText(c.lhs, rctx) });
    try params.append(alloc, .{ .text = try operandToText(c.rhs, rctx) });
    return std.fmt.allocPrint(alloc, "? {s} ?", .{opSql(c.op)});
}

/// Emit a set-membership predicate `<col> IN (?,?,…)`, binding each element as a parameter.
/// The left side MUST be a column path. The right side is either an explicit literal list
/// (`("a","b")`) or a list-valued macro (`@request.account.ids`), whose elements are read from the
/// request context. An EMPTY list (`()` or an empty membership set) compiles to the constant-false
/// predicate `0` — fail-closed, and avoids SQLite's `IN ()` syntax error.
fn emitIn(alloc: std.mem.Allocator, j: *joiner.Joiner, c: Cmp, params: *std.ArrayList(Param), rctx: ?*const request.RequestContext) CompileError![]u8 {
    if (!isColPath(c.lhs)) return error.BadFilter; // `<literal> in (...)` is meaningless
    const col = try j.resolve(c.lhs.path);
    var n: usize = 0;
    switch (c.rhs) {
        .list => |items| for (items) |it| {
            try params.append(alloc, try operandToParam(col.field, it, rctx));
            n += 1;
        },
        .list_macro => |m| {
            const rc = rctx orelse return error.BadFilter;
            const ids = (rc.resolveMacroList(alloc, m) catch return error.BadFilter) orelse return error.BadFilter;
            for (ids) |idv| {
                try params.append(alloc, .{ .text = idv });
                n += 1;
            }
        },
        else => return error.BadFilter, // parser only yields list/list_macro on the RHS of `in`
    }
    if (n == 0) return alloc.dupe(u8, "0"); // empty set -> constant-false, fail-closed
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, col.sql);
    try buf.appendSlice(alloc, " IN (");
    for (0..n) |i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.append(alloc, '?');
    }
    try buf.append(alloc, ')');
    return buf.toOwnedSlice(alloc);
}

fn literalToText(op: parser.Operand) CompileError![]const u8 {
    return switch (op) {
        .str => op.str,
        .num => op.num,
        .boolean => |b| if (b) "true" else "false",
        .nul => "",
        .path, .list, .list_macro => error.BadFilter,
    };
}

fn literalToParam(field: ?schema.Field, op: parser.Operand) CompileError!Param {
    if (field) |f| switch (f.options) {
        .number => |o| switch (o.mode) {
            .float => if (op == .num) return .{ .double = std.fmt.parseFloat(f64, op.num) catch return error.BadValue } else return error.BadValue,
            .int => if (op == .num) return .{ .int = try values.decimalToScaledInt(op.num, 0) } else return error.BadValue,
            .fixed => if (op == .num) return .{ .int = try values.decimalToScaledInt(op.num, o.scale orelse 0) } else return error.BadValue,
        },
        .@"bool" => if (op == .boolean) return .{ .int = if (op.boolean) 1 else 0 } else return error.BadValue,
        else => {},
    };
    return switch (op) {
        .str => .{ .text = op.str },
        .num => .{ .text = op.num },
        .boolean => |b| .{ .text = if (b) "true" else "false" },
        .nul => .{ .text = "" },
        .path, .list, .list_macro => error.BadFilter,
    };
}

fn setup(d: *db.Db, a: std.mem.Allocator) !schema.Collection {
    const migrations = @import("../migrations.zig");
    const collections = @import("../collections.zig");
    try migrations.run(d);
    const users = try collections.create(a, std.testing.io, d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }} });
    const pf = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
        .{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } },
    };
    return collections.create(a, std.testing.io, d, .{ .id = "", .name = "posts", .fields = &pf });
}

fn compileFilter(a: std.mem.Allocator, d: *db.Db, posts: schema.Collection, filter: []const u8, j: *joiner.Joiner) !Compiled {
    _ = d;
    _ = posts;
    const toks = try lexer.lex(a, filter);
    const ast = try parser.parse(a, toks);
    return compile(a, j, ast, null);
}

test "compile text equality binds the literal" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compileFilter(a, &d, posts, "title = \"hi\"", &j);
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    try std.testing.expectEqual(@as(usize, 1), c.params.len);
    try std.testing.expectEqualStrings("hi", c.params[0].text);
}

test "compile fixed comparison scales the numeric literal to an int param" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compileFilter(a, &d, posts, "price >= 10.50", &j);
    try std.testing.expectEqualStrings("\"posts\".\"price\" >= ?", c.where_sql);
    try std.testing.expectEqual(@as(i64, 1050), c.params[0].int);
}

test "compile LIKE wraps the term in percents" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compileFilter(a, &d, posts, "title ~ \"ab\"", &j);
    try std.testing.expectEqualStrings("\"posts\".\"title\" LIKE ?", c.where_sql);
    try std.testing.expectEqualStrings("%ab%", c.params[0].text);
}

test "compile a relation-path filter emits a join and uses the alias" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compileFilter(a, &d, posts, "author.name = \"x\"", &j);
    try std.testing.expectEqual(@as(usize, 1), j.joins.items.len);
    try std.testing.expect(std.mem.indexOf(u8, j.joins.items[0], "LEFT JOIN \"users\" AS j1 ON \"posts\".\"author\" = j1.\"id\"") != null);
    try std.testing.expectEqualStrings("j1.\"name\" = ?", c.where_sql);
    try std.testing.expectEqualStrings("x", c.params[0].text);
}

test "compile logical grouping" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compileFilter(a, &d, posts, "title = \"a\" && price > 1.00", &j);
    try std.testing.expectEqualStrings("(\"posts\".\"title\" = ? AND \"posts\".\"price\" > ?)", c.where_sql);
    try std.testing.expectEqual(@as(usize, 2), c.params.len);
}

test "compile a dedup of a repeated relation prefix uses one join" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    _ = try compileFilter(a, &d, posts, "author.name = \"x\" || author.id = \"y\"", &j);
    try std.testing.expectEqual(@as(usize, 1), j.joins.items.len); // single join reused
}

test "compile rejects an unknown field" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    try std.testing.expectError(error.UnknownField, compileFilter(a, &d, posts, "nonsuch = 1", &j));
}

test "SQL injection: string literal with metacharacters stays in params, never in where_sql" {
    // The dangerous literal contains SQL metacharacters that could break out of a
    // parameter position if ever interpolated directly.  The correct behaviour is:
    // where_sql must be exactly `"posts"."title" = ?` and the raw dangerous string
    // must appear verbatim in params[0].text.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    // Use single-quotes in the filter so the double-quote inside the value is not
    // the filter string delimiter, letting us embed " characters in the value.
    const dangerous = "x\" OR \"1\"=\"1; DROP TABLE posts;--";
    const filter = "title = 'x\" OR \"1\"=\"1; DROP TABLE posts;--'";
    const c = try compileFilter(a, &d, posts, filter, &j);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compileFilter(a, &d, posts, "title = 'O\\'Brien \\\"Jr\\\"'", &j);
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    try std.testing.expectEqual(@as(usize, 1), c.params.len);
    try std.testing.expectEqualStrings("O'Brien \"Jr\"", c.params[0].text);
}

test "compile a macro rule binds the auth id as a param" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var auth: std.json.ObjectMap = .empty;
    try auth.put(a, "id", .{ .string = "u1" });
    const rctx = request.RequestContext{ .auth = .{ .object = auth } };
    const toks = try lexer.lex(a, "title = @request.auth.id");
    const ast = try parser.parse(a, toks);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compile(a, &j, ast, &rctx);
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    try std.testing.expectEqualStrings("u1", c.params[0].text);
}

test "compile @ path without a context errors" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    const toks = try lexer.lex(a, "title = @request.auth.id");
    const ast = try parser.parse(a, toks);
    var j = joiner.Joiner.init(a, &d, posts);
    try std.testing.expectError(error.BadFilter, compile(a, &j, ast, null));
}

test "compile `in` with a literal list emits placeholders and binds each element" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compileFilter(a, &d, posts, "title in (\"a\", \"b\", \"c\")", &j);
    try std.testing.expectEqualStrings("\"posts\".\"title\" IN (?,?,?)", c.where_sql);
    try std.testing.expectEqual(@as(usize, 3), c.params.len);
    try std.testing.expectEqualStrings("a", c.params[0].text);
    try std.testing.expectEqualStrings("c", c.params[2].text);
}

test "compile `in` coerces list elements to the column type" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compileFilter(a, &d, posts, "price in (1.00, 2.50)", &j);
    try std.testing.expectEqualStrings("\"posts\".\"price\" IN (?,?)", c.where_sql);
    try std.testing.expectEqual(@as(i64, 100), c.params[0].int);
    try std.testing.expectEqual(@as(i64, 250), c.params[1].int);
}

test "compile `in @request.account.ids` binds each membership id" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    const mem = [_]request.Membership{ .{ .account = "acc1" }, .{ .account = "acc2" } };
    const rctx = request.RequestContext{ .memberships = &mem };
    const toks = try lexer.lex(a, "author in @request.account.ids");
    const ast = try parser.parse(a, toks);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compile(a, &j, ast, &rctx);
    try std.testing.expectEqualStrings("\"posts\".\"author\" IN (?,?)", c.where_sql);
    try std.testing.expectEqualStrings("acc1", c.params[0].text);
    try std.testing.expectEqualStrings("acc2", c.params[1].text);
}

test "compile `in` with an empty set is a constant-false predicate (fail-closed)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    // Empty literal list.
    var j1 = joiner.Joiner.init(a, &d, posts);
    const c1 = try compileFilter(a, &d, posts, "title in ()", &j1);
    try std.testing.expectEqualStrings("0", c1.where_sql);
    try std.testing.expectEqual(@as(usize, 0), c1.params.len);
    // Empty membership set via the macro.
    const rctx = request.RequestContext{}; // no memberships
    const toks = try lexer.lex(a, "author in @request.account.ids");
    const ast = try parser.parse(a, toks);
    var j2 = joiner.Joiner.init(a, &d, posts);
    const c2 = try compile(a, &j2, ast, &rctx);
    try std.testing.expectEqualStrings("0", c2.where_sql);
}

test "compile a relation-path macro rule (account.owner_user = @request.auth.id) still compiles" {
    // PR1 confirms relationship traversal + macros compose (the foundation for ability rules).
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a); // posts.author -> users
    var auth: std.json.ObjectMap = .empty;
    try auth.put(a, "id", .{ .string = "u1" });
    const rctx = request.RequestContext{ .auth = .{ .object = auth } };
    const toks = try lexer.lex(a, "author.name = @request.auth.id");
    const ast = try parser.parse(a, toks);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compile(a, &j, ast, &rctx);
    try std.testing.expectEqual(@as(usize, 1), j.joins.items.len);
    try std.testing.expectEqualStrings("j1.\"name\" = ?", c.where_sql);
    try std.testing.expectEqualStrings("u1", c.params[0].text);
}

test "compile a method-vs-literal rule binds both as text" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    const rctx = request.RequestContext{ .method = "GET" };
    const toks = try lexer.lex(a, "@request.method = \"GET\"");
    const ast = try parser.parse(a, toks);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compile(a, &j, ast, &rctx);
    try std.testing.expectEqualStrings("? = ?", c.where_sql);
    try std.testing.expectEqualStrings("GET", c.params[0].text);
    try std.testing.expectEqualStrings("GET", c.params[1].text);
}
