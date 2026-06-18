const std = @import("std");
const schema = @import("../schema.zig");
const acquire_core = @import("acquire.zig");

/// Parse a `GET /api/collections` JSON array into user collections. The
/// endpoint serializes fields under the "schema" key (collectionToJson shape);
/// nested arrays/objects are re-stringified to feed acquire.buildCollection,
/// which uses the same parsers as the data-dir path — so both converge.
pub fn parseCollections(alloc: std.mem.Allocator, json_bytes: []const u8) ![]schema.Collection {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidSchema;

    // Build id→name map across ALL elements (including system collections,
    // since a relation could target one) so UUID targetCollectionIds can be
    // resolved back to names before the system-collection filter runs.
    var id_to_name = std.StringHashMap([]const u8).init(alloc);
    defer id_to_name.deinit();
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const id = objStr(obj, "id") orelse continue;
        const name = objStr(obj, "name") orelse continue;
        try id_to_name.put(try alloc.dupe(u8, id), try alloc.dupe(u8, name));
    }

    var list: std.ArrayList(schema.Collection) = .empty;
    for (parsed.value.array.items) |item| {
        if (item != .object) return error.InvalidSchema;
        const obj = item.object;
        // Skip system collections (e.g. _superusers) to match the comptime surface.
        if (obj.get("system")) |sv| {
            if (sv == .bool and sv.bool) continue;
        }
        const name = (objStr(obj, "name")) orelse return error.InvalidSchema;
        const type_str = objStr(obj, "type") orelse "base";
        const schema_json = try valueToJson(alloc, obj.get("schema"));
        const indexes_json = try valueToJson(alloc, obj.get("indexes"));
        const options_json = try valueToJson(alloc, obj.get("options"));
        try list.append(alloc, try acquire_core.buildCollection(alloc, .{
            .name = name,
            .type_str = type_str,
            .schema_json = schema_json,
            .indexes_json = indexes_json,
            .options_json = options_json,
        }));
    }
    const cols = try list.toOwnedSlice(alloc);
    // Resolve UUID targetCollectionIds → names (same as data-dir path).
    try acquire_core.resolveRelationTargets(alloc, cols, &id_to_name);
    acquire_core.sortByName(cols);
    return cols;
}

fn objStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Stringify a nested JSON value (array/object) back to text for the *FromJson
/// parsers. Missing values default to the empty array/object the parsers accept.
fn valueToJson(alloc: std.mem.Allocator, v: ?std.json.Value) ![]const u8 {
    const val = v orelse return "[]";
    if (val == .null) return "[]";
    return std.json.Stringify.valueAlloc(alloc, val, .{});
}

/// Authenticate as superuser then GET /api/collections. Network round-trip is
/// validated by SP3b's live e2e; SP3a unit-tests parseCollections.
pub fn acquire(alloc: std.mem.Allocator, io: std.Io, origin: []const u8, email: []const u8, password: []const u8) ![]schema.Collection {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();

    // 1) superuser auth-with-password -> token
    const auth_url = try std.fmt.allocPrint(alloc, "{s}/api/collections/_superusers/auth-with-password", .{origin});
    const auth_body = try std.fmt.allocPrint(alloc, "{{\"identity\":\"{s}\",\"password\":\"{s}\"}}", .{ email, password });
    const auth_resp = try doFetch(alloc, &client, .POST, auth_url, &.{.{ .name = "content-type", .value = "application/json" }}, auth_body);
    if (auth_resp.status != 200) {
        std.log.err("typegen: superuser auth failed (HTTP {d})", .{auth_resp.status});
        return error.AuthFailed;
    }
    const token = try extractToken(alloc, auth_resp.body);

    // 2) GET /api/collections with the bearer token
    const cols_url = try std.fmt.allocPrint(alloc, "{s}/api/collections", .{origin});
    const bearer = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    const cols_resp = try doFetch(alloc, &client, .GET, cols_url, &.{.{ .name = "authorization", .value = bearer }}, null);
    if (cols_resp.status != 200) {
        std.log.err("typegen: GET /api/collections failed (HTTP {d})", .{cols_resp.status});
        return error.CollectionsFetchFailed;
    }
    return parseCollections(alloc, cols_resp.body);
}

const Resp = struct { status: u16, body: []const u8 };

fn doFetch(alloc: std.mem.Allocator, client: *std.http.Client, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) !Resp {
    const buf = try alloc.alloc(u8, 8 << 20); // 8 MiB cap for a schema dump
    var fw = std.Io.Writer.fixed(buf);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .extra_headers = headers,
        .response_writer = &fw,
    });
    return .{ .status = @intFromEnum(res.status), .body = fw.buffered() };
}

fn extractToken(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.AuthFailed;
    const tv = parsed.value.object.get("token") orelse return error.AuthFailed;
    if (tv != .string) return error.AuthFailed;
    return alloc.dupe(u8, tv.string);
}

test "parseCollections: parses /api/collections array, strips auth fields, sorts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Shape mirrors collectionToJson output: fields under "schema", visible-only.
    const body =
        \\[
        \\ {"id":"c2","name":"posts","type":"base","system":false,
        \\  "schema":[{"id":"f1","name":"title","type":"text","options":{}}],
        \\  "indexes":[],"options":{}},
        \\ {"id":"c1","name":"users","type":"auth","system":false,
        \\  "schema":[{"id":"_email","name":"email","type":"email","options":{}},
        \\            {"id":"u1","name":"displayName","type":"text","options":{}}],
        \\  "indexes":[],"options":{}}
        \\]
    ;
    const cols = try parseCollections(a, body);
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("posts", cols[0].name); // name-sorted
    try std.testing.expectEqualStrings("users", cols[1].name);
    // Auth "email" stripped; only displayName remains.
    try std.testing.expectEqual(@as(usize, 1), cols[1].fields.len);
    try std.testing.expectEqualStrings("displayName", cols[1].fields[0].name);
}

test "parseCollections: resolves UUID targetCollectionId to collection name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The HTTP API serves live UUID ids, not names, in targetCollectionId.
    // The map is built from ALL elements (including system collections) before
    // the system-collection filter runs.
    const body =
        \\[
        \\ {"id":"col_users_uuid","name":"users","type":"auth","system":false,
        \\  "schema":[{"id":"u1","name":"displayName","type":"text","options":{}}],
        \\  "indexes":[],"options":{}},
        \\ {"id":"col_posts_uuid","name":"posts","type":"base","system":false,
        \\  "schema":[
        \\    {"id":"f1","name":"title","type":"text","options":{}},
        \\    {"id":"f2","name":"author","type":"relation",
        \\     "options":{"targetCollectionId":"col_users_uuid","maxSelect":1}}
        \\  ],
        \\  "indexes":[],"options":{}}
        \\]
    ;
    const cols = try parseCollections(a, body);
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    // name-sorted: posts, users
    try std.testing.expectEqualStrings("posts", cols[0].name);
    try std.testing.expectEqualStrings("users", cols[1].name);
    // The relation field's targetCollectionId must be resolved to the NAME, not the UUID.
    const posts = cols[0];
    try std.testing.expectEqual(@as(usize, 2), posts.fields.len);
    try std.testing.expectEqualStrings("author", posts.fields[1].name);
    switch (posts.fields[1].options) {
        .relation => |r| try std.testing.expectEqualStrings("users", r.targetCollectionId),
        else => return error.WrongFieldType,
    }
}
