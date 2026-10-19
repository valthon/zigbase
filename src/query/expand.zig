const std = @import("std");
const collections = @import("../collections.zig");
const records = @import("../records.zig");
const schema = @import("../schema.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const policy = @import("../policy.zig");
const request = @import("../request.zig");
const values = @import("../values.zig");

const max_depth = 6;

/// Explicit error set so the mutual recursion between `expand` and `expandField`
/// does not produce an inferred-error-set dependency loop.
pub const ExpandError = records.RecordError || collections.EngineError || policy.PolicyError;

/// Per-page caches shared across every item of a list result by `expandItems`.
///
/// Both cached things are request-scoped and IMMUTABLE, so sharing them across items can never
/// change output:
///   - `cols`: a target collection's parsed schema, keyed by collection id. Without this the list
///     path re-runs a `_collections` SELECT and fully re-parses the target schema/indexes/options
///     JSON once PER ROW even though the target is identical for every row (#15).
///   - `views`: the per-`(target,id)` view decision (`canView`), a deterministic function of
///     `(collection, id, rctx)`. A feed of many rows sharing a relation (e.g. 500 posts by 10
///     authors) makes each distinct author's decision ONCE rather than per row (#16).
///
/// The RECORD itself is deliberately NOT cached: `records.get` is re-run per item so each item owns
/// a FRESH `std.json.Value`. The list result is handed to framework consumer code (see `ctx.zig`'s
/// `Records.list`) which may mutate items in place, so sharing a record object between items would
/// be an observable behavior change — the caches above never share mutable record data.
const PageCache = struct {
    cols: std.StringHashMapUnmanaged(schema.Collection) = .empty,
    views: std.StringHashMapUnmanaged(bool) = .empty,
};

/// Resolve a target collection's schema, consulting `pc` (a per-page cache) when present so the
/// `_collections` SELECT + JSON parse happens once per collection per page, not once per row (#15).
fn resolveTarget(alloc: std.mem.Allocator, conn: *db.Db, pc: ?*PageCache, target_id: []const u8) ExpandError!?schema.Collection {
    if (pc) |c| if (c.cols.get(target_id)) |col| return col;
    const col = try collections.get(alloc, conn, target_id);
    if (col) |cc| if (pc) |c| try c.cols.put(alloc, target_id, cc);
    return col;
}

/// Whether `rctx` is permitted to view record `id` of `target` under `target.viewRule`.
/// Mirrors the view handler in src/api/records.zig: superuser/empty-rule => allow,
/// null rule => deny, otherwise the row must satisfy the rule. This is what closes the
/// access-control bypass where a public collection's relation leaked a locked target.
/// Routed through `policy.*` so PR2 tenant-scope + PR3 abilities cover `?expand=` too.
/// When `pc` is present the deterministic decision is memoized per `(target,id)` (#16).
fn canView(alloc: std.mem.Allocator, conn: *db.Db, pc: ?*PageCache, target: schema.Collection, id: []const u8, rctx: *const request.RequestContext) ExpandError!bool {
    if (pc) |c| {
        const key = try std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ target.id, id });
        if (c.views.get(key)) |v| {
            alloc.free(key); // probe key not stored on a hit — free it
            return v;
        }
        errdefer alloc.free(key); // owned by the map only once `put` succeeds
        const v = try policy.authorizes(alloc, conn, target, .view, id, rctx);
        try c.views.put(alloc, key, v);
        return v;
    }
    return policy.authorizes(alloc, conn, target, .view, id, rctx);
}

/// Expand a self-contained record. All inserted keys and values are owned by `alloc`.
pub fn expand(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, rec: *std.json.Value, spec: []const u8, depth: usize, rctx: *const request.RequestContext) ExpandError!void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var pc: PageCache = .{};
    return expandInner(alloc, scratch.allocator(), conn, col, rec, spec, depth, rctx, &pc, true);
}

/// Expand interned-key list items. Their top-level keys remain borrowed, matching
/// ListResult.deinit; every nested expansion key/value is independently owned.
/// Metadata and authorization caches are temporary; mutable records are never shared.
pub fn expandItems(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, items: []std.json.Value, spec: []const u8, depth: usize, rctx: *const request.RequestContext) ExpandError!void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var pc: PageCache = .{};
    for (items) |*item| try expandInner(alloc, scratch.allocator(), conn, col, item, spec, depth, rctx, &pc, false);
}

fn expandInner(alloc: std.mem.Allocator, scratch: std.mem.Allocator, conn: *db.Db, col: schema.Collection, rec: *std.json.Value, spec: []const u8, depth: usize, rctx: *const request.RequestContext, pc: *PageCache, owned_keys: bool) ExpandError!void {
    if (depth >= max_depth or rec.* != .object) return;
    var it = std.mem.splitScalar(u8, spec, ',');
    var expand_obj: std.json.ObjectMap = .empty;
    errdefer values.freeValue(alloc, .{ .object = expand_obj });
    while (it.next()) |raw| {
        const path = std.mem.trim(u8, raw, " ");
        if (path.len == 0) continue;
        const dot = std.mem.indexOfScalar(u8, path, '.');
        const head = if (dot) |i| path[0..i] else path;
        if (expand_obj.contains(head)) continue;
        const field = schema.fieldByName(col, head) orelse continue;
        if (field.fieldType() != .relation) continue;
        const id_val = rec.object.get(head) orelse continue;
        const target = (try resolveTarget(scratch, conn, pc, field.options.relation.targetCollectionId)) orelse continue;
        // Coalesce all descendants before fetching this relation. This preserves siblings,
        // duplicates, and direct + descendant requests independently of their input order.
        var descendants: std.ArrayList(u8) = .empty;
        var paths = std.mem.splitScalar(u8, spec, ',');
        while (paths.next()) |candidate_raw| {
            const candidate = std.mem.trim(u8, candidate_raw, " ");
            const split = std.mem.indexOfScalar(u8, candidate, '.') orelse continue;
            if (!std.mem.eql(u8, candidate[0..split], head) or split + 1 == candidate.len) continue;
            if (descendants.items.len > 0) try descendants.append(scratch, ',');
            try descendants.appendSlice(scratch, candidate[split + 1 ..]);
        }
        const nested = try expandField(alloc, scratch, conn, target, id_val, descendants.items, depth, rctx, pc);
        errdefer values.freeValue(alloc, nested);
        const key = try alloc.dupe(u8, head);
        errdefer alloc.free(key);
        try expand_obj.put(alloc, key, nested);
    }
    if (expand_obj.count() == 0) {
        expand_obj.deinit(alloc);
        return;
    }
    if (rec.object.getPtr("expand")) |old| {
        values.freeValue(alloc, old.*);
        old.* = .{ .object = expand_obj };
    } else {
        const key = if (owned_keys) try alloc.dupe(u8, "expand") else "expand";
        errdefer if (owned_keys) alloc.free(key);
        try rec.object.put(alloc, key, .{ .object = expand_obj });
    }
}

fn expandField(alloc: std.mem.Allocator, scratch: std.mem.Allocator, conn: *db.Db, target: schema.Collection, id_val: std.json.Value, rest: []const u8, depth: usize, rctx: *const request.RequestContext, pc: *PageCache) ExpandError!std.json.Value {
    switch (id_val) {
        .string => |id| {
            if (!try canView(scratch, conn, pc, target, id, rctx)) return .null;
            var sub = (try records.get(alloc, conn, target, id)) orelse return .null;
            errdefer records.freeRecord(alloc, sub);
            if (rest.len > 0) try expandInner(alloc, scratch, conn, target, &sub, rest, depth + 1, rctx, pc, true);
            return sub;
        },
        .array => |arr| {
            var out = std.json.Array.init(alloc);
            errdefer values.freeValue(alloc, .{ .array = out });
            for (arr.items) |item| if (item == .string) {
                if (!try canView(scratch, conn, pc, target, item.string, rctx)) continue;
                var sub = (try records.get(alloc, conn, target, item.string)) orelse continue;
                errdefer records.freeRecord(alloc, sub);
                if (rest.len > 0) try expandInner(alloc, scratch, conn, target, &sub, rest, depth + 1, rctx, pc, true);
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
        try std.testing.expectEqual(want, try canView(a, &d, null, notes, "n_1", &rctx));
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

test "expandItems is byte-identical to per-item expand (shared metadata + decision caches, #15/#16)" {
    // The list-page batch entry must produce, for every item, exactly what expanding each item
    // independently produces — the caches only remove redundant metadata parses / view decisions,
    // never change the result. Exercises a shared single-relation head, a per-record-scoped
    // (check-state) target so decisions actually differ per id, and a multi-relation array.
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try migrations.run(&d);
    // owner-scoped users: only the row whose owner == @request.auth.id is viewable.
    const users = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "u", .fields = &[_]schema.Field{
        .{ .id = "u1", .name = "owner", .options = .{ .text = .{} } },
    }, .viewRule = "owner = @request.auth.id" });
    const tags = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "t", .fields = &[_]schema.Field{
        .{ .id = "t1", .name = "label", .options = .{ .text = .{} } },
    }, .viewRule = "@public" });
    const pf = [_]schema.Field{
        .{ .id = "f1", .name = "author", .options = .{ .relation = .{ .targetCollectionId = users.id, .maxSelect = 1 } } },
        .{ .id = "f2", .name = "tags", .options = .{ .relation = .{ .targetCollectionId = tags.id, .maxSelect = 9 } } },
    };
    const posts = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &pf, .viewRule = "@public" });
    try d.exec("INSERT INTO u (id,created,updated,owner) VALUES ('u_me','t','t','me'),('u_them','t','t','them');");
    try d.exec("INSERT INTO t (id,created,updated,label) VALUES ('t_1','t','t','x'),('t_2','t','t','y');");
    // Two posts SHARE author u_me (viewable) and one has the non-viewable u_them; tags overlap so
    // ids repeat across the page (the case the decision cache collapses).
    try d.exec("INSERT INTO posts (id,created,updated,author,tags) VALUES " ++
        "('p_1','t','t','u_me','[\"t_1\",\"t_2\"]')," ++
        "('p_2','t','t','u_them','[\"t_1\"]')," ++
        "('p_3','t','t','u_me','[\"t_2\",\"t_1\"]');");

    var auth_obj: std.json.ObjectMap = .empty;
    try auth_obj.put(a, "id", .{ .string = "me" });
    const me = request.RequestContext{ .auth = .{ .object = auth_obj } };
    const spec = "author,tags";
    const ids = [_][]const u8{ "p_1", "p_2", "p_3" };

    // Reference: expand each item independently.
    var want: [3]std.json.Value = undefined;
    for (0..ids.len) |i| {
        want[i] = (try records.get(a, &d, posts, ids[i])).?;
        try expand(a, &d, posts, &want[i], spec, 0, &me);
    }
    // Batch: expandItems over the same three records.
    var got: [3]std.json.Value = undefined;
    for (0..ids.len) |i| got[i] = (try records.get(a, &d, posts, ids[i])).?;
    try expandItems(a, &d, posts, &got, spec, 0, &me);

    // Serialized output must match item-for-item.
    for (0..ids.len) |i| {
        const ws = try std.json.Stringify.valueAlloc(a, want[i], .{});
        const gs = try std.json.Stringify.valueAlloc(a, got[i], .{});
        try std.testing.expectEqualStrings(ws, gs);
    }
    // Spot-check the semantics the caches must preserve: p_2's non-viewable author is null, and the
    // multi-relation tag arrays are fully expanded (public target).
    try std.testing.expect(got[1].object.get("expand").?.object.get("author").? == .null);
    try std.testing.expectEqual(@as(usize, 2), got[0].object.get("expand").?.object.get("tags").?.array.items.len);
}

const OwnershipFixture = struct { conn: *db.Db, col: schema.Collection };

fn expansionAllocationCase(a: std.mem.Allocator, fixture: OwnershipFixture) !void {
    const su = request.RequestContext{ .is_superuser = true };
    var rec = (try records.get(a, fixture.conn, fixture.col, "p1")).?;
    defer records.freeRecord(a, rec);
    try expand(a, fixture.conn, fixture.col, &rec, "author.org,author.manager,authors.org,authors.manager", 0, &su);
    // Replacement must preserve the original top-level key's ownership.
    try expand(a, fixture.conn, fixture.col, &rec, "author,author.org", 0, &su);
    var result = try records.list(a, fixture.conn, fixture.col, .{});
    defer result.deinit(a);
    try expandItems(a, fixture.conn, fixture.col, result.items, "author.org,authors.manager", 0, &su);
    try expandItems(a, fixture.conn, fixture.col, result.items, "author.manager,authors.org", 0, &su);
}

test "expansion owns nested output and coalesces shared paths under raw allocators" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);
    const groups = try collections.create(a, std.testing.io, &conn, .{ .id = "", .name = "groups", .fields = &.{} });
    defer groups.deinit(a);
    const people = try collections.create(a, std.testing.io, &conn, .{ .id = "", .name = "people", .fields = &.{
        .{ .id = "f1", .name = "org", .options = .{ .relation = .{ .targetCollectionId = groups.id, .maxSelect = 1 } } },
        .{ .id = "f2", .name = "manager", .options = .{ .relation = .{ .targetCollectionId = groups.id, .maxSelect = 1 } } },
    } });
    defer people.deinit(a);
    const posts = try collections.create(a, std.testing.io, &conn, .{ .id = "", .name = "posts", .fields = &.{
        .{ .id = "f1", .name = "author", .options = .{ .relation = .{ .targetCollectionId = people.id, .maxSelect = 1 } } },
        .{ .id = "f2", .name = "authors", .options = .{ .relation = .{ .targetCollectionId = people.id, .maxSelect = 9 } } },
    } });
    defer posts.deinit(a);
    try conn.exec("INSERT INTO groups (id,created,updated) VALUES ('g1','t','t'),('g2','t','t');");
    try conn.exec("INSERT INTO people (id,created,updated,org,manager) VALUES ('u1','t','t','g1','g2');");
    try conn.exec("INSERT INTO posts (id,created,updated,author,authors) VALUES ('p1','t','t','u1','[\"u1\"]'),('p2','t','t','u1','[\"u1\"]');");
    const su = request.RequestContext{ .is_superuser = true };
    for ([_][]const u8{
        "author.org,author.manager,authors.org,authors.manager",
        "author.manager,author.org,author.org,authors.manager,authors.org",
        "author,author.org,author.manager,authors,authors.org,authors.manager",
        "author.org,author.manager,author,authors.org,authors.manager,authors",
    }) |spec| {
        var rec = (try records.get(a, &conn, posts, "p1")).?;
        defer records.freeRecord(a, rec);
        try expand(a, &conn, posts, &rec, spec, 0, &su);
        const expanded = rec.object.get("expand").?.object;
        const author = expanded.get("author").?.object.get("expand").?.object;
        try std.testing.expect(author.contains("org") and author.contains("manager"));
        const authors = expanded.get("authors").?.array.items[0].object.get("expand").?.object;
        try std.testing.expect(authors.contains("org") and authors.contains("manager"));
    }
    var result = try records.list(a, &conn, posts, .{});
    defer result.deinit(a);
    try expandItems(a, &conn, posts, result.items, "author.org", 0, &su);
    const first = result.items[0].object.get("expand").?.object.get("author").?;
    const second = result.items[1].object.get("expand").?.object.get("author").?;
    try std.testing.expect(first.object.entries.items(.value).ptr != second.object.entries.items(.value).ptr);
    // A locked target and a no-op path must also be safely destructible.
    var denied = (try records.get(a, &conn, posts, "p1")).?;
    defer records.freeRecord(a, denied);
    const anon = request.RequestContext{};
    try expand(a, &conn, posts, &denied, "missing", 0, &anon);
    try std.testing.expect(!denied.object.contains("expand"));
    try expand(a, &conn, posts, &denied, "author", 0, &anon);
    try std.testing.expect(denied.object.get("expand").?.object.get("author").? == .null);
    try std.testing.checkAllAllocationFailures(a, expansionAllocationCase, .{OwnershipFixture{ .conn = &conn, .col = posts }});
}
