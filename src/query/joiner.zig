const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");
const ddl = @import("../ddl.zig");

pub const JoinError = error{ UnknownField, NotARelation, MultiRelationTraversal, EncryptedField, HiddenField } || db.DbError || std.mem.Allocator.Error || @typeInfo(@typeInfo(@TypeOf(collections.get)).@"fn".return_type.?).error_union.error_set;

/// A resolved column reference. `nocase` is true when the column is covered by a `.nocase` index
/// on its (possibly joined) collection — the compiler then lowers an equality/IN compare so it
/// agrees with the case-insensitive uniqueness (Postgres `lower()`; SQLite unchanged) (#159).
pub const ColumnRef = struct { sql: []const u8, field: ?schema.Field, nocase: bool = false };

pub const Joiner = struct {
    alloc: std.mem.Allocator,
    /// Owns every per-resolve intermediate that never escapes the joiner's own lifetime: the
    /// `cur_alias`/`prefix_buf`/`ColumnRef.sql` fragments, the join-clause strings appended to
    /// `joins`, the deduped `seen[i].prefix`, and the `collections.get` target collection graphs
    /// stored in `seen[i].col` (which back every `ColumnRef.field`). Reclaimed wholesale by
    /// `deinit`. The `joins`/`seen` LIST BACKINGS deliberately live on `alloc` instead (see
    /// `deinit`) because external callers grow `joins` with the SAME `alloc` (e.g. records.list
    /// appends its FTS join clause), so a single owning allocator for that list is required.
    scratch: std.heap.ArenaAllocator,
    conn: *db.Db,
    base: schema.Collection,
    joins: std.ArrayList([]const u8) = .empty,
    seen: std.ArrayList(Seen) = .empty,
    counter: usize = 0,
    /// When true, references to hidden fields are permitted. Set ONLY for trusted, operator-authored
    /// access rules (a server-side WHERE clause whose truth is never serialized to the client, so it
    /// is no boolean oracle). Client-controlled `?filter=`/`?sort=` leave this false so a hidden field
    /// is still rejected closed. Encrypted fields stay rejected regardless (they can never match).
    allow_hidden: bool = false,

    const Seen = struct { prefix: []const u8, alias: []const u8, col: schema.Collection };

    pub fn init(alloc: std.mem.Allocator, conn: *db.Db, base: schema.Collection) Joiner {
        return .{ .alloc = alloc, .scratch = std.heap.ArenaAllocator.init(alloc), .conn = conn, .base = base };
    }

    /// Release everything the joiner allocated: the `joins`/`seen` list backings (on `alloc`) and
    /// the scratch arena (every string fragment + `seen` collection graph). The escaping product is
    /// `joins.items` (the join-clause strings the compiler reads) plus any `ColumnRef` returned by
    /// `resolve`; both point into the scratch arena, so a caller that keeps them past `deinit` must
    /// dupe them first. Every production caller passes a request/rule arena as `alloc` and simply
    /// lets that arena reclaim the whole joiner, so they never call `deinit` — it exists so the
    /// leak-detecting test allocator can verify the joiner is honest.
    pub fn deinit(self: *Joiner) void {
        self.joins.deinit(self.alloc);
        self.seen.deinit(self.alloc);
        self.scratch.deinit();
    }

    pub fn resolve(self: *Joiner, path: []const u8) JoinError!ColumnRef {
        const sa = self.scratch.allocator();
        var cur_col = self.base;
        var cur_alias = try std.fmt.allocPrint(sa, "\"{s}\"", .{self.base.name});
        var prefix_buf: std.ArrayList(u8) = .empty;

        var it = std.mem.splitScalar(u8, path, '.');
        var seg = it.next().?;
        while (true) {
            const nxt = it.next();
            if (nxt == null) {
                const field = schema.fieldByName(cur_col, seg);
                if (field == null and !isSystemCol(seg)) return error.UnknownField;
                // Encrypted fields are stored as per-row-nonce ciphertext, so a
                // filter/sort over them can never match correctly — reject closed.
                //
                // Hidden fields (passwordHash, tokenKey, token_epoch, any `.hidden`
                // user field) are never serialized (`rowToObject` strips them), so a
                // CLIENT filter/sort that references one would let match/no-match presence
                // act as a boolean oracle over a secret the API deliberately withholds —
                // reject closed. Trusted, operator-authored rules set `allow_hidden` (their
                // truth is never serialized), so a `.hidden` field can still gate access.
                if (field) |fl| {
                    if (fl.encrypted) return error.EncryptedField;
                    if (fl.hidden and !self.allow_hidden) return error.HiddenField;
                }
                const ref = try std.fmt.allocPrint(sa, "{s}.\"{s}\"", .{ cur_alias, seg });
                return .{ .sql = ref, .field = field, .nocase = ddl.isNocaseField(cur_col, seg) };
            }
            const rf = schema.fieldByName(cur_col, seg) orelse return error.UnknownField;
            // A hidden relation is non-serialized too: traversing THROUGH it would still let a
            // client filter oracle its foreign key. Reject closed here (trusted rules excepted,
            // symmetric with the leaf check).
            if (rf.hidden and !self.allow_hidden) return error.HiddenField;
            if (rf.fieldType() != .relation) return error.NotARelation;
            if (rf.isMultiValue()) return error.MultiRelationTraversal;
            if (prefix_buf.items.len > 0) try prefix_buf.append(sa, '.');
            try prefix_buf.appendSlice(sa, seg);
            const prefix = prefix_buf.items;
            if (self.find(prefix)) |s| {
                cur_alias = try sa.dupe(u8, s.alias);
                cur_col = s.col;
            } else {
                const target = (try collections.get(sa, self.conn, rf.options.relation.targetCollectionId)) orelse return error.UnknownField;
                self.counter += 1;
                const alias = try std.fmt.allocPrint(sa, "j{d}", .{self.counter});
                const join = try std.fmt.allocPrint(sa, "LEFT JOIN \"{s}\" AS {s} ON {s}.\"{s}\" = {s}.\"id\"", .{ target.name, alias, cur_alias, seg, alias });
                try self.joins.append(self.alloc, join);
                try self.seen.append(self.alloc, .{ .prefix = try sa.dupe(u8, prefix), .alias = alias, .col = target });
                cur_alias = alias;
                cur_col = target;
            }
            seg = nxt.?;
        }
    }

    fn find(self: *Joiner, prefix: []const u8) ?Seen {
        for (self.seen.items) |s| {
            if (std.mem.eql(u8, s.prefix, prefix)) return s;
        }
        return null;
    }
};

fn isSystemCol(s: []const u8) bool {
    return std.mem.eql(u8, s, "id") or std.mem.eql(u8, s, "created") or std.mem.eql(u8, s, "updated");
}

test "joiner rejects traversal through non-relation and multi-relation fields" {
    const migrations = @import("../migrations.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    try migrations.run(&d);
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }} });
    defer users.deinit(a);
    const pf = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "tags", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 9 } } },
    };
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });
    defer posts.deinit(a);

    var j = Joiner.init(a, &d, posts);
    defer j.deinit();
    // Traversing THROUGH a text field (title is not a relation).
    try std.testing.expectError(error.NotARelation, j.resolve("title.x"));
    // Traversing THROUGH a multi-value relation is unsupported.
    try std.testing.expectError(error.MultiRelationTraversal, j.resolve("tags.name"));
}

test "joiner rejects filtering/sorting on an encrypted field" {
    const migrations = @import("../migrations.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    try migrations.run(&d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "secret", .encrypted = true, .options = .{ .text = .{} } },
    };
    const docs = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "docs", .fields = &fields });
    defer docs.deinit(a);
    var j = Joiner.init(a, &d, docs);
    defer j.deinit();
    // A normal field resolves; an encrypted field is rejected closed.
    _ = try j.resolve("title");
    try std.testing.expectError(error.EncryptedField, j.resolve("secret"));
}

test "joiner rejects filtering/sorting on a hidden field (no boolean oracle over non-serialized secrets)" {
    const migrations = @import("../migrations.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    const a = std.testing.allocator;
    try migrations.run(&d);
    const fields = [_]schema.Field{
        .{ .id = "f1", .name = "name", .options = .{ .text = .{} } },
        // A hidden field mirrors passwordHash/tokenKey on auth collections: stored but
        // never serialized, so it must not be referenceable in filter/sort/rule.
        .{ .id = "f2", .name = "secret", .hidden = true, .options = .{ .text = .{} } },
    };
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users2", .fields = &fields });
    defer users.deinit(a);
    var j = Joiner.init(a, &d, users);
    defer j.deinit();
    // A visible field resolves; a hidden field is rejected closed (no partial leak).
    _ = try j.resolve("name");
    try std.testing.expectError(error.HiddenField, j.resolve("secret"));
    // System columns (id/created/updated) remain filterable — the block is exactly the hidden set.
    _ = try j.resolve("id");

    // A TRUSTED, operator-authored rule (allow_hidden) MAY gate access on that hidden field: its
    // truth is a server-side WHERE clause, never serialized, so it is no boolean oracle.
    var jr = Joiner.init(a, &d, users);
    defer jr.deinit();
    jr.allow_hidden = true;
    _ = try jr.resolve("secret");
}
