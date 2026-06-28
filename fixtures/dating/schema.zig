//! The SP2.1b dating-app coverage fixture — exercises every schema capability in
//! one coherent domain. The generator reads this via @import("app").App.collections.
//! Plan 2: collection-scoped photo privacy (public `photos` vs auth-required
//! `privatePhotos`) + access rules so a live client can exercise the API.
const std = @import("std");
const zigbase = @import("zigbase");

// ---------------------------------------------------------------------------
// Route types + handlers for the RPC golden-test coverage.
// All handlers are pure (no DB access) so the fixture compiles and runs
// trivially as the live dating-server binary.
// ---------------------------------------------------------------------------

const Color = enum { red, green, blue };
const SendWinkIn = struct {
    note: []const u8,
    color: Color,
    sticker: ?[]const u8,
    tags: []const []const u8,
};
const SendWinkOut = struct { ok: bool, note: []const u8 };
const SearchOut = struct { count: i64 };

// void input + path param + struct output (POST)
fn echoPing(req: *zigbase.Req(void)) zigbase.RouteError!SendWinkOut {
    return .{ .ok = true, .note = req.param("id") orelse "" };
}
// POST body input (nested enum/optional/array) + struct output
fn winksSend(req: *zigbase.Req(SendWinkIn)) zigbase.RouteError!SendWinkOut {
    if (req.input.note.len == 0) return req.fail(400, "note required");
    return .{ .ok = true, .note = req.input.note };
}
// GET query input (flat scalars + enum) + struct output.
// SearchSort exercises the enum-in-query path: the GET route guard in buildRoutes
// must accept it (isQueryParseable is true for enums), and the thunk's parseQuery
// must coerce the query string "sort=newest" into the enum variant at runtime.
const SearchSort = enum { newest, oldest };
const SearchIn = struct { q: []const u8, limit: i32, sort: SearchSort };
fn messagesSearch(req: *zigbase.Req(SearchIn)) zigbase.RouteError!SearchOut {
    // Reference sort so an overzealous unused-variable lint doesn't fire;
    // the handler returns count only (sort drives ordering in a real impl).
    _ = req.input.sort;
    return .{ .count = req.input.limit };
}
// void input + void output (GET) — exercises Promise<void>
fn winksStatus(req: *zigbase.Req(void)) zigbase.RouteError!void {
    _ = req;
    return;
}
// std.json.Value output — exercises the `unknown` escape-hatch mapping in the
// generated TS client (Finding 3: ensure the golden + type-level tests cover it).
fn winksRaw(req: *zigbase.Req(void)) zigbase.RouteError!std.json.Value {
    _ = req;
    return .{ .bool = true };
}

// ---------------------------------------------------------------------------
// Custom auth method with DECLARED comptime I/O types (issue #119).
// `device_link` is a CLI/TV-style device-linking flow:
//   initiate (void input)      -> a device code the user enters elsewhere
//   complete ({ deviceCode })  -> a session token once the code is approved
// The typed `.custom` declaration below feeds the TS client generator so the
// generated client gets precise initiate/complete I/O — see App.custom_auth.
// The runtime impl is a no-op stub (this fixture exists for codegen coverage).
// ---------------------------------------------------------------------------
const DeviceLinkInitiateResp = struct { deviceCode: []const u8, expiresIn: i64 };
const DeviceLinkCompleteReq = struct { deviceCode: []const u8 };
const DeviceLinkSession = struct { token: []const u8 };

const DeviceLinkMethod = struct {
    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !DeviceLinkMethod {
        _ = gpa;
        _ = io;
        _ = cfg;
        return .{};
    }
    pub fn method(self: *DeviceLinkMethod) zigbase.AuthMethod {
        return .{ .slug = "device_link", .ctx = self, .vtable = &vtable };
    }
    pub fn deinit(self: *DeviceLinkMethod) void {
        _ = self;
    }
    const vtable = zigbase.AuthMethod.VTable{ .initiate = initiate, .complete = complete };
    fn initiate(ctx: *anyopaque, ac: *zigbase.AuthCtx) anyerror!zigbase.InitiateResult {
        _ = ctx;
        _ = ac;
        return .{ .status = 200, .body = "{\"deviceCode\":\"demo\",\"expiresIn\":600}" };
    }
    fn complete(ctx: *anyopaque, ac: *zigbase.AuthCtx) anyerror!zigbase.Resolution {
        _ = ctx;
        _ = ac;
        return .{ .fail = .{ .status = 501, .message = "device_link is a codegen demo; not implemented" } };
    }
};

pub const App = zigbase.App(.{
    .enable_typegen = true,
    .auth_methods = .{DeviceLinkMethod},
    // Feature flags + experiments (#130): exercise the typed `zb.flags.resolveAll`
    // surface (named booleans + a variant string-union) and the public GET /api/state.
    .flags = .{
        .device_link_v2 = false, // bare-bool shorthand default
        .verbose_winks = .{ .default = true, .description = "Send richer wink payloads" },
    },
    .experiments = .{
        .discovery_ranking = .{
            .variants = .{ "recency", "affinity", "hybrid" },
            .weights = .{ 34, 33, 33 },
            .description = "Profile discovery ordering",
        },
    },
    .routes = .{
        .{ .method = .POST, .path = "/api/echo/:id/ping", .handler = echoPing, .auth = .public },
        .{ .method = .POST, .path = "/api/winks/send", .handler = winksSend, .auth = .public },
        .{ .method = .GET, .path = "/api/messages/search", .handler = messagesSearch, .auth = .public },
        .{ .method = .GET, .path = "/api/winks/status", .handler = winksStatus, .auth = .public },
        .{ .method = .GET, .path = "/api/winks/raw", .handler = winksRaw, .auth = .public },
    },
    .collections = .{
        .profiles = .{
            .type = .auth,
            .fields = .{
                .{ .name = "name", .type = .text },
                .{ .name = "bio", .type = .editor },
                .{ .name = "website", .type = .url },
                .{ .name = "age", .type = .number, .mode = .int },
                .{ .name = "gender", .type = .select, .values = .{ "female", "male", "nonbinary", "other" } },
                .{ .name = "avatar", .type = .file },
            },
            // Public signup + public profile browsing; self-service edits.
            .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@request.auth.id = id", .delete = "@request.auth.id = id" },
            // Typed custom auth method (issue #119): the struct form carries comptime
            // I/O types the generator reflects into precise TS interfaces (named by the
            // Zig type). A void Initiate.Input omits the initiate `input` arg.
            .auth = .{ .methods = .{ .custom = &.{
                .{
                    .slug = "device_link",
                    .Initiate = .{ .Output = DeviceLinkInitiateResp },
                    .Complete = .{ .Input = DeviceLinkCompleteReq, .Output = DeviceLinkSession },
                },
            } } },
        },
        .tags = .{
            .fields = .{
                .{ .name = "label", .type = .text, .required = true, .unique = true },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@public", .update = "@public", .delete = "@public" },
        },
        .photos = .{
            .fields = .{
                .{ .name = "owner", .type = .relation, .target = "profiles" },
                .{ .name = "image", .type = .file },
                .{ .name = "caption", .type = .text },
                .{ .name = "tags", .type = .relation, .target = "tags", .maxSelect = 20 },
            },
            // Public photos: anyone can browse; create/edit need auth.
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
        // Private photos as a separate dependent collection (no per-field privacy):
        // owner-only list/view, so the IMAGE FILE is gated by the auth-required
        // viewRule — accessing it requires a files/token. Individual records so a
        // future feature could grant access to a specific private photo.
        .privatePhotos = .{
            .fields = .{
                .{ .name = "owner", .type = .relation, .target = "profiles" },
                .{ .name = "image", .type = .file },
                .{ .name = "caption", .type = .text },
            },
            .rules = .{ .list = "@request.auth.id = owner", .view = "@request.auth.id = owner", .create = "@request.auth.id != \"\"", .update = "@request.auth.id = owner", .delete = "@request.auth.id = owner" },
        },
        .messages = .{
            .fields = .{
                .{ .name = "from", .type = .relation, .target = "profiles" },
                .{ .name = "to", .type = .relation, .target = "profiles" },
                .{ .name = "body", .type = .text, .required = true },
                .{ .name = "sentAt", .type = .autodate, .onCreate = true },
                .{ .name = "read", .type = .@"bool" },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
        .winks = .{
            .fields = .{
                .{ .name = "from", .type = .relation, .target = "profiles" },
                .{ .name = "to", .type = .relation, .target = "profiles" },
                .{ .name = "createdAt", .type = .autodate, .onCreate = true },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
        .subscriptions = .{
            .fields = .{
                .{ .name = "profile", .type = .relation, .target = "profiles" },
                .{ .name = "plan", .type = .select, .values = .{ "free", "plus", "premium" } },
                .{ .name = "price", .type = .number, .mode = .fixed, .scale = 2 },
                .{ .name = "renewsAt", .type = .date, .min = "2020-01-01", .max = "2099-12-31" },
                .{ .name = "active", .type = .@"bool" },
                .{ .name = "metadata", .type = .json },
            },
            .rules = .{ .list = "@public", .view = "@public", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
        },
    },
});

// The generator's `app` module import resolves `App.collections`. A thin `main`
// keeps the module runnable as a normal zigbase app (Task 2 builds it as a server).
pub fn main(init: std.process.Init) !void {
    return App.runCli(init);
}
