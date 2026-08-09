const std = @import("std");
const schema = @import("schema.zig");

/// Frozen change identifiers. The tag NAME is the wire value; append-only.
pub const ChangeKind = enum {
    create_collection,
    add_field,
    modify_field,
    rename_field,
    add_index,
    drop_index,
    modify_rules,
    modify_options,
    modify_index,
    // Destructive from here down.
    retype_field,
    drop_field,
    drop_collection,
};

pub fn isDestructive(k: ChangeKind) bool {
    return switch (k) {
        .retype_field, .drop_field, .drop_collection => true,
        else => false,
    };
}

pub const Change = struct {
    kind: ChangeKind,
    collection: []const u8,
    field: ?[]const u8 = null,
    /// Human context. NOT a contract — match on `kind`.
    detail: []const u8 = "",
};

pub const Deferred = struct { collection: []const u8, field: []const u8 };

pub const Plan = struct {
    changes: []const Change,
    untracked: []const []const u8,
    deferred: []const Deferred,
    order: []const usize,
    /// Owns every string and slice above. One arena, one free.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }

    pub fn hasDestructive(self: Plan) bool {
        for (self.changes) |c| if (isDestructive(c.kind)) return true;
        return false;
    }

    pub fn isDeferred(self: Plan, collection: []const u8, field: []const u8) bool {
        for (self.deferred) |d| {
            if (std.mem.eql(u8, d.collection, collection) and std.mem.eql(u8, d.field, field)) return true;
        }
        return false;
    }
};

pub const Options = struct { prune: bool = false };

/// Return `c` with the named fields removed. Strings are borrowed from `c`; only the
/// fields array is allocated (on `sa`).
pub fn withoutFields(sa: std.mem.Allocator, c: schema.Collection, drop: []const []const u8) !schema.Collection {
    var kept: std.ArrayList(schema.Field) = .empty;
    outer: for (c.fields) |f| {
        for (drop) |d| if (std.mem.eql(u8, f.name, d)) continue :outer;
        try kept.append(sa, f);
    }
    var out = c;
    out.fields = try kept.toOwnedSlice(sa);
    return out;
}

fn findByName(cols: []const schema.Collection, name: []const u8) ?schema.Collection {
    for (cols) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

pub fn indexByName(cols: []const schema.Collection, name: []const u8) ?usize {
    for (cols, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) return i;
    return null;
}

/// Fields match by stable id when both sides carry one (that is what `ddl.rebuildPlan`
/// matches on), else by name — so a hand-written document with `"id": ""` still lines up
/// with the live column instead of reading as drop+add.
fn matchField(fields: []const schema.Field, want: schema.Field) ?schema.Field {
    if (want.id.len > 0) {
        for (fields) |f| if (f.id.len > 0 and std.mem.eql(u8, f.id, want.id)) return f;
    }
    for (fields) |f| if (std.mem.eql(u8, f.name, want.name)) return f;
    return null;
}

/// Structural equality by serialization, identity-independent: compare each field through
/// the SAME serializer the engine persists with, but strip id and name first so a hand-written
/// doc with `"id": ""` matches a live field with a real stable id. This avoids phantom
/// modify_field when matchField pairs by name and both sides have identical structure.
/// A hand-written 12-arm comparator would silently miss every option added later; this cannot.
fn fieldEql(sa: std.mem.Allocator, x: schema.Field, y: schema.Field) !bool {
    var x_norm = x;
    var y_norm = y;
    x_norm.id = "";
    y_norm.id = "";
    x_norm.name = "";
    y_norm.name = "";
    const a = try schema.fieldsToJson(sa, &.{x_norm});
    const b = try schema.fieldsToJson(sa, &.{y_norm});
    return std.mem.eql(u8, a, b);
}

/// A blank rule — `null` OR `""` — both mean Locked (superusers only), so they are the
/// same value and must not produce a phantom change.
fn ruleEql(x: ?[]const u8, y: ?[]const u8) bool {
    const xs = x orelse "";
    const ys = y orelse "";
    return std.mem.eql(u8, xs, ys);
}

fn rulesEql(x: schema.Collection, y: schema.Collection) bool {
    return ruleEql(x.listRule, y.listRule) and ruleEql(x.viewRule, y.viewRule) and
        ruleEql(x.createRule, y.createRule) and ruleEql(x.updateRule, y.updateRule) and
        ruleEql(x.deleteRule, y.deleteRule);
}

fn findIndex(idx: []const schema.Index, name: []const u8) ?schema.Index {
    for (idx) |i| if (std.mem.eql(u8, i.name, name)) return i;
    return null;
}

/// Structural equality by serialization, for the same reason `fieldEql` does it: an index
/// carries `fields`, `unique`, `collation` and `where` besides its name, and a hand-written
/// N-arm comparator would silently stop seeing whatever key `schema.Index` gains next.
/// Comparing by name alone made `unique: false -> true` (and every other redefinition) an
/// invisible change: an empty plan, `applied: []`, and a dry run reporting "settled" while
/// the live index still had the old shape.
fn indexEql(sa: std.mem.Allocator, x: schema.Index, y: schema.Index) !bool {
    const a = try schema.indexesToJson(sa, &.{x});
    const b = try schema.indexesToJson(sa, &.{y});
    return std.mem.eql(u8, a, b);
}

/// Emit each collection only after every collection it points at, and report the relation
/// edges that had to be broken. Public because the data pump needs the same ordering and
/// the same back-edge list that the DDL pump does.
pub fn orderWithCycles(
    sa: std.mem.Allocator,
    cols: []const schema.Collection,
    order: *std.ArrayList(usize),
    back: *std.ArrayList(Deferred),
) !void {
    const state = try sa.alloc(u8, cols.len); // 0 = unseen, 1 = on stack, 2 = done
    @memset(state, 0);

    const W = struct {
        fn visit(
            all: []const schema.Collection,
            st: []u8,
            ord: *std.ArrayList(usize),
            bk: *std.ArrayList(Deferred),
            a: std.mem.Allocator,
            i: usize,
        ) !void {
            if (st[i] != 0) return;
            st[i] = 1;
            for (all[i].fields) |f| {
                if (f.options != .relation) continue;
                const target = f.options.relation.targetCollectionId;
                if (std.mem.eql(u8, target, all[i].name)) continue; // self-relation: not an edge
                const j = indexByName(all, target) orelse continue; // target lives outside the doc
                if (st[j] == 1) {
                    // Back edge into a collection still on the stack: a real cycle.
                    try bk.append(a, .{ .collection = all[i].name, .field = f.name });
                    continue;
                }
                try visit(all, st, ord, bk, a, j);
            }
            st[i] = 2;
            try ord.append(a, i);
        }
    };
    for (0..cols.len) |i| try W.visit(cols, state, order, back, sa, i);
}

/// Compute the plan. `live` must already be filtered to non-system collections.
pub fn compute(
    alloc: std.mem.Allocator,
    live: []const schema.Collection,
    doc: []const schema.Collection,
    opts: Options,
) !Plan {
    var arena = std.heap.ArenaAllocator.init(alloc);
    // The plan OWNS this arena on success; on any error below it must not leak.
    errdefer arena.deinit();
    const sa = arena.allocator();

    var changes: std.ArrayList(Change) = .empty;
    var untracked: std.ArrayList([]const u8) = .empty;
    var deferred: std.ArrayList(Deferred) = .empty;
    var order: std.ArrayList(usize) = .empty;

    for (doc) |want| {
        const have = findByName(live, want.name) orelse {
            try changes.append(sa, .{ .kind = .create_collection, .collection = want.name });
            continue;
        };

        for (want.fields) |wf| {
            const hf = matchField(have.fields, wf) orelse {
                try changes.append(sa, .{ .kind = .add_field, .collection = want.name, .field = wf.name });
                continue;
            };
            if (hf.fieldType() != wf.fieldType() or hf.storageClass() != wf.storageClass()) {
                try changes.append(sa, .{
                    .kind = .retype_field,
                    .collection = want.name,
                    .field = wf.name,
                    .detail = try std.fmt.allocPrint(sa, "{s} -> {s}", .{ @tagName(hf.fieldType()), @tagName(wf.fieldType()) }),
                });
                continue;
            }
            if (!std.mem.eql(u8, hf.name, wf.name)) {
                try changes.append(sa, .{
                    .kind = .rename_field,
                    .collection = want.name,
                    .field = wf.name,
                    .detail = try std.fmt.allocPrint(sa, "{s} -> {s}", .{ hf.name, wf.name }),
                });
                continue;
            }
            if (!try fieldEql(sa, hf, wf)) {
                try changes.append(sa, .{ .kind = .modify_field, .collection = want.name, .field = wf.name });
            }
        }

        // A live field the document omits is a DROP (silent data loss on rebuild).
        for (have.fields) |hf| {
            if (schema.isSystemFieldName(hf.name)) continue; // re-injected by the engine
            if (matchField(want.fields, hf) == null) {
                try changes.append(sa, .{ .kind = .drop_field, .collection = want.name, .field = hf.name });
            }
        }

        for (want.indexes) |wi| {
            const hi = findIndex(have.indexes, wi.name) orelse {
                try changes.append(sa, .{ .kind = .add_index, .collection = want.name, .detail = wi.name });
                continue;
            };
            // Same name: only a change if the definition (columns, uniqueness, collation,
            // predicate) actually differs, so a converged doc reports no phantom change.
            if (!try indexEql(sa, hi, wi))
                try changes.append(sa, .{ .kind = .modify_index, .collection = want.name, .detail = wi.name });
        }
        for (have.indexes) |hi| {
            if (findIndex(want.indexes, hi.name) == null)
                try changes.append(sa, .{ .kind = .drop_index, .collection = want.name, .detail = hi.name });
        }

        if (!rulesEql(have, want))
            try changes.append(sa, .{ .kind = .modify_rules, .collection = want.name });

        // Both sides redacted, so a redacted OAuth secret can never look like a change.
        const have_opts = try schema.optionsToJson(sa, have, true);
        const want_opts = try schema.optionsToJson(sa, want, true);
        if (!std.mem.eql(u8, have_opts, want_opts))
            try changes.append(sa, .{ .kind = .modify_options, .collection = want.name });
    }

    for (live) |l| {
        if (findByName(doc, l.name) != null) continue;
        if (opts.prune) {
            try changes.append(sa, .{ .kind = .drop_collection, .collection = try sa.dupe(u8, l.name) });
        } else {
            try untracked.append(sa, try sa.dupe(u8, l.name));
        }
    }

    try orderWithCycles(sa, doc, &order, &deferred);

    return .{
        .changes = try changes.toOwnedSlice(sa),
        .untracked = try untracked.toOwnedSlice(sa),
        .deferred = try deferred.toOwnedSlice(sa),
        .order = try order.toOwnedSlice(sa),
        .arena = arena,
    };
}

fn textField(id: []const u8, name: []const u8) schema.Field {
    return .{ .id = id, .name = name, .options = .{ .text = .{} } };
}

fn relField(id: []const u8, name: []const u8, target: []const u8) schema.Field {
    return .{ .id = id, .name = name, .options = .{ .relation = .{ .targetCollectionId = target } } };
}

fn col(name: []const u8, fields: []const schema.Field) schema.Collection {
    return .{ .id = "", .name = name, .fields = fields };
}

test "an unchanged schema produces an empty plan" {
    const a = std.testing.allocator;
    const live = [_]schema.Collection{col("posts", &.{textField("aaaaaaaa", "title")})};
    const doc = [_]schema.Collection{col("posts", &.{textField("aaaaaaaa", "title")})};
    var p = try compute(a, &live, &doc, .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.changes.len);
    try std.testing.expectEqual(@as(usize, 0), p.untracked.len);
    try std.testing.expect(!p.hasDestructive());
}

test "a new collection and a new field are non-destructive" {
    const a = std.testing.allocator;
    const live = [_]schema.Collection{col("posts", &.{textField("aaaaaaaa", "title")})};
    const doc = [_]schema.Collection{
        col("posts", &.{ textField("aaaaaaaa", "title"), textField("", "body") }),
        col("tags", &.{textField("cccccccc", "label")}),
    };
    var p = try compute(a, &live, &doc, .{});
    defer p.deinit();
    try std.testing.expect(!p.hasDestructive());
    var saw_add_field = false;
    var saw_create = false;
    for (p.changes) |c| {
        if (c.kind == .add_field and std.mem.eql(u8, c.field.?, "body")) saw_add_field = true;
        if (c.kind == .create_collection and std.mem.eql(u8, c.collection, "tags")) saw_create = true;
    }
    try std.testing.expect(saw_add_field and saw_create);
}

test "a retype and a dropped field are destructive; a rename is not" {
    const a = std.testing.allocator;
    const live = [_]schema.Collection{col("posts", &.{
        textField("aaaaaaaa", "views"),
        textField("bbbbbbbb", "title"),
        textField("cccccccc", "gone"),
    })};
    const doc = [_]schema.Collection{col("posts", &.{
        .{ .id = "aaaaaaaa", .name = "views", .options = .{ .number = .{ .mode = .int } } },
        textField("bbbbbbbb", "headline"), // same stable id, new name => rename
    })};
    var p = try compute(a, &live, &doc, .{});
    defer p.deinit();
    try std.testing.expect(p.hasDestructive());

    var kinds = std.EnumSet(ChangeKind).initEmpty();
    for (p.changes) |c| kinds.insert(c.kind);
    try std.testing.expect(kinds.contains(.retype_field));
    try std.testing.expect(kinds.contains(.drop_field));
    try std.testing.expect(kinds.contains(.rename_field));
    try std.testing.expect(!isDestructive(.rename_field));
}

test "a live collection absent from the document is untracked, or a drop under --prune" {
    const a = std.testing.allocator;
    const live = [_]schema.Collection{
        col("posts", &.{textField("aaaaaaaa", "title")}),
        col("legacy", &.{textField("dddddddd", "junk")}),
    };
    const doc = [_]schema.Collection{col("posts", &.{textField("aaaaaaaa", "title")})};

    var keep = try compute(a, &live, &doc, .{});
    defer keep.deinit();
    try std.testing.expectEqual(@as(usize, 0), keep.changes.len);
    try std.testing.expectEqual(@as(usize, 1), keep.untracked.len);
    try std.testing.expectEqualStrings("legacy", keep.untracked[0]);
    try std.testing.expect(!keep.hasDestructive());

    var pruned = try compute(a, &live, &doc, .{ .prune = true });
    defer pruned.deinit();
    try std.testing.expectEqual(@as(usize, 1), pruned.changes.len);
    try std.testing.expectEqual(ChangeKind.drop_collection, pruned.changes[0].kind);
    try std.testing.expect(pruned.hasDestructive());
}

test "rules and options changes are reported; null and empty rules are the same value" {
    const a = std.testing.allocator;
    var live_c = col("posts", &.{textField("aaaaaaaa", "title")});
    live_c.listRule = null;
    var doc_c = col("posts", &.{textField("aaaaaaaa", "title")});
    doc_c.listRule = ""; // blank and null both mean Locked — not a change
    {
        var p = try compute(a, &.{live_c}, &.{doc_c}, .{});
        defer p.deinit();
        try std.testing.expectEqual(@as(usize, 0), p.changes.len);
    }
    doc_c.listRule = "@public";
    var p = try compute(a, &.{live_c}, &.{doc_c}, .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.changes.len);
    try std.testing.expectEqual(ChangeKind.modify_rules, p.changes[0].kind);
}

test "hand-written docs omitting stable field id do not produce phantom modify_field" {
    const a = std.testing.allocator;
    const live = [_]schema.Collection{col("posts", &.{
        .{ .id = "aaaaaaaa", .name = "title", .options = .{ .text = .{} } },
    })};
    const doc = [_]schema.Collection{col("posts", &.{
        .{ .id = "", .name = "title", .options = .{ .text = .{} } },
    })};
    var p = try compute(a, &live, &doc, .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.changes.len); // no phantom modify_field
}

test "creation order puts relation targets first" {
    const a = std.testing.allocator;
    const doc = [_]schema.Collection{
        col("posts", &.{relField("aaaaaaaa", "author", "authors")}),
        col("authors", &.{textField("bbbbbbbb", "nom")}),
    };
    var p = try compute(a, &.{}, &doc, .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.order.len);
    try std.testing.expectEqual(@as(usize, 1), p.order[0]); // authors
    try std.testing.expectEqual(@as(usize, 0), p.order[1]); // posts
    try std.testing.expectEqual(@as(usize, 0), p.deferred.len);
}

test "a relation cycle reports a deferred back edge; a self-relation does not" {
    const a = std.testing.allocator;
    const cyc = [_]schema.Collection{
        col("a", &.{relField("aaaaaaaa", "toB", "b")}),
        col("b", &.{relField("bbbbbbbb", "toA", "a")}),
    };
    var p = try compute(a, &.{}, &cyc, .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.order.len);
    try std.testing.expectEqual(@as(usize, 1), p.deferred.len);

    // Exact deferred edge: b.toA (back to a). Which edge of the cycle becomes the deferred one
    // is deterministic-but-arbitrary, depending on DFS visit order — but once deferred, it
    // imposes no ordering constraint at all: it is simply omitted from pass 1. The only edge
    // left live is a.toB -> b, and that one requires b to be created before a — that's the
    // FK-safety invariant pass 1 must uphold.
    try std.testing.expectEqualStrings("b", p.deferred[0].collection);
    try std.testing.expectEqualStrings("toA", p.deferred[0].field);

    // Order is a permutation: must contain every index [0..1] exactly once.
    var seen = [_]bool{false} ** 2;
    for (p.order) |idx| {
        try std.testing.expect(idx < 2);
        try std.testing.expect(!seen[idx]); // no duplicate
        seen[idx] = true;
    }
    try std.testing.expect(seen[0] and seen[1]); // all indices present

    // Invariant: b (index 1) is created before a (index 0) — the live edge a.toB -> b demands it.
    // This holds no matter which edge got deferred above, because the deferred edge (b.toA) is
    // omitted from pass 1 and so cannot constrain order.
    try std.testing.expectEqual(@as(usize, 1), p.order[0]); // b created first
    try std.testing.expectEqual(@as(usize, 0), p.order[1]); // a created second

    // A self-relation is fine: the FK targets the very table being created.
    const selfrel = [_]schema.Collection{col("tree", &.{relField("cccccccc", "parent", "tree")})};
    var q = try compute(a, &.{}, &selfrel, .{});
    defer q.deinit();
    try std.testing.expectEqual(@as(usize, 0), q.deferred.len);
}

test "a redefined index is a modify_index; add/drop still key off the name" {
    const a = std.testing.allocator;
    const live_idx = [_]schema.Index{
        .{ .name = "idx_slug", .fields = &.{"slug"}, .unique = false },
        .{ .name = "idx_gone", .fields = &.{"old"} },
    };
    const want_idx = [_]schema.Index{
        .{ .name = "idx_slug", .fields = &.{"slug"}, .unique = true }, // same name, now UNIQUE
        .{ .name = "idx_new", .fields = &.{"body"} },
    };
    var live_c = col("posts", &.{ textField("aaaaaaaa", "slug"), textField("bbbbbbbb", "body") });
    live_c.indexes = &live_idx;
    var want_c = col("posts", &.{ textField("aaaaaaaa", "slug"), textField("bbbbbbbb", "body") });
    want_c.indexes = &want_idx;

    var p = try compute(a, &.{live_c}, &.{want_c}, .{});
    defer p.deinit();

    var kinds = std.EnumSet(ChangeKind).initEmpty();
    var modified_name: []const u8 = "";
    for (p.changes) |c| {
        kinds.insert(c.kind);
        if (c.kind == .modify_index) modified_name = c.detail;
    }
    try std.testing.expect(kinds.contains(.modify_index));
    try std.testing.expect(kinds.contains(.add_index));
    try std.testing.expect(kinds.contains(.drop_index));
    try std.testing.expectEqualStrings("idx_slug", modified_name);
    // Non-destructive: rewriting an index definition never drops a column or a table.
    try std.testing.expect(!isDestructive(.modify_index));
    try std.testing.expect(!p.hasDestructive());

    // An identical index set is not a change (no phantom modify_index on a converged doc).
    var same = try compute(a, &.{live_c}, &.{live_c}, .{});
    defer same.deinit();
    try std.testing.expectEqual(@as(usize, 0), same.changes.len);
}

test "exactly three change kinds are destructive" {
    // `isDestructive`'s boundary is load-bearing: exit code 2, the --allow-destructive gate
    // and the documented kind table all key off it. A kind appended in the wrong place would
    // silently move that boundary, so pin the whole enum rather than the three members.
    var n: usize = 0;
    inline for (@typeInfo(ChangeKind).@"enum".fields) |f| {
        if (isDestructive(@field(ChangeKind, f.name))) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(isDestructive(.retype_field));
    try std.testing.expect(isDestructive(.drop_field));
    try std.testing.expect(isDestructive(.drop_collection));
}

test "withoutFields removes exactly the named fields" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const c = col("a", &.{ textField("1", "keep"), relField("2", "drop", "b"), textField("3", "also") });
    const trimmed = try withoutFields(arena.allocator(), c, &.{"drop"});
    try std.testing.expectEqual(@as(usize, 2), trimmed.fields.len);
    try std.testing.expectEqualStrings("keep", trimmed.fields[0].name);
    try std.testing.expectEqualStrings("also", trimmed.fields[1].name);
}
