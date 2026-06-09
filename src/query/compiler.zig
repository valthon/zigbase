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
        else => "=",
    };
}

const Cmp = @TypeOf(@as(parser.Node, undefined).cmp);

fn emitCmp(alloc: std.mem.Allocator, j: *joiner.Joiner, c: Cmp, params: *std.ArrayList(Param)) CompileError![]u8 {
    const lhs_path = (c.lhs == .path);
    const rhs_path = (c.rhs == .path);
    if (lhs_path and rhs_path) {
        const lc = try j.resolve(c.lhs.path);
        const rc = try j.resolve(c.rhs.path);
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ lc.sql, opSql(c.op), rc.sql });
    }
    const col_operand = if (lhs_path) c.lhs else c.rhs;
    const lit_operand = if (lhs_path) c.rhs else c.lhs;
    if (col_operand != .path) return error.BadFilter;
    const col = try j.resolve(col_operand.path);

    if (c.op == .like or c.op == .nlike) {
        const term = try literalToText(lit_operand);
        try params.append(alloc, .{ .text = try std.fmt.allocPrint(alloc, "%{s}%", .{term}) });
        return std.fmt.allocPrint(alloc, "{s} {s} ?", .{ col.sql, opSql(c.op) });
    }

    try params.append(alloc, try literalToParam(col.field, lit_operand));
    if (lhs_path) return std.fmt.allocPrint(alloc, "{s} {s} ?", .{ col.sql, opSql(c.op) });
    return std.fmt.allocPrint(alloc, "? {s} {s}", .{ opSql(c.op), col.sql });
}

fn literalToText(op: parser.Operand) CompileError![]const u8 {
    return switch (op) {
        .str => op.str,
        .num => op.num,
        .boolean => |b| if (b) "true" else "false",
        .nul => "",
        .path => error.BadFilter,
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
        .path => error.BadFilter,
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
    return compile(a, j, ast);
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
