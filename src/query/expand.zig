const std = @import("std");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const schema = @import("../schema.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const policy = @import("../policy.zig");
const request = @import("../request.zig");

const max_depth = 6;

/// Explicit error set so the mutual recursion between `expand` and `expandField`
/// does not produce an inferred-error-set dependency loop.
pub const ExpandError = records.RecordError || collections.EngineError || policy.PolicyError;

/// Expand the given comma-separated, dot-nested expand-spec ("author,tags.owner") into
/// `rec.object`'s "expand" key. `rec` must be a `.object`. Single relations nest an object;
/// multi nest an array. Depth-guarded.
///
/// LIMITATION: when multiple expand paths share a head (e.g. "author.org,author.name"),
/// `head` is expanded once per comma-segment and the later segment overwrites the earlier.
pub fn expand(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, rec: *std.json.Value, spec: []const u8, depth: usize, rctx: *const request.RequestContext) ExpandError!void {
    if (depth >= max_depth or rec.* != .object) return;
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
        const nested = try expandField(alloc, conn, target, id_val, rest, depth, rctx);
        try expand_obj.put(alloc, head, nested);
        any = true;
    }
    if (any) try rec.object.put(alloc, "expand", .{ .object = expand_obj });
}

/// Whether `rctx` is permitted to view record `id` of `target` under `target.viewRule`.
/// Mirrors the view handler in src/api/records.zig: superuser/empty-rule => allow,
/// null rule => deny, otherwise the row must satisfy the rule. This is what closes the
/// access-control bypass where a public collection's relation leaked a locked target.
/// Routed through `policy.*` so PR2 tenant-scope + PR3 abilities cover `?expand=` too.
fn canView(alloc: std.mem.Allocator, conn: *db.Db, target: schema.Collection, id: []const u8, rctx: *const request.RequestContext) ExpandError!bool {
    return policy.authorizes(alloc, conn, target, .view, id, rctx);
}

fn expandField(alloc: std.mem.Allocator, conn: *db.Db, target: schema.Collection, id_val: std.json.Value, rest: []const u8, depth: usize, rctx: *const request.RequestContext) ExpandError!std.json.Value {
    switch (id_val) {
        .string => |id| {
            if (!try canView(alloc, conn, target, id, rctx)) return .null;
            var sub = (try records.get(alloc, conn, target, id)) orelse return .null;
            if (rest.len > 0) try expand(alloc, conn, target, &sub, rest, depth + 1, rctx);
            return sub;
        },
        .array => |arr| {
            var out = std.json.Array.init(alloc);
            for (arr.items) |item| if (item == .string) {
                if (!try canView(alloc, conn, target, item.string, rctx)) continue;
                var sub = (try records.get(alloc, conn, target, item.string)) orelse continue;
                if (rest.len > 0) try expand(alloc, conn, target, &sub, rest, depth + 1, rctx);
                try out.append(sub);
            };
            return .{ .array = out };
        },
        else => return .null,
    }
}

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
    const su = request.RequestContext{ .is_superuser = true };
    try expand(a, &d, posts, &rec, "author", 0, &su);
    const exp = rec.object.get("expand").?.object;
    try std.testing.expectEqualStrings("Ada", exp.get("author").?.object.get("name").?.string);
}

test "expand nests two hops (author.org)" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const orgs = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "orgs", .fields = &[_]schema.Field{.{ .id = "o1", .name = "label", .options = .{ .text = .{} } }} });
    const uf = [_]schema.Field{
        .{ .id = "u1", .name = "name", .options = .{ .text = .{} } },
        .{ .id = "u2", .name = "org", .options = .{ .relation = .{ .targetCollectionId = orgs.id, .maxSelect = 1 } } },
    };
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &uf });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf });
    try d.exec("INSERT INTO orgs (id,created,updated,label) VALUES ('o_1','t','t','Acme');");
    try d.exec("INSERT INTO users (id,created,updated,name,org) VALUES ('u_1','t','t','Ada','o_1');");
    try d.exec("INSERT INTO posts (id,created,updated,author) VALUES ('p_1','t','t','u_1');");

    var rec = (try records.get(a, &d, posts, "p_1")).?;
    const su = request.RequestContext{ .is_superuser = true };
    try expand(a, &d, posts, &rec, "author.org", 0, &su);
    const author = rec.object.get("expand").?.object.get("author").?.object;
    const org = author.get("expand").?.object.get("org").?.object;
    try std.testing.expectEqualStrings("Acme", org.get("label").?.string);
}

test "H1: expand enforces the target collection's viewRule" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    // secrets has a NULL viewRule -> superuser-only (locked). posts is public and
    // relates to secrets; without the fix anyone expanding `owner` would read it.
    const secrets = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "secrets", .fields = &[_]schema.Field{.{ .id = "s1", .name = "ssn", .options = .{ .text = .{} } }}, .viewRule = null });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "owner", .options = .{ .relation = .{ .targetCollectionId = secrets.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf, .viewRule = "" });
    try d.exec("INSERT INTO secrets (id,created,updated,ssn) VALUES ('s_1','t','t','111-22-3333');");
    try d.exec("INSERT INTO posts (id,created,updated,owner) VALUES ('p_1','t','t','s_1');");

    const anon = request.RequestContext{};
    const su = request.RequestContext{ .is_superuser = true };

    // Anonymous: the locked related record is OMITTED (expanded value is null).
    {
        var rec = (try records.get(a, &d, posts, "p_1")).?;
        try expand(a, &d, posts, &rec, "owner", 0, &anon);
        const owner = rec.object.get("expand").?.object.get("owner").?;
        try std.testing.expect(owner == .null);
    }
    // Superuser: the related record IS included.
    {
        var rec = (try records.get(a, &d, posts, "p_1")).?;
        try expand(a, &d, posts, &rec, "owner", 0, &su);
        const owner = rec.object.get("expand").?.object.get("owner").?;
        try std.testing.expectEqualStrings("111-22-3333", owner.object.get("ssn").?.string);
    }
}

test "PIN: expand view-authz routes through policy byte-identically (check-state rule)" {
    // Guards the M1 fix: `canView` now delegates to `policy.authorizes(.view)`. For an
    // owner-scoped (check-state) target rule the per-record decision must equal the
    // `rules.*` primitive it replaced — so PR2 tenant-scope / PR3 abilities compose into
    // `?expand=` without silently changing today's behavior.
    const rules = @import("../rules.zig");
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const notes = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "notes", .fields = &[_]schema.Field{
        .{ .id = "n1", .name = "body", .options = .{ .text = .{} } },
        .{ .id = "n2", .name = "owner", .options = .{ .text = .{} } },
    }, .viewRule = "owner = @request.auth.id" });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "note", .options = .{ .relation = .{ .targetCollectionId = notes.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf, .viewRule = "@public" });
    try d.exec("INSERT INTO notes (id,created,updated,body,owner) VALUES ('n_1','t','t','secret','u1');");
    try d.exec("INSERT INTO posts (id,created,updated,note) VALUES ('p_1','t','t','n_1');");

    var owner_obj: std.json.ObjectMap = .empty;
    try owner_obj.put(a, "id", .{ .string = "u1" });
    const owner = request.RequestContext{ .auth = .{ .object = owner_obj } };
    var other_obj: std.json.ObjectMap = .empty;
    try other_obj.put(a, "id", .{ .string = "u2" });
    const other = request.RequestContext{ .auth = .{ .object = other_obj } };

    // canView (policy-routed) must agree with the rules primitive for both principals.
    for ([_]request.RequestContext{ owner, other }) |rctx| {
        const want = try rules.matches(a, &d, notes, "n_1", notes.viewRule.?, &rctx);
        try std.testing.expectEqual(want, try canView(a, &d, notes, "n_1", &rctx));
    }
    // End-to-end through expand(): owner gets the note, stranger gets null.
    {
        var rec = (try records.get(a, &d, posts, "p_1")).?;
        try expand(a, &d, posts, &rec, "note", 0, &owner);
        try std.testing.expectEqualStrings("secret", rec.object.get("expand").?.object.get("note").?.object.get("body").?.string);
    }
    {
        var rec = (try records.get(a, &d, posts, "p_1")).?;
        try expand(a, &d, posts, &rec, "note", 0, &other);
        try std.testing.expect(rec.object.get("expand").?.object.get("note").? == .null);
    }
}

test "expand of a dangling relation id yields null" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "users", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }}, .viewRule = "" });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf, .viewRule = "" });
    // The author id points at a row that does not exist (FK off to simulate a
    // target row that was removed out-of-band / a stale reference).
    try d.exec("PRAGMA foreign_keys=OFF;");
    try d.exec("INSERT INTO posts (id,created,updated,author) VALUES ('p_1','t','t','u_missing');");
    try d.exec("PRAGMA foreign_keys=ON;");

    var rec = (try records.get(a, &d, posts, "p_1")).?;
    const su = request.RequestContext{ .is_superuser = true };
    try expand(a, &d, posts, &rec, "author", 0, &su);
    // The relation key is present under expand but the target is missing -> null.
    const author = rec.object.get("expand").?.object.get("author").?;
    try std.testing.expect(author == .null);
}

test "expand silently skips a non-relation or unknown head" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }}, .viewRule = "" });
    try d.exec("INSERT INTO posts (id,created,updated,title) VALUES ('p_1','t','t','hi');");
    const su = request.RequestContext{ .is_superuser = true };

    // "title" is a non-relation field -> skipped; "ghost" is unknown -> skipped.
    {
        var rec = (try records.get(a, &d, posts, "p_1")).?;
        try expand(a, &d, posts, &rec, "title", 0, &su);
        try std.testing.expect(rec.object.get("expand") == null);
    }
    {
        var rec = (try records.get(a, &d, posts, "p_1")).?;
        try expand(a, &d, posts, &rec, "ghost", 0, &su);
        try std.testing.expect(rec.object.get("expand") == null);
    }
}

test "H1: a public (@public) target is expanded for anyone" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    const pub_users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "pubusers", .fields = &[_]schema.Field{.{ .id = "u1", .name = "name", .options = .{ .text = .{} } }}, .viewRule = "@public" });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "author", .options = .{ .relation = .{ .targetCollectionId = pub_users.id, .maxSelect = 1 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf, .viewRule = "@public" });
    try d.exec("INSERT INTO pubusers (id,created,updated,name) VALUES ('u_1','t','t','Ada');");
    try d.exec("INSERT INTO posts (id,created,updated,author) VALUES ('p_1','t','t','u_1');");

    const anon = request.RequestContext{};
    var rec = (try records.get(a, &d, posts, "p_1")).?;
    try expand(a, &d, posts, &rec, "author", 0, &anon);
    const author = rec.object.get("expand").?.object.get("author").?;
    try std.testing.expectEqualStrings("Ada", author.object.get("name").?.string);
}

test "H1: a multi-relation array filters out the records the rctx may not view" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    // owner-scoped target: only the matching @request.auth.id row is viewable.
    const items = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "items", .fields = &[_]schema.Field{.{ .id = "i1", .name = "owner", .options = .{ .text = .{} } }}, .viewRule = "owner = @request.auth.id" });
    const pf = [_]schema.Field{.{ .id = "f3", .name = "things", .options = .{ .relation = .{ .targetCollectionId = items.id, .maxSelect = 9 } } }};
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf, .viewRule = "" });
    try d.exec("INSERT INTO items (id,created,updated,owner) VALUES ('i_1','t','t','u_me'),('i_2','t','t','u_other');");
    try d.exec("INSERT INTO posts (id,created,updated,things) VALUES ('p_1','t','t','[\"i_1\",\"i_2\"]');");

    var auth_obj: std.json.ObjectMap = .empty;
    try auth_obj.put(a, "id", .{ .string = "u_me" });
    const me = request.RequestContext{ .auth = .{ .object = auth_obj } };

    var rec = (try records.get(a, &d, posts, "p_1")).?;
    try expand(a, &d, posts, &rec, "things", 0, &me);
    const arr = rec.object.get("expand").?.object.get("things").?.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    try std.testing.expectEqualStrings("i_1", arr.items[0].object.get("id").?.string);
}
