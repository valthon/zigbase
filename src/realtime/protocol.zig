const std = @import("std");

pub const Action = enum { create, update, delete };

pub const ClientMsg = union(enum) {
    auth: struct { token: []const u8 },
    subscribe: struct { topic: []const u8, filter: ?[]const u8 },
    unsubscribe: struct { topic: []const u8 },
};

pub const Topic = struct { collection: []const u8, record_id: ?[]const u8 };

pub const ParseError = error{BadMessage} || std.mem.Allocator.Error;

fn objStr(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Parse a client message frame. Strings are duped onto `alloc` (fresh, independent of the
/// parse's own scratch — safe under any allocator, including a plain GPA).
/// Unknown action / missing field / non-object / bad JSON -> BadMessage.
pub fn parseClient(alloc: std.mem.Allocator, frame: []const u8) ParseError!ClientMsg {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, frame, .{}) catch return error.BadMessage;
    defer parsed.deinit(); // scratch: every string below is duped BEFORE this runs
    const root = parsed.value;
    if (root != .object) return error.BadMessage;
    const action = objStr(root, "action") orelse return error.BadMessage;
    if (std.mem.eql(u8, action, "auth")) {
        const token = objStr(root, "token") orelse return error.BadMessage;
        return .{ .auth = .{ .token = try alloc.dupe(u8, token) } };
    } else if (std.mem.eql(u8, action, "subscribe")) {
        const topic = objStr(root, "topic") orelse return error.BadMessage;
        const filter = objStr(root, "filter");
        const dup_topic = try alloc.dupe(u8, topic);
        errdefer alloc.free(dup_topic); // free `topic` if the `filter` dupe OOMs (error return)
        const dup_filter = if (filter) |f| try alloc.dupe(u8, f) else null;
        return .{ .subscribe = .{ .topic = dup_topic, .filter = dup_filter } };
    } else if (std.mem.eql(u8, action, "unsubscribe")) {
        const topic = objStr(root, "topic") orelse return error.BadMessage;
        return .{ .unsubscribe = .{ .topic = try alloc.dupe(u8, topic) } };
    }
    return error.BadMessage;
}

/// Split a topic into `<collection>` or `<collection>/<recordId>`.
pub fn parseTopic(topic: []const u8) Topic {
    if (std.mem.indexOfScalar(u8, topic, '/')) |i| {
        return .{ .collection = topic[0..i], .record_id = topic[i + 1 ..] };
    }
    return .{ .collection = topic, .record_id = null };
}

/// {"type":"event","topic":..,"action":..,"record":record}
///
/// `o` is pure scratch: `valueAlloc` reads it into a fresh, self-contained buffer before
/// returning, so its own backing arrays are freed here (never escape). `record` is the CALLER's
/// value (possibly a nested object/array) — `o.deinit` frees only `o`'s own map storage, never
/// `record`'s, so the caller's ownership of `record` is untouched.
pub fn serializeEvent(alloc: std.mem.Allocator, topic: []const u8, action: Action, record: std.json.Value) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    defer o.deinit(alloc);
    try o.put(alloc, "type", .{ .string = "event" });
    try o.put(alloc, "topic", .{ .string = topic });
    try o.put(alloc, "action", .{ .string = @tagName(action) });
    try o.put(alloc, "record", record);
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = o }, .{});
}

pub fn connectFrame(alloc: std.mem.Allocator, client_id: []const u8) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    defer o.deinit(alloc);
    try o.put(alloc, "type", .{ .string = "connect" });
    try o.put(alloc, "clientId", .{ .string = client_id });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = o }, .{});
}

pub fn ackFrame(alloc: std.mem.Allocator, action: []const u8, topic: []const u8) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    defer o.deinit(alloc);
    try o.put(alloc, "type", .{ .string = "ack" });
    try o.put(alloc, "action", .{ .string = action });
    try o.put(alloc, "topic", .{ .string = topic });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = o }, .{});
}

pub fn authFrame(alloc: std.mem.Allocator, ok: bool) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    defer o.deinit(alloc);
    try o.put(alloc, "type", .{ .string = "auth" });
    try o.put(alloc, "status", .{ .string = if (ok) "ok" else "error" });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = o }, .{});
}

pub fn errorFrame(alloc: std.mem.Allocator, message: []const u8) ![]u8 {
    var o: std.json.ObjectMap = .empty;
    defer o.deinit(alloc);
    try o.put(alloc, "type", .{ .string = "error" });
    try o.put(alloc, "message", .{ .string = message });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = o }, .{});
}

test "parseClient: auth / subscribe (with+without filter) / unsubscribe" {
    const a = std.testing.allocator;
    const m1 = try parseClient(a, "{\"action\":\"auth\",\"token\":\"jwt123\"}");
    defer a.free(m1.auth.token);
    try std.testing.expectEqualStrings("jwt123", m1.auth.token);
    const m2 = try parseClient(a, "{\"action\":\"subscribe\",\"topic\":\"posts\",\"filter\":\"status='x'\"}");
    defer a.free(m2.subscribe.topic);
    defer if (m2.subscribe.filter) |f| a.free(f);
    try std.testing.expectEqualStrings("posts", m2.subscribe.topic);
    try std.testing.expectEqualStrings("status='x'", m2.subscribe.filter.?);
    const m3 = try parseClient(a, "{\"action\":\"subscribe\",\"topic\":\"posts\"}");
    defer a.free(m3.subscribe.topic);
    try std.testing.expect(m3.subscribe.filter == null);
    const m4 = try parseClient(a, "{\"action\":\"unsubscribe\",\"topic\":\"posts\"}");
    defer a.free(m4.unsubscribe.topic);
    try std.testing.expectEqualStrings("posts", m4.unsubscribe.topic);
}

test "parseClient: malformed and unknown -> BadMessage" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadMessage, parseClient(a, "not json"));
    try std.testing.expectError(error.BadMessage, parseClient(a, "{\"action\":\"bogus\"}"));
    try std.testing.expectError(error.BadMessage, parseClient(a, "{\"action\":\"auth\"}"));
    try std.testing.expectError(error.BadMessage, parseClient(a, "[]"));
}

test "parseTopic splits collection and optional record id" {
    const t1 = parseTopic("posts");
    try std.testing.expectEqualStrings("posts", t1.collection);
    try std.testing.expect(t1.record_id == null);
    const t2 = parseTopic("posts/REC123");
    try std.testing.expectEqualStrings("posts", t2.collection);
    try std.testing.expectEqualStrings("REC123", t2.record_id.?);
}

test "serializeEvent emits type/topic/action/record" {
    const a = std.testing.allocator;
    var rec: std.json.ObjectMap = .empty;
    defer rec.deinit(a);
    try rec.put(a, "id", .{ .string = "REC1" });
    try rec.put(a, "title", .{ .string = "hi" });
    const s = try serializeEvent(a, "posts", .create, .{ .object = rec });
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"type\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"topic\":\"posts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"action\":\"create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"title\":\"hi\"") != null);
}

test "control frames" {
    const a = std.testing.allocator;
    const f1 = try connectFrame(a, "cid9");
    defer a.free(f1);
    try std.testing.expect(std.mem.indexOf(u8, f1, "\"clientId\":\"cid9\"") != null);
    const f2 = try ackFrame(a, "subscribe", "posts");
    defer a.free(f2);
    try std.testing.expect(std.mem.indexOf(u8, f2, "\"action\":\"subscribe\"") != null);
    const f3 = try authFrame(a, true);
    defer a.free(f3);
    try std.testing.expect(std.mem.indexOf(u8, f3, "\"status\":\"ok\"") != null);
    const f4 = try authFrame(a, false);
    defer a.free(f4);
    try std.testing.expect(std.mem.indexOf(u8, f4, "\"status\":\"error\"") != null);
    const f5 = try errorFrame(a, "nope");
    defer a.free(f5);
    try std.testing.expect(std.mem.indexOf(u8, f5, "\"message\":\"nope\"") != null);
}
