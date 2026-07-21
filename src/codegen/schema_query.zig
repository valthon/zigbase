//! Language-neutral schema queries shared by every client emitter
//! (emit.zig / emit_dart.zig / emit_kotlin.zig / emit_python.zig).
//!
//! These predicates are pure functions of the `schema.Collection` model — they
//! carry no TypeScript/Dart/Kotlin/Python specifics — yet each emitter used to
//! keep its own byte-identical copy. That duplication was a correctness hazard,
//! not just noise: `appendVisibleAuthFields`/`recordFields` hand-rolled the
//! visible subset of `schema.authSystemFields()`, so adding a new non-hidden
//! auth system field to the schema (as `verified` once was) served it from the
//! API automatically while every generated SDK silently omitted it until all
//! four copies were found and edited. Deriving the visible auth fields from the
//! canonical `schema.authSystemFields()` here removes that drift entirely.
//!
//! Genuinely language-specific queries stay in each emitter: file/select
//! detection routes through the per-language `kindOf` type map, keyword sets
//! and enum-member policy differ, and the identifier-collision *error* differs
//! (only `checkDuplicateIdents`'s shared O(n²) scan lives here, parameterized).
const std = @import("std");
const schema = @import("../schema.zig");

/// Returns true for the synthesized read-only system field names that are NOT
/// user-declared fields: id, created, updated. Used to dedup a user field that
/// happens to be named one of these, since the three are always appended last.
pub fn isReadOnlySystem(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "created") or
        std.mem.eql(u8, name, "updated");
}

/// Returns true for the three visible auth fields synthesized for `.auth`
/// collections (email, username, verified). Guards against double-emission when
/// a caller passes a collection whose `.fields` already contain these names.
pub fn isAuthSynthesized(name: []const u8) bool {
    return std.mem.eql(u8, name, "email") or
        std.mem.eql(u8, name, "username") or
        std.mem.eql(u8, name, "verified");
}

/// Appends the visible synthesized auth fields for an auth collection record,
/// in schema order (email, username, verified). Derived from the canonical
/// `schema.authSystemFields()` filtered to its non-hidden subset — so a new
/// non-hidden auth system field flows into every generated SDK automatically
/// instead of requiring four hand-maintained copies to be edited in lockstep.
pub fn appendVisibleAuthFields(alloc: std.mem.Allocator, list: *std.ArrayList(schema.Field)) !void {
    for (schema.authSystemFields()) |f| {
        if (f.hidden) continue;
        try list.append(alloc, f);
    }
}

/// The record fields in emission order: id, (auth visible fields), user fields,
/// created, updated. User-declared fields named id/created/updated are
/// deduplicated (they are always appended at the end).
pub fn recordFields(alloc: std.mem.Allocator, c: schema.Collection) ![]schema.Field {
    var list: std.ArrayList(schema.Field) = .empty;
    errdefer list.deinit(alloc); // free the backing array if an append OOMs mid-build
    try list.append(alloc, .{ .id = "_id", .name = "id", .options = .{ .text = .{} } });
    if (c.type == .auth) try appendVisibleAuthFields(alloc, &list);
    for (c.fields) |f| {
        if (f.hidden) continue;
        if (isReadOnlySystem(f.name)) continue; // dedup: created/updated always appended below
        try list.append(alloc, f);
    }
    try list.append(alloc, .{ .id = "_created", .name = "created", .options = .{ .autodate = .{} } });
    try list.append(alloc, .{ .id = "_updated", .name = "updated", .options = .{ .autodate = .{} } });
    return list.toOwnedSlice(alloc);
}

/// True if a collection named `name` exists in `cols`.
pub fn collectionExists(cols: []const schema.Collection, name: []const u8) bool {
    for (cols) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

/// True if `c` has at least one relation field whose target collection is part
/// of the generated set (an unresolvable relation cannot be expanded/typed).
pub fn hasResolvableRelations(cols: []const schema.Collection, c: schema.Collection) bool {
    for (c.fields) |f| {
        if (f.options != .relation) continue;
        if (collectionExists(cols, f.options.relation.targetCollectionId)) return true;
    }
    return false;
}

/// Membership test for a string against a small set — the shared primitive
/// behind each emitter's `memberIdent` reserved-name check.
pub fn inSet(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Generation-time duplicate-identifier check: two distinct schema names that
/// sanitize to the same target-language identifier (e.g. fields `class` and
/// `class_`) would emit a duplicate member. Returns `Collision` naming the two.
///
/// The scan is identical across languages; only the log prefix, the language
/// name in the message, and the returned error differ, so those are comptime
/// parameters. `gen_name` is the emitter's log prefix (e.g. "gen_dart") and
/// `lang_name` the language in the message (e.g. "Dart").
pub fn checkDuplicateIdents(
    comptime gen_name: []const u8,
    comptime lang_name: []const u8,
    comptime Collision: anyerror,
    idents: []const []const u8,
    names: []const []const u8,
    scope: []const u8,
) !void {
    for (idents, 0..) |a, i| {
        for (idents[i + 1 ..], i + 1..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                // warn (not err): the returned error is the failure signal and the
                // CLI layer logs err at top level; std.log.err inside would also
                // fail the Zig test runner in the expectError coverage tests.
                std.log.warn(
                    gen_name ++ ": schema names '{s}' and '{s}' both map to " ++ lang_name ++ " identifier '{s}' in {s} — rename one of them",
                    .{ names[i], names[j], a, scope },
                );
                return Collision;
            }
        }
    }
}

test "appendVisibleAuthFields is exactly the non-hidden subset of authSystemFields" {
    const a = std.testing.allocator;
    var list: std.ArrayList(schema.Field) = .empty;
    defer list.deinit(a);
    try appendVisibleAuthFields(a, &list);
    // The visible auth triple, in schema order, with the canonical stable ids
    // and options — regression guard for the drift hazard this module removes.
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("email", list.items[0].name);
    try std.testing.expect(list.items[0].options == .email);
    try std.testing.expectEqualStrings("username", list.items[1].name);
    try std.testing.expect(list.items[1].options == .text);
    try std.testing.expectEqualStrings("verified", list.items[2].name);
    try std.testing.expect(list.items[2].options == .bool);
    // None of the hidden system fields (passwordHash/tokenKey/token_epoch) leak.
    for (list.items) |f| try std.testing.expect(!f.hidden);
}

test "recordFields ordering: id, auth visible, user, created, updated" {
    const a = std.testing.allocator;
    const c = schema.Collection{
        .id = "",
        .name = "users",
        .type = .auth,
        .fields = &.{
            .{ .id = "", .name = "bio", .options = .{ .text = .{} } },
            // A user field named `created` is deduped (system copy appended last).
            .{ .id = "", .name = "created", .options = .{ .autodate = .{} } },
        },
    };
    const fields = try recordFields(a, c);
    defer a.free(fields);
    try std.testing.expectEqualStrings("id", fields[0].name);
    try std.testing.expectEqualStrings("email", fields[1].name);
    try std.testing.expectEqualStrings("username", fields[2].name);
    try std.testing.expectEqualStrings("verified", fields[3].name);
    try std.testing.expectEqualStrings("bio", fields[4].name);
    try std.testing.expectEqualStrings("created", fields[fields.len - 2].name);
    try std.testing.expectEqualStrings("updated", fields[fields.len - 1].name);
    // `created` appears once (the deduped system copy), not twice.
    var created_count: usize = 0;
    for (fields) |f| if (std.mem.eql(u8, f.name, "created")) {
        created_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), created_count);
}

test "checkDuplicateIdents flags a collision and returns the parameterized error" {
    const idents = [_][]const u8{ "class_", "class_" };
    const names = [_][]const u8{ "class", "class_" };
    try std.testing.expectError(
        error.PythonIdentCollision,
        checkDuplicateIdents("gen_python", "Python", error.PythonIdentCollision, &idents, &names, "record"),
    );
    const unique = [_][]const u8{ "a", "b" };
    try checkDuplicateIdents("gen_dart", "Dart", error.DartIdentCollision, &unique, &unique, "record");
}
