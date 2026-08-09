const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const collections = @import("collections.zig");
const migrations = @import("migrations.zig");

/// Frozen document-format version. Append-only: bump ONLY on a breaking shape change,
/// and teach `parse` to accept both.
pub const doc_version: u32 = 1;

pub const DocError = error{ UnsupportedVersion, InvalidDocument } ||
    collections.EngineError || std.mem.Allocator.Error;

/// Free a slice returned by `parse` (or by `collections.list`): every element owns its
/// strings, and the backing slice is owned too.
pub fn freeCollections(alloc: std.mem.Allocator, cols: []schema.Collection) void {
    for (cols) |c| c.deinit(alloc);
    alloc.free(cols);
}

fn lessByName(_: void, a: schema.Collection, b: schema.Collection) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Strip the fields the engine re-injects on every create/update (`injectAuthFields`) and
/// that `parseCollectionInput` drops on input — emitting them would be round-trip noise.
/// Relation targets are rewritten id -> target NAME so the document is instance-portable
/// (`collections.resolveRelations` accepts either form).
fn documentFields(sa: std.mem.Allocator, c: schema.Collection, all: []const schema.Collection) ![]schema.Field {
    var out: std.ArrayList(schema.Field) = .empty;
    for (c.fields) |f| {
        if (schema.isSystemFieldName(f.name)) continue;
        var nf = f;
        if (f.options == .relation) {
            var r = f.options.relation;
            r.targetCollectionId = targetName(r.targetCollectionId, c, all);
            nf.options = .{ .relation = r };
        }
        try out.append(sa, nf);
    }
    return out.toOwnedSlice(sa);
}

/// Map a relation's stored `targetCollectionId` to a collection NAME. The stored value may
/// already BE a name (the comptime path stores ids, the REST path stores whatever the
/// client sent), so fall through unchanged when no id matches. Public because
/// `import_manifest.zig` normalizes `collections.list`'s raw (possibly id-based) targets the
/// same way before handing collections to `schema_diff.orderWithCycles`, which is name-only.
pub fn targetName(target: []const u8, self: schema.Collection, all: []const schema.Collection) []const u8 {
    if (std.mem.eql(u8, target, self.id)) return self.name;
    for (all) |c| if (std.mem.eql(u8, c.id, target)) return c.name;
    return target;
}

fn optStr(v: ?[]const u8) std.json.Value {
    return if (v) |s| .{ .string = s } else .null;
}

/// Serialize every non-system collection to the canonical document.
pub fn dump(alloc: std.mem.Allocator, w: *db.Db) DocError![]u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // `list` returns fully-owned collections on `sa`; the arena reclaims them wholesale, so
    // no per-element deinit is needed (and none is correct — deinit on an arena is a no-op).
    const all = try collections.list(sa, w);

    var kept: std.ArrayList(schema.Collection) = .empty;
    // System collections (`_superusers`, `_accounts`, …) are owned by the engine's
    // migrations, not by consumers, and are never part of a schema document.
    for (all) |c| if (!c.system) try kept.append(sa, c);
    // Deterministic order: `collections.list` orders by `created` (second-resolution text),
    // which ties for same-second creations. Sort by name so the document diffs cleanly.
    std.sort.pdq(schema.Collection, kept.items, {}, lessByName);

    var arr: std.json.Array = .init(sa);
    for (kept.items) |c| {
        var o: std.json.ObjectMap = .empty;
        try o.put(sa, "name", .{ .string = c.name });
        try o.put(sa, "type", .{ .string = @tagName(c.type) });

        const fields_json = try schema.fieldsToJson(sa, try documentFields(sa, c, all));
        try o.put(sa, "fields", try std.json.parseFromSliceLeaky(std.json.Value, sa, fields_json, .{}));

        const idx_json = try schema.indexesToJson(sa, c.indexes);
        try o.put(sa, "indexes", try std.json.parseFromSliceLeaky(std.json.Value, sa, idx_json, .{}));

        try o.put(sa, "listRule", optStr(c.listRule));
        try o.put(sa, "viewRule", optStr(c.viewRule));
        try o.put(sa, "createRule", optStr(c.createRule));
        try o.put(sa, "updateRule", optStr(c.updateRule));
        try o.put(sa, "deleteRule", optStr(c.deleteRule));

        // redact = true: OAuth client secrets are NEVER written to a schema document.
        // `schema apply` reuses the REST rule (an empty secret preserves the stored one).
        const opts_json = try schema.optionsToJson(sa, c, true);
        try o.put(sa, "options", try std.json.parseFromSliceLeaky(std.json.Value, sa, opts_json, .{}));

        try arr.append(.{ .object = o });
    }

    var root: std.json.ObjectMap = .empty;
    try root.put(sa, "zigbaseSchema", .{ .integer = @intCast(doc_version) });
    try root.put(sa, "collections", .{ .array = arr });

    const body = try std.json.Stringify.valueAlloc(sa, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 });
    // A trailing newline so the file is a well-formed text file and `git diff` is clean.
    return std.fmt.allocPrint(alloc, "{s}\n", .{body});
}

/// Parse a document into collections, in document order. Each element is parsed by
/// `schema.parseCollectionInput` — the SAME parse the REST `POST /api/collections` handler
/// uses, so a document can never mean something the API would not.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) DocError![]schema.Collection {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, sa, bytes, .{}) catch return DocError.InvalidDocument;
    if (root != .object) return DocError.InvalidDocument;

    const ver = root.object.get("zigbaseSchema") orelse return DocError.InvalidDocument;
    if (ver != .integer) return DocError.InvalidDocument;
    if (ver.integer != @as(i64, @intCast(doc_version))) return DocError.UnsupportedVersion;

    const list = root.object.get("collections") orelse return DocError.InvalidDocument;
    if (list != .array) return DocError.InvalidDocument;

    var out: std.ArrayList(schema.Collection) = .empty;
    // Every element already appended owns its strings on `alloc`; free them all (plus the
    // backing buffer) if a later element fails, so `parse` is leak-correct under a raw
    // allocator on EVERY error path, not just the happy one.
    errdefer {
        for (out.items) |c| c.deinit(alloc);
        out.deinit(alloc);
    }
    for (list.array.items) |el| {
        if (el != .object) return DocError.InvalidDocument;
        const one = try std.json.Stringify.valueAlloc(sa, el, .{});
        const col = schema.parseCollectionInput(alloc, one) catch |e| return switch (e) {
            // OOM is not a malformed document; report it as what it is instead of masking an
            // allocation failure as `InvalidDocument` (which a caller could plausibly treat as
            // "fix your input and retry" rather than "the process is out of memory").
            error.OutOfMemory => error.OutOfMemory,
            else => DocError.InvalidDocument,
        };
        // `col` is fully owned the moment parse succeeds: an OOM inside `append` must not
        // lose it.
        errdefer col.deinit(alloc);
        try out.append(alloc, col);
    }
    return out.toOwnedSlice(alloc);
}

test "dump emits a versioned document, sorted by name, without system collections" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);

    const zebra = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "zebra",
        .fields = &.{.{ .id = "", .name = "title", .options = .{ .text = .{} } }},
    });
    defer zebra.deinit(a);
    const alpha = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "alpha",
        .fields = &.{.{ .id = "", .name = "body", .options = .{ .text = .{} } }},
    });
    defer alpha.deinit(a);

    const doc = try dump(a, &conn);
    defer a.free(doc);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, doc, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("zigbaseSchema").?.integer);
    const cols = parsed.value.object.get("collections").?.array;
    // Exactly the two user collections, name-sorted; `_superusers` (system) is absent.
    try std.testing.expectEqual(@as(usize, 2), cols.items.len);
    try std.testing.expectEqualStrings("alpha", cols.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("zebra", cols.items[1].object.get("name").?.string);
    // Collection ids are omitted (instance-local); field ids are kept (rebuild-load-bearing).
    try std.testing.expect(cols.items[0].object.get("id") == null);
    const f0 = cols.items[0].object.get("fields").?.array.items[0];
    try std.testing.expectEqual(@as(usize, 8), f0.object.get("id").?.string.len);
}

test "dump omits auth system fields but keeps user fields" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);

    const users = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{.{ .id = "", .name = "nick", .options = .{ .text = .{} } }},
    });
    defer users.deinit(a);

    const doc = try dump(a, &conn);
    defer a.free(doc);
    // The physical table carries email/passwordHash/tokenKey/verified; the DOCUMENT must not.
    try std.testing.expect(std.mem.indexOf(u8, doc, "passwordHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"verified\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "nick") != null);
}

test "dump rewrites relation targets from id to the target collection's name" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);

    const authors = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "authors",
        .fields = &.{.{ .id = "", .name = "nom", .options = .{ .text = .{} } }},
    });
    defer authors.deinit(a);
    const posts = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "posts",
        .fields = &.{.{ .id = "", .name = "author", .options = .{ .relation = .{ .targetCollectionId = authors.id } } }},
    });
    defer posts.deinit(a);

    const doc = try dump(a, &conn);
    defer a.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"targetCollectionId\": \"authors\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, authors.id) == null);
}

test "parse round-trips a dumped document" {
    const a = std.testing.allocator;
    var conn = try db.Db.openMemory();
    defer conn.close();
    try migrations.run(&conn);

    const posts = try collections.create(a, std.testing.io, &conn, .{
        .id = "",
        .name = "posts",
        .viewRule = "@public",
        .fields = &.{
            .{ .id = "", .name = "title", .required = true, .options = .{ .text = .{ .max = 120 } } },
            .{ .id = "", .name = "views", .options = .{ .number = .{ .mode = .int } } },
        },
        .indexes = &.{.{ .name = "idx_posts_title", .fields = &.{"title"}, .unique = true }},
    });
    defer posts.deinit(a);

    const doc = try dump(a, &conn);
    defer a.free(doc);

    const cols = try parse(a, doc);
    defer freeCollections(a, cols);

    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqualStrings("posts", cols[0].name);
    try std.testing.expectEqualStrings("@public", cols[0].viewRule.?);
    try std.testing.expectEqual(@as(usize, 2), cols[0].fields.len);
    try std.testing.expectEqualStrings("title", cols[0].fields[0].name);
    try std.testing.expect(cols[0].fields[0].required);
    try std.testing.expectEqual(@as(?u32, 120), cols[0].fields[0].options.text.max);
    // The stable field id survives the round trip — this is what preserves data on apply.
    try std.testing.expectEqual(@as(usize, 8), cols[0].fields[0].id.len);
    try std.testing.expectEqual(@as(usize, 1), cols[0].indexes.len);
    try std.testing.expectEqualStrings("idx_posts_title", cols[0].indexes[0].name);
}

test "parse rejects a missing or future version and a non-object root" {
    const a = std.testing.allocator;
    try std.testing.expectError(DocError.InvalidDocument, parse(a, "[]"));
    try std.testing.expectError(DocError.InvalidDocument, parse(a, "{\"collections\":[]}"));
    try std.testing.expectError(DocError.UnsupportedVersion, parse(a, "{\"zigbaseSchema\":99,\"collections\":[]}"));
    try std.testing.expectError(DocError.InvalidDocument, parse(a, "{\"zigbaseSchema\":1}"));
}
