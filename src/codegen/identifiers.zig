//! TS identifier validity, the reserved/imported-name set, and name derivations.
const std = @import("std");
const schema = @import("../schema.zig");

/// PascalCase a name: uppercase the first char, drop separators ('_','-') and
/// uppercase the char that follows. camelCase humps are preserved (sentAt -> SentAt).
pub fn pascal(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
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
    if (p.len > 1 and p[p.len - 1] == 's') return p[0 .. p.len - 1];
    return p;
}

fn suffixed(alloc: std.mem.Allocator, col_name: []const u8, suffix: []const u8) ![]const u8 {
    const r = try recordName(alloc, col_name);
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
    return std.fmt.allocPrint(alloc, "{s}Realtime", .{p});
}
pub fn serviceName(alloc: std.mem.Allocator, c: []const u8) ![]const u8 {
    // Plural collection name + "Service" (blog: posts -> PostsService).
    const p = try pascal(alloc, c);
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
pub fn routeMethodName(alloc: std.mem.Allocator, path: []const u8, api_prefix: []const u8) ![]const u8 {
    var rest = path;
    if (std.mem.startsWith(u8, rest, api_prefix)) rest = rest[api_prefix.len..];
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    var it = std.mem.tokenizeScalar(u8, rest, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or seg[0] == ':') continue; // skip path params
        if (first) {
            // first segment: camelCase (leading char lowercase, strip separators).
            var seg_first = true;
            var upper_next = false;
            for (seg) |ch| {
                if (ch == '_' or ch == '-') { upper_next = true; continue; }
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
        "WithExpand",    "StringOps", "NumberOps", "BoolOps",  "DateOps",
        "EnumOps",       "RelOps",    "Expr",      "FieldExpr", "TypedFieldExpr",
        "RelationResolver", "RawTypedRealtime", "CollectionMeta",
        "makeRecordService", "makeTypedRealtime", "makeTypedFiles",
        "ListResult", "CursorPage", "FileUrlOptions", "Client",
        "RealtimeEnabledClient", "createClient",
        // TS structural built-ins a record/where might shadow
        "Partial", "Omit", "Promise", "AsyncIterableIterator", "File", "Blob",
    };
    for (reserved) |r| if (std.mem.eql(u8, name, r)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "pascal + recordName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("SentAt", try pascal(a, "sentAt"));
    try std.testing.expectEqualStrings("Profile", try recordName(a, "profiles"));
    try std.testing.expectEqualStrings("Photo", try recordName(a, "photos"));
    try std.testing.expectEqualStrings("Tag", try recordName(a, "tags"));
    try std.testing.expectEqualStrings("Subscription", try recordName(a, "subscriptions"));
    try std.testing.expectEqualStrings("Wink", try recordName(a, "winks"));
}

test "derived names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("ProfileWhere", try whereName(a, "profiles"));
    try std.testing.expectEqualStrings("ProfileCreate", try createName(a, "profiles"));
    try std.testing.expectEqualStrings("ProfilesService", try serviceName(a, "profiles"));
    try std.testing.expectEqualStrings("profilesMeta", try metaConst(a, "profiles"));
    try std.testing.expectEqualStrings("ProfilesRealtime", try realtimeAliasName(a, "profiles"));
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Status", try pascal(a, "status"));
    try std.testing.expectEqualStrings("FieldName", try pascal(a, "field_name"));
    try std.testing.expectEqualStrings("BlogPost", try pascal(a, "blog_post"));
}

test "recordName singularizes and pascal-cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Post", try recordName(a, "posts"));
    try std.testing.expectEqualStrings("User", try recordName(a, "users"));
    try std.testing.expectEqualStrings("BlogPost", try recordName(a, "blog_posts"));
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
        "/health",
    };
    inline for (cases) |path| {
        const got = try routeMethodName(a, path, "/api");
        defer a.free(got);
        try std.testing.expectEqualStrings(events.comptimeRouteName(path, null), got);
    }
}
