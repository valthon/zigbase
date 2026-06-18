//! RPC section renderer: walks a []const RouteMeta and assembles three TS fragments:
//!   1. `decls`          — `export interface`/`export type` declarations for named Input/Output types
//!   2. `iface_member`   — the `rpc: { … }` member body for the `ZbClient` interface
//!   3. `factory_member` — the `rpc: { … }` object body for the `createClient` factory
const std = @import("std");
const events = @import("../events.zig");
const http = @import("../http.zig");
const rpc_ts = @import("rpc_ts.zig");

const RouteMeta = events.RouteMeta;
const W = std.ArrayList(u8);

pub const Section = struct {
    decls: []const u8, // <Name>Input/<Name>Output interfaces + named nested decls
    iface_member: []const u8, // body of `rpc: { … }` in the ZbClient interface
    factory_member: []const u8, // body of `rpc: { … }` in createClient
};

/// Ordered ":segment" names (colon stripped) from a path.
pub fn pathParams(comptime path: []const u8) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (seg.len > 0 and seg[0] == ':') out = out ++ &[_][]const u8{seg[1..]};
        }
        return out;
    }
}

fn methodStr(comptime m: http.Method) []const u8 {
    return switch (m) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .PATCH => "PATCH",
        .DELETE => "DELETE",
        else => @compileError("rpc: unsupported HTTP method for a typed route"),
    };
}

fn isBodyMethod(comptime m: http.Method) bool {
    return m == .POST or m == .PUT or m == .PATCH;
}

/// `params: { id: string }` type literal, or "" if no params.
fn paramsTypeLiteral(comptime path: []const u8) []const u8 {
    const ps = pathParams(path);
    if (ps.len == 0) return "";
    comptime {
        var s: []const u8 = "params: { ";
        for (ps, 0..) |p, i| {
            if (i != 0) s = s ++ "; ";
            s = s ++ p ++ ": string";
        }
        return s ++ " }";
    }
}

/// The interpolated URL template literal for the route's path.
fn urlTemplate(comptime path: []const u8) []const u8 {
    comptime {
        var s: []const u8 = "`";
        var it = std.mem.splitScalar(u8, path, '/');
        var first = true;
        while (it.next()) |seg| {
            if (first) {
                first = false;
            } else {
                s = s ++ "/";
            }
            if (seg.len > 0 and seg[0] == ':') {
                s = s ++ "${encodeURIComponent(String(params." ++ seg[1..] ++ "))}";
            } else {
                s = s ++ seg;
            }
        }
        return s ++ "`";
    }
}

pub fn render(comptime routes: []const RouteMeta, alloc: std.mem.Allocator) !Section {
    var decls: W = .empty;
    var iface: W = .empty;
    var factory: W = .empty;
    errdefer {
        decls.deinit(alloc);
        iface.deinit(alloc);
        factory.deinit(alloc);
    }

    inline for (routes) |r| {
        const has_params = comptime pathParams(r.path).len > 0;
        const has_input = r.Input != void;
        const out_ts = comptime rpc_ts.tsForType(r.Output);

        // 1) named decls for Input (if struct/enum) and Output (if struct/enum)
        try rpc_ts.renderNamedDecls(r.Input, &decls, alloc);
        try rpc_ts.renderNamedDecls(r.Output, &decls, alloc);

        // 2) interface member: name(<params,><input,> opts?): Promise<Out>;
        try iface.appendSlice(alloc, "    ");
        try iface.appendSlice(alloc, r.name);
        try iface.appendSlice(alloc, "(");
        var wrote_arg = false;
        if (has_params) {
            try iface.appendSlice(alloc, comptime paramsTypeLiteral(r.path));
            wrote_arg = true;
        }
        if (has_input) {
            if (wrote_arg) try iface.appendSlice(alloc, ", ");
            try iface.appendSlice(alloc, "input: ");
            try iface.appendSlice(alloc, comptime rpc_ts.tsForType(r.Input));
            wrote_arg = true;
        }
        if (wrote_arg) try iface.appendSlice(alloc, ", ");
        try iface.appendSlice(alloc, "opts?: SendOptions): Promise<");
        try iface.appendSlice(alloc, if (r.Output == void) "void" else out_ts);
        try iface.appendSlice(alloc, ">;\n");

        // 3) factory method
        try factory.appendSlice(alloc, "      ");
        try factory.appendSlice(alloc, r.name);
        try factory.appendSlice(alloc, "(");
        var wrote_p = false;
        if (has_params) {
            try factory.appendSlice(alloc, "params");
            wrote_p = true;
        }
        if (has_input) {
            if (wrote_p) try factory.appendSlice(alloc, ", ");
            try factory.appendSlice(alloc, "input");
            wrote_p = true;
        }
        if (wrote_p) try factory.appendSlice(alloc, ", ");
        try factory.appendSlice(alloc, "opts) {\n");
        const send_prefix = comptime blk: {
            break :blk "        return base.send(\"" ++ methodStr(r.method) ++ "\", " ++ urlTemplate(r.path) ++ ", ";
        };
        try factory.appendSlice(alloc, send_prefix);
        // options object
        if (has_input and comptime isBodyMethod(r.method)) {
            try factory.appendSlice(alloc, "{ body: input, ...opts });\n");
        } else if (has_input) {
            try factory.appendSlice(alloc, "{ query: input as Record<string, string | number | boolean | undefined>, ...opts });\n");
        } else {
            try factory.appendSlice(alloc, "opts);\n");
        }
        try factory.appendSlice(alloc, "      },\n");
    }

    return .{
        .decls = try decls.toOwnedSlice(alloc),
        .iface_member = try iface.toOwnedSlice(alloc),
        .factory_member = try factory.toOwnedSlice(alloc),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const ConfirmOut = struct { id: []const u8, status: []const u8 };
const SearchIn = struct { q: []const u8, limit: i32 };

const test_routes = [_]events.RouteMeta{
    .{ .method = .POST, .path = "/api/bookings/:id/confirm", .name = "bookingsConfirm", .auth = .authed, .Input = void, .Output = ConfirmOut },
    .{ .method = .GET, .path = "/api/search", .name = "search", .auth = .public, .Input = SearchIn, .Output = std.json.Value },
};

test "pathParams extracts colon segments in order" {
    const ps = comptime pathParams("/api/bookings/:id/confirm");
    try std.testing.expectEqual(@as(usize, 1), ps.len);
    try std.testing.expectEqualStrings("id", ps[0]);
    try std.testing.expectEqual(@as(usize, 0), comptime pathParams("/api/search").len);
}

test "render emits interface member, factory method, and named decls" {
    const a = std.testing.allocator;
    const sec = try render(&test_routes, a);
    defer a.free(sec.decls);
    defer a.free(sec.iface_member);
    defer a.free(sec.factory_member);

    // Output interface emitted
    try std.testing.expect(std.mem.indexOf(u8, sec.decls, "export interface ConfirmOut {") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.decls, "export interface SearchIn {") != null);

    // Interface member: void input → no input arg; params object present; query route has input
    try std.testing.expect(std.mem.indexOf(u8, sec.iface_member,
        "bookingsConfirm(params: { id: string }, opts?: SendOptions): Promise<ConfirmOut>;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.iface_member,
        "search(input: SearchIn, opts?: SendOptions): Promise<unknown>;") != null);

    // Factory: POST interpolates :id and sends body absent (void input); GET sends query
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "bookingsConfirm(params, opts) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "`/api/bookings/${encodeURIComponent(String(params.id))}/confirm`") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "return base.send(\"POST\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "query: input as Record<string, string | number | boolean | undefined>") != null);
}
