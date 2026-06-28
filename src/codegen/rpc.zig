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
        // A larger route table accumulates comptime branches across the shared evaluation;
        // raise the per-evaluation quota well above the default 1000 so real-world apps with
        // dozens/hundreds of custom routes don't hit it (provision.zig uses 1_000_000; this is
        // safe headroom with zero runtime cost).
        @setEvalBranchQuota(100_000);
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

/// Render the RPC section with a fresh per-call seen-map (the standalone form used by
/// tests). The generator proper uses `renderShared` so the seen-map is shared with the
/// custom-auth surface for cross-surface collision detection.
pub fn render(comptime routes: []const RouteMeta, alloc: std.mem.Allocator) !Section {
    var seen = rpc_ts.SeenMap.init(alloc);
    defer seen.deinit();
    return renderShared(routes, alloc, &seen);
}

/// Like `render` but takes an externally-owned seen-map so named-decl deduplication and
/// TS-name collision detection span this surface AND the typed custom-auth surface.
pub fn renderShared(comptime routes: []const RouteMeta, alloc: std.mem.Allocator, seen: *rpc_ts.SeenMap) !Section {
    var decls: W = .empty;
    var iface: W = .empty;
    var factory: W = .empty;
    errdefer {
        decls.deinit(alloc);
        iface.deinit(alloc);
        factory.deinit(alloc);
    }

    inline for (routes) |r| {
        // Untyped handlers own the raw response (cookies/redirect/non-JSON body) and have
        // no typed Input/Output — emitting an RPC client method for them would produce a
        // call that mis-parses the response. Keep them off the typed RPC surface.
        if (r.untyped) continue;
        const has_params = comptime pathParams(r.path).len > 0;
        const has_input = r.Input != void;
        const out_ts = comptime rpc_ts.tsForType(r.Output);

        // 1) named decls for Input (if struct/enum) and Output (if struct/enum)
        try rpc_ts.renderNamedDeclsShared(r.Input, &decls, alloc, seen);
        try rpc_ts.renderNamedDeclsShared(r.Output, &decls, alloc, seen);

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
            try factory.appendSlice(alloc, "{ query: input as unknown as Record<string, string | number | boolean | undefined>, ...opts });\n");
        } else {
            try factory.appendSlice(alloc, "opts);\n");
        }
        try factory.appendSlice(alloc, "      },\n");
    }

    const decls_s = try decls.toOwnedSlice(alloc);
    errdefer alloc.free(decls_s);
    const iface_s = try iface.toOwnedSlice(alloc);
    errdefer alloc.free(iface_s);
    const factory_s = try factory.toOwnedSlice(alloc);
    return .{ .decls = decls_s, .iface_member = iface_s, .factory_member = factory_s };
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
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "query: input as unknown as Record<string, string | number | boolean | undefined>") != null);
}

// Struct shared by two routes to verify cross-route dedup.
const SharedOut = struct { ok: bool };
// Struct for the params+input coverage route.
const UpdateIn = struct { value: []const u8 };

test "render deduplicates named decls across routes sharing the same type" {
    const cross_routes = [_]events.RouteMeta{
        .{ .method = .POST, .path = "/api/a/confirm", .name = "aConfirm", .auth = .public, .Input = void, .Output = SharedOut },
        .{ .method = .POST, .path = "/api/b/confirm", .name = "bConfirm", .auth = .public, .Input = void, .Output = SharedOut },
    };
    const a = std.testing.allocator;
    const sec = try render(&cross_routes, a);
    defer a.free(sec.decls);
    defer a.free(sec.iface_member);
    defer a.free(sec.factory_member);

    // SharedOut must appear exactly once — not duplicated.
    const needle = "export interface SharedOut {";
    const first = std.mem.indexOf(u8, sec.decls, needle);
    try std.testing.expect(first != null);
    const last = std.mem.lastIndexOf(u8, sec.decls, needle);
    try std.testing.expectEqual(first, last);
}

test "render handles params+non-void input and no-params+void input call shapes" {
    const SomeStruct = struct { label: []const u8 };
    const mixed_routes = [_]events.RouteMeta{
        // params + non-void input (most complex case)
        .{ .method = .POST, .path = "/api/a/:x/b/:y", .name = "abUpdate", .auth = .public, .Input = UpdateIn, .Output = SomeStruct },
        // no params + void input
        .{ .method = .GET, .path = "/api/ping", .name = "ping", .auth = .public, .Input = void, .Output = void },
    };
    const a = std.testing.allocator;
    const sec = try render(&mixed_routes, a);
    defer a.free(sec.decls);
    defer a.free(sec.iface_member);
    defer a.free(sec.factory_member);

    // params + input: both appear in the signature
    try std.testing.expect(std.mem.indexOf(u8, sec.iface_member,
        "abUpdate(params: { x: string; y: string }, input: UpdateIn, opts?: SendOptions): Promise<SomeStruct>;") != null);
    // factory interpolates both params
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member,
        "${encodeURIComponent(String(params.x))}") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member,
        "${encodeURIComponent(String(params.y))}") != null);

    // no-params + void input: bare opts only
    try std.testing.expect(std.mem.indexOf(u8, sec.iface_member,
        "ping(opts?: SendOptions): Promise<void>;") != null);
    // factory calls send with bare opts (no body/query object)
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member,
        "return base.send(\"GET\", `/api/ping`, opts);") != null);
}

test "render skips untyped routes (no typed RPC surface for raw-response handlers)" {
    const untyped_routes = [_]events.RouteMeta{
        // Untyped handler: owns the raw response, so it must not appear in the client.
        .{ .method = .GET, .path = "/api/calendar.ics", .name = "calendarIcs", .auth = .public, .Input = void, .Output = void, .untyped = true },
        // A typed route alongside it must still be emitted normally.
        .{ .method = .GET, .path = "/api/search", .name = "search", .auth = .public, .Input = SearchIn, .Output = std.json.Value },
    };
    const a = std.testing.allocator;
    const sec = try render(&untyped_routes, a);
    defer a.free(sec.decls);
    defer a.free(sec.iface_member);
    defer a.free(sec.factory_member);

    // The untyped route contributes nothing: no interface member, factory method, or decls.
    try std.testing.expect(std.mem.indexOf(u8, sec.iface_member, "calendarIcs") == null);
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "calendarIcs") == null);
    // The typed route is still present.
    try std.testing.expect(std.mem.indexOf(u8, sec.iface_member, "search(input: SearchIn") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec.factory_member, "search(input, opts) {") != null);
}
