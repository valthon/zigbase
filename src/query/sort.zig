const std = @import("std");
const joiner = @import("joiner.zig");
const schema = @import("../schema.zig");
const dialect_mod = @import("../sql/dialect.zig");
const Dialect = dialect_mod.Dialect;

pub const SortError = error{BadSort} || joiner.JoinError;

/// A single resolved ORDER BY term: the already-joined column SQL, its direction, the
/// resolved `schema.Field` (null for system columns id/created/updated, which bind as text),
/// and the bare field path (e.g. "created", "author.name") for cursor token (re)building.
/// Keyset pagination (`query/keyset.zig`) consumes these to emit a NULL-aware lexicographic
/// predicate and to bind boundary values through the same field-aware path as filter literals.
pub const SortTerm = struct {
    col_sql: []const u8,
    field: ?schema.Field,
    desc: bool,
    path: []const u8,
};

/// Resolve a comma-separated sort spec ("-created,author.name") into structured `SortTerm`s,
/// resolving relation paths via `j` (registering any joins on `j`). Empty spec -> empty slice.
/// This is the structured counterpart to `compile`; the latter is defined in terms of it.
pub fn compileTerms(alloc: std.mem.Allocator, j: *joiner.Joiner, spec: []const u8) SortError![]SortTerm {
    var terms: std.ArrayList(SortTerm) = .empty;
    errdefer terms.deinit(alloc);
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, " ");
        if (term.len == 0) continue;
        const desc = term[0] == '-';
        const path = if (desc or term[0] == '+') term[1..] else term;
        if (path.len == 0) return error.BadSort;
        const col = try j.resolve(path);
        try terms.append(alloc, .{ .col_sql = col.sql, .field = col.field, .desc = desc, .path = path });
    }
    return terms.toOwnedSlice(alloc);
}

/// Compile a comma-separated sort spec ("-created,author.name") into an ORDER BY fragment
/// (without the "ORDER BY" keywords), resolving relation paths via `j`. Empty -> "". `dialect`
/// adds the explicit `NULLS FIRST/LAST` Postgres needs to match SQLite's implicit NULL placement.
pub fn compile(alloc: std.mem.Allocator, j: *joiner.Joiner, spec: []const u8, dialect: Dialect) SortError![]u8 {
    const terms = try compileTerms(alloc, j, spec);
    // The SortTerm structs only borrow `col_sql`/`path` (owned by the joiner / input spec), so the
    // slice itself is the only thing compile() owns here — free it after building the string.
    defer alloc.free(terms);
    return orderByFromTerms(alloc, terms, dialect);
}

/// Build an ORDER BY fragment string (no "ORDER BY" keywords) from resolved terms.
/// Shared by `compile` and the keyset path, which appends an `id` tiebreaker term first.
/// On Postgres each term gets an explicit `NULLS FIRST/LAST` so its NULL placement matches
/// SQLite's implicit ordering (NULLs first ascending, last descending) — critical for keyset
/// pagination boundaries to line up across the two backends. SQLite emits no `NULLS` clause.
pub fn orderByFromTerms(alloc: std.mem.Allocator, terms: []const SortTerm, dialect: Dialect) SortError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (terms, 0..) |t, i| {
        if (i != 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, t.col_sql);
        try out.appendSlice(alloc, if (t.desc) " DESC" else " ASC");
        try out.appendSlice(alloc, dialect.nullsOrder(if (t.desc) .desc else .asc));
    }
    return out.toOwnedSlice(alloc);
}

test "sort compiles direction and relation paths" {
    const db = @import("../db.zig");
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
    const ob = try compile(a, &j, "-created,author.name", Dialect.sqlite);
    try std.testing.expectEqualStrings("\"posts\".\"created\" DESC, j1.\"name\" ASC", ob);
}

test "compile() frees its intermediate terms slice (no leak on the testing allocator)" {
    const db = @import("../db.zig");
    const migrations = @import("../migrations.zig");
    const collections = @import("../collections.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    // Use an ARENA only for the schema-setup churn (collections.create), but drive compile()
    // itself on the raw testing allocator so a leaked `terms` slice fails the test.
    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    const sa = setup.allocator();
    try migrations.run(&d);
    const pf = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    const posts = try collections.create(sa, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });

    const a = std.testing.allocator;
    var j = joiner.Joiner.init(sa, &d, posts); // joiner allocations live in the arena
    const ob = try compile(a, &j, "-created,price", Dialect.sqlite); // returned string owned by `a`
    defer a.free(ob);
    try std.testing.expectEqualStrings("\"posts\".\"created\" DESC, \"posts\".\"price\" ASC", ob);
    // Test teardown: std.testing.allocator panics if compile() leaked the `terms` slice.
}

test "compileTerms surfaces resolved col_sql, direction, and field per term" {
    const db = @import("../db.zig");
    const migrations = @import("../migrations.zig");
    const collections = @import("../collections.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const pf = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "price", .options = .{ .number = .{ .mode = .fixed, .scale = 2 } } },
    };
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });
    var j = joiner.Joiner.init(a, &d, posts);
    const terms = try compileTerms(a, &j, "-created,price");
    try std.testing.expectEqual(@as(usize, 2), terms.len);
    // system column "created": DESC, no schema.Field (binds as text)
    try std.testing.expectEqualStrings("\"posts\".\"created\"", terms[0].col_sql);
    try std.testing.expect(terms[0].desc);
    try std.testing.expect(terms[0].field == null);
    try std.testing.expectEqualStrings("created", terms[0].path);
    // user field "price": ASC, carries its fixed/2 field for value scaling
    try std.testing.expectEqualStrings("\"posts\".\"price\"", terms[1].col_sql);
    try std.testing.expect(!terms[1].desc);
    try std.testing.expect(terms[1].field != null);
    try std.testing.expectEqual(schema.FieldType.number, terms[1].field.?.fieldType());
    // and the string compiler still produces the same ORDER BY it always did.
    try std.testing.expectEqualStrings("\"posts\".\"created\" DESC, \"posts\".\"price\" ASC", try compile(a, &j, "-created,price", Dialect.sqlite));
}

test "sort error paths: bare sign, unknown column, empty" {
    const db = @import("../db.zig");
    const migrations = @import("../migrations.zig");
    const collections = @import("../collections.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }} });

    var j = joiner.Joiner.init(a, &d, posts);
    // A bare sign with no column is a bad sort spec.
    try std.testing.expectError(error.BadSort, compile(a, &j, "-", Dialect.sqlite));
    // Sorting on a nonexistent column propagates from the joiner.
    try std.testing.expectError(error.UnknownField, compile(a, &j, "nope", Dialect.sqlite));
    // Empty / whitespace-only spec yields an empty ORDER BY fragment.
    try std.testing.expectEqualStrings("", try compile(a, &j, "", Dialect.sqlite));
    try std.testing.expectEqualStrings("", try compile(a, &j, "   ", Dialect.sqlite));
}
