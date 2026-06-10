const std = @import("std");
const db = @import("../db.zig");
const schema = @import("../schema.zig");
const collections = @import("../collections.zig");

pub const JoinError = error{ UnknownField, NotARelation, MultiRelationTraversal } || db.DbError || std.mem.Allocator.Error || @typeInfo(@typeInfo(@TypeOf(collections.get)).@"fn".return_type.?).error_union.error_set;

pub const ColumnRef = struct { sql: []const u8, field: ?schema.Field };

pub const Joiner = struct {
    alloc: std.mem.Allocator,
    conn: *db.Db,
    base: schema.Collection,
    joins: std.ArrayList([]const u8) = .empty,
    seen: std.ArrayList(Seen) = .empty,
    counter: usize = 0,

    const Seen = struct { prefix: []const u8, alias: []const u8, col: schema.Collection };

    pub fn init(alloc: std.mem.Allocator, conn: *db.Db, base: schema.Collection) Joiner {
        return .{ .alloc = alloc, .conn = conn, .base = base };
    }

    pub fn resolve(self: *Joiner, path: []const u8) JoinError!ColumnRef {
        var cur_col = self.base;
        var cur_alias = try std.fmt.allocPrint(self.alloc, "\"{s}\"", .{self.base.name});
        var prefix_buf: std.ArrayList(u8) = .empty;

        var it = std.mem.splitScalar(u8, path, '.');
        var seg = it.next().?;
        while (true) {
            const nxt = it.next();
            if (nxt == null) {
                const field = schema.fieldByName(cur_col, seg);
                if (field == null and !isSystemCol(seg)) return error.UnknownField;
                const ref = try std.fmt.allocPrint(self.alloc, "{s}.\"{s}\"", .{ cur_alias, seg });
                return .{ .sql = ref, .field = field };
            }
            const rf = schema.fieldByName(cur_col, seg) orelse return error.UnknownField;
            if (rf.fieldType() != .relation) return error.NotARelation;
            if (rf.isMultiValue()) return error.MultiRelationTraversal;
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }} });
    const pf = [_]schema.Field{
        .{ .id = "f1", .name = "title", .options = .{ .text = .{} } },
        .{ .id = "f2", .name = "tags", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 9 } } },
    };
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });

    var j = Joiner.init(a, &d, posts);
    // Traversing THROUGH a text field (title is not a relation).
    try std.testing.expectError(error.NotARelation, j.resolve("title.x"));
    // Traversing THROUGH a multi-value relation is unsupported.
    try std.testing.expectError(error.MultiRelationTraversal, j.resolve("tags.name"));
}
