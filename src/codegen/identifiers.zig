//! TS identifier validity, the reserved/imported-name set, and name derivations.
const std = @import("std");
const schema = @import("../schema.zig");

/// PascalCase a name: uppercase the first char, drop separators ('_','-') and
/// uppercase the char that follows. camelCase humps are preserved (sentAt -> SentAt).
pub fn pascal(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc); // free the buffer if an append OOMs mid-build
    var upper_next = true;
    for (s) |ch| {
        if (ch == '_' or ch == '-') {
            upper_next = true;
            continue;
        }
        if (upper_next) {
            try out.append(alloc, std.ascii.toUpper(ch));
            upper_next = false;
        } else {
            try out.append(alloc, ch);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// The record type name: PascalCase(collection), trailing 's' stripped (simple
/// singularization matching blog.gen.ts: users->User, posts->Post, tags->Tag).
pub fn recordName(alloc: std.mem.Allocator, col_name: []const u8) ![]const u8 {
    const p = try pascal(alloc, col_name);
    // When stripping the trailing 's', return an independently-owned copy rather
    // than a subslice of `p`: the caller must be able to `free` the result, and
    // freeing a subslice (whose length differs from the original allocation) is an
    // invalid free.
    if (p.len > 1 and p[p.len - 1] == 's') {
        defer alloc.free(p);
        return alloc.dupe(u8, p[0 .. p.len - 1]);
    }
    return p;
}

fn suffixed(alloc: std.mem.Allocator, col_name: []const u8, suffix: []const u8) ![]const u8 {
    const r = try recordName(alloc, col_name);
    defer alloc.free(r);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ r, suffix });
}

pub fn whereName(alloc: std.mem.Allocator, c: []const u8) ![]const u8 {
    return suffixed(alloc, c, "Where");
}
pub fn createName(alloc: std.mem.Allocator, c: []const u8) ![]const u8 {
    return suffixed(alloc, c, "Create");
}
pub fn updateName(alloc: std.mem.Allocator, c: []const u8) ![]const u8 {
    return suffixed(alloc, c, "Update");
}
pub fn relationsName(alloc: std.mem.Allocator, c: []const u8) ![]const u8 {
    return suffixed(alloc, c, "Relations");
}
pub fn expandName(alloc: std.mem.Allocator, c: []const u8) ![]const u8 {
    return suffixed(alloc, c, "Expand");
}
pub fn fieldsName(alloc: std.mem.Allocator, c: []const u8) ![]const u8 {
    return suffixed(alloc, c, "Fields");
}
pub fn realtimeAliasName(alloc: std.mem.Allocator, c: []const u8) ![]const u8 {
    // Plural collection name + "Realtime" (blog: posts -> PostsRealtime).
    const p = try pascal(alloc, c);
    defer alloc.free(p);
    return std.fmt.allocPrint(alloc, "{s}Realtime", .{p});
}
pub fn serviceName(alloc: std.mem.Allocator, c: []const u8) ![]const u8 {
    // Plural collection name + "Service" (blog: posts -> PostsService).
    const p = try pascal(alloc, c);
    defer alloc.free(p);
    return std.fmt.allocPrint(alloc, "{s}Service", .{p});
}
pub fn metaConst(alloc: std.mem.Allocator, c: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}Meta", .{c});
}

/// Derive a camelCase RPC method name from a route path: strip the api-prefix, drop
/// `:param` segments, and camel-join the remaining segments. First segment camelCased
/// (leading char lowercase, separators stripped with following char uppercased);
/// subsequent segments PascalCased: "/api/bookings/:id/confirm" -> "bookingsConfirm",
/// "/api/user-profile/list-items" -> "userProfileListItems".
///
/// NOTE: this function is NOT on the code-generation path — the generator consumes
/// `events.RouteMeta.name` (populated at comptime by `events.comptimeRouteName`).
/// It is retained as the reference implementation that the drift-guard test
/// (`routeMethodName matches the framework's comptimeRouteName`) pins
/// `comptimeRouteName` against. Do not delete it.
pub fn routeMethodName(alloc: std.mem.Allocator, path: []const u8, api_prefix: []const u8) ![]const u8 {
    var rest = path;
    if (std.mem.startsWith(u8, rest, api_prefix)) rest = rest[api_prefix.len..];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc); // free the buffer if an append OOMs mid-build
    var first = true;
    var it = std.mem.tokenizeScalar(u8, rest, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or seg[0] == ':') continue; // skip path params
        if (first) {
            // first segment: camelCase (leading char lowercase, strip separators).
            var seg_first = true;
            var upper_next = false;
            for (seg) |ch| {
                if (ch == '_' or ch == '-') {
                    upper_next = true;
                    continue;
                }
                if (upper_next) {
                    try out.append(alloc, std.ascii.toUpper(ch));
                    upper_next = false;
                } else if (seg_first) {
                    try out.append(alloc, std.ascii.toLower(ch));
                } else {
                    try out.append(alloc, ch);
                }
                seg_first = false;
            }
            first = false;
        } else {
            const p = try pascal(alloc, seg);
            defer alloc.free(p);
            try out.appendSlice(alloc, p);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// TS identifier rule — reuse the engine's identifier validity (letter-start,
/// then letters/digits/underscore). Sufficient for collection/field names, which
/// also constrain the derived PascalCase type names.
pub fn isValidTsIdent(s: []const u8) bool {
    return schema.isValidIdentifier(s);
}

/// Names imported/exported by the typed core (and TS built-ins) that a generated
/// type name must not collide with.
pub fn isReservedName(name: []const u8) bool {
    const reserved = [_][]const u8{
        // typed-core imports referenced by the generated file
        "WithExpand",            "StringOps",        "NumberOps",      "BoolOps",           "DateOps",
        "EnumOps",               "RelOps",           "Expr",           "FieldExpr",         "TypedFieldExpr",
        "RelationResolver",      "RawTypedRealtime", "CollectionMeta", "makeRecordService", "makeTypedRealtime",
        "makeTypedFiles",        "ListResult",       "CursorPage",     "FileUrlOptions",    "Client",
        "RealtimeEnabledClient", "createClient",
        // TS structural built-ins a record/where might shadow
            "Partial",        "Omit",              "Promise",
        "AsyncIterableIterator", "File",             "Blob",
    };
    for (reserved) |r| if (std.mem.eql(u8, name, r)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Assert an owned-slice result equals `expected`, then free it — restores the
/// leak detection an arena would mask for these single-owned-string manglers.
fn expectName(al: std.mem.Allocator, expected: []const u8, got: anyerror![]const u8) !void {
    const g = try got;
    defer al.free(g);
    try std.testing.expectEqualStrings(expected, g);
}

test "pascal + recordName" {
    const a = std.testing.allocator;
    try expectName(a, "SentAt", pascal(a, "sentAt"));
    try expectName(a, "Profile", recordName(a, "profiles"));
    try expectName(a, "Photo", recordName(a, "photos"));
    try expectName(a, "Tag", recordName(a, "tags"));
    try expectName(a, "Subscription", recordName(a, "subscriptions"));
    try expectName(a, "Wink", recordName(a, "winks"));
}

test "derived names" {
    const a = std.testing.allocator;
    try expectName(a, "ProfileWhere", whereName(a, "profiles"));
    try expectName(a, "ProfileCreate", createName(a, "profiles"));
    try expectName(a, "ProfilesService", serviceName(a, "profiles"));
    try expectName(a, "profilesMeta", metaConst(a, "profiles"));
    try expectName(a, "ProfilesRealtime", realtimeAliasName(a, "profiles"));
}

test "reserved names" {
    try std.testing.expect(isReservedName("WithExpand"));
    try std.testing.expect(isReservedName("RelOps"));
    try std.testing.expect(isReservedName("Expr"));
    try std.testing.expect(isReservedName("StringOps"));
    try std.testing.expect(isReservedName("CollectionMeta"));
    try std.testing.expect(!isReservedName("Profile"));
}

test "pascal converts snake_case and simple names" {
    const a = std.testing.allocator;
    try expectName(a, "Status", pascal(a, "status"));
    try expectName(a, "FieldName", pascal(a, "field_name"));
    try expectName(a, "BlogPost", pascal(a, "blog_post"));
}

test "recordName singularizes and pascal-cases" {
    const a = std.testing.allocator;
    try expectName(a, "Post", recordName(a, "posts"));
    try expectName(a, "User", recordName(a, "users"));
    try expectName(a, "BlogPost", recordName(a, "blog_posts"));
}

test "routeMethodName camel-joins non-param segments" {
    const a = std.testing.allocator;
    const cases = [_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "/api/bookings/:id/confirm", .want = "bookingsConfirm" },
        .{ .path = "/api/listings/:id/availability", .want = "listingsAvailability" },
        .{ .path = "/api/golfsim/health", .want = "golfsimHealth" },
        .{ .path = "/api/ping", .want = "ping" },
    };
    inline for (cases) |c| {
        const got = try routeMethodName(a, c.path, "/api");
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "routeMethodName matches the framework's comptimeRouteName" {
    const events = @import("../events.zig");
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "/api/bookings/:id/confirm",
        "/api/listings/:id/availability",
        "/api/golfsim/health",
        "/api/ping",
        "/api/user-profile/list-items", // separator case: both must strip '-'
        "/api/Bookings/confirm", // uppercase-initial first segment: both must lowercase first char
        "/health",
    };
    inline for (cases) |path| {
        const got = try routeMethodName(a, path, "/api");
        defer a.free(got);
        try std.testing.expectEqualStrings(events.comptimeRouteName(path, null), got);
    }
}
