const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const request = @import("request.zig");
const records = @import("records.zig");
const lexer = @import("query/lexer.zig");
const parser = @import("query/parser.zig");
const compiler = @import("query/compiler.zig");
const joiner = @import("query/joiner.zig");

pub const Decision = enum { allow, deny_locked, check };

/// Pure policy: superuser -> allow; null rule -> deny_locked; "" -> allow; else -> check.
pub fn decide(rule: ?[]const u8, rctx: *const request.RequestContext) Decision {
    if (rctx.is_superuser) return .allow;
    const r = rule orelse return .deny_locked;
    if (r.len == 0) return .allow;
    return .check;
}

pub const RuleError = error{ BadRule } || lexer.LexError || parser.ParseError || compiler.CompileError || db.DbError || std.mem.Allocator.Error || @typeInfo(@typeInfo(@TypeOf(joiner.Joiner.resolve)).@"fn".return_type.?).error_union.error_set;

/// Compile a `check`-state rule into a records.Guard (its own joiner; standalone guarded query).
pub fn compileGuard(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, rule: []const u8, rctx: *const request.RequestContext) RuleError!records.Guard {
    const toks = try lexer.lex(alloc, rule);
    const ast = try parser.parse(alloc, toks);
    var j = joiner.Joiner.init(alloc, conn, col);
    const c = try compiler.compile(alloc, &j, ast, rctx);
    return .{ .where_sql = c.where_sql, .joins = j.joins.items, .params = c.params };
}

/// True if `id`'s row satisfies a `check`-state rule (guarded SELECT 1).
pub fn matches(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, id: []const u8, rule: []const u8, rctx: *const request.RequestContext) RuleError!bool {
    const g = try compileGuard(alloc, conn, col, rule, rctx);
    var joins: std.ArrayList(u8) = .empty;
    for (g.joins) |jn| { try joins.append(alloc, ' '); try joins.appendSlice(alloc, jn); }
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT 1 FROM \"{s}\"{s} WHERE \"{s}\".\"id\"=?1 AND ({s});", .{ col.name, joins.items, col.name, g.where_sql }, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id);
    _ = try records.bindParams(&st, g.params, 2);
    return try st.step();
}

test "decide: superuser/allow/null/empty/expr" {
    const su = request.RequestContext{ .is_superuser = true };
    const anon = request.RequestContext{};
    try std.testing.expectEqual(Decision.allow, decide(null, &su));
    try std.testing.expectEqual(Decision.deny_locked, decide(null, &anon));
    try std.testing.expectEqual(Decision.allow, decide("", &anon));
    try std.testing.expectEqual(Decision.check, decide("title = \"x\"", &anon));
}

test "matches runs a guarded select" {
    var d = try db.Db.openMemory(); defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const migrations = @import("migrations.zig");
    const collections = @import("collections.zig");
    try migrations.run(&d);
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }} });
    try d.exec("INSERT INTO posts (id,created,updated,title) VALUES ('r1','t','t','ok');");
    const anon = request.RequestContext{};
    try std.testing.expect(try matches(a, &d, col, "r1", "title = \"ok\"", &anon));
    try std.testing.expect(!try matches(a, &d, col, "r1", "title = \"no\"", &anon));
}
