const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const request = @import("request.zig");
const records = @import("records.zig");
const ddl = @import("ddl.zig");
const lexer = @import("query/lexer.zig");
const parser = @import("query/parser.zig");
const compiler = @import("query/compiler.zig");
const joiner = @import("query/joiner.zig");

pub const Decision = enum { allow, deny_locked, check };

/// The ONLY way to open a collection to everyone (allow-all). A rule must be set
/// to exactly this sentinel string to be public; an empty string is NOT public.
/// Safe-by-default: an unset (`null`) or blank (`""`) rule is locked to superusers.
pub const public_sentinel = "@public";

/// True if `rule` opens the collection to anyone (the `@public` sentinel).
pub fn isPublic(rule: ?[]const u8) bool {
    const r = rule orelse return false;
    return std.mem.eql(u8, r, public_sentinel);
}

/// Pure policy (safe-by-default):
///   superuser            -> allow
///   null rule            -> deny_locked  (superuser only)
///   "" (empty)           -> deny_locked  (locked too — NOT public)
///   "@public" sentinel   -> allow        (the only way to open a collection)
///   any other string     -> check        (compile + evaluate the expression per record)
pub fn decide(rule: ?[]const u8, rctx: *const request.RequestContext) Decision {
    if (rctx.is_superuser) return .allow;
    const r = rule orelse return .deny_locked;
    if (r.len == 0) return .deny_locked;
    if (std.mem.eql(u8, r, public_sentinel)) return .allow;
    return .check;
}

pub const RuleError = error{BadRule} || lexer.LexError || parser.ParseError || compiler.CompileError || db.DbError || std.mem.Allocator.Error || @typeInfo(@typeInfo(@TypeOf(joiner.Joiner.resolve)).@"fn".return_type.?).error_union.error_set;

/// Compile a `check`-state rule into a records.Guard (its own joiner; standalone guarded query).
/// Self-contained (contract 2): the lexer tokens, the parsed AST, and the joiner (its join-clause
/// strings + resolved target-collection graphs) are scratch consumed to produce the guard — none
/// escape. Build them on a function-local arena, then deep-clone the escaping graph (`where_sql` +
/// `joins` + `params`) onto `alloc` via `Guard.own`, so the returned Guard solely owns its bytes
/// and aliases neither the joiner's scratch nor the lexer's buffers. Free it with `Guard.deinit`.
/// (In production `alloc` is a request/rule arena, so the deep clone is a cheap extra copy reclaimed
/// wholesale at request end.)
pub fn compileGuard(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, rule: []const u8, rctx: *const request.RequestContext) RuleError!records.Guard {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const toks = try lexer.lex(sa, rule);
    const ast = try parser.parse(sa, toks);
    var j = joiner.Joiner.init(sa, conn, col);
    j.allow_hidden = true; // operator-authored rule: may gate access on a hidden field (trusted, not serialized)
    const c = try compiler.compile(sa, &j, ast, rctx, db.dbDialect(conn), &.{});
    return records.Guard.own(alloc, c.where_sql, j.joins.items, c.params);
}

/// True if `id`'s row satisfies a `check`-state rule (guarded SELECT 1).
/// Self-freeing (contract 1): the compiled guard, joins, SQL and `$n`-renumber are
/// all scratch consumed to run one `SELECT 1` — none escape the `bool` return — so
/// the function builds and frees them on a function-local arena. This makes it
/// leak-correct under ANY allocator (a general-purpose allocator, the test leak
/// detector) rather than relying on the caller passing an arena. (When `alloc` is
/// itself an arena — every production call site — the scratch lives and dies with
/// that arena as before; the deinit frees back into it, which is a no-op there.)
pub fn matches(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, id: []const u8, rule: []const u8, rctx: *const request.RequestContext) RuleError!bool {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const g = try compileGuard(sa, conn, col, rule, rctx);
    var joins: std.ArrayList(u8) = .empty;
    for (g.joins) |jn| {
        try joins.append(sa, ' ');
        try joins.appendSlice(sa, jn);
    }
    const qcol = try ddl.quoteIdent(sa, col.name);
    const sql = try std.fmt.allocPrintSentinel(sa, "SELECT 1 FROM {s}{s} WHERE {s}.\"id\"=?1 AND ({s});", .{ qcol, joins.items, qcol, g.where_sql }, 0);
    const param_sink = @import("sql/param_sink.zig");
    var st = try conn.prepare(try param_sink.renumberZ(sa, db.dbDialect(conn), sql));
    defer st.finalize();
    try st.bindText(1, id);
    _ = try records.bindParams(&st, g.params, 2);
    return try st.step();
}

test "decide: superuser/null/empty/@public/expr (safe-by-default)" {
    const su = request.RequestContext{ .is_superuser = true };
    const anon = request.RequestContext{};
    // superuser bypasses every rule, including null/empty/expr.
    try std.testing.expectEqual(Decision.allow, decide(null, &su));
    try std.testing.expectEqual(Decision.allow, decide("", &su));
    try std.testing.expectEqual(Decision.allow, decide("title = \"x\"", &su));
    // null -> locked (superuser only).
    try std.testing.expectEqual(Decision.deny_locked, decide(null, &anon));
    // "" is now LOCKED too — no longer allow-all (the old trap).
    try std.testing.expectEqual(Decision.deny_locked, decide("", &anon));
    // The explicit "@public" sentinel is the only way to open a collection.
    try std.testing.expectEqual(Decision.allow, decide(public_sentinel, &anon));
    try std.testing.expectEqual(Decision.allow, decide("@public", &anon));
    // any other string -> evaluate per record.
    try std.testing.expectEqual(Decision.check, decide("title = \"x\"", &anon));
}

test "isPublic: only the exact sentinel is public" {
    try std.testing.expect(isPublic("@public"));
    try std.testing.expect(!isPublic(null));
    try std.testing.expect(!isPublic(""));
    try std.testing.expect(!isPublic("title = \"x\""));
    try std.testing.expect(!isPublic("@publicx"));
}

test "matches runs a guarded select" {
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    const migrations = @import("migrations.zig");
    const collections = @import("collections.zig");
    try migrations.run(&d);
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }} });
    defer col.deinit(a);
    try d.exec("INSERT INTO posts (id,created,updated,title) VALUES ('r1','t','t','ok');");
    const anon = request.RequestContext{};
    try std.testing.expect(try matches(a, &d, col, "r1", "title = \"ok\"", &anon));
    try std.testing.expect(!try matches(a, &d, col, "r1", "title = \"no\"", &anon));
}
